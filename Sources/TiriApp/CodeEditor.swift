import AppKit
import TiriCore

/// A text view that knows code a little: Return keeps the indent, Tab indents, and the line
/// with the cursor shows. The commands themselves are pure functions in TextEditing.
final class CodeTextView: NSTextView {
    weak var editor: TextController?

    /// The text, without the copy that `string` makes. Only for reading.
    var nsText: NSString { textStorage?.mutableString ?? "" }

    static func makeScrollable() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: 10_000_000))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = CodeTextView(frame: .zero, textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        guard let editor, isEditable, !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        if hasMultipleCursors {
            newlineAtEveryCursor()
        } else {
            editor.insertNewline()
        }
    }

    /// Esc and F5 would offer the system's word list. Esc is for closing things, and ⌃Space asks for Tiri's own.
    override func complete(_ sender: Any?) {}

    override func resignFirstResponder() -> Bool {
        editor?.completion.close()
        return super.resignFirstResponder()
    }

    /// Another tab came to the front. Nothing tells a view it's lost the keyboard when that happens.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { editor?.completion.close() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func insertTab(_ sender: Any?) {
        guard let editor, isEditable, !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        if hasMultipleCursors {
            insertAtEveryCursor(editor.indentUnit, typing: false)
        } else {
            editor.insertTabKey()
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard let editor, isEditable, !hasMarkedText() else {
            super.insertBacktab(sender)
            return
        }
        editor.run(.outdentLines)
    }

    // MARK: The current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawExtraSelections(in: rect)
        guard selectedRange().length == 0, let found = caretLineRect, found.intersects(rect) else { return }
        ThemePalette.currentLine.setFill()
        found.fill(using: .sourceOver)
    }

    /// The row with the cursor, across the whole width of the view.
    private var caretLineRect: NSRect? {
        guard let layout = layoutManager, let textStorage else { return nil }
        let caret = selectedRange().location
        var line: NSRect
        if caret >= textStorage.length {
            line = layout.extraLineFragmentRect
            if line.isEmpty, textStorage.length > 0 {
                line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: textStorage.length - 1), effectiveRange: nil)
            }
        } else {
            line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: caret), effectiveRange: nil)
        }
        if line.isEmpty { line = NSRect(x: 0, y: 0, width: 0, height: (font?.pointSize ?? 12) + 4) }
        return NSRect(x: 0, y: line.minY + textContainerOrigin.y, width: bounds.width, height: line.height)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Anything else moving the selection, like a click or a jump, is back to one cursor.
        if !isSteering, hasMultipleCursors { dropExtraCursors() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The old row and the new one. Over the visible part only, so it costs the same in any size of file.
        setNeedsDisplay(visibleRect)
    }

    // MARK: Applying an edit

    /// Makes an edit one step for undo, and has undo put the selection back where it was.
    func apply(_ edit: TextEdit, name: String) {
        guard !edit.changes.isEmpty, let textStorage else { return }
        dropExtraCursors()
        var changes = edit.changes
        // A text view takes a few thousand ranges at once well, but not a hundred thousand.
        if changes.count > 2_000, let one = edit.coalesced(in: textStorage.string as NSString) { changes = [one] }
        let ranges = changes.map { NSValue(range: $0.range) }
        breakUndoCoalescing()
        // Registered before the text view registers its own, so it runs after that and has the last word.
        registerSelectionStep(restore: selectedRange(), afterwards: nil)
        guard shouldChangeText(inRanges: ranges, replacementStrings: changes.map(\.text)) else { return }
        textStorage.beginEditing()
        for change in changes.reversed() {
            textStorage.replaceCharacters(in: change.range, with: NSAttributedString(string: change.text, attributes: typingAttributes))
        }
        textStorage.endEditing()
        didChangeText()
        setSelectedRange(edit.selection)
        registerSelectionStep(restore: nil, afterwards: edit.selection)
        undoManager?.setActionName(name)
        breakUndoCoalescing()
        scrollRangeToVisible(NSRange(location: edit.selection.location, length: 0))
    }

    /// Undo runs last to first, so a step registered before the edit runs after undoing it, and
    /// one registered after the edit runs after redoing it. Each hands over to the other.
    private func registerSelectionStep(restore: NSRange?, afterwards: NSRange?) {
        undoManager?.registerUndo(withTarget: self) { view in
            if let restore { view.setSelectedRange(restore) }
            view.registerSelectionStep(restore: afterwards, afterwards: restore)
        }
    }

    // MARK: Several cursors

    /// ⌘D's others. The text view's own selection is always the one most recently added.
    private(set) var extraCursors: [TextCursor] = []
    private var primary = TextCursor(anchor: 0, head: 0)
    /// Moving the selection on purpose, one cursor at a time.
    private(set) var isSteering = false
    private var typingRun = false
    /// ⌘D chose the word itself, so only the whole word matches.
    private var matchesWholeWord = false
    private var chosenWord: NSRange?
    private var caretViews: [NSTextInsertionIndicator] = []

    var hasMultipleCursors: Bool { !extraCursors.isEmpty }

    private var allCursors: [TextCursor] { MultiCursor.normalized(extraCursors + [primary]) }

    /// The next place the selection's text appears gets a cursor too.
    func addNextOccurrence() {
        guard let textStorage, !hasMarkedText() else { return }
        let string = nsText
        let selection = selectedRange()
        if !hasMultipleCursors, selection.length == 0 {
            // The first press takes the word the cursor's in.
            guard let word = SymbolText.word(in: string, at: selection.location) else { return }
            setSelectedRange(word)
            chosenWord = word
            scrollRangeToVisible(word)
            return
        }
        if !hasMultipleCursors {
            matchesWholeWord = chosenWord == selection
            primary = TextCursor(selection)
        }
        guard selection.length > 0 else { return }
        let existing = allCursors.map(\.range)
        guard let next = MultiCursor.nextOccurrence(of: string.substring(with: selection), in: string, after: NSMaxRange(selection),
                                                    existing: existing, wholeWord: matchesWholeWord) else { return }
        extraCursors.append(primary)
        steer(to: TextCursor(next))
        updateCursors()
        scrollRangeToVisible(next)
    }

    func dropExtraCursors() {
        guard hasMultipleCursors else { return }
        extraCursors = []
        typingRun = false
        endComposing()
        updateCursors()
    }

    private func steer(to cursor: TextCursor) {
        primary = cursor
        isSteering = true
        super.setSelectedRanges([NSValue(range: cursor.range)], affinity: .downstream, stillSelecting: false)
        isSteering = false
    }

    /// Puts these cursors in place, with the one nearest the last primary as the text view's own.
    private func setCursors(_ cursors: [TextCursor], primaryIndex: Int) {
        var list = MultiCursor.normalized(cursors)
        let wanted = cursors.indices.contains(primaryIndex) ? cursors[primaryIndex].range.location : (list.last?.range.location ?? 0)
        let index = list.lastIndex { $0.range.location <= wanted } ?? 0
        let main = list.remove(at: index)
        extraCursors = list
        steer(to: main)
        updateCursors()
        setNeedsDisplay(visibleRect)
    }

    private var primaryIndex: Int {
        allCursors.firstIndex(of: primary) ?? 0
    }

    // MARK: Typing with several cursors

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let completion = editor?.completion
        let wasComposing = hasMarkedText()
        completion?.isEditing = true
        insertTextAtCursors(string, text: text, replacementRange: replacementRange)
        completion?.isEditing = false
        // What an input method settles on isn't a name being typed out, letter by letter.
        if wasComposing {
            completion?.close()
        } else {
            completion?.typed(text)
        }
    }

    private func insertTextAtCursors(_ string: Any, text: String, replacementRange: NSRange) {
        guard hasMultipleCursors else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if composing {
            isSteering = true
            super.insertText(string, replacementRange: replacementRange)
            isSteering = false
            finishComposing(with: text)
            return
        }
        guard replacementRange.location == NSNotFound || replacementRange == selectedRange() else {
            dropExtraCursors()
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        insertAtEveryCursor(text, typing: true)
    }

    // An input method writes at one place, and what it settles on goes in at the others. Pinyin
    // shows the letters it's still working on beside the cursor that was added last.

    private var composing = false
    private var composingStart = 0
    private var composedLength = 0

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Hidden while an input method is composing.
        editor?.completion.close()
        guard hasMultipleCursors, let textStorage else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        if !composing {
            composing = true
            registerSnapshotUndo(text: textStorage.string, cursors: allCursors, primaryIndex: primaryIndex)
            typingRun = false
            allowsUndo = false
            composingStart = primary.range.location
            composedLength = primary.range.length
        }
        let length = (string as? NSAttributedString)?.length ?? (string as? NSString)?.length ?? 0
        isSteering = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isSteering = false
        shiftCursorsAfterComposition(by: length - composedLength)
        composedLength = length
    }

    override func unmarkText() {
        guard composing, let textStorage else {
            super.unmarkText()
            return
        }
        let marked = markedRange()
        let text = marked.location == NSNotFound ? "" : (textStorage.string as NSString).substring(with: marked)
        isSteering = true
        super.unmarkText()
        isSteering = false
        finishComposing(with: text)
    }

    private func shiftCursorsAfterComposition(by delta: Int) {
        for index in extraCursors.indices where extraCursors[index].range.location >= composingStart {
            extraCursors[index].anchor += delta
            extraCursors[index].head += delta
        }
        updateCursors()
    }

    private func endComposing() {
        guard composing else { return }
        composing = false
        allowsUndo = true
    }

    /// The input method has settled on this at the newest cursor. Now the others.
    private func finishComposing(with text: String) {
        guard composing else { return }
        shiftCursorsAfterComposition(by: (text as NSString).length - composedLength)
        endComposing()
        primary = TextCursor(selectedRange())
        guard !text.isEmpty, let textStorage else { return }
        let cursors = allCursors
        let index = primaryIndex
        let texts = cursors.indices.map { $0 == index ? "" : text }
        let result = MultiCursor.replacing(cursors, with: texts)
        let changes = result.changes.filter { $0.range.length > 0 || !$0.text.isEmpty }
        let wasUndoable = allowsUndo
        allowsUndo = false
        defer { allowsUndo = wasUndoable }
        guard shouldChangeText(inRanges: changes.map { NSValue(range: $0.range) }, replacementStrings: changes.map(\.text)) else { return }
        isSteering = true
        textStorage.beginEditing()
        for change in changes.reversed() {
            textStorage.replaceCharacters(in: change.range, with: NSAttributedString(string: change.text, attributes: typingAttributes))
        }
        textStorage.endEditing()
        isSteering = false
        setCursors(result.cursors, primaryIndex: index)
        didChangeText()
    }

    private func insertAtEveryCursor(_ text: String, typing: Bool) {
        let cursors = allCursors
        let result = MultiCursor.inserting(text, at: cursors)
        commit(result.changes, cursors: result.cursors, primaryIndex: primaryIndex, typing: typing)
    }

    private func newlineAtEveryCursor() {
        guard let editor, let textStorage else { return }
        let string = nsText
        let edits = allCursors.map { editor.newlineEdit(in: string, selection: $0.range) }
        // Two cursors on one blank line would want the same characters. Plain newlines can't collide.
        let overlaps = zip(edits, edits.dropFirst()).contains { pair in
            guard let first = pair.0.changes.last, let second = pair.1.changes.first else { return false }
            return NSMaxRange(first.range) > second.range.location
        }
        if overlaps {
            insertAtEveryCursor(TextEditing.lineEnding(of: string), typing: false)
            return
        }
        let result = MultiCursor.combining(edits)
        commit(result.changes, cursors: result.cursors, primaryIndex: primaryIndex, typing: false)
    }

    /// One text-and-cursors snapshot per undo step: nothing to get wrong about where things moved.
    /// The text view's own undo stays out of it, and the two take turns on one stack.
    private func commit(_ changes: [TextChange], cursors: [TextCursor], primaryIndex: Int, typing: Bool) {
        guard let textStorage else { return }
        if !(typing && typingRun) {
            registerSnapshotUndo(text: textStorage.string, cursors: allCursors, primaryIndex: self.primaryIndex)
        }
        typingRun = typing
        let wasUndoable = allowsUndo
        allowsUndo = false
        defer { allowsUndo = wasUndoable }
        guard shouldChangeText(inRanges: changes.map { NSValue(range: $0.range) }, replacementStrings: changes.map(\.text)) else { return }
        // The text view keeps its own selection valid as the text changes, and that isn't anyone moving it.
        isSteering = true
        textStorage.beginEditing()
        for change in changes.reversed() {
            textStorage.replaceCharacters(in: change.range, with: NSAttributedString(string: change.text, attributes: typingAttributes))
        }
        textStorage.endEditing()
        isSteering = false
        // In place before anyone hears about the change.
        setCursors(cursors, primaryIndex: primaryIndex)
        didChangeText()
        scrollRangeToVisible(NSRange(location: primary.head, length: 0))
    }

    private func registerSnapshotUndo(text: String, cursors: [TextCursor], primaryIndex: Int) {
        undoManager?.registerUndo(withTarget: self) { view in
            view.restoreSnapshot(text: text, cursors: cursors, primaryIndex: primaryIndex)
        }
    }

    private func restoreSnapshot(text: String, cursors: [TextCursor], primaryIndex: Int) {
        guard let textStorage else { return }
        registerSnapshotUndo(text: textStorage.string, cursors: hasMultipleCursors ? allCursors : [TextCursor(selectedRange())], primaryIndex: hasMultipleCursors ? self.primaryIndex : 0)
        typingRun = false
        let old = nsText
        let new = text as NSString
        // Only what differs is replaced, so the colors everywhere else stay.
        var start = 0
        let shortest = min(old.length, new.length)
        while start < shortest, old.character(at: start) == new.character(at: start) { start += 1 }
        var end = 0
        while end < shortest - start, old.character(at: old.length - 1 - end) == new.character(at: new.length - 1 - end) { end += 1 }
        let range = NSRange(location: start, length: old.length - start - end)
        let inserted = new.substring(with: NSRange(location: start, length: new.length - start - end))
        let wasUndoable = allowsUndo
        allowsUndo = false
        defer { allowsUndo = wasUndoable }
        guard shouldChangeText(in: range, replacementString: inserted) else { return }
        isSteering = true
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: inserted, attributes: typingAttributes))
        isSteering = false
        setCursors(cursors, primaryIndex: primaryIndex)
        didChangeText()
        scrollRangeToVisible(NSRange(location: primary.head, length: 0))
    }

    // MARK: Moving with several cursors

    private static let deletions: [String: String] = [
        "deleteBackward:": "moveLeft:", "deleteBackwardByDecomposingPreviousCharacter:": "moveLeft:", "deleteForward:": "moveRight:",
        "deleteWordBackward:": "moveWordLeft:", "deleteWordForward:": "moveWordRight:",
        "deleteToBeginningOfLine:": "moveToLeftEndOfLine:", "deleteToEndOfLine:": "moveToRightEndOfLine:",
        "deleteToBeginningOfParagraph:": "moveToBeginningOfParagraph:", "deleteToEndOfParagraph:": "moveToEndOfParagraph:",
    ]

    override func doCommand(by selector: Selector) {
        let completion = editor?.completion
        if completion?.handle(selector) == true { return }
        let deleting = selector == #selector(deleteBackward(_:)) || selector == #selector(deleteBackwardByDecomposingPreviousCharacter(_:))
        completion?.isEditing = deleting
        runCommand(selector)
        completion?.isEditing = false
        if deleting { completion?.deleted() }
    }

    private func runCommand(_ selector: Selector) {
        guard hasMultipleCursors else {
            super.doCommand(by: selector)
            return
        }
        let name = NSStringFromSelector(selector)
        // A key that means nothing here means nothing to the cursors either.
        if name == "noop:" { return }
        typingRun = selector == #selector(deleteBackward(_:)) ? typingRun : false
        if let motion = Self.deletions[name] {
            deleteAtEveryCursor(motion: Selector(motion))
        } else if name.hasPrefix("move"), name.hasSuffix("AndModifySelection:") {
            let plain = Selector(name.replacingOccurrences(of: "AndModifySelection", with: ""))
            if responds(to: plain) {
                moveEveryCursor(by: plain, extending: true)
            } else {
                dropExtraCursors()
                super.doCommand(by: selector)
            }
        } else if name.hasPrefix("move") {
            moveEveryCursor(by: selector, extending: false)
        } else if selector == #selector(insertNewline(_:)) || selector == #selector(insertTab(_:)) || name.hasPrefix("scroll") {
            super.doCommand(by: selector)
        } else {
            // Anything else is about one place.
            dropExtraCursors()
            super.doCommand(by: selector)
        }
    }

    /// Where a cursor would land, asking the text view itself, so words and lines mean what they usually do.
    private func landing(from range: NSRange, motion: Selector) -> Int {
        super.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: false)
        super.doCommand(by: motion)
        return selectedRange().location
    }

    private func moveEveryCursor(by motion: Selector, extending: Bool) {
        let origin = enclosingScrollView?.contentView.bounds.origin
        let wanted = primaryIndex
        isSteering = true
        let moved = allCursors.map { cursor -> TextCursor in
            if extending {
                let head = landing(from: NSRange(location: cursor.head, length: 0), motion: motion)
                return TextCursor(anchor: cursor.anchor, head: head)
            }
            let caret = landing(from: cursor.range, motion: motion)
            return TextCursor(anchor: caret, head: caret)
        }
        isSteering = false
        if let origin { enclosingScrollView?.contentView.scroll(to: origin) }
        setCursors(moved, primaryIndex: wanted)
        scrollRangeToVisible(NSRange(location: primary.head, length: 0))
    }

    private func deleteAtEveryCursor(motion: Selector) {
        let wanted = primaryIndex
        let origin = enclosingScrollView?.contentView.bounds.origin
        isSteering = true
        let ranges = allCursors.map { cursor -> NSRange in
            if cursor.range.length > 0 { return cursor.range }
            let other = landing(from: cursor.range, motion: motion)
            return NSRange(location: min(other, cursor.head), length: abs(other - cursor.head))
        }
        isSteering = false
        if let origin { enclosingScrollView?.contentView.scroll(to: origin) }
        let result = MultiCursor.deleting(ranges)
        commit(result.changes, cursors: result.cursors, primaryIndex: wanted, typing: true)
    }

    // MARK: Accepting a completion

    /// `left` and `right` are how much around the cursor it replaces. At other cursors, it's the
    /// same amount, as far as the name there goes.
    func applyCompletion(left: Int, right: Int, text: String, extra: [TextChange]) {
        guard textStorage != nil else { return }
        let string = nsText
        let index = primaryIndex
        let heads = hasMultipleCursors ? allCursors.map(\.head) : [selectedRange().location]
        let wordStarts = hasMultipleCursors ? heads.map { WordIndex.prefix(in: string, before: $0)?.location ?? $0 } : nil
        let ranges = CompletionEdit.ranges(heads: heads, left: left, right: right, wordStarts: wordStarts, length: string.length)
        let made = CompletionEdit.make(replacing: ranges, with: text, extra: extra)
        guard hasMultipleCursors else {
            apply(TextEdit(changes: made.changes, selection: NSRange(location: made.carets.first ?? 0, length: 0)), name: "Completion")
            return
        }
        commit(made.changes, cursors: made.carets.map { TextCursor(anchor: $0, head: $0) }, primaryIndex: index, typing: false)
    }

    // MARK: Copying and pasting with several cursors

    override func copy(_ sender: Any?) {
        guard hasMultipleCursors, let textStorage else {
            super.copy(sender)
            return
        }
        let string = nsText
        let text = allCursors.map { string.substring(with: $0.range) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard hasMultipleCursors else {
            super.cut(sender)
            return
        }
        copy(sender)
        let wanted = primaryIndex
        let result = MultiCursor.deleting(allCursors.map(\.range))
        commit(result.changes, cursors: result.cursors, primaryIndex: wanted, typing: false)
    }

    override func paste(_ sender: Any?) {
        guard hasMultipleCursors, let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let cursors = allCursors
        let result = MultiCursor.replacing(cursors, with: MultiCursor.pieces(forPasting: text, cursors: cursors.count))
        commit(result.changes, cursors: result.cursors, primaryIndex: primaryIndex, typing: false)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if hasMultipleCursors { paste(sender) } else { super.pasteAsPlainText(sender) }
    }

    // MARK: Drawing the other cursors

    private func drawExtraSelections(in rect: NSRect) {
        guard hasMultipleCursors, let layout = layoutManager, let container = textContainer else { return }
        (selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor).setFill()
        let origin = textContainerOrigin
        for cursor in extraCursors where cursor.range.length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: cursor.range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                let shifted = box.offsetBy(dx: origin.x, dy: origin.y)
                if shifted.intersects(rect) { shifted.fill() }
            }
        }
    }

    /// Carets with nothing selected are small views of the system's own blinking kind.
    func updateCursors() {
        let carets = extraCursors.filter { $0.range.length == 0 }
        while caretViews.count > carets.count { caretViews.removeLast().removeFromSuperview() }
        while caretViews.count < carets.count {
            let view = NSTextInsertionIndicator()
            view.color = insertionPointColor
            view.displayMode = .automatic
            addSubview(view)
            caretViews.append(view)
        }
        for (view, cursor) in zip(caretViews, carets) { view.frame = caretRect(at: cursor.head) }
        setNeedsDisplay(visibleRect)
    }

    private func caretRect(at offset: Int) -> NSRect {
        guard let layout = layoutManager, let textStorage else { return .zero }
        var line: NSRect
        var x: CGFloat = 0
        if offset >= textStorage.length, !layout.extraLineFragmentRect.isEmpty {
            line = layout.extraLineFragmentRect
        } else {
            let glyph = layout.glyphIndexForCharacter(at: min(offset, max(textStorage.length - 1, 0)))
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = layout.location(forGlyphAt: glyph).x
            if offset >= textStorage.length, let last = layout.textContainer(forGlyphAt: glyph, effectiveRange: nil) {
                x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: last).maxX - line.minX
            }
        }
        let origin = textContainerOrigin
        return NSRect(x: line.minX + x + origin.x - 0.5, y: line.minY + origin.y, width: 2, height: line.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if hasMultipleCursors { updateCursors() }
    }
}

