import Foundation

/// A piece of terminal text that may name a file or directory.
public struct PathCandidate: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var col: Int?
    /// Character offsets into the (ANSI-stripped) line. This is what gets underlined.
    public var range: Range<Int>

    public init(path: String, line: Int? = nil, col: Int? = nil, range: Range<Int>) {
        self.path = path
        self.line = line
        self.col = col
        self.range = range
    }
}

public struct ResolvedPath: Equatable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var line: Int?
    public var col: Int?
    public var range: Range<Int>

    public init(path: String, isDirectory: Bool, line: Int? = nil, col: Int? = nil, range: Range<Int> = 0..<0) {
        self.path = path
        self.isDirectory = isDirectory
        self.line = line
        self.col = col
        self.range = range
    }
}

public enum PathLinkDetector {
    /// Strip SGR, OSC and other escape sequences so raw captured output can be scanned.
    public static func stripANSI(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            guard scalar.value == 0x1B else {
                out.append(scalar)
                continue
            }
            guard let next = scalars.first else { break }
            switch next {
            case "[":  // CSI: parameters end at a final byte in @...~
                scalars.removeFirst()
                while let c = scalars.popFirst(), !(0x40...0x7E).contains(c.value) {}
            case "]":  // OSC: ends at BEL or ST
                scalars.removeFirst()
                while let c = scalars.popFirst() {
                    if c.value == 0x07 { break }
                    if c.value == 0x1B {
                        if scalars.first == "\\" { scalars.removeFirst() }
                        break
                    }
                }
            default:
                scalars.removeFirst()
            }
        }
        // A non-breaking space is a space for our purposes. Same length, so columns still line up.
        return String(out).replacingOccurrences(of: "\u{A0}", with: " ")
    }

    private static let openers: [Character: Character] = ["\"": "\"", "'": "'", "`": "`"]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"", "`"]
    private static let leadingPunctuation: Set<Character> = ["(", "[", "{", "<", "'", "\"", "`", "="]
    /// Characters that end an unquoted token.
    private static let tokenBreaks: Set<Character> = [" ", "\t", "|", "\"", "'", "`", "<", ">", "│", "┃", "·", "•", "❯", "›", "⎿", "→"]

    /// The argument of something shaped like `Update(src/a.ts)`.
    private static func toolCallArgument(_ line: [Character], start: Int, end: Int) -> Range<Int>? {
        guard let open = line[start..<end].firstIndex(of: "("), open > start,
              line[start..<open].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              let close = line[open..<end].lastIndex(of: ")"), close > open + 1 else { return nil }
        // Nothing but punctuation may follow the closing bracket.
        guard line[(close + 1)..<end].allSatisfy({ trailingPunctuation.contains($0) }) else { return nil }
        return (open + 1)..<close
    }

    /// The nearest brackets around a column, within one token.
    private static func enclosed(_ line: [Character], start: Int, end: Int, column: Int) -> Range<Int>? {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        var open = column
        while open >= start {
            if let close = pairs[line[open]], open != column,
               let closing = line[column..<end].firstIndex(of: close), closing > open + 1 {
                return (open + 1)..<closing
            }
            open -= 1
        }
        return nil
    }

    /// Every path-looking candidate in a line, left to right. Conservative: bare words
    /// without a slash or extension are skipped. Use `candidates(atColumn:in:)` for hover.
    public static func candidates(in rawLine: String) -> [PathCandidate] {
        let line = Array(stripANSI(rawLine))
        var results: [PathCandidate] = []
        var index = 0
        while index < line.count {
            let character = line[index]
            if openers[character] != nil, let close = closingQuote(for: index, in: line) {
                let inner = String(line[(index + 1)..<close])
                if looksLikePath(inner, quoted: true) {
                    var candidate = parseLocation(inner, start: index + 1)
                    // `File "a.py", line 12` carries its line number after the quote.
                    applyFollowingLocation(&candidate, in: line, after: close)
                    results.append(candidate)
                    index = close + 1
                    continue
                }
            }
            if tokenBreaks.contains(character) {
                index += 1
                continue
            }
            var end = index
            while end < line.count, !isTokenBreak(line, end) { end += 1 }
            // Claude Code prints what it touched as `Update(src/a.ts)`.
            if let inner = toolCallArgument(line, start: index, end: end), let candidate = cleanToken(line, start: inner.lowerBound, end: inner.upperBound),
               looksLikePath(candidate.path, quoted: false) {
                results.append(candidate)
            } else if let candidate = cleanToken(line, start: index, end: end), looksLikePath(candidate.path, quoted: false) {
                results.append(candidate)
                // A location after the token may have swallowed further text.
                index = max(index, candidate.range.upperBound)
            }
            index = max(end, index + 1)
        }
        return results
    }

    /// Candidates under a column, best first. Hover has an existence check behind it,
    /// so it can try anything: plain words too (`ls` output), and spaces in unquoted paths.
    public static func candidates(atColumn column: Int, in rawLine: String) -> [PathCandidate] {
        let line = Array(stripANSI(rawLine))
        guard column >= 0, column < line.count else { return [] }
        var results: [PathCandidate] = []

        // 1. Inside quotes.
        for candidate in candidates(in: rawLine) where candidate.range.contains(column) {
            results.append(candidate)
        }

        // 2. The token under the cursor, even if it doesn't look like a path.
        if !isTokenBreak(line, column) {
            var start = column
            while start > 0, !isTokenBreak(line, start - 1) { start -= 1 }
            var end = column + 1
            while end < line.count, !isTokenBreak(line, end) { end += 1 }
            // Whatever is in brackets around the cursor comes first. A file really named
            // `a(b.c).txt` still opens, because what exists as written beats any search.
            // In `Update(src/a.ts)`, the path is what's meant wherever you click.
            if let inner = toolCallArgument(line, start: start, end: end) ?? enclosed(line, start: start, end: end, column: column),
               let candidate = cleanToken(line, start: inner.lowerBound, end: inner.upperBound),
               candidate.path.contains("/") || candidate.path.contains("."), !results.contains(candidate) {
                results.insert(candidate, at: 0)
            }
            if let candidate = cleanToken(line, start: start, end: end),
               candidate.range.contains(column) {
                // On a diff header, `a/foo.swift` means `foo.swift`, even if `a/foo.swift` exists.
                if isDiffHeader(line), let stripped = strippingDiffPrefix(candidate) {
                    results.removeAll { $0.path == candidate.path }
                    results.append(stripped)
                }
                if !results.contains(candidate) { results.append(candidate) }
                // A name that literally contains what looked like a location: `foo(1)`.
                let literal = String(line[candidate.range])
                if literal != candidate.path, !literal.contains(":"), !results.contains(where: { $0.path == literal }) {
                    results.append(PathCandidate(path: literal, range: candidate.range))
                }
            }
        }

        // 3. Unquoted paths with spaces: grow outward across single spaces, longest first.
        if line[column] != "\t" {
            var start = column
            var end = column + 1
            while start > 0, canJoinAcrossSpace(line, start - 1) { start -= 1 }
            while end < line.count, canJoinAcrossSpace(line, end) { end += 1 }
            let hasSpace = line[start..<end].contains(" ")
            if hasSpace {
                var variants: [(Int, Int)] = []
                var starts = [start]
                for index in start..<column where line[index] == " " { starts.append(index + 1) }
                var ends = [end]
                var index = end - 1
                while index > column {
                    if line[index] == " " { ends.append(index) }
                    index -= 1
                }
                for from in starts {
                    for to in ends where from <= column && to > column {
                        variants.append((from, to))
                    }
                }
                variants.sort { ($0.1 - $0.0) > ($1.1 - $1.0) }
                for (from, to) in variants.prefix(24) {
                    if let candidate = cleanToken(line, start: from, end: to),
                       candidate.range.contains(column), candidate.path.contains(" "),
                       !results.contains(candidate) {
                        results.append(candidate)
                    }
                }
            }
        }
        return results
    }

    private static func isTokenBreak(_ line: [Character], _ index: Int) -> Bool {
        let character = line[index]
        if character == " " {
            // `my\ file.txt`: an escaped space belongs to the token.
            return !(index > 0 && line[index - 1] == "\\")
        }
        return tokenBreaks.contains(character)
    }

    private static func canJoinAcrossSpace(_ line: [Character], _ index: Int) -> Bool {
        let character = line[index]
        if character == " " {
            // Two spaces in a row are column separators, not part of a name.
            let previousIsSpace = index > 0 && line[index - 1] == " "
            let nextIsSpace = index + 1 < line.count && line[index + 1] == " "
            return !previousIsSpace && !nextIsSpace
        }
        return !tokenBreaks.contains(character)
    }

    private static func closingQuote(for open: Int, in line: [Character]) -> Int? {
        let quote = line[open]
        // An apostrophe inside a word (`don't`) doesn't open anything.
        if quote == "'", open > 0, line[open - 1].isLetter { return nil }
        var index = open + 1
        while index < line.count {
            if line[index] == quote { return index > open + 1 ? index : nil }
            index += 1
        }
        return nil
    }

    private static func isDiffHeader(_ line: [Character]) -> Bool {
        let head = String(line.prefix(11))
        return head.hasPrefix("--- ") || head.hasPrefix("+++ ") || head.hasPrefix("diff --git ")
    }

    private static func strippingDiffPrefix(_ candidate: PathCandidate) -> PathCandidate? {
        guard candidate.path.count > 2, candidate.path.dropFirst().first == "/",
              let first = candidate.path.first, "abciow12".contains(first) else { return nil }
        var stripped = candidate
        stripped.path = String(candidate.path.dropFirst(2))
        return stripped
    }

    /// A location that's separate from the path: `foo.ts, line 339`, `foo.ts 339:12`,
    /// `foo.ts (339, 12)`. These are VS Code's formats, from compilers and test runners.
    private static func applyFollowingLocation(_ candidate: inout PathCandidate, in line: [Character], after index: Int) {
        guard candidate.line == nil, index < line.count else { return }
        let start = index + 1
        guard start <= line.count else { return }
        let rest = String(line[start...])
        var matched: (line: Int?, col: Int?, length: Int)?
        if let match = rest.prefixMatch(of: /[,:]? ?(?:on )?lines? (\d+)(?:-\d+)?(?:,? ?(?:col|column|character) (\d+))?/) {
            matched = (Int(match.1), match.2.flatMap { Int($0) }, match.0.count)
        } else if let match = rest.prefixMatch(of: /:? ?[\(\[](\d+)(?:[,: ] ?(\d+))?[\)\]]/) {
            matched = (Int(match.1), match.2.flatMap { Int($0) }, match.0.count)
        } else if let match = rest.prefixMatch(of: /,? ?(\d+)(?::(\d+))?(?![\w.\/])/) {
            matched = (Int(match.1), match.2.flatMap { Int($0) }, match.0.count)
        }
        guard let matched else { return }
        candidate.line = matched.line
        candidate.col = matched.col
        candidate.range = candidate.range.lowerBound..<(start + matched.length)
    }

    private static func cleanToken(_ line: [Character], start: Int, end: Int) -> PathCandidate? {
        var from = start
        while from < end, leadingPunctuation.contains(line[from]) { from += 1 }
        // Keep `key=path` useful: `--file=src/a.swift`.
        if let equals = line[from..<end].firstIndex(of: "="), equals + 1 < end,
           line[(equals + 1)..<end].contains(where: { $0 == "/" || $0 == "." }) {
            from = equals + 1
        }
        guard from < end else { return nil }
        let raw = String(line[from..<end])
        var candidate: PathCandidate
        if var glued = parseGluedLocation(raw, start: from) {
            // `foo.ts(339, 12)`: the space split the column off into the next token.
            if glued.col == nil, raw.hasSuffix(",") || raw.hasSuffix(":") {
                let rest = String(line[end...])
                if let match = rest.prefixMatch(of: /\s?(\d+)[\)\]]/) {
                    glued.col = Int(match.1)
                    glued.range = glued.range.lowerBound..<(end + match.0.count)
                }
            }
            candidate = glued
        } else {
            // Trailing punctuation goes, unless a closing bracket has its opener in the
            // token, as in `app/(tabs)/index.tsx` or `foo(1).txt`.
            var to = end
            while to > from, trailingPunctuation.contains(line[to - 1]),
                  !isBalancedClose(line[to - 1], in: Array(line[from..<to])) {
                to -= 1
            }
            guard to > from else { return nil }
            candidate = PathCandidate(path: String(line[from..<to]), range: from..<to)
            // `foo.ts:line 339` and `foo.ts?raw`.
            if candidate.path.hasSuffix(":line") || candidate.path.hasSuffix(":lines") {
                let colon = candidate.path.lastIndex(of: ":")!
                let length = candidate.path.distance(from: candidate.path.startIndex, to: colon)
                candidate = PathCandidate(path: String(candidate.path[..<colon]), range: from..<(from + length))
            } else if let query = candidate.path.firstIndex(of: "?"), !candidate.path.contains("://"),
                      candidate.path.distance(from: candidate.path.startIndex, to: query) > 0 {
                candidate.path = String(candidate.path[..<query])
            }
            applyFollowingLocation(&candidate, in: line, after: candidate.range.upperBound - 1)
        }
        guard !candidate.path.isEmpty else { return nil }
        if candidate.path.hasPrefix("file://") {
            guard let url = URL(string: candidate.path), url.isFileURL else { return nil }
            candidate.path = url.path
        }
        candidate.path = candidate.path.replacingOccurrences(of: "\\ ", with: " ")
        return candidate
    }

    private static func isBalancedClose(_ character: Character, in token: [Character]) -> Bool {
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        guard let open = pairs[character] else { return false }
        return token.filter { $0 == open }.count >= token.filter { $0 == character }.count
    }

    /// A location stuck to the path, with no space: `a.ts:12`, `a.ts:12:3`, `a.ts:12:const x`
    /// (grep -n), `a.ts:339.12-341.789`, `a.ts#339`, `a.md#L12`, `a.ts(12,3)`, `a.ts[12:3]`.
    private static func parseGluedLocation(_ text: String, start: Int) -> PathCandidate? {
        func candidate(_ path: Substring, _ line: Substring?, _ col: Substring?, length: Int) -> PathCandidate {
            PathCandidate(path: String(path), line: line.flatMap { Int($0) }, col: col.flatMap { Int($0) },
                          range: start..<(start + length))
        }
        if let match = text.wholeMatch(of: /(.+?)#L?(\d+)(?:-L?\d+)?(?::(\d+))?[.,;:)\]]?/) {
            let trailing = text.last.map { ".,;:)]".contains($0) } == true ? 1 : 0
            return candidate(match.1, match.2, match.3, length: text.count - trailing)
        }
        if let match = text.wholeMatch(of: /(.+?)[\(\[](\d+)(?:[,:](\d+)?)?[\)\]]?[:,.]?/) {
            let trimmed = text.reversed().prefix { ":,.".contains($0) }.count
            return candidate(match.1, match.2, match.3, length: text.count - trimmed)
        }
        // The lookahead is what lets `a.ts:12/b` stay a path while `a.ts:12:const` stops at the 12.
        if let match = text.prefixMatch(of: /(.+?):(\d+)(?:[:.](\d+))?(?:-\d+(?:\.\d+)?)?(?=$|[:,;.)\]}!?'"`])/) {
            return candidate(match.1, match.2, match.3, length: match.0.count)
        }
        return nil
    }

    private static func parseLocation(_ text: String, start: Int) -> PathCandidate {
        parseGluedLocation(text, start: start) ?? PathCandidate(path: text, range: start..<(start + text.count))
    }

    private static func looksLikePath(_ text: String, quoted: Bool) -> Bool {
        let body = text.wholeMatch(of: /(.+?):(\d+)(:\d+)?:?/).map { String($0.1) } ?? text
        guard !body.isEmpty else { return false }
        if body.contains("://") { return body.hasPrefix("file://") }
        if body.hasPrefix("-") { return false }
        if body.hasPrefix("/") || body.hasPrefix("~/") || body.hasPrefix("./") || body.hasPrefix("../") {
            return body.count > 1
        }
        if body == "~" { return true }
        if !quoted, body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "/" }) { return false }
        // `1/2`, `and/or`: a slash alone is weak evidence, but the resolver checks existence.
        if body.contains("/") { return true }
        // A bare filename: `README.md`.
        if let dot = body.lastIndex(of: "."), dot != body.startIndex {
            let ext = body[body.index(after: dot)...]
            return !ext.isEmpty && ext.count <= 12 && ext.allSatisfy { $0.isLetter || $0.isNumber }
                && ext.contains { $0.isLetter }
        }
        return false
    }
}

