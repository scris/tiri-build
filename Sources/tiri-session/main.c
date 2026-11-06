// tiri-session keeps one terminal's program running when Tiri isn't.
//
// The first run forks a small background server that owns the real terminal and the program
// in it. Tiri's terminal view runs `tiri-session attach`, which only relays bytes between the
// two. Quit Tiri, or update it, and the relay ends while the server and the agent carry on. The
// next launch attaches again and replays recent output to redraw the screen.
//
// It's C, and small, because this process sits under every running agent, sometimes for days.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <pty.h>
#else
#include <util.h>
#endif
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/sysctl.h>
#endif

// Frames from the relay to the server: type, then a 16-bit length, then that many bytes.
//   'D' input for the program   'W' rows and columns, 16 bits each   'K' stop the program
//   'C' forget the output so far: the view was cleared with ⌘K, and a reattach shouldn't bring it back
// Frames from the server to the relay: type, then a 32-bit length, then that many bytes.
//   'D' the program's output    'R' the replay is over              'X' it exited, with this code
// 'R' carries whether there was anything to replay, then the server's protocol version, then its pid in
// 32 bits. A server from before versions sends only the first byte, which reads as version 0. Servers
// outlive many builds of Tiri, so anything new a server can do is asked for only once its version says
// it can. Version 1 takes SIGUSR1 from the relay as "a Ctrl-C is coming": see drop_waiting_keys.
//
// The relay exits with the program's code. It exits with SESSION_LOST when the server hung up without
// saying the program ended, so Tiri can tell a lost view from a finished program.

#define RING_BYTES (4 * 1024 * 1024)
#define READ_BYTES 65536
#define SESSION_PROTOCOL 1
#define SESSION_LOST 254
// Input waiting for a program that isn't reading it. Past this, the view isn't read until it's taken.
#define TYPED_BYTES (1024 * 1024)

static void die(const char *message) {
    fprintf(stderr, "tiri-session: %s: %s\n", message, strerror(errno));
    exit(70);
}

static int write_all(int fd, const void *data, size_t count) {
    const char *cursor = data;
    while (count > 0) {
        ssize_t written = write(fd, cursor, count);
        if (written < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                struct pollfd wait = {fd, POLLOUT, 0};
                if (poll(&wait, 1, 2000) <= 0) return -1;
                continue;
            }
            return -1;
        }
        cursor += written;
        count -= (size_t)written;
    }
    return 0;
}

static int connect_to(const char *path) {
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof address.sun_path) return -1;
    strcpy(address.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&address, sizeof address) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// MARK: Terminal modes

// A long-running program turns modes on once. If that's fell out of the replay buffer, the new
// view would never hear about it, so the modes that matter are remembered and said again.

static const int tracked_modes[] = {1, 7, 12, 25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1048, 1049, 2004, 2026};
#define TRACKED_COUNT (sizeof tracked_modes / sizeof tracked_modes[0])
static signed char mode_state[TRACKED_COUNT];  // 0 unknown, 1 set, -1 reset
static int kitty_level = -1;                   // The keyboard flags last pushed. -1 is none.

enum { S_GROUND, S_ESC, S_CSI, S_STRING, S_STRING_ESC };
static int parse_state = S_GROUND;
static char csi[32];
static size_t csi_length;

static void apply_csi(char final) {
    csi[csi_length] = 0;
    if ((final == 'h' || final == 'l') && csi[0] == '?') {
        char *cursor = csi + 1;
        while (*cursor) {
            long mode = strtol(cursor, &cursor, 10);
            for (size_t index = 0; index < TRACKED_COUNT; index++) {
                if (tracked_modes[index] == mode) mode_state[index] = final == 'h' ? 1 : -1;
            }
            if (*cursor == ';') cursor++;
            else break;
        }
    } else if (final == 'u' && csi[0] == '>') {
        kitty_level = atoi(csi + 1);
    } else if (final == 'u' && csi[0] == '<') {
        kitty_level = -1;
    }
}

static void track_output(const unsigned char *data, size_t count) {
    for (size_t index = 0; index < count; index++) {
        unsigned char byte = data[index];
        switch (parse_state) {
        case S_GROUND:
            if (byte == 0x1B) parse_state = S_ESC;
            break;
        case S_ESC:
            if (byte == '[') {
                parse_state = S_CSI;
                csi_length = 0;
            } else if (byte == ']' || byte == 'P' || byte == '_' || byte == '^') {
                parse_state = S_STRING;
            } else {
                parse_state = S_GROUND;
            }
            break;
        case S_CSI:
            if (byte >= 0x40 && byte <= 0x7E) {
                apply_csi((char)byte);
                parse_state = S_GROUND;
            } else if (csi_length < sizeof csi - 1) {
                csi[csi_length++] = (char)byte;
            }
            break;
        case S_STRING:
            if (byte == 0x07) parse_state = S_GROUND;
            else if (byte == 0x1B) parse_state = S_STRING_ESC;
            break;
        case S_STRING_ESC:
            parse_state = byte == '\\' ? S_GROUND : S_STRING;
            break;
        }
    }
}

// MARK: The server

static unsigned char *ring;
static size_t ring_start, ring_count;

static void ring_append(const unsigned char *data, size_t count) {
    if (count >= RING_BYTES) {
        data += count - RING_BYTES;
        count = RING_BYTES;
    }
    for (size_t remaining = count; remaining > 0;) {
        size_t end = (ring_start + ring_count) % RING_BYTES;
        size_t chunk = RING_BYTES - end;
        if (chunk > remaining) chunk = remaining;
        memcpy(ring + end, data, chunk);
        data += chunk;
        remaining -= chunk;
        if (ring_count + chunk <= RING_BYTES) {
            ring_count += chunk;
        } else {
            ring_start = (ring_start + (ring_count + chunk - RING_BYTES)) % RING_BYTES;
            ring_count = RING_BYTES;
        }
    }
}

