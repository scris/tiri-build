import AppKit
import TiriCore
import TiriHighlight

/// The list that appears while typing a name. One per file editor. It never has the keyboard: the
/// text view does, and hands over only the keys that mean something to the list.
final class CompletionController {
    /// A tab can close while a server is still answering, so anything arriving late checks `isAlive`.
    private weak var editorIfOpen: TextController?
    private var editor: TextController { editorIfOpen! }
    private var isAlive: Bool { editorIfOpen != nil }
    private var textView: CodeTextView { editor.codeView }
    private var model: AppModel { editor.model }

    private var listView: CompletionListView?
    private(set) var isOpen = false
    /// Where the name being completed starts.
    private var anchor = 0
    /// Where the cursor was when the server was last asked.
    private var requestCaret = 0
    private var requestColumn = 0
    private var serverItems: [CompletionItem]?
    private var serverIncomplete = false
    private var serverAsked = false
    private var wordItems: [CompletionItem] = []
    private var ranked: [CompletionRanker.Ranked] = []
    private var selected = 0
    private var query = ""
    private var nearby = Set<String>()
    private var wasAsked = false
    /// Changes when the list starts over, so that late answers can be dropped.
    private var generation = 0
    private var resolved: [String: CompletionItem] = [:]
    private var resolveWork: DispatchWorkItem?
    private var wordsFallback: DispatchWorkItem?

    /// While the text view edits. The cursor moves as part of that, and that isn't anyone moving it.
    var isEditing = false

    // Names seen in the file, read off the main thread, and read again when typing pauses.
    private(set) var words = Set<String>()
    private var wordsWork: DispatchWorkItem?
    private var wordsGeneration = 0

    private static var recent: [String: [String]] = [:]
    /// The list is drawn over the whole window, so there's only ever room for one.
    private static weak var showing: CompletionController?
    private var windowObserver: NSObjectProtocol?

