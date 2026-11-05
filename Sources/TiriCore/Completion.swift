import Foundation

// MARK: - What a server suggests

public struct CompletionItem: Sendable, Equatable {
    public enum Kind: Int, Sendable {
        case text = 1, method, function, constructor, field, variable, `class`, interface, module, property, unit, value, `enum`, keyword,
             snippet, color, file, reference, folder, enumMember, constant, `struct`, event, `operator`, typeParameter
    }

    public var label: String
    public var kind: Kind?
    /// Beside the name, like its type.
    public var detail: String?
    public var documentation: String?
    /// What to match the typing against, when it isn't the label.
    public var filterText: String?
    public var sortText: String?
    public var insertText: String?
    public var replaceRange: LSPRange?
    /// Things like the import this name needs.
    public var additionalEdits: [LSPTextEdit]
    public var preselect: Bool
    public var isFromServer: Bool
    /// Exactly as the server sent it, to send back when asking for its details.
    public var raw: JSONValue?

    public init(label: String, kind: Kind? = nil, detail: String? = nil, documentation: String? = nil, filterText: String? = nil, sortText: String? = nil,
                insertText: String? = nil, replaceRange: LSPRange? = nil, additionalEdits: [LSPTextEdit] = [], preselect: Bool = false,
                isFromServer: Bool = true, raw: JSONValue? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.filterText = filterText
        self.sortText = sortText
        self.insertText = insertText
        self.replaceRange = replaceRange
        self.additionalEdits = additionalEdits
        self.preselect = preselect
        self.isFromServer = isFromServer
        self.raw = raw
    }

    public var matchText: String { filterText ?? label }
    /// Several can share a name, from different modules.
    public var identity: String { [label, sortText ?? "", detail ?? "", insertText ?? ""].joined(separator: "\u{0}") }
    public var textToInsert: String { insertText ?? label }
}

/// Counting from 0, in UTF-16.
public struct LSPRange: Sendable, Equatable {
    public var startLine: Int
    public var startCharacter: Int
    public var endLine: Int
    public var endCharacter: Int

