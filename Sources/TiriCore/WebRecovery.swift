import Foundation

/// A page's web process died: crashed, or the system ended it. The first time it's started again.
/// A second time soon after says the page itself is the trouble, so it stops instead of looping.
public struct CrashRecovery: Sendable {
    /// Milliseconds within which a second crash isn't tried again.
    public static let window = 5000.0
    private var lastCrash: Double?

    public init() {}

    /// True to load the page again, false to show that it stopped. `now` is in milliseconds.
    public mutating func shouldReload(at now: Double) -> Bool {
        defer { lastCrash = now }
        guard let lastCrash else { return true }
        return now - lastCrash >= Self.window
    }
}

/// What a `Range` header asks of a file, for video and audio to seek in it.
public enum ByteRangeRequest: Equatable, Sendable {
    case whole
    case partial(Range<Int>)
    /// Starts past the end: answered with 416.
    case unsatisfiable

    /// One range only. Anything else, or anything malformed, gets the whole file, as servers do.
    public static func parse(_ header: String?, length: Int) -> ByteRangeRequest {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            // The last n bytes.
            guard let suffix = Int(last), suffix >= 0 else { return .whole }
            guard suffix > 0, length > 0 else { return .unsatisfiable }
            return .partial(max(0, length - suffix)..<length)
        }
        guard let start = Int(first), start >= 0 else { return .whole }
        guard start < length else { return .unsatisfiable }
        if last.isEmpty { return .partial(start..<length) }
        guard let end = Int(last), end >= start else { return .whole }
        return .partial(start..<min(end + 1, length))
    }
}

/// Whether a change in a local page's folder is one the page could show: the page itself, or
/// something it loaded. A folder full of dependencies and caches changes all the time otherwise.
public enum LocalPageChanges {
    /// All paths are real ones (no symlinks), as file events report them. `changed` holds what the
    /// watcher reported for this folder, which can be the folder itself or one above it when it
    /// lost track and everything inside has to be looked at again.
    public static func affect(page: String, folder: String, loaded: Set<String>, changed: [String], excluded: Set<String>) -> Bool {
        let inside = folder.hasSuffix("/") ? folder : folder + "/"
        for path in changed {
            // The folder itself or one above it: anything in it may have changed.
            if path == folder || inside.hasPrefix(path.hasSuffix("/") ? path : path + "/") { return true }
            guard path.hasPrefix(inside) else { continue }
            // What it loaded counts even from node_modules. Nothing else in there does.
            if path == page || loaded.contains(path) { return true }
            let relative = path.dropFirst(inside.count).split(separator: "/")
            if relative.contains(where: { excluded.contains(String($0)) }) { continue }
            // A folder holding something it loaded, renamed or looked at again as a whole.
            let asFolder = path + "/"
            if page.hasPrefix(asFolder) || loaded.contains(where: { $0.hasPrefix(asFolder) }) { return true }
        }
        // Told of a change without being told where: count it.
        return changed.isEmpty
    }
}
