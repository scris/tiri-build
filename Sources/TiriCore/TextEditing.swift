import Foundation

/// One replacement in a document. Offsets are UTF-16, as NSString and NSTextView count them.
public struct TextChange: Equatable, Sendable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// What an editing command does: its changes, sorted and in terms of the text before them, and
/// the selection afterwards, in terms of the text after them.
public struct TextEdit: Equatable, Sendable {
    public var changes: [TextChange]
    public var selection: NSRange

    public init(changes: [TextChange], selection: NSRange) {
        self.changes = changes
        self.selection = selection
    }

    /// The same result as one replacement, for edits too many for a text view to take one at a time.
    public func coalesced(in text: NSString) -> TextChange? {
        guard let first = changes.first, let last = changes.last else { return nil }
        let result = NSMutableString(capacity: text.length)
        var position = first.range.location
        for change in changes {
            result.append(text.substring(with: NSRange(location: position, length: change.range.location - position)))
            result.append(change.text)
            position = NSMaxRange(change.range)
        }
        return TextChange(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), text: result as String)
    }
}

/// How a file indents.
public enum IndentStyle: Equatable, Sendable {
    case tabs(width: Int)
    case spaces(Int)

    public var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let count): String(repeating: " ", count: count)
        }
    }

    public var width: Int {
        switch self {
        case .tabs(let width): width
        case .spaces(let count): count
        }
    }

    /// Reads the start of a file, the way VS Code does: tabs if tabs lead, otherwise the
    /// commonest step between neighbouring lines. Four spaces if there's nothing to go on.
    public static func detect(in text: NSString, sampleLines: Int = 2_000) -> IndentStyle {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var location = 0
        var seen = 0
        while location < text.length, seen < sampleLines {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            seen += 1
            var spaces = 0
            var index = line.location
            var startsWithTab = false
            while index < NSMaxRange(line) {
                let unit = text.character(at: index)
                if unit == 32 {
                    spaces += 1
                } else if unit == 9 {
                    startsWithTab = index == line.location
                    break
                } else {
                    break
                }
                index += 1
            }
            if index >= NSMaxRange(line) || text.character(at: index) == 10 || text.character(at: index) == 13 { continue }
            if startsWithTab { tabLines += 1; continue }
            if spaces > 0 { spaceLines += 1 }
            let step = abs(spaces - previous)
            if step >= 2, step <= 8 { steps[step, default: 0] += 1 }
            previous = spaces
        }
        if tabLines > spaceLines { return .tabs(width: 4) }
        guard spaceLines > 0 else { return .spaces(4) }
        // A tie goes to the smaller step: an 8 is more likely two levels than one.
        let best = steps.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 4
        return .spaces(best)
    }
}

/// How a language writes comments.
public struct CommentSyntax: Equatable, Sendable {
    public var line: String?
    public var block: (open: String, close: String)?

    public init(line: String? = nil, block: (open: String, close: String)? = nil) {
        self.line = line
        self.block = block
    }

    public static func == (a: CommentSyntax, b: CommentSyntax) -> Bool {
        a.line == b.line && a.block?.open == b.block?.open && a.block?.close == b.block?.close
    }

    /// Nil when this kind of file has no comments, like JSON or plain text.
    public static func forFile(_ path: String) -> CommentSyntax? {
        LanguageCatalog.language(forPath: path)?.comment
    }

    /// Whether a line ending in `:` opens a block in this kind of file.
    public static func colonOpensBlock(_ path: String) -> Bool {
        LanguageCatalog.language(forPath: path)?.colonOpensBlock ?? false
    }
}

/// The small things an editor's fingers expect, as pure functions of text and selection.
/// Each returns nil when there's nothing to do, so a key press that can't apply leaves undo alone.
public enum TextEditing {
    // MARK: Lines

    struct Lines {
        /// From the start of the first line to the end of the last, with its line ending if it has one.
        var range: NSRange
        /// Each line's start.
        var starts: [Int]
        var endsWithTerminator: Bool
    }

