import Foundation

/// A Jupyter notebook, read-only. nbformat 4 and later: older files have a different shape.
public struct Notebook: Sendable, Equatable {
    public enum CellKind: Sendable, Equatable { case markdown, code, raw }

    public enum Output: Sendable, Equatable {
        case stream(name: String, text: String)
        case error(name: String, message: String, traceback: [String])
        /// MIME type to content, with images still in base64.
        case display(data: [String: String], width: Int?, height: Int?)
    }

    public struct Cell: Sendable, Equatable {
        public var kind: CellKind
        public var source: String
        public var executionCount: Int?
        public var outputs: [Output]
        /// `attachment:name` in a markdown cell, as a data URL.
        public var attachments: [String: String]
    }

    public var cells: [Cell]
    public var language: String?

    /// Why a file can't be shown as a notebook. Each says so in words, and the source shows instead.
    public enum Failure: Error, Equatable {
        case notJSON(line: Int?)
        case notANotebook
        case oldFormat(Int)
        case tooLarge(bytes: Int)

        public var message: String {
            switch self {
            case .notJSON(let line):
                let place = line.map { " Line \($0) is where it goes wrong." } ?? ""
                return "This notebook isn't valid JSON, so here's its source.\(place)"
            case .notANotebook:
                return "This file doesn't have notebook cells in it, so here's its source."
            case .oldFormat(let version):
                return "This is an nbformat \(version) notebook, which Tiri can't render, so here's its source."
            case .tooLarge(let bytes):
                return "This notebook is too large to render (\(NotebookRenderer.size(bytes))), so here's its source."
            }
        }
    }

    /// Beyond this, even off the main thread, a notebook isn't worth the memory it would take.
    public static let maximumBytes = 512 * 1024 * 1024

    public static func parse(_ data: Data) throws(Failure) -> Notebook {
        if data.count > maximumBytes { throw .tooLarge(bytes: data.count) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Python's json module writes NaN and Infinity, which only JSON5 allows.
            guard let lenient = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) else {
                throw .notJSON(line: errorLine(error))
            }
            object = lenient
        }
        guard let root = object as? [String: Any] else { throw .notANotebook }
        let major = (root["nbformat"] as? NSNumber)?.intValue
        if let major, major < 4 { throw .oldFormat(major) }
        if root["worksheets"] != nil, root["cells"] == nil { throw .oldFormat(major ?? 3) }
        guard let cells = root["cells"] as? [Any] else { throw .notANotebook }
        let metadata = root["metadata"] as? [String: Any]
        let language = (metadata?["language_info"] as? [String: Any])?["name"] as? String
            ?? (metadata?["kernelspec"] as? [String: Any])?["language"] as? String
        return Notebook(cells: cells.compactMap { ($0 as? [String: Any]).map(cell) }, language: language)
    }

    private static func errorLine(_ error: Error) -> Int? {
        let text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
        return (text.firstMatch(of: /line (\d+)/)?.1).flatMap { Int($0) }
    }

    /// Notebook text is a string, or a list of strings to join.
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let parts = value as? [Any] { return parts.compactMap { $0 as? String }.joined() }
        return ""
    }

    private static func cell(_ raw: [String: Any]) -> Cell {
        let kind: CellKind
        switch raw["cell_type"] as? String {
        case "markdown": kind = .markdown
        case "code": kind = .code
        default: kind = .raw
        }
        var attachments: [String: String] = [:]
        for (name, value) in raw["attachments"] as? [String: Any] ?? [:] {
            guard let versions = value as? [String: Any] else { continue }
            for (type, content) in versions where type.hasPrefix("image/") {
                attachments[name] = "data:\(type);base64,\(text(content).filter { !$0.isWhitespace })"
            }
        }
        return Cell(kind: kind, source: text(raw["source"]), executionCount: (raw["execution_count"] as? NSNumber)?.intValue,
                    outputs: (raw["outputs"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(output) },
                    attachments: attachments)
    }

    private static func output(_ raw: [String: Any]) -> Output? {
        switch raw["output_type"] as? String {
        case "stream":
            return .stream(name: raw["name"] as? String ?? "stdout", text: text(raw["text"]))
        case "error":
            return .error(name: raw["ename"] as? String ?? "Error", message: raw["evalue"] as? String ?? "",
                          traceback: (raw["traceback"] as? [Any] ?? []).compactMap { $0 as? String })
        case "display_data", "execute_result", "update_display_data":
            var data: [String: String] = [:]
            for (type, value) in raw["data"] as? [String: Any] ?? [:] {
                if let content = value as? String {
                    data[type] = content
                } else if let lines = value as? [Any], lines.allSatisfy({ $0 is String }) {
                    data[type] = text(lines)
                } else if !type.contains("json") {
                    continue
                } else {
                    data[type] = ""
                }
            }
            // Sizes are per type, and retina images are drawn at half their pixels.
            let metadata = raw["metadata"] as? [String: Any] ?? [:]
            var width: Int?
            var height: Int?
            for type in ["image/png", "image/jpeg", "image/svg+xml"] {
                guard data[type] != nil, let size = metadata[type] as? [String: Any] else { continue }
                width = (size["width"] as? NSNumber)?.intValue
                height = (size["height"] as? NSNumber)?.intValue
            }
            return .display(data: data, width: width, height: height)
        default:
            return nil
        }
    }
}