    public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
    }

    init?(_ value: JSONValue?) {
        guard let start = value?["start"], let end = value?["end"], let startLine = start["line"]?.intValue, let startCharacter = start["character"]?.intValue,
              let endLine = end["line"]?.intValue, let endCharacter = end["character"]?.intValue else { return nil }
        self.init(startLine: startLine, startCharacter: startCharacter, endLine: endLine, endCharacter: endCharacter)
    }

    public func range(in lines: LineTable, length: Int) -> NSRange? {
        guard startLine < lines.count, endLine < lines.count else { return nil }
        let start = min(lines.starts[startLine] + startCharacter, length)
        let end = min(lines.starts[endLine] + endCharacter, length)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

public struct LSPTextEdit: Sendable, Equatable {
    public var range: LSPRange
    public var text: String

    public init(range: LSPRange, text: String) {
        self.range = range
        self.text = text
    }

    init?(_ value: JSONValue) {
        guard let range = LSPRange(value["range"]), let text = value["newText"]?.stringValue else { return nil }
        self.init(range: range, text: text)
    }
}

public struct CompletionList: Sendable, Equatable {
    public var items: [CompletionItem]
    /// Typing more could turn up things that aren't here, so asking again is worth it.
    public var isIncomplete: Bool

    public init(items: [CompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

extension LSP {
    /// What a server said it can do about completion and about being told of changes.
    public struct ServerAbilities: Sendable, Equatable {
        /// 0 is never tell it, 1 is the whole file each time, 2 is just what changed.
        public var syncKind = 1
        public var completes = false
        public var triggerCharacters = Set<String>()
        public var canResolve = false

        public init() {}

        public init(capabilities: JSONValue?) {
            let sync = capabilities?["textDocumentSync"]
            syncKind = sync?.intValue ?? sync?["change"]?.intValue ?? 1
            if let provider = capabilities?["completionProvider"], case .object = provider {
                completes = true
                triggerCharacters = Set((provider["triggerCharacters"]?.arrayValue ?? []).compactMap(\.stringValue))
                canResolve = provider["resolveProvider"]?.boolValue ?? false
            }
        }
    }

    /// An answer is a list of items, or a list with a flag saying whether it's the whole list.
    public static func completions(from result: JSONValue?) -> CompletionList {
        guard let result else { return CompletionList(items: [], isIncomplete: false) }
        let defaults = result["itemDefaults"]
        let entries = result.arrayValue ?? result["items"]?.arrayValue ?? []
        let items = entries.compactMap { completionItem($0, defaults: defaults) }
        return CompletionList(items: items, isIncomplete: result["isIncomplete"]?.boolValue ?? false)
    }

    public static func completionItem(_ entry: JSONValue, defaults: JSONValue? = nil) -> CompletionItem? {
        // clangd pads its labels, leaving room for a mark of its own.
        guard let label = entry["label"]?.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        let format = entry["insertTextFormat"]?.intValue ?? defaults?["insertTextFormat"]?.intValue
        func plain(_ text: String?) -> String? {
            guard let text else { return nil }
            // Told it can't, a server can still send one. Its placeholders shouldn't reach the file.
            return format == 2 ? Snippets.plainText(of: text) : text
        }
        var insert = plain(entry["insertText"]?.stringValue ?? entry["textEditText"]?.stringValue)
        var range: LSPRange?
        if let edit = entry["textEdit"] {
            insert = plain(edit["newText"]?.stringValue) ?? insert
            range = LSPRange(edit["range"]) ?? LSPRange(edit["replace"]) ?? LSPRange(edit["insert"])
        } else if let shared = defaults?["editRange"] {
            range = LSPRange(shared) ?? LSPRange(shared["replace"]) ?? LSPRange(shared["insert"])
        }
        // Where a name comes from tells apart several with the same name, so it comes first.
        let detail = entry["labelDetails"]?["description"]?.stringValue ?? entry["detail"]?.stringValue ?? entry["labelDetails"]?["detail"]?.stringValue
        return CompletionItem(label: label, kind: entry["kind"]?.intValue.flatMap(CompletionItem.Kind.init(rawValue:)), detail: detail,
                              documentation: documentation(entry["documentation"]), filterText: entry["filterText"]?.stringValue, sortText: entry["sortText"]?.stringValue,
                              insertText: insert, replaceRange: range, additionalEdits: (entry["additionalTextEdits"]?.arrayValue ?? []).compactMap(LSPTextEdit.init),
                              preselect: entry["preselect"]?.boolValue ?? false, raw: entry)
    }

    static func documentation(_ value: JSONValue?) -> String? {
        let text = value?.stringValue ?? value?["value"]?.stringValue
        return text?.isEmpty == true ? nil : text
    }

    public static func completionParams(path: String, line: Int, character: Int, triggerCharacter: String?) -> JSONValue {
        var params = textPosition(path: path, line: line, character: character).objectValue
        var context: [String: JSONValue] = ["triggerKind": .int(triggerCharacter == nil ? 1 : 2)]
        if let triggerCharacter { context["triggerCharacter"] = .string(triggerCharacter) }
        params["context"] = .object(context)
        return .object(params)
    }

    /// A range of an edit, as a server wants to hear about it: where it was in the text before.
    public static func contentChange(range: NSRange, text: String, in mirror: TextMirror) -> JSONValue {
        let start = mirror.position(of: range.location)
        let end = mirror.position(of: NSMaxRange(range))
        return .object([
            "range": .object(["start": position(line: start.line, character: start.character), "end": position(line: end.line, character: end.character)]),
            "text": .string(text),
        ])
    }
}

enum Snippets {
    /// `foo(${1:bar}, $2)$0` as plain text is `foo(bar, )`.
    static func plainText(of snippet: String) -> String {
        var result = ""
        let characters = Array(snippet)
        var index = 0
        func skipDigits() { while index < characters.count, characters[index].isNumber { index += 1 } }
        func body(until end: Character?) {
            while index < characters.count {
                let character = characters[index]
                if let end, character == end {
                    index += 1
                    return
                }
                if character == "\\", index + 1 < characters.count {
                    result.append(characters[index + 1])
                    index += 2
                } else if character == "$", index + 1 < characters.count, characters[index + 1] == "{" {
                    index += 2
                    skipDigits()
                    guard index < characters.count else { return }
                    if characters[index] == ":" {
                        index += 1
                        body(until: "}")
                    } else if characters[index] == "|" {
                        index += 1
                        var choice = ""
                        while index < characters.count, characters[index] != "," , characters[index] != "|" {
                            choice.append(characters[index])
                            index += 1
                        }
                        result += choice
                        while index < characters.count, characters[index] != "}" { index += 1 }
                        index += 1
                    } else {
                        // `${name}`, a variable nobody here can fill in.
                        while index < characters.count, characters[index] != "}" { index += 1 }
                        index += 1
                    }
                } else if character == "$", index + 1 < characters.count, characters[index + 1].isNumber {
                    index += 1
                    skipDigits()
                } else {
                    result.append(character)
                    index += 1
                }
            }
        }
        body(until: nil)
        return result
    }
}

// MARK: - Matching what's typed

public enum CompletionMatcher {
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// UTF-16 offsets in the text that matched, for showing them.
        public var positions: [Int]
    }

    private static func lower(_ unit: UInt16) -> UInt16 {
        unit >= 65 && unit <= 90 ? unit + 32 : unit
    }

    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    private static func isLowerOrDigit(_ unit: UInt16) -> Bool { (unit >= 97 && unit <= 122) || (unit >= 48 && unit <= 57) }

    /// Where a word starts: "cra" finds `createApplication`, and `create_app` too.
    private static func boundaryBonus(_ target: [UInt16], at index: Int) -> Int {
        if index == 0 { return 12 }
        let previous = target[index - 1]
        if previous == 95 || previous == 45 || previous == 46 || previous == 36 || previous == 32 || previous == 47 || previous == 58 { return 9 }
        if isUpper(target[index]), isLowerOrDigit(previous) { return 9 }
        return 0
    }

    /// Nil if the letters aren't all there, in order. Higher is better, and an exact start is best.
    public static func match(query: String, in target: String) -> Match? {
        let needle = Array(query.utf16)
        let haystack = Array(target.utf16)
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        guard needle.count <= haystack.count, haystack.count <= 512 else { return nil }
        let folded = needle.map(lower)
        // Most things don't match at all, and this finds that without any tables.
        var at = 0
        for unit in haystack where at < folded.count && lower(unit) == folded[at] { at += 1 }
        guard at == folded.count else { return nil }

        // The best way to line them up, by each query letter ending at each position.
        let none = Int.min / 2
        let width = haystack.count
        var previousBest = [Int](repeating: none, count: width)
        var trace = [[Int32]](repeating: [Int32](repeating: -1, count: width), count: needle.count)
        for row in 0..<needle.count {
            var current = [Int](repeating: none, count: width)
            var bestBefore = none
            var bestBeforeAt: Int32 = -1
            for column in 0..<width {
                if row > 0, column > 0, previousBest[column - 1] > bestBefore - 1 {
                    // Each letter skipped costs a little, whichever way they were reached.
                    bestBefore = previousBest[column - 1]
                    bestBeforeAt = Int32(column - 1)
                } else if row > 0, column > 0 {
                    bestBefore -= 1
                }
                guard lower(haystack[column]) == folded[row] else { continue }
                var score = 1 + boundaryBonus(haystack, at: column)
                if haystack[column] == needle[row] { score += 1 }
                if row == 0 {
                    // Starting later costs, a little.
                    current[column] = score - min(column, 8)
                } else {
                    var best = none
                    var from: Int32 = -1
                    if column > 0, previousBest[column - 1] > none {
                        // Next to the letter before: runs of letters are what people remember.
                        best = previousBest[column - 1] + 6
                        from = Int32(column - 1)
                    }
                    if bestBefore > none, bestBefore - 1 > best {
                        best = bestBefore - 1
                        from = bestBeforeAt
                    }
                    guard from >= 0 else { continue }
                    current[column] = best + score
                    trace[row][column] = from
                }
            }
            previousBest = current
        }
        var end = -1
        var best = none
        for column in 0..<width where previousBest[column] > best {
            best = previousBest[column]
            end = column
        }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: needle.count)
        var column = end
        for row in stride(from: needle.count - 1, through: 0, by: -1) {
            positions[row] = column
            if row > 0 { column = Int(trace[row][column]) }
        }
        return Match(score: best, positions: positions)
    }
}

/// Puts a list in order, for what's been typed so far.
public enum CompletionRanker {
    public struct Ranked: Sendable, Equatable {
        public var item: CompletionItem
        public var positions: [Int]
        public var score: Int
    }

    /// `recent` are labels accepted lately, most recent last. `nearby` are names close to the cursor.
    public static func rank(_ items: [CompletionItem], query: String, recent: [String] = [], nearby: Set<String> = [], limit: Int = 200) -> [Ranked] {
        var recency: [String: Int] = [:]
        for (index, label) in recent.enumerated() { recency[label] = index + 1 }
        var ranked: [Ranked] = []
        ranked.reserveCapacity(min(items.count, 512))
        for item in items {
            guard let match = CompletionMatcher.match(query: query, in: item.matchText) else { continue }
            var score = match.score
            if let used = recency[item.label] { score += 6 + min(used, 6) }
            if nearby.contains(item.label) { score += 5 }
            if item.label == query { score += 1 }
            ranked.append(Ranked(item: item, positions: match.positions, score: score))
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let left = a.item.sortText ?? a.item.label
            let right = b.item.sortText ?? b.item.label
            if left != right { return left < right }
            return a.item.label.utf16.count < b.item.label.utf16.count
        }
        return Array(ranked.prefix(limit))
    }

    /// With nothing to go on, the server's own order and what it would like chosen first.
    public static func preselected(in ranked: [Ranked], query: String) -> Int {
        guard query.isEmpty else { return 0 }
        return ranked.firstIndex { $0.item.preselect } ?? 0
    }
}

// MARK: - Words, for when no server can say

public enum WordIndex {
    private static func isPart(_ unit: UInt16, first: Bool) -> Bool {
        if unit == 95 || unit == 36 { return true }
        if (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) { return true }
        if unit >= 48 && unit <= 57 { return !first }
        return unit >= 0x80 && unit != 0x2028 && unit != 0x2029 && !(unit >= 0x3000 && unit <= 0x303F) && !(unit >= 0xFF00 && unit <= 0xFFEF)
    }

    /// Every name in the text. Length two and up, because a single letter isn't worth suggesting.
    public static func words(in text: NSString, range: NSRange? = nil) -> Set<String> {
        let range = range ?? NSRange(location: 0, length: text.length)
        var found = Set<String>()
        guard range.length > 0 else { return found }
        let chunk = 4_096
        var buffer = [unichar](repeating: 0, count: chunk)
        var word: [UInt16] = []
        func finish() {
            if word.count >= 2, word.count <= 128 { found.insert(String(decoding: word, as: UTF16.self)) }
            word.removeAll(keepingCapacity: true)
        }
        var position = range.location
        let end = NSMaxRange(range)
        while position < end {
            let count = min(chunk, end - position)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: position, length: count)) }
            for offset in 0..<count {
                let unit = buffer[offset]
                if isPart(unit, first: word.isEmpty) { word.append(unit) } else { finish() }
            }
            position += count
        }
        finish()
        return found
    }

    /// The name being typed: from the name's start to the cursor. Nil if the cursor isn't after one.
    public static func prefix(in text: NSString, before caret: Int) -> NSRange? {
        guard caret > 0, caret <= text.length else { return nil }
        var start = caret
        while start > 0, isPart(text.character(at: start - 1), first: false) { start -= 1 }
        // Digits can't start a name: `12ab` isn't one.
        while start < caret, !isPart(text.character(at: start), first: true) { start += 1 }
        return start < caret ? NSRange(location: start, length: caret - start) : nil
    }

    public static func items(from words: Set<String>, excluding typed: String?) -> [CompletionItem] {
        words.compactMap { word in
            word == typed ? nil : CompletionItem(label: word, kind: .text, isFromServer: false)
        }
    }
}