/// The commands that edit or move around in the file in front. They only take their keys when
/// that file has the keyboard, so ⌥↑ still reaches a terminal and ⌘[ a web page.
enum EditorCommand: String, CaseIterable {
    case toggleLineComment, indentLines, outdentLines, moveLinesUp, moveLinesDown
    case copyLinesUp, copyLinesDown, deleteLine, insertLineBelow, insertLineAbove, addNextOccurrence, triggerCompletion

    var title: String {
        switch self {
        case .toggleLineComment: "Toggle Line Comment"
        case .indentLines: "Indent Lines"
        case .outdentLines: "Outdent Lines"
        case .moveLinesUp: "Move Lines Up"
        case .moveLinesDown: "Move Lines Down"
        case .copyLinesUp: "Copy Lines Up"
        case .copyLinesDown: "Copy Lines Down"
        case .deleteLine: "Delete Lines"
        case .insertLineBelow: "Insert Line Below"
        case .insertLineAbove: "Insert Line Above"
        case .addNextOccurrence: "Add Next Occurrence"
        case .triggerCompletion: "Suggest Completions"
        }
    }
}

extension TextController {
    private var style: IndentStyle { IndentStyle.detect(in: codeView.nsText) }

    func run(_ command: EditorCommand) {
        guard codeView.isEditable, !codeView.hasMarkedText() else { return }
        if command == .addNextOccurrence {
            codeView.addNextOccurrence()
            return
        }
        if command == .triggerCompletion {
            completion.trigger()
            return
        }
        // These are about lines around the cursor, so they apply to the one that was added last.
        codeView.dropExtraCursors()
        let text = codeView.nsText
        let selection = codeView.selectedRange()
        let edit: TextEdit?
        switch command {
        case .toggleLineComment:
            guard let syntax = CommentSyntax.forFile(path) else {
                model.showToast(title: "This kind of file has no comments", detail: nil, symbol: "text.bubble", tint: .secondary)
                return
            }
            edit = TextEditing.toggleLineComment(in: text, selection: selection, syntax: syntax)
        case .indentLines: edit = TextEditing.indent(in: text, selection: selection, style: style)
        case .outdentLines: edit = TextEditing.outdent(in: text, selection: selection, style: style)
        case .moveLinesUp: edit = TextEditing.moveLines(in: text, selection: selection, up: true)
        case .moveLinesDown: edit = TextEditing.moveLines(in: text, selection: selection, up: false)
        case .copyLinesUp: edit = TextEditing.copyLines(in: text, selection: selection, up: true)
        case .copyLinesDown: edit = TextEditing.copyLines(in: text, selection: selection, up: false)
        case .deleteLine: edit = TextEditing.deleteLines(in: text, selection: selection)
        case .insertLineBelow:
            edit = TextEditing.insertLineBelow(in: text, selection: selection, style: style, colonOpensBlock: CommentSyntax.colonOpensBlock(path))
        case .insertLineAbove: edit = TextEditing.insertLineAbove(in: text, selection: selection)
        case .addNextOccurrence, .triggerCompletion: edit = nil
        }
        if let edit { codeView.apply(edit, name: command.title) }
    }