/// Terminal output as HTML: colors mapped, other control sequences dropped.
public enum TerminalText {
    /// What a terminal would be left showing: `\r` rewrites its line, as progress bars do.
    public static func settled(_ text: String) -> String {
        guard text.utf8.contains(13) || text.utf8.contains(8) else { return text }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n").map { line -> String in
            var kept = line
            if let last = line.range(of: "\r", options: .backwards) { kept = String(line[last.upperBound...]) }
            guard kept.contains("\u{8}") else { return kept }
            var characters: [Character] = []
            for character in kept {
                if character == "\u{8}" { _ = characters.popLast() } else { characters.append(character) }
            }
            return String(characters)
        }.joined(separator: "\n")
    }

    public static func html(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return MarkdownRenderer.escapeText(text) }
        var result = ""
        walk(text) { piece, style in
            let escaped = MarkdownRenderer.escapeText(piece)
            result += style.isPlain ? escaped : "<span\(style.attributes)>\(escaped)</span>"
        }
        return result
    }

    private struct Style {
        var bold = false
        var classes: [String] = []
        var inline: [String] = []

        var isPlain: Bool { !bold && classes.isEmpty && inline.isEmpty }

        var attributes: String {
            var names = classes
            if bold { names.append("ansi-bold") }
            var result = names.isEmpty ? "" : " class=\"\(names.joined(separator: " "))\""
            if !inline.isEmpty { result += " style=\"\(inline.joined(separator: ";"))\"" }
            return result
        }

        mutating func clearColor(prefix: String, property: String) {
            classes.removeAll { $0.hasPrefix(prefix) }
            inline.removeAll { $0.hasPrefix(property + ":") }
        }

        mutating func apply(_ codes: [Int]) {
            var index = 0
            while index < codes.count {
                let code = codes[index]
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 22: bold = false
                case 30...37, 90...97:
                    clearColor(prefix: "ansi-fg", property: "color")
                    classes.append("ansi-fg\(code)")
                case 39: clearColor(prefix: "ansi-fg", property: "color")
                case 40...47, 100...107:
                    clearColor(prefix: "ansi-bg", property: "background")
                    classes.append("ansi-bg\(code)")
                case 49: clearColor(prefix: "ansi-bg", property: "background")
                case 38, 48:
                    let isForeground = code == 38
                    let property = isForeground ? "color" : "background"
                    var color: (Int, Int, Int)?
                    if index + 2 < codes.count, codes[index + 1] == 5 {
                        color = Self.color256(codes[index + 2])
                        index += 2
                    } else if index + 4 < codes.count, codes[index + 1] == 2 {
                        let part = codes[(index + 2)...(index + 4)].map { min(max($0, 0), 255) }
                        color = (part[0], part[1], part[2])
                        index += 4
                    }
                    if let color {
                        clearColor(prefix: isForeground ? "ansi-fg" : "ansi-bg", property: property)
                        inline.append("\(property):\(isForeground ? Self.readable(color) : Self.css(color))")
                    }
                default: break
                }
                index += 1
            }
        }

        /// The standard palette: 16 named colors, a 6×6×6 cube, then grays.
        private static func color256(_ code: Int) -> (Int, Int, Int) {
            let named = [(0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39), (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
                         (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35), (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235)]
            if code >= 0, code < 16 { return named[code] }
            if code >= 16, code < 232 {
                let value = code - 16
                let level = { (step: Int) in step == 0 ? 0 : 55 + step * 40 }
                return (level(value / 36), level(value / 6 % 6), level(value % 6))
            }
            let gray = 8 + 10 * (min(max(code, 232), 255) - 232)
            return (gray, gray, gray)
        }

        private static func css(_ color: (Int, Int, Int)) -> String {
            "rgb(\(color.0),\(color.1),\(color.2))"
        }

        /// Programs pick these colors for one background. IPython's dark blue can't be read on a
        /// dark one, nor bright yellow on white, so each theme gets a version it can show.
        private static func readable(_ color: (Int, Int, Int)) -> String {
            let brightness = (0.299 * Double(color.0) + 0.587 * Double(color.1) + 0.114 * Double(color.2)) / 255
            func mix(_ value: Int, toward target: Double, by amount: Double) -> Int {
                Int((Double(value) + (target - Double(value)) * amount).rounded())
            }
            var dark = color
            if brightness < 0.55 {
                let amount = (0.55 - brightness) / (1 - brightness)
                dark = (mix(color.0, toward: 255, by: amount), mix(color.1, toward: 255, by: amount), mix(color.2, toward: 255, by: amount))
            }
            var light = color
            if brightness > 0.5 {
                let amount = (brightness - 0.5) / brightness
                light = (mix(color.0, toward: 0, by: amount), mix(color.1, toward: 0, by: amount), mix(color.2, toward: 0, by: amount))
            }
            return "light-dark(\(css(light)),\(css(dark)))"
        }
    }

    private static func walk(_ text: String, _ emit: (String, Style) -> Void) {
        var style = Style()
        var plain = [UInt8]()
        func flush() {
            if !plain.isEmpty { emit(String(decoding: plain, as: UTF8.self), style) }
            plain.removeAll(keepingCapacity: true)
        }
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x1B else {
                plain.append(byte)
                index += 1
                continue
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if next == UInt8(ascii: "[") {
                var end = index + 2
                while end < bytes.count, !(bytes[end] >= 0x40 && bytes[end] <= 0x7E) { end += 1 }
                if end < bytes.count, bytes[end] == UInt8(ascii: "m") {
                    flush()
                    let parameters = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
                    style.apply(parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 })
                }
                index = end + 1
            } else if next == UInt8(ascii: "]") {
                // A title or a link: up to its terminator, which is BEL or ESC \.
                var end = index + 2
                while end < bytes.count, bytes[end] != 7, !(bytes[end] == 0x1B && end + 1 < bytes.count && bytes[end + 1] == UInt8(ascii: "\\")) {
                    end += 1
                }
                index = end < bytes.count && bytes[end] == 7 ? end + 1 : end + 2
            } else {
                index += 2
            }
        }
        flush()
    }
}

