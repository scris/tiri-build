import AppKit
import Observation
import TiriCore
import WebKit

/// A web view item: local or remote pages, with auto-reload and forced dark.
@Observable
final class WebController: NSObject, ForceDarkCapable, WKNavigationDelegate, WKUIDelegate {
    let itemID: ItemID
    let isFile: Bool
    @ObservationIgnored unowned let model: AppModel
    @ObservationIgnored let webView: TiriWebView
    @ObservationIgnored private let container = HostContainer()
    @ObservationIgnored private lazy var quoteButton: QuoteButton = {
        let button = QuoteButton(host: container)
        button.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        return button
    }()
    @ObservationIgnored private var token: FileWatchHub.Token?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var appearanceObserver: NSObjectProtocol?
    @ObservationIgnored private var requested: URL
    @ObservationIgnored private var showingError = false
    @ObservationIgnored private var lastPopupAt: Double = 0

    var addressText: String
    var title: String = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// nil follows the `web.forceDark` setting.
    var forceDarkOverride: Bool?
    var errorCount = 0
    var picking = false
    @ObservationIgnored var log: [WebLogEntry] = []
    @ObservationIgnored var requests: [WebRequestEntry] = []

    var view: NSView { container }

    /// A web page has no lines to point at, so what's selected goes in as a quotation.
    var agentReference: AgentSelection? {
        guard let selection = webView.selection else { return nil }
        let source = isFile ? (requested.path as NSString).lastPathComponent : currentURLString
        return AgentSelection(path: requested.path, quote: AgentReference.quotation(from: source, text: selection.text))
    }

    func select(text: String, to end: String?) -> Bool {
        webView.evaluateJavaScript(WebSelectionScript.selecting(text, to: end), in: nil, in: .defaultClient) { _ in }
        return true
    }

    /// What this item is showing: the page asked for, even while its error page is up.
    var currentURLString: String {
        showingError ? requested.absoluteString : (webView.url?.absoluteString ?? requested.absoluteString)
    }

    var forceDarkActive: Bool {
        if let forceDarkOverride { return forceDarkOverride }
        return model.settings.webForceDark && model.effectiveDark
    }

