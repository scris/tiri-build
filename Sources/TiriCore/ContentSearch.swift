import Foundation

public struct ContentMatch: Sendable, Equatable, Identifiable {
    public var path: String
    public var line: Int
    public var column: Int
    /// The line, trimmed and cut to a readable length.
    public var text: String
    /// Where the match is in `text`, in UTF-8 bytes.
    public var matchOffset: Int
    public var matchLength: Int
    public var id: String { "\(path):\(line):\(column)" }
}

/// Search across files. Lowercase queries ignore case, and one with a capital means it,
/// the way Cursor's smart case does.
public enum ContentSearch {
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let maximumMatches = 500

    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public init() {}
        public func cancel() { lock.withLock { cancelled = true } }
        public var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// Finds matches in one file's bytes. Binary files have none.
    public static func matches(in data: Data, path: String, query: String, limit: Int = 200) -> [ContentMatch] {
        let needle = Array(query.utf8)
        guard !needle.isEmpty, data.count >= needle.count else { return [] }
        // A NUL early on means this isn't text.
        if data.prefix(8192).contains(0) { return [] }
        let ignoreCase = query == query.lowercased()
        var results: [ContentMatch] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var lineStart = 0
            var lineNumber = 1
            var index = 0
            var lastMatchedLine = 0
            let first = needle[0]
            let firstFolded = fold(first)
            while index + needle.count <= count {
                let byte = bytes[index]
                if byte == 10 {
                    lineStart = index + 1
                    lineNumber += 1
                    index += 1
                    continue
                }
                if byte == first || (ignoreCase && fold(byte) == firstFolded) {
                    var offset = 1
                    while offset < needle.count {
                        let candidate = bytes[index + offset]
                        if candidate != needle[offset], !(ignoreCase && fold(candidate) == needle[offset]) { break }
                        offset += 1
                    }
                    if offset == needle.count, lineNumber != lastMatchedLine {
                        lastMatchedLine = lineNumber
                        var lineEnd = index + needle.count
                        while lineEnd < count, bytes[lineEnd] != 10 { lineEnd += 1 }
                        results.append(make(bytes: bytes, lineStart: lineStart, lineEnd: lineEnd, matchStart: index, length: needle.count,
                                            path: path, line: lineNumber))
                        if results.count >= limit { return }
                    }
                }
                index += 1
            }
        }
        return results
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private static func make(bytes: UnsafeBufferPointer<UInt8>, lineStart: Int, lineEnd: Int, matchStart: Int, length: Int,
                             path: String, line: Int) -> ContentMatch {
        var start = lineStart
        while start < matchStart, bytes[start] == 32 || bytes[start] == 9 { start += 1 }
        // Long lines keep some context in front of the match.
        if matchStart - start > 60 {
            start = matchStart - 60
            while start < matchStart, bytes[start] & 0xC0 == 0x80 { start += 1 }
        }
        var end = lineEnd
        if end - start > 220 {
            end = start + 220
            while end > matchStart + length, end < lineEnd, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        }
        while end > start, bytes[end - 1] == 13 { end -= 1 }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        let column = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<matchStart]), as: UTF8.self).count + 1
        return ContentMatch(path: path, line: line, column: column, text: text, matchOffset: matchStart - start, matchLength: length)
    }

    private final class Remaining: @unchecked Sendable {
        private let lock = NSLock()
        private var room: Int
        init(_ room: Int) { self.room = room }

        /// How many of `count` still fit.
        func take(_ count: Int) -> Int {
            lock.withLock {
                let allowed = min(room, count)
                room -= allowed
                return allowed
            }
        }
    }

    /// Searches files in parallel. `found` gets each batch as it's ready, from any thread.
    public static func run(paths: [String], query: String, cancellation: Cancellation,
                           found: @escaping @Sendable ([ContentMatch]) -> Void) {
        guard !query.isEmpty, !paths.isEmpty else { return }
        let remaining = Remaining(maximumMatches)
        let chunk = 64
        let chunks = stride(from: 0, to: paths.count, by: chunk).map { Array(paths[$0..<min($0 + chunk, paths.count)]) }
        DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
            var batch: [ContentMatch] = []
            for path in chunks[index] {
                if cancellation.isCancelled { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      (attributes[.size] as? Int ?? 0) <= maximumFileBytes,
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { continue }
                batch.append(contentsOf: matches(in: data, path: path, query: query))
            }
            guard !batch.isEmpty, !cancellation.isCancelled else { return }
            let allowed = remaining.take(batch.count)
            if allowed > 0 { found(Array(batch.prefix(allowed))) }
            if allowed < batch.count { cancellation.cancel() }
        }
    }
}

