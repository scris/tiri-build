import Foundation

/// The name under a position in text.
public enum SymbolText {
    private static func isPart(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// The whole name around an index, including one just before it, the way a cursor sits at a
    /// word's end. Nil for a number or for anything that isn't a name.
    public static func word(in string: NSString, at index: Int) -> NSRange? {
        guard string.length > 0 else { return nil }
        var start = min(max(index, 0), string.length)
        if start == string.length || !isPart(string.character(at: start)) {
            guard start > 0, isPart(string.character(at: start - 1)) else { return nil }
            start -= 1
        }
        var end = start
        while start > 0, isPart(string.character(at: start - 1)) { start -= 1 }
        while end < string.length, isPart(string.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        if let first = Unicode.Scalar(string.character(at: start)), CharacterSet.decimalDigits.contains(first) { return nil }
        return range
    }
}

public struct SymbolLocation: Sendable, Equatable, Identifiable {
    public var path: String
    /// Counting from 1.
    public var line: Int
    public var column: Int
    public var text: String
    public var id: String { "\(path):\(line):\(column)" }

    public init(path: String, line: Int, column: Int, text: String) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
    }
}

/// Finds where a name is defined by reading the files, for when no language server is there to
/// ask. It's a good guess rather than an answer, so several matches become a choice.
public enum DefinitionSearch {
    /// How sure a line is. Only the surest found gets shown.
    struct Patterns {
        let declaration: NSRegularExpression
        let binding: NSRegularExpression
        let cLike: NSRegularExpression
        let method: NSRegularExpression
        let assignment: NSRegularExpression
        let attribute: NSRegularExpression
        let addition: NSRegularExpression

        init?(symbol: String) {
            let name = NSRegularExpression.escapedPattern(for: symbol)
            func regex(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }
            let tail = "(?![\\w$])"
            guard let declaration = regex("(?:^|[\\s(])(?:(?:func|function\\*?|def|class|struct|enum|union|protocol|interface|trait|type|typealias|fn|actor|record|module|mod|namespace|package|macro_rules!|sub|object)\\s+\(name)\(tail)|func\\s*\\([^)]*\\)\\s*\(name)\(tail)|#\\s*define\\s+\(name)\(tail))"),
                  let binding = regex("(?:^|[\\s(])(?:let|var|const|val|static)\\s+(?:mut\\s+)?\(name)\(tail)|^(?:async\\s+)?\(name)\\s*[:=]\\s*(?:async\\s*)?(?:function|\\([^)]*\\)\\s*=>|\\w+\\s*=>)"),
                  let cLike = regex("^(?!return\\b|else\\b|new\\b|throw\\b|await\\b|yield\\b|delete\\b|case\\b|goto\\b)[\\w:<>,*&\\[\\]\\s]+?[\\s*&:]\(name)\\s*\\([^;]*$"),
                  let method = regex("^(?:(?:async|static|public|private|protected|get|set|override)\\s+)*\(name)\\s*\\([^)]*\\)\\s*(?::[^{]*)?\\{\\s*$"),
                  let assignment = regex("^\(name)\\s*(?::[^=]*)?=(?!=)"),
                  let attribute = regex("^(?:self|this)\\.\(name)\\s*(?::[^=]*)?=(?!=)"),
                  let addition = regex("^(?:(?:public|private|internal|fileprivate|open)\\s+)?(?:extension|impl(?:<[^>]*>)?)\\s+\(name)\(tail)") else { return nil }
            self.declaration = declaration
            self.binding = binding
            self.cLike = cLike
            self.method = method
            self.assignment = assignment
            self.attribute = attribute
            self.addition = addition
        }

        /// `text` starts at the line's first character that isn't space.
        func score(text: String, column: Int) -> Int {
            if text.hasPrefix("//") || text.hasPrefix("* ") || text.hasPrefix("/*") || text.hasPrefix("--")
                || (text.hasPrefix("#") && !text.hasPrefix("#define") && !text.hasPrefix("# define")) { return 0 }
            let range = NSRange(location: 0, length: (text as NSString).length)
            func hit(_ regex: NSRegularExpression) -> Bool { regex.firstMatch(in: text, range: range) != nil }
            if hit(declaration) { return 5 }
            if hit(binding) || hit(method) { return 4 }
            if hit(cLike) { return 4 }
            let topLevel = column == 1 && hit(assignment)
            if topLevel { return 4 }
            if hit(attribute) || hit(assignment) { return 2 }
            if hit(addition) { return 1 }
            return 0
        }
    }