static void put_header(unsigned char *header, char type, uint32_t count) {
    header[0] = (unsigned char)type;
    header[1] = (unsigned char)(count >> 24);
    header[2] = (unsigned char)(count >> 16);
    header[3] = (unsigned char)(count >> 8);
    header[4] = (unsigned char)count;
}

static int send_frame(int fd, char type, const void *data, uint32_t count) {
    unsigned char header[5];
    put_header(header, type, count);
    if (write_all(fd, header, sizeof header) < 0) return -1;
    return count ? write_all(fd, data, count) : 0;
}

// A program's output, read into the space after a frame header, so header and bytes go out in one
// write. A program printing a line at a time otherwise costs two writes and two wakeups per line.
static unsigned char output_frame[5 + READ_BYTES];

/// Reads what the program has written. After a small read, also whatever else is already waiting,
/// up to a frame: a program printing a line at a time otherwise becomes a frame, and a batch for the
/// view to parse, per line. A large read goes at once, so the view can be parsing it while this reads
/// the next. Never waits for more: a terminal's buffer is small, and a program blocks while it's full.
#define GATHER_BELOW 4096
static ssize_t read_output(int master) {
    ssize_t got = read(master, output_frame + 5, READ_BYTES);
    if (got <= 0 || got >= GATHER_BELOW) return got;
    size_t total = (size_t)got;
    while (total < READ_BYTES) {
        struct pollfd more = {master, POLLIN, 0};
        if (poll(&more, 1, 0) <= 0 || !(more.revents & POLLIN)) break;
        ssize_t extra = read(master, output_frame + 5 + total, READ_BYTES - total);
        if (extra <= 0) break;
        total += (size_t)extra;
    }
    return (ssize_t)total;
}

static int send_output(int fd, size_t count) {
    put_header(output_frame, 'D', (uint32_t)count);
    return write_all(fd, output_frame, 5 + count);
}

// Before each prompt zsh prints a % and a line's width of spaces, so a prompt can't overwrite a
// line left unfinished. On a fresh line it erases itself, but only at the width it was printed for.
// A view that's since changed size would show it above every prompt, so it isn't replayed.
static size_t without_prompt_marks(unsigned char *data, size_t count) {
    static const char mark[] = "\033[1m\033[7m%\033[27m\033[1m\033[0m";
    const size_t mark_length = sizeof mark - 1;
    size_t kept = 0;
    for (size_t index = 0; index < count;) {
        if (data[index] == 0x1B && count - index >= mark_length && memcmp(data + index, mark, mark_length) == 0) {
            size_t after = index + mark_length;
            while (after < count && data[after] == ' ') after++;
            if (count - after >= 3 && memcmp(data + after, "\r \r", 3) == 0) {
                index = after + 3;
                continue;
            }
        }
        data[kept++] = data[index++];
    }
    return kept;
}

static int send_replay(int fd) {
    // Start at the beginning of a line if the buffer has wrapped, so nothing begins mid-sequence.
    size_t skip = 0;
    if (ring_count == RING_BYTES) {
        while (skip < 4096 && skip < ring_count && ring[(ring_start + skip) % RING_BYTES] != '\n') skip++;
        if (skip < ring_count) skip++;
    }
    char prefix[512];
    size_t used = 0;
    if (ring_count == RING_BYTES) {
        for (size_t index = 0; index < TRACKED_COUNT; index++) {
            if (mode_state[index] && used + 16 < sizeof prefix) {
                used += (size_t)snprintf(prefix + used, sizeof prefix - used, "\033[?%d%c", tracked_modes[index], mode_state[index] > 0 ? 'h' : 'l');
            }
        }
        if (kitty_level >= 0 && used + 16 < sizeof prefix) {
            used += (size_t)snprintf(prefix + used, sizeof prefix - used, "\033[>%du", kitty_level);
        }
        if (used && send_frame(fd, 'D', prefix, (uint32_t)used) < 0) return -1;
    }
    size_t remaining = ring_count - skip;
    size_t position = (ring_start + skip) % RING_BYTES;
    unsigned char *flat = remaining ? malloc(remaining) : NULL;
    if (flat) {
        size_t first = RING_BYTES - position;
        if (first > remaining) first = remaining;
        memcpy(flat, ring + position, first);
        memcpy(flat + first, ring, remaining - first);
        remaining = without_prompt_marks(flat, remaining);
        for (size_t sent = 0; sent < remaining;) {
            size_t chunk = remaining - sent;
            if (chunk > READ_BYTES) chunk = READ_BYTES;
            if (send_frame(fd, 'D', flat + sent, (uint32_t)chunk) < 0) {
                free(flat);
                return -1;
            }
            sent += chunk;
        }
        free(flat);
    }
    // The relay needs to know whether there was anything to replay. See relay().
    uint32_t self = (uint32_t)getpid();
    unsigned char done[6] = {ring_count > 0, SESSION_PROTOCOL, (unsigned char)(self >> 24), (unsigned char)(self >> 16),
                             (unsigned char)(self >> 8), (unsigned char)self};
    return send_frame(fd, 'R', done, sizeof done);
}

static double now_seconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static volatile sig_atomic_t child_changed;
static void on_child(int signal) {
    (void)signal;
    child_changed = 1;
}

// SIGUSR1 from the relay: a Ctrl-C is on its way behind a paste the program isn't reading, and the relay
// has thrown away the rest of the paste. What's ahead of the Ctrl-C goes too. See drop_waiting_keys.
static volatile sig_atomic_t interrupt_coming;
static void on_interrupt_coming(int signal) {
    (void)signal;
    interrupt_coming = 1;
}

typedef struct {
    const char *socket_path;
    const char *directory;
    const char *argv0;
    char **command;
    struct winsize size;
    const char *report;  // A tag that says it's really from here, not something a program printed.
} launch_options;

static void remove_files(const char *socket_path) {
    char pid_path[1100];
    snprintf(pid_path, sizeof pid_path, "%s.pid", socket_path);
    unlink(socket_path);
    unlink(pid_path);
    snprintf(pid_path, sizeof pid_path, "%s.server", socket_path);
    unlink(pid_path);
}

