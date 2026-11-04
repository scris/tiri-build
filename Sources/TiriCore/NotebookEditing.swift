import Foundation

/// Changes to a notebook's file that touch only the bytes they're about. Decoding and re-encoding
/// would rewrite the whole file in a new layout, and a one-word edit would show as a diff of everything.
public enum NotebookEditing {
    public enum Failure: Error, Equatable {
        case notANotebook
        case noSuchCell
        /// Someone else changed this cell since it was read.
        case changedMeanwhile
    }

    public enum NewCell: Sendable { case code, markdown }

    public static func replacingSource(in data: Data, cell index: Int, expecting expected: String?, with source: String) throws(Failure) -> Data {
        let bytes = [UInt8](data)
        let cell = try cellRange(in: bytes, index: index)
        guard let range = member("source", of: cell, in: bytes) else { throw .noSuchCell }
        if let expected, sourceText(bytes, range) != expected { throw .changedMeanwhile }
        let indent = indentation(before: member(key: "source", of: cell, in: bytes)?.lowerBound ?? range.lowerBound, in: bytes)
        return splice(bytes, range, with: encodeLines(source, indent: indent, step: detectStep(bytes)))
    }

    /// Goes after `index`, or first with -1.
    public static func insertingCell(in data: Data, after index: Int, kind: NewCell) throws(Failure) -> Data {
        let bytes = [UInt8](data)
        let cells = try cellRanges(in: bytes)
        guard index >= -1, index < cells.ranges.count else { throw .noSuchCell }
        let step = detectStep(bytes)
        let cellIndent = cells.ranges.first.map { indentation(before: $0.lowerBound, in: bytes) } ?? cells.indent + String(repeating: " ", count: step)
        let inner = cellIndent + String(repeating: " ", count: step)
        // The format has required cells to have an ID since 4.5.
        let id = String(UUID().uuidString.lowercased().prefix(8))
        var members = ["\"cell_type\": \"\(kind == .code ? "code" : "markdown")\""]
        if kind == .code { members.append("\"execution_count\": null") }
        if usesCellIDs(bytes) { members.append("\"id\": \"\(id)\"") }
        members.append("\"metadata\": {}")
        if kind == .code { members.append("\"outputs\": []") }
        members.append("\"source\": []")
        let cell = "{\n" + members.map { inner + $0 }.joined(separator: ",\n") + "\n" + cellIndent + "}"
        if cells.ranges.isEmpty {
            let closing = "\n" + cells.indent
            return splice(bytes, cells.body, with: "[\n" + cellIndent + cell + closing + "]")
        }
        if index == -1 {
            let first = cells.ranges[0].lowerBound
            return splice(bytes, first..<first, with: cell + ",\n" + cellIndent)
        }
        let end = cells.ranges[index].upperBound
        return splice(bytes, end..<end, with: ",\n" + cellIndent + cell)
    }

    public static func deletingCell(in data: Data, cell index: Int) throws(Failure) -> Data {
        let bytes = [UInt8](data)
        let cells = try cellRanges(in: bytes)
        guard cells.ranges.indices.contains(index) else { throw .noSuchCell }
        if cells.ranges.count == 1 { return splice(bytes, cells.body, with: "[]") }
        // With the comma and the white space that belong to it.
        let range = index + 1 < cells.ranges.count
            ? cells.ranges[index].lowerBound..<cells.ranges[index + 1].lowerBound
            : cells.ranges[index - 1].upperBound..<cells.ranges[index].upperBound
        return splice(bytes, range, with: "")
    }