// MARK: - Accepting

public enum CompletionEdit {
    /// What each cursor replaces, in order. Each goes `left` back, as far as its own name goes, and
    /// `right` on, and none reaches into the next or past the end of the text.
    public static func ranges(heads: [Int], left: Int, right: Int, wordStarts: [Int]?, length: Int) -> [NSRange] {
        var result: [NSRange] = []
        var previousEnd = 0
        for (index, head) in heads.enumerated() {
            var start = head - left
            if let wordStarts { start = max(start, wordStarts[index]) }
            start = min(max(start, previousEnd), head)
            let limit = index + 1 < heads.count ? heads[index + 1] : length
            let end = max(min(head + right, limit, length), head)
            result.append(NSRange(location: start, length: end - start))
            previousEnd = end
        }
        return result
    }

    /// The changes to make, in order, and where the cursor ends up, with one replacement at each
    /// place and anything extra, like an import, folded in.
    public static func make(replacing ranges: [NSRange], with text: String, extra: [TextChange]) -> (changes: [TextChange], carets: [Int]) {
        let inserted = (text as NSString).length
        let kept = extra.filter { edit in
            !ranges.contains { range in
                if edit.range.length > 0 { return NSIntersectionRange(range, edit.range).length > 0 }
                return edit.range.location > range.location && edit.range.location < NSMaxRange(range)
            }
        }
        // At the same place, the extra comes first, so that it ends up before the name rather than inside it.
        let entries = kept.map { (change: $0, isName: false) } + ranges.map { (change: TextChange(range: $0, text: text), isName: true) }
        let ordered = entries.enumerated().sorted { a, b in
            let left = (a.element.change.range.location, a.element.isName ? 1 : 0, a.offset)
            let right = (b.element.change.range.location, b.element.isName ? 1 : 0, b.offset)
            return left < right
        }.map(\.element)
        var carets: [Int] = []
        var shift = 0
        for entry in ordered {
            if entry.isName { carets.append(entry.change.range.location + shift + inserted) }
            shift += (entry.change.text as NSString).length - entry.change.range.length
        }
        return (ordered.map(\.change), carets)
    }
}
