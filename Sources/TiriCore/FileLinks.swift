import Foundation

/// A `tiri://` link to a file, the kind that error pages and dev tools make for "open in editor":
///   tiri://file/Users/me/app/src/main.ts:12:5      the way vscode:// links are written
///   tiri://open?file=/Users/me/app/main.ts&line=12&column=5   (`url=file://…` too, as TextMate's are)
public struct FileLink: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var col: Int?

    public init(path: String, line: Int? = nil, col: Int? = nil) {
        self.path = path
        self.line = line
        self.col = col
    }

    public static let scheme = "tiri"

    /// The file a link means, or nil if it isn't one of Tiri's. `exists` decides whether a `:12` at the end is
    /// part of the name: a file that's really called `notes:12` still opens.
    public init?(_ url: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch url.host(percentEncoded: false)?.lowercased() {
        case "file":
            let raw = components.percentEncodedPath.removingPercentEncoding ?? components.path
            guard raw.hasPrefix("/") else { return nil }
            self = Self.located(raw, exists: exists)
        case "open":
            let items = components.queryItems ?? []
            func value(_ names: String...) -> String? {
                items.first { names.contains($0.name.lowercased()) }?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            var path = value("file", "path")
            if path == nil, let address = value("url"), let fileURL = URL(string: address), fileURL.isFileURL {
                path = fileURL.path(percentEncoded: false)
            }
            guard let path, path.hasPrefix("/") else { return nil }
            var link = Self.located(path, exists: exists)
            if let line = value("line").flatMap(Int.init), line > 0 { link.line = line }
            if let col = value("column", "col").flatMap(Int.init), col > 0 { link.col = col }
            self = link
        default:
            return nil
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `/a/b.ts:12:5` → the file and where in it, unless the whole thing is a file's name.
    static func located(_ raw: String, exists: (String) -> Bool) -> FileLink {
        if exists(raw) { return FileLink(path: raw) }
        var parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let last = parts.last, let number = Int(last), number > 0 {
            numbers.insert(number, at: 0)
            parts.removeLast()
        }
        guard !numbers.isEmpty else { return FileLink(path: raw) }
        return FileLink(path: parts.joined(separator: ":"), line: numbers.first, col: numbers.count > 1 ? numbers[1] : nil)
    }
}
