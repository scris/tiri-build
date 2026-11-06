import Foundation

/// Reading and writing files that belong to someone else, like an agent's settings, which can be a
/// link into a dotfiles folder and can hold API keys. A link stays a link, a file keeps its mode,
/// and nothing is ever readable by others, not even for a moment.
public enum SafeFile {
    public enum Failure: Error, CustomStringConvertible {
        case notUTF8(String)
        case system(String, String, Int32)

        public var description: String {
            switch self {
            case .notUTF8(let path): String(localized: "\(path) isn't UTF-8 text, so Tiri left it alone.")
            case .system(let call, let path, let code): "\(call) \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// The file's text, or nil if there's no file. Anything else that goes wrong is an error, never
    /// an empty file, or a write would replace what couldn't be read.
    public static func readText(_ url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
        guard let text = String(validating: data, as: UTF8.self) else { throw Failure.notUTF8(url.path) }
        return text
    }

    /// Where a link ends up, so writing there leaves the link in place. A path that isn't a link
    /// comes back as it is, and so does one that loops.
    public static func resolvingLinks(_ url: URL) -> URL {
        var path = url.path
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return URL(fileURLWithPath: path) }
            path = destination.hasPrefix("/") ? destination : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            path = (path as NSString).standardizingPath
        }
        return url
    }

    /// Replaces the file a path leads to, through any links, all at once: a new file beside it with
    /// the old one's mode (or `newMode` if there wasn't one) from its first byte, renamed over it.
    /// `forcing` gives it that mode whatever it had, and without `followingLinks` a link is replaced.
    public static func replace(_ url: URL, with data: Data, newMode: mode_t = 0o600, forcing forced: mode_t? = nil, followingLinks: Bool = true) throws {
        let target = followingLinks ? resolvingLinks(url) : url
        var info = stat()
        let mode = forced ?? (stat(target.path, &info) == 0 ? info.st_mode & 0o7777 : newMode)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tiri-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try writeNew(data, to: temporary, mode: mode)
        guard rename(temporary.path, target.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw Failure.system("rename", target.path, code)
        }
    }

    /// A copy of what was there before Tiri changed it, as a private regular file. Only the first
    /// one is kept: a later change would otherwise replace the original with Tiri's own edit.
    @discardableResult
    public static func keepFirstCopy(_ data: Data, at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        do {
            try writeNew(data, to: url, mode: 0o600)
        } catch Failure.system(_, _, EEXIST) {
            return false
        }
        return true
    }

    /// A folder only its owner can open: made that way, or, if it's already there and this user's,
    /// with everyone else's access taken off. A link is left alone.
    public static func makePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(url.path, 0o700)
            return
        }
        if info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 != 0 {
            chmod(url.path, info.st_mode & 0o700)
        }
    }

    /// Creates a file that mustn't exist yet, never through a link, with exactly this mode.
    public static func writeNew(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure.system("open", url.path, errno) }
        var failure: Int32 = 0
        // The umask may have taken bits off, and the mode has to be what was asked.
        if fchmod(fd, mode) != 0 { failure = errno }
        if failure == 0 {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        failure = errno
                        return
                    }
                    offset += written
                }
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        guard failure == 0 else {
            unlink(url.path)
            throw Failure.system("write", url.path, failure)
        }
    }

    /// The `sh` for a server that writes stdin to `"$HOME"/<path>` the same way: through links,
    /// keeping the file's mode, private while it's written, and a first copy kept beside it.
    public static func remoteReplaceScript(homeRelativePath path: String) -> String {
        let quoted = "\"$HOME\"/" + ShellQuote.quote(path)
        return """
        f=\(quoted)
        mkdir -p "$(dirname -- "$f")" || exit 1
        t=$(readlink -f -- "$f" 2>/dev/null) || t=
        if [ -z "$t" ]; then
          t=$f; n=0
          while [ -L "$t" ] && [ "$n" -lt 32 ]; do
            l=$(readlink -- "$t") || exit 1
            case $l in /*) t=$l ;; *) t=$(dirname -- "$t")/$l ;; esac
            n=$((n + 1))
          done
        fi
        umask 077
        if [ -e "$f" ] && [ ! -e "$f.tiri-backup" ] && [ ! -L "$f.tiri-backup" ]; then
          cat -- "$f" > "$f.tiri-backup" || exit 1
        fi
        tmp="$t.tiri-new.$$"
        rm -f -- "$tmp"
        (set -C; cat > "$tmp") || { rm -f -- "$tmp"; exit 1; }
        if [ -e "$t" ]; then
          chmod --reference="$t" -- "$tmp" 2>/dev/null || chmod "$(stat -c %a -- "$t" 2>/dev/null || stat -f %Lp -- "$t")" "$tmp" 2>/dev/null || true
        fi
        mv -f -- "$tmp" "$t" || { rm -f -- "$tmp"; exit 1; }
        """
    }
}