/// A notebook as one HTML page, in the same document style as markdown.
public enum NotebookRenderer {
    public struct Limits: Sendable {
        /// One run of text output. Both ends are kept: a long log's end is usually what matters.
        public var text = 200_000
        public var html = 4 * 1024 * 1024
        public var image = 24 * 1024 * 1024
        /// All outputs together. A page much larger than this is slow to scroll.
        public var page = 128 * 1024 * 1024
        public init() {}
    }

    public static func size(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1 { return "\(Int(megabytes.rounded())) MB" }
        return "\(max(bytes / 1024, 1)) KB"
    }

    public static func render(_ notebook: Notebook, baseHref: String?, title: String = "", extras: DocumentExtras = DocumentExtras(),
                              highlight: (@Sendable (_ code: String, _ language: String) -> String?)? = nil, limits: Limits = Limits()) -> RenderedDocument {
        var fragments = MarkdownRenderer.Fragments(extras: extras)
        var budget = limits.page
        var main = ""
        for (index, cell) in notebook.cells.enumerated() {
            let isEmpty = cell.source.allSatisfy(\.isWhitespace) && cell.outputs.isEmpty
            if isEmpty { continue }
            // These go on cells, not lines: a selection names the cell it came from.
            let line = "data-line=\"\(index)\" data-line-end=\"\(index)\""
            switch cell.kind {
            case .markdown:
                let html = fragments.html(markdown: withAttachments(cell), lineOffset: nil)
                main += "<section class=\"nb-cell\" \(line)><div class=\"nb-prompt\"></div><div class=\"nb-body nb-markdown\">\(html)</div></section>\n"
            case .raw:
                main += "<section class=\"nb-cell\" \(line)><div class=\"nb-prompt\"></div><div class=\"nb-body\"><pre class=\"nb-raw\"><code>\(MarkdownRenderer.escapeText(cell.source))</code></pre></div></section>\n"
            case .code:
                let count = cell.executionCount.map(String.init) ?? " "
                // Nearly every notebook without a language in it is Python.
                let highlighted = highlight?(cell.source, notebook.language ?? "python")
                let code = highlighted ?? MarkdownRenderer.escapeText(cell.source)
                var body = "<pre class=\"nb-input\"><code>\(code)</code></pre>"
                let outputs = self.outputs(cell.outputs, fragments: &fragments, budget: &budget, limits: limits)
                if !outputs.isEmpty { body += "<div class=\"nb-outputs\">\(outputs)</div>" }
                main += "<section class=\"nb-cell\" \(line)><div class=\"nb-prompt\">[\(count)]</div><div class=\"nb-body\">\(body)</div></section>\n"
            }
        }
        if main.isEmpty { main = "<p class=\"nb-note\">This notebook has no cells.</p>" }
        let styles = MarkdownRenderer.stylesheet + notebookStyles + fragments.extraStyles()
        return RenderedDocument(html: MarkdownRenderer.wrap(main: main, baseHref: baseHref, title: title, stylesheet: styles),
                                hasDiagrams: fragments.hasDiagrams, hasPendingDiagrams: fragments.hasPendingDiagrams)
    }

