import CryptoKit
import Foundation

// MARK: - What Tiri holds of a remote folder

/// A remote folder appears on this Mac as a sparse copy, under one local folder per server: the
/// real folders, and each file as an empty placeholder with its real date, until someone opens it.
/// So the tree, quick open, ⌘-click, file watching and every viewer work on a remote folder the way
/// they work on a local one. Only what changes a file, runs a program or reads contents across
/// the project goes over SSH. See RemoteConnection.
public enum RemoteMirror {
    /// `.noindex` keeps Spotlight out. Caches, because all of it can be fetched again.
    public static var root: String {
        if let override = ProcessInfo.processInfo.environment["TIRI_HOME"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("Remote.noindex")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Library/Caches"
        return caches + "/Tiri/Remote.noindex"
    }

    /// A folder name for a server. Readable, because it shows up in paths when debugging.
    public static func key(for destination: String) -> String {
        let plain = destination.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." || scalar == "_" ? String(scalar) : "_"
        }.joined()
        if plain == destination { return plain }
        let hash = SHA256.hash(data: Data(destination.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return plain + "-" + hash
    }

    public static func localRoot(of destination: String) -> String {
        (root as NSString).appendingPathComponent(key(for: destination))
    }
}

/// Between a path on the server and where it sits on this Mac.
public struct RemotePathMap: Sendable, Hashable {
    public var destination: String
    public var localRoot: String

    public init(destination: String, localRoot: String? = nil) {
        self.destination = destination
        self.localRoot = localRoot ?? RemoteMirror.localRoot(of: destination)
    }

    /// Whether a path steps out of where it says it is. A server can name anything, and `..` in a
    /// path it names must never reach outside its own local folder.
    public static func climbs(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".." || $0 == "." }
    }

    /// `.` and `..` worked out from the text alone. Foundation's own versions also look at the disk
    /// and change `/private/tmp` to `/tmp`, which would make a path look like it's somewhere else.
    public static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The local path of a path on the server. Always inside `localRoot`, whatever the server says.
    public func local(_ remote: String) -> String {
        let parts = remote.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != ".." && $0 != "." }
        return parts.isEmpty ? localRoot : localRoot + "/" + parts.joined(separator: "/")
    }

    /// The path on the server of a local path, or nil if it isn't this server's.
    public func remote(_ local: String) -> String? {
        if local == localRoot { return "/" }
        guard local.hasPrefix(localRoot + "/"), !Self.climbs(local) else { return nil }
        return String(local.dropFirst(localRoot.count))
    }

    public func contains(_ local: String) -> Bool {
        (local == localRoot || local.hasPrefix(localRoot + "/")) && !Self.climbs(local)
    }

    /// Paths inside text, such as what a command printed. Only whole mirror roots are replaced.
    public func remoteText(_ text: String) -> String {
        text.replacingOccurrences(of: localRoot + "/", with: "/")
    }
}

// MARK: - Listings

public struct RemoteRecord: Equatable, Sendable {
    public enum Kind: Character, Sendable {
        case folder = "d"
        case file = "f"
        case fileLink = "l"
        case folderLink = "L"
        case brokenLink = "?"
        case gone = "-"
    }

    public var kind: Kind
    public var modified: Int64
    /// -1 when the server can't say, as with a plain `find`.
    public var size: Int64
    public var path: String

    public init(kind: Kind, modified: Int64, size: Int64, path: String) {
        self.kind = kind
        self.modified = modified
        self.size = size
        self.path = path
    }

    public var isFolder: Bool { kind == .folder || kind == .folderLink }
}

/// Reads what `tiri-remote scan` and `watch` say: NUL-terminated records, plus signals like `!ready`.
public struct RemoteRecordReader: Sendable {
    public enum Event: Equatable, Sendable {
        case record(RemoteRecord)
        case signal(String)
    }

    private var pending = Data()

    public init() {}

    /// Everything complete so far. What's left waits for the next chunk.
    public mutating func read(_ chunk: Data) -> [Event] {
        pending.append(chunk)
        var events: [Event] = []
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 0) {
            if let event = Self.parse(pending[start..<end]) { events.append(event) }
            start = pending.index(after: end)
        }
        pending = Data(pending[start...])
        // No record is this long. Whatever this is, it doesn't get to fill the memory.
        if pending.count > 1_048_576 { pending = Data() }
        return events
    }

    static func parse(_ bytes: Data) -> Event? {
        guard let first = bytes.first else { return nil }
        if first == UInt8(ascii: "!") { return .signal(String(decoding: bytes.dropFirst(), as: UTF8.self)) }
        let parts = bytes.split(separator: 9, maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let letter = parts[0].first, parts[0].count == 1,
              let kind = RemoteRecord.Kind(rawValue: Character(UnicodeScalar(letter))),
              let modified = Int64(String(decoding: parts[1], as: UTF8.self)),
              let size = Int64(String(decoding: parts[2], as: UTF8.self)),
              !parts[3].isEmpty else { return nil }
        let path = String(decoding: parts[3], as: UTF8.self)
        // A server's say-so only ever covers its own absolute paths.
        guard path.hasPrefix("/"), !RemotePathMap.climbs(path) else { return nil }
        return .record(RemoteRecord(kind: kind, modified: modified, size: size, path: path))
    }
}