// MARK: Who's running

// Beside the socket, `.pid` holds the program's pid and `.server` the server's. Each is written whole
// or not at all: a half-written file, on a full disk, must never read as a dead session.

static void write_pid_file(const char *socket_path, const char *suffix, int pid) {
    char path[1100], temporary[1200], text[32];
    snprintf(path, sizeof path, "%s%s", socket_path, suffix);
    snprintf(temporary, sizeof temporary, "%s.%d.tmp", path, (int)getpid());
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return;
    int length = snprintf(text, sizeof text, "%d\n", pid);
    int written = write_all(fd, text, (size_t)length) == 0;
    if (close(fd) == 0 && written && rename(temporary, path) == 0) return;
    unlink(temporary);
}

static int read_pid_file(const char *socket_path, const char *suffix) {
    char path[1100];
    snprintf(path, sizeof path, "%s%s", socket_path, suffix);
    FILE *file = fopen(path, "r");
    int pid = 0;
    if (file) {
        if (fscanf(file, "%d", &pid) != 1) pid = 0;
        fclose(file);
    }
    return pid;
}

static int parent_of(int pid) {
#if defined(__APPLE__)
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return 0;
    return (int)info.pbi_ppid;
#else
    char path[64], text[1024];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t got = read(fd, text, sizeof text - 1);
    close(fd);
    if (got <= 0) return 0;
    text[got] = 0;
    // After the name in brackets, which can hold anything: state, then the parent.
    char *end = strrchr(text, ')');
    int parent = 0;
    if (!end || sscanf(end + 1, " %*c %d", &parent) != 1) return 0;
    return parent;
#endif
}

enum { SERVER_UNKNOWN, SERVER_RUNNING, SERVER_GONE };

/// Whether pid is alive, and a session server rather than whatever got the number after it died.
static int session_process(int pid) {
    if (kill(pid, 0) != 0 && errno == ESRCH) return SERVER_GONE;
    char name[256] = "";
#if defined(__APPLE__)
    if (proc_name(pid, name, sizeof name) <= 0) return SERVER_UNKNOWN;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/comm", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return SERVER_UNKNOWN;
    ssize_t got = read(fd, name, sizeof name - 1);
    close(fd);
    if (got <= 0) return SERVER_UNKNOWN;
    name[got] = 0;
#endif
    return strncmp(name, "tiri-", 5) == 0 ? SERVER_RUNNING : SERVER_GONE;
}

/// What the pids beside the socket say about its server, without connecting, which would count as
/// attaching. A server from before `.server` existed is its program's parent.
static int server_state(const char *socket_path) {
    int server = read_pid_file(socket_path, ".server");
    if (server > 0) return session_process(server);
    int program = read_pid_file(socket_path, ".pid");
    if (program <= 0) return SERVER_UNKNOWN;
    int parent = parent_of(program);
    // The program outlived its server, or the number now belongs to something else.
    if (parent == 1) return SERVER_GONE;
    return parent > 1 ? (session_process(parent) == SERVER_RUNNING ? SERVER_RUNNING : SERVER_UNKNOWN) : SERVER_UNKNOWN;
}

// MARK: Telling a view over SSH what it can't see for itself

// On this Mac Tiri asks the system which folder a program is in and what's in the foreground. Over
// SSH it can't, so with --report the server says so, on the same stream as the output, in a private
// escape sequence that's never replayed. Fields are split by 0x1F, a command's arguments by 0x1E.

static int state_foreground(int master, pid_t child, char *directory, size_t room) {
    pid_t foreground = tcgetpgrp(master);
    if (foreground <= 0) foreground = child;
    directory[0] = 0;
#if defined(__linux__)
    char link[64];
    snprintf(link, sizeof link, "/proc/%d/cwd", (int)foreground);
    ssize_t got = readlink(link, directory, room - 1);
    if (got <= 0) {
        snprintf(link, sizeof link, "/proc/%d/cwd", (int)child);
        got = readlink(link, directory, room - 1);
    }
    if (got > 0) directory[got] = 0;
#elif defined(__APPLE__)
    struct proc_vnodepathinfo info;
    if (proc_pidinfo(foreground, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info) == (int)sizeof info
        || proc_pidinfo(child, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info) == (int)sizeof info) {
        snprintf(directory, room, "%s", info.pvi_cdir.vip_path);
    }
#endif
    return (int)foreground;
}

// Terminals drop control characters inside these sequences, and paths can hold anything. So fields
// split at `;`, and anything that could get in the way is written %XX.
static void put_encoded(char *out, size_t room, size_t *used, const char *text, size_t length) {
    static const char hex[] = "0123456789ABCDEF";
    for (size_t index = 0; index < length && *used + 4 < room; index++) {
        unsigned char byte = (unsigned char)text[index];
        if (byte < 0x21 || byte == 0x7F || byte == '%' || byte == ';') {
            out[(*used)++] = '%';
            out[(*used)++] = hex[byte >> 4];
            out[(*used)++] = hex[byte & 15];
        } else {
            out[(*used)++] = (char)byte;
        }
    }
    out[*used] = 0;
}

static size_t state_command(int pid, char *out, size_t room) {
    out[0] = 0;
#if defined(__linux__)
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t got = read(fd, out, room - 1);
    close(fd);
    if (got <= 0) return 0;
    out[got] = 0;
    return (size_t)got;
#else
    (void)pid;
    (void)room;
    return 0;
#endif
}

static char last_report[8192];

// A command's arguments split at %00.
/// A shell at its prompt, rather than a program it's running.
static int shell_in_front(int master, pid_t child) {
    static char directory[4096], command[1024];
    int foreground = state_foreground(master, child, directory, sizeof directory);
#if defined(__APPLE__)
    if (proc_name(foreground, command, sizeof command) <= 0) return 0;
#else
    if (!state_command(foreground, command, sizeof command)) return 0;
#endif
    const char *name = strrchr(command, '/');
    name = name ? name + 1 : command;
    if (*name == '-') name++;
    static const char *const shells[] = {"zsh", "bash", "sh", "dash", "fish", "tcsh", "csh", "ksh", NULL};
    for (int index = 0; shells[index]; index++) {
        if (strcmp(name, shells[index]) == 0) return 1;
    }
    return 0;
}