    func insertNewline() {
        codeView.apply(newlineEdit(in: codeView.nsText, selection: codeView.selectedRange()), name: "Typing")
    }

    func newlineEdit(in text: NSString, selection: NSRange) -> TextEdit {
        TextEditing.newline(in: text, selection: selection, style: style, colonOpensBlock: CommentSyntax.colonOpensBlock(path))
    }

    var indentUnit: String { style.unit }

    func insertTabKey() {
        if let edit = TextEditing.tab(in: codeView.nsText, selection: codeView.selectedRange(), style: style) {
            codeView.apply(edit, name: "Typing")
        }
    }
}

/// A file whose outline can be looked through, jumping as you go.
protocol OutlineViewing: AnyObject {
    var path: String { get }
    var outlineText: String { get }
    var outlineLineCount: Int { get }
    var outlineCurrentLine: Int { get }
    /// Remembers where the view is, and gives back what puts it there again.
    func beginPreview() -> (() -> Void)?
    func previewLine(_ line: Int)
    func clearPreview()
}

extension TextController: OutlineViewing {
    var outlineText: String { text }
    var outlineLineCount: Int { lineCount }
    var outlineCurrentLine: Int { currentLine }

    func beginPreview() -> (() -> Void)? {
        let position = scrollPosition
        return { [weak self] in self?.scrollPosition = position }
    }