    private static func withAttachments(_ cell: Notebook.Cell) -> String {
        var source = cell.source
        for (name, url) in cell.attachments {
            source = source.replacingOccurrences(of: "attachment:\(name)", with: url)
        }
        return source
    }

    private static func note(_ text: String) -> String {
        "<p class=\"nb-note\">\(MarkdownRenderer.escapeText(text))</p>"
    }

    private static func outputs(_ outputs: [Notebook.Output], fragments: inout MarkdownRenderer.Fragments, budget: inout Int, limits: Limits) -> String {
        var html = ""
        var index = 0
        var hidden = 0
        while index < outputs.count {
            let output = outputs[index]
            index += 1
            guard budget > 0 else {
                hidden += 1
                continue
            }
            switch output {
            case .stream(let name, var text):
                // Kernels split a stream into many pieces, and `\r` can reach across them.
                while index < outputs.count, case .stream(name, let more) = outputs[index] {
                    text += more
                    index += 1
                }
                let piece = terminal(text, limit: limits.text)
                budget -= piece.utf8.count
                html += "<pre class=\"nb-stream\(name == "stderr" ? " nb-stderr" : "")\"><code>\(piece)</code></pre>"
            case .error(let name, let message, let traceback):
                let text = traceback.isEmpty ? "\(name): \(message)" : traceback.joined(separator: "\n")
                let piece = terminal(text, limit: limits.text)
                budget -= piece.utf8.count
                html += "<pre class=\"nb-error\"><code>\(piece)</code></pre>"
            case .display(let data, let width, let height):
                let piece = display(data, width: width, height: height, fragments: &fragments, limits: limits)
                budget -= piece.utf8.count
                html += piece
            }
        }
        if hidden > 0 {
            html += note("\(hidden) more \(hidden == 1 ? "output" : "outputs") not shown. This notebook's outputs are too large for one page.")
        }
        return html
    }