    /// The whole lines a selection touches. A selection ending at the very start of a line
    /// doesn't count that line, as in VS Code: selecting by dragging down the margin works.
    static func lines(in text: NSString, selection: NSRange) -> Lines {
        var last = NSMaxRange(selection)
        if selection.length > 0, last > 0, last <= text.length {
            let previous = text.character(at: last - 1)
            if previous == 10 || previous == 13 { last -= 1 }
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lastLine = text.lineRange(for: NSRange(location: max(last, selection.location), length: 0))
        var starts: [Int] = []
        var location = first.location
        repeat {
            starts.append(location)
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
        } while location < NSMaxRange(lastLine)
        let range = NSRange(location: first.location, length: NSMaxRange(lastLine) - first.location)
        let finalLine = text.lineRange(for: NSRange(location: starts[starts.count - 1], length: 0))
        return Lines(range: range, starts: starts, endsWithTerminator: terminatorLength(in: text, line: finalLine) > 0)
    }

    /// How long a line's line ending is.
    private static func terminatorLength(in text: NSString, line: NSRange) -> Int {
        guard line.length > 0 else { return 0 }
        let end = NSMaxRange(line)
        let last = text.character(at: end - 1)
        if last == 10 {
            return line.length > 1 && text.character(at: end - 2) == 13 ? 2 : 1
        }
        return last == 13 ? 1 : 0
    }

    /// The line ending this file uses, going by its first line.
    public static func lineEnding(of text: NSString) -> String {
        let found = text.rangeOfCharacter(from: .newlines)
        guard found.location != NSNotFound else { return "\n" }
        let unit = text.character(at: found.location)
        if unit == 13 {
            return found.location + 1 < text.length && text.character(at: found.location + 1) == 10 ? "\r\n" : "\r"
        }
        return "\n"
    }

    /// A line's range without its line ending.
    private static func content(of lineStart: Int, in text: NSString) -> NSRange {
        let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
        return NSRange(location: line.location, length: line.length - terminatorLength(in: text, line: line))
    }

    /// The leading spaces and tabs, as a length.
    private static func indentLength(of line: NSRange, in text: NSString) -> Int {
        var index = line.location
        while index < NSMaxRange(line), text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 }
        return index - line.location
    }

    // MARK: Where the selection ends up

    /// Follows an offset through some changes. `leansRight` says which side of an insertion
    /// exactly at this offset it ends up on.
    static func map(_ offset: Int, through changes: [TextChange], leansRight: Bool) -> Int {
        var delta = 0
        for change in changes {
            let start = change.range.location
            let end = NSMaxRange(change.range)
            let inserted = (change.text as NSString).length
            if offset > end || (offset == end && (change.range.length > 0 || leansRight)) {
                delta += inserted - change.range.length
            } else if offset > start {
                return start + delta + (leansRight ? inserted : 0)
            } else {
                break
            }
        }
        return offset + delta
    }

    /// A caret travels with the text after it. A selection grows to take in what's added at its edges.
    static func mapSelection(_ selection: NSRange, through changes: [TextChange]) -> NSRange {
        if selection.length == 0 {
            let location = map(selection.location, through: changes, leansRight: true)
            return NSRange(location: location, length: 0)
        }
        let start = map(selection.location, through: changes, leansRight: false)
        let end = map(NSMaxRange(selection), through: changes, leansRight: true)
        return NSRange(location: start, length: max(end - start, 0))
    }

    // MARK: Comments

    public static func toggleLineComment(in text: NSString, selection: NSRange, syntax: CommentSyntax) -> TextEdit? {
        if let token = syntax.line {
            return toggleLineTokens(in: text, selection: selection, token: token)
        }
        if let block = syntax.block {
            return toggleBlock(in: text, selection: selection, open: block.open, close: block.close)
        }
        return nil
    }

