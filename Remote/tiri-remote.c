// tiri-remote is what Tiri leaves on a server it connects to, and all of it. One static binary:
//
//   session attach|kill|alive …    keeps a terminal's program running when the connection isn't
//   scan <dir>… [--exclude a,b] [--max N] [--depth N]   lists what's there
//   watch <dir>… [--exclude a,b] [--heartbeat]   says what changes, until its stdin closes
//   write <path>                   replaces a file with stdin, in one step, keeping its mode
//   tiri …  (or run as `tiri`)     relays a `tiri` command to the Mac
//   relay <socket> [--heartbeat]   where those commands arrive, carried over its own stdin and stdout
//
// --heartbeat: the Mac sends a newline every 15 seconds, and a minute without one means it's gone, so
// the process ends rather than waiting for a connection that may never close.
//
// C and static so it runs on any Linux, needs nothing installed and takes almost no room.
// Records from scan and watch end in NUL: type, tab, mtime in ms, tab, size, tab, path.
//   d folder   f file   l link to a file   L link to a folder   ? broken link   - gone
// Watch also says !ready, !rescan (it lost track, look again), !limited (out of kernel watches,
// so it can't see everything) and !git (the repository moved).

#define main tiri_session_main
#include "../Sources/tiri-session/main.c"
#undef main

#include <dirent.h>
#include <fnmatch.h>
#include <sys/file.h>
#if defined(__linux__)
#include <limits.h>
#include <sys/inotify.h>
#endif

#if defined(__APPLE__)
#define MTIME_MS(st) ((long long)(st).st_mtimespec.tv_sec * 1000 + (st).st_mtimespec.tv_nsec / 1000000)
#else
#define MTIME_MS(st) ((long long)(st).st_mtim.tv_sec * 1000 + (st).st_mtim.tv_nsec / 1000000)
#endif

// MARK: Excludes

static char *excludes[256];
static int exclude_count;

static void add_excludes(char *list) {
    for (char *part = strtok(list, ","); part && exclude_count < 256; part = strtok(NULL, ",")) {
        excludes[exclude_count++] = part;
    }
}

static int excluded(const char *name) {
    for (int index = 0; index < exclude_count; index++) {
        if (strcmp(excludes[index], name) == 0 || fnmatch(excludes[index], name, 0) == 0) return 1;
    }
    return 0;
}

// MARK: Records

static char describe(const char *path, struct stat *info) {
    if (lstat(path, info) != 0) return '-';
    if (S_ISLNK(info->st_mode)) {
        struct stat target;
        if (stat(path, &target) != 0) return '?';
        info->st_size = target.st_size;
        return S_ISDIR(target.st_mode) ? 'L' : 'l';
    }
    if (S_ISDIR(info->st_mode)) return 'd';
    return 'f';
}

static void emit(const char *path) {
    struct stat info;
    memset(&info, 0, sizeof info);
    char type = describe(path, &info);
    printf("%c\t%lld\t%lld\t%s", type, type == '-' ? 0LL : MTIME_MS(info), type == '-' ? 0LL : (long long)info.st_size, path);
    putchar(0);
}

// MARK: scan

static long scan_left = 200000;

static int scan_partial;

static void scan_directory(const char *directory, int depth) {
    DIR *handle = opendir(directory);
    if (!handle) {
        // Not a folder is fine. Couldn't look in one means this isn't the whole picture.
        if (errno != ENOTDIR && errno != ENOENT) scan_partial = 1;
        return;
    }
    struct dirent *entry;
    // Only used before recursing, so one will do, and deep trees can't run out of stack.
    static char path[8192];
    // Files before descending, so a cut-off scan shows the top of the tree rather than one deep corner.
    size_t cap = 64, count = 0;
    char **folders = malloc(cap * sizeof *folders);
    while ((entry = readdir(handle))) {
        const char *name = entry->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || excluded(name)) continue;
        if (scan_left <= 0) break;
        int written = snprintf(path, sizeof path, "%s/%s", strcmp(directory, "/") == 0 ? "" : directory, name);
        if (written <= 0 || written >= (int)sizeof path) continue;
        scan_left--;
        emit(path);
        struct stat info;
        if (depth != 1 && lstat(path, &info) == 0 && S_ISDIR(info.st_mode)) {
            if (count == cap) {
                cap *= 2;
                folders = realloc(folders, cap * sizeof *folders);
            }
            folders[count++] = strdup(path);
        }
    }
    closedir(handle);
    for (size_t index = 0; index < count; index++) {
        if (scan_left > 0) scan_directory(folders[index], depth > 0 ? depth - 1 : depth);
        free(folders[index]);
    }
    free(folders);
}

