import Foundation

/// What changed between two versions of a file, as the few replacements that turn one into the other. An
/// agent rewriting a file that's open changes it through these, so text it didn't touch, and the cursor and
/// scroll on it, stay where they were, and undo can take the change back.
public enum ChangedText {
    /// In UTF-16 offsets into `old`, first to last, none overlapping. The common start and end are
    /// left alone, and between them whole lines are compared, up to `lineLimit` lines on a side; past it,
    /// the middle is one replacement.
    /// The limit keeps it fast on the main thread: comparing lines costs their count times how many differ.
    public static func changes(from old: NSString, to new: NSString, lineLimit: Int = 3_000) -> [TextChange] {
        guard !old.isEqual(to: new as String) else { return [] }
        let a = units(old), b = units(new)
        var prefix = 0
        let shorter = min(a.count, b.count)
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Out to whole lines, so the lines are compared as lines.
        var start = prefix
        while start > 0, !isBreak(a[start - 1]) { start -= 1 }
        // The end kept is the start of a line in both: what comes just before it is common, and a line break
        // that isn't the first half of CR LF.
        var tail = suffix
        while tail > 0 {
            let at = a.count - tail
            if tail < suffix, isBreak(a[at - 1]), !(a[at - 1] == 13 && a[at] == 10) { break }
            tail -= 1
        }
        let oldMiddle = NSRange(location: start, length: a.count - tail - start)
        let newMiddle = NSRange(location: start, length: b.count - tail - start)
        let whole = [TextChange(range: oldMiddle, text: new.substring(with: newMiddle))]
        let oldLines = lines(old, in: oldMiddle), newLines = lines(new, in: newMiddle)
        guard oldLines.count <= lineLimit, newLines.count <= lineLimit else { return whole }
        let difference = newLines.map(\.text).difference(from: oldLines.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var found: [TextChange] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            guard removed.contains(i) || inserted.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let (i0, j0) = (i, j)
            while removed.contains(i) || inserted.contains(j) {
                if removed.contains(i) { i += 1 }
                if inserted.contains(j) { j += 1 }
            }
            let from = i0 < oldLines.count ? oldLines[i0].range.location : NSMaxRange(oldMiddle)
            let to = i < oldLines.count ? oldLines[i].range.location : NSMaxRange(oldMiddle)
            found.append(TextChange(range: NSRange(location: from, length: to - from), text: newLines[j0..<j].map(\.text).joined()))
        }
        return found.isEmpty ? whole : found
    }

    /// Where `location` in the old text is once the changes are made: after a change it moves with the text
    /// after it, and inside one it goes to where that change starts.
    public static func moved(_ location: Int, by changes: [TextChange]) -> Int {
        var shift = 0
        for change in changes {
            if NSMaxRange(change.range) <= location {
                shift += (change.text as NSString).length - change.range.length
            } else if change.range.location < location {
                return change.range.location + shift
            } else {
                break
            }
        }
        return location + shift
    }

    /// Two versions compared line by line, as the diff viewer shows git's: hunks with `context` lines around
    /// each change. Needs no git, so it works for text that isn't in a file, like edits not saved yet.
    public static func fileDiff(from old: String, to new: String, context: Int = 3) -> FileDiff {
        func split(_ text: String) -> [String] {
            var lines: [String] = []
            (text as NSString).enumerateLines { line, _ in lines.append(line) }
            return lines
        }
        let a = split(old), b = split(new)
        guard a != b else { return FileDiff() }
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Every line in order, then cut into hunks.
        var all: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if removed.contains(i) {
                all.append(DiffLine(kind: .removed, oldLine: i + 1, text: a[i]))
                i += 1
            } else if inserted.contains(j) {
                all.append(DiffLine(kind: .added, newLine: j + 1, text: b[j]))
                j += 1
            } else if i < a.count, j < b.count {
                all.append(DiffLine(kind: .context, oldLine: i + 1, newLine: j + 1, text: a[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        let changed = all.indices.filter { all[$0].kind != .context }
        var result = FileDiff()
        var index = 0
        while index < changed.count {
            let first = max(changed[index] - context, 0)
            var last = changed[index]
            while index + 1 < changed.count, changed[index + 1] - last <= context * 2 + 1 {
                index += 1
                last = changed[index]
            }
            last = min(last + context, all.count - 1)
            let lines = Array(all[first...last])
            let oldStart = lines.compactMap(\.oldLine).first ?? (all[..<first].compactMap(\.oldLine).last ?? 0)
            let newStart = lines.compactMap(\.newLine).first ?? (all[..<first].compactMap(\.newLine).last ?? 0)
            let oldCount = lines.filter { $0.kind != .added }.count, newCount = lines.filter { $0.kind != .removed }.count
            result.lines.append(DiffLine(kind: .hunk, text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"))
            result.lines += lines
            index += 1
        }
        return result
    }

    private static func units(_ string: NSString) -> [unichar] {
        var buffer = [unichar](repeating: 0, count: string.length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: string.length))
        return buffer
    }

    private static func isBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    private static func lines(_ string: NSString, in range: NSRange) -> [(range: NSRange, text: String)] {
        var found: [(NSRange, String)] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            var lineEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: location, length: 0))
            lineEnd = min(max(lineEnd, location + 1), end)
            let line = NSRange(location: location, length: lineEnd - location)
            found.append((line, string.substring(with: line)))
            location = lineEnd
        }
        return found
    }
}
