import AppKit
import AVKit
import PDFKit
import QuickLookUI
import JavaScriptCore
import TiriCore
import WebKit

/// A plain container so a viewer can swap what it shows while keeping one view in the tab.
final class HostContainer: NSView {
    private var hosted: NSView?

    func show(_ view: NSView) {
        guard hosted !== view else { return }
        hosted?.removeFromSuperview()
        hosted = view
        view.frame = bounds
        // Underneath anything floating over it.
        addSubview(view, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}

/// Serves local files to web views, so markdown's relative images work and pages
/// can't reach anything except by this route.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tiri-file"

    static func baseURL(forDirectory directory: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = directory.hasSuffix("/") ? directory : directory + "/"
        return components.url!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

// MARK: - Factory

enum ViewerFactory {
    static func make(itemID: ItemID, spec: FileSpec, model: AppModel) -> ItemController {
        let kind = FileClassifier.classify(path: spec.path) {
            guard let handle = FileHandle(forReadingAtPath: spec.path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
        switch kind {
        case .markdown:
            return MarkdownController(itemID: itemID, spec: spec, model: model)
        case .text:
            return TextController(itemID: itemID, spec: spec, model: model)
        case .image:
            return ImageController(itemID: itemID, path: spec.path, model: model)
        case .svg:
            return SVGController(itemID: itemID, path: spec.path, model: model)
        case .pdf:
            return PDFController(itemID: itemID, spec: spec, model: model)
        case .media:
            return MediaController(itemID: itemID, path: spec.path)
        case .html:
            return WebController(itemID: itemID, url: URL(fileURLWithPath: spec.path), forceDark: spec.forceDark, isFile: true, model: model)
        case .csv:
            return CSVController(itemID: itemID, path: spec.path)
        case .office:
            return QuickLookController(itemID: itemID, spec: spec, isPaper: true, model: model)
        case .quickLook:
            return QuickLookController(itemID: itemID, spec: spec, isPaper: false, model: model)
        }
    }
}

// MARK: - Markdown: rendered by default, source on request

/// Creating a WKWebView (and its web process) is most of the cost of opening a markdown file.
/// One is kept warm, so the next open only has to render.
enum MarkdownWebViews {
    private static var spare: TiriWebView?

    private static func make() -> TiriWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        let view = TiriWebView.makeConfigured(configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    static func warmUp() {
        guard spare == nil else { return }
        let view = make()
        view.loadHTMLString("<!DOCTYPE html><title></title>", baseURL: nil)
        spare = view
    }

    static func take() -> TiriWebView {
        let view = spare ?? make()
        spare = nil
        // Replace it once things are quiet, not during the open it's serving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { warmUp() }
        return view
    }
}

final class MarkdownController: NSObject, ItemController, WKNavigationDelegate {
    let itemID: ItemID
    let path: String
    unowned let model: AppModel
    private let container = HostContainer()
    private lazy var webView: TiriWebView = makeWebView()
    private lazy var quoteButton: QuoteButton = {
        let button = QuoteButton(host: container)
        button.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        return button
    }()
    private var source: TextController?
    private(set) var showingSource: Bool
    private var token: FileWatchHub.Token?
    private var pendingScrollY: Double?
    private var pendingAnchor: String?
    private var pendingLine: (Int?, Int?)

    var view: NSView { container }

    init(itemID: ItemID, spec: FileSpec, model: AppModel) {
        self.itemID = itemID
        self.path = spec.path
        self.model = model
        self.showingSource = spec.showSource ?? false
        self.pendingLine = (spec.line, spec.col)
        super.init()
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.fileChanged() }
        render(keepScroll: false)
    }

    private func makeWebView() -> TiriWebView {
        let view = MarkdownWebViews.take()
        view.pageZoom = model.webZoom
        view.navigationDelegate = self
        view.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        view.onSelectionChange = { [weak self] selection, top in self?.renderedSelectionChanged(selection, top: top) }
        return view
    }

    /// Selecting in the rendered page is selecting those lines of the file.
    private func renderedSelectionChanged(_ selection: WebSelection?, top: CGFloat?) {
        guard let selection, let top else {
            quoteButton.isHidden = true
            return
        }
        quoteButton.show(fromTop: top)
        if let lines = renderedLines(selection) {
            model.editorBridge.selectionChanged(EditorSelection(path: path, text: selection.text, startLine: lines.first, startCharacter: 0,
                                                                endLine: lines.last, endCharacter: 1))
        }
    }

    private func renderedLines(_ selection: WebSelection) -> (first: Int, last: Int)? {
        guard selection.line >= 0, selection.lineEnd >= selection.line else { return nil }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return MarkdownRenderer.sourceLines(blockStart: selection.line, blockEnd: selection.lineEnd, selected: selection.text, source: text)
    }

    func select(text: String, to end: String?) -> Bool {
        if showingSource { return source?.select(text: text, to: end) ?? false }
        webView.evaluateJavaScript(WebSelectionScript.selecting(text, to: end), in: nil, in: .defaultClient) { _ in }
        return true
    }

    private func sourceController() -> TextController {
        if let source { return source }
        let controller = TextController(itemID: itemID, spec: FileSpec(path: path), model: model, watches: false)
        source = controller
        return controller
    }

    private func render(keepScroll: Bool) {
        if showingSource {
            let text = sourceController()
            container.show(text.view)
            if let line = pendingLine.0 {
                text.goTo(line: line, col: pendingLine.1)
                pendingLine = (nil, nil)
            }
            return
        }
        container.show(webView)
        let source = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? String(data: FileManager.default.contents(atPath: path) ?? Data(), encoding: .isoLatin1)
            ?? ""
        let directory = (path as NSString).deletingLastPathComponent
        let base = LocalFileSchemeHandler.baseURL(forDirectory: directory)
        let page = MarkdownRenderer.page(markdown: source, baseHref: base.absoluteString, title: (path as NSString).lastPathComponent)
        if let line = pendingLine.0 {
            // Rendered stays rendered: `report.md:40` lands on the section holding line 40.
            pendingAnchor = MarkdownRenderer.anchor(forLine: line, in: source)
            pendingLine = (nil, nil)
        }
        if keepScroll {
            // Agents rewrite files as they work. A reload shouldn't lose your place.
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingScrollY = value as? Double
                    self.webView.loadHTMLString(page, baseURL: base)
                }
            }
        } else {
            webView.loadHTMLString(page, baseURL: base)
        }
    }

    private func fileChanged() {
        if !FileManager.default.fileExists(atPath: path) { return }
        if showingSource {
            source?.reload()
        } else {
            render(keepScroll: true)
        }
    }

    func toggleSource() {
        showingSource.toggle()
        // The rendered page's selection isn't what's showing any more.
        quoteButton.isHidden = true
        if showingSource {
            sourceController().reload()
        }
        render(keepScroll: false)
        focus()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model.viewerReady(itemID)
        if let y = pendingScrollY {
            pendingScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
        }
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            scrollTo(anchor: anchor)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.navigationType == .linkActivated else {
            // Tiri's own load only. Raw HTML in a document (a meta refresh) can't navigate away.
            let isOwnLoad = url.scheme == LocalFileSchemeHandler.scheme || url.scheme == "about"
            decisionHandler(isOwnLoad ? .allow : .cancel)
            return
        }
        // Links inside the same document scroll; everything else opens as a peer item.
        if url.fragment != nil, url.path(percentEncoded: false) == webView.url?.path(percentEncoded: false) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        switch url.scheme {
        case LocalFileSchemeHandler.scheme, "file":
            model.open(path: url.path(percentEncoded: false), intent: .pinned)
            model.requestFocus()
        case "http", "https":
            model.openWeb(url: url.absoluteString, split: nil)
        case "mailto":
            NSWorkspace.shared.open(url)
        default:
            // A document shouldn't be able to launch an arbitrary URL scheme handler.
            break
        }
    }

    func focus() {
        if showingSource { source?.focus() } else { webView.window?.makeFirstResponder(webView) }
    }

    func applySettings() {
        source?.applySettings()
        webView.pageZoom = model.webZoom
    }

    /// The source, when that's what's showing.
    var sourceIfShowing: TextController? { showingSource ? source : nil }

    /// The rendered page's scroll, for coming back to it. It can only be asked for and answered later.
    func renderedScrollRestorer() -> (() -> Void)? {
        var position: Double?
        webView.evaluateJavaScript("window.scrollY") { value, _ in
            MainActor.assumeIsolated { position = value as? Double }
        }
        return { [weak self] in
            guard let position else { return }
            self?.webView.evaluateJavaScript("window.scrollTo(0, \(position))", completionHandler: nil)
        }
    }

    private func scrollTo(anchor: String) {
        let escaped = anchor.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("document.getElementById('\(escaped)')?.scrollIntoView()", completionHandler: nil)
    }

    func goTo(line: Int?, col: Int?) {
        guard let line else { return }
        if showingSource {
            source?.goTo(line: line, col: col)
            return
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if let anchor = MarkdownRenderer.anchor(forLine: line, in: text) { scrollTo(anchor: anchor) }
    }

    func teardown() {
        token = nil
        if showingSource == false { webView.stopLoading() }
    }

    var supportsFind: Bool { true }

    var selectedTextForFind: String? { showingSource ? source?.selectedTextForFind : nil }
    var agentReference: AgentSelection? {
        if showingSource { return source?.agentReference }
        guard let selection = webView.selection else { return nil }
        if let lines = renderedLines(selection) {
            return AgentSelection(path: path, firstLine: lines.first, lastLine: lines.last)
        }
        return AgentSelection(path: path, quote: AgentReference.quotation(from: (path as NSString).lastPathComponent, text: selection.text))
    }
    var isDirty: Bool { source?.isDirty ?? false }
    func save(overwriting: Bool) -> SaveResult { source?.save(overwriting: overwriting) ?? .saved }

    func find(_ query: String, backwards: Bool) -> Bool {
        if showingSource { return source?.find(query, backwards: backwards) ?? false }
        return WebFind.run(webView, query: query, backwards: backwards)
    }

    func findIncrementally(_ query: String, caseSensitive: Bool) -> Bool {
        if showingSource { return source?.findIncrementally(query, caseSensitive: caseSensitive) ?? false }
        return WebFind.run(webView, query: query, backwards: false)
    }

    var findCount: (current: Int, total: Int)? { showingSource ? source?.findCount : nil }
    var supportsReplace: Bool { showingSource ? (source?.supportsReplace ?? false) : false }

    func replaceCurrent(query: String, with replacement: String, caseSensitive: Bool) -> Bool {
        source?.replaceCurrent(query: query, with: replacement, caseSensitive: caseSensitive) ?? false
    }

    func replaceAll(query: String, with replacement: String, caseSensitive: Bool) -> Int {
        source?.replaceAll(query: query, with: replacement, caseSensitive: caseSensitive) ?? 0
    }

    func clearFind() {
        if showingSource { source?.clearFind() } else { WebFind.clear(webView) }
    }
}

/// `WKWebView.find` is async and our protocol isn't. The bar's "not found" state updates when
/// the answer arrives; the immediate return only says the query was accepted.
enum WebFind {
    static func run(_ webView: WKWebView, query: String, backwards: Bool) -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            MainActor.assumeIsolated {
                AppModel.shared.find?.notFound = !result.matchFound
            }
        }
        return true
    }

    static func clear(_ webView: WKWebView) {
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
    }
}

// MARK: - Plain text and code: read-only, monospaced

final class TextController: NSObject, ItemController, SymbolViewing, NSTextViewDelegate, NSTextStorageDelegate {
    let itemID: ItemID
    let path: String
    unowned let model: AppModel
    private let scrollView = CodeTextView.makeScrollable()
    private var textView: CodeTextView { scrollView.documentView as! CodeTextView }
    var codeView: CodeTextView { textView }
    /// Its own, so ⌘Z in one file can't undo something in another that isn't even showing.
    private let undo = UndoManager()
    /// ⌥Z, for this file while it's open. Settings say what happens otherwise.
    private var wrapOverride: WordWrap?
    private var bracketMarks: [NSRange] = []
    private let container: CodeContainer
    private var ruler: LineGutter { container.gutter }
    private var token: FileWatchHub.Token?
    private var pendingLocation: (Int?, Int?)
    private var loadedOnce = false
    private var highlightWork: DispatchWorkItem?
    private var quoteButton: QuoteButton?
    private var highlightGeneration = 0
    /// Strings and comments, in order, as of the colors with this generation.
    private var ignorableSpans: [NSRange] = []
    private var spansGeneration = -1
    private var scrollObservation: NSObjectProtocol?
    /// What's on disk, as far as this viewer knows.
    private var savedText = ""
    private var findQuery = ""
    private var findCaseSensitive = false
    private var findMatches: [NSRange] = []
    private var findIsStale = false
    private var currentMatch: Int?
    /// Where the cursor was when typing in the find box began.
    private var findAnchor: Int?
    private var markedMatches: [NSRange] = []
    private var diskChangedUnderEdits = false
    private var menuProblems: [LSPDiagnostic] = []
    private(set) var isDirty = false {
        didSet { if isDirty != oldValue { model.controllerRevision += 1 } }
    }
    nonisolated static let maximumBytes = 32 * 1024 * 1024

    var view: NSView { container }

    init(itemID: ItemID, spec: FileSpec, model: AppModel, watches: Bool = true) {
        self.itemID = itemID
        self.path = spec.path
        self.model = model
        self.pendingLocation = (spec.line, spec.col)
        self.container = CodeContainer(scrollView: scrollView)
        super.init()
        configure()
        if watches {
            token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.reload() }
        }
        reload()
        model.languageServers.viewerOpened(path)
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        if textView.isSteering { return }
        reportSelection()
    }

    /// Tell Claude what's selected, as an editor would.
    private func reportSelection() {
        markBrackets()
        guard textView.window != nil, loadedOnce else { return }
        model.editorBridge.selectionChanged(editorSelection)
    }

    private var editorSelection: EditorSelection {
        let string = textView.nsText
        let range = textView.selectedRange()
        func position(_ location: Int) -> (Int, Int) {
            let table = ruler.lines
            let line = table.line(containing: location)
            return (line, location - table.starts[line])
        }
        let (startLine, startCharacter) = position(range.location)
        let (endLine, endCharacter) = position(NSMaxRange(range))
        return EditorSelection(path: path, text: string.substring(with: range), startLine: startLine, startCharacter: startCharacter,
                               endLine: endLine, endCharacter: endCharacter)
    }

    var agentReference: AgentSelection? {
        let selection = editorSelection
        guard !selection.isEmpty else { return nil }
        return AgentSelection(path: path, firstLine: selection.startLine, lastLine: selection.lastLine)
    }

    var symbolTextView: NSTextView { textView }

    func fileLocation(ofCharacter index: Int) -> (line: Int, character: Int)? {
        guard index <= textView.nsText.length else { return nil }
        let line = ruler.lines.line(containing: index)
        return (line, index - ruler.lines.starts[line])
    }

    /// With nothing selected, a comment is on the line the cursor is in.
    var reviewAnchor: ReviewAnchor? {
        let selection = editorSelection
        let first = selection.startLine + 1
        let last = max(selection.lastLine + 1, first)
        let string = textView.nsText
        let lines = string.lineRange(for: textView.selectedRange())
        let excerpt = string.substring(with: lines)
        return ReviewAnchor(path: path, firstLine: first, lastLine: last, excerpt: excerpt)
    }

    var reviewPopoverPosition: (view: NSView, rect: NSRect)? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let range = textView.selectedRange()
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if rect.height < 1 { rect.size.height = 16 }
        // A long line's selection can start out of sight. The box stays with what's on screen.
        return rect.intersects(textView.visibleRect) ? (textView, rect) : nil
    }

