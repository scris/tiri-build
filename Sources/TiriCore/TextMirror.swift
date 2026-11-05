import Foundation

/// Which lines an edit touched: `removed` lines at `start` became `inserted` lines.
public struct LineEdit: Equatable, Sendable {
    public var start: Int
    public var removed: Int
    public var inserted: Int

    public init(start: Int, removed: Int, inserted: Int) {
        self.start = start
        self.removed = removed
        self.inserted = inserted
    }

    /// `range` is in the old text. A \r before the edit can join with a \n in it, so that line counts too.
    public static func between(before: LineTable, after: LineTable, range: NSRange, newLength: Int, precededByCR: Bool) -> LineEdit {
        var start = before.line(containing: range.location)
        var oldEnd = before.line(containing: NSMaxRange(range))
        var newEnd = after.line(containing: range.location + newLength)
        // A text view reports a keystroke as the whole line with its ending. Stopping exactly at the
        // start of a line, both before and after, leaves that line alone.
        if range.length > 0, newLength > 0, oldEnd > start, newEnd > start,
           before.starts[oldEnd] == NSMaxRange(range), after.starts[newEnd] == range.location + newLength {
            oldEnd -= 1
            newEnd -= 1
        }
        if precededByCR, start > 0 { start -= 1 }
        return LineEdit(start: start, removed: oldEnd - start, inserted: newEnd - start)
    }
}

/// A copy of some text kept up to date one edit at a time, for anyone off the main thread or in
/// another process who needs to read it, or to say where an edit was.
public final class TextMirror {
    public private(set) var text: NSMutableString
    public private(set) var lines: LineTable

    public init(_ string: String) {
        text = NSMutableString(string: string)
        lines = LineTable(text)
    }

    public var length: Int { text.length }

    public func replaceAll(_ string: String) {
        text = NSMutableString(string: string)
        lines = LineTable(text)
    }

    /// `range` is in the text as it stands.
    @discardableResult
    public func apply(range: NSRange, replacement: String) -> LineEdit {
        let before = lines
        let precededByCR = range.location > 0 && text.character(at: range.location - 1) == 13
        text.replaceCharacters(in: range, with: replacement)
        let newLength = (replacement as NSString).length
        lines.update(editedRange: NSRange(location: range.location, length: newLength), delta: newLength - range.length, in: text)
        return LineEdit.between(before: before, after: lines, range: range, newLength: newLength, precededByCR: precededByCR)
    }

    /// Line and UTF-16 character, each counting from 0.
    public func position(of offset: Int) -> (line: Int, character: Int) {
        let line = lines.line(containing: offset)
        return (line, offset - lines.starts[line])
    }
}