    func clearPreview() { clearPreviewMark() }
}

extension MarkdownController: OutlineViewing {
    private var sourceText: String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    var outlineText: String { sourceIfShowing?.text ?? sourceText }
    var outlineLineCount: Int { sourceIfShowing?.lineCount ?? LineTable(sourceText as NSString).count }
    var outlineCurrentLine: Int { sourceIfShowing?.currentLine ?? 1 }

    func beginPreview() -> (() -> Void)? {
        if let source = sourceIfShowing { return source.beginPreview() }
        return renderedScrollRestorer()
    }

    func previewLine(_ line: Int) {
        if let source = sourceIfShowing {
            source.previewLine(line)
        } else {
            goTo(line: line, col: nil)
        }
    }

    func clearPreview() { sourceIfShowing?.clearPreview() }
}

extension AppModel {
    /// The file in front, if it has an outline to look through.
    var frontOutlineTarget: OutlineViewing? {
        guard let target = (peekHasKeyboard ? active.peek?.id : nil) ?? active.focused.active else { return nil }
        return existingController(for: target) as? OutlineViewing
    }

    var frontTerminal: TerminalController? {
        guard let target = (peekHasKeyboard ? active.peek?.id : nil) ?? active.focused.active else { return nil }
        return existingController(for: target) as? TerminalController
    }