static void report_state(int client, int master, pid_t child, int force, const char *tag) {
    static char directory[4096], command[1024], encoded[6000], message[8192];
    int foreground = state_foreground(master, child, directory, sizeof directory);
    size_t length = state_command(foreground, command, sizeof command);
    size_t used = 0;
    encoded[0] = 0;
    put_encoded(encoded, sizeof encoded, &used, directory, strlen(directory));
    int written = snprintf(message, sizeof message, "\033]6973;n=%s;cwd=%s;fg=%d;shell=%d;cmd=", tag, encoded, foreground, (int)child);
    if (written <= 0 || written >= (int)sizeof message) return;
    used = (size_t)written;
    put_encoded(message, sizeof message - 2, &used, command, length);
    message[used++] = 7;
    message[used] = 0;
    if (!force && strcmp(message, last_report) == 0) return;
    strcpy(last_report, message);
    send_frame(client, 'D', message, (uint32_t)used);
}

// MARK: Input for the program

// A program that isn't reading takes about 1 KB before its terminal is full, and a write after that
// waits. This loop also reads the program's output and hears from the view, so a paste into a dev
// server would freeze it all. Input waits here instead, and goes in as the program takes it.

static unsigned char *typed;
static size_t typed_start, typed_count;

static void write_typed(int master) {
    while (typed_count > 0) {
        ssize_t written = write(master, typed + typed_start, typed_count);
        if (written < 0) {
            if (errno == EINTR) continue;
            // Anything but full means the program's going, and its input with it.
            if (errno != EAGAIN) typed_count = 0;
            break;
        }
        typed_start += (size_t)written;
        typed_count -= (size_t)written;
    }
    if (typed_count == 0) typed_start = 0;
}

static void queue_typed(int master, const unsigned char *data, size_t count) {
    if (typed_start + typed_count + count > TYPED_BYTES) {
        memmove(typed, typed + typed_start, typed_count);
        typed_start = 0;
    }
    memcpy(typed + typed_start + typed_count, data, count);
    typed_count += count;
    write_typed(master);
}

/// Where the last Ctrl-C, Ctrl-\ or Ctrl-Z is in what was typed, if the terminal takes it as a signal.
static long interrupt_at(int master, const unsigned char *data, size_t count) {
    struct termios modes;
    if (tcgetattr(master, &modes) != 0 || !(modes.c_lflag & ISIG) || (modes.c_lflag & NOFLSH)) return -1;
    const cc_t keys[3] = {modes.c_cc[VINTR], modes.c_cc[VQUIT], modes.c_cc[VSUSP]};
    for (size_t index = count; index-- > 0;) {
        for (int key = 0; key < 3; key++) {
            if (keys[key] != _POSIX_VDISABLE && data[index] == keys[key]) return (long)index;
        }
    }
    return -1;
}

/// Throws away what the program was sent and hasn't read. On a Mac this side can do it, but on Linux
/// flushing this side drops the program's output instead, and only its own side holds its input.
static void flush_program_input(int master) {
#if defined(__APPLE__)
    tcflush(master, TCIFLUSH);
#endif
    const char *name = ptsname(master);
    if (!name) return;
    int program_side = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (program_side < 0) return;
    tcflush(program_side, TCIFLUSH);
    close(program_side);
}

/// Takes typed input for the program, or says there isn't room for it yet. A Ctrl-C can't wait behind a
/// paste the program isn't reading: the terminal throws away what's waiting when it sees one, so this
/// does too, and the key goes straight in.
static int take_input(int master, const unsigned char *data, size_t count) {
    if (typed_count == 0) {
        queue_typed(master, data, count);
        if (typed_count == 0) return 1;
    } else if (count > TYPED_BYTES - typed_count) {
        if (interrupt_at(master, data, count) < 0) return 0;
    } else {
        queue_typed(master, data, count);
    }
    long at = interrupt_at(master, data, count);
    if (at >= 0) {
        typed_start = typed_count = 0;
        flush_program_input(master);
        queue_typed(master, data + at, count - (size_t)at);
    }
    return 1;
}

/// When typed input has to wait, where the first frame after it holding a Ctrl-C starts, or 0. Frames
/// from the relay: type, then a 16-bit length, then that many bytes.
static size_t frame_with_interrupt(int master, const unsigned char *frames, size_t count) {
    size_t at = 3 + (((size_t)frames[1] << 8) | frames[2]);
    while (count - at >= 3) {
        size_t length = ((size_t)frames[at + 1] << 8) | frames[at + 2];
        if (count - at < 3 + length) break;
        if (frames[at] == 'D' && interrupt_at(master, frames + at + 3, length) >= 0) return at;
        at += 3 + length;
    }
    return 0;
}

static int attach_lock = -1;

