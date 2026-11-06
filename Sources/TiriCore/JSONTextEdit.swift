import Foundation

/// Changes to a JSON file made as small edits to its text, the way VS Code edits settings: everything
/// that isn't changed keeps its order, spacing, line endings and digits. Only strict JSON is read.
enum JSONTextEdit {
    struct Malformed: Error {}

    /// Where a value sits in the text, in UTF-8 bytes, and what's inside it.
    final class Node {
        enum Kind { case object, array, scalar }
        struct Member {
            var key: String
            var keyStart: Int
            var value: Node
        }

        let kind: Kind
        let start: Int
        fileprivate(set) var end = 0
        fileprivate(set) var members: [Member] = []
        fileprivate(set) var elements: [Node] = []

        init(kind: Kind, start: Int) {
            self.kind = kind
            self.start = start
        }

        /// The one a parser keeps when a key appears twice is the last.
        func member(_ key: String) -> Node? { members.last { $0.key == key }?.value }
        func memberIndex(_ key: String) -> Int? { members.lastIndex { $0.key == key } }

        /// Each child from its first byte (a member's key) to its last.
        var children: [(start: Int, end: Int)] {
            kind == .object ? members.map { ($0.keyStart, $0.value.end) } : elements.map { ($0.start, $0.end) }
        }
    }

