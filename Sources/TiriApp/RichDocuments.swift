import Foundation
import JavaScriptCore
import TiriCore

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