// MARK: - Hosts the user already has

/// The hosts in `~/.ssh/config`, as Cursor's Connect to Host lists them. Nothing here is Tiri's own:
/// keys, jump hosts and everything else stay with OpenSSH, which runs every connection.
public enum SSHConfigFile {
    public struct Host: Equatable, Sendable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var detail: String? {
            guard let hostName, hostName != alias else { return user.map { String(localized: "as \($0)") } }
            return user.map { "\($0)@\(hostName)" } ?? hostName
        }
    }

    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["TIRI_SSH_CONFIG"] ?? NSHomeDirectory() + "/.ssh/config"
    }

    public static func hosts(at path: String = defaultPath) -> [Host] {
        var visited = Set<String>()
        var found: [Host] = []
        read(path, visited: &visited, found: &found)
        var seen = Set<String>()
        return found.filter { seen.insert($0.alias).inserted }
    }

    private static func read(_ path: String, visited: inout Set<String>, found: inout [Host]) {
        guard visited.insert(path).inserted, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        found += parse(text) { included in
            var nested: [Host] = []
            for file in expand(included, relativeTo: (path as NSString).deletingLastPathComponent) {
                read(file, visited: &visited, found: &nested)
            }
            return nested
        }
    }

    /// `Include` paths can be relative and hold wildcards.
    private static func expand(_ pattern: String, relativeTo directory: String) -> [String] {
        var full = (pattern as NSString).expandingTildeInPath
        if !full.hasPrefix("/") { full = NSHomeDirectory() + "/.ssh/" + full }
        var results = glob_t()
        defer { globfree(&results) }
        guard glob(full, 0, nil, &results) == 0 else { return [] }
        return (0..<Int(results.gl_pathc)).compactMap { results.gl_pathv[$0].map { String(cString: $0) } }
    }

    public static func parse(_ text: String, including: (String) -> [Host] = { _ in [] }) -> [Host] {
        var hosts: [Host] = []
        var open: [Int] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch parts[0].lowercased() {
            case "host":
                open = []
                for name in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    // A pattern isn't somewhere you can go.
                    if name.contains("*") || name.contains("?") || name.hasPrefix("!") { continue }
                    hosts.append(Host(alias: String(name)))
                    open.append(hosts.count - 1)
                }
            case "match":
                open = []
            case "hostname":
                for index in open where hosts[index].hostName == nil { hosts[index].hostName = value }
            case "user":
                for index in open where hosts[index].user == nil { hosts[index].user = value }
            case "include":
                open = []
                for pattern in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    hosts += including(String(pattern))
                }
            default:
                break
            }
        }
        return hosts
    }

    /// What someone typed, as something `ssh` understands: `gpu`, `me@gpu`, `ssh -p 2222 me@gpu`, or
    /// `me@gpu:2222`. Nil when it can't be a place, so nothing odd reaches a command line.
    public static func destination(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ssh ") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        var port: String?
        let words = text.split(separator: " ").map(String.init)
        var host: String?
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "-p", index + 1 < words.count {
                port = words[index + 1]
                index += 2
            } else if word.hasPrefix("-") {
                return nil
            } else if host == nil {
                host = word
                index += 1
            } else {
                return nil
            }
        }
        guard var host, !host.isEmpty else { return nil }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if host.hasSuffix("/") { host.removeLast() }
        // Would be taken as an option, or as a folder name that climbs.
        guard !host.isEmpty, !host.hasPrefix("-"), host != ".", host != ".." else { return nil }
        if port == nil, let colon = host.lastIndex(of: ":"), !host.contains("[") {
            let after = host[host.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                port = String(after)
                host = String(host[..<colon])
            }
        }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || "@.-_:[]%".contains($0) }) else { return nil }
        if let port {
            guard port.allSatisfy(\.isNumber) else { return nil }
            return "ssh://\(host):\(port)"
        }
        return host
    }

    /// What a Chinese or Japanese input method makes of the punctuation in a path or host.
    public static func halfWidth(_ text: String) -> String {
        var out = text
        for (wide, plain) in [("～", "~"), ("／", "/"), ("。", "."), ("．", "."), ("：", ":"), ("＠", "@"), ("－", "-"), ("＿", "_"), ("、", "/")] {
            out = out.replacingOccurrences(of: wide, with: plain)
        }
        return out
    }

    /// Short name for a destination, for the workspace list.
    public static func displayName(of destination: String) -> String {
        var text = destination
        if text.hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        return text
    }
}

// MARK: - Speaking to `sh` on the other side

public enum RemoteShell {
    /// Whatever the user's login shell is, the script runs in `sh`. It travels encoded, because ssh
    /// hands it to that shell first, and fish and tcsh don't read quotes the way `sh` does. A file
    /// named to break out of the quotes would otherwise run on the server, as you.
    public static func wrap(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "sh -c 'eval \"$(printf %s \(encoded) | base64 -d 2>/dev/null || printf %s \(encoded) | base64 -D)\"'"
    }

    /// A path in double quotes, where `$HOME` still expands. Paths from Tiri are absolute anyway.
    public static func arguments(_ words: [String]) -> String {
        words.map(ShellQuote.quote).joined(separator: " ")
    }
}
