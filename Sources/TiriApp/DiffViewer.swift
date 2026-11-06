import AppKit
import CryptoKit
import SwiftUI
import TiriCore

/// What an agent changed in one file. An item like any other: a tab, a split or a Peek.
final class DiffController: NSObject, ItemController, SymbolViewing, NSTextViewDelegate {
    let itemID: ItemID
    let spec: DiffSpec
    var path: String { spec.path }
    /// One agent's turn, or nil for what `spec.target` says.
    private var turn: String? { spec.turn }
    private unowned let model: AppModel
    /// The one column, or the new side when there are two.
    private let main = DiffPane(side: .inline)
    /// The old side, once it's been wanted.
    private var old: DiffPane?
    private var activePane: DiffPane
    /// The column under the mouse, when it's a name there that's being asked about.
    private var askedPane: DiffPane?
    private let container = DiffContainer()
    private var token: FileWatchHub.Token?
    private var generation = 0
    private var firstLoad = true
    private var wasMissing = false
    private var shownImages: Data?
    private let message = NSTextField(labelWithString: "")
    private var quoteButtons: [QuoteButton] = []
    private var menuProblems: [LSPDiagnostic] = []
    private(set) var diff = FileDiff()
    private var pairs: [Int: Int] = [:]
    private var wordRanges: [Int: [NSRange]] = [:]
    private var changeStarts: [Int] = []
    /// Which change F7 last went to.
    private var currentChange: Int?
    /// A line to go to once the diff has loaded.
    private var pendingLine: Int?
    private var syncingScroll = false
    private var scrollObservers: [NSObjectProtocol] = []
    /// Over the change the mouse is on.
    private let changeActions = ChangeActionsView()
    private var hoveredChange: ClosedRange<Int>?

    var view: NSView { container }

    init(itemID: ItemID, spec: DiffSpec, model: AppModel) {
        self.itemID = itemID
        self.spec = spec
        self.model = model
        activePane = main
        super.init()
        configure(main)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        container.install(main: main, message: message)
        container.onWidthChange = { [weak self] in self?.layoutModeMayHaveChanged() }
        changeActions.isHidden = true
        changeActions.onUndo = { [weak self] in self?.requestHoveredChange(.undo) }
        changeActions.onAsk = { [weak self] in self?.requestHoveredChange(.ask) }
        container.addSubview(changeActions)
        applySettings()
        // A commit stays what it was, whatever happens to the file.
        if spec.commit == nil {
            token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        }
        load()
        model.languageServers.viewerOpened(path, viewer: self) { nil }
    }

