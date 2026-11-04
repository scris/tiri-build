import Foundation
import Markdown

/// What rich rendering needs from the app. Without it, math shows as its source.
public struct DocumentExtras: Sendable {
    /// Returns markup, or nil when the math doesn't parse.
    public var renderMath: (@Sendable (_ tex: String, _ display: Bool) -> String?)?
    /// Only asked for when a page has math.
    public var mathStylesheet: (@Sendable () -> String)?
    public init(renderMath: (@Sendable (String, Bool) -> String?)? = nil, mathStylesheet: (@Sendable () -> String)? = nil) {
        self.renderMath = renderMath
        self.mathStylesheet = mathStylesheet
    }
}

public struct RenderedDocument: Sendable {
    public var html: String
}

public enum MarkdownRenderer {
    /// A complete HTML page for a markdown document. Local files resolve through `baseHref`.
    public static func page(markdown source: String, baseHref: String?, title: String = "") -> String {
        render(markdown: source, baseHref: baseHref, title: title).html
    }

    public static func render(markdown source: String, baseHref: String?, title: String = "", extras: DocumentExtras = DocumentExtras()) -> RenderedDocument {
        let (frontMatter, body) = splitFrontMatter(source)
        var fragments = Fragments(extras: extras)
        // Each block says which source lines it came from, so a selection in the rendered page
        // can name them. `display: contents` keeps these wrappers out of the layout.
        let html = fragments.html(markdown: body, lineOffset: frontMatterLineCount(frontMatter))
        var main = ""
        if let frontMatter {
            main += "<pre class=\"front-matter\"><code>\(escapeText(frontMatter))</code></pre>\n"
        }
        main += html
        return RenderedDocument(html: wrap(main: main, baseHref: baseHref, title: title, stylesheet: stylesheet + fragments.extraStyles()))
    }

    static func wrap(main: String, baseHref: String?, title: String, stylesheet: String) -> String {
        // Documents can contain raw HTML. Nothing but local files and secure images gets to load.
        var head = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        if let baseHref {
            head += "<base href=\"\(escapeAttribute(baseHref))\">"
        }
        head += "<title>\(escapeText(title))</title><style>\(stylesheet)</style>"
        return "<!DOCTYPE html><html><head>\(head)</head><body><main>\(main)</main></body></html>"
    }

    /// Turns markdown into HTML, with its math, for a page or part of one.
    struct Fragments {
        let extras: DocumentExtras
        private(set) var usesMath = false

        init(extras: DocumentExtras) { self.extras = extras }

        /// With a `lineOffset`, each block records the source lines it came from.
        mutating func html(markdown: String, lineOffset: Int?) -> String {
            let math = MathText.extract(markdown)
            let tall = math.spans.filter { $0.endLine != nil }
            let document = Document(parsing: math.markdown)
            var html = document.children.map { block -> String in
                let inner = DocumentHTML.format(block)
                guard let lineOffset, let range = block.range else { return inner }
                var end = range.upperBound.line - 1
                // Math over several lines is one line to the parser.
                for span in tall where inner.contains(span.token) { end = max(end, span.endLine ?? end) }
                return "<div class=\"src\" data-line=\"\(range.lowerBound.line - 1 + lineOffset)\" data-line-end=\"\(end + lineOffset)\">\(inner)</div>\n"
            }.joined()
            html = addHeadingAnchors(html, math: math.spans)
            html = convertTaskLists(html)
            return MathText.restore(html, spans: math.spans) { span in renderedMath(span) }
        }

        mutating func renderedMath(_ span: MathText.Span) -> String {
            let source = escapeAttribute(span.original)
            if let markup = extras.renderMath?(span.tex, span.display) {
                usesMath = true
                return "<span class=\"math\(span.display ? " math-display" : "")\" data-tex=\"\(source)\">\(markup)</span>"
            }
            return "<code class=\"math-failed\">\(escapeText(span.original))</code>"
        }

