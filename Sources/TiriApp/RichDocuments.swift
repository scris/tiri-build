import Foundation
import JavaScriptCore
import TiriCore
import WebKit

/// Where bundled web libraries live. Nothing here is fetched.
nonisolated enum WebLibrary {
    static func url(_ path: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("web/\(path)")
    }

    static func text(_ path: String) -> String? {
        url(path).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// KaTeX, run in JavaScriptCore on its own thread, and only loaded once a document has math.
nonisolated final class MathEngine: @unchecked Sendable {
    static let shared = MathEngine()
    private let queue = DispatchQueue(label: "tiri.math", qos: .userInitiated)
    private var context: JSContext?
    private var render: JSValue?
    private var loaded = false
    private var currentDocument: UUID?

    private static let glue = """
    var tiriMacros = {};
    function tiriResetMath() { tiriMacros = {}; }
    function tiriMath(tex, display) {
      try { return katex.renderToString(tex, { displayMode: display, throwOnError: true, output: 'html', strict: false, macros: tiriMacros, globalGroup: true }); }
      catch (error) { return null; }
    }
    """

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let source = WebLibrary.text("katex/katex.min.js"), let context = JSContext() else { return }
        context.evaluateScript(source)
        context.evaluateScript(Self.glue)
        self.context = context
        render = context.objectForKeyedSubscript("tiriMath")
    }

    /// `\newcommand` lasts for the rest of its document, and not into the next one.
    func markup(tex: String, display: Bool, document: UUID) -> String? {
        queue.sync {
            load()
            if currentDocument != document {
                currentDocument = document
                context?.evaluateScript("tiriResetMath()")
            }
            guard let value = render?.call(withArguments: [tex, display]), value.isString else { return nil }
            return value.toString()
        }
    }

    /// KaTeX's styles, with its fonts pointing into the app.
    static let stylesheet: String = {
        guard let css = WebLibrary.text("katex/katex.min.css"), let fonts = WebLibrary.url("katex/fonts") else { return "" }
        let base = LocalFileSchemeHandler.baseURL(forDirectory: fonts.path).absoluteString
        return css.replacingOccurrences(of: "url(fonts/", with: "url(\(base)")
    }()
}

/// Mermaid needs a page to measure text in, so it's drawn in the web view, in a world of its own
/// that works with the page's own scripts turned off. It's only loaded when a page still has a
/// diagram to draw, because it's 3.5 MB.
enum DiagramDrawing {
    static let world = WKContentWorld.world(name: "tiri-diagrams")

    /// Marks anything still waiting as not drawn, so its source shows.
    static let giveUp = """
    for (const figure of document.querySelectorAll('figure.mermaid.pending')) {
      figure.classList.replace('pending', 'broken');
      const note = document.createElement('figcaption');
      note.textContent = "Can't draw this diagram.";
      figure.append(note);
    }
    """

    static let draw = """
    const slices = dark ? ['#5aa5ff', '#c791eb', '#73d48f', '#e6bf7a', '#ed9e78', '#6bd1d1', '#a1a1a6', '#f28ba8']
                        : ['#2f7fe0', '#8733ad', '#1f9e47', '#c48a0a', '#c8561a', '#0a8a93', '#6e6e73', '#c93a66'];
    const themeVariables = {};
    slices.forEach((color, index) => { themeVariables['pie' + (index + 1)] = color; });
    themeVariables.pieSectionTextColor = '#ffffff';
    themeVariables.pieStrokeColor = 'transparent';
    themeVariables.pieOuterStrokeColor = 'transparent';
    mermaid.initialize({
      startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true, theme: dark ? 'dark' : 'neutral', themeVariables,
      fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif', fontSize: 14
    });
    const results = [];
    for (const figure of document.querySelectorAll('figure.mermaid.pending')) {
      const key = figure.dataset.key;
      const id = 'tiri-diagram-' + key;
      try {
        const { svg } = await mermaid.render(id, figure.dataset.diagram);
        figure.innerHTML = svg;
        figure.classList.remove('pending');
        results.push({ key: key, svg: figure.innerHTML });
      } catch (error) {
        for (const stray of document.querySelectorAll('#' + id + ', #d' + id)) stray.remove();
        const detail = String(error && error.message || error).split('\\n')[0].replace(/[:.\\s]+$/, '');
        const reason = "Can't draw this diagram: " + detail + '.';
        figure.classList.replace('pending', 'broken');
        const note = document.createElement('figcaption');
        note.textContent = reason;
        figure.append(note);
        results.push({ key: key, reason: reason });
      }
    }
    return results;
    """
}
