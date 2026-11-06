import AppKit
import TiriCore
import TiriHighlight

extension TokenKind {
    /// The theme's color for this kind of code, looked up again each time it's drawn.
    var color: NSColor { ThemePalette.tokens[Int(rawValue)] }
}

/// Keeps one text view's colors. It tells the engine about each edit, stores what comes back line
/// by line, and only ever touches the lines on screen, so this costs the same in any size of file.
final class LineHighlighter {
    private weak var textView: NSTextView?
    private var scope: String?
    private var document: HighlightDocument?
    private var table = LineTable()
    private var tokens: [LineTokens?] = [nil]
    private var painted: [Bool] = [false]
    /// Counts every change. Lines the engine wrote before an edit it hadn't heard of get moved.
    private var sequence = 0
    private var edits: [(sequence: Int, edit: LineEdit)] = []
    /// Anything older than this was about text that's gone.
    private var oldestWanted = 0
    private var knownLength = 0
    private var shownLines: Range<Int>?
    private var observers: [NSObjectProtocol] = []

    /// Colored this far beyond the edge, so a small scroll doesn't show them arrive.
    private static let margin = 30

    init(textView: NSTextView) {
        self.textView = textView
    }

    isolated deinit {
        document?.close()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Scrolling and resizing bring other lines into view.
    private func watchScrolling() {
        guard observers.isEmpty, let scroll = textView?.enclosingScrollView else { return }
        let center = NotificationCenter.default
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        let repaint: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.paintVisible() }
        }
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main, using: repaint))
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main, using: repaint))
    }

    /// Which grammar, if any. Starts over if it's a different one.
    func use(language: LanguageDefinition?) {
        let wanted = language?.grammar
        guard wanted != scope else { return }
        scope = wanted
        document?.close()
        document = nil
        clearColors()
        guard let wanted else { return }
        document = HighlightDocument(scope: wanted) { [weak self] update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(update) }
            }
        }
        watchScrolling()
        textReplaced()
    }

    private func clearColors() {
        guard let textView, let layout = textView.layoutManager else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (textView.textStorage?.length ?? 0)))
    }

    /// All new text. A text storage in the middle of an edit can't be asked about its layout, so
    /// from there the painting waits.
    func textReplaced(paint: Bool = true) {
        guard let textView, let storage = textView.textStorage else { return }
        table = LineTable(storage.mutableString)
        knownLength = storage.length
        tokens = Array(repeating: nil, count: table.count)
        painted = Array(repeating: false, count: table.count)
        sequence += 1
        oldestWanted = sequence
        edits = []
        shownLines = nil
        document?.replaceAll(textView.string, sequence: sequence)
        if paint { paintVisible() }
    }

    /// From the text storage, as each edit happens. `range` is what's there now.
    func textEdited(range: NSRange, delta: Int, in storage: NSTextStorage) {
        let string = storage.mutableString
        let oldLength = range.length - delta
        if oldLength == knownLength || document == nil {
            // Without a grammar there's nobody to keep up to date, and the numbers wait until there is.
            if document == nil { knownLength = storage.length } else { textReplaced(paint: false) }
            return
        }
        let before = table
        let precededByCR = range.location > 0 && string.character(at: range.location - 1) == 13
        table.update(editedRange: range, delta: delta, in: string)
        knownLength = storage.length
        let oldRange = NSRange(location: range.location, length: oldLength)
        let edit = LineEdit.between(before: before, after: table, range: oldRange, newLength: range.length, precededByCR: precededByCR)
        guard edit.start + edit.removed < tokens.count else {
            textReplaced(paint: false)
            return
        }
        // Typing within a line: what's known stays roughly right until the real answer arrives, so
        // nothing flickers, and it's still known whether this is a string or a comment.
        if edit.removed == 0, edit.inserted == 0, let line = tokens[edit.start] {
            let column = range.location - table.starts[edit.start]
            tokens[edit.start] = shiftedTokens(line, column: column, removed: oldLength, inserted: range.length)
            painted[edit.start] = false
            sequence += 1
            edits.append((sequence, edit))
            document?.edit(range: oldRange, replacement: string.substring(with: range), sequence: sequence)
            DispatchQueue.main.async { [weak self] in self?.paintVisible() }
            return
        }
        let fresh = edit.start..<(edit.start + edit.inserted + 1)
        tokens.replaceSubrange(edit.start..<(edit.start + edit.removed + 1), with: fresh.map { _ in nil })
        painted.replaceSubrange(edit.start..<(edit.start + edit.removed + 1), with: fresh.map { _ in false })
        sequence += 1
        edits.append((sequence, edit))
        document?.edit(range: oldRange, replacement: string.substring(with: range), sequence: sequence)
    }

    private func receive(_ update: HighlightDocument.Update) {
        guard update.sequence >= oldestWanted, document != nil else { return }
        edits.removeAll { $0.sequence <= update.sequence }
        // It and this have ended up seeing different lines. Everything again puts that right.
        if edits.isEmpty, update.lineCount != table.count {
            textReplaced()
            return
        }
        for (offset, line) in update.lines.enumerated() {
            var index = update.first + offset
            var gone = false
            for (_, edit) in edits {
                if index >= edit.start + edit.removed + 1 {
                    index += edit.inserted - edit.removed
                } else if index >= edit.start {
                    gone = true
                    break
                }
            }
            guard !gone, tokens.indices.contains(index) else { continue }
            tokens[index] = line
            painted[index] = false
        }
        paintVisible()
    }

    func paintVisible() {
        guard document != nil, let textView, textView.window != nil, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        // What the scroll view shows, not `visibleRect`: while a Peek grows open that's only a sliver.
        let shown = textView.enclosingScrollView?.documentVisibleRect ?? textView.visibleRect
        guard shown.height > 0 else { return }
        let glyphs = layout.glyphRange(forBoundingRect: shown, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = table.line(containing: characters.location)
        let last = table.line(containing: NSMaxRange(characters))
        let lines = first..<(last + 1)
        if lines != shownLines {
            shownLines = lines
            document?.show(lines: lines)
        }
        let lower = max(first - Self.margin, 0)
        let upper = min(last + Self.margin, table.count - 1)
        guard lower <= upper else { return }
        for index in lower...upper where !painted[index] {
            guard let line = tokens[index] else { continue }
            paint(line, at: index, in: layout)
            painted[index] = true
        }
    }

    private func paint(_ line: LineTokens, at index: Int, in layout: NSLayoutManager) {
        let start = table.starts[index]
        let end = index + 1 < table.count ? table.starts[index + 1] : knownLength
        let whole = NSRange(location: start, length: end - start)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for (position, entry) in line.enumerated() {
            let kind = TokenKind.of(entry)
            guard kind != .plain else { continue }
            let from = start + TokenKind.start(of: entry)
            let to = position + 1 < line.count ? start + TokenKind.start(of: line[position + 1]) : end
            guard from < to, to <= end else { continue }
            layout.addTemporaryAttribute(.foregroundColor, value: kind.color, forCharacterRange: NSRange(location: from, length: to - from))
        }
    }

    var hasGrammar: Bool { document != nil }

    /// What's known about a character. Plain until its line has been done.
    func kind(at offset: Int) -> TokenKind {
        guard offset >= 0, offset < knownLength else { return .plain }
        let index = table.line(containing: offset)
        guard tokens.indices.contains(index), let line = tokens[index], !line.isEmpty else { return .plain }
        let column = offset - table.starts[index]
        var low = 0
        var high = line.count
        while low < high {
            let middle = (low + high) / 2
            if TokenKind.start(of: line[middle]) <= column { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? .plain : TokenKind.of(line[low - 1])
    }

    /// In a comment. A grammar can mark a word inside one as something else, like TODO, and that's
    /// still in the comment that started before it on the line.
    func isInComment(_ offset: Int) -> Bool {
        let here = kind(at: offset)
        if here == .comment { return true }
        guard here != .string, offset >= 0, offset < knownLength else { return false }
        let index = table.line(containing: offset)
        guard tokens.indices.contains(index), let line = tokens[index] else { return false }
        let column = offset - table.starts[index]
        return line.contains { TokenKind.start(of: $0) <= column && TokenKind.of($0) == .comment }
    }

    /// Inside a string or a comment, where brackets and names aren't code.
    func isInStringOrComment(_ offset: Int) -> Bool {
        let kind = kind(at: offset)
        return kind == .string || kind == .comment
    }
}
