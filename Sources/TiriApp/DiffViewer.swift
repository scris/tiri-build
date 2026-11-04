import AppKit
import SwiftUI
import TiriCore

/// What an agent changed in one file. An item like any other: a tab, a split or a Peek.
final class DiffController: NSObject, ItemController, SymbolViewing, NSTextViewDelegate {
    let itemID: ItemID
    let path: String
    /// One agent's turn, or nil for everything since the last commit.
    let turn: String?
    private unowned let model: AppModel
    private let scrollView = NSTextView.scrollableTextView()
    private let textView: DiffTextView
    private let gutter = DiffGutter()
    private let container = DiffContainer()
    private var token: FileWatchHub.Token?
    private var generation = 0
    private var firstLoad = true
    private let message = NSTextField(labelWithString: "")
    private var quoteButton: QuoteButton?
    private var menuProblems: [LSPDiagnostic] = []
    private(set) var diff = FileDiff()

    var view: NSView { container }

    init(itemID: ItemID, path: String, turn: String? = nil, model: AppModel) {
        self.itemID = itemID
        self.path = path
        self.turn = turn
        self.model = model
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView = DiffTextView(frame: frame)
        super.init()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000_000, height: 10_000_000)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        gutter.attach(to: scrollView, textView: textView)
        textView.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: textView)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        container.install(gutter: gutter, scrollView: scrollView, message: message)
        quoteButton = QuoteButton(textView: textView, scrollView: scrollView, host: container)
        quoteButton?.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        applySettings()
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
        model.languageServers.viewerOpened(path)
    }

    func didAttach() { model.languageServers.viewerShown(path) }

    /// Only what this change is answerable for: the lines it added, in the file as it is now.
    /// A finished turn's lines may not be the file's any more, so it shows nothing.
    func diagnosticsChanged() {
        ProblemMarks.clear(textView)
        guard turn == nil || model.turn(id: turn ?? "")?.isOpen == true else {
            container.showProblems(nil, count: 0, onQuote: nil)
            gutter.problemRows = [:]
            return
        }
        let found = LSP.onAddedRows(model.languageServers.knownDiagnostics(for: path), rows: diff.lines)
        var rows: [Int: LSPDiagnostic.Severity] = [:]
        let index = LineIndex(textView.string as NSString)
        let rowOfLine = Dictionary(diff.lines.enumerated().compactMap { row, line in line.newLine.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        for problem in found.sorted(by: { $0.severity > $1.severity }) {
            guard let row = rowOfLine[problem.line + 1] else { continue }
            rows[row] = problem.severity
            guard let start = index.location(line: row, character: problem.character) else { continue }
            // Only as far as this row: the next row in a diff isn't the next line of the file.
            let rowEnd = index.start(ofLine: row + 1).map { $0 - 1 } ?? (textView.string as NSString).length
            let end = problem.endLine == problem.line ? min(start + max(problem.endCharacter - problem.character, 0), rowEnd) : rowEnd
            ProblemMarks.underline(NSRange(location: start, length: max(end - start, 0)), severity: problem.severity, in: textView)
        }
        gutter.problemRows = rows
        let errors = found.filter { $0.severity == .error }.count
        let text: String?
        if found.isEmpty {
            text = nil
        } else if errors == found.count {
            text = errors == 1 ? "1 error on lines this change added" : "\(errors) errors on lines this change added"
        } else {
            text = found.count == 1 ? "1 problem on lines this change added" : "\(found.count) problems on lines this change added"
        }
        container.showProblems(text, count: errors) { [weak self] in
            guard let self else { return }
            self.model.quoteDiagnostics(found, path: self.path)
        }
    }

    /// Other things change the answer too, like a commit. The app asks after any change it sees.
    func load() {
        generation += 1
        let current = generation
        let path = path
        let wanted = turn
        let found = turn.flatMap { model.turn(id: $0) }
        let snapshots = model.snapshots
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: FileDiff?
            if wanted != nil {
                result = found.flatMap { snapshots.diff(path: path, in: $0) }
            } else {
                result = Git.diff(path: path)
            }
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.display(result ?? FileDiff(), missing: result == nil)
            }
        }
    }

    private func display(_ result: FileDiff, missing: Bool = false) {
        let keepPlace = !firstLoad
        let origin = scrollView.contentView.bounds.origin
        diff = result
        model.controllerRevision += 1
        container.showMessage(missing ? "Tiri no longer has this turn's snapshot."
                              : result.isBinary ? "This is a binary file. Git can't show its changes line by line."
                              : (result.isEmpty ? (turn == nil ? "No changes in this file." : "This turn didn't change this file.") : nil))
        let text = result.lines.map(\.text).joined(separator: "\n")
        if text != textView.string || firstLoad {
            textView.lines = result.lines
            textView.string = text
            gutter.lines = result.lines
            scheduleHighlight(text)
            if keepPlace {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        reviewChanged()
        diagnosticsChanged()
        model.languageServers.fileMayHaveChanged(path)
        gutter.needsDisplay = true
        textView.needsDisplay = true
        firstLoad = false
        AppModel.shared.viewerReady(itemID)
    }

    private func scheduleHighlight(_ text: String) {
        let language = FileClassifier.language(path: path)
        guard (text as NSString).length < 500_000 else { return }
        let current = generation
        Task.detached(priority: .utility) { [weak self] in
            let spans = SyntaxHighlighter.spans(text: text, language: language)
            await MainActor.run {
                guard let self, self.generation == current, let layout = self.textView.layoutManager else { return }
                let full = NSRange(location: 0, length: (self.textView.string as NSString).length)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                for span in spans where NSMaxRange(span.range) <= full.length {
                    layout.addTemporaryAttribute(.foregroundColor, value: span.kind.color, forCharacterRange: span.range)
                }
            }
        }
    }

    func applySettings() {
        let settings = model.settings
        textView.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSize))
        gutter.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSize) - 1)
        textView.needsDisplay = true
    }

    func focus() { textView.window?.makeFirstResponder(textView) }
    func teardown() {
        token = nil
        model.languageServers.viewerClosed(path)
    }

    func select(text: String, to end: String?) -> Bool {
        let string = textView.string as NSString
        let start = string.range(of: text)
        guard start.location != NSNotFound else { return false }
        var range = start
        if let end {
            let rest = NSRange(location: NSMaxRange(start), length: string.length - NSMaxRange(start))
            let found = string.range(of: end, options: [], range: rest)
            guard found.location != NSNotFound else { return false }
            range = NSRange(location: start.location, length: NSMaxRange(found) - start.location)
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    /// The selected rows, as they appear in the diff. Removed lines aren't in the file any more,
    /// so a line number couldn't point at them: the agent gets the change itself.
    var agentReference: AgentSelection? {
        let rows = selectedRows
        guard !rows.isEmpty else { return AgentSelection(path: path) }
        return AgentSelection(path: path, quote: DiffQuote.text(path: path, rows: rows))
    }

    var symbolTextView: NSTextView { textView }

    /// A row's text is a line of the file, unless it's a removed row or a hunk's heading.
    func fileLocation(ofCharacter index: Int) -> (line: Int, character: Int)? {
        let string = textView.string as NSString
        guard index <= string.length else { return nil }
        let before = string.substring(to: index)
        let row = before.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        guard row < diff.lines.count, let line = diff.lines[row].newLine else { return nil }
        let start = (before as NSString).range(of: "\n", options: .backwards)
        return (line - 1, start.location == NSNotFound ? index : index - NSMaxRange(start))
    }

    /// With nothing selected, a comment is on the row the cursor is in.
    var reviewAnchor: ReviewAnchor? {
        var rows = selectedRows
        if rows.isEmpty {
            let string = textView.string as NSString
            let before = string.substring(to: min(textView.selectedRange().location, string.length))
            let index = before.utf16.filter { $0 == 10 }.count
            guard index < diff.lines.count else { return ReviewAnchor(path: path) }
            rows = diff.lines[index...index]
        }
        let body = rows.filter { $0.kind != .hunk }
        guard !body.isEmpty else { return ReviewAnchor(path: path) }
        let numbers = body.compactMap(\.newLine)
        let kept = body.filter { $0.kind != .removed }.map(\.text)
        return ReviewAnchor(path: path, firstLine: numbers.first, lastLine: numbers.last,
                            excerpt: kept.isEmpty ? nil : kept.joined(separator: "\n"),
                            quote: DiffQuote.rows(body), quoteIsDiff: true)
    }

    var reviewPopoverPosition: (view: NSView, rect: NSRect)? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let range = textView.selectedRange()
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if rect.height < 1 { rect.size.height = 16 }
        return rect.intersects(textView.visibleRect) ? (textView, rect) : nil
    }

    func reviewChanged() {
        gutter.commentMarkers = model.reviewMarkers(for: path, rows: diff.lines)
    }

    private var selectedRows: ArraySlice<DiffLine> {
        let string = textView.string as NSString
        let range = textView.selectedRange()
        guard range.length > 0 else { return [] }
        func row(at location: Int) -> Int {
            var count = 0
            var search = NSRange(location: 0, length: min(location, string.length))
            while true {
                let found = string.range(of: "\n", options: .literal, range: search)
                if found.location == NSNotFound { return count }
                count += 1
                search = NSRange(location: NSMaxRange(found), length: min(location, string.length) - NSMaxRange(found))
            }
        }
        let first = row(at: range.location)
        // A selection ending just after a newline doesn't reach into the next row.
        let endsAtLineStart = string.character(at: NSMaxRange(range) - 1) == 10
        let last = row(at: NSMaxRange(range)) - (endsAtLineStart ? 1 : 0)
        guard first < diff.lines.count else { return [] }
        return diff.lines[first...min(max(last, first), diff.lines.count - 1)]
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        // Claude sees it too, as lines of the file as it stands, where the rows have numbers.
        let rows = selectedRows
        let numbers = rows.compactMap(\.newLine)
        guard let first = numbers.first, let last = numbers.last, textView.window != nil else { return }
        let text = rows.filter { $0.kind != .removed && $0.kind != .hunk }.map(\.text).joined(separator: "\n")
        model.editorBridge.selectionChanged(EditorSelection(path: path, text: text, startLine: first - 1, startCharacter: 0,
                                                            endLine: last - 1, endCharacter: rows.last?.text.utf16.count ?? 0))
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        var index = 0
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        if view.selectedRange().length > 0 { add("Quote in Agent", #selector(quoteSelection)) }
        add("Add Comment", #selector(addComment))
        if SymbolText.word(in: view.string as NSString, at: charIndex) != nil {
            // A right-click doesn't move the cursor, and it's what was clicked that's being asked about.
            view.setSelectedRange(NSRange(location: charIndex, length: 0))
            add("Go to Definition", #selector(goToDefinitionFromMenu))
            add("Find References", #selector(findReferencesFromMenu))
        }
        if let line = fileLocation(ofCharacter: charIndex)?.line {
            let problems = model.languageServers.knownDiagnostics(for: path).filter { $0.line <= line && line <= $0.endLine }
            if !problems.isEmpty {
                menuProblems = problems
                add("Quote Problem in Agent", #selector(quoteProblems))
            }
        }
        menu.insertItem(.separator(), at: index)
        return menu
    }

    @objc private func quoteSelection() { model.addFrontToAgent() }
    @objc private func addComment() { model.beginReviewComment() }
    @objc private func goToDefinitionFromMenu() { model.goToDefinition() }
    @objc private func findReferencesFromMenu() { model.findReferences() }
    @objc private func quoteProblems() { model.quoteDiagnostics(menuProblems, path: path) }

    var supportsFind: Bool { true }

    func find(_ query: String, backwards: Bool) -> Bool {
        let string = textView.string as NSString
        let current = textView.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let start = backwards ? current.location : NSMaxRange(current)
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: string.length - start)
        var found = string.range(of: query, options: options, range: range)
        if found.location == NSNotFound { found = string.range(of: query, options: options) }
        guard found.location != NSNotFound else { return false }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }
}

/// A row's color runs the full width of the pane, past the end of the text.
final class DiffTextView: NSTextView {
    var lines: [DiffLine] = []

    static func color(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.16)
        case .removed: NSColor.systemRed.withAlphaComponent(0.16)
        case .hunk: NSColor.secondaryLabelColor.withAlphaComponent(0.1)
        case .context: nil
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, !lines.isEmpty else { return }
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let string = self.string as NSString
        var lineIndex: Int?
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            if lineIndex == nil {
                // Only the first needs counting. After that they go one at a time.
                var count = 0
                string.enumerateSubstrings(in: NSRange(location: 0, length: character), options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
                lineIndex = count
            }
            if let index = lineIndex, index < self.lines.count, let color = Self.color(for: self.lines[index].kind) {
                color.setFill()
                NSRect(x: 0, y: fragment.minY + self.textContainerInset.height, width: max(self.bounds.width, rect.maxX), height: fragment.height)
                    .fill(using: .sourceOver)
            }
            lineIndex = (lineIndex ?? 0) + 1
        }
    }
}

/// Old and new line numbers, side by side.
final class DiffGutter: NSView {
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    var lines: [DiffLine] = [] { didSet { needsDisplay = true } }
    /// Row, counting from 0, to the comments on it.
    var commentMarkers: [Int: [ReviewComment]] = [:] { didSet { needsDisplay = true } }
    private var markerHits: [(rect: NSRect, comments: [ReviewComment])] = []
    /// Row, counting from 0, to the worst thing wrong with it.
    var problemRows: [Int: LSPDiagnostic.Severity] = [:] { didSet { needsDisplay = true } }
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private let columnWidth: CGFloat = 40
    var thickness: CGFloat { columnWidth * 2 + 8 }

    override var isFlipped: Bool { true }

    func attach(to scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        let string = text.string as NSString
        var index: Int?
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        markerHits = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            if index == nil {
                var count = 0
                string.enumerateSubstrings(in: NSRange(location: 0, length: layout.characterIndexForGlyph(at: range.location)),
                                           options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
                index = count
            }
            guard let current = index, current < self.lines.count else { return }
            let line = self.lines[current]
            let y = text.convert(NSPoint(x: 0, y: fragment.minY + text.textContainerInset.height), to: self).y
            if let color = DiffTextView.color(for: line.kind) {
                color.setFill()
                NSRect(x: 0, y: y, width: self.thickness, height: fragment.height).fill(using: .sourceOver)
            }
            for (number, column) in [(line.oldLine, CGFloat(0)), (line.newLine, self.columnWidth)] {
                guard let number else { continue }
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: column + self.columnWidth - size.width - 2, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            }
            if let comments = self.commentMarkers[current] {
                self.markerHits.append((ReviewMarker.draw(atY: y, lineHeight: fragment.height), comments))
            }
            if let severity = self.problemRows[current] {
                ProblemMarks.drawDot(severity: severity, x: self.thickness - 6, y: y, lineHeight: fragment.height)
            }
            index = current + 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = markerHits.first(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(point) }) {
            AppModel.shared.editReviewComment(hit.comments[0], from: self, rect: hit.rect)
            return
        }
        super.mouseDown(with: event)
    }
}

final class DiffContainer: NSView {
    private var gutter: DiffGutter?
    private var scrollView: NSScrollView?
    private var message: NSTextField?
    private let problemsBar = NSView()
    private let problemsLabel = NSTextField(labelWithString: "")
    private let problemsIcon = NSImageView()
    private let problemsButton = NSButton(title: "Quote in Agent", target: nil, action: nil)
    private var onQuoteProblems: (() -> Void)?
    private static let problemsHeight: CGFloat = 26

    func showProblems(_ text: String?, count: Int, onQuote: (() -> Void)?) {
        onQuoteProblems = onQuote
        let shown = text != nil
        problemsBar.isHidden = !shown
        problemsLabel.stringValue = text ?? ""
        let symbol = count > 0 ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
        problemsIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        problemsIcon.contentTintColor = count > 0 ? .systemRed : .systemOrange
        needsLayout = true
    }

    @objc private func quoteProblems() { onQuoteProblems?() }

    func install(gutter: DiffGutter, scrollView: NSScrollView, message: NSTextField) {
        self.gutter = gutter
        self.scrollView = scrollView
        self.message = message
        addSubview(gutter)
        addSubview(scrollView)
        addSubview(message)
        message.isHidden = true
        problemsBar.wantsLayer = true
        problemsBar.isHidden = true
        problemsLabel.font = .systemFont(ofSize: 11.5)
        problemsLabel.textColor = .secondaryLabelColor
        problemsButton.controlSize = .small
        problemsButton.bezelStyle = .accessoryBarAction
        problemsButton.target = self
        problemsButton.action = #selector(quoteProblems)
        problemsButton.font = .systemFont(ofSize: 11)
        problemsButton.sizeToFit()
        for view in [problemsIcon, problemsLabel, problemsButton] as [NSView] { problemsBar.addSubview(view) }
        addSubview(problemsBar)
    }

    func showMessage(_ text: String?) {
        message?.stringValue = text ?? ""
        message?.isHidden = text == nil
        gutter?.isHidden = text != nil
        scrollView?.isHidden = text != nil
    }

    override func layout() {
        super.layout()
        let width = gutter?.thickness ?? 0
        let bar = problemsBar.isHidden ? 0 : Self.problemsHeight
        // This view's origin is at its bottom, unless it's flipped, and the bar goes on top either way.
        let contentY: CGFloat = isFlipped ? bar : 0
        let contentHeight = max(bounds.height - bar, 0)
        gutter?.frame = CGRect(x: 0, y: contentY, width: width, height: contentHeight)
        scrollView?.frame = CGRect(x: width, y: contentY, width: max(bounds.width - width, 0), height: contentHeight)
        problemsBar.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - bar, width: bounds.width, height: bar)
        problemsIcon.frame = CGRect(x: 12, y: 6, width: 14, height: 14)
        let buttonWidth = problemsButton.frame.width
        problemsButton.frame = CGRect(x: bounds.width - buttonWidth - 12, y: 3, width: buttonWidth, height: 20)
        problemsLabel.frame = CGRect(x: 32, y: 5, width: max(bounds.width - buttonWidth - 56, 0), height: 16)
        message?.frame = CGRect(x: 20, y: bounds.midY - 12, width: max(bounds.width - 40, 0), height: 24)
        gutter?.needsDisplay = true
    }
}

// MARK: - The sidebar section

struct ChangesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.visibleChanges) { change in
                    ChangeRow(change: change)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

struct ChangeRow: View {
    let change: ChangedFile
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var isActive: Bool {
        guard case .diff(let spec)? = model.active.activeItem?.content else { return false }
        return spec.path == change.path && spec.turn == model.scopedTurn?.id
    }

    private var statusColor: Color {
        switch change.status {
        case .modified: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .renamed: .blue
        }
    }

    private var name: String { (change.path as NSString).lastPathComponent }

    private var detail: String {
        let folder = model.active.folder(containing: change.path)
        let relative = folder != nil ? model.active.relativePath(change.path) : change.relative
        let directory = (relative as NSString).deletingLastPathComponent
        guard model.active.folders.count > 1, let folder else { return directory }
        let folderName = (folder as NSString).lastPathComponent
        return directory.isEmpty ? folderName : folderName + " • " + directory
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcons.symbolName(forName: name, isDirectory: false))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            // Dated file names differ at the end, so the middle is what goes.
            Text(name)
                .font(.system(size: 12.5))
                .strikethrough(change.status == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            // Long names give way to this, never the other way round.
            Text(change.status.letter)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .fixedSize()
                .layoutPriority(2)
                .help(change.status.rawValue.capitalized)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click previews, like the explorer. A second keeps it.
        .onTapGesture { model.openDiff(path: change.path, preview: true, turn: model.scopedTurn?.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openDiff(path: change.path, preview: false, turn: model.scopedTurn?.id) })
        .contextMenu {
            Button("Open Changes") { model.openDiff(path: change.path, preview: false, turn: model.scopedTurn?.id) }
            if change.status != .deleted {
                Button("Open File") { model.open(path: change.path, intent: .pinned); model.requestFocus() }
            }
            Button("Add to Agent") { model.addFilesToAgent([change.path]) }
            Divider()
            Button("Copy Path") { Clipboard.copy(change.path) }
        }
    }
}