    /// For a tab in its own window, whose keys don't go through the main window's handling.
    func runOnFocusedItem(stroke: KeyStroke, in window: NSWindow) -> Bool {
        guard let binding = keybindings.first(where: { $0.strokes == [stroke] && (focusedKeyCommands.contains($0.command) || EditorCommand(rawValue: $0.command) != nil) }) else { return false }
        if let view = window.firstResponder as? CodeTextView, let editor = view.editor {
            if let command = EditorCommand(rawValue: binding.command) {
                guard view.isEditable else { return false }
                editor.run(command)
                return true
            }
            if binding.command == "toggleWordWrap" {
                editor.toggleWordWrap()
                return true
            }
            return false
        }
        if let terminal = (window.firstResponder as? TiriTerminalView)?.owner {
            switch binding.command {
            case "terminalLineStart": terminal.sendLineStart()
            case "terminalLineEnd": terminal.sendLineEnd()
            case "terminalDeleteToLineStart": terminal.sendDeleteToLineStart()
            default: return false
            }
            return true
        }
        return false
    }

    private var focusedKeyCommands: Set<String> {
        ["toggleWordWrap", "terminalLineStart", "terminalLineEnd", "terminalDeleteToLineStart"]
    }

    /// The file editor with the keyboard, if one has it. Works in a tab's own window too.
    var focusedEditor: TextController? {
        ((NSApp.keyWindow ?? window)?.firstResponder as? CodeTextView)?.editor
    }

