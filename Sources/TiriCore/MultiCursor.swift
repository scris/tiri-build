import Foundation

/// One of several cursors. The anchor stays put when a selection is extended, and the head moves.
public struct TextCursor: Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public init(_ range: NSRange) {
        self.init(anchor: range.location, head: NSMaxRange(range))
    }

    public var range: NSRange {
        NSRange(location: min(anchor, head), length: abs(head - anchor))
    }
}

/// What several cursors do to text, as pure functions. ⌘D's behaviour is all here, and the text
/// view only has to draw the result.
public enum MultiCursor {
    /// In order, with cursors that touch made into one. Where two selections merge, or a caret
    /// meets a selection, one selection covers both.
    public static func normalized(_ cursors: [TextCursor]) -> [TextCursor] {
        let sorted = cursors.sorted { $0.range.location < $1.range.location }
        var result: [TextCursor] = []
        for cursor in sorted {
            guard let last = result.last else {
                result.append(cursor)
                continue
            }
            let lastRange = last.range
            let range = cursor.range
            let touches = range.location < NSMaxRange(lastRange)
                || (range.location == NSMaxRange(lastRange) && (range.length == 0 || lastRange.length == 0))
            guard touches else {
                result.append(cursor)
                continue
            }
            let merged = NSRange(location: lastRange.location, length: max(NSMaxRange(lastRange), NSMaxRange(range)) - lastRange.location)
            result[result.count - 1] = TextCursor(merged)
        }
        return result
    }

    /// Each cursor's selection replaced with its text, and a caret after it.
    public static func replacing(_ cursors: [TextCursor], with texts: [String]) -> (changes: [TextChange], cursors: [TextCursor]) {
        precondition(cursors.count == texts.count)
        var changes: [TextChange] = []
        var result: [TextCursor] = []
        var delta = 0
        for (cursor, text) in zip(cursors, texts) {
            let range = cursor.range
            changes.append(TextChange(range: range, text: text))
            let caret = range.location + delta + (text as NSString).length
            result.append(TextCursor(anchor: caret, head: caret))
            delta += (text as NSString).length - range.length
        }
        return (changes, result)
    }

    /// The same text at every cursor.
    public static func inserting(_ text: String, at cursors: [TextCursor]) -> (changes: [TextChange], cursors: [TextCursor]) {
        replacing(cursors, with: Array(repeating: text, count: cursors.count))
    }