/// Turns candidates into real paths: relative to the terminal's cwd, then workspace folders.
public struct PathResolver: Sendable {
    public var cwd: String?
    public var workspaceFolders: [String]
    public var home: String
    /// nil = doesn't exist; otherwise whether it's a directory.
    public var probe: @Sendable (String) -> Bool?
    /// Last resort: the files in the workspace this could mean, best first. Agents often print a
    /// path relative to some other folder, or to a web root like `/resume/index.html`.
    public var search: (@Sendable (String) -> [String])?
    /// Where an absolute path really is. On a server, that's in the local copy of it.
    public var absolute: (@Sendable (String) -> String)?

    public init(cwd: String?, workspaceFolders: [String],
                home: String = NSHomeDirectory(),
                probe: @escaping @Sendable (String) -> Bool? = PathResolver.fileSystemProbe,
                search: (@Sendable (String) -> [String])? = nil) {
        self.cwd = cwd
        self.workspaceFolders = workspaceFolders
        self.home = home
        self.probe = probe
        self.search = search
    }

    public static let fileSystemProbe: @Sendable (String) -> Bool? = { path in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    public func resolve(_ candidate: PathCandidate) -> ResolvedPath? {
        resolveAll(candidate).first
    }

    public func resolve(atColumn column: Int, in line: String) -> ResolvedPath? {
        resolveAll(atColumn: column, in: line).first
    }

    /// The path as written if it exists, or else every file in the workspace it could mean.
    public func resolveAll(_ candidate: PathCandidate) -> [ResolvedPath] {
        if let exact = resolveExactly(candidate) { return [exact] }
        return searchMatches(candidate)
    }

    /// Any reading of the text under the column that exists as written beats any search result.
    public func resolveAll(atColumn column: Int, in line: String) -> [ResolvedPath] {
        let candidates = PathLinkDetector.candidates(atColumn: column, in: line)
        for candidate in candidates {
            if let exact = resolveExactly(candidate) { return [exact] }
        }
        for candidate in candidates {
            let matches = searchMatches(candidate)
            if !matches.isEmpty { return matches }
        }
        return []
    }

    private func resolveExactly(_ candidate: PathCandidate) -> ResolvedPath? {
        for path in absoluteVariants(of: candidate.path) {
            if let isDirectory = probe(path) {
                return ResolvedPath(path: path, isDirectory: isDirectory,
                                    line: candidate.line, col: candidate.col, range: candidate.range)
            }
        }
        // `../src/a.ts` printed from a sibling folder: try it without the climbing.
        var stripped = candidate.path
        while stripped.hasPrefix("../") { stripped.removeFirst(3) }
        if stripped != candidate.path, !stripped.isEmpty {
            var next = candidate
            next.path = stripped
            return resolveExactly(next)
        }
        return nil
    }

    private func searchMatches(_ candidate: PathCandidate) -> [ResolvedPath] {
        // Only things that look like files: a bare word shouldn't match something far away.
        guard let search, !candidate.path.hasPrefix("~"),
              candidate.path.contains(".") || candidate.path.contains("/") else { return [] }
        return search(candidate.path).compactMap { found in
            probe(found).map { ResolvedPath(path: found, isDirectory: $0, line: candidate.line, col: candidate.col, range: candidate.range) }
        }
    }

    /// Where a path as written could be, in the order they're tried.
    public func candidatePaths(of path: String) -> [String] { absoluteVariants(of: path) }

    private func absoluteVariants(of path: String) -> [String] {
        if path == "~" { return [home] }
        if path.hasPrefix("~/") { return [home + String(path.dropFirst(1))] }
        if path.hasPrefix("/") { return [standardize(absolute?(path) ?? path)] }
        var roots: [String] = []
        if let cwd { roots.append(cwd) }
        roots.append(contentsOf: workspaceFolders)
        return roots.map { standardize(($0 as NSString).appendingPathComponent(path)) }
    }

    private func standardize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}

/// Finding what a path that doesn't exist as written most likely means.
public enum PathSearch {
    /// The most specific match wins. Files ending in all of `a/b/c.html` beat files ending in
    /// `b/c.html`, which beat files that only share the name. A name without an extension is
    /// too vague to match on its own.
    public static func matches(for path: String, filesNamed: (String) -> [String]) -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
        guard let name = parts.last else { return [] }
        let named = filesNamed(name)
        guard !named.isEmpty else { return [] }
        for start in parts.indices {
            let tail = parts[start...].joined(separator: "/")
            let hits = named.filter { $0.hasSuffix("/" + tail) }
            if !hits.isEmpty {
                return start == parts.count - 1 && !name.contains(".") ? [] : hits
            }
        }
        return []
    }

    /// What's already open first, then what's under the terminal's folder, then the shortest path.
    public static func ranked(_ paths: [String], open: Set<String>, near cwd: String?) -> [String] {
        func key(_ path: String) -> (Int, Int, Int, String) {
            let isNear = cwd.map { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ?? false
            return (open.contains(path) ? 0 : 1, isNear ? 0 : 1, path.count, path)
        }
        return Array(Set(paths)).sorted { key($0) < key($1) }
    }
}

public enum ShellQuote {
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=+,@%")

    /// Quote for a POSIX shell. Plain paths stay plain, as Cursor does on drop.
    public static func quote(_ text: String) -> String {
        if text.isEmpty { return "''" }
        if text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ paths: [String]) -> String {
        paths.map(quote).joined(separator: " ")
    }
}
