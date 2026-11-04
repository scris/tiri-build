import Foundation
import Markdown

/// Finds math in markdown source before the markdown parser can read `a_b` as emphasis or `\(` as
/// a plain bracket. Each piece of math becomes a token the parser leaves alone, on the same line,
/// so source line numbers stay true.
enum MathText {
    struct Span {
        var token: String
        var tex: String
        var display: Bool
        /// As written, with its delimiters.
        var original: String
        /// The line it ends on, counting from zero, when that's later than where it starts.
        var endLine: Int?
    }

    struct Extracted {
        var markdown: String
        var spans: [Span]
    }

    private static let tokenPrefix = "TIRIMATHZ"

    /// True when no scan is needed at all, which is most documents.
    static func cannotContainMath(_ source: String) -> Bool {
        var previous: UInt8 = 0
        for byte in source.utf8 {
            if byte == UInt8(ascii: "$") { return false }
            if previous == UInt8(ascii: "\\"), byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") { return false }
            previous = byte
        }
        return true
    }

    static func extract(_ source: String) -> Extracted {
        if cannotContainMath(source) || source.contains(tokenPrefix) { return Extracted(markdown: source, spans: []) }
        var scanner = Scanner(source: source, protected: protectedLines(source))
        scanner.run()
        return Extracted(markdown: String(decoding: scanner.output, as: UTF8.self), spans: scanner.spans)
    }

    /// Lines the parser says are code or raw HTML, counting from zero. Math isn't looked for there.
    private static func protectedLines(_ source: String) -> Set<Int> {
        var lines = Set<Int>()
        func walk(_ node: Markup) {
            if node is CodeBlock || node is HTMLBlock {
                guard let range = node.range else { return }
                let last = range.upperBound.column == 1 ? range.upperBound.line - 1 : range.upperBound.line
                if last >= range.lowerBound.line { lines.formUnion((range.lowerBound.line - 1)...(last - 1)) }
                return
            }
            for child in node.children { walk(child) }
        }
        walk(Document(parsing: source))
        return lines
    }