    /// Definitions of a name in one file's bytes, with how sure each one is.
    static func candidates(in data: Data, path: String, symbol: String, patterns: Patterns) -> [(SymbolLocation, Int)] {
        ContentSearch.matches(in: data, path: path, query: symbol, limit: 400).compactMap { match in
            guard isWholeWord(match, symbol: symbol) else { return nil }
            let text = match.text.trimmingCharacters(in: .whitespaces)
            let score = patterns.score(text: text, column: match.column)
            guard score > 0 else { return nil }
            return (SymbolLocation(path: path, line: match.line, column: match.column, text: text), score)
        }
    }

    /// Whole words, in the case they were asked for. Search itself folds lowercase.
    static func isWholeWord(_ match: ContentMatch, symbol: String) -> Bool {
        let bytes = Array(match.text.utf8)
        var found = false
        let needle = Array(symbol.utf8)
        var index = 0
        func isPart(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 36 || byte >= 0x80
        }
        while index + needle.count <= bytes.count {
            if Array(bytes[index..<(index + needle.count)]) == needle,
               index == 0 || !isPart(bytes[index - 1]),
               index + needle.count == bytes.count || !isPart(bytes[index + needle.count]) {
                found = true
                break
            }
            index += 1
        }
        return found
    }

    /// Languages that can call each other. A definition in another language is only a last resort.
    static func family(of path: String) -> String {
        LanguageCatalog.language(forPath: path)?.familyName ?? (path as NSString).pathExtension.lowercased()
    }

    /// The surest matches, nearest first.
    static func ranked(_ candidates: [(SymbolLocation, Int)], near path: String) -> [SymbolLocation] {
        guard let best = candidates.map(\.1).max() else { return [] }
        var kept = candidates.filter { $0.1 == best }.map(\.0)
        let family = family(of: path)
        if kept.contains(where: { Self.family(of: $0.path) == family }) {
            kept = kept.filter { Self.family(of: $0.path) == family }
        }
        let directory = (path as NSString).deletingLastPathComponent
        func distance(_ location: SymbolLocation) -> Int {
            if location.path == path { return 0 }
            return (location.path as NSString).deletingLastPathComponent == directory ? 1 : 2
        }
        return kept.sorted {
            (distance($0), $0.path.count, $0.path, $0.line) < (distance($1), $1.path.count, $1.path, $1.line)
        }
    }

    public static func run(paths: [String], symbol: String, near path: String, cancellation: ContentSearch.Cancellation) -> [SymbolLocation] {
        guard let patterns = Patterns(symbol: symbol) else { return [] }
        let collected = Collector<(SymbolLocation, Int)>()
        forEachFile(paths, cancellation: cancellation) { data, file in
            collected.add(candidates(in: data, path: file, symbol: symbol, patterns: patterns))
        }
        return Array(ranked(collected.all, near: path).prefix(50))
    }

    /// Every use of a name, in the same languages when there are any.
    public static func references(paths: [String], symbol: String, near path: String, cancellation: ContentSearch.Cancellation) -> [SymbolLocation] {
        let collected = Collector<SymbolLocation>()
        forEachFile(paths, cancellation: cancellation) { data, file in
            collected.add(ContentSearch.matches(in: data, path: file, query: symbol, limit: 100).compactMap { match in
                guard isWholeWord(match, symbol: symbol) else { return nil }
                return SymbolLocation(path: file, line: match.line, column: match.column, text: match.text.trimmingCharacters(in: .whitespaces))
            })
        }
        var found = collected.all
        let family = family(of: path)
        if found.contains(where: { Self.family(of: $0.path) == family }) {
            found = found.filter { Self.family(of: $0.path) == family }
        }
        return Array(found.sorted { ($0.path, $0.line) < ($1.path, $1.line) }.prefix(300))
    }

    private static func forEachFile(_ paths: [String], cancellation: ContentSearch.Cancellation, body: @escaping @Sendable (Data, String) -> Void) {
        let chunk = 64
        let chunks = stride(from: 0, to: paths.count, by: chunk).map { Array(paths[$0..<min($0 + chunk, paths.count)]) }
        DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
            for file in chunks[index] {
                if cancellation.isCancelled { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                      (attributes[.size] as? Int ?? 0) <= ContentSearch.maximumFileBytes,
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) else { continue }
                body(data, file)
            }
        }
    }

    private final class Collector<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Element] = []
        func add(_ new: [Element]) { lock.withLock { items.append(contentsOf: new) } }
        var all: [Element] { lock.withLock { items } }
    }
}