    /// Takes out these ranges, one per cursor, in order. Ranges that overlap become one, and so do their cursors.
    public static func deleting(_ ranges: [NSRange]) -> (changes: [TextChange], cursors: [TextCursor]) {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else {
                merged.append(range)
            }
        }
        let cursors = merged.map { TextCursor($0) }
        return replacing(cursors, with: Array(repeating: "", count: cursors.count))
    }

    /// Several edits, one per cursor, each worked out as if it were alone. Their ranges mustn't overlap.
    public static func combining(_ edits: [TextEdit]) -> (changes: [TextChange], cursors: [TextCursor]) {
        var changes: [TextChange] = []
        var cursors: [TextCursor] = []
        var delta = 0
        for edit in edits {
            changes += edit.changes
            let selection = NSRange(location: edit.selection.location + delta, length: edit.selection.length)
            cursors.append(TextCursor(selection))
            for change in edit.changes { delta += (change.text as NSString).length - change.range.length }
        }
        return (changes, cursors)
    }

    /// Where the cursors go after a line command.
    public enum LineCursors: Sendable {
        /// They stay on their text as it changes around them: comments, indenting.
        case follow
        /// They go with their lines: moving and copying.
        case travel
        /// The lines' cursors become the one the command leaves: deleting, inserting a line.
        case one
    }

    /// A line command at every cursor. Cursors whose lines touch are one block, so a line is
    /// commented, moved or deleted once however many cursors are on it. Each block is worked
    /// out as if it were the only selection, and nil leaves that block as it was.
    public static func lineEdit(at cursors: [TextCursor], in text: NSString, cursors placing: LineCursors,
                                edit: (NSRange) -> TextEdit?) -> (changes: [TextChange], cursors: [TextCursor])? {
        let sorted = normalized(cursors)
        guard !sorted.isEmpty else { return nil }
        // Blocks of whole lines, with the cursors on them.
        var blocks: [(lines: NSRange, cursors: [TextCursor])] = []
        for cursor in sorted {
            let lines = TextEditing.lines(in: text, selection: cursor.range).range
            if let last = blocks.last, lines.location <= NSMaxRange(last.lines) {
                let union = NSUnionRange(last.lines, lines)
                blocks[blocks.count - 1] = (union, last.cursors + [cursor])
            } else {
                blocks.append((lines, [cursor]))
            }
        }
        var changes: [TextChange] = []
        var result: [TextCursor] = []
        var delta = 0
        var changed = false
        for block in blocks {
            // One cursor's own selection; several, from the first to the end of the block's last line,
            // so a caret at the start of that line still counts it.
            let first = block.cursors[0].range.location
            var end = block.cursors.map { NSMaxRange($0.range) }.max() ?? first
            if block.cursors.count > 1 {
                var lastLine = NSMaxRange(block.lines)
                while lastLine > block.lines.location, lastLine > end, [10, 13].contains(text.character(at: lastLine - 1)) { lastLine -= 1 }
                end = max(end, lastLine)
            }
            let span = NSRange(location: first, length: end - first)
            guard let made = edit(span) else {
                result += block.cursors.map { TextCursor(anchor: $0.anchor + delta, head: $0.head + delta) }
                continue
            }
            changed = true
            let own = made.changes.sorted { $0.range.location < $1.range.location }
            let placed: [TextCursor]
            if block.cursors.count == 1 || placing == .one {
                placed = [TextCursor(made.selection)]
            } else if placing == .travel {
                let shift = made.selection.location - span.location
                placed = block.cursors.map { TextCursor(anchor: $0.anchor + shift, head: $0.head + shift) }
            } else {
                placed = block.cursors.map { TextCursor(anchor: position($0.anchor, through: own), head: position($0.head, through: own)) }
            }
            result += placed.map { TextCursor(anchor: $0.anchor + delta, head: $0.head + delta) }
            changes += own
            for change in own { delta += (change.text as NSString).length - change.range.length }
        }
        return changed ? (changes, normalized(result)) : nil
    }

    /// Where a place in the text ends up once these changes, in order, are made. Text put in
    /// right where it is goes before it; a place inside what's replaced stays inside the new text.
    static func position(_ offset: Int, through changes: [TextChange]) -> Int {
        var shift = 0
        for change in changes {
            let length = (change.text as NSString).length
            if change.range.length == 0 {
                if change.range.location <= offset { shift += length } else { break }
            } else if NSMaxRange(change.range) <= offset {
                shift += length - change.range.length
            } else if change.range.location < offset {
                return change.range.location + shift + min(offset - change.range.location, length)
            } else {
                break
            }
        }
        return offset + shift
    }

    /// What ⌘D adds: the next place this text appears after `offset`, going round to the top.
    /// A word ⌘D chose by itself matches whole and exact. Nil once they're all selected.
    public static func nextOccurrence(of needle: String, in text: NSString, after offset: Int, existing: [NSRange], wholeWord: Bool) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        func isWordPart(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
        }
        func search(_ range: NSRange) -> NSRange? {
            var remaining = range
            while remaining.length > 0 {
                let found = text.range(of: needle, options: [.literal], range: remaining)
                if found.location == NSNotFound { return nil }
                let isWhole = !isWordPart(found.location - 1) && !isWordPart(NSMaxRange(found))
                if (!wholeWord || isWhole), !existing.contains(where: { NSIntersectionRange($0, found).length > 0 }) { return found }
                let next = found.location + max(found.length, 1)
                remaining = NSRange(location: next, length: NSMaxRange(range) - next)
            }
            return nil
        }
        let start = min(max(offset, 0), text.length)
        return search(NSRange(location: start, length: text.length - start)) ?? search(NSRange(location: 0, length: text.length))
    }

    /// Pasting: one line per cursor if the lines and cursors match up, as when they were copied that way.
    public static func pieces(forPasting text: String, cursors: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        if cursors > 1, lines.count == cursors { return lines }
        return Array(repeating: text, count: cursors)
    }
}