    private func configure(_ pane: DiffPane) {
        pane.textView.delegate = self
        pane.textView.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activePane = pane
        }
        pane.wordRanges = { [weak self] line in self?.changedRanges(ofLine: line) ?? [] }
        pane.textView.onHoverRow = { [weak self, weak pane] row in
            guard let self, let pane else { return }
            self.hover(row: row, in: pane)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: pane.textView)
        let button = QuoteButton(textView: pane.textView, scrollView: pane.scrollView, host: container)
        button.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        quoteButtons.append(button)
        pane.scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView, queue: .main) { [weak self, weak pane] _ in
            MainActor.assumeIsolated {
                guard let pane else { return }
                self?.scrollOtherSide(from: pane)
                self?.hideChangeActions()
            }
        })
    }

    isolated deinit {
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private var panes: [DiffPane] { showsTwoColumns ? [old ?? main, main] : [main] }

    /// The two columns scroll as one.
    private func scrollOtherSide(from pane: DiffPane) {
        guard showsTwoColumns, !syncingScroll, let old else { return }
        let other = pane === main ? old : main
        syncingScroll = true
        other.scrollView.contentView.scroll(to: pane.scrollView.contentView.bounds.origin)
        other.scrollView.reflectScrolledClipView(other.scrollView.contentView)
        syncingScroll = false
    }

    // MARK: One column or two

    private var showsTwoColumns = false

    /// Side by side needs room for both. In a narrow pane or Peek it stays in one column.
    private var wantsTwoColumns: Bool {
        model.settings.diffSideBySide && (container.bounds.width == 0 || container.bounds.width >= DiffContainer.narrowestTwoColumns)
    }

    var isTooNarrowForTwoColumns: Bool { container.bounds.width > 0 && container.bounds.width < DiffContainer.narrowestTwoColumns }

    private func layoutModeMayHaveChanged() {
        model.controllerRevision += 1
        guard wantsTwoColumns != showsTwoColumns, !firstLoad else { return }
        rebuildPanes(keepingPlace: true)
    }

    /// Puts the diff's lines into the columns.
    private func rebuildPanes(keepingPlace: Bool) {
        let top = keepingPlace ? activePane.topLine : nil
        showsTwoColumns = wantsTwoColumns
        if showsTwoColumns {
            if old == nil {
                let pane = DiffPane(side: .old)
                configure(pane)
                container.install(old: pane)
                pane.apply(font: textFont, gutterFont: gutterFont)
                old = pane
            }
            let rows = DiffRows.sideBySide(diff.lines)
            old?.set(rows: rows.map(\.left), lines: diff.lines, side: .old, counterpart: rows.map(\.right))
            main.set(rows: rows.map(\.right), lines: diff.lines, side: .new, counterpart: rows.map(\.left))
        } else {
            old?.textView.setSelectedRange(NSRange(location: 0, length: 0))
            activePane = main
            main.set(rows: diff.lines.indices.map { $0 }, lines: diff.lines, side: .inline, counterpart: [])
        }
        container.showsOld = showsTwoColumns
        for pane in panes { scheduleHighlight(pane) }
        reviewChanged()
        diagnosticsChanged()
        applyCurrentChange()
        if let top { scroll(toLine: top, atTop: true) }
    }

    func toggleLayout() {
        _ = model.setSetting("diff.sideBySide", to: .bool(!model.settings.diffSideBySide))
    }

    var isSideBySide: Bool { model.settings.diffSideBySide }

    // MARK: Loading

    func didAttach() {
        model.languageServers.viewerShown(path)
        // Edits not saved yet may have changed since it was last showing.
        if spec.unsaved == true, !firstLoad { load() }
    }

    /// Only what this change is answerable for: the lines it added, in the file as it is now.
    /// A finished turn's or a commit's lines may not be the file's any more, so it shows nothing.
    func diagnosticsChanged() {
        for pane in panes { ProblemMarks.clear(pane.textView) }
        guard spec.commit == nil, turn == nil || model.turn(id: turn ?? "")?.isOpen == true else {
            container.showProblems(nil, count: 0, onQuote: nil)
            main.gutter.problemRows = [:]
            return
        }
        let found = LSP.onAddedRows(model.languageServers.knownDiagnostics(for: path), rows: diff.lines)
        var rows: [Int: LSPDiagnostic.Severity] = [:]
        let index = LineIndex(main.textView.string as NSString)
        let rowOfLine = Dictionary(diff.lines.enumerated().compactMap { row, line in line.newLine.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        for problem in found.sorted(by: { $0.severity > $1.severity }) {
            guard let line = rowOfLine[problem.line + 1], let row = main.row(ofLine: line) else { continue }
            rows[row] = problem.severity
            guard let start = index.location(line: row, character: problem.character) else { continue }
            // Only as far as this row: the next row in a diff isn't the next line of the file.
            let rowEnd = index.start(ofLine: row + 1).map { $0 - 1 } ?? (main.textView.string as NSString).length
            let end = problem.endLine == problem.line ? min(start + max(problem.endCharacter - problem.character, 0), rowEnd) : rowEnd
            ProblemMarks.underline(NSRange(location: start, length: max(end - start, 0)), severity: problem.severity, in: main.textView)
        }
        main.gutter.problemRows = rows
        let errors = found.filter { $0.severity == .error }.count
        let text: String?
        if found.isEmpty {
            text = nil
        } else if errors == found.count {
            text = errors == 1 ? String(localized: "1 error on lines this change added") : String(localized: "\(errors) errors on lines this change added")
        } else {
            text = found.count == 1 ? String(localized: "1 problem on lines this change added") : String(localized: "\(found.count) problems on lines this change added")
        }
        container.showProblems(text, count: errors) { [weak self] in
            guard let self else { return }
            self.model.quoteDiagnostics(found, path: self.path)
        }
    }

    /// What one load found, worked out away from the main thread.
    nonisolated private struct Loaded: @unchecked Sendable {
        var diff: FileDiff?
        var pairs: [Int: Int] = [:]
        var starts: [Int] = []
        var note: String?
        var images: ImageDiffView.Content?
    }

    /// Other things change the answer too, like a commit. The app asks after any change it sees.
    func load() {
        // A commit doesn't change, unless it couldn't be found.
        if spec.commit != nil, !firstLoad, !wasMissing { return }
        generation += 1
        let current = generation
        let spec = spec
        let found = spec.turn.flatMap { model.turn(id: $0) }
        let snapshots = model.snapshots
        let scale = view.window?.backingScaleFactor ?? 2
        let unsaved = spec.unsaved == true ? model.unsavedText(of: path) : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = spec.unsaved == true ? Self.read(spec.path, against: unsaved) : Self.read(spec, turn: found, snapshots: snapshots, scale: scale)
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.display(loaded)
            }
        }
    }

    /// The file on disk, old, against edits not saved yet, new: what saving them would change.
    nonisolated private static func read(_ path: String, against unsaved: String?) -> Loaded {
        var loaded = Loaded()
        let data = FileManager.default.contents(atPath: path) ?? Data()
        let disk = TextEncodings.decode(data)?.text ?? String(decoding: data, as: UTF8.self)
        let diff = unsaved.map { ChangedText.fileDiff(from: disk, to: $0) } ?? FileDiff()
        loaded.diff = diff
        loaded.pairs = DiffRows.pairs(diff.lines)
        loaded.starts = DiffRows.changeStarts(diff.lines)
        return loaded
    }

    nonisolated private static func read(_ spec: DiffSpec, turn: AgentTurn?, snapshots: TurnSnapshots, scale: CGFloat) -> Loaded {
        var loaded = Loaded()
        let path = spec.path
        loaded.diff = spec.turn != nil ? turn.flatMap { snapshots.diff(path: path, in: $0) } : Git.diff(path: path, target: spec.target)
        guard let diff = loaded.diff else { return loaded }
        loaded.pairs = DiffRows.pairs(diff.lines)
        loaded.starts = DiffRows.changeStarts(diff.lines)
        var notes: [String] = []
        if let oid = spec.commit, let root = Git.repositoryRoot(ofFile: path), let commit = Git.commitSummary(oid, in: root) {
            notes.append("\(commit.shortOID) \(commit.subject)")
            if commit.isMerge { notes.append(String(localized: "compared with its first parent")) }
        } else if spec.branch == true, let root = Git.repositoryRoot(ofFile: path) {
            notes.append(Git.branchBase(root: root).displayDescription)
        }
        if let old = diff.oldRelative, !diff.lines.isEmpty { notes.append(String(localized: "renamed from \(old)")) }
        loaded.note = notes.isEmpty ? nil : notes.joined(separator: " · ")
        if diff.isBinary, FileClassifier.classify(path: path) == .image {
            let versions: FileVersions
            if spec.turn != nil {
                versions = turn.flatMap { snapshots.versions(path: path, in: $0) } ?? FileVersions()
            } else {
                versions = Git.versions(path: path, target: spec.target)
            }
            loaded.images = ImageDiffView.Content(versions: versions, scale: scale)
        }
        return loaded
    }

    private func display(_ loaded: Loaded) {
        let result = loaded.diff ?? FileDiff()
        let missing = loaded.diff == nil
        wasMissing = missing
        let keepPlace = !firstLoad
        let origin = main.scrollView.contentView.bounds.origin
        let linesChanged = result.lines != diff.lines || firstLoad
        diff = result
        pairs = loaded.pairs
        changeStarts = loaded.starts
        model.controllerRevision += 1
        container.showNote(loaded.note)
        if loaded.images?.fingerprint != shownImages {
            shownImages = loaded.images?.fingerprint
            container.showImages(loaded.images)
        }
        container.showMessage(loaded.images != nil ? nil : messageText(for: result, missing: missing))
        if linesChanged {
            wordRanges = [:]
            currentChange = nil
            rebuildPanes(keepingPlace: false)
            if keepPlace {
                main.scrollView.contentView.scroll(to: origin)
                main.scrollView.reflectScrolledClipView(main.scrollView.contentView)
            }
        } else {
            reviewChanged()
            diagnosticsChanged()
        }
        model.languageServers.fileMayHaveChanged(path)
        for pane in panes { pane.redraw() }
        firstLoad = false
        if let line = pendingLine {
            pendingLine = nil
            goTo(line: line, col: nil)
        }
        AppModel.shared.viewerReady(itemID)
    }

    private func messageText(for result: FileDiff, missing: Bool) -> String? {
        if missing { return spec.commit != nil ? String(localized: "Tiri can't find this commit any more.") : String(localized: "Tiri no longer has this turn's snapshot.") }
        if result.isBinary { return String(localized: "This is a binary file. Git can't show its changes line by line.") }
        guard result.isEmpty else { return nil }
        if let old = result.oldRelative { return String(localized: "Renamed from \(old), with no other changes.") }
        if let note = result.note { return note }
        if spec.commit != nil { return String(localized: "This commit didn't change this file.") }
        if turn != nil { return String(localized: "This turn didn't change this file.") }
        if spec.branch == true { return String(localized: "This branch didn't change this file.") }
        return String(localized: "No changes in this file.")
    }

    /// A plugin came or went, so this file may be another language now.
    func languagesChanged() {
        load()
    }

    private func scheduleHighlight(_ pane: DiffPane) {
        pane.highlighter.use(language: LanguageCatalog.language(forPath: path))
        pane.highlighter.textReplaced()
    }

    private var textFont: NSFont {
        TerminalTheme.font(family: model.settings.codeFontFamily, size: CGFloat(model.settings.codeFontSizeZoomed))
    }

    private var gutterFont: NSFont {
        TerminalTheme.font(family: model.settings.codeFontFamily, size: CGFloat(model.settings.codeFontSizeZoomed) - 1)
    }

    func applySettings() {
        main.apply(font: textFont, gutterFont: gutterFont)
        old?.apply(font: textFont, gutterFont: gutterFont)
        model.controllerRevision += 1
        if !firstLoad, wantsTwoColumns != showsTwoColumns { rebuildPanes(keepingPlace: true) }
    }

    func focus() { activePane.textView.window?.makeFirstResponder(activePane.textView) }
    func teardown() {
        token = nil
        model.languageServers.viewerClosed(path, viewer: self)
    }

    // MARK: Going to a change

    /// A line of the file: the change at or after it. It's how a mark beside a file's line arrives here.
    func goTo(line: Int?, col: Int?) {
        guard let line else { return }
        if firstLoad {
            pendingLine = line
            return
        }
        guard let row = DiffRows.changeRow(atOrAfterLine: line, in: diff.lines) else { return }
        currentChange = changeStarts.lastIndex { $0 <= row }
        applyCurrentChange()
        scroll(toLine: row, atTop: false)
    }

    /// F7 and ⇧F7, round and round.
    func goToChange(forward: Bool) {
        guard !changeStarts.isEmpty else { return }
        let next: Int
        if let currentChange {
            next = (currentChange + (forward ? 1 : -1) + changeStarts.count) % changeStarts.count
        } else {
            // From what's on screen, the first time.
            let top = activePane.topLine ?? 0
            if forward {
                next = changeStarts.firstIndex { $0 >= top } ?? 0
            } else {
                next = changeStarts.lastIndex { $0 < top } ?? changeStarts.count - 1
            }
        }
        currentChange = next
        applyCurrentChange()
        scroll(toLine: changeStarts[next], atTop: false)
    }

    /// The change that F7 is on gets a bar beside it, since a diff has no cursor to show.
    private func applyCurrentChange() {
        var range: Range<Int>?
        if let currentChange, currentChange < changeStarts.count {
            let start = changeStarts[currentChange]
            var end = start
            while end < diff.lines.count, diff.lines[end].kind == .added || diff.lines[end].kind == .removed { end += 1 }
            range = start..<end
        }
        for pane in panes { pane.gutter.currentLines = range }
    }

    /// Puts a line of the diff on screen: a third of the way down, or at the very top to keep a place.
    private func scroll(toLine line: Int, atTop: Bool) {
        let pane = activePane
        guard let row = pane.row(ofLine: line) ?? pane.nearestRow(toLine: line) else { return }
        let clip = pane.scrollView.contentView
        pane.textView.layoutManager?.ensureLayout(forCharacterRange: pane.range(ofRow: row))
        let y = pane.y(ofRow: row) - (atTop ? 0 : clip.bounds.height / 3)
        let highest = max(pane.textView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: atTop ? clip.bounds.origin.x : 0, y: min(max(y, 0), highest)))
        pane.scrollView.reflectScrolledClipView(clip)
        pane.textView.setSelectedRange(NSRange(location: pane.range(ofRow: row).location, length: 0))
    }

    // MARK: Selecting

    func select(text: String, to end: String?) -> Bool {
        for pane in [activePane] + panes.filter({ $0 !== activePane }) {
            let string = pane.textView.string as NSString
            let start = string.range(of: text)
            guard start.location != NSNotFound else { continue }
            var range = start
            if let end {
                let rest = NSRange(location: NSMaxRange(start), length: string.length - NSMaxRange(start))
                let found = string.range(of: end, options: [], range: rest)
                guard found.location != NSNotFound else { continue }
                range = NSRange(location: start.location, length: NSMaxRange(found) - start.location)
            }
            activePane = pane
            pane.textView.setSelectedRange(range)
            pane.textView.scrollRangeToVisible(range)
            return true
        }
        return false
    }

    private var shortCommit: String? { spec.commit.map { String($0.prefix(7)) } }

    /// The selected rows, as they appear in the diff. Removed lines aren't in the file any more,
    /// so a line number couldn't point at them: the agent gets the change itself.
    var agentReference: AgentSelection? {
        let rows = selectedRows
        guard !rows.isEmpty else { return AgentSelection(path: path) }
        return AgentSelection(path: path, quote: DiffQuote.text(path: path, rows: rows, commit: shortCommit))
    }

    var symbolTextView: NSTextView { (askedPane ?? activePane).textView }
    var symbolTextViews: [NSTextView] { panes.map(\.textView) }

    /// The mouse can be over one column with the selection in the other, so this doesn't move the selection.
    func willAsk(about view: NSTextView?) {
        askedPane = panes.first { $0.textView === view }
    }

    /// A row's text is a line of the file, unless it's a removed row or a hunk's heading. A
    /// commit's rows are the file as it was then, and a language server only knows it as it is.
    func fileLocation(ofCharacter index: Int) -> (line: Int, character: Int)? {
        let pane = askedPane ?? activePane
        guard spec.commit == nil, index <= pane.length else { return nil }
        let row = pane.row(atCharacter: index)
        guard row < pane.rows.count, let source = pane.rows[row], let line = diff.lines[source].newLine else { return nil }
        return (line - 1, index - pane.range(ofRow: row).location)
    }

    // MARK: Telling the agent about a change

    /// Hovering over a change offers what you'd want to say about it. Doing it is the agent's job.
    func hover(row: Int?, in pane: DiffPane) {
        // Asking an agent to undo is for what an agent changed, not for edits of your own.
        guard spec.unsaved != true, let row, row < pane.rows.count, let line = pane.rows[row] ?? (row < pane.counterpart.count ? pane.counterpart[row] : nil),
              let change = DiffHunks.change(around: line, in: diff.lines) else {
            // On its way to the buttons, the mouse is still over the change.
            if !changeActions.isHidden, changeActions.frame.contains(container.convert(NSEvent.mouseLocationInWindow(of: container), from: nil)) { return }
            hideChangeActions()
            return
        }
        hoveredChange = change
        let firstRow = pane.rows.firstIndex { $0.map(change.contains) == true } ?? row
        let point = pane.textView.convert(NSPoint(x: 0, y: pane.y(ofRow: firstRow)), to: container)
        let size = changeActions.fittingSize
        let right = pane.scrollView.convert(NSPoint(x: pane.scrollView.bounds.maxX, y: 0), to: container).x
        changeActions.frame = NSRect(x: right - size.width - 18, y: point.y - size.height - 1, width: size.width, height: size.height)
        changeActions.isHidden = false
    }

    func hideChangeActions() {
        changeActions.isHidden = true
        hoveredChange = nil
    }

    private func requestHoveredChange(_ kind: ChangeRequest.Kind) {
        guard let change = hoveredChange else { return }
        hideChangeActions()
        request(kind, lines: Array(diff.lines[change]))
    }

    private func request(_ kind: ChangeRequest.Kind, lines: [DiffLine]?) {
        model.tellAgentAboutChange(path: path, prompt: ChangeRequest.prompt(kind, path: path, commit: spec.commit, lines: lines))
    }

    /// For a test copy, where nothing can hover: what the mouse being on this row would do.
    func hoverForTest(row: Int) { hover(row: row, in: activePane) }
    func requestForTest(_ kind: ChangeRequest.Kind) { requestHoveredChange(kind) }

    private var menuChange: [DiffLine]?

    @objc private func undoFromMenu() { request(.undo, lines: menuChange) }
    @objc private func askFromMenu() { request(.ask, lines: menuChange) }
    @objc private func undoFileFromMenu() { request(.undo, lines: nil) }

    /// With nothing selected, a comment is on the row the cursor is in.
    var reviewAnchor: ReviewAnchor? {
        var rows = selectedRows
        if rows.isEmpty {
            let row = activePane.row(atCharacter: activePane.textView.selectedRange().location)
            rows = lines(inRows: row...row)
            guard !rows.isEmpty else { return ReviewAnchor(path: path, commit: spec.commit) }
        }
        let body = rows.filter { $0.kind != .hunk }
        guard !body.isEmpty else { return ReviewAnchor(path: path, commit: spec.commit) }
        let numbers = body.compactMap(\.newLine)
        let kept = body.filter { $0.kind != .removed }.map(\.text)
        return ReviewAnchor(path: path, firstLine: numbers.first, lastLine: numbers.last,
                            excerpt: kept.isEmpty ? nil : kept.joined(separator: "\n"),
                            quote: DiffQuote.rows(body), quoteIsDiff: true, commit: spec.commit)
    }

    var reviewPopoverPosition: (view: NSView, rect: NSRect)? {
        let textView = activePane.textView
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
        let markers = model.reviewMarkers(for: path, rows: diff.lines, commit: spec.commit)
        for pane in panes {
            var rows: [Int: [ReviewComment]] = [:]
            for (line, comments) in markers {
                if let row = pane.row(ofLine: line) { rows[row] = comments }
            }
            pane.gutter.commentMarkers = rows
        }
    }

    /// Both sides of those rows, in the diff's own order: quoting a change means quoting the change.
    private func lines(inRows rows: ClosedRange<Int>) -> [DiffLine] {
        var found = Set<Int>()
        for row in rows {
            if row < activePane.rows.count, let line = activePane.rows[row] { found.insert(line) }
            if row < activePane.counterpart.count, let line = activePane.counterpart[row] { found.insert(line) }
        }
        return found.sorted().map { diff.lines[$0] }
    }

    private var selectedRows: [DiffLine] {
        let pane = activePane
        let range = pane.textView.selectedRange()
        guard range.length > 0 else { return [] }
        let first = pane.row(atCharacter: range.location)
        // A selection ending just after a newline doesn't reach into the next row.
        let string = pane.textView.string as NSString
        let endsAtLineStart = string.character(at: NSMaxRange(range) - 1) == 10
        let last = pane.row(atCharacter: NSMaxRange(range)) - (endsAtLineStart ? 1 : 0)
        guard first < pane.rows.count else { return [] }
        return lines(inRows: first...min(max(last, first), pane.rows.count - 1))
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard let view = notification.object as? DiffTextView, let pane = panes.first(where: { $0.textView === view }) else { return }
        // One selection at a time, across the two columns.
        if view.selectedRange().length > 0 {
            activePane = pane
            for other in panes where other !== pane && other.textView.selectedRange().length > 0 {
                other.textView.setSelectedRange(NSRange(location: other.textView.selectedRange().location, length: 0))
            }
        }
        // Claude sees it too, as lines of the file as it stands, where the rows have numbers.
        guard spec.commit == nil, pane === activePane else { return }
        let rows = selectedRows
        let numbers = rows.compactMap(\.newLine)
        guard let first = numbers.first, let last = numbers.last, view.window != nil else { return }
        let text = rows.filter { $0.kind != .removed && $0.kind != .hunk }.map(\.text).joined(separator: "\n")
        model.editorBridge.selectionChanged(EditorSelection(path: path, text: text, startLine: first - 1, startCharacter: 0,
                                                            endLine: last - 1, endCharacter: rows.last?.text.utf16.count ?? 0))
    }

    /// Which parts of a changed row changed, worked out as rows come on screen.
    private func changedRanges(ofLine line: Int) -> [NSRange] {
        if let known = wordRanges[line] { return known }
        guard let other = pairs[line], line < diff.lines.count, other < diff.lines.count else { return [] }
        let isOld = diff.lines[line].kind == .removed
        let oldLine = isOld ? line : other
        let newLine = isOld ? other : line
        let ranges = WordDiff.ranges(old: diff.lines[oldLine].text, new: diff.lines[newLine].text)
        wordRanges[oldLine] = ranges.old
        wordRanges[newLine] = ranges.new
        return isOld ? ranges.old : ranges.new
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        if let pane = panes.first(where: { $0.textView === view }) { activePane = pane }
        var index = 0
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        if view.selectedRange().length > 0 { add(String(localized: "Quote in Agent"), #selector(quoteSelection)) }
        add(String(localized: "Add Comment"), #selector(addComment))
        let clicked = (activePane.rows.indices.contains(activePane.row(atCharacter: charIndex)) ? activePane.rows[activePane.row(atCharacter: charIndex)] : nil)
        let chosen = selectedRows.filter { $0.kind != .hunk }
        menuChange = !chosen.isEmpty ? chosen : clicked.flatMap { DiffHunks.change(around: $0, in: diff.lines) }.map { Array(diff.lines[$0]) }
        if menuChange != nil {
            add(String(localized: "Undo This Change"), #selector(undoFromMenu))
            add(String(localized: "Ask About This Change"), #selector(askFromMenu))
        }
        add(String(localized: "Undo All Changes in This File"), #selector(undoFileFromMenu))
        if SymbolText.word(in: view.string as NSString, at: charIndex) != nil {
            // A right-click doesn't move the cursor, and it's what was clicked that's being asked about.
            view.setSelectedRange(NSRange(location: charIndex, length: 0))
            add(String(localized: "Go to Definition"), #selector(goToDefinitionFromMenu))
            add(String(localized: "Find References"), #selector(findReferencesFromMenu))
        }
        if let line = fileLocation(ofCharacter: charIndex)?.line {
            let problems = model.languageServers.knownDiagnostics(for: path).filter { $0.line <= line && line <= $0.endLine }
            if !problems.isEmpty {
                menuProblems = problems
                add(String(localized: "Quote Problem in Agent"), #selector(quoteProblems))
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
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        // From the selection to the end of this column, then round through the other one.
        let order = [activePane] + panes.filter { $0 !== activePane }
        for (index, pane) in order.enumerated() {
            let textView = pane.textView
            let string = textView.string as NSString
            let current = textView.selectedRange()
            let start = backwards ? current.location : NSMaxRange(current)
            let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: string.length - start)
            var found = string.range(of: query, options: options, range: range)
            if found.location == NSNotFound, index == order.count - 1 { found = string.range(of: query, options: options) }
            guard found.location != NSNotFound else { continue }
            activePane = pane
            textView.setSelectedRange(found)
            textView.scrollRangeToVisible(found)
            textView.showFindIndicator(for: found)
            return true
        }
        return false
    }
}

/// One column of a diff, and which of the diff's lines each of its rows shows. Every row is
/// exactly one line high, so the two columns stay level and finding what's on screen takes no
/// work, however long the diff is.
final class DiffPane {
    enum Side { case inline, old, new }
    /// A row longer than this is cut, because laying out a very long line takes seconds.
    static let longestRow = 4_000

    private(set) var side: Side
    let scrollView = NSTextView.scrollableTextView()
    let textView: DiffTextView
    let gutter = DiffGutter()
    /// For each row, its index in the diff's lines. Nil is a blank row opposite a change.
    private(set) var rows: [Int?] = []
    /// For each row, what's opposite it in the other column.
    private(set) var counterpart: [Int?] = []
    private(set) var lines: [DiffLine] = []
    private var rowOfLine: [Int: Int] = [:]
    private var rowStarts: [Int] = [0]
    private(set) var length = 0
    private(set) var lineHeight: CGFloat = 16
    var wordRanges: ((Int) -> [NSRange])?
    private(set) lazy var highlighter = LineHighlighter(textView: textView)

    init(side: Side) {
        self.side = side
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView = DiffTextView(frame: frame)
        textView.pane = self
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
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        // Laid out from the top, in the background, so a row is where its number says it is.
        textView.layoutManager?.allowsNonContiguousLayout = false
        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        gutter.clipsToBounds = true
        gutter.attach(to: scrollView, pane: self)
    }

    func apply(font: NSFont, gutterFont: NSFont) {
        textView.font = font
        gutter.font = gutterFont
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        applyLineHeight()
        redraw()
    }

    /// Only what's on screen: asking a long diff's whole text view to redraw lays out all of it first.
    func redraw() {
        textView.setNeedsDisplay(textView.visibleRect, avoidAdditionalLayout: true)
        gutter.needsDisplay = true
    }

    private func applyLineHeight() {
        defer { textView.setFrameSize(textView.frame.size) }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        textView.defaultParagraphStyle = style
        textView.textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: length))
    }

    func set(rows: [Int?], lines: [DiffLine], side: Side, counterpart: [Int?]) {
        self.side = side
        self.rows = rows
        self.lines = lines
        self.counterpart = counterpart
        rowOfLine.removeAll(keepingCapacity: true)
        rowStarts = [0]
        rowStarts.reserveCapacity(rows.count + 1)
        var text = ""
        var offset = 0
        for (row, line) in rows.enumerated() {
            if let line {
                rowOfLine[line] = row
                let shown = Self.displayText(lines[line].text)
                text += shown
                offset += shown.utf16.count
            }
            if row < rows.count - 1 {
                text += "\n"
                offset += 1
                rowStarts.append(offset)
            }
        }
        length = offset
        if text != textView.string || textView.textStorage?.length == 0 { textView.string = text }
        applyLineHeight()
        // Wide enough for the biggest number, once there are six digits.
        let biggest = lines.last { $0.newLine != nil || $0.oldLine != nil }.map { max($0.newLine ?? 0, $0.oldLine ?? 0) } ?? 0
        gutter.columnWidth = max(40, CGFloat(String(biggest).count) * 7 + 6)
        gutter.thickness = side == .inline ? gutter.columnWidth * 2 + 8 : gutter.columnWidth + 12
        redraw()
    }

    /// One row of text, however it was written: anything that would start a new line of text
    /// becomes a space, and a very long line is cut. A carriage return at the end just goes.
    private static func displayText(_ text: String) -> String {
        var text = text
        if text.utf8.last == 13 { text.removeLast(text.hasSuffix("\r\n") ? 2 : 1) }
        if text.utf16.count > longestRow { text = String(decoding: Array(text.utf16.prefix(longestRow)), as: UTF16.self) + " …" }
        guard text.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 11 || $0.value == 12 || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            [13, 11, 12, 0x85, 0x2028, 0x2029].contains(scalar.value) ? " " : scalar
        }))
    }

    func row(ofLine line: Int) -> Int? { rowOfLine[line] }

    /// A line that's only on the other side: the row nearest to it on this one.
    func nearestRow(toLine line: Int) -> Int? {
        for distance in 1..<max(lines.count, 2) {
            if let row = rowOfLine[line + distance] ?? rowOfLine[line - distance] { return row }
        }
        return nil
    }

    func row(atCharacter index: Int) -> Int {
        var low = 0
        var high = rowStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if rowStarts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func range(ofRow row: Int) -> NSRange {
        guard row < rowStarts.count else { return NSRange(location: length, length: 0) }
        let start = rowStarts[row]
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] - 1 : length
        return NSRange(location: start, length: max(end - start, 0))
    }

    func y(ofRow row: Int) -> CGFloat { textView.textContainerInset.height + CGFloat(row) * lineHeight }

    var contentHeight: CGFloat { textView.textContainerInset.height * 2 + CGFloat(rows.count) * lineHeight }

    func visibleRows(in rect: NSRect) -> Range<Int> {
        let inset = textView.textContainerInset.height
        let first = min(max(Int((rect.minY - inset) / lineHeight), 0), rows.count)
        let last = min(max(Int((rect.maxY - inset) / lineHeight) + 1, 0), rows.count)
        return first..<max(first, last)
    }

    /// The first of the diff's lines at the top of the view, for keeping a place.
    var topLine: Int? {
        for row in visibleRows(in: textView.visibleRect) {
            if let line = rows[row] { return line }
        }
        return nil
    }
}

/// A row's color runs the full width of the pane, past the end of the text.
/// A word to the agent about the change under the mouse.
final class ChangeActionsView: NSView {
    var onUndo: (() -> Void)?
    var onAsk: (() -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (title, action, help) in [(String(localized: "Undo"), #selector(undo), String(localized: "Ask the agent that made this change to undo it")),
                                      (String(localized: "Ask"), #selector(ask), String(localized: "Ask the agent that made this change about it"))] {
            let button = NSButton(title: title, target: self, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = help
            stack.addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func undo() { onUndo?() }
    @objc private func ask() { onAsk?() }
}

extension NSEvent {
    /// Where the mouse is, in a window's coordinates, without an event to read it from.
    static func mouseLocationInWindow(of view: NSView) -> NSPoint {
        view.window?.mouseLocationOutsideOfEventStream ?? .zero
    }
}

final class DiffTextView: NSTextView {
    weak var pane: DiffPane?
    var onFocus: (() -> Void)?
    var onHoverRow: ((Int?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let pane else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - textContainerInset.height) / pane.lineHeight)
        onHoverRow?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverRow?(nil)
    }

    /// Always in the same place. Working it out asks how much text has been laid out, each
    /// time some more is, which takes minutes on a long diff.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }

    /// As tall as the rows will need, however few have been laid out so far.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let pane { size.height = max(pane.contentHeight, enclosingScrollView?.contentView.bounds.height ?? 0) }
        super.setFrameSize(size)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    static func color(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.16)
        case .removed: NSColor.systemRed.withAlphaComponent(0.16)
        case .hunk: NSColor.secondaryLabelColor.withAlphaComponent(0.1)
        case .context: nil
        }
    }

    static var blankRowColor: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.06) }

    private static func wordColor(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.36)
        case .removed: NSColor.systemRed.withAlphaComponent(0.36)
        case .hunk, .context: nil
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let pane else { return }
        let width = max(bounds.width, rect.maxX)
        for row in pane.visibleRows(in: rect) {
            let y = pane.y(ofRow: row)
            let full = NSRect(x: 0, y: y, width: width, height: pane.lineHeight)
            guard let index = pane.rows[row] else {
                Self.blankRowColor.setFill()
                full.fill(using: .sourceOver)
                continue
            }
            let line = pane.lines[index]
            guard let color = Self.color(for: line.kind) else { continue }
            color.setFill()
            full.fill(using: .sourceOver)
            guard let wordColor = Self.wordColor(for: line.kind), let changed = pane.wordRanges?(index), !changed.isEmpty else { continue }
            drawWords(changed, row: row, y: y, color: wordColor)
        }
    }

    private func drawWords(_ ranges: [NSRange], row: Int, y: CGFloat, color: NSColor) {
        guard let pane, let layout = layoutManager, let container = textContainer else { return }
        let rowRange = pane.range(ofRow: row)
        color.setFill()
        for range in ranges {
            let location = rowRange.location + range.location
            guard location + range.length <= NSMaxRange(rowRange), range.length > 0 else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: range.length), actualCharacterRange: nil)
            var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += textContainerInset.width
            box.origin.y = y
            box.size.height = pane.lineHeight
            NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

/// Old and new line numbers: side by side in one column, or whichever each of two columns shows.
final class DiffGutter: NSView {
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    /// Row, counting from 0, to the comments on it.
    var commentMarkers: [Int: [ReviewComment]] = [:] { didSet { needsDisplay = true } }
    private var markerHits: [(rect: NSRect, comments: [ReviewComment])] = []
    /// Row, counting from 0, to the worst thing wrong with it.
    var problemRows: [Int: LSPDiagnostic.Severity] = [:] { didSet { needsDisplay = true } }
    /// The diff's lines that F7 is on.
    var currentLines: Range<Int>? { didSet { needsDisplay = true } }
    private weak var pane: DiffPane?
    private var observers: [NSObjectProtocol] = []
    var columnWidth: CGFloat = 40
    var thickness: CGFloat = 88 { didSet { if thickness != oldValue { superview?.needsLayout = true } } }

    override var isFlipped: Bool { true }

    func attach(to scrollView: NSScrollView, pane: DiffPane) {
        self.pane = pane
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
        // What's asked for can reach outside this view, over its neighbor.
        dirtyRect.intersection(bounds).fill()
        guard let pane else { return }
        let text = pane.textView
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.faintLabel]
        markerHits = []
        for row in pane.visibleRows(in: text.visibleRect) {
            let y = text.convert(NSPoint(x: 0, y: pane.y(ofRow: row)), to: self).y
            let height = pane.lineHeight
            guard let index = pane.rows[row] else {
                DiffTextView.blankRowColor.setFill()
                NSRect(x: 0, y: y, width: thickness, height: height).fill(using: .sourceOver)
                continue
            }
            let line = pane.lines[index]
            if let color = DiffTextView.color(for: line.kind) {
                color.setFill()
                NSRect(x: 0, y: y, width: thickness, height: height).fill(using: .sourceOver)
            }
            if currentLines?.contains(index) == true {
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: y, width: 2, height: height).fill()
            }
            for (number, right) in columns(for: line) {
                guard let number else { continue }
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: right - size.width, y: y + (height - size.height) / 2), withAttributes: attributes)
            }
            if let comments = commentMarkers[row] {
                markerHits.append((ReviewMarker.draw(atY: y, lineHeight: height), comments))
            }
            if let severity = problemRows[row] {
                ProblemMarks.drawDot(severity: severity, x: thickness - 6, y: y, lineHeight: height)
            }
        }
    }

    /// Each number to draw, and where its right edge goes.
    private func columns(for line: DiffLine) -> [(number: Int?, right: CGFloat)] {
        switch pane?.side {
        case .old: [(line.oldLine, thickness - 8)]
        case .new: [(line.newLine, thickness - 8)]
        default: [(line.oldLine, columnWidth - 2), (line.newLine, columnWidth * 2 - 2)]
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

/// An image before and after, since git can't say what changed in one.
final class ImageDiffView: NSView {
    nonisolated struct Side: @unchecked Sendable {
        var title: String
        var detail: String
        var image: ImageDecoding.Decoded?
    }

    nonisolated struct Content: @unchecked Sendable {
        var sides: [Side]
        /// Whether two looks found the same images.
        var fingerprint: Data

        init(versions: FileVersions, scale: CGFloat) {
            var hash = SHA256()
            for data in [versions.old, versions.new] {
                hash.update(data: data ?? Data())
                hash.update(data: Data([data == nil ? 0 : 1]))
            }
            fingerprint = Data(hash.finalize())
            func side(_ title: String, _ data: Data) -> Side {
                let decoded = ImageDecoding.decode(data: data, scale: scale)
                var detail = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                if let size = decoded?.size {
                    detail = "\(Int(size.width * scale)) × \(Int(size.height * scale)), " + detail
                }
                return Side(title: title, detail: detail, image: decoded)
            }
            switch (versions.old, versions.new) {
            case (let old?, let new?): sides = [side(String(localized: "Before"), old), side(String(localized: "After"), new)]
            case (let old?, nil): sides = [side(String(localized: "Deleted"), old)]
            case (nil, let new?): sides = [side(String(localized: "Added"), new)]
            case (nil, nil): sides = []
            }
        }
    }

    private var columns: [(label: NSTextField, image: NSImageView)] = []

    override var isFlipped: Bool { true }

    func show(_ content: Content, plateIfDarkOnClear dark: Bool) {
        for column in columns {
            column.label.removeFromSuperview()
            column.image.removeFromSuperview()
        }
        columns = content.sides.map { side in
            let label = NSTextField(labelWithString: "\(side.title)  \(side.detail)")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignTop
            view.animates = true
            if let decoded = side.image {
                let image: NSImage?
                if let data = decoded.animatedData {
                    image = NSImage(data: data)
                } else {
                    image = decoded.cgImage.map { NSImage(cgImage: $0, size: decoded.size) }
                }
                image?.size = decoded.size
                view.image = image
                view.wantsLayer = true
                view.layer?.backgroundColor = decoded.darkOnClear && dark ? ClearArt.plate.cgColor : nil
            } else {
                label.stringValue = side.title + "  " + String(localized: "Tiri can't read this image")
            }
            addSubview(view)
            addSubview(label)
            return (label, view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !columns.isEmpty else { return }
        let width = bounds.width / CGFloat(columns.count)
        for (index, column) in columns.enumerated() {
            let x = CGFloat(index) * width
            column.label.frame = CGRect(x: x + 8, y: 8, width: max(width - 16, 0), height: 18)
            column.image.frame = CGRect(x: x + 12, y: 32, width: max(width - 24, 0), height: max(bounds.height - 44, 0))
        }
    }
}

final class DiffContainer: NSView {
    /// Below this, two columns of code aren't readable.
    static let narrowestTwoColumns: CGFloat = 640
    private var main: DiffPane?
    private var old: DiffPane?
    private var message: NSTextField?
    private let divider = NSBox()
    private let images = ImageDiffView()
    private let noteBar = NSView()
    private let noteLabel = NSTextField(labelWithString: "")
    private let problemsBar = NSView()
    private let problemsLabel = NSTextField(labelWithString: "")
    private let problemsIcon = NSImageView()
    private let problemsButton = NSButton(title: String(localized: "Quote in Agent"), target: nil, action: nil)
    private var onQuoteProblems: (() -> Void)?
    private static let barHeight: CGFloat = 26
    private var lastWidth: CGFloat = 0
    private var contentHidden = false
    var onWidthChange: (() -> Void)?
    var showsOld = false {
        didSet {
            needsLayout = true
            updateVisibility()
        }
    }

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

    /// What's being compared, when it isn't simply the last commit.
    func showNote(_ text: String?) {
        noteBar.isHidden = text == nil
        noteLabel.stringValue = text ?? ""
        noteLabel.toolTip = text
        needsLayout = true
    }

    func showImages(_ content: ImageDiffView.Content?) {
        images.isHidden = content == nil
        if let content { images.show(content, plateIfDarkOnClear: AppModel.shared.effectiveDark) }
        contentHidden = content != nil
        updateVisibility()
    }

    @objc private func quoteProblems() { onQuoteProblems?() }

    func install(main: DiffPane, message: NSTextField) {
        self.main = main
        self.message = message
        addSubview(main.gutter)
        addSubview(main.scrollView)
        addSubview(images)
        addSubview(message)
        message.isHidden = true
        images.isHidden = true
        divider.boxType = .separator
        divider.isHidden = true
        addSubview(divider)
        noteBar.isHidden = true
        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteBar.addSubview(noteLabel)
        addSubview(noteBar)
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

    func install(old: DiffPane) {
        self.old = old
        addSubview(old.gutter, positioned: .below, relativeTo: images)
        addSubview(old.scrollView, positioned: .below, relativeTo: images)
        needsLayout = true
    }

    func showMessage(_ text: String?) {
        message?.stringValue = text ?? ""
        message?.isHidden = text == nil
        contentHidden = text != nil || !images.isHidden
        updateVisibility()
    }

    private func updateVisibility() {
        main?.gutter.isHidden = contentHidden
        main?.scrollView.isHidden = contentHidden
        old?.gutter.isHidden = contentHidden || !showsOld
        old?.scrollView.isHidden = contentHidden || !showsOld
        divider.isHidden = contentHidden || !showsOld
    }

    override func layout() {
        super.layout()
        let note = noteBar.isHidden ? 0 : Self.barHeight
        let problems = problemsBar.isHidden ? 0 : Self.barHeight
        let bars = note + problems
        // This view's origin is at its bottom, unless it's flipped, and the bars go on top either way.
        let contentY: CGFloat = isFlipped ? bars : 0
        let contentHeight = max(bounds.height - bars, 0)
        var x: CGFloat = 0
        let width = bounds.width
        if showsOld, let old, let main {
            let half = floor(width / 2)
            old.gutter.frame = CGRect(x: 0, y: contentY, width: old.gutter.thickness, height: contentHeight)
            old.scrollView.frame = CGRect(x: old.gutter.thickness, y: contentY, width: max(half - old.gutter.thickness, 0), height: contentHeight)
            divider.frame = CGRect(x: half, y: contentY, width: 1, height: contentHeight)
            x = half + 1
            main.gutter.frame = CGRect(x: x, y: contentY, width: main.gutter.thickness, height: contentHeight)
            main.scrollView.frame = CGRect(x: x + main.gutter.thickness, y: contentY, width: max(width - x - main.gutter.thickness, 0), height: contentHeight)
            old.gutter.needsDisplay = true
        } else if let main {
            main.gutter.frame = CGRect(x: 0, y: contentY, width: main.gutter.thickness, height: contentHeight)
            main.scrollView.frame = CGRect(x: main.gutter.thickness, y: contentY, width: max(width - main.gutter.thickness, 0), height: contentHeight)
        }
        images.frame = CGRect(x: 0, y: contentY, width: width, height: contentHeight)
        noteBar.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - note, width: width, height: note)
        noteLabel.frame = CGRect(x: 12, y: 5, width: max(width - 24, 0), height: 16)
        problemsBar.frame = CGRect(x: 0, y: isFlipped ? note : bounds.height - bars, width: width, height: problems)
        problemsIcon.frame = CGRect(x: 12, y: 6, width: 14, height: 14)
        let buttonWidth = problemsButton.frame.width
        problemsButton.frame = CGRect(x: width - buttonWidth - 12, y: 3, width: buttonWidth, height: 20)
        problemsLabel.frame = CGRect(x: 32, y: 5, width: max(width - buttonWidth - 56, 0), height: 16)
        message?.frame = CGRect(x: 20, y: bounds.midY - 12, width: max(width - 40, 0), height: 24)
        main?.gutter.needsDisplay = true
        if width != lastWidth {
            lastWidth = width
            // Rebuilding columns during layout would ask for layout again.
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }
    }
}

// MARK: - The sidebar section

struct ChangesList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.windowScope) private var scope
    /// The model as this window sees it, with its own workspace's changes.
    private var model: WindowModel { WindowModel(app: app, scope: scope) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if case .otherWork = model.changesScope {
                    ForEach(model.otherWork) { work in
                        WorkRow(work: work)
                    }
                    if model.otherWork.isEmpty {
                        EmptyChangesRow(text: model.emptyChangesText)
                    }
                } else if case .recentCommits = model.changesScope {
                    ForEach(model.recentCommits) { commit in
                        CommitRow(commit: commit)
                    }
                    if model.recentCommits.isEmpty, !model.scopeIsLoading {
                        EmptyChangesRow(text: String(localized: "No commits yet."))
                    }
                } else {
                    ForEach(model.visibleChanges) { change in
                        ChangeRow(change: change)
                    }
                    if model.visibleChanges.isEmpty, !model.scopeIsLoading {
                        EmptyChangesRow(text: model.emptyChangesText)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

/// What the list would hold, in words, when it holds nothing.
struct EmptyChangesRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
    }
}

/// A commit in the list. Choosing it shows its files.
struct CommitRow: View {
    let commit: CommitSummary
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }
    @State private var hovering = false

    private var detail: String {
        var parts = [commit.shortOID, RelativeTime.display(commit.date)]
        if here.repositories.count > 1 { parts.insert((commit.root as NSString).lastPathComponent, at: 0) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(commit.subject)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.setChangesScope(.commit(commit)) }
        .accessibleRow(commit.subject, value: detail) { model.setChangesScope(.commit(commit)) }
        .help(commit.subject + "\n" + commit.author)
        .contextMenu {
            Button("Copy Hash") { Clipboard.copy(commit.oid) }
        }
    }
}

struct ChangeRow: View {
    let change: ChangedFile
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }
    @State private var hovering = false

    private var spec: DiffSpec { model.diffSpecForScope(path: change.path) }

    private var isActive: Bool {
        guard case .diff(let front)? = here.active.activeItem?.content else { return false }
        return front == spec
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
        let folder = here.active.folder(containing: change.path)
        let relative = folder != nil ? here.active.relativePath(change.path) : change.relative
        let directory = (relative as NSString).deletingLastPathComponent
        guard here.active.folders.count > 1, let folder else { return directory }
        let folderName = (folder as NSString).lastPathComponent
        return directory.isEmpty ? folderName : folderName + " • " + directory
    }

    private var statusHelp: String {
        if let old = change.oldRelative { return String(localized: "Renamed from \(old)") }
        return change.status.title
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
                .help(statusHelp)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .currentMark(isActive, hovering: hovering, cornerRadius: 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click previews, like the explorer. A second keeps it.
        .onTapGesture { model.openDiff(spec, preview: true) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openDiff(spec, preview: false) })
        // The letter's color is the only sign of what happened to it, so it's said in words.
        .accessibleRow(name, value: [statusHelp, detail].filter { !$0.isEmpty }.joined(separator: ", "), selected: isActive) {
            model.openDiff(spec, preview: false)
        }
        .contextMenu {
            Button("Open Changes") { model.openDiff(spec, preview: false) }
            if change.status != .deleted {
                Button("Open File") { model.open(path: change.path, intent: .pinned); model.requestFocus() }
            }
            Button("Add to Agent") { model.addFilesToAgent([change.path]) }
            Button("Ask Agent to Undo") { model.tellAgentAboutChange(path: change.path, prompt: ChangeRequest.prompt(.undo, path: change.path, lines: nil)) }
            Divider()
            Button("Copy Path") { Clipboard.copy(change.path) }
        }
    }
}