static void run_server(const launch_options *options, int listener) {
    ring = malloc(RING_BYTES);
    typed = malloc(TYPED_BYTES);
    if (!ring || !typed) exit(71);
    // Held by the view that started this. Kept, it would keep every later one waiting.
    if (attach_lock >= 0) close(attach_lock);
    attach_lock = -1;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_child;
    sigaction(SIGCHLD, &action, NULL);
    action.sa_handler = on_interrupt_coming;
    sigaction(SIGUSR1, &action, NULL);
    // Before the program starts, so an attach waiting on the lock can see this is here.
    write_pid_file(options->socket_path, ".server", (int)getpid());

    int master = -1;
    struct winsize size = options->size;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) die("forkpty");
    if (child == 0) {
        close(listener);
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        // Whatever started this may have ignored these, and a program inherits that: Ctrl-C would do nothing.
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTSTP, SIG_DFL);
        signal(SIGTTIN, SIG_DFL);
        signal(SIGTTOU, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
#ifdef IUTF8
        // Off by default, and then Backspace in a plain prompt takes one byte of a character that has three.
        struct termios modes;
        if (tcgetattr(STDIN_FILENO, &modes) == 0) {
            modes.c_iflag |= IUTF8;
            tcsetattr(STDIN_FILENO, TCSANOW, &modes);
        }
#endif
        if (options->directory && chdir(options->directory) != 0) { /* Stay where we are. */ }
        char *path = options->command[0];
        if (options->argv0) options->command[0] = (char *)options->argv0;
        execv(path, options->command);
        fprintf(stderr, "tiri-session: can't run %s: %s\r\n", path, strerror(errno));
        _exit(127);
    }

    write_pid_file(options->socket_path, ".pid", (int)child);
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);

    double last_report_at = 0;
    double interrupt_heard_at = 0;
    int client = -1;
    // Room to look past a paste that has to wait, for a Ctrl-C behind it. See frame_with_interrupt.
    static unsigned char input[4 * READ_BYTES];
    size_t input_count = 0;
    unsigned char buffer[READ_BYTES];
    int exit_code = -1;
    int program_done = 0;

    while (!program_done) {
        // The view isn't read while what it sent can't be taken, so it waits, rather than this.
        struct pollfd fds[3] = {{listener, POLLIN, 0}, {master, (short)(POLLIN | (typed_count ? POLLOUT : 0)), 0},
                                {input_count < sizeof input ? client : -1, POLLIN, 0}};
        int ready = poll(fds, 3, 500);
        if (ready < 0 && errno != EINTR) break;

        if (ready > 0 && (fds[0].revents & POLLIN)) {
            int fresh = accept(listener, NULL, NULL);
            if (fresh >= 0) {
                // One view at a time. The newest is the one you're looking at.
                if (client >= 0) close(client);
                client = fresh;
                input_count = 0;
                interrupt_coming = 0;
                struct timeval timeout = {2, 0};
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
                // A local socket holds 8 KB by default, so this would wait on the view after every frame.
                int room = 4 * READ_BYTES;
                setsockopt(client, SOL_SOCKET, SO_SNDBUF, &room, sizeof room);
                if (send_replay(client) < 0) {
                    close(client);
                    client = -1;
                } else if (options->report) {
                    report_state(client, master, child, 1, options->report);
                }
            }
        }

        if (options->report && client >= 0) {
            double now = now_seconds();
            if (now - last_report_at >= 0.7) {
                last_report_at = now;
                report_state(client, master, child, 0, options->report);
            }
        }

        if (ready > 0 && (fds[1].revents & (POLLIN | POLLHUP))) {
            ssize_t got = read_output(master);
            if (got > 0) {
                ring_append(output_frame + 5, (size_t)got);
                track_output(output_frame + 5, (size_t)got);
                if (client >= 0 && send_output(client, (size_t)got) < 0) {
                    close(client);
                    client = -1;
                }
            } else if (got == 0 || (errno != EINTR && errno != EAGAIN)) {
                program_done = 1;
            }
        }

        if (ready > 0 && (fds[1].revents & POLLOUT)) write_typed(master);

        int heard = 0;
        if (client >= 0 && ready > 0 && (fds[2].revents & (POLLIN | POLLHUP))) {
            ssize_t got = read(client, input + input_count, sizeof input - input_count);
            if (got <= 0) {
                close(client);
                client = -1;
                input_count = 0;
            } else {
                input_count += (size_t)got;
                heard = 1;
            }
        }
        // A Ctrl-C that was said to be coming and hasn't, in a while, isn't.
        if (!interrupt_coming) interrupt_heard_at = 0;
        else if (interrupt_heard_at == 0) interrupt_heard_at = now_seconds();
        else if (now_seconds() - interrupt_heard_at > 3) interrupt_coming = 0;
        // Again after the program takes some input, for what had to wait for room.
        if (client >= 0 && input_count >= 3 && (heard || interrupt_coming || typed_count < TYPED_BYTES - READ_BYTES)) {
            {
                size_t offset = 0;
                // Typed before a Ctrl-C further on, so thrown away with what the program hasn't taken.
                size_t dropped_before = 0;
                while (input_count - offset >= 3) {
                    unsigned char type = input[offset];
                    size_t length = ((size_t)input[offset + 1] << 8) | input[offset + 2];
                    if (input_count - offset < 3 + length) break;
                    const unsigned char *payload = input + offset + 3;
                    if (type == 'D') {
                        if (offset < dropped_before || (interrupt_coming && !memchr(payload, 3, length))) {
                            // Gone, with what the program hasn't taken.
                        } else {
                            interrupt_coming = 0;
                            if (!take_input(master, payload, length)) {
                                dropped_before = frame_with_interrupt(master, input + offset, input_count - offset);
                                if (!dropped_before) break;
                                dropped_before += offset;
                                continue;
                            }
                        }
                    } else if (type == 'W' && length == 4) {
                        struct winsize wanted;
                        memset(&wanted, 0, sizeof wanted);
                        wanted.ws_row = (unsigned short)((payload[0] << 8) | payload[1]);
                        wanted.ws_col = (unsigned short)((payload[2] << 8) | payload[3]);
                        // The same size wouldn't tell a program to redraw for the new view. A shell doesn't
                        // need to: the replay already put its screen back, and a redraw moves up over rows
                        // that have since wrapped differently, wiping or repeating lines.
                        if (!shell_in_front(master, child)) {
                            struct winsize nudge = wanted;
                            if (nudge.ws_row > 1) nudge.ws_row--;
                            ioctl(master, TIOCSWINSZ, &nudge);
                        }
                        ioctl(master, TIOCSWINSZ, &wanted);
                    } else if (type == 'C') {
                        ring_start = 0;
                        ring_count = 0;
                    } else if (type == 'K') {
                        // An agent is usually its own process group, in the foreground.
                        pid_t foreground = tcgetpgrp(master);
                        if (foreground > 0) kill(-foreground, SIGHUP);
                        kill(-child, SIGHUP);
                        kill(child, SIGHUP);
                        // Give it a moment to finish properly.
                        for (int attempt = 0; attempt < 20 && waitpid(child, NULL, WNOHANG) == 0; attempt++) usleep(100000);
                        if (foreground > 0) kill(-foreground, SIGKILL);
                        kill(-child, SIGKILL);
                        kill(child, SIGKILL);
                        remove_files(options->socket_path);
                        _exit(0);
                    }
                    offset += 3 + length;
                }
                memmove(input, input + offset, input_count - offset);
                input_count -= offset;
            }
        }

        if (child_changed) {
            child_changed = 0;
            int status;
            if (waitpid(child, &status, WNOHANG) == child) {
                exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                // Whatever it printed last is still on its way out.
                for (;;) {
                    struct pollfd drain = {master, POLLIN, 0};
                    if (poll(&drain, 1, 50) <= 0) break;
                    ssize_t got = read(master, buffer, sizeof buffer);
                    if (got <= 0) break;
                    ring_append(buffer, (size_t)got);
                    if (client >= 0) send_frame(client, 'D', buffer, (uint32_t)got);
                }
                program_done = 1;
            }
        }
    }

    if (exit_code < 0) {
        // The child ending is what interrupts this, if the terminal closed first.
        int status;
        pid_t waited;
        do {
            waited = waitpid(child, &status, 0);
        } while (waited < 0 && errno == EINTR);
        if (waited == child) exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        else exit_code = 0;
    }
    remove_files(options->socket_path);
    if (client >= 0) {
        unsigned char code = (unsigned char)exit_code;
        send_frame(client, 'X', &code, 1);
        close(client);
    }
    _exit(0);
}