        /// Styles only the page in question needs.
        func extraStyles() -> String {
            var styles = ""
            if usesMath { styles += mathStyles + (extras.mathStylesheet?() ?? "") }
            return styles
        }
    }

    static let mathStyles = """
    .math-display { display:block; margin:1em 0; overflow-x:auto; overflow-y:hidden; }
    .math-display .katex-display { margin:0; }
    code.math-failed { white-space:pre-wrap; color:var(--muted); }

    """

    static let contentSecurityPolicy = "default-src 'none'; img-src tiri-file: data: https:; media-src tiri-file:; style-src 'unsafe-inline'; font-src tiri-file: data:"

    private static func frontMatterLineCount(_ frontMatter: String?) -> Int {
        frontMatter.map { $0.components(separatedBy: "\n").count + 2 } ?? 0
    }

    /// Narrows a selection in the rendered page from the blocks it touched to the source lines it
    /// really covers, as far as the text can be found there. Lines count from zero.
    public static func sourceLines(blockStart: Int, blockEnd: Int, selected: String, source: String) -> (first: Int, last: Int) {
        let lines = source.components(separatedBy: "\n")
        guard blockStart >= 0, blockEnd >= blockStart, blockStart < lines.count else { return (blockStart, blockEnd) }
        let end = min(blockEnd, lines.count - 1)
        func plain(_ text: String) -> String {
            text.lowercased().filter { !"*_`~[]()#>|-".contains($0) && !$0.isWhitespace }
        }
        let pieces = selected.components(separatedBy: .newlines).map(plain).filter { !$0.isEmpty }
        guard let firstPiece = pieces.first, let lastPiece = pieces.last else { return (blockStart, end) }
        let searchable = lines[blockStart...end].map(plain)
        func locate(_ piece: String, fromEnd: Bool) -> Int? {
            // Long enough to be sure, short enough to survive wrapping and links.
            let probe = String(piece.prefix(24))
            let indices = fromEnd ? Array(searchable.indices.reversed()) : Array(searchable.indices)
            return indices.first { searchable[$0].contains(probe) }.map { $0 - searchable.startIndex + blockStart }
        }
        let first = locate(firstPiece, fromEnd: false) ?? blockStart
        let last = locate(lastPiece, fromEnd: true) ?? end
        return first <= last ? (first, last) : (blockStart, end)
    }

    /// The anchor of the section containing a source line, so `report.md:40` can land in the
    /// right place in the rendered view. nil when the line comes before any heading.
    public static func anchor(forLine line: Int, in source: String) -> String? {
        let (frontMatter, body) = splitFrontMatter(source)
        let offset = frontMatter.map { $0.components(separatedBy: "\n").count + 2 } ?? 0
        let math = MathText.extract(body)
        let document = Document(parsing: math.markdown)
        var seen: [String: Int] = [:]
        var best: String?
        for child in document.children {
            guard let heading = child as? Heading, let range = heading.range else { continue }
            var slug = slugify(MathText.sourceText(heading.plainText, spans: math.spans))
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            if count > 0 { slug += "-\(count)" }
            if range.lowerBound.line + offset <= line { best = slug } else { break }
        }
        return best
    }