static int run_scan(int argc, char **argv) {
    int depth = 0;
    char *roots[64];
    int root_count = 0;
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--exclude") == 0 && index + 1 < argc) add_excludes(argv[++index]);
        else if (strcmp(argv[index], "--max") == 0 && index + 1 < argc) scan_left = atol(argv[++index]);
        else if (strcmp(argv[index], "--depth") == 0 && index + 1 < argc) depth = atoi(argv[++index]);
        else if (root_count < 64) roots[root_count++] = argv[index];
    }
    for (int index = 0; index < root_count; index++) {
        emit(roots[index]);
        scan_directory(roots[index], depth);
    }
    if (scan_left <= 0) { printf("!truncated"); putchar(0); }
    if (scan_partial) { printf("!partial"); putchar(0); }
    return fflush(stdout) == 0 ? 0 : 1;
}

// MARK: Hearing from the Mac

#define HEARTBEAT_LIMIT 60.0

static int heartbeat;
static double last_heard;

static void heard(void) { last_heard = now_seconds(); }

static int mac_gone(void) { return heartbeat && now_seconds() - last_heard > HEARTBEAT_LIMIT; }

// How long a poll may wait: for ever, unless it has to notice the Mac going quiet.
static int heartbeat_wait(int otherwise) {
    if (!heartbeat) return otherwise;
    return otherwise >= 0 && otherwise < 5000 ? otherwise : 5000;
}

// The watcher has nothing to hear on stdin but the heartbeat, and its end.
static int drain_stdin_until_gone(void) {
    char sink[256];
    for (;;) {
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&input, 1, heartbeat_wait(-1));
        if (ready < 0 && errno != EINTR) return 0;
        if (ready > 0) {
            ssize_t got = read(STDIN_FILENO, sink, sizeof sink);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) return 0;
            heard();
        }
        if (mac_gone()) return 0;
    }
}

// MARK: watch

#if defined(__linux__)

static int watcher = -1;
static char **watched;       // By watch descriptor.
static int watched_cap;
static int limited;

static void remember_watch(int descriptor, const char *path) {
    if (descriptor >= watched_cap) {
        int fresh = watched_cap ? watched_cap : 1024;
        while (fresh <= descriptor) fresh *= 2;
        watched = realloc(watched, (size_t)fresh * sizeof *watched);
        memset(watched + watched_cap, 0, (size_t)(fresh - watched_cap) * sizeof *watched);
        watched_cap = fresh;
    }
    free(watched[descriptor]);
    watched[descriptor] = strdup(path);
}

static void watch_tree(const char *directory) {
    if (strlen(directory) > 7000) return;
    const uint32_t mask = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_ONLYDIR;
    int descriptor = inotify_add_watch(watcher, directory, mask);
    if (descriptor < 0) {
        if ((errno == ENOSPC || errno == ENOMEM) && !limited) {
            limited = 1;
            printf("!limited");
            putchar(0);
        }
        return;
    }
    remember_watch(descriptor, directory);
    DIR *handle = opendir(directory);
    if (!handle) return;
    struct dirent *entry;
    char *path = malloc(8192);
    if (!path) {
        closedir(handle);
        return;
    }
    while ((entry = readdir(handle))) {
        const char *name = entry->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || excluded(name)) continue;
#ifdef DT_DIR
        if (entry->d_type != DT_DIR && entry->d_type != DT_UNKNOWN) continue;
#endif
        int written = snprintf(path, 8192, "%s/%s", strcmp(directory, "/") == 0 ? "" : directory, name);
        if (written <= 0 || written >= 8192) continue;
        struct stat info;
        if (lstat(path, &info) == 0 && S_ISDIR(info.st_mode)) watch_tree(path);
    }
    free(path);
    closedir(handle);
}

// What changed since the last flush, without repeats. Agents write in bursts.
static char *pending[4096];
static int pending_count;
static int pending_overflow;
static int git_moved;

static void note_change(const char *path) {
    for (int index = pending_count - 1; index >= 0 && index >= pending_count - 64; index--) {
        if (strcmp(pending[index], path) == 0) return;
    }
    if (pending_count == 4096) {
        pending_overflow = 1;
        return;
    }
    pending[pending_count++] = strdup(path);
}

static void flush_changes(void) {
    if (pending_overflow) {
        printf("!rescan");
        putchar(0);
    } else {
        for (int index = 0; index < pending_count; index++) emit(pending[index]);
    }
    for (int index = 0; index < pending_count; index++) free(pending[index]);
    pending_count = 0;
    pending_overflow = 0;
    if (git_moved) {
        printf("!git");
        putchar(0);
        git_moved = 0;
    }
    fflush(stdout);
}