    /// Puts rendered math where the tokens are. Inside a tag, like an image's title, only the
    /// source text can go.
    static func restore(_ html: String, spans: [Span], render: (Span) -> String) -> String {
        guard !spans.isEmpty else { return html }
        let prefix = Array(tokenPrefix.utf8)
        let bytes = Array(html.utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var inTag = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") { inTag = true }
            if byte == UInt8(ascii: ">") { inTag = false }
            if byte == prefix[0], index + prefix.count < bytes.count, bytes[index..<(index + prefix.count)].elementsEqual(prefix) {
                var end = index + prefix.count
                var number = 0
                while end < bytes.count, bytes[end] >= 48, bytes[end] <= 57 {
                    number = number * 10 + Int(bytes[end] - 48)
                    end += 1
                }
                if end < bytes.count, bytes[end] == UInt8(ascii: "Z"), number < spans.count {
                    let span = spans[number]
                    output += Array((inTag ? MarkdownRenderer.escapeAttribute(span.original) : render(span)).utf8)
                    index = end + 1
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// What a token stood for, for places that want text: a heading's anchor.
    static func sourceText(_ text: String, spans: [Span]) -> String {
        guard !spans.isEmpty else { return text }
        var result = text
        for span in spans where result.contains(span.token) {
            result = result.replacingOccurrences(of: span.token, with: span.original)
        }
        return result
    }

    private struct Scanner {
        let bytes: [UInt8]
        let protected: Set<Int>
        var output: [UInt8] = []
        var spans: [Span] = []
        private var lineStarts: [Int] = [0]

        init(source: String, protected: Set<Int>) {
            bytes = Array(source.utf8)
            self.protected = protected
            for (index, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(index + 1) }
            output.reserveCapacity(bytes.count)
        }

        /// Blank lines and code end a run of lines. Math and code spans never cross one.
        mutating func run() {
            var line = 0
            while line < lineStarts.count {
                if isBreak(line) {
                    copyLine(line)
                    line += 1
                    continue
                }
                var last = line
                while last + 1 < lineStarts.count, !isBreak(last + 1) { last += 1 }
                let end = last + 1 < lineStarts.count ? lineStarts[last + 1] : bytes.count
                scan(from: lineStarts[line], to: end)
                line = last + 1
            }
        }

        private func isBreak(_ line: Int) -> Bool {
            if protected.contains(line) { return true }
            var index = lineStarts[line]
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count
            while index < end {
                let byte = bytes[index]
                if byte != 32, byte != 9, byte != 13, byte != 10 { return false }
                index += 1
            }
            return true
        }

        private mutating func copyLine(_ line: Int) {
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count
            output += bytes[lineStarts[line]..<end]
        }

        private mutating func scan(from low: Int, to high: Int) {
            var index = low
            var copied = low
            while index < high {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    let next = index + 1 < high ? bytes[index + 1] : 0
                    if next == UInt8(ascii: "("), let close = findClosing(UInt8(ascii: ")"), from: index + 2, to: high) {
                        output += bytes[copied..<index]
                        emit(from: index, to: close + 2, tex: (index + 2)..<close, display: false)
                        index = close + 2
                        copied = index
                    } else if next == UInt8(ascii: "["), startsLine(index),
                              let close = findClosing(UInt8(ascii: "]"), from: index + 2, to: high), endsLine(close + 2, high) {
                        output += bytes[copied..<index]
                        emit(from: index, to: close + 2, tex: (index + 2)..<close, display: true)
                        index = close + 2
                        copied = index
                    } else {
                        index += 2
                    }
                case UInt8(ascii: "`"):
                    let run = runLength(of: UInt8(ascii: "`"), at: index, to: high)
                    index = closingBackticks(run, from: index + run, to: high) ?? index + run
                case UInt8(ascii: "$"):
                    let run = runLength(of: UInt8(ascii: "$"), at: index, to: high)
                    if run == 2, let close = findDisplayClose(from: index + 2, to: high) {
                        output += bytes[copied..<index]
                        emit(from: index, to: close + 2, tex: (index + 2)..<close, display: true)
                        index = close + 2
                        copied = index
                    } else if run == 1, let close = findInlineClose(open: index, to: high) {
                        output += bytes[copied..<index]
                        emit(from: index, to: close + 1, tex: (index + 1)..<close, display: false)
                        index = close + 1
                        copied = index
                    } else {
                        index += run
                    }
                default:
                    index += 1
                }
            }
            output += bytes[copied..<min(high, bytes.count)]
        }

        private func runLength(of byte: UInt8, at index: Int, to high: Int) -> Int {
            var end = index
            while end < high, bytes[end] == byte { end += 1 }
            return end - index
        }

        /// CommonMark: a code span ends at the next run of exactly as many backticks.
        private func closingBackticks(_ run: Int, from start: Int, to high: Int) -> Int? {
            var index = start
            while index < high {
                if bytes[index] == UInt8(ascii: "`") {
                    let length = runLength(of: UInt8(ascii: "`"), at: index, to: high)
                    if length == run { return index + length }
                    index += length
                } else {
                    index += 1
                }
            }
            return nil
        }

        /// Finds `\)` or `\]`, stepping over other escapes so `\\)` is a line break and a bracket.
        private func findClosing(_ bracket: UInt8, from start: Int, to high: Int) -> Int? {
            var index = start
            while index + 1 < high {
                if bytes[index] == UInt8(ascii: "\\") {
                    if bytes[index + 1] == bracket { return index }
                    index += 2
                } else {
                    index += 1
                }
            }
            return nil
        }

        private func findDisplayClose(from start: Int, to high: Int) -> Int? {
            var index = start
            var hasContent = false
            while index + 1 < high {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\\") {
                    hasContent = true
                    index += 2
                } else if byte == UInt8(ascii: "$") {
                    guard bytes[index + 1] == UInt8(ascii: "$"), hasContent else { return nil }
                    return index
                } else {
                    if byte != 32, byte != 10, byte != 13, byte != 9 { hasContent = true }
                    index += 1
                }
            }
            return nil
        }

        /// `$` is math only when it can't be money or a shell variable: something right after the
        /// opener, something right before the closer, no word touching the outside, one line.
        private func findInlineClose(open: Int, to high: Int) -> Int? {
            if open > 0, isWord(bytes[open - 1]) { return nil }
            guard open + 1 < high, !isSpace(bytes[open + 1]) else { return nil }
            var index = open + 1
            var hasBackslash = false
            while index < high {
                let byte = bytes[index]
                if byte == 10 || byte == UInt8(ascii: "`") { return nil }
                if byte == UInt8(ascii: "\\") {
                    hasBackslash = true
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "$") {
                    guard !isSpace(bytes[index - 1]) else { return nil }
                    if index + 1 < high, bytes[index + 1] == UInt8(ascii: "$") || isWord(bytes[index + 1]) { return nil }
                    if !hasBackslash, readsLikeProse(open + 1, index) { return nil }
                    return index
                }
                index += 1
            }
            return nil
        }

        /// `$5 to 10$` starts with a number and then has words in it. `$2x + 3y$` doesn't.
        private func readsLikeProse(_ start: Int, _ end: Int) -> Bool {
            guard bytes[start] >= 48, bytes[start] <= 57 else { return false }
            var letters = 0
            for byte in bytes[start..<end] {
                let isLetter = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                letters = isLetter ? letters + 1 : 0
                if letters >= 2 { return true }
            }
            return false
        }

        private func isWord(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }

        private func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

        private func lineIndex(_ offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }

        /// What's before this on its line, if that's only indentation and quote marks.
        private func linePrefix(_ offset: Int) -> ArraySlice<UInt8>? {
            let start = lineStarts[lineIndex(offset)]
            let prefix = bytes[start..<offset]
            return prefix.allSatisfy { $0 == 32 || $0 == 9 || $0 == UInt8(ascii: ">") } ? prefix : nil
        }

        private func startsLine(_ offset: Int) -> Bool { linePrefix(offset) != nil }

        private func endsLine(_ offset: Int, _ high: Int) -> Bool {
            var index = offset
            while index < high, bytes[index] != 10 {
                if !isSpace(bytes[index]) { return false }
                index += 1
            }
            return true
        }

        private mutating func emit(from start: Int, to end: Int, tex range: Range<Int>, display: Bool) {
            let token = "\(tokenPrefix)\(spans.count)Z"
            let firstLine = lineIndex(start)
            let lastLine = lineIndex(max(end - 1, start))
            let prefix = linePrefix(start)
            let isQuoted = prefix?.contains(UInt8(ascii: ">")) ?? false
            var tex = String(decoding: bytes[range], as: UTF8.self)
            var original = String(decoding: bytes[start..<end], as: UTF8.self)
            if isQuoted, lastLine > firstLine {
                tex = Self.removingQuoteMarks(tex)
                original = Self.removingQuoteMarks(original)
            }
            spans.append(Span(token: token, tex: tex.trimmingCharacters(in: .whitespacesAndNewlines), display: display,
                              original: original, endLine: lastLine > firstLine ? lastLine : nil))
            output += Array(token.utf8)
            // The lines it took stay in the file, so everything below keeps its line number.
            for _ in 0..<(lastLine - firstLine) {
                output.append(10)
                if isQuoted, let prefix { output += prefix }
            }
        }

        private static func removingQuoteMarks(_ text: String) -> String {
            text.components(separatedBy: "\n").map { line in
                String(line.drop { $0 == " " || $0 == "\t" || $0 == ">" })
            }.joined(separator: "\n")
        }
    }
}