    /// Every code cell's outputs and count, or just the one's.
    public static func clearingOutputs(in data: Data, cell index: Int? = nil) throws(Failure) -> Data {
        var bytes = [UInt8](data)
        let cells = try cellRanges(in: bytes)
        if let index, !cells.ranges.indices.contains(index) { throw .noSuchCell }
        // Backwards, so an edit doesn't move what's still to come.
        for position in cells.ranges.indices.reversed() where index == nil || position == index {
            let cell = cells.ranges[position]
            var edits: [(Range<Int>, String)] = []
            if let range = member("outputs", of: cell, in: bytes) { edits.append((range, "[]")) }
            if let range = member("execution_count", of: cell, in: bytes) { edits.append((range, "null")) }
            for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                bytes.replaceSubrange(range, with: Array(text.utf8))
            }
        }
        return Data(bytes)
    }

    private static func splice(_ bytes: [UInt8], _ range: Range<Int>, with text: String) -> Data {
        var result = bytes
        result.replaceSubrange(range, with: Array(text.utf8))
        return Data(result)
    }

    private static func usesCellIDs(_ bytes: [UInt8]) -> Bool {
        var position = 0
        guard let root = skipValue(bytes, &position, start: true),
              let minor = member("nbformat_minor", of: root, in: bytes),
              let major = member("nbformat", of: root, in: bytes),
              let minorValue = Int(String(decoding: bytes[minor], as: UTF8.self)),
              let majorValue = Int(String(decoding: bytes[major], as: UTF8.self)) else { return true }
        return majorValue > 4 || (majorValue == 4 && minorValue >= 5)
    }

    /// How much the file indents per level: nbformat uses one space, others two or four.
    private static func detectStep(_ bytes: [UInt8]) -> Int {
        var position = 0
        guard let root = skipValue(bytes, &position, start: true), let key = member(key: "cells", of: root, in: bytes) else { return 1 }
        return max(indentation(before: key.lowerBound, in: bytes).count, 1)
    }

    /// Text is stored as lines, each keeping its newline, the way the format's own writers do it.
    private static func encodeLines(_ source: String, indent: String, step: Int) -> String {
        if source.isEmpty { return "[]" }
        var lines: [String] = []
        var current = ""
        for character in source {
            current.append(character)
            if character == "\n" || character == "\r\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        let inner = indent + String(repeating: " ", count: step)
        return "[\n" + lines.map { inner + encodeString($0) }.joined(separator: ",\n") + "\n" + indent + "]"
    }

    static func encodeString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func sourceText(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) else { return "" }
        if let text = value as? String { return text }
        return (value as? [Any])?.compactMap { $0 as? String }.joined() ?? ""
    }

    private static func indentation(before position: Int, in bytes: [UInt8]) -> String {
        var start = position
        while start > 0, bytes[start - 1] == 32 { start -= 1 }
        return start == 0 || bytes[start - 1] == 10 ? String(repeating: " ", count: position - start) : ""
    }

    // MARK: Finding things without decoding them

    private static func cellRange(in bytes: [UInt8], index: Int) throws(Failure) -> Range<Int> {
        let cells = try cellRanges(in: bytes)
        guard cells.ranges.indices.contains(index) else { throw .noSuchCell }
        return cells.ranges[index]
    }

    private static func cellRanges(in bytes: [UInt8]) throws(Failure) -> (ranges: [Range<Int>], body: Range<Int>, indent: String) {
        var position = 0
        guard let root = skipValue(bytes, &position, start: true), bytes[root.lowerBound] == UInt8(ascii: "{"),
              let body = member("cells", of: root, in: bytes), bytes[body.lowerBound] == UInt8(ascii: "["),
              let key = member(key: "cells", of: root, in: bytes) else { throw .notANotebook }
        var ranges: [Range<Int>] = []
        var cursor = body.lowerBound + 1
        while true {
            skipSpace(bytes, &cursor)
            guard cursor < body.upperBound - 1 else { break }
            guard let value = skipValue(bytes, &cursor) else { throw .notANotebook }
            ranges.append(value)
            skipSpace(bytes, &cursor)
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ",") { cursor += 1 }
        }
        return (ranges, body, indentation(before: key.lowerBound, in: bytes))
    }

    private static func member(_ name: String, of object: Range<Int>, in bytes: [UInt8]) -> Range<Int>? {
        members(of: object, in: bytes).first { $0.name == name }?.value
    }

    private static func member(key name: String, of object: Range<Int>, in bytes: [UInt8]) -> Range<Int>? {
        members(of: object, in: bytes).first { $0.name == name }?.key
    }

    private static func members(of object: Range<Int>, in bytes: [UInt8]) -> [(name: String, key: Range<Int>, value: Range<Int>)] {
        var result: [(String, Range<Int>, Range<Int>)] = []
        guard bytes[object.lowerBound] == UInt8(ascii: "{") else { return [] }
        var cursor = object.lowerBound + 1
        while cursor < object.upperBound - 1 {
            skipSpace(bytes, &cursor)
            guard cursor < object.upperBound - 1, bytes[cursor] == UInt8(ascii: "\""), let key = skipValue(bytes, &cursor) else { break }
            skipSpace(bytes, &cursor)
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { break }
            cursor += 1
            skipSpace(bytes, &cursor)
            guard let value = skipValue(bytes, &cursor) else { break }
            let name = (try? JSONSerialization.jsonObject(with: Data(bytes[key]), options: .fragmentsAllowed)) as? String ?? ""
            result.append((name, key, value))
            skipSpace(bytes, &cursor)
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ",") { cursor += 1 }
        }
        return result
    }

    private static func skipSpace(_ bytes: [UInt8], _ cursor: inout Int) {
        while cursor < bytes.count, [32, 10, 13, 9].contains(bytes[cursor]) { cursor += 1 }
    }

    /// Moves past one JSON value, whatever's in it, and says where it was.
    private static func skipValue(_ bytes: [UInt8], _ cursor: inout Int, start: Bool = false) -> Range<Int>? {
        skipSpace(bytes, &cursor)
        guard cursor < bytes.count else { return nil }
        let begin = cursor
        switch bytes[cursor] {
        case UInt8(ascii: "\""):
            cursor += 1
            while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "\"") {
                cursor += bytes[cursor] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard cursor < bytes.count else { return nil }
            cursor += 1
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte == UInt8(ascii: "\"") {
                    guard skipValue(bytes, &cursor) != nil else { return nil }
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
                cursor += 1
                if depth == 0 { break }
            }
            guard depth == 0 else { return nil }
        default:
            while cursor < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 32, 10, 13, 9].contains(bytes[cursor]) { cursor += 1 }
        }
        return begin..<cursor
    }
}