// Agents commit all the time, and nothing in the tree changes when they do. A commit, a checkout
// and a pull all move these two files. The index isn't watched: reading status rewrites it.
static void watch_repository(const char *root) {
    char path[8192];
    snprintf(path, sizeof path, "%s/.git", root);
    int descriptor = inotify_add_watch(watcher, path, IN_MOVED_TO | IN_CLOSE_WRITE | IN_ONLYDIR);
    if (descriptor >= 0) remember_watch(descriptor, path);
    snprintf(path, sizeof path, "%s/.git/logs", root);
    descriptor = inotify_add_watch(watcher, path, IN_MOVED_TO | IN_CLOSE_WRITE | IN_ONLYDIR);
    if (descriptor >= 0) remember_watch(descriptor, path);
}

static int is_git_watch(const char *path) {
    size_t length = strlen(path);
    return (length >= 5 && strcmp(path + length - 5, "/.git") == 0)
        || (length >= 10 && strcmp(path + length - 10, "/.git/logs") == 0);
}

static int run_watch(int argc, char **argv) {
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--exclude") == 0 && index + 1 < argc) add_excludes(argv[++index]);
        else if (strcmp(argv[index], "--heartbeat") == 0) heartbeat = 1;
    }
    heard();
    watcher = inotify_init1(IN_CLOEXEC);
    if (watcher < 0) {
        printf("!limited");
        putchar(0);
        fflush(stdout);
        return drain_stdin_until_gone();
    }
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--exclude") == 0) {
            index++;
            continue;
        }
        if (strcmp(argv[index], "--heartbeat") == 0) continue;
        watch_tree(argv[index]);
        watch_repository(argv[index]);
    }
    printf("!ready");
    putchar(0);
    fflush(stdout);

    static char events[65536] __attribute__((aligned(__alignof__(struct inotify_event))));
    char path[8192];
    double first_pending = 0;
    for (;;) {
        struct pollfd fds[2] = {{watcher, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        int waiting = pending_count || git_moved || pending_overflow;
        if (!waiting) first_pending = 0;
        else if (first_pending == 0) first_pending = now_seconds();
        // Settle a little once something's waiting to be said, but not for ever if it keeps coming.
        int ready = poll(fds, 2, heartbeat_wait(waiting ? 80 : -1));
        if (ready < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (fds[1].revents) {
            char sink[256];
            if (read(STDIN_FILENO, sink, sizeof sink) <= 0) return 0;
            heard();
        }
        if (mac_gone()) return 0;
        if (ready == 0 || (first_pending != 0 && now_seconds() - first_pending > 0.5)) {
            flush_changes();
            first_pending = 0;
            if (ferror(stdout)) return 0;
            if (ready == 0) continue;
        }
        if (!(fds[0].revents & POLLIN)) continue;
        ssize_t got = read(watcher, events, sizeof events);
        if (got <= 0) continue;
        for (char *cursor = events; cursor < events + got;) {
            struct inotify_event *event = (struct inotify_event *)cursor;
            cursor += sizeof *event + event->len;
            if (event->mask & IN_Q_OVERFLOW) {
                pending_overflow = 1;
                continue;
            }
            if (event->wd < 0 || event->wd >= watched_cap || !watched[event->wd]) continue;
            const char *directory = watched[event->wd];
            if (is_git_watch(directory)) {
                if (event->len && strcmp(event->name, "HEAD") == 0) git_moved = 1;
                continue;
            }
            if (event->mask & IN_IGNORED) {
                free(watched[event->wd]);
                watched[event->wd] = NULL;
                continue;
            }
            if (event->mask & IN_DELETE_SELF) continue;
            if (!event->len || excluded(event->name)) continue;
            int written = snprintf(path, sizeof path, "%s/%s", strcmp(directory, "/") == 0 ? "" : directory, event->name);
            if (written <= 0 || written >= (int)sizeof path) continue;
            note_change(path);
            if ((event->mask & (IN_CREATE | IN_MOVED_TO)) && (event->mask & IN_ISDIR)) {
                // Whatever arrived inside it before the watch took hold wouldn't be heard about.
                watch_tree(path);
                scan_left = 200000;
                scan_directory(path, 0);
                fflush(stdout);
            }
        }
    }
}

#else

static int run_watch(int argc, char **argv) {
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--heartbeat") == 0) heartbeat = 1;
    }
    heard();
    // No inotify here, so Tiri looks again every so often.
    printf("!limited");
    putchar(0);
    fflush(stdout);
    return drain_stdin_until_gone();
}

#endif

// MARK: write

// tiri-remote write <path> <size> [--if-modified <ms>]
// All of it or none of it: a connection that drops part-way ends stdin early, which is why the size is
// said up front. --if-modified leaves the file alone if it isn't the version the edit was made to,
// and exits 9, so a save that waited out a dropped connection can't silently replace newer work.
static int run_write(int argc, char **argv) {
    if (argc != 4 && argc != 6) return 64;
    long long size = atoll(argv[3]);
    if (size < 0) return 64;
    long long if_modified = -1;
    if (argc == 6) {
        if (strcmp(argv[4], "--if-modified") != 0) return 64;
        if_modified = atoll(argv[5]);
    }
    char target[8192];
    snprintf(target, sizeof target, "%s", argv[2]);
    // Write through a link, rather than replacing the link with a file.
    char resolved[4096];
    if (realpath(target, resolved)) snprintf(target, sizeof target, "%s", resolved);
    mode_t mode = 0644;
    struct stat info;
    int existed = stat(target, &info) == 0;
    if (existed) mode = info.st_mode & 07777;
    if (existed && if_modified > 0 && MTIME_MS(info) != if_modified) {
        fprintf(stderr, "changed on the server\n");
        return 9;
    }

    char temporary[8200];
    snprintf(temporary, sizeof temporary, "%s.tiri-XXXXXX", target);
    int fd = mkstemp(temporary);
    // Only a folder that won't take a new file, or a name with no room for the suffix, is a reason to
    // write over the old one in place. Any other failure, like a full disk, would leave it emptied.
    if (fd < 0 && errno != EACCES && errno != EPERM && errno != ENAMETOOLONG) {
        fprintf(stderr, "%s\n", strerror(errno));
        return 1;
    }
    int in_place = fd < 0;
    char *held = NULL;
    if (in_place) {
        // A folder we can't create in can still hold a file we can write to. Nothing's touched
        // until all of it has arrived.
        held = malloc(size ? (size_t)size : 1);
        if (!held) return 1;
    }
    char buffer[65536];
    long long have = 0;
    while (have < size) {
        size_t want = size - have < (long long)sizeof buffer ? (size_t)(size - have) : sizeof buffer;
        ssize_t got = read(STDIN_FILENO, buffer, want);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        if (in_place) {
            memcpy(held + have, buffer, (size_t)got);
        } else if (write_all(fd, buffer, (size_t)got) < 0) {
            fprintf(stderr, "%s\n", strerror(errno));
            unlink(temporary);
            return 1;
        }
        have += got;
    }
    if (have != size) {
        fprintf(stderr, "the connection dropped part-way, so the file wasn't changed\n");
        if (!in_place) unlink(temporary);
        return 1;
    }
    if (in_place) {
        fd = open(target, O_WRONLY | O_TRUNC | (existed ? 0 : O_CREAT), mode);
        if (fd < 0) {
            fprintf(stderr, "%s\n", strerror(errno));
            return 1;
        }
        if (write_all(fd, held, (size_t)size) < 0) {
            fprintf(stderr, "%s\n", strerror(errno));
            return 1;
        }
    } else {
        if (!existed) {
            mode_t mask = umask(0);
            umask(mask);
            mode = 0666 & ~mask;
        }
        fchmod(fd, mode);
    }
    if (fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP) {
        fprintf(stderr, "%s\n", strerror(errno));
        if (!in_place) unlink(temporary);
        return 1;
    }
    if (close(fd) != 0) {
        fprintf(stderr, "%s\n", strerror(errno));
        if (!in_place) unlink(temporary);
        return 1;
    }
    if (!in_place && rename(temporary, target) != 0) {
        fprintf(stderr, "%s\n", strerror(errno));
        unlink(temporary);
        return 1;
    }
    if (stat(target, &info) != 0) return 1;
    printf("%lld %lld\n", MTIME_MS(info), (long long)info.st_size);
    return 0;
}

// MARK: Where `tiri` commands arrive

// The socket `tiri` connects to on the server. Requests go to the Mac over this process's stdout and
// answers come back on its stdin, so it works over a plain SSH session, even on a server that
// forbids forwarding. It also says its pid first, because it lives exactly as long as the connection.
//   Out: "P <pid> 0\n"   "R <id> <length>\n" then the request
//        "S <now in ms> <length>\n" then what was spooled while the Mac couldn't be reached
//   In:  "A <id> <length>\n" then the answer   "K 0 0\n" the spool arrived   "\n" the heartbeat

#define RELAY_CLIENTS 64

typedef struct {
    int fd;
    unsigned id;
    char *data;
    size_t length;
    int sent;
} relay_client;

static int read_line_from(int fd, char *line, size_t room) {
    size_t used = 0;
    while (used + 1 < room) {
        ssize_t got = read(fd, line + used, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return -1;
        if (line[used] == '\n') break;
        used++;
    }
    line[used] = 0;
    return 0;
}

// MARK: The spool

// What an agent's hook says while the Mac is asleep or away would otherwise be lost. It waits in a
// file beside the socket, which the next relay sends on, and only this user can read.
#define SPOOL_LIMIT (1024 * 1024)

static long long now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int open_spool(const char *spool, int flags) {
    int fd = open(spool, flags | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()) {
        close(fd);
        return -1;
    }
    flock(fd, LOCK_EX);
    return fd;
}

// Keeps only what follows the first `count` bytes.
static void spool_drop_front(int fd, size_t count) {
    struct stat info;
    if (fstat(fd, &info) != 0) return;
    size_t size = (size_t)info.st_size;
    if (count >= size) {
        if (ftruncate(fd, 0) != 0) {}
        return;
    }
    size_t rest = size - count;
    char *kept = malloc(rest);
    if (!kept) return;
    if (pread(fd, kept, rest, (off_t)count) == (ssize_t)rest && pwrite(fd, kept, rest, 0) == (ssize_t)rest) {
        if (ftruncate(fd, (off_t)rest) != 0) {}
    }
    free(kept);
}

static void spool_request(const char *socket_path, const char *request, size_t length, long long stamped) {
    if (length > SPOOL_LIMIT / 4) return;
    char spool[4200];
    if (snprintf(spool, sizeof spool, "%s.spool", socket_path) >= (int)sizeof spool) return;
    int fd = open_spool(spool, O_RDWR | O_CREAT);
    if (fd < 0) return;
    fchmod(fd, 0600);
    struct stat info;
    if (fstat(fd, &info) == 0 && (size_t)info.st_size + length + 32 > SPOOL_LIMIT) {
        // Full: the oldest half goes, from a line's start. Only the newest of each terminal counts anyway.
        size_t size = (size_t)info.st_size;
        size_t cut = size - SPOOL_LIMIT / 2;
        char byte;
        while (cut < size && pread(fd, &byte, 1, (off_t)cut) == 1 && byte != '\n') cut++;
        spool_drop_front(fd, cut + 1);
    }
    char stamp[32];
    int stamp_length = snprintf(stamp, sizeof stamp, "%lld ", stamped);
    char *entry = malloc((size_t)stamp_length + length);
    if (entry) {
        memcpy(entry, stamp, (size_t)stamp_length);
        memcpy(entry + stamp_length, request, length);
        lseek(fd, 0, SEEK_END);
        write_all(fd, entry, (size_t)stamp_length + length);
        free(entry);
    }
    close(fd);
}

// This relay's own spool, and the shared one behind `control.sock` when that's now this relay.
static char spools[2][4200];
static size_t spool_sent[2];

static void send_spools(const char *path) {
    snprintf(spools[0], sizeof spools[0], "%s.spool", path);
    spools[1][0] = 0;
    const char *slash = strrchr(path, '/');
    if (slash) {
        char shared[4200], target[4096];
        snprintf(shared, sizeof shared, "%.*s/control.sock", (int)(slash - path), path);
        ssize_t got = readlink(shared, target, sizeof target - 1);
        if (got > 0) {
            target[got] = 0;
            if (strcmp(target, slash + 1) == 0 || strcmp(target, path) == 0) snprintf(spools[1], sizeof spools[1], "%s.spool", shared);
        }
    }
    char *all = NULL;
    size_t total = 0;
    for (int index = 0; index < 2; index++) {
        spool_sent[index] = 0;
        if (!spools[index][0]) continue;
        int fd = open_spool(spools[index], O_RDONLY);
        if (fd < 0) continue;
        struct stat info;
        if (fstat(fd, &info) == 0 && info.st_size > 0) {
            size_t size = (size_t)info.st_size > SPOOL_LIMIT ? SPOOL_LIMIT : (size_t)info.st_size;
            char *grown = realloc(all, total + size);
            if (grown) {
                all = grown;
                ssize_t got = pread(fd, all + total, size, 0);
                if (got > 0) {
                    // Whole lines only. A line still being written waits for the next time.
                    while (got > 0 && all[total + (size_t)got - 1] != '\n') got--;
                    total += (size_t)got;
                    spool_sent[index] = (size_t)got;
                }
            }
        }
        close(fd);
    }
    if (total) {
        printf("S %lld %zu\n", now_ms(), total);
        fwrite(all, 1, total, stdout);
        fflush(stdout);
    }
    free(all);
}

// The Mac has it, so it can go. Whatever was added since stays for next time.
static void spools_arrived(void) {
    for (int index = 0; index < 2; index++) {
        if (!spools[index][0] || !spool_sent[index]) continue;
        int fd = open_spool(spools[index], O_RDWR);
        if (fd < 0) continue;
        spool_drop_front(fd, spool_sent[index]);
        spool_sent[index] = 0;
        close(fd);
    }
}

static int run_relay_server(int argc, char **argv) {
    if (argc != 3 && !(argc == 4 && strcmp(argv[3], "--heartbeat") == 0)) return 64;
    heartbeat = argc == 4;
    heard();
    const char *path = argv[2];
    signal(SIGPIPE, SIG_IGN);
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof address.sun_path) return 64;
    strcpy(address.sun_path, path);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return 70;
    unlink(path);
    mode_t previous = umask(0077);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) < 0 || listen(listener, 32) < 0) return 70;
    umask(previous);
    // A relay from a dropped connection can linger for hours. It mustn't take the new one's socket with it.
    struct stat bound;
    ino_t bound_inode = stat(path, &bound) == 0 ? bound.st_ino : 0;
    printf("P %d 0\n", (int)getpid());
    fflush(stdout);
    send_spools(path);

    relay_client clients[RELAY_CLIENTS];
    for (int index = 0; index < RELAY_CLIENTS; index++) {
        clients[index].fd = -1;
        clients[index].data = NULL;
    }
    unsigned next_id = 1;
    for (;;) {
        struct pollfd fds[RELAY_CLIENTS + 2];
        int slots[RELAY_CLIENTS + 2];
        nfds_t count = 0;
        fds[count++] = (struct pollfd){STDIN_FILENO, POLLIN, 0};
        fds[count++] = (struct pollfd){listener, POLLIN, 0};
        for (int index = 0; index < RELAY_CLIENTS; index++) {
            // Once a request has gone, there's nothing more to hear from it but its leaving.
            if (clients[index].fd >= 0) {
                slots[count] = index;
                fds[count++] = (struct pollfd){clients[index].fd, POLLIN, 0};
            }
        }
        int ready = poll(fds, count, heartbeat_wait(-1));
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (mac_gone()) break;
        if (ready == 0) continue;
        if (fds[0].revents) {
            char line[128];
            if (read_line_from(STDIN_FILENO, line, sizeof line) < 0) break;
            heard();
            if (!line[0]) continue;
            if (line[0] == 'K') {
                spools_arrived();
                continue;
            }
            unsigned id = 0;
            unsigned long length = 0;
            if (sscanf(line, "A %u %lu", &id, &length) != 2) break;
            char *answer = malloc(length ? length : 1);
            if (!answer) break;
            size_t have = 0;
            while (have < length) {
                ssize_t got = read(STDIN_FILENO, answer + have, length - have);
                if (got < 0 && errno == EINTR) continue;
                if (got <= 0) { free(answer); goto done; }
                have += (size_t)got;
            }
            for (int index = 0; index < RELAY_CLIENTS; index++) {
                if (clients[index].fd >= 0 && clients[index].id == id) {
                    write_all(clients[index].fd, answer, length);
                    close(clients[index].fd);
                    clients[index].fd = -1;
                    free(clients[index].data);
                    clients[index].data = NULL;
                }
            }
            free(answer);
            continue;  // Client slots may have changed under the poll.
        }
        if (fds[1].revents & POLLIN) {
            int fresh = accept(listener, NULL, NULL);
            if (fresh >= 0) {
                int placed = 0;
                for (int index = 0; index < RELAY_CLIENTS && !placed; index++) {
                    if (clients[index].fd < 0) {
                        // An answer can't be written to a client that isn't reading, for ever.
                        struct timeval limit = {5, 0};
                        setsockopt(fresh, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof limit);
                        clients[index] = (relay_client){fresh, next_id++, NULL, 0, 0};
                        placed = 1;
                    }
                }
                if (!placed) close(fresh);
            }
        }
        for (nfds_t entry = 2; entry < count; entry++) {
            if (!fds[entry].revents) continue;
            relay_client *client = &clients[slots[entry]];
            char buffer[65536];
            ssize_t got = read(client->fd, buffer, sizeof buffer);
            if (got <= 0) {
                close(client->fd);
                client->fd = -1;
                free(client->data);
                client->data = NULL;
                continue;
            }
            if (client->sent) continue;
            char *grown = client->length + (size_t)got > 16 * 1024 * 1024 ? NULL : realloc(client->data, client->length + (size_t)got);
            if (!grown) {
                close(client->fd);
                client->fd = -1;
                free(client->data);
                client->data = NULL;
                continue;
            }
            client->data = grown;
            memcpy(client->data + client->length, buffer, (size_t)got);
            client->length += (size_t)got;
            if (memchr(client->data, '\n', client->length)) {
                printf("R %u %zu\n", client->id, client->length);
                fwrite(client->data, 1, client->length, stdout);
                if (fflush(stdout) != 0) goto done;
                client->sent = 1;
            }
        }
    }
