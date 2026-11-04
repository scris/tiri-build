import Foundation
import Testing
@testable import TiriCore

private func math(_ source: String) -> [String] {
    MathText.extract(source).spans.map(\.tex)
}

private let stub = DocumentExtras(renderMath: { tex, display in
    tex.contains("BAD") ? nil : "<m\(display ? " d" : "")>\(tex)</m>"
}, mathStylesheet: { "/*katex*/" })

@Suite struct MathTextTests {
    @Test(arguments: [
        "It costs $5 and $10 today.",
        "From $5-$10 a month.",
        "US$20 and CA$30.",
        "Between $1,000 and $2,000.",
        "$5 to 10$ isn't math.",
        "Set $HOME and $PATH first.",
        "$HOME/$PATH and $A:$B",
        "Inside `$x^2$` a code span.",
        "Inside ``a ` $x$ b`` a longer span.",
        "Escaped \\$3 and \\$4 stay money.",
        "A lone $ sign.",
        "$$$ is expensive, $$$$ more.",
        "Spaces $ x $ aren't math.",
        "\\[1\\] is a footnote mark.",
        "\\[link\\](url) stays a link.",
        "$a\n\nb$ crosses a paragraph.",
        "$$\n\n$$",
    ])
    func notMath(source: String) {
        #expect(math(source).isEmpty)
    }

    @Test(arguments: [
        ("$x^2$", ["x^2"]),
        ("Euler $e^{i\\pi}$ and $a_b$.", ["e^{i\\pi}", "a_b"]),
        ("(see $x$)", ["x"]),
        ("$2x + 3y$", ["2x + 3y"]),
        ("$5\\%$", ["5\\%"]),
        ("\\(a_b\\)", ["a_b"]),
        ("$$x$$", ["x"]),
        ("before $$ x + y $$ after", ["x + y"]),
        ("$$\nx\n+ y\n$$", ["x\n+ y"]),
        ("\\[\nx \\\\ y\n\\]", ["x \\\\ y"]),
        ("\\[x\\]", ["x"]),
        ("costs $5 but $x$ doesn't", ["x"]),
    ])
    func findsMath(source: String, expected: [String]) {
        #expect(math(source) == expected)
    }

    @Test func leavesCodeBlocksAlone() {
        #expect(math("```\n$x$\n```\n").isEmpty)
        #expect(math("~~~\n$$\nx\n$$\n~~~\n").isEmpty)
        #expect(math("para\n\n    $x$\n").isEmpty)
        #expect(math("- item\n\n  ```\n  $x$\n  ```\n").isEmpty)
        #expect(math("<div>\n$x$\n</div>\n").isEmpty)
        #expect(math("```\n$x$\n```\n\n$y$\n") == ["y"])
    }

    @Test func tokensKeepLineNumbers() {
        let source = "a\n\n$$\nx\ny\n$$\n\nb $z$\n"
        let extracted = MathText.extract(source)
        #expect(extracted.markdown.components(separatedBy: "\n").count == source.components(separatedBy: "\n").count)
        #expect(extracted.spans[0].endLine == 5)
        #expect(extracted.spans[1].endLine == nil)
        #expect(extracted.spans[1].original == "$z$")
    }

    @Test func quotedMathLosesItsMarks() {
        let spans = MathText.extract("> $$\n> a\n> b\n> $$\n").spans
        #expect(spans.map(\.tex) == ["a\nb"])
    }

    @Test func fastPathSkipsPlainText() {
        #expect(MathText.cannotContainMath("no math (here) [at] all"))
        #expect(!MathText.cannotContainMath("a $ b"))
        #expect(!MathText.cannotContainMath("a \\( b"))
    }
}

@Suite struct RichMarkdownTests {
    private func html(_ source: String, extras: DocumentExtras = stub) -> String {
        MarkdownRenderer.render(markdown: source, baseHref: nil, extras: extras).html
    }

    @Test func rendersMathAndKeepsTheSource() {
        let page = html("Say $a_b$ and $c_d$.")
        #expect(page.contains("<m>a_b</m>"))
        #expect(page.contains("data-tex=\"$a_b$\""))
        // Not emphasis, which is how markdown alone would read those underscores.
        #expect(!page.contains("<em>"))
        #expect(page.contains("/*katex*/"))
    }

    @Test func stylesOnlyLoadWithMath() {
        #expect(!html("Plain $5 text").contains("/*katex*/"))
    }

    @Test func brokenMathShowsItsSource() {
        let page = html("Try $BAD<x$ now")
        #expect(page.contains("<code class=\"math-failed\">$BAD&lt;x$</code>"))
    }

    @Test func mathWithoutAnEngineShowsItsSource() {
        #expect(html("$x$", extras: DocumentExtras()).contains("math-failed"))
    }

    @Test func mathInsideAnAttributeStaysText() {
        let page = html("![a $x$ b](pic.png \"$y$\")")
        #expect(page.contains("alt=\"a $x$ b\""))
        #expect(page.contains("title=\"$y$\""))
        #expect(!page.contains("TIRIMATH"))
    }

    @Test func blocksKeepTheirSourceLines() {
        let page = html("one\n\n$$\nx\n$$\n\nfour\n")
        #expect(page.contains("data-line=\"2\" data-line-end=\"4\""))
        #expect(page.contains("data-line=\"6\" data-line-end=\"6\""))
    }

    @Test func headingAnchorsAgreeWithMath() {
        let source = "# A\n\n## Energy $E=mc^2$\n\ntext\n"
        let anchor = MarkdownRenderer.anchor(forLine: 5, in: source)
        #expect(anchor == "energy-emc2")
        #expect(html(source).contains("id=\"energy-emc2\""))
    }

    @Test func escapesCodeAndText() {
        let page = html("Use `Array<Int>` when a < b.\n\n```swift\nlet a: Array<Int> = [] // <b>x</b>\n```\n")
        #expect(page.contains("<code>Array&lt;Int&gt;</code>"))
        #expect(page.contains("a &lt; b"))
        #expect(page.contains("Array&lt;Int&gt; = [] // &lt;b&gt;x&lt;/b&gt;"))
    }

    @Test func keepsMarkdownFeatures() {
        let page = html("# Tom & `Jerry`\n\n| a |\n|---|\n| **b** |\n\n- [x] done\n\n<b>raw</b>\n\n[l](http://x.y/?a=1&b=2)\n")
        #expect(page.contains("<h1 id=\"tom--jerry\">Tom &amp; <code>Jerry</code></h1>"))
        #expect(page.contains("<td><strong>b</strong></td>"))
        #expect(page.contains("<li class=\"task\"><input type=\"checkbox\""))
        #expect(page.contains("<b>raw</b>"))
        #expect(page.contains("href=\"http://x.y/?a=1&amp;b=2\""))
    }

    @Test func anchorsAgreeWithEscapedHeadings() {
        let source = "# Tom & Jerry\n\nbody\n"
        #expect(MarkdownRenderer.anchor(forLine: 3, in: source) == "tom--jerry")
    }
}