    func reviewChanged() {
        ruler.commentMarkers = model.reviewMarkers(for: path, text: textView.string)
    }

    func select(text: String, to end: String?) -> Bool {
        let string = textView.nsText
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

    private func configure() {
        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: textView)
        quoteButton = QuoteButton(textView: textView, scrollView: scrollView, host: container)
        quoteButton?.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        let text = textView
        text.editor = self
        text.isEditable = true
        text.allowsUndo = true
        text.delegate = self
        text.textStorage?.delegate = self
        text.isSelectable = true
        text.isRichText = false
        // It's code. Quotes and dashes stay what was typed.
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.usesFindBar = false
        text.isAutomaticLinkDetectionEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        ruler.attach(to: scrollView, textView: text)
        container.onLayout = { [weak self] in self?.fitTextToWrapColumn() }
        scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markVisibleMatches() }
        }
        applySettings()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    /// Keeps the line table up to date, looking only at what changed.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        ruler.textEdited(range: editedRange, delta: delta, in: textStorage.string as NSString)
    }

    // MARK: Wrapping

    private var wrap: WordWrap { wrapOverride ?? model.settings.editorWordWrap }

    private func applyWrap() {
        let unlimited = NSSize(width: 10_000_000, height: 10_000_000)
        guard let container = textView.textContainer else { return }
        textView.minSize = .zero
        textView.maxSize = unlimited
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        switch wrap {
        case .off:
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = unlimited
            scrollView.hasHorizontalScroller = true
        case .on, .bounded:
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
            var frame = textView.frame
            frame.size.width = scrollView.contentSize.width
            textView.frame = frame
            container.widthTracksTextView = wrap == .on
            fitTextToWrapColumn()
        }
        textView.needsDisplay = true
        ruler.needsDisplay = true
        textView.updateCursors()
    }

    /// Bounded means the column, or the pane's edge if that comes first.
    private func fitTextToWrapColumn() {
        guard wrap == .bounded, let container = textView.textContainer, let font = textView.font else { return }
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        let column = CGFloat(model.settings.editorWordWrapColumn) * digit + container.lineFragmentPadding * 2
        let available = scrollView.contentSize.width - textView.textContainerInset.width * 2
        let width = max(min(column, available), 40)
        guard abs(container.containerSize.width - width) > 0.5 else { return }
        container.containerSize = NSSize(width: width, height: 10_000_000)
    }

    func toggleWordWrap() {
        // VS Code's: wrapped in any way goes off, and off goes to what settings say, or to the pane's edge.
        let setting = model.settings.editorWordWrap
        wrapOverride = wrap == .off ? (setting == .off ? .on : setting) : .off
        applyWrap()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Brackets

    private func markBrackets() {
        guard let layout = textView.layoutManager else { return }
        let string = textView.nsText
        for range in bracketMarks where NSMaxRange(range) <= string.length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketMarks = []
        restoreMatchMarks()
        let selection = textView.selectedRange()
        guard selection.length == 0, string.length > 0, string.length < 8_000_000 else { return }
        let spans = highlightGeneration == spansGeneration ? ignorableSpans : []
        let found = BracketMatcher.match(in: string, caret: selection.location) { offset in
            var low = 0
            var high = spans.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(spans[mid]) <= offset { low = mid + 1 } else { high = mid }
            }
            return low < spans.count && spans[low].location <= offset
        }
        guard let found else { return }
        let color = NSColor.labelColor.withAlphaComponent(0.16)
        for offset in [found.open, found.close] {
            let range = NSRange(location: offset, length: 1)
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            bracketMarks.append(range)
        }
    }

    func applySettings() {
        let settings = model.settings
        textView.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSizeZoomed))
        ruler.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSizeZoomed) - 1)
        applyWrap()
        ruler.needsDisplay = true
        scheduleHighlight()
    }

    func reload() {
        let path = path
        // Agents often write by replacing the file, so it can be briefly missing. A file that's
        // gone keeps showing what it last said rather than going blank.
        if loadedOnce, !FileManager.default.fileExists(atPath: path) { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        if size > 5 * 1024 * 1024 {
            // Big logs load off the main thread so opening one never stalls the app.
            Task.detached(priority: .userInitiated) { [weak self] in
                let (text, editable) = Self.read(path: path)
                await MainActor.run { self?.display(text, editable: editable) }
            }
        } else {
            let (text, editable) = Self.read(path: path)
            display(text, editable: editable)
        }
    }

    /// Saving what's shown has to give back exactly what's on disk, or it isn't editable: a file
    /// that was cut short or isn't valid UTF-8 would be damaged.
    nonisolated private static func read(path: String) -> (String, Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        let decoded = String(data: data, encoding: .utf8)
        var text = decoded ?? String(decoding: data, as: UTF8.self)
        if data.count == maximumBytes {
            text += "\n\n… truncated at \(maximumBytes / (1024 * 1024)) MB. Open it in an external editor to see the rest."
            return (text, false)
        }
        return (text, decoded != nil)
    }

    private func display(_ text: String, editable: Bool) {
        // Your edits come first. An agent writing the same file doesn't get to erase them.
        if isDirty {
            if text != savedText {
                diskChangedUnderEdits = true
                model.showToast(title: "\((path as NSString).lastPathComponent) changed on disk", detail: "You have unsaved changes here, so they're still showing.",
                                symbol: "exclamationmark.triangle", tint: .orange, actionTitle: "Use Disk Version") { [weak self] in
                    self?.discardEdits()
                }
            }
            return
        }
        savedText = text
        textView.isEditable = editable
        guard text != textView.string || !loadedOnce else {
            applyPendingLocation()
            return
        }
        let origin = scrollView.contentView.bounds.origin
        let selection = textView.selectedRange()
        textView.dropExtraCursors()
        textView.string = text
        // What undo remembers is about text that's gone.
        undo.removeAllActions()
        reviewChanged()
        if loadedOnce {
            // A reload shouldn't lose your place.
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            // A file opens at its top, with the cursor there.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        loadedOnce = true
        applyPendingLocation()
        scheduleHighlight()
        diagnosticsChanged()
        model.languageServers.fileMayHaveChanged(path)
    }

    // MARK: Editing

    /// Right-click on a selection offers the same thing as the button beside it.
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

    func textDidChange(_ notification: Notification) {
        // A different length says it without comparing every character of a large file.
        isDirty = textView.nsText.length != (savedText as NSString).length || textView.string != savedText
        if isDirty { model.fileWasEdited(itemID) }
        reviewChanged()
        ruler.needsDisplay = true
        findIsStale = true
        // Until the new colors arrive, what's known to be a string may have moved.
        spansGeneration = -1
        markBrackets()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduleHighlight()
            self.refreshFindAfterEdit()
            self.model.languageServers.unsavedText(self.isDirty ? self.textView.string : nil, for: self.path)
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func save(overwriting: Bool) -> SaveResult {
        guard isDirty else { return .saved }
        let onDisk = Self.read(path: path).0
        if !overwriting, onDisk != savedText, FileManager.default.fileExists(atPath: path) { return .changedOnDisk }
        do {
            try textView.string.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = textView.string
            diskChangedUnderEdits = false
            isDirty = false
            model.languageServers.unsavedText(nil, for: path)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func discardEdits() {
        isDirty = false
        diskChangedUnderEdits = false
        model.languageServers.unsavedText(nil, for: path)
        undo.removeAllActions()
        reload()
    }

    private func scheduleHighlight() {
        highlightGeneration += 1
        let generation = highlightGeneration
        let text = textView.string
        let language = FileClassifier.language(path: path)
        guard (text as NSString).length < 500_000 else { return }
        Task.detached(priority: .utility) { [weak self] in
            let spans = SyntaxHighlighter.spans(text: text, language: language)
            await MainActor.run {
                guard let self, self.highlightGeneration == generation else { return }
                self.apply(spans)
                self.ignorableSpans = spans.filter { $0.kind == .string || $0.kind == .comment }.map(\.range).sorted { $0.location < $1.location }
                self.spansGeneration = generation
                self.markBrackets()
            }
        }
    }

    private func apply(_ spans: [SyntaxHighlighter.Span]) {
        guard let layout = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: textView.nsText.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for span in spans where NSMaxRange(span.range) <= full.length {
            layout.addTemporaryAttribute(.foregroundColor, value: span.kind.color, forCharacterRange: span.range)
        }
    }

    private func applyPendingLocation() {
        guard let line = pendingLocation.0 else { return }
        let col = pendingLocation.1
        pendingLocation = (nil, nil)
        jump(line: line, col: col)
    }

    private func jump(line: Int, col: Int?) {
        let string = textView.nsText
        var location = 0
        var current = 1
        while current < line, location < string.length {
            let range = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        let lineRange = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        let cursor = min(location + max((col ?? 1) - 1, 0), NSMaxRange(lineRange))
        textView.setSelectedRange(col == nil ? lineRange : NSRange(location: cursor, length: 0))
        textView.scrollRangeToVisible(lineRange)
        // Long lines shouldn't drag the view sideways and hide their own beginning.
        if col == nil {
            var origin = scrollView.contentView.bounds.origin
            origin.x = 0
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        textView.showFindIndicator(for: lineRange)
        ruler.needsDisplay = true
    }

    func goTo(line: Int?, col: Int?) {
        guard let line else { return }
        jump(line: line, col: col)
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
        reportSelection()
        model.languageServers.viewerShown(path)
    }

    func didAttach() { model.languageServers.viewerShown(path) }

    func teardown() {
        token = nil
        model.languageServers.viewerClosed(path)
    }

    func diagnosticsChanged() {
        let found = model.languageServers.knownDiagnostics(for: path)
        ProblemMarks.clear(textView)
        let index = LineIndex(textView.nsText)
        var lines: [Int: LSPDiagnostic.Severity] = [:]
        // Worst last, so it's what shows where they overlap.
        for problem in found.sorted(by: { $0.severity > $1.severity }) {
            lines[problem.line + 1] = problem.severity
            guard let start = index.location(line: problem.line, character: problem.character),
                  let end = index.location(line: problem.endLine, character: problem.endCharacter), end >= start else { continue }
            ProblemMarks.underline(NSRange(location: start, length: end - start), severity: problem.severity, in: textView)
        }
        ruler.problemLines = lines
    }

    var supportsFind: Bool { true }

    var selectedTextForFind: String? {
        let range = textView.selectedRange()
        guard range.length > 0, range.length < 200 else { return nil }
        let selected = textView.nsText.substring(with: range)
        return selected.contains("\n") ? nil : selected
    }

    // MARK: Find and replace

    var supportsReplace: Bool { textView.isEditable }

    private func updateFind(_ query: String, caseSensitive: Bool) {
        quoteButton?.isSuppressed = true
        // Next and previous don't change anything, and reading a large file again for them would show.
        if query == findQuery, caseSensitive == findCaseSensitive, !findIsStale { return }
        findQuery = query
        findCaseSensitive = caseSensitive
        findMatches = TextSearch.ranges(of: query, in: textView.nsText, caseSensitive: caseSensitive)
        findIsStale = false
    }

    var findCount: (current: Int, total: Int)? {
        guard !findQuery.isEmpty else { return nil }
        return (currentMatch.map { $0 + 1 } ?? 0, findMatches.count)
    }

    /// As you type, the match stays where it starts. Next and previous move on from there.
    func find(_ query: String, backwards: Bool, incremental: Bool, caseSensitive: Bool) -> Bool {
        updateFind(query, caseSensitive: caseSensitive)
        let selection = textView.selectedRange()
        let index: Int?
        if backwards {
            index = TextSearch.index(before: selection.location, in: findMatches)
        } else {
            let from = incremental ? (findAnchor ?? selection.location) : NSMaxRange(selection)
            index = TextSearch.index(atOrAfter: from, in: findMatches)
        }
        if incremental, findAnchor == nil { findAnchor = selection.location }
        if !incremental { findAnchor = nil }
        currentMatch = index
        markVisibleMatches()
        guard let index else { return false }
        let found = findMatches[index]
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        if !incremental { textView.showFindIndicator(for: found) }
        return true
    }

    func find(_ query: String, backwards: Bool) -> Bool {
        find(query, backwards: backwards, incremental: false, caseSensitive: findCaseSensitive)
    }

    func findIncrementally(_ query: String, caseSensitive: Bool) -> Bool {
        find(query, backwards: false, incremental: true, caseSensitive: caseSensitive)
    }

    func clearFind() {
        quoteButton?.isSuppressed = false
        findQuery = ""
        findMatches = []
        findIsStale = false
        currentMatch = nil
        findAnchor = nil
        markVisibleMatches()
    }

    /// Replaces the match that's selected, then moves to the next. With none selected, finds one first.
    func replaceCurrent(query: String, with replacement: String, caseSensitive: Bool) -> Bool {
        guard textView.isEditable else { return false }
        updateFind(query, caseSensitive: caseSensitive)
        let selection = textView.selectedRange()
        guard findMatches.contains(selection) else {
            return find(query, backwards: false, incremental: false, caseSensitive: caseSensitive)
        }
        let after = selection.location + (replacement as NSString).length
        textView.apply(TextEdit(changes: [TextChange(range: selection, text: replacement)], selection: NSRange(location: after, length: 0)), name: "Replace")
        updateFind(query, caseSensitive: caseSensitive)
        currentMatch = TextSearch.index(atOrAfter: after, in: findMatches)
        if let currentMatch {
            textView.setSelectedRange(findMatches[currentMatch])
            textView.scrollRangeToVisible(findMatches[currentMatch])
        }
        markVisibleMatches()
        return true
    }

    func replaceAll(query: String, with replacement: String, caseSensitive: Bool) -> Int {
        guard textView.isEditable else { return 0 }
        updateFind(query, caseSensitive: caseSensitive)
        let count = findMatches.count
        guard count > 0 else { return 0 }
        textView.apply(TextSearch.replaceAll(findMatches, with: replacement, selection: textView.selectedRange()), name: "Replace All")
        updateFind(query, caseSensitive: caseSensitive)
        currentMatch = nil
        markVisibleMatches()
        return count
    }

    private func refreshFindAfterEdit() {
        guard !findQuery.isEmpty else { return }
        updateFind(findQuery, caseSensitive: findCaseSensitive)
        currentMatch = findMatches.firstIndex(of: textView.selectedRange())
        markVisibleMatches()
        if model.find?.targetItem == itemID { model.findCountChanged() }
    }

    /// Only what's on screen is marked, so a hundred thousand matches cost the same as ten.
    /// Temporary attributes never reach the file or undo.
    private func markVisibleMatches() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let length = textView.nsText.length
        for range in markedMatches where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        markedMatches = []
        defer { restoreBracketMarks() }
        guard !findMatches.isEmpty else { return }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard var index = TextSearch.index(atOrAfter: visible.location, in: findMatches), findMatches[index].location >= visible.location else { return }
        while index < findMatches.count, findMatches[index].location <= NSMaxRange(visible) {
            let range = findMatches[index]
            let color = index == currentMatch ? Self.currentMatchColor : Self.matchColor
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            markedMatches.append(range)
            index += 1
        }
    }

    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.28)
    private static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.55)

    private func restoreBracketMarks() {
        guard let layout = textView.layoutManager else { return }
        let color = NSColor.labelColor.withAlphaComponent(0.16)
        for range in bracketMarks where NSMaxRange(range) <= textView.nsText.length {
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    private func restoreMatchMarks() {
        guard !markedMatches.isEmpty, let layout = textView.layoutManager else { return }
        for range in markedMatches where NSMaxRange(range) <= textView.nsText.length {
            let isCurrent = currentMatch.map { findMatches.indices.contains($0) && findMatches[$0] == range } ?? false
            layout.addTemporaryAttribute(.backgroundColor, value: isCurrent ? Self.currentMatchColor : Self.matchColor, forCharacterRange: range)
        }
    }

    // MARK: Showing a line while choosing

    private var previewMark: NSRange?

    /// Shows a line in the middle of the view without moving the cursor, for jumping through a list.
    func previewLine(_ line: Int) {
        clearPreviewMark()
        let table = ruler.lines
        let index = min(max(line - 1, 0), table.count - 1)
        let start = table.starts[index]
        let string = textView.nsText
        let lineRange = string.lineRange(for: NSRange(location: min(start, string.length), length: 0))
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x = 0
        origin.y = max(rect.midY - clip.bounds.height / 2, 0)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18), forCharacterRange: lineRange)
        previewMark = lineRange
        ruler.needsDisplay = true
    }

    func clearPreviewMark() {
        guard let mark = previewMark else { return }
        previewMark = nil
        if NSMaxRange(mark) <= textView.nsText.length {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: mark)
        }
        restoreBracketMarks()
        restoreMatchMarks()
    }

    var scrollPosition: NSPoint {
        get { scrollView.contentView.bounds.origin }
        set {
            scrollView.contentView.scroll(to: newValue)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            ruler.needsDisplay = true
        }
    }

    var currentLine: Int { ruler.lines.line(containing: textView.selectedRange().location) + 1 }
    var lineCount: Int { ruler.lines.count }
    var text: String { textView.string }
}

/// Line numbers beside the text. A plain view rather than NSRulerView, which on macOS 26+
/// covers the document it's attached to.
final class LineGutter: NSView {
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }
    weak var textView: NSTextView?
    /// Line, counting from 1, to the comments on it.
    var commentMarkers: [Int: [ReviewComment]] = [:] {
        didSet { needsDisplay = true }
    }
    private var markerHits: [(rect: NSRect, comments: [ReviewComment])] = []
    /// Line, counting from 1, to the worst thing wrong with it.
    var problemLines: [Int: LSPDiagnostic.Severity] = [:] {
        didSet { needsDisplay = true }
    }
    private(set) var lines = LineTable()
    private var lineStarts: [Int] { lines.starts }
    private var observers: [NSObjectProtocol] = []
    private(set) var thickness: CGFloat = 44
    var onThicknessChange: (() -> Void)?

    override var isFlipped: Bool { true }

    func attach(to scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: redraw))
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main, using: redraw))
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Text changed: `range` is what's there now.
    func textEdited(range: NSRange, delta: Int, in string: NSString) {
        if range.location == 0, range.length == string.length {
            lines.rebuild(string)
        } else {
            lines.update(editedRange: range, delta: delta, in: string)
        }
        updateThickness()
        needsDisplay = true
    }

    private func updateThickness() {
        let digits = max(String(lines.count).count, 3)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = (CGFloat(digits) * digit + 18).rounded(.up)
        if width != thickness {
            thickness = width
            onThicknessChange?()
        }
    }

    private func lineNumber(forCharacter index: Int) -> Int {
        lines.line(containing: index) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let length = (text.string as NSString).length
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let selectedLine = lineNumber(forCharacter: text.selectedRange().location)
        markerHits = []
        var index = lineNumber(forCharacter: characters.location) - 1
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(characters) { break }
            var line: NSRect
            if start >= length {
                line = layout.extraLineFragmentRect
            } else {
                // A wrapped line can start above the view, somewhere not laid out yet.
                line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            if line.isEmpty, length == 0 { line = NSRect(x: 0, y: 0, width: 0, height: font.pointSize + 4) }
            let y = text.convert(NSPoint(x: 0, y: line.minY + text.textContainerInset.height), to: self).y
            let color: NSColor = index + 1 == selectedLine ? .secondaryLabelColor : .tertiaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: thickness - size.width - 8, y: y + (line.height - size.height) / 2), withAttributes: attributes)
            if let comments = commentMarkers[index + 1] {
                markerHits.append((ReviewMarker.draw(atY: y, lineHeight: line.height), comments))
            }
            if let severity = problemLines[index + 1] {
                ProblemMarks.drawDot(severity: severity, x: thickness - 6, y: y, lineHeight: line.height)
            }
            index += 1
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