/// Leaves a server running in the background, with the socket listening before this returns.
static void start_server(const launch_options *options) {
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    if (strlen(options->socket_path) >= sizeof address.sun_path) {
        errno = ENAMETOOLONG;
        die("socket path");
    }
    strcpy(address.sun_path, options->socket_path);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) die("socket");
    unlink(options->socket_path);
    mode_t previous = umask(0077);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) < 0) die("bind");
    umask(previous);
    if (listen(listener, 4) < 0) die("listen");

    pid_t first = fork();
    if (first < 0) die("fork");
    if (first > 0) {
        close(listener);
        waitpid(first, NULL, 0);
        return;
    }
    setsid();
    pid_t second = fork();
    if (second < 0) _exit(1);
    if (second > 0) _exit(0);
    int null = open("/dev/null", O_RDWR);
    if (null >= 0) {
        dup2(null, 0);
        dup2(null, 1);
        dup2(null, 2);
        if (null > 2) close(null);
    }
    run_server(options, listener);
}

// MARK: The relay

static struct termios saved_terminal;
static int have_saved_terminal;
static volatile sig_atomic_t size_changed = 1;

static void on_resize(int signal) {
    (void)signal;
    size_changed = 1;
}

static void restore_terminal(void) {
    if (have_saved_terminal) tcsetattr(STDIN_FILENO, TCSANOW, &saved_terminal);
}

static int send_input(int fd, char type, const void *data, size_t count) {
    unsigned char header[3] = {(unsigned char)type, (unsigned char)(count >> 8), (unsigned char)count};
    if (write_all(fd, header, 3) < 0) return -1;
    return count ? write_all(fd, data, count) : 0;
}

// The view asks for 'C' in what it types, so it stays in order with the keys around it. A private
// message, which nothing else sends: it never reaches the program.
static const char forget_marker[] = "\x1b_tiri:forget\x1b\\";

// What the relay has for the server, sent as the server takes it. The server stops reading while a
// program isn't taking its input, and a relay waiting to write would stop reading the server too, which
// would then give up on the view. So it waits here instead, whole frames from outgoing_head to
// outgoing_end, the first of them outgoing_written bytes on its way. Memory is only used as it fills,
// and the view isn't read once it's full. It's that large so a Ctrl-C typed after a paste the program
// isn't reading reaches the relay, rather than waiting behind the paste in the view.
#define OUTGOING_BYTES (16 * 1024 * 1024)
static unsigned char outgoing[OUTGOING_BYTES];
static size_t outgoing_head, outgoing_end, outgoing_written;
#define outgoing_count (outgoing_end - outgoing_head)

static size_t frame_length(size_t at) { return 3 + (((size_t)outgoing[at + 1] << 8) | outgoing[at + 2]); }

static void queue_frame(char type, const void *data, size_t count) {
    if (outgoing_end + 3 + count > OUTGOING_BYTES) {
        memmove(outgoing, outgoing + outgoing_head, outgoing_count);
        outgoing_end -= outgoing_head;
        outgoing_head = 0;
    }
    unsigned char *end = outgoing + outgoing_end;
    end[0] = (unsigned char)type;
    end[1] = (unsigned char)(count >> 8);
    end[2] = (unsigned char)count;
    if (count) memcpy(end + 3, data, count);
    outgoing_end += 3 + count;
}

static int send_outgoing(int server) {
    while (outgoing_count > outgoing_written) {
        ssize_t written = write(server, outgoing + outgoing_head + outgoing_written, outgoing_count - outgoing_written);
        if (written < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) break;
            outgoing_head = outgoing_end = outgoing_written = 0;
            return -1;
        }
        outgoing_written += (size_t)written;
        while (outgoing_count && frame_length(outgoing_head) <= outgoing_written) {
            outgoing_written -= frame_length(outgoing_head);
            outgoing_head += frame_length(outgoing_head);
        }
    }
    if (!outgoing_count) outgoing_head = outgoing_end = outgoing_written = 0;
    return 0;
}

/// What the server said it speaks, once its replay is over, and its pid. See SESSION_PROTOCOL.
static int server_protocol;
static pid_t server_pid;

