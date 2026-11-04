import Foundation

/// One row of a side-by-side diff: indexes into the diff's lines.
public struct SideBySideRow: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public init(left: Int?, right: Int?) {
        self.left = left
        self.right = right
    }
}

public enum DiffRows {
    /// Old on the left and new on the right. A change's rows line up, with blanks for whichever side has fewer.
    public static func sideBySide(_ lines: [DiffLine]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        rows.reserveCapacity(lines.count)
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(SideBySideRow(left: index < removed.count ? removed[index] : nil,
                                          right: index < added.count ? added[index] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .removed: removed.append(index)
            case .added: added.append(index)
            case .context, .hunk:
                flush()
                rows.append(SideBySideRow(left: index, right: index))
            }
        }
        flush()
        return rows
    }

    /// Each removed row with the added row it became, both ways round.
    public static func pairs(_ lines: [DiffLine]) -> [Int: Int] {
        var pairs: [Int: Int] = [:]
        for row in sideBySide(lines) {
            if let left = row.left, let right = row.right, left != right {
                pairs[left] = right
                pairs[right] = left
            }
        }
        return pairs
    }

    /// The first row of each run of changed rows.
    public static func changeStarts(_ lines: [DiffLine]) -> [Int] {
        var starts: [Int] = []
        var inChange = false
        for (index, line) in lines.enumerated() {
            let changed = line.kind == .added || line.kind == .removed
            if changed, !inChange { starts.append(index) }
            inChange = changed
        }
        return starts
    }

    /// The change at or after a line of the file: its first row, removed rows included.
    public static func changeRow(atOrAfterLine line: Int, in lines: [DiffLine]) -> Int? {
        var lastNew = 0
        for (index, row) in lines.enumerated() {
            switch row.kind {
            case .hunk: continue
            case .context: lastNew = row.newLine ?? lastNew
            case .added:
                if (row.newLine ?? 0) >= line { return index }
                lastNew = row.newLine ?? lastNew
            case .removed:
                if lastNew + 1 >= line { return index }
            }
        }
        return nil
    }
}

// MARK: - Word-level changes

/// Which parts of a changed line changed, so the eye goes to them rather than the whole line.
public enum WordDiff {
    /// Longer lines aren't compared word by word: it's slow, and rarely readable anyway.
    public static let longestLine = 2_000
    /// With less than this share kept, the lines are simply different, and the row's color says that.
    private static let leastKept = 0.3

    public struct Ranges: Equatable, Sendable {
        public var old: [NSRange]
        public var new: [NSRange]
        public init(old: [NSRange] = [], new: [NSRange] = []) {
            self.old = old
            self.new = new
        }
    }

    public static func ranges(old: String, new: String) -> Ranges {
        guard old != new, old.utf16.count <= longestLine, new.utf16.count <= longestLine else { return Ranges() }
        let a = tokens(old)
        let b = tokens(new)
        guard !a.isEmpty, !b.isEmpty else { return Ranges() }
        let kept = longestCommon(a.map(\.text), b.map(\.text))
        var keptLength = 0
        var oldKept = [Bool](repeating: false, count: a.count)
        var newKept = [Bool](repeating: false, count: b.count)
        for (i, j) in kept {
            oldKept[i] = true
            newKept[j] = true
            keptLength += a[i].range.length
        }
        // Whitespace matches too easily to count as having something in common.
        let meaningful = kept.reduce(0) { $0 + (a[$1.0].isSpace ? 0 : a[$1.0].range.length) }
        let total = max(a.reduce(0) { $0 + ($1.isSpace ? 0 : $1.range.length) }, b.reduce(0) { $0 + ($1.isSpace ? 0 : $1.range.length) })
        if total > 0, Double(meaningful) / Double(total) < leastKept { return Ranges() }
        return Ranges(old: merged(a, kept: oldKept), new: merged(b, kept: newKept))
    }

    private struct Token {
        var text: Substring
        var range: NSRange
        var isSpace: Bool
    }

    /// Words, runs of spaces, and each other character alone. Offsets are in UTF-16, which is what text views use.
    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var offset = 0
        var index = text.startIndex
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .other
        }
        while index < text.endIndex {
            let start = index
            let startOffset = offset
            let kind = classify(text[index])
            offset += text[index].utf16.count
            index = text.index(after: index)
            if kind != .other {
                while index < text.endIndex, classify(text[index]) == kind {
                    offset += text[index].utf16.count
                    index = text.index(after: index)
                }
            }
            result.append(Token(text: text[start..<index], range: NSRange(location: startOffset, length: offset - startOffset), isSpace: kind == .space))
        }
        return result
    }

    /// Runs of tokens that weren't kept. A space between two changed words joins them: two
    /// highlights a space apart read worse than one.
    private static func merged(_ tokens: [Token], kept: [Bool]) -> [NSRange] {
        var result: [NSRange] = []
        var index = 0
        while index < tokens.count {
            guard !kept[index] else {
                index += 1
                continue
            }
            var last = index
            var next = index + 1
            while next < tokens.count {
                if !kept[next] {
                    last = next
                } else if !(tokens[next].isSpace && next + 1 < tokens.count && !kept[next + 1]) {
                    break
                }
                next += 1
            }
            let start = tokens[index].range.location
            result.append(NSRange(location: start, length: NSMaxRange(tokens[last].range) - start))
            index = last + 1
        }
        return result
    }

    /// Longest common subsequence, as pairs of indexes. Lines are capped, so plain dynamic programming is enough.
    static func longestCommon(_ a: [Substring], _ b: [Substring]) -> [(Int, Int)] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var pairs = (0..<prefix).map { ($0, $0) }
        let (m, n) = (a.count - prefix - suffix, b.count - prefix - suffix)
        if m > 0, n > 0 {
            let width = n + 1
            var table = [Int32](repeating: 0, count: (m + 1) * width)
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    table[i * width + j] = a[prefix + i] == b[prefix + j]
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
            var (i, j) = (0, 0)
            while i < m, j < n {
                if a[prefix + i] == b[prefix + j] {
                    pairs.append((prefix + i, prefix + j))
                    i += 1
                    j += 1
                } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        pairs += (0..<suffix).map { (a.count - suffix + $0, b.count - suffix + $0) }
        return pairs
    }
}
