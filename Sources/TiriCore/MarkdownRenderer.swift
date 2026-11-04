import Foundation
import Markdown

public enum MarkdownRenderer {
    /// A complete HTML page for a markdown document. Local files resolve through `baseHref`.
    public static func page(markdown source: String, baseHref: String?, title: String = "") -> String {
        let (frontMatter, body) = splitFrontMatter(source)
        let document = Document(parsing: body)
        // Each block says which source lines it came from, so a selection in the rendered page
        // can name them. `display: contents` keeps these wrappers out of the layout.
        let offset = frontMatterLineCount(frontMatter)
        var html = document.children.map { block -> String in
            let inner = HTMLFormatter.format(block)
            guard let range = block.range else { return inner }
            return "<div class=\"src\" data-line=\"\(range.lowerBound.line - 1 + offset)\" data-line-end=\"\(range.upperBound.line - 1 + offset)\">\(inner)</div>\n"
        }.joined()
        html = addHeadingAnchors(html)
        html = convertTaskLists(html)
        // Documents can contain raw HTML. Nothing but local files and secure images gets to load.
        var head = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        if let baseHref {
            head += "<base href=\"\(escapeAttribute(baseHref))\">"
        }
        head += "<title>\(escapeText(title))</title><style>\(stylesheet)</style>"
        var main = ""
        if let frontMatter {
            main += "<pre class=\"front-matter\"><code>\(escapeText(frontMatter))</code></pre>\n"
        }
        main += html
        return "<!DOCTYPE html><html><head>\(head)</head><body><main>\(main)</main></body></html>"
    }

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
        let document = Document(parsing: body)
        var seen: [String: Int] = [:]
        var best: String?
        for child in document.children {
            guard let heading = child as? Heading, let range = heading.range else { continue }
            var slug = slugify(heading.plainText)
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

    static func addHeadingAnchors(_ html: String) -> String {
        var seen: [String: Int] = [:]
        let pattern = /<h([1-6])>(.*?)<\/h\1>/.dotMatchesNewlines()
        return html.replacing(pattern) { match in
            let inner = String(match.2)
            let plain = inner.replacing(/<[^>]+>/, with: "")
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