    static func slugify(_ text: String) -> String {
        String(text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            if character == " " { return "-" }
            return nil
        })
    }

    /// YAML front matter is metadata, not content, so it shouldn't render as a heading and a rule.
    static func splitFrontMatter(_ source: String) -> (String?, String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return (nil, source) }
        let lines = source.components(separatedBy: "\n")
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                let front = lines[1..<index].joined(separator: "\n")
                let rest = lines[(index + 1)...].joined(separator: "\n")
                return (front, rest)
            }
        }
        return (nil, source)
    }

    static func addHeadingAnchors(_ html: String, math: [MathText.Span] = []) -> String {
        var seen: [String: Int] = [:]
        let pattern = /<h([1-6])>(.*?)<\/h\1>/.dotMatchesNewlines()
        return html.replacing(pattern) { match in
            let inner = String(match.2)
            let plain = MathText.sourceText(inner.replacing(/<[^>]+>/, with: ""), spans: math)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            var slug = slugify(plain)
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            if count > 0 { slug += "-\(count)" }
            return "<h\(match.1) id=\"\(slug)\">\(inner)</h\(match.1)>"
        }
    }

    /// swift-markdown already emits checkboxes. This marks those items so they can drop the bullet.
    static func convertTaskLists(_ html: String) -> String {
        html.replacingOccurrences(of: "<li><input type=\"checkbox\"", with: "<li class=\"task\"><input type=\"checkbox\"")
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// swift-markdown's own formatter copies text and code as they are, so `Array<Int>` in a code
    /// block loses `<Int>` to the HTML parser. This one escapes them, and keeps inline formatting
    /// in headings and alt text on images.
    private struct DocumentHTML: MarkupWalker {
        var result = ""
        private var inTableHead = false
        private var alignments: [Table.ColumnAlignment?] = []
        private var column = 0

        static func format(_ markup: Markup) -> String {
            var walker = DocumentHTML()
            walker.visit(markup)
            return walker.result
        }

        private mutating func wrap(_ tag: String, _ content: Markup, newline: Bool = false) {
            result += "<\(tag)>"
            descendInto(content)
            result += "</\(tag)>" + (newline ? "\n" : "")
        }

        mutating func visitBlockQuote(_ node: BlockQuote) {
            result += "<blockquote>\n"
            descendInto(node)
            result += "</blockquote>\n"
        }

        mutating func visitCodeBlock(_ node: CodeBlock) {
            let language = node.language.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
            result += "<pre><code\(language)>\(escapeText(node.code))</code></pre>\n"
        }

        mutating func visitHeading(_ node: Heading) { wrap("h\(node.level)", node, newline: true) }
        mutating func visitThematicBreak(_ node: ThematicBreak) { result += "<hr />\n" }
        mutating func visitHTMLBlock(_ node: HTMLBlock) { result += node.rawHTML }

        mutating func visitListItem(_ node: ListItem) {
            result += "<li>"
            if let checkbox = node.checkbox {
                result += "<input type=\"checkbox\" disabled=\"\"\(checkbox == .checked ? " checked=\"\"" : "") /> "
            }
            descendInto(node)
            result += "</li>\n"
        }

        mutating func visitOrderedList(_ node: OrderedList) {
            result += node.startIndex == 1 ? "<ol>\n" : "<ol start=\"\(node.startIndex)\">\n"
            descendInto(node)
            result += "</ol>\n"
        }

        mutating func visitUnorderedList(_ node: UnorderedList) {
            result += "<ul>\n"
            descendInto(node)
            result += "</ul>\n"
        }

        mutating func visitParagraph(_ node: Paragraph) { wrap("p", node, newline: true) }

        mutating func visitTable(_ node: Table) {
            result += "<table>\n"
            alignments = node.columnAlignments
            descendInto(node)
            result += "</table>\n"
        }

        mutating func visitTableHead(_ node: Table.Head) {
            result += "<thead>\n<tr>\n"
            inTableHead = true
            column = 0
            descendInto(node)
            inTableHead = false
            result += "</tr>\n</thead>\n"
        }

        mutating func visitTableBody(_ node: Table.Body) {
            guard !node.isEmpty else { return }
            result += "<tbody>\n"
            descendInto(node)
            result += "</tbody>\n"
        }

        mutating func visitTableRow(_ node: Table.Row) {
            result += "<tr>\n"
            column = 0
            descendInto(node)
            result += "</tr>\n"
        }

        mutating func visitTableCell(_ node: Table.Cell) {
            guard node.colspan > 0, node.rowspan > 0 else {
                column += 1
                return
            }
            let tag = inTableHead ? "th" : "td"
            result += "<\(tag)"
            if column < alignments.count, let alignment = alignments[column] { result += " align=\"\(alignment)\"" }
            column += 1
            if node.rowspan > 1 { result += " rowspan=\"\(node.rowspan)\"" }
            if node.colspan > 1 { result += " colspan=\"\(node.colspan)\"" }
            result += ">"
            descendInto(node)
            result += "</\(tag)>\n"
        }

        mutating func visitInlineCode(_ node: InlineCode) { result += "<code>\(escapeText(node.code))</code>" }
        mutating func visitEmphasis(_ node: Emphasis) { wrap("em", node) }
        mutating func visitStrong(_ node: Strong) { wrap("strong", node) }
        mutating func visitStrikethrough(_ node: Strikethrough) { wrap("del", node) }

        mutating func visitImage(_ node: Image) {
            result += "<img"
            if let source = node.source, !source.isEmpty { result += " src=\"\(escapeAttribute(source))\"" }
            if !node.plainText.isEmpty { result += " alt=\"\(escapeAttribute(node.plainText))\"" }
            if let title = node.title, !title.isEmpty { result += " title=\"\(escapeAttribute(title))\"" }
            result += " />"
        }

        mutating func visitInlineHTML(_ node: InlineHTML) { result += node.rawHTML }
        mutating func visitLineBreak(_ node: LineBreak) { result += "<br />\n" }
        mutating func visitSoftBreak(_ node: SoftBreak) { result += "\n" }

        mutating func visitLink(_ node: Link) {
            result += "<a"
            if let destination = node.destination { result += " href=\"\(escapeAttribute(destination))\"" }
            result += ">"
            descendInto(node)
            result += "</a>"
        }

        mutating func visitText(_ node: Text) { result += escapeText(node.string) }
        mutating func visitSymbolLink(_ node: SymbolLink) { result += "<code>\(escapeText(node.destination ?? ""))</code>" }
    }

    static let stylesheet = """
    .src { display: contents; }
    :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --line:#d9d9de; --code:#f4f4f6; --link:#0a66d6; --bg:#ffffff; --quote:#55555a; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e8e8ed; --muted:#a1a1a6; --line:#3a3a3e; --code:#2a2a2d; --link:#5aa5ff; --bg:#1c1c1e; --quote:#b0b0b5; } }
    html { background: var(--bg); }
    body { margin:0; color:var(--fg); background:var(--bg); font:15px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; -webkit-font-smoothing:antialiased; }
    main { max-width: 820px; margin: 0 auto; padding: 28px 36px 80px; }
    h1,h2,h3,h4,h5,h6 { line-height:1.25; margin:1.6em 0 .6em; font-weight:650; }
    h1 { font-size:1.9em; padding-bottom:.25em; border-bottom:1px solid var(--line); }
    h2 { font-size:1.45em; padding-bottom:.2em; border-bottom:1px solid var(--line); }
    h3 { font-size:1.2em; } h4 { font-size:1.05em; } h5,h6 { font-size:.95em; color:var(--muted); }
    main > :first-child { margin-top:0; }
    p,ul,ol,pre,table,blockquote { margin:0 0 1em; }
    a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
    code { font:.88em ui-monospace, "SF Mono", Menlo, monospace; background:var(--code); padding:.15em .35em; border-radius:4px; }
    pre { background:var(--code); padding:12px 14px; border-radius:8px; overflow-x:auto; line-height:1.45; }
    pre code { background:none; padding:0; font-size:.86em; }
    pre.front-matter { color:var(--muted); }
    blockquote { padding:0 0 0 14px; border-left:3px solid var(--line); color:var(--quote); }
    table { border-collapse:collapse; display:block; overflow-x:auto; max-width:100%; }
    th,td { border:1px solid var(--line); padding:6px 11px; text-align:left; vertical-align:top; }
    th { background:var(--code); font-weight:600; }
    img,video { max-width:100%; height:auto; }
    hr { border:0; border-top:1px solid var(--line); margin:2em 0; }
    li { margin:.2em 0; } li.task { list-style:none; margin-left:-1.3em; } li > p { margin:0 0 .4em; } li.task > p { display:inline; }
    input[type=checkbox] { margin-right:.35em; }
    ::selection { background:rgba(0,122,255,.3); }
    """
}