    private static func terminal(_ raw: String, limit: Int) -> String {
        let settled = TerminalText.settled(raw)
        let length = settled.utf8.count
        guard length > limit else { return TerminalText.html(settled) }
        var head = settled.utf8.prefix(limit * 3 / 4)
        var tail = settled.utf8.suffix(limit / 4)
        // On whole lines, where there are any.
        if let end = head.lastIndex(of: 10) { head = head[..<end] }
        if let start = tail.firstIndex(of: 10) { tail = tail[tail.index(after: start)...] }
        let cut = "\n\n… \(size(length - head.count - tail.count)) of output not shown.\n\n"
        return TerminalText.html(String(decoding: head, as: UTF8.self))
            + "<span class=\"nb-cut\">\(MarkdownRenderer.escapeText(cut))</span>"
            + TerminalText.html(String(decoding: tail, as: UTF8.self))
    }

    private static func display(_ data: [String: String], width: Int?, height: Int?, fragments: inout MarkdownRenderer.Fragments, limits: Limits) -> String {
        // The richest thing that can be shown. HTML that needs scripts can't be, so a picture
        // beside it wins.
        let html = data["text/html"]
        let needsScripts = html.map(hasScript) ?? false
        if let html, !needsScripts { return htmlOutput(html, limits: limits) }
        for type in ["image/svg+xml", "image/png", "image/jpeg"] {
            if let content = data[type] { return image(type, content, width: width, height: height, limits: limits) }
        }
        if let html {
            return htmlOutput(html, limits: limits) + note("This output needs scripts, which don't run here.")
        }
        if let markdown = data["text/markdown"] {
            return "<div class=\"nb-markdown\">\(fragments.html(markdown: markdown, lineOffset: nil))</div>"
        }
        if let latex = data["text/latex"] {
            if let rendered = math(latex, fragments: &fragments) { return rendered }
            if data["text/plain"] == nil { return "<pre class=\"nb-stream\"><code>\(MarkdownRenderer.escapeText(latex))</code></pre>" }
        }
        if let plain = data["text/plain"] {
            return "<pre class=\"nb-stream\"><code>\(terminal(plain, limit: limits.text))</code></pre>"
        }
        guard let type = data.keys.sorted().first else { return "" }
        return note("Output of type \(type) isn't shown here.")
    }