    /// The text file in front, whether or not it has the keyboard.
    var frontEditor: TextController? {
        guard let target = (peekHasKeyboard ? active.peek?.id : nil) ?? active.focused.active,
              let controller = existingController(for: target) else { return nil }
        if let text = controller as? TextController { return text }
        return (controller as? MarkdownController)?.sourceIfShowing
    }

    /// Every file editor open, in any workspace. Their words can be offered in each other.
    var openTextEditors: [TextController] {
        workspaces.flatMap { $0.items + ($0.peek.map { [$0] } ?? []) }.compactMap { item in
            let controller = existingController(for: item.id)
            return (controller as? TextController) ?? (controller as? MarkdownController)?.sourceIfShowing
        }
    }

    func zoom(by steps: Int) {
        let range = TiriSettings.zoomRange
        let next = min(max(settings.zoomLevel + steps, range.lowerBound), range.upperBound)
        if next != settings.zoomLevel { setSetting("window.zoomLevel", to: .int(next)) }
    }

    func zoomReset() {
        if settings.zoomLevel != 0 { setSetting("window.zoomLevel", to: .int(0)) }
    }

    /// Page zoom that keeps web pages in step with the text size steps.
    var webZoom: CGFloat { pow(1.08, CGFloat(settings.zoomLevel)) }
}
