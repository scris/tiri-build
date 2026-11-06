import AppKit
import AVKit
import PDFKit
import QuickLookUI
import JavaScriptCore
import TiriCore
import TiriHighlight
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
    nonisolated static let scheme = "tiri-file"

    nonisolated static func baseURL(forDirectory directory: String) -> URL {
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
        if let viewer = model.plugins.makeViewer(itemID: itemID, spec: spec) { return viewer }
        let kind = FileClassifier.classify(path: spec.path) {
            guard let handle = FileHandle(forReadingAtPath: spec.path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
        switch kind {
        case .markdown:
            return MarkdownController(itemID: itemID, spec: spec, model: model, format: .markdown)
        case .notebook:
            return MarkdownController(itemID: itemID, spec: spec, model: model, format: .notebook)
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

// MARK: - Markdown and notebooks: rendered by default, source on request

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

final class MarkdownController: NSObject, ItemController, WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated enum Format: Sendable { case markdown, notebook }

    let format: Format
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
    /// The text viewer in front, when it's the source that's showing.
    var shownSource: TextController? { showingSource ? source : nil }
    private var token: FileWatchHub.Token?
    private var pendingScrollY: Double?
    private var pendingAnchor: String?
    private var pendingLine: (Int?, Int?)
    /// Each new render replaces any still under way.
    private var renderGeneration = 0
    private var pageHasDiagrams = false
    private var pageHasPendingDiagrams = false
    private var renderedDark = false
    /// Drawn diagrams for each theme, by source, so a reload shows them straight away.
    private var drawnDiagrams: [Bool: [String: DocumentExtras.Diagram]] = [:]
    /// Why this notebook is showing its source, when rendering it isn't possible.
    private var fallbackNotice: String?
    private var fallbackWork: DispatchWorkItem?
    private var hasRenderedPage = false
    private var showingOpeningNote = false
    private lazy var noticeView = SourceNoticeView()
    // A notebook's cells, when it's being run or typed in.
    private var shownCells: [Notebook.Cell] = []
    private var currentCell: Int?
    private var editingCell: Int?
    /// What the file held in that cell when typing began, or at the last save.
    private var editingBase: String?
    private var renderAfterEditing = false
    private var editAfterRender: Int?
    private var outputGenerations: [Int: Int] = [:]

    var view: NSView { container }

    private var inSource: Bool { showingSource || fallbackNotice != nil }
    /// There's nothing to switch to when the file can't be rendered.
    var canToggleSource: Bool { fallbackNotice == nil }
    var kindName: String { format == .notebook ? "notebook" : "markdown" }

    init(itemID: ItemID, spec: FileSpec, model: AppModel, format: Format = .markdown) {
        self.format = format
        self.itemID = itemID
        self.path = spec.path
        self.model = model
        // There's nothing to read in an empty file, so it's somewhere to type.
        let isEmpty = format == .markdown && (try? FileManager.default.attributesOfItem(atPath: spec.path))?[.size] as? Int == 0
        // Edits kept from before a quit or a crash are in the source, so that's what comes back.
        self.showingSource = UnsavedEdits.read(itemID)?.path == spec.path ? true : (spec.showSource ?? isEmpty)
        self.pendingLine = (spec.line, spec.col)
        super.init()
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.fileChanged() }
        render(keepScroll: false)
        if format == .notebook {
            model.notebookKernels.register(self)
            model.notebookKernels.kernel(for: path).adoptIfRunning()
        }
    }

    private func makeWebView() -> TiriWebView {
        let view = MarkdownWebViews.take()
        view.pageZoom = model.webZoom
        view.navigationDelegate = self
        view.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        view.onSelectionChange = { [weak self] selection, top in self?.renderedSelectionChanged(selection, top: top) }
        if format == .notebook {
            let controller = view.configuration.userContentController
            controller.removeScriptMessageHandler(forName: NotebookPage.handler, contentWorld: .defaultClient)
            controller.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: NotebookPage.handler)
        }
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
        guard format == .markdown, selection.line >= 0, selection.lineEnd >= selection.line else { return nil }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return MarkdownRenderer.sourceLines(blockStart: selection.line, blockEnd: selection.lineEnd, selected: selection.text, source: text)
    }

    func select(text: String, to end: String?) -> Bool {
        if inSource { return source?.select(text: text, to: end) ?? false }
        webView.evaluateJavaScript(WebSelectionScript.selecting(text, to: end), in: nil, in: .defaultClient) { _ in }
        return true
    }

    private func sourceController() -> TextController {
        if let source { return source }
        let controller = TextController(itemID: itemID, spec: FileSpec(path: path), model: model, watches: false)
        source = controller
        return controller
    }

    private func render(keepScroll: Bool, behindSource: Bool = false) {
        if inSource, !behindSource {
            let text = sourceController()
            if let fallbackNotice {
                noticeView.show(fallbackNotice, above: text.view)
                container.show(noticeView)
            } else {
                container.show(text.view)
            }
            if let line = pendingLine.0 {
                text.goTo(line: line, col: pendingLine.1)
                pendingLine = (nil, nil)
            }
            return
        }
        renderGeneration += 1
        let generation = renderGeneration
        if !behindSource {
            container.show(webView)
            if !hasRenderedPage { showOpeningNote(generation: generation) }
        }
        let path = path
        let format = format
        let line = format == .markdown ? pendingLine.0 : nil
        if format == .markdown { pendingLine = (nil, nil) }
        let dark = model.effectiveDark
        renderedDark = dark
        let diagrams = drawnDiagrams[dark] ?? [:]
        let directory = (path as NSString).deletingLastPathComponent
        let base = LocalFileSchemeHandler.baseURL(forDirectory: directory)
        let title = (path as NSString).lastPathComponent
        // Off the main thread: a long document with lots of math shouldn't stall the app.
        Task.detached(priority: .userInitiated) { [weak self] in
            if format == .notebook {
                let result = Self.renderNotebook(path: path, base: base, title: title, diagrams: diagrams)
                await MainActor.run {
                    guard let self, self.renderGeneration == generation else { return }
                    switch result {
                    case .success(let (rendered, cells)):
                        self.shownCells = cells
                        self.notebookRendered(rendered, base: base, keepScroll: keepScroll)
                    case .failure(let failure): self.notebookFailed(failure)
                    }
                }
                return
            }
            let source = (try? String(contentsOfFile: path, encoding: .utf8))
                ?? String(data: FileManager.default.contents(atPath: path) ?? Data(), encoding: .isoLatin1)
                ?? ""
            let rendered = MarkdownRenderer.render(markdown: source, baseHref: base.absoluteString, title: title,
                                                   extras: Self.extras(diagrams: diagrams))
            // Rendered stays rendered: `report.md:40` lands on the section holding line 40.
            let anchor = line.flatMap { MarkdownRenderer.anchor(forLine: $0, in: source) }
            await MainActor.run {
                guard let self, self.renderGeneration == generation else { return }
                self.load(rendered, base: base, anchor: anchor, keepScroll: keepScroll)
            }
        }
    }

    /// A big document takes seconds to read. A blank pane for that long looks broken.
    private func showOpeningNote(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.renderGeneration == generation, !self.hasRenderedPage, self.fallbackNotice == nil else { return }
            self.showingOpeningNote = true
            let opening = MarkdownRenderer.escapeText(String(localized: "Opening…"))
            self.webView.loadHTMLString("""
            <!DOCTYPE html><meta charset="utf-8"><style>:root{color-scheme:light dark}html{height:100%}body{height:100%;margin:0;display:flex;align-items:center;justify-content:center;font:13px -apple-system;color:GrayText}</style>\(opening)
            """, baseURL: nil)
        }
    }

    nonisolated private static func renderNotebook(path: String, base: URL, title: String, diagrams: [String: DocumentExtras.Diagram]) -> Result<(RenderedDocument, [Notebook.Cell]), Notebook.Failure> {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        if size > Notebook.maximumBytes { return .failure(.tooLarge(bytes: size)) }
        // Not mapped: an agent cutting a mapped file short while it's being parsed would crash the app.
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        do {
            let notebook = try Notebook.parse(data)
            let rendered = NotebookRenderer.render(notebook, baseHref: base.absoluteString, title: title, extras: extras(diagrams: diagrams),
                                                   highlight: { HighlightEngine.shared.html(code: $0, language: $1) }, interactive: true)
            return .success((rendered, notebook.cells))
        } catch {
            return .failure(error)
        }
    }

    private func notebookRendered(_ rendered: RenderedDocument, base: URL, keepScroll: Bool) {
        fallbackWork?.cancel()
        fallbackWork = nil
        if fallbackNotice != nil {
            // Fixing it by hand here: what's being typed stays until it's saved.
            if source?.isDirty == true { return }
            fallbackNotice = nil
            model.controllerRevision += 1
        }
        load(rendered, base: base, anchor: nil, keepScroll: keepScroll)
    }

    /// An agent writing a notebook can leave it half written for a moment. What was showing
    /// stays until it's clear that the file really is broken.
    private func notebookFailed(_ failure: Notebook.Failure) {
        let show = { [weak self] in
            guard let self else { return }
            let hadKeyboard = self.view.window?.firstResponder === self.webView
            self.fallbackNotice = failure.message
            self.quoteButton.isHidden = true
            self.sourceController().reload()
            self.render(keepScroll: false)
            if hadKeyboard { self.source?.focus() }
            self.model.controllerRevision += 1
            self.model.viewerReady(self.itemID)
        }
        fallbackWork?.cancel()
        guard hasRenderedPage, fallbackNotice == nil else {
            show()
            return
        }
        let work = DispatchWorkItem(block: show)
        fallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    nonisolated private static func extras(diagrams: [String: DocumentExtras.Diagram]) -> DocumentExtras {
        let document = UUID()
        return DocumentExtras(renderMath: { MathEngine.shared.markup(tex: $0, display: $1, document: document) },
                              mathStylesheet: { MathEngine.stylesheet }, diagrams: diagrams,
                              highlight: { HighlightEngine.shared.html(code: $0, language: $1) })
    }

    private func load(_ rendered: RenderedDocument, base: URL, anchor: String?, keepScroll: Bool) {
        container.show(webView)
        hasRenderedPage = true
        pageHasDiagrams = rendered.hasDiagrams
        pageHasPendingDiagrams = rendered.hasPendingDiagrams
        if let anchor { pendingAnchor = anchor }
        if keepScroll {
            // Agents rewrite files as they work. A reload shouldn't lose your place.
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingScrollY = value as? Double
                    self.webView.loadHTMLString(rendered.html, baseURL: base)
                }
            }
        } else {
            webView.loadHTMLString(rendered.html, baseURL: base)
        }
    }

    /// Runs once the page is showing. Diagrams change its height, so a place it was asked to keep
    /// gets restored again afterwards.
    private func drawDiagrams(generation: Int, restoring place: @escaping @MainActor @Sendable () -> Void) {
        let dark = renderedDark
        Task.detached(priority: .userInitiated) { [weak self] in
            let library = WebLibrary.text("mermaid/mermaid.min.js")
            await MainActor.run {
                guard let self, self.renderGeneration == generation else { return }
                guard let library else {
                    self.webView.evaluateJavaScript(DiagramDrawing.giveUp, in: nil, in: DiagramDrawing.world) { _ in }
                    return
                }
                self.webView.evaluateJavaScript(library + "\n;0", in: nil, in: DiagramDrawing.world) { _ in
                    MainActor.assumeIsolated {
                        guard self.renderGeneration == generation else { return }
                        self.webView.callAsyncJavaScript(DiagramDrawing.draw, arguments: ["dark": dark], in: nil, in: DiagramDrawing.world) { result in
                            MainActor.assumeIsolated {
                                if case .success(let value) = result { self.remember(value, dark: dark) } else {
                                    self.webView.evaluateJavaScript(DiagramDrawing.giveUp, in: nil, in: DiagramDrawing.world) { _ in }
                                }
                                if self.renderGeneration == generation { place() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func remember(_ results: Any?, dark: Bool) {
        guard let results = results as? [[String: Any]] else { return }
        var known = drawnDiagrams[dark] ?? [:]
        // Plenty for one document, and a file an agent keeps rewriting can't grow this for ever.
        if known.count > 64 { known = [:] }
        for result in results {
            guard let key = result["key"] as? String else { continue }
            if let svg = result["svg"] as? String {
                known[key] = .drawn(svg: svg)
            } else if let reason = result["reason"] as? String {
                known[key] = .failed(reason: reason)
            }
        }
        drawnDiagrams[dark] = known
    }

    private func fileChanged() {
        if !FileManager.default.fileExists(atPath: path) { return }
        if inSource { source?.reload() }
        guard !showingSource else { return }
        if format == .notebook, fallbackNotice == nil {
            // What's being typed stays until it's done with.
            if editingCell != nil {
                renderAfterEditing = true
                return
            }
            // A kernel's results already showed as they came, and reloading the page for them would
            // lose the reader's selection for nothing. So only what really differs from the page counts.
            // While one runs, its saves lag behind what's showing, so then only the code counts.
            let path = path
            let shown = shownCells
            let running = model.notebookKernels.existing(for: path)?.isActive == true
            let generation = renderGeneration
            Task.detached(priority: .userInitiated) { [weak self] in
                let cells = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? Notebook.parse($0) }?.cells
                if let cells, cells == shown { return }
                if let cells, running, cells.map(\.source) == shown.map(\.source) { return }
                await MainActor.run {
                    guard let self, self.renderGeneration == generation else { return }
                    self.render(keepScroll: true)
                }
            }
            return
        }
        // Behind a notice, the source stays up unless the file now renders.
        render(keepScroll: fallbackNotice == nil, behindSource: fallbackNotice != nil)
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
        if showingOpeningNote, !hasRenderedPage { return }
        model.viewerReady(itemID)
        let scrollY = pendingScrollY
        let anchor = pendingAnchor
        pendingScrollY = nil
        pendingAnchor = nil
        let restorePlace: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if let scrollY { self.webView.evaluateJavaScript("window.scrollTo(0, \(scrollY))", completionHandler: nil) }
            if let anchor { self.scrollTo(anchor: anchor) }
        }
        restorePlace()
        if format == .notebook { preparePage() }
        if pageHasPendingDiagrams {
            pageHasPendingDiagrams = false
            drawDiagrams(generation: renderGeneration, restoring: restorePlace)
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
            let openHere = { [weak model] in _ = model?.openWeb(url: url.absoluteString, split: nil) }
            if !model.sendsToBrowser(url, openHere: openHere) { openHere() }
        case "mailto":
            NSWorkspace.shared.open(url)
        default:
            // A document shouldn't be able to launch an arbitrary URL scheme handler.
            break
        }
    }

    func focus() {
        if inSource { source?.focus() } else { webView.window?.makeFirstResponder(webView) }
    }

    func applySettings() {
        source?.applySettings()
        // A drawn diagram's colors are fixed when it's drawn. Everything else follows by itself.
        if !inSource, pageHasDiagrams, renderedDark != model.effectiveDark { render(keepScroll: true) }
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
        if inSource {
            source?.goTo(line: line, col: col)
            return
        }
        // A notebook's lines are its JSON's, and don't exist in the rendered page.
        guard format == .markdown else { return }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if let anchor = MarkdownRenderer.anchor(forLine: line, in: text) { scrollTo(anchor: anchor) }
    }

    func teardown() {
        token = nil
        fallbackWork?.cancel()
        if format == .notebook, hasRenderedPage {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: NotebookPage.handler, contentWorld: .defaultClient)
        }
        if hasRenderedPage { webView.stopLoading() }
    }

    var supportsFind: Bool { true }

    var selectedTextForFind: String? { inSource ? source?.selectedTextForFind : nil }
    var agentReference: AgentSelection? {
        if inSource { return source?.agentReference }
        guard hasRenderedPage, let selection = webView.selection else { return nil }
        if let lines = renderedLines(selection) {
            return AgentSelection(path: path, firstLine: lines.first, lastLine: lines.last)
        }
        var name = (path as NSString).lastPathComponent
        if format == .notebook, selection.line >= 0 {
            let first = selection.line + 1
            let last = max(selection.lineEnd + 1, first)
            name += first == last ? ", cell \(first)" : ", cells \(first)-\(last)"
        }
        return AgentSelection(path: path, quote: AgentReference.quotation(from: name, text: selection.text))
    }
    var isDirty: Bool { source?.isDirty ?? false }
    func save(overwriting: Bool) -> SaveResult { source?.save(overwriting: overwriting) ?? .saved }
    func keepUnsavedEdits() -> Bool { source?.keepEditsNow() ?? true }

    func find(_ query: String, backwards: Bool) -> Bool {
        if inSource { return source?.find(query, backwards: backwards) ?? false }
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
        if inSource { source?.clearFind() } else { WebFind.clear(webView) }
    }
}

/// A line of explanation above what it's about.
final class SourceNoticeView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let line = NSBox()
    private weak var content: NSView?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        line.boxType = .separator
        addSubview(label)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show(_ notice: String, above view: NSView) {
        label.stringValue = notice
        if content !== view {
            content?.removeFromSuperview()
            content = view
            // Scroll views draw past their edges, which would cover the line above.
            view.clipsToBounds = true
            addSubview(view, positioned: .below, relativeTo: label)
        }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = max(bounds.width - 28, 40)
        let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height ?? 16)
        label.frame = CGRect(x: 14, y: 8, width: width, height: height)
        let top = height + 16
        line.frame = CGRect(x: 0, y: top - 1, width: bounds.width, height: 1)
        content?.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
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
    private var editWork: DispatchWorkItem?
    private lazy var highlighter = LineHighlighter(textView: textView)
    private(set) lazy var completion = CompletionController(editor: self)
    private lazy var realPath = Git.real(path)
    private var quoteButton: QuoteButton?
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
    private var keepEditsWork: DispatchWorkItem?
    private var menuProblems: [LSPDiagnostic] = []
    private var folderToken: FileWatchHub.Token?
    /// The PDF this LaTeX file builds, once there is one.
    private(set) var compiledPDF: String? {
        didSet { if compiledPDF != oldValue { model.controllerRevision += 1 } }
    }
    private(set) var isDirty = false {
        didSet { if isDirty != oldValue { model.controllerRevision += 1 } }
    }
    nonisolated static let maximumBytes = 32 * 1024 * 1024
    /// How the file's bytes are read, and written back. Found when it opens, unless someone chose one.
    private(set) var encoding: String.Encoding = .utf8 {
        didSet { if encoding != oldValue { model.controllerRevision += 1 } }
    }
    private var chosenEncoding: String.Encoding?
    /// The start of what's on disk, so a byte order mark goes back on when it's saved.
    private var startOnDisk = Data()
    /// Past this, a file gets no marks beside its lines.
    private static let largestWithMarks = 4 * 1024 * 1024
    private var marksGeneration = 0

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
            watchForCompiledPDF()
        }
        reload()
        model.languageServers.viewerOpened(path, viewer: self) { [weak self] in
            guard let self, self.isDirty else { return nil }
            return self.textView.string
        }
    }

    /// An agent's first latexmk makes the PDF while this is open, so its folder gets watched.
    private func watchForCompiledPDF() {
        guard (path as NSString).pathExtension.lowercased() == "tex" else { return }
        compiledPDF = CompiledPDF.find(forTex: path)
        folderToken = FileWatchHub.shared.watch(path: (path as NSString).deletingLastPathComponent, recursive: true) { [weak self] in
            guard let self else { return }
            self.compiledPDF = CompiledPDF.find(forTex: self.path)
        }
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        if textView.isSteering { return }
        completion.selectionMoved()
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
        // VoiceOver says "text area" otherwise, with nothing to say which file it is.
        text.setAccessibilityLabel((path as NSString).lastPathComponent)
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
        text.backgroundColor = ThemePalette.editorBackground
        text.textColor = ThemePalette.editorForeground
        text.insertionPointColor = ThemePalette.editorCursor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ThemePalette.editorBackground
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        ruler.attach(to: scrollView, textView: text)
        ruler.onChangeClicked = { [weak self] line in
            guard let self else { return }
            self.model.peekChange(path: self.path, line: line)
        }
        container.onLayout = { [weak self] in
            self?.fitTextToPane()
            self?.fitTextToWrapColumn()
        }
        scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markVisibleMatches()
                self?.completion.scrolled()
            }
        }
        applySettings()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    /// Keeps the line table up to date, looking only at what changed.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        ruler.textEdited(range: editedRange, delta: delta, in: textStorage.string as NSString)
        highlighter.textEdited(range: editedRange, delta: delta, in: textStorage)
        let replacement = (textStorage.string as NSString).substring(with: editedRange)
        model.languageServers.textEdited(realPath: realPath, range: NSRange(location: editedRange.location, length: editedRange.length - delta),
                                         replacement: replacement, length: textStorage.length)
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

    /// A view that was hosted narrow, in a split or before its first layout, can stay narrow in a wider
    /// pane, and the row with the cursor is only marked as far as the view goes.
    private func fitTextToPane() {
        let width = scrollView.contentSize.width
        guard width > 0, wrap == .off ? textView.frame.width < width : abs(textView.frame.width - width) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
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
        let found = BracketMatcher.match(in: string, caret: selection.location) { [highlighter] in highlighter.isInStringOrComment($0) }
        guard let found else { return }
        let color = NSColor.labelColor.withAlphaComponent(0.16)
        for offset in [found.open, found.close] {
            let range = NSRange(location: offset, length: 1)
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            bracketMarks.append(range)
        }
    }

    private static let systemSelection = NSTextView().selectedTextAttributes

    func applySettings() {
        let settings = model.settings
        textView.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSizeZoomed))
        ruler.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSizeZoomed) - 1)
        applyWrap()
        // The theme's colors are looked up as they're drawn: a new one only needs drawing again. Only a theme's own
        // selection replaces the system's, which also knows to dim when the window isn't in front.
        textView.selectedTextAttributes = ThemePalette.current == nil ? Self.systemSelection : [.backgroundColor: ThemePalette.editorSelection]
        textView.needsDisplay = true
        textView.enclosingScrollView?.needsDisplay = true
        ruler.needsDisplay = true
    }

    func reload() {
        let path = path
        // Agents often write by replacing the file, so it can be briefly missing. A file that's
        // gone keeps showing what it last said rather than going blank.
        if loadedOnce, !FileManager.default.fileExists(atPath: path) { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        let wanted = chosenEncoding
        if size > 5 * 1024 * 1024 {
            // Big logs load off the main thread so opening one never stalls the app.
            Task.detached(priority: .userInitiated) { [weak self] in
                let read = Self.read(path: path, as: wanted)
                await MainActor.run { self?.display(read) }
            }
        } else {
            display(Self.read(path: path, as: wanted))
        }
    }

    /// Reopen with Encoding: the same file, read another way. Unsaved edits would be lost, so not with any.
    func reopen(as wanted: String.Encoding) -> String? {
        guard !isDirty else { return String(localized: "Save or undo your edits first.") }
        let read = Self.read(path: path, as: wanted)
        guard read.encoding == wanted else { return String(localized: "It isn't valid \(TextEncodings.name(of: wanted)).") }
        chosenEncoding = wanted
        loadedOnce = false
        display(read)
        return nil
    }

    /// Save as UTF-8: what's showing, written back as UTF-8 from now on.
    func convertToUTF8() -> String? {
        guard let bytes = textView.string.data(using: .utf8) else { return String(localized: "Couldn't write it as UTF-8.") }
        do {
            try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return error.localizedDescription
        }
        chosenEncoding = nil
        encoding = .utf8
        startOnDisk = Data()
        savedText = textView.string
        isDirty = false
        keepEditsNow()
        textView.isEditable = true
        model.languageServers.didSave(path)
        return nil
    }

    struct Read: Sendable {
        var text: String
        var editable: Bool
        var encoding: String.Encoding
        var start: Data
    }

    /// Saving what's shown has to give back exactly what's on disk, or it isn't editable: a file that was cut
    /// short, or that its encoding can't give back byte for byte, would be damaged. One that wasn't UTF-8 is
    /// read the way it was written, or the way chosen, and saved the same way.
    nonisolated private static func read(path: String, as wanted: String.Encoding? = nil) -> Read {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            let text = FileManager.default.fileExists(atPath: path) ? String(localized: "Tiri isn't allowed to read this file. Check its permissions.") : ""
            return Read(text: text, editable: false, encoding: .utf8, start: Data())
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        // A choice that can't read it is reported by the caller, which gets back what would be found instead.
        let decoded = wanted.flatMap { TextEncodings.decode(data, as: $0) } ?? TextEncodings.decode(data)
        var text = decoded?.text ?? String(decoding: data, as: UTF8.self)
        let start = data.prefix(4)
        if data.count == maximumBytes {
            text += "\n\n" + String(localized: "… truncated at \(maximumBytes / (1024 * 1024)) MB. Open it in an external editor to see the rest.")
            return Read(text: text, editable: false, encoding: decoded?.encoding ?? .utf8, start: start)
        }
        return Read(text: text, editable: decoded?.roundTrips == true, encoding: decoded?.encoding ?? .utf8, start: start)
    }

    private func display(_ read: Read) {
        let text = read.text
        let editable = read.editable
        // Your edits come first. An agent writing the same file doesn't get to erase them.
        if isDirty {
            if text != savedText {
                diskChangedUnderEdits = true
                model.showToast(title: String(localized: "\((path as NSString).lastPathComponent) changed on disk"),
                                detail: String(localized: "You have unsaved changes here, so they're still showing."),
                                symbol: "exclamationmark.triangle", tint: .orange, actionTitle: String(localized: "Use Disk Version")) { [weak self] in
                    self?.discardEdits()
                }
            }
            return
        }
        savedText = text
        encoding = read.encoding
        startOnDisk = read.start
        textView.isEditable = editable
        guard text != textView.string || !loadedOnce else {
            applyPendingLocation()
            refreshChangeMarks()
            return
        }
        let origin = scrollView.contentView.bounds.origin
        let selection = textView.selectedRange()
        // Edits from before a quit or a crash come back over what's on disk, as they were.
        let kept = loadedOnce || !editable ? nil : UnsavedEdits.read(itemID).flatMap { $0.path == path ? $0 : nil }
        let shown = kept?.text ?? text
        textView.dropExtraCursors()
        textView.string = shown
        highlighter.use(language: LanguageCatalog.language(forPath: path, firstLine: Self.firstLine(of: shown)))
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
        if let kept { cameBack(kept, onDisk: text) }
        applyPendingLocation()
        highlighter.paintVisible()
        diagnosticsChanged()
        model.languageServers.fileMayHaveChanged(path)
        refreshChangeMarks()
    }

    private func cameBack(_ kept: UnsavedEdit, onDisk text: String) {
        guard kept.text != text else {
            UnsavedEdits.remove(itemID)
            return
        }
        isDirty = true
        model.fileWasEdited(itemID)
        guard kept.diskChanged(now: text) else { return }
        diskChangedUnderEdits = true
        model.showToast(title: String(localized: "\((path as NSString).lastPathComponent) changed on disk while Tiri was closed"),
                        detail: String(localized: "Your unsaved changes are still showing."),
                        symbol: "exclamationmark.triangle", tint: .orange, actionTitle: String(localized: "Use Disk Version")) { [weak self] in
            self?.discardEdits()
        }
    }

    /// Kept on disk shortly after each edit, so nothing typed is lost to a crash.
    private func scheduleKeepingEdits() {
        keepEditsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.keepEditsNow() }
        keepEditsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func keepUnsavedEdits() -> Bool { keepEditsNow() }

    /// False if there are edits and they couldn't be kept.
    @discardableResult
    func keepEditsNow() -> Bool {
        keepEditsWork?.cancel()
        keepEditsWork = nil
        guard isDirty else {
            UnsavedEdits.remove(itemID)
            return true
        }
        do {
            try UnsavedEdits.write(UnsavedEdit(path: path, text: textView.string, onDisk: savedText), for: itemID)
            return true
        } catch {
            return false
        }
    }

    // MARK: Marks beside the lines

    /// What differs from the last commit. A file outside the workspace's repositories, or a very
    /// large one, never gets as far as asking git. Your own edits aren't on disk yet, so while
    /// there are any the marks wouldn't line up, and they wait until you save.
    func refreshChangeMarks() {
        marksGeneration += 1
        ruler.changesHidden = isDirty
        guard (textView.string as NSString).length <= Self.largestWithMarks, let place = model.repositoryPlace(of: path) else {
            ruler.changes = LineChanges()
            return
        }
        let current = marksGeneration
        Task.detached(priority: .utility) { [weak self] in
            let changes = Git.lineChanges(relative: place.relative, root: place.root)
            await MainActor.run {
                guard let self, self.marksGeneration == current else { return }
                self.ruler.changes = changes
            }
        }
    }

    var hasChangeMarks: Bool { !isDirty && !ruler.changes.starts.isEmpty }

    /// F7 and ⇧F7, round and round.
    func goToChange(forward: Bool) {
        let starts = ruler.changes.starts
        guard !starts.isEmpty, !isDirty else { return }
        let here = editorSelection.startLine + 1
        let target = forward ? (starts.first { $0 > here } ?? starts[0]) : (starts.last { $0 < here } ?? starts[starts.count - 1])
        jump(line: target, col: 1)
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
        if view.selectedRange().length > 0 { add(String(localized: "Quote in Agent"), #selector(quoteSelection)) }
        add(String(localized: "Add Comment"), #selector(addComment))
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

    func textDidChange(_ notification: Notification) {
        // A different length says it without comparing every character of a large file.
        isDirty = textView.nsText.length != (savedText as NSString).length || textView.string != savedText
        ruler.changesHidden = isDirty
        if isDirty { model.fileWasEdited(itemID) }
        scheduleKeepingEdits()
        reviewChanged()
        ruler.needsDisplay = true
        findIsStale = true
        markBrackets()
        editWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshFindAfterEdit()
        }
        editWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// A plugin came or went. Same text, and maybe another language now.
    func languagesChanged(restarting scopes: Set<String>) {
        let language = LanguageCatalog.language(forPath: path, firstLine: Self.firstLine(of: textView.string))
        // The same grammar under the same name carries on, with nothing to see.
        if let grammar = language?.grammar, scopes.contains(grammar) { highlighter.use(language: nil) }
        highlighter.use(language: language)
    }

    var currentLineForPlugins: Int {
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        var line = 1
        var index = 0
        while index < location {
            let unit = text.character(at: index)
            if unit == 10 || (unit == 13 && (index + 1 >= text.length || text.character(at: index + 1) != 10)) { line += 1 }
            index += 1
        }
        return line
    }

    func save(overwriting: Bool) -> SaveResult {
        guard isDirty else { return .saved }
        let onDisk = Self.read(path: path, as: encoding).text
        if !overwriting, onDisk != savedText, FileManager.default.fileExists(atPath: path) { return .changedOnDisk }
        guard let bytes = TextEncodings.encode(textView.string, as: encoding, bom: startOnDisk) else {
            return .failed(String(localized: "\(TextEncodings.name(of: encoding)) can't hold everything typed here. Choose Save as UTF-8 from its encoding above the file."))
        }
        do {
            try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
            savedText = textView.string
            diskChangedUnderEdits = false
            isDirty = false
            keepEditsNow()
            model.languageServers.didSave(path)
            model.remote.didSave(path)
            model.plugins.fileSaved(path)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func discardEdits() {
        isDirty = false
        keepEditsNow()
        diskChangedUnderEdits = false
        undo.removeAllActions()
        reload()
        model.languageServers.fileMayHaveChanged(path)
    }

    /// For a file whose name doesn't say, like a script with a `#!` line.
    private static func firstLine(of text: String) -> String {
        String(text.prefix(200).prefix { !$0.isNewline })
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
        // A cursor, not a selection: going to a line isn't choosing it. A selection brings up Quote in
        // Agent, tells Claude about it, and the next key typed would replace the line.
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
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

    func didAttach() {
        model.languageServers.viewerShown(path)
        highlighter.paintVisible()
        completion.refreshWordsSoon(delay: 0.1)
        // The bar offers to add a language nobody knows, once there's a text file to say it about.
        if LanguageCatalog.language(forPath: path) == nil {
            DispatchQueue.main.async { [weak self] in self?.model.controllerRevision += 1 }
        }
    }

    func isInStringOrComment(_ offset: Int) -> Bool { highlighter.isInStringOrComment(offset) }

    func teardown() {
        token = nil
        folderToken = nil
        completion.close()
        model.languageServers.viewerClosed(path, viewer: self)
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
        textView.apply(TextEdit(changes: [TextChange(range: selection, text: replacement)], selection: NSRange(location: after, length: 0)), name: String(localized: "Replace"))
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
        textView.apply(TextSearch.replaceAll(findMatches, with: replacement, selection: textView.selectedRange()), name: String(localized: "Replace All"))
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
    /// What differs from the last commit: thin bars at the edge, nearest the text.
    var changes = LineChanges() {
        didSet { if changes != oldValue { needsDisplay = true } }
    }
    var changesHidden = false {
        didSet { if changesHidden != oldValue { needsDisplay = true } }
    }
    var onChangeClicked: ((Int) -> Void)?
    private var changeHits: [(rect: NSRect, line: Int)] = []
    private(set) var lines = LineTable()
    private var lineStarts: [Int] { lines.starts }
    private var observers: [NSObjectProtocol] = []
    private(set) var thickness: CGFloat = 48
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
        // A text view has no height until it's laid out, and nothing else would ask for its numbers again.
        textView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main, using: redraw))
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
        ThemePalette.editorBackground.setFill()
        dirtyRect.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let length = (text.string as NSString).length
        // What the scroll view shows, not `visibleRect`: while a Peek grows open that's only a sliver,
        // and the first draw is the only one that covers the numbers.
        let shown = text.enclosingScrollView?.documentVisibleRect ?? text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: shown, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let selectedLine = lineNumber(forCharacter: text.selectedRange().location)
        markerHits = []
        changeHits = []
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
            let color: NSColor = index + 1 == selectedLine ? ThemePalette.currentLineNumber : ThemePalette.lineNumber
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: thickness - size.width - 12, y: y + (line.height - size.height) / 2), withAttributes: attributes)
            if !changesHidden { drawChanges(forLine: index + 1, y: y, height: line.height) }
            if let comments = commentMarkers[index + 1] {
                markerHits.append((ReviewMarker.draw(atY: y, lineHeight: line.height), comments))
            }
            if let severity = problemLines[index + 1] {
                ProblemMarks.drawDot(severity: severity, x: thickness - 10, y: y, lineHeight: line.height)
            }
            index += 1
        }
    }

    private func drawChanges(forLine line: Int, y: CGFloat, height: CGFloat) {
        let width: CGFloat = 3
        // A wide target, for a thin mark.
        let hitX = thickness - 9
        if let kind = changes.lines[line] {
            (kind == .added ? NSColor.systemGreen : NSColor.systemBlue).setFill()
            NSRect(x: thickness - width, y: y, width: width, height: height).fill()
            changeHits.append((NSRect(x: hitX, y: y, width: 9, height: height), line))
        }
        // Lines deleted here have no row of their own, so a small wedge sits between the rows.
        if changes.deletions.contains(line) { drawDeletion(atY: y, line: line) }
        if changes.deletions.contains(line + 1), line == lineStarts.count { drawDeletion(atY: y + height, line: line + 1) }
    }

    private func drawDeletion(atY y: CGFloat, line: Int) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: thickness, y: y - 4))
        path.line(to: NSPoint(x: thickness - 6, y: y))
        path.line(to: NSPoint(x: thickness, y: y + 4))
        path.close()
        NSColor.systemRed.setFill()
        path.fill()
        // First, so it wins over a bar it sits on.
        changeHits.insert((NSRect(x: thickness - 9, y: y - 5, width: 9, height: 10), line), at: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (changeHits.contains { $0.rect.contains(point) } ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = markerHits.first(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(point) }) {
            AppModel.shared.editReviewComment(hit.comments[0], from: self, rect: hit.rect)
            return
        }
        if let hit = changeHits.first(where: { $0.rect.contains(point) }) {
            onChangeClicked?(hit.line)
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
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return decode(source: source, scale: scale) { FileManager.default.contents(atPath: path) }
    }

    /// An image that isn't a file, like an old version from git.
    static func decode(data: Data, scale: CGFloat) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: source, scale: scale) { data }
    }

    private static func decode(source: CGImageSource, scale: CGFloat, contents: () -> Data?) -> Decoded? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        // Sideways phone photos report their unrotated size.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if CGImageSourceGetCount(source) > 1, let data = contents() {
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
        let item = NSMenuItem(title: String(localized: "Quote in Agent"), action: #selector(quoteFromMenu), keyEquivalent: "")
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
    private var pendingPage: Int?
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
        pendingPage = spec.line
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
        let url = URL(fileURLWithPath: path)
        guard pdfView.document != nil else {
            pdfView.document = PDFDocument(url: url)
            if let pendingPage { goTo(line: pendingPage, col: nil) }
            pendingPage = nil
            return
        }
        // latexmk writes in place, so a change can arrive with half a file. The finished file
        // sends another change, and until then what's showing stays.
        guard Self.isComplete(url), let document = PDFDocument(url: url), document.pageCount > 0 else { return }
        // An agent recompiling shouldn't lose your place: same page, same spot on it, same zoom.
        let place = pdfView.currentDestination
        let pageIndex = place?.page.flatMap { pdfView.document?.index(for: $0) }
        let keepsFit = pdfView.autoScales
        let scale = pdfView.scaleFactor
        pdfView.document = document
        if keepsFit {
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
        }
        pdfView.layoutDocumentView()
        if let pageIndex, let place, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            pdfView.go(to: PDFDestination(page: page, at: place.point))
        }
        // The selection went with the old document.
        updateQuoteButton()
    }

    /// A PDF ends with `%%EOF`, give or take a few bytes.
    nonisolated private static func isComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        try? handle.seek(toOffset: size > 2048 ? size - 2048 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        return tail.range(of: Data("%%EOF".utf8)) != nil
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
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "play.fill" ? String(localized: "Play") : String(localized: "Pause"))
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
    private let container = HostContainer()
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private lazy var noticeView = SourceNoticeView()
    private var file: CSVFile?
    private var numericColumns: Set<Int> = []
    /// A table asks for a row one cell at a time.
    private var cachedRow: (index: Int, cells: [String])?
    private var token: FileWatchHub.Token?
    private var generation = 0
    private var findTask: Task<Void, Never>?

    var view: NSView { container }

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
        container.show(scrollView)
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
    }

    private func load() {
        generation += 1
        let current = generation
        let path = path
        Task.detached(priority: .userInitiated) { [weak self] in
            // A file being replaced can be gone for a moment. What's showing stays until it's back.
            guard let file = CSVFile(path: path) else { return }
            let numeric = file.numericColumns()
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.display(file, numeric: numeric)
            }
        }
    }

    private func display(_ new: CSVFile, numeric: Set<Int>) {
        let sameColumns = file?.header == new.header && file?.columnCount == new.columnCount
        file = new
        numericColumns = numeric
        cachedRow = nil
        // An agent adding rows shouldn't reset your column widths or your place.
        if !sameColumns { rebuildColumns() }
        table.reloadData()
        showNotice()
    }

    private func rebuildColumns() {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        guard let file else { return }
        for index in 0..<max(file.header.count, file.columnCount) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = index < file.header.count ? file.header[index] : ""
            column.headerCell.alignment = numericColumns.contains(index) ? .right : .left
            column.width = columnWidth(index: index, header: column.title, file: file)
            column.minWidth = 40
            table.addTableColumn(column)
        }
    }

    private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private func columnWidth(index: Int, header: String, file: CSVFile) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.cellFont]
        var widest = (header as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        // Both ends: the last rows of a long file have the longest ids.
        let sample = Array(0..<min(file.rowCount, 100)) + Array(max(file.rowCount - 50, 100)..<max(file.rowCount, 100))
        for row in sample {
            let cells = file.row(row)
            if index < cells.count { widest = max(widest, (cells[index] as NSString).size(withAttributes: attributes).width) }
        }
        return min(max(ceil(widest) + 18, 50), 420)
    }

    private func showNotice() {
        var notice: String?
        if let file {
            if file.header.isEmpty {
                notice = String(localized: "This file is empty.")
            } else if file.isTruncated {
                notice = String(localized: "Showing the first \(file.rowCount.formatted()) rows.")
            }
        }
        if let notice {
            noticeView.show(notice, above: scrollView)
            container.show(noticeView)
        } else {
            container.show(scrollView)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { file?.rowCount ?? 0 }

    private func cells(_ row: Int) -> [String] {
        if let cachedRow, cachedRow.index == row { return cachedRow.cells }
        let cells = file?.row(row) ?? []
        cachedRow = (row, cells)
        return cells
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let index = Int(column.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.font = Self.cellFont
            field.isSelectable = true
            return field
        }()
        let cells = cells(row)
        let cell = index < cells.count ? cells[index] : ""
        // One line to a row. A line break shows as a mark, and the whole cell is a hover away.
        let hasBreak = cell.utf8.contains(10) || cell.utf8.contains(13)
        field.stringValue = hasBreak ? cell.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ") : cell
        field.alignment = numericColumns.contains(index) ? .right : .left
        field.toolTip = hasBreak || cell.count > 50 ? cell : nil
        return field
    }

    func focus() { table.window?.makeFirstResponder(table) }

    func teardown() {
        token = nil
        findTask?.cancel()
    }

    var supportsFind: Bool { true }

    /// Off the main thread, because a file can have millions of rows. The bar's "not found" state
    /// updates when the answer arrives, as it does for web pages.
    func find(_ query: String, backwards: Bool) -> Bool {
        guard let file else { return false }
        findTask?.cancel()
        let start = table.selectedRow >= 0 ? table.selectedRow : nil
        findTask = Task.detached(priority: .userInitiated) { [weak self] in
            let row = file.find(query, from: start, backwards: backwards) { Task.isCancelled }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                if let row {
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.table.scrollRowToVisible(row)
                }
                AppModel.shared.find?.notFound = row == nil
            }
        }
        return true
    }

    func clearFind() {
        findTask?.cancel()
        table.deselectAll(nil)
    }
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

// MARK: - Running a notebook

extension MarkdownController {
    private var kernel: NotebookKernel { model.notebookKernels.kernel(for: path) }
    var isNotebook: Bool { format == .notebook }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let operation = body["op"] as? String else { return }
        let cell = (body["cell"] as? NSNumber)?.intValue
        switch operation {
        case "select":
            currentCell = cell
        case "run":
            if let cell { runCell(cell) }
        case "edit":
            if let cell { beginEditing(cell) }
        case "save":
            if let cell, let source = body["source"] as? String { saveSource(cell, source) }
        case "endEdit":
            endEditing(run: body["run"] as? Bool ?? false, cell: cell)
        case "cancelEdit":
            if let cell, let source = body["source"] as? String { saveSource(cell, source) }
            endEditing(run: false, cell: cell)
        case "add":
            addCell(kind: body["kind"] as? String == "markdown" ? .markdown : .code)
        case "answer":
            kernel.answer(body["value"] as? String ?? "")
        default:
            break
        }
    }

    /// Runs after every load: what's going on has to show on the new page.
    private func preparePage() {
        webView.evaluateJavaScript(NotebookPage.script, in: nil, in: .defaultClient) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let currentCell = self.currentCell, self.editAfterRender == nil { self.callPage("tiriNB.select(cell)", ["cell": currentCell]) }
                self.kernelStatusChanged(self.kernel)
                if let cell = self.editAfterRender {
                    self.editAfterRender = nil
                    self.beginEditing(cell)
                }
            }
        }
    }

    private func callPage(_ code: String, _ arguments: [String: Any]) {
        webView.callAsyncJavaScript(code, arguments: arguments, in: nil, in: .defaultClient) { _ in }
    }

    /// Working on a Peek or a preview means wanting to keep it.
    private func keep() {
        if model.active.peek?.id == itemID {
            model.promotePeek()
        } else {
            model.updateWorkspace(containing: itemID) { $0.pin(itemID) }
        }
    }

    func runCell(_ index: Int) {
        keep()
        kernel.run(cells: [index])
    }

    func runAllCells() {
        keep()
        kernel.runAll()
    }

    func runCurrentCell() {
        if let currentCell { runCell(currentCell) }
    }

    private func cells() -> [Notebook.Cell]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? Notebook.parse($0) }?.cells
    }

    private func beginEditing(_ index: Int) {
        guard editingCell == nil, let cells = cells(), cells.indices.contains(index) else { return }
        keep()
        editingCell = index
        editingBase = cells[index].source
        callPage("tiriNB.beginEdit(cell, source)", ["cell": index, "source": cells[index].source])
    }

    private func saveSource(_ index: Int, _ source: String) {
        guard let base = editingBase, base != source else { return }
        let sent = kernel.edit(["action": "source", "index": .int(index), "expected": .string(base), "source": .string(source)])
        if sent {
            editingBase = source
            return
        }
        write { data in try NotebookEditing.replacingSource(in: data, cell: index, expecting: base, with: source) }
        editingBase = source
    }

    private func endEditing(run: Bool, cell: Int?) {
        editingCell = nil
        editingBase = nil
        renderAfterEditing = false
        // The highlighted version of what was typed.
        render(keepScroll: true)
        guard run, let cell else { return }
        // Its save went first, so what runs is what's on the screen.
        if kernel.isAttached || RemoteRegistry.shared.connection(forLocal: path) == nil {
            kernel.run(cells: [cell])
        } else if let connection = RemoteRegistry.shared.connection(forLocal: path) {
            connection.push(path) { [weak self] _ in
                DispatchQueue.main.async { self?.kernel.run(cells: [cell]) }
            }
        }
    }

    func addCell(kind: NotebookEditing.NewCell) {
        let count = cells()?.count ?? 0
        let after = currentCell.map { min($0, count - 1) } ?? count - 1
        keep()
        editAfterRender = after + 1
        currentCell = after + 1
        if !kernel.edit(["action": "insert", "after": .int(after), "kind": .string(kind == .code ? "code" : "markdown")]) {
            write { data in try NotebookEditing.insertingCell(in: data, after: after, kind: kind) }
        }
    }

    func deleteCurrentCell() {
        guard let index = currentCell else {
            model.showNotebookNotice(String(localized: "Click a cell first."))
            return
        }
        keep()
        currentCell = nil
        if !kernel.edit(["action": "delete", "index": .int(index)]) {
            write { data in try NotebookEditing.deletingCell(in: data, cell: index) }
        }
    }

    func clearOutputs() {
        keep()
        if !kernel.edit(["action": "clear"]) {
            write { data in try NotebookEditing.clearingOutputs(in: data) }
        }
    }

    private func write(_ change: (Data) throws -> Data) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try change(data).write(to: URL(fileURLWithPath: path), options: .atomic)
            model.remote.didSave(path)
        } catch NotebookEditing.Failure.changedMeanwhile {
            model.showNotebookNotice(String(localized: "Something else changed this cell while you were editing it, so your edit wasn't saved."))
        } catch {
            model.showNotebookNotice(String(localized: "Couldn't change this notebook: \(error.localizedDescription)"))
        }
    }

    func kernelStatusChanged(_ kernel: NotebookKernel) {
        guard hasRenderedPageForKernel else { return }
        callPage("tiriNB.status(running, queued)", ["running": kernel.running as Any? ?? NSNull(), "queued": kernel.queued])
        if let question = kernel.question, let cell = kernel.running {
            callPage("tiriNB.ask(cell, prompt, password)", ["cell": cell, "prompt": question.prompt, "password": question.password])
        } else {
            callPage("tiriNB.answered()", [:])
        }
    }

    func kernelOutput(index: Int, count: Int?, running: Bool, outputs: [Notebook.Output]) {
        guard hasRenderedPageForKernel else { return }
        if shownCells.indices.contains(index) {
            shownCells[index].outputs = outputs
            shownCells[index].executionCount = running ? nil : count
        }
        let generation = (outputGenerations[index] ?? 0) + 1
        outputGenerations[index] = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let extras = DocumentExtras(renderMath: { MathEngine.shared.markup(tex: $0, display: $1, document: UUID()) }, mathStylesheet: { MathEngine.stylesheet })
            let html = NotebookRenderer.outputsHTML(outputs, extras: extras)
            await MainActor.run {
                guard let self, self.outputGenerations[index] == generation else { return }
                self.callPage("tiriNB.outputs(cell, html, count)", ["cell": index, "html": html, "count": count as Any? ?? NSNull()])
            }
        }
    }

    private var hasRenderedPageForKernel: Bool { isNotebook && !showingSource }

    /// For a test copy: what a click or a key press in the page would set off.
    func runInPage(_ script: String) {
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }
}
