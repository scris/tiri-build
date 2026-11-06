import Foundation

/// A file written so that a crash, a power cut or a full disk leaves either the old contents or the new, and the new
/// ones are on the disk itself, not in its cache, by the time this returns. `.atomic` alone only does the first half:
/// macOS can hold a renamed file's data in memory or in the drive's cache for a while after.
///
/// A link is written through: the file it points to is what changes, beside itself, and the link stays a link.
/// The file keeps its permissions.
public enum DurableFile {
    public struct Failure: Error, CustomStringConvertible {
        public var call: String
        public var code: Int32
        public var path: String
        public var description: String { "\(call) \(path): \(String(cString: strerror(code)))" }
    }

    public static func write(_ data: Data, to url: URL, permissions: mode_t? = nil) throws {
        let target = resolved(url)
        let folder = target.deletingLastPathComponent()
        let existing = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        let mode = permissions ?? existing.map { mode_t($0.uint16Value) } ?? 0o644
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure(call: "open", code: errno, path: temporary.path) }
        var finished = false
        defer {
            if !finished { unlink(temporary.path) }
        }
        do {
            defer { close(fd) }
            // The mode given to open is cut down by the umask, and the old file's should come through whole.
            fchmod(fd, mode)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Foundation.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Failure(call: "write", code: errno, path: temporary.path)
                    }
                    offset += written
                }
            }
            // To the disk itself. Some disks, like network ones, can't, and fsync is the most they offer.
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                throw Failure(call: "fsync", code: errno, path: temporary.path)
            }
        }
        guard rename(temporary.path, target.path) == 0 else { throw Failure(call: "rename", code: errno, path: target.path) }
        finished = true
        // The rename lives in the folder. The data is already safe, so the worst a crash now does is leave the old file.
        let folderFD = open(folder.path, O_RDONLY | O_CLOEXEC)
        if folderFD >= 0 {
            fsync(folderFD)
            close(folderFD)
        }
    }

    public static func write(_ text: String, to url: URL, permissions: mode_t? = nil) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
    }

    /// Where a write to this path really lands: through any links, to the file at the end of them.
    public static func resolved(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return current }
            current = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
            current = current.standardizedFileURL
        }
        return current
    }
}

/// Durable writes that skip a file whose contents haven't changed since this wrote it, because each costs the disk a
/// flush of its cache, and most saves change one file of many.
final class WrittenFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: Data] = [:]

    func write(_ data: Data, to url: URL) throws {
        let key = url.standardizedFileURL.path
        if lock.withLock({ last[key] == data }), FileManager.default.fileExists(atPath: key) { return }
        try DurableFile.write(data, to: url)
        lock.withLock { last[key] = data }
    }
}