/// Ctrl-C while a paste waits here for a program that isn't taking it: what's waiting is thrown away,
/// as a terminal throws away what's in it on Ctrl-C. Between here and the server there's more, which
/// the Ctrl-C would wait behind, so a server that knows how is told to throw that away too.
static void drop_waiting_keys(const unsigned char *keys, size_t count) {
    if (!memchr(keys, 3, count)) return;
    size_t on_its_way = outgoing_count && outgoing_written ? frame_length(outgoing_head) : 0;
    if (outgoing_count <= on_its_way) return;
    if (server_protocol >= 1 && server_pid > 0) kill(server_pid, SIGUSR1);
    size_t kept = outgoing_head, at = outgoing_head;
    while (at < outgoing_end) {
        size_t length = frame_length(at);
        // The one on its way has to arrive whole.
        if (outgoing[at] != 'D' || (at == outgoing_head && outgoing_written)) {
            memmove(outgoing + kept, outgoing + at, length);
            kept += length;
        }
        at += length;
    }
    outgoing_end = kept;
}

/// Frames for what was typed: at most twice as many bytes, which the caller leaves room for.
static void send_keys(const unsigned char *keys, size_t count) {
    size_t marker_length = sizeof forget_marker - 1;
    size_t start = 0;
    for (size_t index = 0; index + marker_length <= count; index++) {
        if (keys[index] != 0x1b || memcmp(keys + index, forget_marker, marker_length) != 0) continue;
        if (index > start) queue_frame('D', keys + start, index - start);
        queue_frame('C', NULL, 0);
        start = index + marker_length;
        index = start - 1;
    }
    if (count > start) queue_frame('D', keys + start, count - start);
}

/// Connects to the terminal's server, or starts one when there's none. Two views starting the same
/// terminal at once take turns here, or both would start one and the second would take the socket
/// from the first. Only a socket nobody listens on, or no socket, means there's none: a server that's
/// busy refuses for a moment too, and its pid says it's still there.
static int attach_or_start(launch_options *options) {
    if (strlen(options->socket_path) >= sizeof ((struct sockaddr_un *)0)->sun_path) {
        errno = ENAMETOOLONG;
        die("socket path");
    }
    char lock_path[1100];
    snprintf(lock_path, sizeof lock_path, "%s.lock", options->socket_path);
    attach_lock = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (attach_lock >= 0) {
        while (flock(attach_lock, LOCK_EX) < 0 && errno == EINTR) {}
    }
    int server = -1;
    for (int attempt = 0; attempt < 250; attempt++) {
        server = connect_to(options->socket_path);
        if (server >= 0) break;
        int refused = errno == ECONNREFUSED;
        if (!refused && errno != ENOENT) {
            usleep(20000);
            continue;
        }
        if (refused && server_state(options->socket_path) == SERVER_RUNNING) {
            usleep(20000);
            continue;
        }
        if (!options->command || !options->command[0]) break;
        if (ioctl(STDIN_FILENO, TIOCGWINSZ, &options->size) != 0 || options->size.ws_row == 0) {
            options->size.ws_row = 24;
            options->size.ws_col = 80;
        }
        start_server(options);
        for (int wait = 0; wait < 100 && server < 0; wait++) {
            server = connect_to(options->socket_path);
            if (server < 0) usleep(20000);
        }
        // The next attach in line would take a socket that refuses, without the pid, for one that's gone.
        for (int wait = 0; wait < 100 && server >= 0 && read_pid_file(options->socket_path, ".server") <= 0; wait++) usleep(20000);
        break;
    }
    int saved = errno;
    if (attach_lock >= 0) close(attach_lock);
    attach_lock = -1;
    errno = saved;
    return server;
}

static int relay(int server) {
    signal(SIGPIPE, SIG_IGN);
    int room = 4 * READ_BYTES;  // See the server's side, in run_server.
    setsockopt(server, SOL_SOCKET, SO_RCVBUF, &room, sizeof room);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_resize;
    sigaction(SIGWINCH, &action, NULL);
    if (tcgetattr(STDIN_FILENO, &saved_terminal) == 0) {
        have_saved_terminal = 1;
        atexit(restore_terminal);
        struct termios raw = saved_terminal;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }

    static unsigned char incoming[READ_BYTES + 8];
    size_t incoming_count = 0;
    unsigned char keys[32768];
    // While old output replays, the view answers questions that were asked long ago. Those answers
    // would land in the program as if typed, so they're dropped until the replay has settled.
    // Anything typed before the server has said hello just waits in the terminal for it.
    double accept_input_after = -1;
    int size_sent_after_replay = 0;
    // A server that's gone has still left its last output and the exit code to read.
    int can_send = 1;
    fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK);

    for (;;) {
        if (size_changed && (accept_input_after >= 0) && outgoing_count + 7 <= OUTGOING_BYTES) {
            size_changed = 0;
            struct winsize size;
            if (can_send && ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0) {
                unsigned char payload[4] = {(unsigned char)(size.ws_row >> 8), (unsigned char)size.ws_row,
                                            (unsigned char)(size.ws_col >> 8), (unsigned char)size.ws_col};
                queue_frame('W', payload, 4);
            }
        }
        if (can_send && outgoing_count && send_outgoing(server) < 0) can_send = 0;
        // Room for the most that one read of keys can become.
        int take_keys = accept_input_after >= 0 && outgoing_count + 2 * sizeof keys + 16 <= OUTGOING_BYTES;
        struct pollfd fds[2] = {{server, (short)(POLLIN | (outgoing_count ? POLLOUT : 0)), 0}, {STDIN_FILENO, POLLIN, 0}};
        int ready = poll(fds, take_keys ? 2 : 1, 200);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (take_keys && (fds[1].revents & (POLLIN | POLLHUP))) {
            ssize_t got = read(STDIN_FILENO, keys, sizeof keys);
            if (got <= 0) return 0;  // The view went away. The server and its program carry on.
            int accepting = accept_input_after >= 0 && now_seconds() >= accept_input_after;
            if (accepting && can_send) {
                drop_waiting_keys(keys, (size_t)got);
                send_keys(keys, (size_t)got);
            }
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t got = read(server, incoming + incoming_count, sizeof incoming - incoming_count);
            if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            // Gone without saying the program ended: the server dropped this view, or is gone itself.
            if (got <= 0) return SESSION_LOST;
            incoming_count += (size_t)got;
            size_t offset = 0;
            // Output frames that arrived together go to the view in one write, so it parses one batch.
            size_t pending = 0;
            while (incoming_count - offset >= 5) {
                unsigned char type = incoming[offset];
                uint32_t length = ((uint32_t)incoming[offset + 1] << 24) | ((uint32_t)incoming[offset + 2] << 16)
                    | ((uint32_t)incoming[offset + 3] << 8) | incoming[offset + 4];
                if (incoming_count - offset < 5 + (size_t)length) break;
                const unsigned char *payload = incoming + offset + 5;
                if (type == 'D') {
                    // Compacted in place: what's written always sits before what's still to read.
                    memmove(incoming + pending, payload, length);
                    pending += length;
                    offset += 5 + (size_t)length;
                    continue;
                }
                if (pending) {
                    if (write_all(STDOUT_FILENO, incoming, pending) < 0) return 0;
                    pending = 0;
                }
                if (type == 'R') {
                    accept_input_after = length && payload[0] ? now_seconds() + 0.15 : 0;
                    server_protocol = length >= 2 ? payload[1] : 0;
                    server_pid = length >= 6 ? (pid_t)(((uint32_t)payload[2] << 24) | ((uint32_t)payload[3] << 16)
                                                       | ((uint32_t)payload[4] << 8) | payload[5]) : 0;
                    if (!size_sent_after_replay) {
                        size_sent_after_replay = 1;
                        size_changed = 1;
                    }
                } else if (type == 'X') {
                    return length ? payload[0] : 0;
                }
                offset += 5 + (size_t)length;
            }
            if (pending && write_all(STDOUT_FILENO, incoming, pending) < 0) return 0;
            memmove(incoming, incoming + offset, incoming_count - offset);
            incoming_count -= offset;
        }
    }
}