    init(editor: TextController) {
        editorIfOpen = editor
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Whichever window it was: the one this is in can't be key while another takes over.
                guard let self, self.isAlive, self.isOpen, self.textView.window?.isKeyWindow != true else { return }
                self.close()
            }
        }
    }

    isolated deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        listView?.removeFromSuperview()
    }

    private var language: LanguageDefinition? { LanguageCatalog.language(forPath: editor.path, firstLine: nil) }

    // MARK: Words

    /// Soon, not now: a large file shouldn't cost anything while it's being typed in.
    func refreshWordsSoon(delay: TimeInterval = 0.8) {
        wordsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isAlive else { return }
            self.wordsGeneration += 1
            let current = self.wordsGeneration
            let text = self.textView.string
            Task.detached(priority: .utility) { [weak self] in
                let found = WordIndex.words(in: text as NSString)
                await MainActor.run {
                    guard let self, self.wordsGeneration == current else { return }
                    self.words = found
                }
            }
        }
        wordsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Names close to the cursor, which also catches anything typed since the words were last read.
    private func namesNearCursor() -> Set<String> {
        let text = textView.nsText
        let caret = textView.selectedRange().location
        let radius = 8_000
        let start = max(caret - radius, 0)
        return WordIndex.words(in: text, range: NSRange(location: start, length: min(caret + radius, text.length) - start))
    }

    private func gatherWords(excluding typed: String) -> [CompletionItem] {
        var all = nearby.union(words)
        for other in model.openTextEditors where other !== editor {
            all.formUnion(other.completion.words)
        }
        return WordIndex.items(from: all, excluding: typed)
    }

    // MARK: What starts it

    private static func isNameStart(_ text: String) -> Bool {
        guard text.utf16.count == 1, let unit = text.utf16.first else { return false }
        return unit == 95 || unit == 36 || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    private static func isNamePart(_ text: String) -> Bool {
        guard text.utf16.count == 1, let unit = text.utf16.first else { return false }
        return isNameStart(text) || (unit >= 48 && unit <= 57)
    }

    private var caret: Int { textView.selectedRange().location }

    /// Someone typed this, not an input method still working on it.
    func typed(_ text: String) {
        guard textView.isEditable, !textView.hasMarkedText() else { return close() }
        refreshWordsSoon()
        if isOpen {
            if Self.isNamePart(text) {
                updateQuery(by: text.utf16.count)
                return
            }
            close()
        }
        guard model.settings.editorCompletion else { return }
        let position = caret
        guard position > 0, textView.selectedRange().length == 0 else { return }
        // A comment or a string is words, not code. ⌃Space is still there for those.
        if editor.isInStringOrComment(position - 1) { return }
        let abilities = model.languageServers.completionAbilities(for: editor.path)
        if let abilities, abilities.triggerCharacters.contains(text) {
            open(trigger: text, asked: false)
            return
        }
        // Writing prose, a list popping up at every word would be in the way.
        guard Self.isNameStart(text), let language, !language.isProse else { return }
        open(trigger: nil, asked: false)
    }

    func deleted() {
        guard isOpen else { return }
        refreshWordsSoon()
        if query.utf16.isEmpty {
            close()
        } else {
            updateQuery(by: -1)
        }
    }

    /// ⌃Space, anywhere: asked for, so comments and prose are fine too.
    func trigger() {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        close()
        open(trigger: nil, asked: true)
    }

    /// The cursor went somewhere that wasn't typing.
    func selectionMoved() {
        guard isOpen, !isEditing else { return }
        close()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        ranked = []
        resolved = [:]
        resolveWork?.cancel()
        wordsFallback?.cancel()
        listView?.removeFromSuperview()
    }

    func scrolled() {
        guard isOpen, !isEditing else { return }
        // It moves with the text, and goes when the text does.
        guard let frame = listFrame() else { return close() }
        listView?.frame = frame
    }

    /// For `tiri perf`, and the tests that use it.
    var state: JSONValue {
        var object: [String: JSONValue] = ["open": .bool(isOpen), "rows": .int(ranked.count), "showing": .bool(listView?.superview != nil), "query": .string(query)]
        if ranked.indices.contains(selected) { object["selected"] = .string(ranked[selected].item.label) }
        if let listView {
            object["frame"] = .string(NSStringFromRect(listView.frame))
        }
        return .object(object)
    }

    // MARK: Filling the list

    private func open(trigger: String?, asked: Bool) {
        generation += 1
        let position = caret
        let text = textView.nsText
        anchor = trigger == nil ? (WordIndex.prefix(in: text, before: position)?.location ?? position) : position
        requestCaret = position
        requestColumn = editor.fileLocation(ofCharacter: position)?.character ?? 0
        query = text.substring(with: NSRange(location: anchor, length: position - anchor))
        isOpen = true
        wasAsked = asked
        serverItems = nil
        serverIncomplete = false
        selected = 0
        resolved = [:]
        nearby = namesNearCursor()
        wordItems = []
        let hasServer = model.languageServers.completionAbilities(for: editor.path) != nil
        serverAsked = hasServer
        if hasServer {
            askServer(trigger: trigger)
            // Quick answers shouldn't flash words first, and slow ones shouldn't leave nothing.
            if trigger == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isAlive, self.isOpen, self.serverItems == nil else { return }
                    self.useWords()
                }
                wordsFallback = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        } else if trigger == nil {
            useWords()
        } else {
            close()
        }
    }

    private func useWords() {
        wordItems = gatherWords(excluding: query)
        refilter()
    }

    private func askServer(trigger: String?) {
        let current = generation
        let position = caret
        requestCaret = position
        guard let place = editor.fileLocation(ofCharacter: position) else { return }
        requestColumn = place.character
        Task { [weak self] in
            guard let self, self.isAlive else { return }
            let answer = await self.model.languageServers.complete(path: self.editor.path, line: place.line, character: place.character, triggerCharacter: trigger)
            guard self.isAlive, self.isOpen, self.generation == current else { return }
            guard let answer else {
                // No answer in time, or an error. Words are better than nothing.
                if self.serverItems == nil, trigger == nil { self.useWords() }
                return
            }
            self.serverItems = answer.items
            self.serverIncomplete = answer.isIncomplete
            if answer.items.isEmpty, trigger == nil, self.wordItems.isEmpty { self.wordItems = self.gatherWords(excluding: self.query) }
            self.refilter()
        }
    }

    /// The name's start is worked out from the cursor rather than remembered: with several cursors,
    /// typing at an earlier one moves everything after it.
    private func updateQuery(by change: Int) {
        let position = caret
        let length = query.utf16.count + change
        guard length >= 0, position - length >= 0 else { return close() }
        anchor = position - length
        query = textView.nsText.substring(with: NSRange(location: anchor, length: length))
        // Only what's been typed since can't be told from what's in the list, when the list says it's partial.
        if serverAsked, serverIncomplete { askServer(trigger: nil) }
        if !wordItems.isEmpty { wordItems.removeAll { $0.label == query } }
        refilter()
    }

    private func refilter() {
        guard isOpen else { return }
        let source = (serverItems?.isEmpty == false) ? serverItems! : wordItems
        let previous = ranked.indices.contains(selected) ? ranked[selected].item.identity : nil
        // Words start at two letters, unless asked for: one letter matches nearly everything.
        if source.first?.isFromServer == false, query.utf16.count < 2, !wasAsked {
            ranked = []
        } else {
            let recent = Self.recent[language?.id ?? ""] ?? []
            ranked = CompletionRanker.rank(source, query: query, recent: recent, nearby: nearby)
        }
        // Finished typing it, and it's the only one: nothing left to offer.
        if ranked.count == 1, ranked[0].item.textToInsert == query { ranked = [] }
        guard !ranked.isEmpty else {
            hideList()
            if !wasAsked, serverItems != nil, !serverIncomplete, query.isEmpty { close() }
            return
        }
        selected = previous.flatMap { identity in ranked.firstIndex { $0.item.identity == identity } } ?? CompletionRanker.preselected(in: ranked, query: query)
        showList()
        resolveSoon()
    }

    // MARK: Showing it

    private func hideList() {
        listView?.removeFromSuperview()
    }

    private func showList() {
        guard let content = host else { return close() }
        if let other = Self.showing, other !== self { other.close() }
        Self.showing = self
        let list = listView ?? CompletionListView()
        listView = list
        list.font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        list.onAccept = { [weak self] index in
            guard let self else { return }
            self.selected = index
            self.acceptSelected()
        }
        list.onHighlight = { [weak self] index in
            guard let self else { return }
            self.selected = index
            self.listView?.selected = index
            self.resolveSoon()
        }
        list.set(rows: ranked, selected: selected, detail: selectedDetail)
        guard let frame = listFrame() else { return close() }
        list.frame = frame
        if list.superview !== content { content.addSubview(list, positioned: .above, relativeTo: nil) }
    }

    /// One level above the window's content: SwiftUI's hosting view never gives a child of its own
    /// a place among its layers, so the list there would exist but not be drawn.
    private var host: NSView? { textView.window?.contentView?.superview ?? textView.window?.contentView }

    private var selectedDetail: String? {
        guard ranked.indices.contains(selected) else { return nil }
        let item = resolved[ranked[selected].item.identity] ?? ranked[selected].item
        return item.documentation ?? item.detail
    }

    /// Below the line, or above it if there's no room. Lined up with the name's first letter.
    private func listFrame() -> NSRect? {
        guard let window = textView.window, let content = host, let list = listView else { return nil }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        guard screenRect != .zero else { return nil }
        let rect = window.convertFromScreen(screenRect)
        let visible = textView.convert(textView.enclosingScrollView?.documentVisibleRect ?? textView.visibleRect, to: nil)
        guard rect.midY >= visible.minY - 1, rect.midY <= visible.maxY + 1 else { return nil }
        let size = list.preferredSize
        let bounds = content.convert(content.bounds, to: nil)
        var x = rect.minX - CompletionListView.textInset
        x = max(min(x, bounds.maxX - size.width - 8), bounds.minX + 8)
        var y = rect.minY - size.height - 2
        if y < bounds.minY + 8 { y = rect.maxY + 2 }
        return content.convert(NSRect(x: x, y: y, width: size.width, height: size.height), from: nil)
    }

    // MARK: Keys

    /// True if the list used it. Only with the list on screen: an invisible list has no say.
    func handle(_ selector: Selector) -> Bool {
        guard isOpen, listView?.superview != nil, !ranked.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-CompletionListView.visibleRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(CompletionListView.visibleRows)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): acceptSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ by: Int) {
        guard !ranked.isEmpty else { return }
        if abs(by) == 1 {
            selected = (selected + by + ranked.count) % ranked.count
        } else {
            selected = min(max(selected + by, 0), ranked.count - 1)
        }
        listView?.set(rows: ranked, selected: selected, detail: selectedDetail)
        if let frame = listFrame() { listView?.frame = frame }
        resolveSoon()
    }

    // MARK: Details

    /// Only for what's highlighted, and only after it's been there a moment.
    private func resolveSoon() {
        resolveWork?.cancel()
        guard ranked.indices.contains(selected), ranked[selected].item.isFromServer, resolved[ranked[selected].item.identity] == nil else { return }
        let item = ranked[selected].item
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isAlive else { return }
            Task {
                guard let found = await self.model.languageServers.resolve(item, path: self.editor.path), self.isAlive, self.generation == current else { return }
                self.resolved[item.identity] = found
                if self.ranked.indices.contains(self.selected), self.ranked[self.selected].item.identity == item.identity {
                    self.listView?.set(rows: self.ranked, selected: self.selected, detail: self.selectedDetail)
                    if let frame = self.listFrame() { self.listView?.frame = frame }
                }
            }
        }
        resolveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Accepting

    private func acceptSelected() {
        guard ranked.indices.contains(selected) else { return close() }
        let original = ranked[selected].item
        let item = resolved[original.identity] ?? original
        let position = caret
        let table = LineTable(textView.nsText)
        var start = anchor
        var overhang = 0
        // A server's range was about the text when it was asked. What's been typed since is after its start.
        if let range = item.replaceRange?.range(in: table, length: textView.nsText.length), range.location <= position {
            start = range.location
            overhang = max((item.replaceRange?.endCharacter ?? 0) - requestColumn, 0)
        }
        let delta = position - requestCaret
        let extra: [TextChange] = item.additionalEdits.compactMap { edit in
            guard let range = edit.range.range(in: table, length: textView.nsText.length) else { return nil }
            return TextChange(range: range.location >= requestCaret ? NSRange(location: range.location + delta, length: range.length) : range, text: edit.text)
        }
        var recent = Self.recent[language?.id ?? ""] ?? []
        recent.removeAll { $0 == item.label }
        recent.append(item.label)
        Self.recent[language?.id ?? ""] = Array(recent.suffix(50))
        let needsResolve = item.isFromServer && resolved[original.identity] == nil && extra.isEmpty
        close()
        isEditing = true
        textView.applyCompletion(left: position - start, right: overhang, text: item.textToInsert, extra: extra)
        isEditing = false
        // An import a server only gives on request. It arrives after the name, as its own undo step.
        if needsResolve { addImportsLater(original, boundary: start) }
    }

    private func addImportsLater(_ item: CompletionItem, boundary: Int) {
        Task { [weak self] in
            guard let self, self.isAlive, let found = await self.model.languageServers.resolve(item, path: self.editor.path),
                  self.isAlive, !found.additionalEdits.isEmpty else { return }
            let table = LineTable(self.textView.nsText)
            let changes = found.additionalEdits.compactMap { edit -> TextChange? in
                guard let range = edit.range.range(in: table, length: self.textView.nsText.length), NSMaxRange(range) <= boundary else { return nil }
                return TextChange(range: range, text: edit.text)
            }.sorted { $0.range.location < $1.range.location }
            guard !changes.isEmpty, changes.count == found.additionalEdits.count, !self.textView.hasMarkedText() else { return }
            let shift = changes.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            let selection = self.textView.selectedRange()
            self.textView.apply(TextEdit(changes: changes, selection: NSRange(location: selection.location + shift, length: selection.length)), name: "Add Import")
        }
    }
}