    init(itemID: ItemID, url: URL, forceDark: Bool?, isFile: Bool, model: AppModel) {
        self.itemID = itemID
        self.isFile = isFile
        self.model = model
        self.requested = url
        self.forceDarkOverride = forceDark
        self.addressText = url.isFileURL ? url.path : url.absoluteString
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = TiriWebView.makeConfigured(configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installTools()
        container.show(webView)
        webView.onQuote = { [weak self] in self?.model.addFrontToAgent() }
        webView.onSelectionChange = { [weak self] selection, top in
            guard let self else { return }
            if selection != nil, let top {
                self.quoteButton.show(fromTop: top)
            } else {
                self.quoteButton.isHidden = true
            }
        }
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                let value = view.canGoBack
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.canGoBack = value } }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                let value = view.canGoForward
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.canGoForward = value } }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let value = view.title ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.titleChanged(value) } }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let value = view.isLoading
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.isLoading = value } }
            },
        ]
        load(url)
        watchIfLocal(url)
    }

    private func titleChanged(_ value: String) {
        title = value
        model.controllerRevision += 1
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageStarted()
    }

    func load(_ url: URL) {
        requested = url
        showingError = false
        addressText = url.isFileURL ? url.path : url.absoluteString
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func submitAddress() {
        let raw = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let target = CLIParser.normalizeWebTarget(raw, cwd: NSHomeDirectory())
        var url: URL?
        if target.hasPrefix("file://"), !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.hasPrefix(".") {
            // Typed something without a scheme: it's a website unless it's clearly a path.
            url = URL(string: "https://" + raw)
        } else {
            url = URL(string: target)
        }
        guard let url else { return }
        load(url)
        watchIfLocal(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        // The error page isn't the page. Reload tries what was asked for.
        if showingError { load(requested) } else { webView.reload() }
    }

    private func watchIfLocal(_ url: URL) {
        guard url.isFileURL else {
            token = nil
            return
        }
        // A page's folder, not just the file: a changed stylesheet should reload it too.
        let directory = url.deletingLastPathComponent().path
        token = FileWatchHub.shared.watch(path: directory, recursive: true) { [weak self] in
            self?.webView.reload()
        }
    }

    // MARK: Forced dark

    func setForceDark(_ on: Bool?) {
        forceDarkOverride = on
        applyDark()
    }

    func toggleForceDark() {
        model.setForceDark(!forceDarkActive, item: itemID)
    }

    private func applyDark() {
        // Let pages with a dark mode use their own first; only fall back to inverting.
        webView.appearance = forceDarkActive ? NSAppearance(named: .darkAqua) : nil
        webView.evaluateJavaScript(forceDarkActive ? Self.enableDarkScript : Self.disableDarkScript, completionHandler: nil)
    }

    private static let disableDarkScript = """
    (function(){ for (const id of ['tiri-dark-scheme','tiri-dark-invert']) { const n=document.getElementById(id); if(n) n.remove(); } })();
    """

    /// `color-scheme: dark` first; if the page still paints a light background, invert it
    /// and re-invert media so photos and video keep their colors.
    private static let enableDarkScript = """
    (function(){
      const add=(id,css)=>{ let n=document.getElementById(id); if(!n){ n=document.createElement('style'); n.id=id; (document.head||document.documentElement).appendChild(n);} n.textContent=css; };
      add('tiri-dark-scheme', ':root{color-scheme:dark !important}');
      const invertCSS = `html{filter:invert(1) hue-rotate(180deg) !important;background:#fff !important}
        img,video,picture,canvas,iframe,embed,object,svg image,[style*="background-image"]{filter:invert(1) hue-rotate(180deg) !important}`;
      const luminance=(c)=>{ const m=c.match(/rgba?\\(([^)]+)\\)/); if(!m) return null; const p=m[1].split(',').map(parseFloat);
        if(p.length===4 && p[3]===0) return null; return (0.2126*p[0]+0.7152*p[1]+0.0722*p[2])/255; };
      requestAnimationFrame(()=>{
        const old=document.getElementById('tiri-dark-invert'); if(old) old.remove();
        const body=document.body; let l=null;
        if(body) l=luminance(getComputedStyle(body).backgroundColor);
        if(l===null) l=luminance(getComputedStyle(document.documentElement).backgroundColor);
        // A transparent page on color-scheme:dark is already dark unless its text is dark.
        let lightPage = l!==null && l>0.5;
        if(l===null && body){ const t=luminance(getComputedStyle(body).color); if(t!==null && t<0.35) lightPage=true; }
        if(lightPage) add('tiri-dark-invert', invertCSS);
      });
    })();
    """

    // MARK: Delegates

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "data", "blob":
            decisionHandler(.allow)
        case "file":
            // Local pages can link to each other. A remote page has no business in local files.
            decisionHandler(requested.isFileURL && (webView.url?.isFileURL ?? true) ? .allow : .cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model.viewerReady(itemID)
        if showingError {
            applyDark()
            return
        }
        if let url = webView.url, url.scheme != "about" {
            addressText = url.isFileURL ? url.path : url.absoluteString
            requested = url
            let isLocal = url.isFileURL
            if isLocal { watchIfLocal(url) }
        }
        applyDark()
        if !isFile, let index = model.workspaces.firstIndex(where: { $0.item(itemID) != nil }), let url = webView.url {
            model.workspaces[index].updateItem(itemID) { item in
                if case .web(var spec) = item.content {
                    spec.url = url.absoluteString
                    spec.title = webView.title
                    item.content = .web(spec)
                }
            }
            model.scheduleSave()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        showError(error)
    }

    private func showError(_ error: any Error) {
        let nsError = error as NSError
        // A navigation replaced by another one isn't a failure.
        if nsError.code == NSURLErrorCancelled || nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let address = requested.absoluteString
        let escaped = address.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let reason = nsError.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let page = """
        <!DOCTYPE html><meta charset="utf-8"><title>Can't load page</title>
        <style>:root{color-scheme:light dark}body{font:14px -apple-system;margin:0;height:100vh;display:flex;align-items:center;justify-content:center;color:GrayText}
        div{max-width:460px;text-align:center}h1{font-size:17px;font-weight:600;color:CanvasText;margin:0 0 8px}code{word-break:break-all}</style>
        <div><h1>Can't load this page</h1><p>\(reason)</p><p><code>\(escaped)</code></p><p>Press reload to try again.</p></div>
        """
        showingError = true
        webView.loadHTMLString(page, baseURL: nil)
        addressText = requested.isFileURL ? requested.path : address
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank opens as a peer item rather than a stray window. Pages can ask for this
        // from a script without any click, so it's web links only, one at a time, in this
        // page's own workspace, and only the page in front gets to take the keyboard.
        guard let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        let now = ProcessClock.now()
        guard now - lastPopupAt > 1000 else { return nil }
        lastPopupAt = now
        model.openWeb(url: url.absoluteString, split: nil, in: model.workspace(containing: itemID)?.id)
        return nil
    }

    // MARK: ItemController

    func focus() { webView.window?.makeFirstResponder(webView) }

    func applySettings() {
        applyDark()
        webView.pageZoom = model.webZoom
    }

    func teardown() {
        token = nil
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    var supportsFind: Bool { true }

    func find(_ query: String, backwards: Bool) -> Bool {
        WebFind.run(webView, query: query, backwards: backwards)
    }

    func clearFind() { WebFind.clear(webView) }
}