    /// `text/latex` is one formula, usually with its delimiters.
    private static func math(_ latex: String, fragments: inout MarkdownRenderer.Fragments) -> String? {
        var tex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = tex
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] where tex.hasPrefix(open) && tex.hasSuffix(close) && tex.count >= open.count + close.count {
            tex = String(tex.dropFirst(open.count).dropLast(close.count))
            break
        }
        guard fragments.extras.renderMath?(tex, true) != nil else { return nil }
        return "<div class=\"nb-math\">\(fragments.renderedMath(MathText.Span(token: "", tex: tex, display: true, original: original, endLine: nil)))</div>"
    }

    private static func hasScript(_ html: String) -> Bool {
        html.range(of: "<script", options: .caseInsensitive) != nil || html.range(of: "<iframe", options: .caseInsensitive) != nil
    }

    /// Scripts and frames can't run in this page, so they only take up room: Plotly embeds megabytes.
    static func withoutScripts(_ html: String) -> String {
        guard hasScript(html) else { return html }
        return html.replacing(/(?i)<script\b.*?<\/script\s*>/.dotMatchesNewlines(), with: "")
            .replacing(/(?i)<iframe\b.*?<\/iframe\s*>/.dotMatchesNewlines(), with: "")
    }

    /// In a shadow root, so a notebook's styles apply to that output and not to this page. Nothing
    /// in it can run: the page has scripts off and allows no loads but images.
    private static func htmlOutput(_ raw: String, limits: Limits) -> String {
        let html = withoutScripts(raw)
        guard html.utf8.count <= limits.html else {
            return note("HTML output not shown: it's \(size(html.utf8.count)).")
        }
        // Only this page's own template may close it, or the output could spill out of its root.
        let contained = html.replacing(/(?i)<(\/?template)/, with: { "&lt;\($0.1)" })
        return "<div class=\"nb-html\"><template shadowrootmode=\"open\"><style>\(htmlOutputStyles)</style>\(contained)</template></div>"
    }

    private static func image(_ type: String, _ content: String, width: Int?, height: Int?, limits: Limits) -> String {
        guard content.utf8.count <= limits.image else {
            return note("Image not shown: it's \(size(content.utf8.count * 3 / 4)).")
        }
        let base64: String
        if type == "image/svg+xml" {
            // As an image, so nothing in it runs, and its styles stay in it.
            base64 = Data(content.utf8).base64EncodedString()
        } else {
            base64 = String(decoding: content.utf8.filter { $0 != 10 && $0 != 13 && $0 != 32 }, as: UTF8.self)
        }
        guard base64.utf8.allSatisfy({ isBase64($0) }) else { return note("This image can't be read.") }
        var size = ""
        if let width { size += " width=\"\(width)\"" }
        if let height, width == nil { size += " height=\"\(height)\"" }
        return "<img class=\"nb-image\"\(size) src=\"data:\(type);base64,\(base64)\" alt=\"\">"
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "=")
    }

    static let htmlOutputStyles = """
    :host { display:block; overflow-x:auto; }
    table { border-collapse:collapse; font-size:.9em; margin:.2em 0; }
    th,td { border:1px solid var(--line); padding:4px 9px; text-align:right; vertical-align:top; }
    thead th { background:var(--code); font-weight:600; }
    tbody tr:nth-child(even) { background:color-mix(in srgb, var(--code) 50%, transparent); }
    img { max-width:100%; height:auto; }
    """

    static let notebookStyles = """
    :root { --c-comment:#6e6e73; --c-function:#1a57bf; --c-type:#07707a; --c-attr:#a6450f; --c-string:#177a33; --c-number:#996600; --c-keyword:#8733ad; --err:#fbeeee; --warn:#fbf6e9; }
    @media (prefers-color-scheme: dark) { :root { --c-comment:#a1a1a6; --c-function:#82b5fa; --c-type:#6bd1d1; --c-attr:#ed9e78; --c-string:#73d48f; --c-number:#e6bf7a; --c-keyword:#c791eb; --err:#3a2526; --warn:#35301f; } }
    main { max-width:1000px; padding:20px 28px 80px 12px; }
    .nb-cell { display:grid; grid-template-columns:44px minmax(0,1fr); column-gap:8px; margin:0 0 14px; }
    .nb-prompt { font:12px/1.5 ui-monospace,"SF Mono",Menlo,monospace; color:var(--muted); text-align:right; padding-top:11px; white-space:nowrap; user-select:none; -webkit-user-select:none; }
    .nb-body { min-width:0; }
    .nb-markdown > :first-child { margin-top:0; } .nb-markdown > :last-child { margin-bottom:0; }
    pre.nb-input, pre.nb-raw { margin:0; }
    pre.nb-raw { color:var(--muted); }
    .nb-outputs { margin-top:6px; }
    .nb-outputs > * { margin:0 0 6px; }
    .nb-outputs > :last-child { margin-bottom:0; }
    pre.nb-stream, pre.nb-error { background:none; padding:2px 14px; border-radius:6px; white-space:pre-wrap; overflow-wrap:anywhere; }
    pre.nb-stderr { background:var(--warn); padding:6px 14px; }
    pre.nb-error { background:var(--err); padding:8px 14px; }
    .nb-cut { color:var(--muted); font-style:italic; }
    .nb-note { color:var(--muted); font-size:.85em; padding:0 14px; }
    .nb-html, .nb-math, .nb-outputs .nb-markdown { padding:0 14px; }
    img.nb-image { display:block; max-width:calc(100% - 28px); height:auto; margin-left:14px; border-radius:4px; }
    @media (prefers-color-scheme: dark) { img.nb-image, .nb-markdown img { background:#f2f2f2; border-radius:4px; } }
    @media (max-width: 560px) {
      .nb-cell { display:block; }
      .nb-prompt { text-align:left; padding:0 0 2px; }
      .nb-prompt:empty { display:none; }
    }
    .hljs-comment,.hljs-quote,.hljs-doctag { color:var(--c-comment); }
    .hljs-string,.hljs-regexp,.hljs-addition,.hljs-symbol,.hljs-bullet,.hljs-code { color:var(--c-string); }
    .hljs-number,.hljs-literal { color:var(--c-number); }
    .hljs-keyword,.hljs-selector-tag { color:var(--c-keyword); }
    .hljs-title,.hljs-function,.hljs-section,.hljs-selector-id,.hljs-selector-class,.hljs-name { color:var(--c-function); }
    .hljs-title.class_,.hljs-type,.hljs-built_in,.hljs-class { color:var(--c-type); }
    .hljs-attr,.hljs-attribute,.hljs-property,.hljs-params,.hljs-variable,.hljs-template-variable,.hljs-meta,.hljs-tag { color:var(--c-attr); }
    .ansi-bold { font-weight:700; }
    .ansi-fg30 { color:#3b3b3f; } .ansi-fg31 { color:#c4281c; } .ansi-fg32 { color:#177a33; } .ansi-fg33 { color:#996600; } .ansi-fg34 { color:#1a57bf; } .ansi-fg35 { color:#8733ad; } .ansi-fg36 { color:#07707a; } .ansi-fg37 { color:#6e6e73; }
    .ansi-fg90 { color:#6e6e73; } .ansi-fg91 { color:#e0392a; } .ansi-fg92 { color:#1f9e47; } .ansi-fg93 { color:#b58a00; } .ansi-fg94 { color:#2f7fe0; } .ansi-fg95 { color:#a64fd1; } .ansi-fg96 { color:#0a8a93; } .ansi-fg97 { color:#1d1d1f; }
    .ansi-bg40 { background:#3b3b3f; color:#fff; } .ansi-bg41 { background:#f6c9c5; } .ansi-bg42 { background:#c6ecd1; } .ansi-bg43 { background:#f3e3b3; } .ansi-bg44 { background:#c9dcf8; } .ansi-bg45 { background:#e6d0f2; } .ansi-bg46 { background:#bfe8ea; } .ansi-bg47 { background:#ececef; }
    .ansi-bg100 { background:#c9c9ce; } .ansi-bg101 { background:#f6c9c5; } .ansi-bg102 { background:#c6ecd1; } .ansi-bg103 { background:#f3e3b3; } .ansi-bg104 { background:#c9dcf8; } .ansi-bg105 { background:#e6d0f2; } .ansi-bg106 { background:#bfe8ea; } .ansi-bg107 { background:#f6f6f8; }
    @media (prefers-color-scheme: dark) {
      .ansi-fg30 { color:#8e8e93; } .ansi-fg31 { color:#ff7b72; } .ansi-fg32 { color:#73d48f; } .ansi-fg33 { color:#e6bf7a; } .ansi-fg34 { color:#82b5fa; } .ansi-fg35 { color:#c791eb; } .ansi-fg36 { color:#6bd1d1; } .ansi-fg37 { color:#d1d1d6; }
      .ansi-fg90 { color:#8e8e93; } .ansi-fg91 { color:#ff9a92; } .ansi-fg92 { color:#94e3ab; } .ansi-fg93 { color:#f2d38f; } .ansi-fg94 { color:#a6ccff; } .ansi-fg95 { color:#ddb0f5; } .ansi-fg96 { color:#8fe3e3; } .ansi-fg97 { color:#f2f2f7; }
      .ansi-bg40 { background:#000; } .ansi-bg41 { background:#5c2320; } .ansi-bg42 { background:#1e4a2c; } .ansi-bg43 { background:#4d3f18; } .ansi-bg44 { background:#1f3a66; } .ansi-bg45 { background:#46285a; } .ansi-bg46 { background:#154a4d; } .ansi-bg47 { background:#48484a; }
      .ansi-bg100 { background:#48484a; } .ansi-bg101 { background:#74302b; } .ansi-bg102 { background:#2a5e3b; } .ansi-bg103 { background:#5e4e20; } .ansi-bg104 { background:#2a4c82; } .ansi-bg105 { background:#5a3573; } .ansi-bg106 { background:#1d5f63; } .ansi-bg107 { background:#636366; }
    }

    """
}