done:
    if (stat(path, &bound) == 0 && bound.st_ino == bound_inode) unlink(path);
    return 0;
}

// MARK: The tiri relay

static void json_string(FILE *out, const char *text, size_t length) {
    fputc('"', out);
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)text[index];
        if (byte == '"' || byte == '\\') fprintf(out, "\\%c", byte);
        else if (byte == '\n') fputs("\\n", out);
        else if (byte == '\t') fputs("\\t", out);
        else if (byte == '\r') fputs("\\r", out);
        else if (byte < 0x20) fprintf(out, "\\u%04x", byte);
        else fputc(byte, out);
    }
    fputc('"', out);
}

static void json_field(FILE *out, const char *name, const char *value) {
    if (!value) return;
    fprintf(out, ",\"%s\":", name);
    json_string(out, value, strlen(value));
}

// The command lines above this process, nearest first. Words are joined with spaces, which is enough
// for telling which agent ran a hook and whether it was a one-shot.
static void write_ancestors(FILE *out) {
    fputs(",\"ancestors\":[", out);
    int pid = (int)getppid();
    for (int depth = 0; depth < 16 && pid > 1; depth++) {
        char line[4096] = "";
        size_t length = 0;
        int parent = 0;
#if defined(__linux__)
        char path[64];
        snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
            ssize_t got = read(fd, line, sizeof line - 1);
            close(fd);
            if (got > 0) {
                length = (size_t)got;
                while (length > 0 && line[length - 1] == 0) length--;
                for (size_t index = 0; index < length; index++) if (line[index] == 0) line[index] = ' ';
                line[length] = 0;
            }
        }
        snprintf(path, sizeof path, "/proc/%d/stat", pid);
        fd = open(path, O_RDONLY);
        if (fd >= 0) {
            char stat[1024];
            ssize_t got = read(fd, stat, sizeof stat - 1);
            close(fd);
            if (got > 0) {
                stat[got] = 0;
                // After the name in brackets, which can hold anything: state, then the parent.
                char *end = strrchr(stat, ')');
                if (end) sscanf(end + 1, " %*c %d", &parent);
            }
        }
#else
        char command[64];
        snprintf(command, sizeof command, "ps -o ppid=,command= -p %d", pid);
        FILE *pipe = popen(command, "r");
        if (pipe) {
            char row[4096];
            if (fgets(row, sizeof row, pipe)) {
                int skip = 0;
                if (sscanf(row, " %d %n", &parent, &skip) >= 1) {
                    snprintf(line, sizeof line, "%s", row + skip);
                    length = strcspn(line, "\n");
                    line[length] = 0;
                }
            }
            pclose(pipe);
        }
#endif
        if (depth) fputc(',', out);
        json_string(out, line, length);
        pid = parent;
    }
    fputc(']', out);
}

