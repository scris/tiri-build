import CryptoKit
import Foundation
import TiriCore

/// Where a terminal's background session lives. See Sources/tiri-session/main.c.
enum TerminalSessions {
    /// Socket paths are short by law, so this hashes which Tiri it belongs to.
    /// A test instance's sessions never mix with yours.
    static var directory: String {
        let identity = TiriPaths.supportDirectory.path
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "/tmp/tiri-\(getuid())-\(digest)"
    }

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

    /// Whether a program is still running for this item. A socket left behind says nothing.
    static func isAlive(_ item: ItemID) -> Bool {
        let path = socketPath(for: item)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Asking the socket would count as attaching, which replaces whoever's attached.
        guard let pid = shellPID(for: item), kill(pid, 0) == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".pid")
            return false
        }
        return true
    }

    static func shellPID(for item: ItemID) -> pid_t? {
        guard let text = try? String(contentsOfFile: socketPath(for: item) + ".pid", encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Sessions whose tabs no longer exist have nothing to come back to.
    static func endAll(except keep: Set<ItemID>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for file in files where file.hasSuffix(".sock") {
            let item = String(file.dropLast(5))
            if !keep.contains(item) { end(item) }
        }
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