// MARK: What it was started with

// Whatever started this leaves its own files open in it: the app's sockets and pipes, other
// terminals' masters. Kept, they'd last as long as the agent, and a pipe would never see its end.
// Everything past 0-2 goes, before anything of this program's own is opened.
#if defined(__linux__)
#include <dirent.h>
#endif

static void close_inherited(void) {
#if defined(__APPLE__)
    int room = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (room > 0) {
        room += 32 * (int)PROC_PIDLISTFD_SIZE;
        struct proc_fdinfo *found = malloc((size_t)room);
        int used = found ? proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, found, room) : 0;
        if (used > 0) {
            for (int index = 0; index < used / (int)PROC_PIDLISTFD_SIZE; index++) {
                if (found[index].proc_fd > 2) close(found[index].proc_fd);
            }
            free(found);
            return;
        }
        free(found);
    }
#elif defined(__linux__)
    DIR *folder = opendir("/proc/self/fd");
    if (folder) {
        int open_fds[4096], count = 0, own = dirfd(folder);
        struct dirent *entry;
        while ((entry = readdir(folder)) && count < 4096) {
            int fd = atoi(entry->d_name);
            if (fd > 2 && fd != own) open_fds[count++] = fd;
        }
        closedir(folder);
        if (count < 4096) {
            for (int index = 0; index < count; index++) close(open_fds[index]);
            return;
        }
    }
#endif
    int limit = getdtablesize();
    if (limit < 0 || limit > 65536) limit = 65536;
    for (int fd = 3; fd < limit; fd++) close(fd);
}

int main(int argc, char **argv) {
    close_inherited();
    // tiri-session attach <socket> [--cwd DIR] [--argv0 NAME] -- program args...
    if (argc >= 3 && strcmp(argv[1], "attach") == 0) {
        launch_options options;
        memset(&options, 0, sizeof options);
        options.socket_path = argv[2];
        int index = 3;
        while (index < argc) {
            if (strcmp(argv[index], "--cwd") == 0 && index + 1 < argc) {
                options.directory = argv[index + 1];
                index += 2;
            } else if (strcmp(argv[index], "--argv0") == 0 && index + 1 < argc) {
                options.argv0 = argv[index + 1];
                index += 2;
            } else if (strcmp(argv[index], "--report") == 0 && index + 1 < argc) {
                options.report = argv[index + 1];
                index += 2;
            } else if (strcmp(argv[index], "--") == 0) {
                options.command = argv + index + 1;
                break;
            } else {
                break;
            }
        }
        int server = attach_or_start(&options);
        if (server < 0) {
            if (!options.command || !options.command[0]) {
                fprintf(stderr, "tiri-session: nothing is running at %s\n", options.socket_path);
                return 3;
            }
            die("connect");
        }
        return relay(server);
    }
    // tiri-session kill <socket>: ends the program, because its terminal was closed on purpose.
    if (argc == 3 && strcmp(argv[1], "kill") == 0) {
        int server = connect_to(argv[2]);
        if (server < 0) return 3;
        send_input(server, 'K', NULL, 0);
        char sink[65536];
        while (read(server, sink, sizeof sink) > 0) {}
        return 0;
    }
    // tiri-session alive <socket>: asking the socket would count as attaching, so this reads the pids,
    // and asks the socket only when they can't say.
    if (argc == 3 && strcmp(argv[1], "alive") == 0) {
        int state = server_state(argv[2]);
        if (state != SERVER_UNKNOWN) return state == SERVER_RUNNING ? 0 : 1;
        int server = connect_to(argv[2]);
        if (server >= 0) {
            close(server);
            return 0;
        }
        return errno == ECONNREFUSED || errno == ENOENT ? 1 : 0;
    }
    fprintf(stderr, "usage: tiri-session attach <socket> [--cwd DIR] [--argv0 NAME] [--report TAG] -- program args...\n");
    return 64;
}
