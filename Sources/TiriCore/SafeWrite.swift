import Darwin
import Foundation

/// Saving a file someone opened, the way they'd expect it to be saved. A symlink stays a symlink and its
/// target gets the new text, a hard link stays linked, and the file keeps its mode, owner, ACL and extended
/// attributes. Where it can be, it's atomic and durable: a temporary file beside the target, flushed to the
/// disk itself, renamed over it, and the folder flushed too. Where it can't be, as for a hard link or a
/// writable file in a folder that isn't, it's written in place, and only once there's room for it.
/// VS Code refuses atomic writes through symlinks for the same reason (`canWriteFileAtomic`), and Zed
/// writes in place.
public enum SafeWrite {
    public enum Mode: Equatable, Sendable {
        case atomic, inPlace, created
    }

    /// Writes `data` to `path`, and says how.
    @discardableResult
    public static func write(_ data: Data, to path: String) throws -> Mode {
        let target = try resolvingSymlinks(path)
        var info = stat()
        guard stat(target, &info) == 0 else {
            guard errno == ENOENT else { throw failure(errno, target) }
            try create(data, at: target)
            return .created
        }
        let folder = (target as NSString).deletingLastPathComponent
        let isRegular = (info.st_mode & S_IFMT) == S_IFREG
        let folderWritable = access(folder.isEmpty ? "." : folder, W_OK) == 0
        if !isRegular || info.st_nlink > 1 || (!folderWritable && access(target, W_OK) == 0) {
            try writeInPlace(data, at: target, size: Int64(info.st_size))
            return .inPlace
        }
        try writeAtomically(data, at: target, folder: folder, info: info)
        return .atomic
    }

    /// Where a symlink in the last part of the path leads, followed as far as it goes. Folders on the
    /// way are left as they are: the rename happens in the target's own folder either way.
    static func resolvingSymlinks(_ path: String) throws -> String {
        var current = path
        for _ in 0..<32 {
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(current, &buffer, Int(PATH_MAX))
            guard count >= 0 else { throw failure(errno, current) }
            let destination = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current = destination.hasPrefix("/") ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        throw failure(ELOOP, path)
    }

    private static func create(_ data: Data, at target: String) throws {
        // The mode the umask allows, as any new file gets.
        let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw failure(errno, target) }
        do {
            try writeAll(data, to: fd, path: target)
            flush(fd)
            close(fd)
        } catch {
            close(fd)
            unlink(target)
            throw error
        }
        flushFolder(of: target)
    }

    private static func writeInPlace(_ data: Data, at target: String, size: Int64) throws {
        // Truncating first and running out of room part way would leave the file cut short.
        var volume = statfs()
        if statfs(target, &volume) == 0 {
            let free = Int64(volume.f_bavail) * Int64(volume.f_bsize)
            let more = Int64(data.count) - size
            if more > 0, free < more + 64 * 1024 { throw failure(ENOSPC, target) }
        }
        let fd = open(target, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno, target) }
        defer { close(fd) }
        try writeAll(data, to: fd, path: target)
        var info = stat()
        if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, ftruncate(fd, off_t(data.count)) != 0 {
            throw failure(errno, target)
        }
        flush(fd)
    }

    private static func writeAtomically(_ data: Data, at target: String, folder: String, info: stat) throws {
        let name = (target as NSString).lastPathComponent
        var template = Array(((folder as NSString).appendingPathComponent(".\(name).tiri-XXXXXX")).utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw failure(errno, target) }
        let temporary = String(cString: template)
        do {
            // Mode, owner where allowed, ACL and extended attributes, before any of the new bytes.
            _ = copyfile(target, temporary, nil, copyfile_flags_t(COPYFILE_METADATA))
            _ = fchown(fd, info.st_uid, info.st_gid)
            if fchmod(fd, info.st_mode & 0o7777) != 0 { throw failure(errno, target) }
            try writeAll(data, to: fd, path: target)
            // Copying the metadata copied the old times too, and the file has just changed.
            _ = futimes(fd, nil)
            flush(fd)
            close(fd)
        } catch {
            close(fd)
            unlink(temporary)
            throw error
        }
        guard rename(temporary, target) == 0 else {
            let code = errno
            unlink(temporary)
            throw failure(code, target)
        }
        flushFolder(of: target)
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let wrote = Darwin.write(fd, base + offset, buffer.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw failure(errno, path)
                }
                offset += wrote
            }
        }
    }

    /// To the disk itself, not only its cache: a plain fsync on a Mac stops at the drive's cache.
    private static func flush(_ fd: Int32) {
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    /// So the rename, or the new name, survives a power cut too.
    private static func flushFolder(of path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        let fd = open(folder.isEmpty ? "." : folder, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    /// The error Foundation would give, so it reads as "You don't have permission to save…".
    private static func failure(_ code: Int32, _ path: String) -> Error {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        let kind: CocoaError.Code = switch code {
        case EACCES, EPERM: .fileWriteNoPermission
        case ENOSPC, EDQUOT: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        case ENOENT: .fileNoSuchFile
        default: .fileWriteUnknown
        }
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: underlying])
    }
}