    private static func toggleLineTokens(in text: NSString, selection: NSRange, token: String) -> TextEdit {
        let tokenLength = (token as NSString).length
        let block = lines(in: text, selection: selection)
        var contents: [(start: Int, indent: Int, isBlank: Bool, isCommented: Bool)] = []
        contents.reserveCapacity(block.starts.count)
        for start in block.starts {
            let line = content(of: start, in: text)
            let indent = indentLength(of: line, in: text)
            let isBlank = indent == line.length
            let begins = NSRange(location: start + indent, length: min(tokenLength, line.length - indent))
            let isCommented = !isBlank && begins.length == tokenLength && text.substring(with: begins) == token
            contents.append((start, indent, isBlank, isCommented))
        }
        let filled = contents.filter { !$0.isBlank }
        var changes: [TextChange] = []
        if !filled.isEmpty, filled.allSatisfy(\.isCommented) {
            for line in filled {
                var length = tokenLength
                let after = line.start + line.indent + tokenLength
                if after < text.length, text.character(at: after) == 32 { length += 1 }
                changes.append(TextChange(range: NSRange(location: line.start + line.indent, length: length), text: ""))
            }
        } else if filled.isEmpty {
            // A blank line: start a comment where the cursor is, ready to type in.
            let first = contents[0]
            changes.append(TextChange(range: NSRange(location: first.start + first.indent, length: 0), text: token + " "))
        } else {
            let column = filled.map(\.indent).min() ?? 0
            for line in filled {
                changes.append(TextChange(range: NSRange(location: line.start + column, length: 0), text: token + " "))
            }
        }
        return TextEdit(changes: changes, selection: mapSelection(selection, through: changes))
    }

    private static func toggleBlock(in text: NSString, selection: NSRange, open: String, close: String) -> TextEdit {
        let block = lines(in: text, selection: selection)
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length
        let firstLine = content(of: block.starts[0], in: text)
        let lastLine = content(of: block.starts[block.starts.count - 1], in: text)
        let indent = indentLength(of: firstLine, in: text)
        var end = NSMaxRange(lastLine)
        while end > lastLine.location, [32, 9].contains(text.character(at: end - 1)) { end -= 1 }
        let begin = firstLine.location + indent
        let span = end - begin
        var changes: [TextChange] = []
        if span >= openLength + closeLength,
           text.substring(with: NSRange(location: begin, length: openLength)) == open,
           text.substring(with: NSRange(location: end - closeLength, length: closeLength)) == close {
            var openEnd = openLength
            if begin + openEnd < end - closeLength, text.character(at: begin + openEnd) == 32 { openEnd += 1 }
            var closeStart = end - closeLength
            if closeStart > begin + openEnd, text.character(at: closeStart - 1) == 32 { closeStart -= 1 }
            changes.append(TextChange(range: NSRange(location: begin, length: openEnd), text: ""))
            changes.append(TextChange(range: NSRange(location: closeStart, length: end - closeStart), text: ""))
        } else {
            changes.append(TextChange(range: NSRange(location: begin, length: 0), text: open + " "))
            changes.append(TextChange(range: NSRange(location: end, length: 0), text: " " + close))
        }
        return TextEdit(changes: changes, selection: mapSelection(selection, through: changes))
    }

    // MARK: Indenting

    private static func indentWidth(_ text: NSString, _ line: NSRange, indent: Int, tabWidth: Int) -> Int {
        var width = 0
        for index in 0..<indent {
            width += text.character(at: line.location + index) == 9 ? tabWidth - width % tabWidth : 1
        }
        return width
    }