/// A gutter and a scrolling text view, side by side.
final class CodeContainer: NSView {
    let gutter = LineGutter()
    let scrollView: NSScrollView
    var onLayout: (() -> Void)?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onThicknessChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let width = gutter.thickness
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = CGRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
        gutter.needsDisplay = true
        onLayout?()
    }
}

/// A small, fast highlighter: comments, strings, numbers and keywords. Not a parser. It's
/// here to make code easier to scan while reviewing, and it stays out of the way when unsure.
nonisolated enum SyntaxHighlighter {
    enum Kind: Sendable {
        case comment, string, number, keyword, function, type, attribute

        @MainActor var color: NSColor {
            switch self {
            case .comment: .secondaryLabelColor
            case .function: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.51, green: 0.71, blue: 0.98, alpha: 1) : NSColor(srgbRed: 0.1, green: 0.34, blue: 0.75, alpha: 1) }
            case .type: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.42, green: 0.82, blue: 0.82, alpha: 1) : NSColor(srgbRed: 0.03, green: 0.44, blue: 0.47, alpha: 1) }
            case .attribute: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.93, green: 0.62, blue: 0.47, alpha: 1) : NSColor(srgbRed: 0.65, green: 0.27, blue: 0.07, alpha: 1) }
            case .string: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.45, green: 0.83, blue: 0.56, alpha: 1) : NSColor(srgbRed: 0.09, green: 0.48, blue: 0.2, alpha: 1) }
            case .number: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.9, green: 0.75, blue: 0.48, alpha: 1) : NSColor(srgbRed: 0.6, green: 0.4, blue: 0, alpha: 1) }
            case .keyword: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.78, green: 0.57, blue: 0.92, alpha: 1) : NSColor(srgbRed: 0.53, green: 0.2, blue: 0.68, alpha: 1) }
            }
        }
    }

    struct Span: Sendable {
        var range: NSRange
        var kind: Kind
    }

    private static let hashComments: Set<String> = ["py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "r", "pl", "ex", "exs", "conf", "ini", "env", "tf", "gitignore"]
    private static let slashComments: Set<String> = ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "go", "rs", "js", "jsx", "mjs", "cjs", "ts", "tsx", "css", "scss", "less", "php", "dart", "scala", "proto", "gradle", "jsonc", "code-workspace"]
    private static let keywords = Set("""
    if else for while do switch case default break continue return func function def class struct enum protocol interface extension import from export package module public private protected internal static final const let var val fn impl trait type try catch throw throws finally async await new this self super nil null none true false True False None in is as guard defer where match with yield lambda and or not pub mut use mod
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// A real grammar when there is one, and the small tokenizer below when there isn't.
    static func spans(text: String, language: String?) -> [Span] {
        if let language, let found = CodeGrammar.shared.spans(text: text, language: language) { return found }
        return tokenSpans(text: text, language: language)
    }

    private static func tokenSpans(text: String, language: String?) -> [Span] {
        let language = language ?? ""
        let hash = hashComments.contains(language)
        let slash = slashComments.contains(language)
        let isData = language == "json" || language == "yaml" || language == "yml" || language == "toml"
        let isProse = !hash && !slash && !isData
        if isProse { return [] }
        let units = Array(text.utf16)
        var spans: [Span] = []
        var index = 0
        let count = units.count
        var token = [UInt16]()
        func isWord(_ unit: UInt16) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
        }
        while index < count {
            let unit = units[index]
            if slash, unit == 47, index + 1 < count, units[index + 1] == 47 {
                let start = index
                while index < count, units[index] != 10 { index += 1 }
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .comment))
            } else if slash, unit == 47, index + 1 < count, units[index + 1] == 42 {
                let start = index
                index += 2
                while index + 1 < count, !(units[index] == 42 && units[index + 1] == 47) { index += 1 }
                index = min(index + 2, count)
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .comment))
            } else if hash, unit == 35 {
                let start = index
                while index < count, units[index] != 10 { index += 1 }
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .comment))
            } else if unit == 34 || unit == 39 || unit == 96 {
                // An apostrophe in the middle of a word isn't a string.
                if unit == 39, index > 0, isWord(units[index - 1]) {
                    index += 1
                    continue
                }
                let start = index
                index += 1
                while index < count, units[index] != unit, units[index] != 10 || unit == 96 {
                    if units[index] == 92 { index += 1 }
                    index += 1
                }
                index = min(index + 1, count)
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .string))
            } else if isWord(unit) {
                let start = index
                token.removeAll(keepingCapacity: true)
                while index < count, isWord(units[index]) {
                    token.append(units[index])
                    index += 1
                }
                if token[0] >= 48, token[0] <= 57 {
                    spans.append(Span(range: NSRange(location: start, length: index - start), kind: .number))
                } else if !isData, keywords.contains(String(decoding: token, as: UTF16.self)) {
                    spans.append(Span(range: NSRange(location: start, length: index - start), kind: .keyword))
                }
            } else {
                index += 1
            }
        }
        return spans
    }
}

/// highlight.js, run in JavaScriptCore on its own thread. Bundled with the app, nothing fetched.
nonisolated final class CodeGrammar: @unchecked Sendable {
    static let shared = CodeGrammar()
    private let queue = DispatchQueue(label: "tiri.grammar", qos: .utility)
    private var context: JSContext?
    private var known = Set<String>()
    private var loaded = false

    /// Beyond this, a real grammar isn't worth the wait on a file you're scrolling.
    private static let maximumLength = 300_000

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return }
        context.evaluateScript(source)
        context.evaluateScript("var hl = globalThis.hljs || hljs; function tiriHighlight(t, l) { return hl.highlight(t, { language: l, ignoreIllegals: true }).value; }")
        self.context = context
    }

    func spans(text: String, language: String) -> [SyntaxHighlighter.Span]? {
        guard text.utf16.count <= Self.maximumLength else { return nil }
        return queue.sync {
            load()
            guard let context, context.evaluateScript("!!hl.getLanguage(\(Self.quote(language)))")?.toBool() == true,
                  let html = context.objectForKeyedSubscript("tiriHighlight")?.call(withArguments: [text, language])?.toString() else { return nil }
            return HighlightMarkup.parse(html).compactMap { run in
                Self.kind(for: run.scope).map { SyntaxHighlighter.Span(range: run.range, kind: $0) }
            }
        }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "#" } + "\""
    }

    private static func kind(for scope: String) -> SyntaxHighlighter.Kind? {
        let parts = scope.split(separator: " ").map { $0.replacingOccurrences(of: "hljs-", with: "") }
        guard let first = parts.first else { return nil }
        switch first {
        case "comment", "quote", "doctag": return .comment
        case "string", "regexp", "addition", "symbol", "bullet", "code": return .string
        case "number", "literal": return .number
        case "keyword", "selector-tag", "meta-keyword", "operator" where first != "operator": return .keyword
        case "title":
            return parts.contains("class_") ? .type : .function
        case "function", "section", "selector-id", "selector-class", "name": return .function
        case "type", "built_in", "class": return .type
        case "attr", "attribute", "property", "params", "variable", "template-variable", "meta", "tag": return .attribute
        default: return nil
        }
    }
}

// MARK: - Images

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

final class ImageController: ItemController {
    let itemID: ItemID
    let path: String
    private let scrollView = ImageScrollView()
    private let imageView = NSImageView()
    private var token: FileWatchHub.Token?
    private var generation = 0
    private var darkOnClear = false
    private unowned let model: AppModel

    var view: NSView { scrollView }

    init(itemID: ItemID, path: String, model: AppModel) {
        self.itemID = itemID
        self.path = path
        self.model = model
        scrollView.contentView = CenteringClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        scrollView.documentView = imageView
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
    }

    private func load() {
        generation += 1
        let current = generation
        let path = path
        let scale = view.window?.backingScaleFactor ?? 2
        // HEIC and big photos take a second or more to decode. That never happens on the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = ImageDecoding.decode(path: path, scale: scale)
            await MainActor.run {
                guard let self, self.generation == current, let decoded else {
                    if let self, self.generation == current { AppModel.shared.viewerReady(self.itemID) }
                    return
                }
                self.display(decoded)
            }
        }
    }

    private func display(_ decoded: ImageDecoding.Decoded) {
        let image: NSImage
        if let data = decoded.animatedData, let animated = NSImage(data: data) {
            image = animated
        } else if let cgImage = decoded.cgImage {
            image = NSImage(cgImage: cgImage, size: decoded.size)
        } else {
            return
        }
        image.size = decoded.size
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: decoded.size)
        darkOnClear = decoded.darkOnClear
        applySettings()
        scrollView.fitOnNextLayout = true
        scrollView.needsLayout = true
        AppModel.shared.viewerReady(itemID)
    }

    func applySettings() {
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = darkOnClear && model.effectiveDark ? ClearArt.plate.cgColor : nil
    }

    func focus() { scrollView.window?.makeFirstResponder(scrollView) }
    func teardown() { token = nil }
}

/// Black line art on a transparent background disappears on a dark surface. Such images get a
/// light plate behind them in dark mode. Anything else keeps showing through to the app.
nonisolated enum ClearArt {
    @MainActor static var plate: NSColor { NSColor(white: 0.93, alpha: 1) }

    static func isDarkOnClear(_ image: CGImage) -> Bool {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return false }
        var clear = 0
        var alpha = 0.0
        var light = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 3] < 26 { clear += 1 }
            alpha += Double(pixels[index + 3])
            // Premultiplied, so this already counts each pixel by how much of it there is.
            light += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        guard alpha > 0, clear > side * side / 50 else { return false }
        return light / alpha < 0.35
    }
}

nonisolated enum ImageDecoding {
    struct Decoded: @unchecked Sendable {
        var cgImage: CGImage?
        var animatedData: Data?
        var size: NSSize
        var darkOnClear = false
    }

    /// Longest side kept in memory. Previews don't need a 48-megapixel bitmap.
    private static let maximumPixels = 6000

    static func decode(path: String, scale: CGFloat) -> Decoded? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        // Sideways phone photos report their unrotated size.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if CGImageSourceGetCount(source) > 1, let data = FileManager.default.contents(atPath: path) {
            let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
            return Decoded(cgImage: nil, animatedData: data, size: size, darkOnClear: first.map(ClearArt.isDarkOnClear) ?? false)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(cgImage: image, animatedData: nil, size: size, darkOnClear: ClearArt.isDarkOnClear(image))
    }
}

final class ImageScrollView: NSScrollView {
    var fitOnNextLayout = true

    override func layout() {
        super.layout()
        guard fitOnNextLayout, let document = documentView, bounds.width > 10, document.frame.width > 0 else { return }
        fitOnNextLayout = false
        // Fit big images; never blow small ones up.
        let scale = min(bounds.width / document.frame.width, bounds.height / document.frame.height, 1)
        magnification = max(scale, minMagnification)
    }

    override var acceptsFirstResponder: Bool { true }
}

final class SVGController: NSObject, ItemController {
    let itemID: ItemID
    let path: String
    private let webView: WKWebView
    private var token: FileWatchHub.Token?
    private var darkOnClear = false
    private var showingPlate = false
    private var generation = 0
    private unowned let model: AppModel

    var view: NSView { webView }

    init(itemID: ItemID, path: String, model: AppModel) {
        self.itemID = itemID
        self.path = path
        self.model = model
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.reload() }
        reload()
    }

    /// Renders it once natively to see what it draws, away from the main thread.
    private func reload() {
        generation += 1
        let current = generation
        let path = path
        load()
        Task.detached(priority: .userInitiated) { [weak self] in
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            // One that has its own dark mode already knows what to do.
            var darkOnClear = false
            if !source.contains("prefers-color-scheme"), let image = NSImage(contentsOfFile: path) {
                var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
                darkOnClear = image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(ClearArt.isDarkOnClear) ?? false
            }
            await MainActor.run { [darkOnClear] in
                guard let self, self.generation == current else { return }
                self.darkOnClear = darkOnClear
                self.applySettings()
            }
        }
    }

    func applySettings() {
        if darkOnClear && model.effectiveDark != showingPlate { load() }
    }

    private func load() {
        showingPlate = darkOnClear && model.effectiveDark
        let plate = showingPlate ? "background:#eee;border-radius:4px;" : ""
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let page = """
        <!DOCTYPE html><style>html,body{height:100%;margin:0;background:transparent;color-scheme:light dark}
        body{display:flex;align-items:center;justify-content:center}img{max-width:94%;max-height:94%;min-width:40%;\(plate)}</style>
        <img src="\(encoded)?\(Int(Date().timeIntervalSince1970 * 1000))">
        """
        webView.loadHTMLString(page, baseURL: LocalFileSchemeHandler.baseURL(forDirectory: directory))
    }

    func focus() { webView.window?.makeFirstResponder(webView) }
    func teardown() { token = nil }
}

// MARK: - Dark documents

/// An item that can be shown dark, or in its true colors, regardless of the setting.
protocol ForceDarkCapable: ItemController {
    var supportsForceDark: Bool { get }
    var forceDarkActive: Bool { get }
    func setForceDark(_ on: Bool?)
}

extension ForceDarkCapable {
    var supportsForceDark: Bool { true }
}

/// PDF and Office pages are white paper drawn by system viewers that have no dark mode. In dark
/// mode this draws them light, then inverts the result on its way to the screen: white paper
/// becomes Tiri's dark surface and black text becomes off-white. Rotating the hue back keeps a
/// blue link blue. Photos in a document can't be told apart from the page, so the moon button
/// shows true colors.
final class DarkPaperHost: NSView {
    let content: NSView
    /// nil follows the `documents.forceDark` setting.
    var forceDarkOverride: Bool?
    var onChange: (() -> Void)?
    private unowned let model: AppModel
    private(set) var isDark = false

    init(content: NSView, forceDark: Bool?, model: AppModel) {
        self.content = content
        self.forceDarkOverride = forceDark
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        addSubview(content)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var wantsDark: Bool {
        forceDarkOverride ?? (model.settings.documentsForceDark && model.effectiveDark)
    }

    func refresh() {
        let dark = wantsDark
        guard dark != isDark else { return }
        isDark = dark
        content.appearance = dark ? NSAppearance(named: .aqua) : nil
        contentFilters = dark ? Self.filters() : []
        onChange?()
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Worked out in sRGB, so a mid gray stays a mid gray.
    private static func filters() -> [CIFilter] {
        // CSS hue-rotate(180deg). Each row sums to 1.
        let hue: [[CGFloat]] = [[-0.574, 1.430, 0.144], [0.426, 0.430, 0.144], [0.426, 1.430, -0.856]]
        // White paper lands on Tiri's dark surface, and black text stops short of pure white.
        let lift: CGFloat = 0.11
        let span: CGFloat = 0.82
        func row(_ values: [CGFloat]) -> CIVector {
            CIVector(x: -span * values[0], y: -span * values[1], z: -span * values[2], w: 0)
        }
        let matrix = CIFilter(name: "CIColorMatrix")!
        matrix.setValue(row(hue[0]), forKey: "inputRVector")
        matrix.setValue(row(hue[1]), forKey: "inputGVector")
        matrix.setValue(row(hue[2]), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: lift + span, y: lift + span, z: lift + span, w: 0), forKey: "inputBiasVector")
        return [CIFilter(name: "CILinearToSRGBToneCurve")!, matrix, CIFilter(name: "CISRGBToneCurveToLinear")!]
    }
}

// MARK: - PDF

/// Offers to quote what's selected when you right-click it.
final class TiriPDFView: PDFView {
    var onQuote: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, currentSelection?.string?.isEmpty == false else { return menu }
        let item = NSMenuItem(title: "Quote in Agent", action: #selector(quoteFromMenu), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func quoteFromMenu() { onQuote?() }
}

final class PDFController: NSObject, ForceDarkCapable {
    let itemID: ItemID
    let path: String
    private let pdfView = TiriPDFView()
    private let host: DarkPaperHost
    private unowned let model: AppModel
    private var token: FileWatchHub.Token?
    private var observers: [NSObjectProtocol] = []
    private var watchedScroll = false
    // Outside the host, because in dark mode everything inside it is inverted.
    private let container = HostContainer()
    private lazy var quoteButton: QuoteButton = {
        let button = QuoteButton(host: container)
        button.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        return button
    }()

    var view: NSView { container }

    init(itemID: ItemID, spec: FileSpec, model: AppModel) {
        self.itemID = itemID
        self.path = spec.path
        self.model = model
        host = DarkPaperHost(content: pdfView, forceDark: spec.forceDark, model: model)
        super.init()
        container.show(host)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        host.onChange = { [weak self] in self?.applyBackground() }
        applyBackground()
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateQuoteButton() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main, using: update))
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main, using: update))
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func didAttach() { watchScrolling() }

    /// The scroll view is PDFKit's own, and only exists once there's a document on screen.
    private func watchScrolling() {
        guard !watchedScroll, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        watchedScroll = true
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateQuoteButton() }
        })
    }

    /// Level with the first part of the selection that's on screen. None on screen, no button.
    private func updateQuoteButton() {
        watchScrolling()
        guard let selection = pdfView.currentSelection, selection.string?.isEmpty == false else {
            quoteButton.isHidden = true
            return
        }
        for page in selection.pages {
            let area = pdfView.convert(pdfView.convert(selection.bounds(for: page), from: page), to: container)
            if area.intersects(container.bounds) {
                let top = container.isFlipped ? area.minY : container.bounds.height - area.maxY
                quoteButton.show(fromTop: max(top, 4))
                return
            }
        }
        quoteButton.isHidden = true
    }

    func select(text: String, to end: String?) -> Bool {
        guard let document = pdfView.document,
              let start = document.findString(text, fromSelection: nil, withOptions: [.caseInsensitive]) else { return false }
        var selection = start
        if let end {
            guard let last = document.findString(end, fromSelection: start, withOptions: [.caseInsensitive]),
                  let firstPage = start.pages.first, let lastPage = last.pages.last else { return false }
            let from = start.range(at: 0, on: firstPage)
            let to = last.range(at: 0, on: lastPage)
            guard let whole = document.selection(from: firstPage, atCharacterIndex: from.location,
                                                 to: lastPage, atCharacterIndex: NSMaxRange(to) - 1) else { return false }
            selection = whole
        }
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.scrollSelectionToVisible(nil)
        return true
    }

    /// Inverted along with the page, so it has to be light to end up dark.
    private func applyBackground() {
        pdfView.backgroundColor = host.isDark ? NSColor(white: 0.9, alpha: 1) : .textBackgroundColor
    }

    func applySettings() { host.refresh() }
    var forceDarkActive: Bool { host.wantsDark }

    func setForceDark(_ on: Bool?) {
        host.forceDarkOverride = on
        host.refresh()
    }

    private func load() {
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        pdfView.document = PDFDocument(url: URL(fileURLWithPath: path))
        if let page, let target = pdfView.document?.page(at: page) { pdfView.go(to: target) }
    }

    func goTo(line: Int?, col: Int?) {
        // `report.pdf:3` means page 3.
        if let line, let page = pdfView.document?.page(at: max(line - 1, 0)) { pdfView.go(to: page) }
    }

    func focus() { pdfView.window?.makeFirstResponder(pdfView) }
    func teardown() { token = nil }

    var supportsFind: Bool { true }
    var selectedTextForFind: String? { pdfView.currentSelection?.string }

    /// A PDF has pages, not lines, so what's selected goes in as a quotation.
    var agentReference: AgentSelection? {
        guard let selection = pdfView.currentSelection, let text = selection.string, !text.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let numbers = selection.pages.compactMap { pdfView.document?.index(for: $0) }.map { $0 + 1 }
        var pages = ""
        if let first = numbers.first, let last = numbers.last {
            pages = first == last ? ", page \(first)" : ", pages \(first)-\(last)"
        }
        return AgentSelection(path: path, quote: AgentReference.quotation(from: name + pages, text: text))
    }

    func find(_ query: String, backwards: Bool) -> Bool {
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        guard let document = pdfView.document else { return false }
        var match = document.findString(query, fromSelection: pdfView.currentSelection, withOptions: options)
        if match == nil { match = document.findString(query, fromSelection: nil, withOptions: options) }
        guard let match else { return false }
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.scrollSelectionToVisible(nil)
        return true
    }

    func clearFind() { pdfView.clearSelection() }
}

// MARK: - Audio and video

final class MediaController: ItemController {
    let itemID: ItemID
    private let playerView = AVPlayerView()
    private let player: AVPlayer
    private let audioView: AudioPlayerView?

    var view: NSView { audioView ?? playerView }

    init(itemID: ItemID, path: String) {
        self.itemID = itemID
        player = AVPlayer(url: URL(fileURLWithPath: path))
        if FileClassifier.isAudioOnly(path: path) {
            audioView = AudioPlayerView(player: player, name: (path as NSString).lastPathComponent)
        } else {
            audioView = nil
            playerView.player = player
            playerView.controlsStyle = .inline
        }
    }

    func focus() { view.window?.makeFirstResponder(audioView?.playButton ?? playerView) }

    func teardown() {
        player.pause()
        playerView.player = nil
        audioView?.stop()
    }
}

/// AVPlayerView fills an audio file's missing picture with a gray panel, in any theme. Audio
/// gets plain native controls on the same surface as every other viewer.
final class AudioPlayerView: NSView {
    let playButton = NSButton()
    private let player: AVPlayer
    private let icon = NSImageView()
    private let label: NSTextField
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00")
    private var observer: Any?

    init(player: AVPlayer, name: String) {
        self.player = player
        label = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.contentTintColor = .labelColor
        slider.target = self
        slider.action = #selector(seek)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        for view in [icon, label, playButton, slider, time] { addSubview(view) }
        updatePlayButton()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func tick() {
        let current = player.currentTime().seconds
        if duration > 0 { slider.doubleValue = current / duration }
        let total = Int(max(duration - current, 0).rounded())
        time.stringValue = "\(total / 60):" + String(format: "%02d", total % 60)
        if duration > 0, current >= duration { player.pause() }
        updatePlayButton()
    }

    private func updatePlayButton() {
        let symbol = player.timeControlStatus == .paused ? "play.fill" : "pause.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "play.fill" ? "Play" : "Pause")
    }

    @objc private func togglePlay() {
        if player.timeControlStatus == .paused {
            if duration > 0, player.currentTime().seconds >= duration { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        updatePlayButton()
    }

    @objc private func seek() {
        player.seek(to: CMTime(seconds: slider.doubleValue * duration, preferredTimescale: 600))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        let width = min(max(bounds.width - 48, 200), 480)
        let x = (bounds.width - width) / 2
        let top = max((bounds.height - 140) / 2, 8)
        icon.frame = CGRect(x: x, y: top, width: width, height: 64)
        label.frame = CGRect(x: x, y: top + 72, width: width, height: 20)
        playButton.frame = CGRect(x: x, y: top + 106, width: 28, height: 28)
        time.frame = CGRect(x: x + width - 44, y: top + 112, width: 44, height: 16)
        slider.frame = CGRect(x: x + 36, y: top + 108, width: width - 88, height: 24)
    }
}

// MARK: - CSV

final class CSVController: NSObject, ItemController, NSTableViewDataSource, NSTableViewDelegate {
    let itemID: ItemID
    let path: String
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private var rows: [[String]] = []
    private var token: FileWatchHub.Token?
    private var generation = 0

    var view: NSView { scrollView }

    init(itemID: ItemID, path: String) {
        self.itemID = itemID
        self.path = path
        super.init()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
    }

    private func load() {
        generation += 1
        let current = generation
        let path = path
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = FileManager.default.contents(atPath: path) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let parsed = CSVParser.parse(text)
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.display(parsed)
            }
        }
    }

    private func display(_ parsed: CSVParser.Table) {
        rows = parsed.rows
        table.tableColumns.forEach { table.removeTableColumn($0) }
        let width = max(parsed.header.count, parsed.rows.map(\.count).max() ?? 0)
        for index in 0..<width {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = index < parsed.header.count ? parsed.header[index] : ""
            column.width = columnWidth(index: index, header: column.title)
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.reloadData()
    }

    private func columnWidth(index: Int, header: String) -> CGFloat {
        var longest = header.count
        for row in rows.prefix(200) where index < row.count {
            longest = max(longest, row[index].count)
        }
        return min(max(CGFloat(longest) * 7.5 + 18, 60), 420)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let index = Int(column.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.isSelectable = true
            return field
        }()
        let cells = rows[row]
        field.stringValue = index < cells.count ? cells[index] : ""
        return field
    }

    func focus() { table.window?.makeFirstResponder(table) }
    func teardown() { token = nil }

    var supportsFind: Bool { true }

    func find(_ query: String, backwards: Bool) -> Bool {
        guard !rows.isEmpty else { return false }
        let start = table.selectedRow >= 0 ? table.selectedRow : (backwards ? rows.count : -1)
        let count = rows.count
        for step in 1...count {
            let row = ((start + (backwards ? -step : step)) % count + count) % count
            if rows[row].contains(where: { $0.range(of: query, options: .caseInsensitive) != nil }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    func clearFind() { table.deselectAll(nil) }
}

// MARK: - Office, iWork and everything else

final class QuickLookController: ForceDarkCapable {
    let itemID: ItemID
    private let preview: QLPreviewView
    private let host: DarkPaperHost
    private let url: URL
    private var token: FileWatchHub.Token?
    /// Office pages are paper. Anything else Quick Look shows, like a file's icon, isn't.
    let supportsForceDark: Bool

    var view: NSView { host }

    init(itemID: ItemID, spec: FileSpec, isPaper: Bool, model: AppModel) {
        self.itemID = itemID
        self.url = URL(fileURLWithPath: spec.path)
        self.supportsForceDark = isPaper
        preview = QLPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), style: .normal)
        host = DarkPaperHost(content: preview, forceDark: isPaper ? spec.forceDark : false, model: model)
        // Tabs move this view around, and it must survive leaving the window.
        preview.shouldCloseWithWindow = false
        preview.previewItem = url as NSURL
        token = FileWatchHub.shared.watch(path: spec.path) { [weak self] in
            self?.preview.refreshPreviewItem()
        }
    }

    func applySettings() { host.refresh() }
    var forceDarkActive: Bool { host.wantsDark }

    func setForceDark(_ on: Bool?) {
        host.forceDarkOverride = on
        host.refresh()
    }

    func focus() { preview.window?.makeFirstResponder(preview) }

    func teardown() {
        token = nil
        preview.close()
    }
}