/// Draws the list. Plain drawing rather than a table, because it's redrawn at every key press.
final class CompletionListView: NSView {
    static let visibleRows = 9
    /// So the name in a row lines up with the text it's completing.
    static let textInset: CGFloat = 30
    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 420

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var onAccept: ((Int) -> Void)?
    var onHighlight: ((Int) -> Void)?
    var selected = 0 {
        didSet { needsDisplay = true }
    }
    private var rows: [CompletionRanker.Ranked] = []
    private var top = 0
    private var detail: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        // SwiftUI's own layers are in the same parent, and would otherwise cover it.
        layer?.zPosition = 10_000
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func set(rows: [CompletionRanker.Ranked], selected: Int, detail: String?) {
        self.rows = rows
        self.selected = selected
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected < top { top = selected }
        if selected >= top + Self.visibleRows { top = selected - Self.visibleRows + 1 }
        top = max(min(top, rows.count - Self.visibleRows), 0)
        needsDisplay = true
    }

    private var detailHeight: CGFloat {
        guard let detail, !detail.isEmpty else { return 0 }
        let bounds = (detail as NSString).boundingRect(with: NSSize(width: Self.width - 20, height: 74), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 11)])
        return min(ceil(bounds.height), 74) + 12
    }

    var preferredSize: NSSize {
        NSSize(width: Self.width, height: CGFloat(min(rows.count, Self.visibleRows)) * Self.rowHeight + 8 + detailHeight)
    }

    private static func symbol(for kind: CompletionItem.Kind?) -> String {
        switch kind {
        case .method, .function, .constructor: "function"
        case .class, .interface, .struct, .enum, .typeParameter: "cube"
        case .field, .property, .enumMember: "tag"
        case .variable, .value, .reference: "x.squareroot"
        case .constant: "number"
        case .module, .folder, .file: "shippingbox"
        case .keyword: "textformat"
        case .operator: "plus.forwardslash.minus"
        case .text, nil: "text.alignleft"
        default: "circle.dotted"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        frame.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()
        frame.setClip()

        let shown = rows.dropFirst(top).prefix(Self.visibleRows)
        var y: CGFloat = 4
        let height = Self.rowHeight
        for (offset, row) in shown.enumerated() {
            let index = top + offset
            let box = NSRect(x: 4, y: y, width: bounds.width - 8, height: height)
            if index == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            }
            drawSymbol(for: row.item.kind, in: NSRect(x: 9, y: y + 3, width: 16, height: 16))
            let labelWidth = drawLabel(row, at: NSPoint(x: Self.textInset, y: y))
            if let detail = row.item.detail, !detail.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                let room = bounds.width - Self.textInset - labelWidth - 22
                if room > 40 {
                    let text = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? detail
                    let size = (text as NSString).size(withAttributes: attributes)
                    let width = min(size.width, room)
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byTruncatingTail
                    var clipped = attributes
                    clipped[.paragraphStyle] = style
                    (text as NSString).draw(in: NSRect(x: bounds.width - width - 12, y: y + (height - size.height) / 2, width: width, height: size.height), withAttributes: clipped)
                }
            }
            y += height
        }
        if let detail, detailHeight > 0 {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: y + 3, width: bounds.width, height: 1).fill()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (detail as NSString).draw(with: NSRect(x: 10, y: y + 9, width: bounds.width - 20, height: detailHeight - 12), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        }
    }

    private func drawSymbol(for kind: CompletionItem.Kind?, in rect: NSRect) {
        guard let image = NSImage(systemSymbolName: Self.symbol(for: kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The letters that matched stand out. Returns how wide it came out.
    private func drawLabel(_ row: CompletionRanker.Ranked, at point: NSPoint) -> CGFloat {
        let label = row.item.label
        let text = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        // Matched against something else, the positions aren't about what's shown.
        if row.item.matchText == label {
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            for position in row.positions where position < text.length {
                text.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: NSRange(location: position, length: 1))
            }
        }
        let size = text.size()
        let room = bounds.width - Self.textInset - 12
        text.draw(with: NSRect(x: point.x, y: point.y + (Self.rowHeight - size.height) / 2, width: room, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(size.width, room)
    }

    private func rowIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let index = top + Int((point.y - 4) / Self.rowHeight)
        guard point.y >= 4, index >= top, index < min(top + Self.visibleRows, rows.count) else { return nil }
        return index
    }

    override func mouseDown(with event: NSEvent) {
        if let index = rowIndex(at: event) { onAccept?(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        top = max(min(top + step, rows.count - Self.visibleRows), 0)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return frame.contains(superview.isFlipped ? point : point) ? self : nil
    }
}