/// Search on a server, where the contents are. `git grep` leaves out what .gitignore does, as
/// searching here does, and `grep` covers a folder that isn't a repository.
public enum RemoteSearch {
    static func script(folder: String, query: String, caseSensitive: Bool, excludes: [String], listOnly: Bool, wholeWord: Bool = false) -> String {
        let flags = (caseSensitive ? "" : " -i") + (wholeWord ? " -w" : "") + (listOnly ? " -l" : " -n")
        let quoted = ShellQuote.quote(query)
        let skips = excludes.filter { !$0.contains("/") && !$0.contains("*") }.map { " --exclude-dir=\(ShellQuote.quote($0))" }.joined()
        return """
        cd \(ShellQuote.quote(folder)) || exit 0
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          LC_ALL=C git grep -z -I --untracked --no-color -F\(flags) -e \(quoted) -- . 2>/dev/null
        else
          LC_ALL=C grep -r -I -F --null\(flags)\(skips) -e \(quoted) . 2>/dev/null
        fi | head -c 8000000
        """
    }

    /// One line per match: the path, a NUL, the line number, then the text.
    public static func parse(_ output: Data, root: String, query: String) -> [ContentMatch] {
        var results: [ContentMatch] = []
        for rawLine in output.split(separator: 10) {
            guard let nul = rawLine.firstIndex(of: 0) else { continue }
            var relative = String(decoding: rawLine[rawLine.startIndex..<nul], as: UTF8.self)
            if relative.hasPrefix("./") { relative.removeFirst(2) }
            guard !RemotePathMap.climbs(relative) else { continue }
            let rest = rawLine[rawLine.index(after: nul)...]
            // `git grep` puts a NUL after the number as well, and `grep` a colon.
            guard let end = rest.firstIndex(where: { $0 == 0 || $0 == UInt8(ascii: ":") }),
                  let line = Int(String(decoding: rest[rest.startIndex..<end], as: UTF8.self)) else { continue }
            let path = root + "/" + relative
            let text = Data(rest[rest.index(after: end)...])
            guard var match = ContentSearch.matches(in: text, path: path, query: query, limit: 1).first else { continue }
            match.line = line
            results.append(match)
        }
        return results
    }

    /// Searches each folder on its server. `found` gets what each one had.
    public static func run(connection: RemoteConnection, folders: [String], query: String, excludes: [String], cancellation: ContentSearch.Cancellation,
                           found: @escaping @Sendable ([ContentMatch]) -> Void) {
        let caseSensitive = query.contains { $0.isUppercase }
        for folder in folders {
            if cancellation.isCancelled { return }
            guard let remote = connection.map.remote(folder),
                  let result = connection.run(script(folder: remote, query: query, caseSensitive: caseSensitive, excludes: excludes, listOnly: false), timeout: 60) else { continue }
            if cancellation.isCancelled { return }
            let matches = parse(result.output, root: folder, query: query)
            if !matches.isEmpty { found(Array(matches.prefix(ContentSearch.maximumMatches))) }
        }
    }

    /// The files on a server that mention a whole word, brought here so they can be read like any
    /// other file. At most a sensible number, nearest the point of asking being the caller's concern.
    public static func filesMentioning(_ word: String, connection: RemoteConnection, folders: [String], excludes: [String], limit: Int = 60) -> [String] {
        var files: [String] = []
        for folder in folders {
            guard let remote = connection.map.remote(folder),
                  let result = connection.run(script(folder: remote, query: word, caseSensitive: true, excludes: excludes, listOnly: true, wholeWord: true), timeout: 30) else { continue }
            for raw in result.output.split(whereSeparator: { $0 == 0 || $0 == 10 }) {
                var relative = String(decoding: raw, as: UTF8.self)
                if relative.hasPrefix("./") { relative.removeFirst(2) }
                guard !RemotePathMap.climbs(relative) else { continue }
                files.append(folder + "/" + relative)
            }
        }
        return Array(files.prefix(limit))
    }
}

extension Git {
    /// The files git would consider part of the project, which leaves out what .gitignore does.
    public static func projectFiles(in folder: String) -> [String]? {
        guard repositoryRoot(of: folder) != nil,
              let result = runGit(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: folder),
              result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map { folder + "/" + $0 }
    }
}
