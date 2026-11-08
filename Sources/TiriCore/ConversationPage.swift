import Foundation
import Markdown

/// A conversation an agent had, laid out as one: what you said in a bubble on the right, as in the agents'
/// own windows, and what the agent said and did in the body between. `Conversations.markdown` writes the
/// file with a mark before each turn, and this reads the marks back. Anything else in the file is markdown
/// as usual, so math and code render as they do anywhere, a selection still names its source lines, and an
/// agent can read the same file. Who's speaking is in the file, for the agent, and kept out of sight on the
/// page: the title says which agent it was, and the side says who.
extension MarkdownRenderer {
    static func isConversation(_ source: String) -> Bool {
        source.hasPrefix(Conversations.documentMark)
    }

    static let conversationStyles = """
    main.conversation { max-width: 900px; }
    :root { --you:#f2f2f2; --you-code:rgba(0,0,0,.05); }
    @media (prefers-color-scheme: dark) { :root { --you:#2a2a2a; --you-code:rgba(255,255,255,.08); } }
    header.conversation { margin:0 0 1.8em; padding-bottom:1em; border-bottom:1px solid var(--line); }
    header.conversation h1 { font-size:1.35em; margin:0 0 .3em; padding:0; border:0; }
    header.conversation p { margin:0; color:var(--muted); font-size:.9em; }
    .turn { display:flex; flex-direction:column; align-items:flex-start; margin:0 0 1.2em; }
    .turn.you { align-items:flex-end; margin:1.6em 0; }
    .speaker { position:absolute; width:1px; height:1px; overflow:hidden; clip-path:inset(50%); }
    .bubble { min-width:0; max-width:100%; box-sizing:border-box; }
    .turn.you .bubble { max-width:82%; padding:.6em 1em; background:var(--you); border-radius:18px 18px 4px 18px; }
    .turn.you .bubble p { white-space:pre-wrap; }
    .turn.you .bubble .math { white-space:normal; }
    .turn.you .bubble pre, .turn.you .bubble code { background:var(--you-code); }
    .bubble > .src:first-child > :first-child { margin-top:0; }
    .bubble > .src:last-child > :last-child { margin-bottom:0; }
    .turn.agent .bubble h1, .turn.agent .bubble h2, .turn.agent .bubble h3 { font-size:1.05em; margin:1.2em 0 .4em; padding:0; border:0; }
    .did { margin:.2em 0 1em; }
    .did ul { list-style:none; margin:0; padding:0; }
    .did li { position:relative; margin:.15em 0; padding-left:1.1em; color:var(--muted); font-size:.86em; overflow-wrap:anywhere; }
    .did li::before { content:"›"; position:absolute; left:.15em; }
    .did li > p { display:inline; margin:0; }
    .did code { background:none; padding:0; font:inherit; }
    details summary { cursor:default; color:var(--muted); font-size:.9em; }
    details pre { margin-top:.5em; max-height:24em; }

    """
}

extension MarkdownRenderer.Fragments {
    /// The same blocks as `html(markdown:lineOffset:)`, grouped into the turns the marks say they belong to.
    /// The heading after a turn's mark names who's speaking, and a list after the doing mark is what the
    /// agent did, in small print.
    mutating func conversationHTML(markdown: String, lineOffset: Int?) -> String {
        let math = MathText.extract(markdown)
        let tall = math.spans.filter { $0.endLine != nil }
        let document = Document(parsing: math.markdown)
        var html = "<header class=\"conversation\">"
        // A turn's bubble opens at its first block, after the speaker's name.
        var turn: (open: Bool, bubble: Bool) = (false, false)
        var didNext = false
        func closing() -> String {
            guard turn.open else { return "</header>" }
            return (turn.bubble ? "</div>" : "") + "</article>"
        }
        for block in document.children {
            if let raw = (block as? HTMLBlock)?.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines) {
                if raw == Conversations.documentMark { continue }
                if raw == Conversations.youMark || raw == Conversations.agentMark {
                    html += closing() + "<article class=\"turn \(raw == Conversations.youMark ? "you" : "agent")\">"
                    turn = (true, false)
                    continue
                }
                if raw == Conversations.didMark {
                    didNext = true
                    continue
                }
            }
            if turn.open, !turn.bubble {
                if let heading = block as? Heading {
                    html += "<div class=\"speaker\">\(MarkdownRenderer.escapeText(heading.plainText))</div>"
                    continue
                }
                html += "<div class=\"bubble\">"
                turn.bubble = true
            }
            var piece = blockHTML(block, lineOffset: lineOffset, tall: tall)
            if didNext {
                piece = "<div class=\"did\">\(piece)</div>"
                didNext = false
            }
            html += piece
        }
        html += closing()
        return finish(html, math: math)
    }
}