// argv[0] is `tiri`. Parsing happens on the Mac, in the one parser there is: this stays dumb on
// purpose, so a new command needs nothing new on any server.
static int run_relay(int argc, char **argv) {
    int quiet = argc > 1 && (strcmp(argv[1], "hook") == 0 || strcmp(argv[1], "notify") == 0);
    const char *socket_path = getenv("TIRI_SOCKET");
    char fallback[4096];
    if (!socket_path || !*socket_path) {
        const char *home = getenv("HOME");
        snprintf(fallback, sizeof fallback, "%s/.tiri/run/control.sock", home ? home : "");
        socket_path = fallback;
    }

    char *stdin_text = NULL;
    size_t stdin_length = 0;
    if (argc > 1 && strcmp(argv[1], "hook") == 0 && !isatty(STDIN_FILENO)) {
        size_t cap = 65536;
        stdin_text = malloc(cap);
        ssize_t got;
        while (stdin_text && (got = read(STDIN_FILENO, stdin_text + stdin_length, cap - stdin_length)) > 0) {
            stdin_length += (size_t)got;
            if (stdin_length == cap) {
                if (cap >= 8 * 1024 * 1024) break;
                cap *= 2;
                stdin_text = realloc(stdin_text, cap);
            }
        }
    }

    // When it happened, by this server's clock, live or spooled: the Mac compares the two to tell
    // what's newest, and a spooled report that something live has overtaken is left out.
    long long asked_at = now_ms();
    char *request = NULL;
    size_t request_length = 0;
    FILE *out = open_memstream(&request, &request_length);
    fputs("{\"argv\":[", out);
    for (int index = 1; index < argc; index++) {
        if (index > 1) fputc(',', out);
        json_string(out, argv[index], strlen(argv[index]));
    }
    fputc(']', out);
    fprintf(out, ",\"at\":%lld", asked_at);
    char directory[4096];
    if (getcwd(directory, sizeof directory)) json_field(out, "cwd", directory);
    json_field(out, "item", getenv("TIRI_ITEM_ID"));
    json_field(out, "workspace", getenv("TIRI_WORKSPACE"));
    json_field(out, "entrypoint", getenv("CLAUDE_CODE_ENTRYPOINT"));
    if (argc > 1 && strcmp(argv[1], "hook") == 0) write_ancestors(out);
    if (stdin_text) {
        fputs(",\"stdin\":", out);
        json_string(out, stdin_text, stdin_length);
    }
    fputs("}\n", out);
    fclose(out);

    // A hook that can't get through now is kept, and arrives when the Mac's back.
    int server = connect_to(socket_path);
    if (server < 0) {
        if (quiet) {
            spool_request(socket_path, request, request_length, asked_at);
            return 0;
        }
        fprintf(stderr, "tiri: this terminal isn't connected to Tiri right now.\n");
        return 1;
    }
    signal(SIGPIPE, SIG_IGN);
    if (write_all(server, request, request_length) < 0) {
        if (!quiet) return 1;
        spool_request(socket_path, request, request_length, asked_at);
        return 0;
    }

    struct timeval timeout = {quiet ? 5 : 60, 0};
    setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    // First line: the exit code. Then what to print, then what to complain about after a 0x1E.
    char buffer[65536];
    int code = -1;
    size_t have = 0;
    int in_error = 0;
    for (;;) {
        ssize_t got = read(server, buffer + have, sizeof buffer - have - 1);
        if (got <= 0) break;
        have += (size_t)got;
        buffer[have] = 0;
        char *body = buffer;
        size_t length = have;
        if (code < 0) {
            char *newline = strchr(buffer, '\n');
            if (!newline) continue;
            code = atoi(buffer);
            body = newline + 1;
            length = have - (size_t)(body - buffer);
        }
        char *split = in_error ? NULL : memchr(body, 0x1E, length);
        if (split) {
            write_all(STDOUT_FILENO, body, (size_t)(split - body));
            write_all(STDERR_FILENO, split + 1, length - (size_t)(split - body) - 1);
            in_error = 1;
        } else {
            write_all(in_error ? STDERR_FILENO : STDOUT_FILENO, body, length);
        }
        have = 0;
    }
    if (code < 0) {
        if (quiet) {
            // A relay whose Mac has gone quiet. If it did get there, the Mac keeps only the newest.
            spool_request(socket_path, request, request_length, asked_at);
            return 0;
        }
        fprintf(stderr, "tiri: Tiri didn't answer.\n");
        return 1;
    }
    return quiet ? 0 : code;
}

int main(int argc, char **argv) {
    const char *name = strrchr(argv[0], '/');
    name = name ? name + 1 : argv[0];
    if (strcmp(name, "tiri") == 0) return run_relay(argc, argv);
    if (argc >= 2) {
        if (strcmp(argv[1], "version") == 0) { puts(TIRI_REMOTE_VERSION); return 0; }
        if (strcmp(argv[1], "session") == 0) return tiri_session_main(argc - 1, argv + 1);
        if (strcmp(argv[1], "scan") == 0) return run_scan(argc, argv);
        if (strcmp(argv[1], "watch") == 0) return run_watch(argc, argv);
        if (strcmp(argv[1], "write") == 0) return run_write(argc, argv);
        if (strcmp(argv[1], "relay") == 0) return run_relay_server(argc, argv);
        if (strcmp(argv[1], "tiri") == 0) return run_relay(argc - 1, argv + 1);
    }
    fprintf(stderr, "tiri-remote is part of Tiri\n");
    return 64;
}