    public static func indent(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit? {
        let block = lines(in: text, selection: selection)
        var changes: [TextChange] = []
        changes.reserveCapacity(block.starts.count)
        for start in block.starts {
            let line = content(of: start, in: text)
            if line.length == 0 { continue }
            let indent = indentLength(of: line, in: text)
            switch style {
            case .tabs:
                changes.append(TextChange(range: NSRange(location: start, length: 0), text: "\t"))
            case .spaces(let size):
                let width = indentWidth(text, line, indent: indent, tabWidth: size)
                let adding = size - width % size
                // Up to the next stop, so a line that's off by one comes back into step.
                changes.append(TextChange(range: NSRange(location: start + indent, length: 0), text: String(repeating: " ", count: adding)))
            }
        }
        guard !changes.isEmpty else { return nil }
        return TextEdit(changes: changes, selection: mapSelection(selection, through: changes))
    }

    public static func outdent(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit? {
        let block = lines(in: text, selection: selection)
        var changes: [TextChange] = []
        changes.reserveCapacity(block.starts.count)
        for start in block.starts {
            let line = content(of: start, in: text)
            let indent = indentLength(of: line, in: text)
            guard indent > 0 else { continue }
            if text.character(at: start) == 9 {
                changes.append(TextChange(range: NSRange(location: start, length: 1), text: ""))
                continue
            }
            // Spaces back to the previous stop, stopping at a tab.
            let width = indentWidth(text, line, indent: indent, tabWidth: style.width)
            let removing = width % style.width == 0 ? style.width : width % style.width
            var count = 0
            while count < min(removing, indent), text.character(at: start + indent - 1 - count) == 32 { count += 1 }
            if count > 0 {
                changes.append(TextChange(range: NSRange(location: start + indent - count, length: count), text: ""))
            }
        }
        guard !changes.isEmpty else { return nil }
        // A caret or selection edge that was inside what went stays at the line's new indent.
        return TextEdit(changes: changes, selection: mapSelection(selection, through: changes))
    }

    /// The Tab key: indents selected lines, otherwise inserts up to the next stop.
    public static func tab(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit? {
        let block = lines(in: text, selection: selection)
        let wholeLine = selection.length > 0 && selection.location == block.starts[0]
            && NSMaxRange(selection) >= NSMaxRange(content(of: block.starts[block.starts.count - 1], in: text))
        if selection.length > 0, block.starts.count > 1 || wholeLine {
            return indent(in: text, selection: selection, style: style)
        }
        let inserted: String
        switch style {
        case .tabs:
            inserted = "\t"
        case .spaces(let size):
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = NSRange(location: line.location, length: selection.location - line.location)
            let width = indentWidth(text, before, indent: before.length, tabWidth: size)
            inserted = String(repeating: " ", count: size - width % size)
        }
        return TextEdit(changes: [TextChange(range: selection, text: inserted)],
                        selection: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    // MARK: Return

    /// What closes a bracket that opens a block.
    private static let closers: [unichar: unichar] = [123: 125, 40: 41, 91: 93]

    public static func newline(in text: NSString, selection: NSRange, style: IndentStyle, colonOpensBlock: Bool = false) -> TextEdit {
        let ending = lineEnding(of: text)
        let line = content(of: selection.location, in: text)
        let before = NSRange(location: line.location, length: selection.location - line.location)
        let indent = indentLength(of: before, in: text)
        let indentation = text.substring(with: NSRange(location: line.location, length: indent))

        // What's left of the line after the cursor, if the selection ends on it.
        var afterStart = NSMaxRange(selection)
        let endLine = content(of: afterStart, in: text)
        while afterStart < NSMaxRange(endLine), [32, 9].contains(text.character(at: afterStart)) { afterStart += 1 }
        let afterHasText = afterStart < NSMaxRange(endLine)

        var opener: unichar?
        var last = selection.location
        while last > line.location, [32, 9].contains(text.character(at: last - 1)) { last -= 1 }
        if last > line.location {
            let unit = text.character(at: last - 1)
            if closers[unit] != nil || (unit == 58 && colonOpensBlock) { opener = unit }
        }

        // A line of nothing but indent, on the way past it, doesn't keep its spaces.
        if before.length > 0, indent == before.length, !afterHasText, selection.length == 0, opener == nil {
            let inserted = ending + indentation
            return TextEdit(changes: [TextChange(range: NSRange(location: line.location, length: NSMaxRange(line) - line.location), text: inserted)],
                            selection: NSRange(location: line.location + (inserted as NSString).length, length: 0))
        }

        // `{|}` opens up onto three lines with the cursor in the middle.
        var replaced = selection
        var inserted: String
        var caretOffset: Int
        if let opener {
            let inner = indentation + style.unit
            if afterHasText, let closer = closers[opener], text.character(at: afterStart) == closer {
                replaced = NSRange(location: selection.location, length: afterStart - selection.location)
                let head = ending + inner
                inserted = head + ending + indentation
                caretOffset = (head as NSString).length
            } else {
                inserted = ending + inner
                caretOffset = (inserted as NSString).length
            }
        } else {
            inserted = ending + indentation
            caretOffset = (inserted as NSString).length
        }
        return TextEdit(changes: [TextChange(range: replaced, text: inserted)],
                        selection: NSRange(location: replaced.location + caretOffset, length: 0))
    }

    // MARK: Moving, copying and deleting lines

    public static func moveLines(in text: NSString, selection: NSRange, up: Bool) -> TextEdit? {
        let block = lines(in: text, selection: selection)
        let start = block.range.location
        let end = NSMaxRange(block.range)
        if up {
            guard start > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let shift = above.length
            let moved = NSRange(location: selection.location - shift, length: selection.length)
            if block.endsWithTerminator {
                let changes = [TextChange(range: above, text: ""),
                               TextChange(range: NSRange(location: end, length: 0), text: text.substring(with: above))]
                return TextEdit(changes: changes, selection: moved)
            }
            // The block is the last line, with no line ending of its own to carry.
            let terminator = terminatorLength(in: text, line: above)
            let neighbour = NSRange(location: above.location, length: above.length - terminator)
            let replacement = text.substring(with: block.range) + text.substring(with: NSRange(location: NSMaxRange(neighbour), length: terminator)) + text.substring(with: neighbour)
            return TextEdit(changes: [TextChange(range: NSRange(location: above.location, length: end - above.location), text: replacement)], selection: moved)
        }
        guard block.endsWithTerminator, end < text.length else { return nil }
        let below = text.lineRange(for: NSRange(location: end, length: 0))
        if terminatorLength(in: text, line: below) > 0 {
            let changes = [TextChange(range: NSRange(location: start, length: 0), text: text.substring(with: below)),
                           TextChange(range: below, text: "")]
            return TextEdit(changes: changes, selection: NSRange(location: selection.location + below.length, length: selection.length))
        }
        // Moving past a last line that has no line ending: it borrows this block's, and the block goes without.
        let terminator = terminatorLength(in: text, line: NSRange(location: block.starts[block.starts.count - 1], length: end - block.starts[block.starts.count - 1]))
        let terminatorText = text.substring(with: NSRange(location: end - terminator, length: terminator))
        let body = text.substring(with: NSRange(location: start, length: block.range.length - terminator))
        let replacement = text.substring(with: below) + terminatorText + body
        return TextEdit(changes: [TextChange(range: NSRange(location: start, length: NSMaxRange(below) - start), text: replacement)],
                        selection: NSRange(location: selection.location + below.length + terminator, length: selection.length))
    }

    public static func copyLines(in text: NSString, selection: NSRange, up: Bool) -> TextEdit {
        let block = lines(in: text, selection: selection)
        let body = text.substring(with: block.range)
        let ending = lineEnding(of: text)
        if up {
            let inserted = block.endsWithTerminator ? body : body + ending
            return TextEdit(changes: [TextChange(range: NSRange(location: block.range.location, length: 0), text: inserted)], selection: selection)
        }
        let inserted = block.endsWithTerminator ? body : ending + body
        let shift = (inserted as NSString).length
        return TextEdit(changes: [TextChange(range: NSRange(location: NSMaxRange(block.range), length: 0), text: inserted)],
                        selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    public static func deleteLines(in text: NSString, selection: NSRange) -> TextEdit? {
        guard text.length > 0 else { return nil }
        let block = lines(in: text, selection: selection)
        let start = block.range.location
        let end = NSMaxRange(block.range)
        let column = selection.location - start
        var removed = block.range
        if !block.endsWithTerminator, start > 0 {
            // The last line, with no line ending: the one before it gives up its own.
            let terminator = terminatorLength(in: text, line: text.lineRange(for: NSRange(location: start - 1, length: 0)))
            removed = NSRange(location: start - terminator, length: end - start + terminator)
        }
        guard removed.length > 0 else { return nil }
        // The cursor keeps its column on whichever line is now there, as far as that line reaches.
        let landing: Int
        if block.endsWithTerminator {
            let next = end < text.length ? content(of: end, in: text) : NSRange(location: end, length: 0)
            landing = start + min(column, next.length)
        } else if start > 0 {
            let previous = content(of: start - 1, in: text)
            landing = previous.location + min(column, previous.length)
        } else {
            landing = 0
        }
        return TextEdit(changes: [TextChange(range: removed, text: "")], selection: NSRange(location: landing, length: 0))
    }

    /// ⌘↩: a new line after this one, wherever on it the cursor is.
    public static func insertLineBelow(in text: NSString, selection: NSRange, style: IndentStyle, colonOpensBlock: Bool = false) -> TextEdit {
        let block = lines(in: text, selection: selection)
        let line = content(of: block.starts[block.starts.count - 1], in: text)
        return newline(in: text, selection: NSRange(location: NSMaxRange(line), length: 0), style: style, colonOpensBlock: colonOpensBlock)
    }

    /// ⇧⌘↩: a new line before this one, at its indent.
    public static func insertLineAbove(in text: NSString, selection: NSRange) -> TextEdit {
        let start = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let line = content(of: start, in: text)
        let indentation = text.substring(with: NSRange(location: start, length: indentLength(of: line, in: text)))
        return TextEdit(changes: [TextChange(range: NSRange(location: start, length: 0), text: indentation + lineEnding(of: text))],
                        selection: NSRange(location: start + (indentation as NSString).length, length: 0))
    }
}

// MARK: - Line starts, kept up to date as text changes

/// Where every line starts. A file of 100,000 lines changes one character at a time, so an edit
/// looks only at what it touched.
public struct LineTable: Equatable, Sendable {
    public private(set) var starts: [Int] = [0]

    public init() {}

    public init(_ text: NSString) {
        rebuild(text)
    }

    public var count: Int { starts.count }

    public mutating func rebuild(_ text: NSString) {
        starts = [0]
        Self.appendStarts(of: text, from: 0, to: text.length, to: &starts)
    }

    /// Terminators in `lower..<upper`, as the offsets just after them. \r\n counts once.
    private static func appendStarts(of text: NSString, from lower: Int, to upper: Int, to starts: inout [Int]) {
        guard upper > lower else { return }
        let length = text.length
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk + 1)
        var position = lower
        while position < upper {
            let count = min(chunk, upper - position)
            // One more, to see what follows a \r at the end of the chunk.
            let fetch = min(count + 1, length - position)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: fetch))
            }
            for offset in 0..<count {
                let unit = buffer[offset]
                if unit == 10 {
                    starts.append(position + offset + 1)
                } else if unit == 13, !(offset + 1 < fetch && buffer[offset + 1] == 10) {
                    starts.append(position + offset + 1)
                }
            }
            position += count
        }
    }

    /// After an edit: `editedRange` is what's there now, and `delta` how much longer the text got.
    public mutating func update(editedRange: NSRange, delta: Int, in text: NSString) {
        let newEnd = NSMaxRange(editedRange)
        let oldEnd = newEnd - delta
        // A terminator can change meaning at the edges, as \r and \n meet or part.
        let lower = max(editedRange.location - 1, 0)
        let upperNew = min(newEnd + 1, text.length)
        let upperOld = min(oldEnd + 1, text.length - delta)
        // Everything starting after `lower` and at or before the old upper edge is looked at again.
        let first = firstIndex(greaterThan: lower)
        let past = firstIndex(greaterThan: upperOld)
        var middle: [Int] = []
        Self.appendStarts(of: text, from: lower, to: upperNew, to: &middle)
        // The tail moves by the same amount, whatever happened in the middle.
        var result: [Int] = []
        result.reserveCapacity(starts.count + middle.count - (past - first))
        result.append(contentsOf: starts[0..<first])
        result.append(contentsOf: middle)
        for index in past..<starts.count { result.append(starts[index] + delta) }
        starts = result
    }

    private func firstIndex(greaterThan value: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] > value { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Which line an offset is on, counting from 0.
    public func line(containing offset: Int) -> Int {
        max(firstIndex(greaterThan: offset) - 1, 0)
    }
}

// MARK: - Brackets

public enum BracketMatcher {
    private static let pairs: [unichar: (other: unichar, forward: Bool)] = [
        40: (41, true), 91: (93, true), 123: (125, true),
        41: (40, false), 93: (91, false), 125: (123, false),
    ]

    /// The bracket beside the cursor and the one it pairs with, left one first. `isIgnored` says
    /// what doesn't count as code, like a bracket inside a string, unless the cursor is in there too.
    public static func match(in text: NSString, caret: Int, limit: Int = 100_000, isIgnored: (Int) -> Bool = { _ in false }) -> (open: Int, close: Int)? {
        guard caret <= text.length else { return nil }
        // Beside the cursor: the left side wins, as in VS Code.
        for position in [caret - 1, caret] where position >= 0 && position < text.length {
            let unit = text.character(at: position)
            guard let pair = pairs[unit] else { continue }
            let ignoring = !isIgnored(position)
            var depth = 0
            var index = position
            var steps = 0
            let step = pair.forward ? 1 : -1
            while true {
                index += step
                steps += 1
                guard index >= 0, index < text.length, steps <= limit else { break }
                let found = text.character(at: index)
                guard found == unit || found == pair.other else { continue }
                if ignoring, isIgnored(index) { continue }
                if found == unit {
                    depth += 1
                } else if depth == 0 {
                    return pair.forward ? (position, index) : (index, position)
                } else {
                    depth -= 1
                }
            }
        }
        return nil
    }
}

// MARK: - Finding in a document

public enum TextSearch {
    /// Every place the query appears. Literal, so offsets line up with the text exactly.
    public static func ranges(of query: String, in text: NSString, caseSensitive: Bool, limit: Int = 200_000) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var options: NSString.CompareOptions = [.literal]
        if !caseSensitive { options.insert(.caseInsensitive) }
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0, found.count < limit {
            let range = text.range(of: query, options: options, range: search)
            if range.location == NSNotFound || range.length == 0 { break }
            found.append(range)
            let next = NSMaxRange(range)
            search = NSRange(location: next, length: text.length - next)
        }
        return found
    }

    /// The first match at or after an offset, going round to the start if there's none. Nil if there are no matches.
    public static func index(atOrAfter offset: Int, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].location >= offset { high = mid } else { low = mid + 1 }
        }
        return low == matches.count ? 0 : low
    }

    /// The last match before an offset, going round to the end if there's none.
    public static func index(before offset: Int, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].location < offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? matches.count - 1 : low - 1
    }

    /// Replacing every match, as an edit whose undo brings them all back in one step.
    public static func replaceAll(_ matches: [NSRange], with replacement: String, selection: NSRange) -> TextEdit {
        let changes = matches.map { TextChange(range: $0, text: replacement) }
        let caret = TextEditing.map(selection.location, through: changes, leansRight: false)
        return TextEdit(changes: changes, selection: NSRange(location: caret, length: 0))
    }
}
