import CryptoKit
import Foundation
import TiriCore

/// Where a terminal's background session lives. See Sources/tiri-session/main.c.
enum TerminalSessions {
    /// Socket paths are short by law, so this hashes which Tiri it belongs to.
    /// A test instance's sessions never mix with yours.
    /// Worked out once: every terminal asks for it several times a second.
    static let directory: String = {
        let identity = TiriPaths.supportDirectory.path
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "/tmp/tiri-\(getuid())-\(digest)"
    }()

    static func socketPath(for item: ItemID) -> String { directory + "/" + item + ".sock" }

    static var helper: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri-session").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func prepareDirectory() {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private static func connect(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        CloseOnExec.mark(fd)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether a program is still running for this item. A socket left behind says nothing. Its files are
    /// removed only once its server is certainly gone: removing a live one's socket strands its program.
    static func isAlive(_ item: ItemID) -> Bool {
        let path = socketPath(for: item)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Asking the socket would count as attaching, which replaces whoever's attached. So the pids
        // answer when they can, the way `tiri-session alive` does.
        var state = serverState(path)
        if state == nil {
            state = connectRefused(path).map { !$0 }
        }
        if state == false {
            for suffix in ["", ".pid", ".server"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        return state != false
    }

    /// What the relay exits with when the server hung up without saying the program ended.
    static let lostExitCode: Int32 = 254

    static func shellPID(for item: ItemID) -> pid_t? {
        readPID(socketPath(for: item) + ".pid")
    }

    private static func readPID(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        return pid
    }

    /// True for a server that's there, false for one that's certainly gone, nil when the pids can't say.
    /// A server from before `.server` was written is its program's parent.
    private static func serverState(_ path: String) -> Bool? {
        if let server = readPID(path + ".server") { return isSessionProcess(server) }
        guard let program = readPID(path + ".pid") else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(program, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // The program outlived its server.
        if info.pbi_ppid == 1 { return false }
        return isSessionProcess(pid_t(info.pbi_ppid)) == true ? true : nil
    }

    /// Alive, and a session server rather than whatever was given the number after it ended.
    private static func isSessionProcess(_ pid: pid_t) -> Bool? {
        if kill(pid, 0) != 0, errno == ESRCH { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name).hasPrefix("tiri-")
    }

    /// Whether nothing is listening on the socket: true only when connecting proves it. Connecting to
    /// one that's there counts as attaching, so this is the last resort.
    private static func connectRefused(_ path: String) -> Bool? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return false }
        return errno == ECONNREFUSED || errno == ENOENT ? true : nil
    }

    /// Ends the program, because its terminal was closed on purpose.
    static func end(_ item: ItemID) {
        guard let fd = connect(socketPath(for: item)) else { return }
        // Connecting replays old output to us, and the server won't read this until that's sent.
        // So it's read and thrown away, off the main thread, until the server hangs up.
        var frame: [UInt8] = [UInt8(ascii: "K"), 0, 0]
        _ = write(fd, &frame, 3)
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while read(fd, &buffer, buffer.count) > 0 {}
            close(fd)
        }
    }

    struct Orphan {
        var id: ItemID
        var cwd: String?
        /// What it was started with, if it wasn't a plain shell.
        var command: String?
    }

    /// Programs still running whose tabs aren't in the saved state: a crash came between opening one and
    /// saving, or the state was damaged. Closing a tab ends its program, so none of these was closed.
    static func orphans(except keep: Set<ItemID>) -> [Orphan] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) }.sorted()
            .filter { !keep.contains($0) && isAlive($0) }
            .map { id in
                guard let pid = shellPID(for: id) else { return Orphan(id: id) }
                return Orphan(id: id, cwd: directory(of: pid), command: command(of: pid))
            }
    }

    private static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// `shell -l -i -c <command>` for a terminal started with a command, `-shell` for a plain one.
    private static func command(of pid: pid_t) -> String? {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&request, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        // The executable's path, then the arguments, split by NULs.
        let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
            .dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) }
        guard let flag = parts.firstIndex(of: "-c"), flag + 1 < parts.count else { return nil }
        return parts[flag + 1]
    }

    /// The process group in the foreground of the session's terminal.
    static func foregroundGroup(of shell: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shell]
        guard sysctl(&request, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let group = info.kp_eproc.e_tpgid
        return group > 0 ? group : nil
    }
}