    /// A value going in, with its keys in the order they're written.
    indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case bool(Bool)
    }

    struct Edit {
        var range: Range<Int>
        var text: String
    }

    struct Document {
        let bytes: [UInt8]
        let root: Node
        let newline: String
        /// One level of indentation, as the file already does it.
        let unit: String

        init(_ text: String) throws {
            bytes = Array(text.utf8)
            var scanner = Scanner(bytes: bytes)
            root = try scanner.value()
            scanner.skipSpace()
            guard scanner.index == bytes.count, root.kind == .object else { throw Malformed() }
            newline = text.contains("\r\n") ? "\r\n" : "\n"
            var unit = "  "
            if let first = root.children.first, Self.hasNewline(bytes, root.start + 1, first.start) {
                let outer = Self.lineIndent(bytes, at: root.start)
                let inner = Self.lineIndent(bytes, at: first.start)
                if inner.count > outer.count, inner.hasPrefix(outer) { unit = String(inner.dropFirst(outer.count)) }
            }
            self.unit = unit
        }

        func applying(_ edits: [Edit]) throws -> String {
            var result = bytes
            var limit = Int.max
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                guard edit.range.upperBound <= limit else { throw Malformed() }
                result.replaceSubrange(edit.range, with: Array(edit.text.utf8))
                limit = edit.range.lowerBound
            }
            return String(decoding: result, as: UTF8.self)
        }

        /// Adds children at the end of an object (with keys) or an array (without), laid out like
        /// the ones already there.
        func appending(_ items: [(key: String?, value: Value)], to node: Node) -> Edit {
            let multiline = isMultiline(node)
            func text(_ item: (key: String?, value: Value), indent: String) -> String {
                (item.key.map { Self.quoted($0) + ": " } ?? "") + render(item.value, indent: indent, multiline: multiline)
            }
            if let last = node.children.last {
                let indent = multiline ? Self.lineIndent(bytes, at: last.start) : ""
                let separator = multiline ? "," + newline + indent : ", "
                return Edit(range: last.end..<last.end, text: items.map { separator + text($0, indent: indent) }.joined())
            }
            let interior = (node.start + 1)..<(node.end - 1)
            guard multiline else { return Edit(range: interior, text: items.map { text($0, indent: "") }.joined(separator: ", ")) }
            let outer = Self.lineIndent(bytes, at: node.start)
            let inner = outer + unit
            let body = items.map { inner + text($0, indent: inner) }.joined(separator: "," + newline)
            return Edit(range: interior, text: newline + body + newline + outer)
        }

        /// Takes out these children with the comma and space that separated each, and nothing else.
        func removing(_ indices: Set<Int>, from node: Node) -> [Edit] {
            let children = node.children
            guard let lastKept = children.indices.last(where: { !indices.contains($0) }) else {
                return [Edit(range: (node.start + 1)..<(node.end - 1), text: "")]
            }
            var edits = indices.filter { $0 < lastKept }.map { Edit(range: children[$0].start..<children[$0 + 1].start, text: "") }
            if lastKept < children.count - 1 {
                edits.append(Edit(range: children[lastKept].end..<children[children.count - 1].end, text: ""))
            }
            return edits
        }

        private func isMultiline(_ node: Node) -> Bool {
            if let first = node.children.first { return Self.hasNewline(bytes, node.start + 1, first.start) }
            if node === root { return true }
            return Self.hasNewline(bytes, node.start + 1, node.end - 1) || isMultiline(root)
        }

        func render(_ value: Value, indent: String, multiline: Bool) -> String {
            let inner = indent + unit
            func wrap(_ open: String, _ parts: [String], _ close: String) -> String {
                guard !parts.isEmpty else { return open + close }
                guard multiline else { return open + parts.joined(separator: ", ") + close }
                return open + newline + parts.map { inner + $0 }.joined(separator: "," + newline) + newline + indent + close
            }
            switch value {
            case .string(let string): return Self.quoted(string)
            case .bool(let flag): return flag ? "true" : "false"
            case .array(let items): return wrap("[", items.map { render($0, indent: inner, multiline: multiline) }, "]")
            case .object(let members):
                return wrap("{", members.map { Self.quoted($0.0) + ": " + render($0.1, indent: inner, multiline: multiline) }, "}")
            }
        }

        static func quoted(_ string: String) -> String {
            var out = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }

        private static func hasNewline(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Bool {
            from < to && bytes[from..<to].contains(0x0A)
        }

        /// The spaces or tabs that start the line this byte is on.
        static func lineIndent(_ bytes: [UInt8], at position: Int) -> String {
            var start = position
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            var end = start
            while end < position, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func expect(_ byte: UInt8) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { throw Malformed() }
            index += 1
        }

        /// What comes next is `close`, or a comma and another child. A comma before `close` is
        /// allowed, as Foundation's parser allows it.
        private mutating func more(closing close: UInt8) throws -> Bool {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipSpace()
                guard index < bytes.count, bytes[index] == close else { return true }
            }
            guard bytes[index] == close else { throw Malformed() }
            index += 1
            return false
        }

        mutating func value() throws -> Node {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                let node = Node(kind: .object, start: start)
                index += 1
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                } else {
                    repeat {
                        skipSpace()
                        let keyStart = index
                        let key = try string()
                        try expect(UInt8(ascii: ":"))
                        node.members.append(.init(key: key, keyStart: keyStart, value: try value()))
                    } while try more(closing: UInt8(ascii: "}"))
                }
                node.end = index
                return node
            case UInt8(ascii: "["):
                let node = Node(kind: .array, start: start)
                index += 1
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                } else {
                    repeat {
                        node.elements.append(try value())
                    } while try more(closing: UInt8(ascii: "]"))
                }
                node.end = index
                return node
            case UInt8(ascii: "\""):
                _ = try string()
            default:
                while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[index]) {
                    index += 1
                }
                guard index > start else { throw Malformed() }
            }
            let node = Node(kind: .scalar, start: start)
            node.end = index
            return node
        }

        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
            let start = index
            var escaped = false
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    escaped = true
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let literal = bytes[start..<index]
                    guard escaped else { return String(decoding: literal.dropFirst().dropLast(), as: UTF8.self) }
                    guard let decoded = try? JSONSerialization.jsonObject(with: Data(literal), options: .fragmentsAllowed) as? String else { throw Malformed() }
                    return decoded
                default:
                    index += 1
                }
            }
            throw Malformed()
        }
    }
}
