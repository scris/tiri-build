import Foundation
import Testing
@testable import TiriCore

private let stub = DocumentExtras(renderMath: { tex, display in
    tex.contains("BAD") ? nil : "<m\(display ? " d" : "")>\(tex)</m>"
}, mathStylesheet: { "/*katex*/" })

@Suite struct NotebookTests {
    private func parse(_ json: String) throws -> Notebook { try Notebook.parse(Data(json.utf8)) }

    private func page(_ json: String, limits: NotebookRenderer.Limits = NotebookRenderer.Limits(),
                      highlight: (@Sendable (String, String) -> String?)? = nil) throws -> String {
        NotebookRenderer.render(try parse(json), baseHref: nil, extras: stub, highlight: highlight, limits: limits).html
    }

    private func oneCell(_ outputs: String, source: String = "\"x\"") -> String {
        "{\"nbformat\":4,\"cells\":[{\"cell_type\":\"code\",\"source\":\(source),\"execution_count\":7,\"outputs\":[\(outputs)]}]}"
    }

    @Test func readsCellsInOrder() throws {
        let notebook = try parse("""
        {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"language":"python"}},"cells":[
          {"cell_type":"markdown","source":["# A\\n","b"]},
          {"cell_type":"code","source":"x = 1","execution_count":3,"outputs":[]},
          {"cell_type":"raw","source":"r"},
          {"cell_type":"code","source":[],"execution_count":null,"outputs":[]}
        ]}
        """)
        #expect(notebook.language == "python")
        #expect(notebook.cells.map(\.kind) == [.markdown, .code, .raw, .code])
        #expect(notebook.cells[0].source == "# A\nb")
        #expect(notebook.cells[1].executionCount == 3)
        #expect(notebook.cells[3].executionCount == nil)
    }

    @Test func languageInfoWinsOverKernelspec() throws {
        let notebook = try parse("{\"nbformat\":4,\"metadata\":{\"language_info\":{\"name\":\"julia\"},\"kernelspec\":{\"language\":\"python\"}},\"cells\":[]}")
        #expect(notebook.language == "julia")
    }

    @Test func oldFormatsSaySo() {
        #expect(throws: Notebook.Failure.oldFormat(3)) { try parse("{\"nbformat\":3,\"worksheets\":[]}") }
        #expect(throws: Notebook.Failure.oldFormat(3)) { try parse("{\"worksheets\":[{\"cells\":[]}]}") }
        #expect(Notebook.Failure.oldFormat(3).message.contains("nbformat 3"))
    }

    @Test func malformedFilesFail() {
        #expect(throws: Notebook.Failure.self) { try parse("") }
        #expect(throws: Notebook.Failure.self) { try parse("{\n\"cells\": [\n") }
        #expect(throws: Notebook.Failure.notANotebook) { try parse("{\"hello\":1}") }
        #expect(throws: Notebook.Failure.notANotebook) { try parse("[1,2]") }
        #expect(throws: Notebook.Failure.notANotebook) { try parse("{\"cells\":3}") }
    }

    @Test func aFutureVersionStillTries() throws {
        #expect(try parse("{\"nbformat\":5,\"cells\":[{\"cell_type\":\"raw\",\"source\":\"r\"}]}").cells.count == 1)
    }

    @Test func oddCellsDontStopTheRest() throws {
        let notebook = try parse("{\"nbformat\":4,\"cells\":[1,{\"cell_type\":\"mystery\",\"source\":\"s\"},{\"cell_type\":\"code\",\"source\":5,\"outputs\":[7,{\"output_type\":\"new\"}]}]}")
        // The 1 still counts, so that each cell's number is its place in the file.
        #expect(notebook.cells.map(\.kind) == [.raw, .raw, .code])
        #expect(notebook.cells[2].source == "")
        #expect(notebook.cells[2].outputs.isEmpty)
    }

    @Test func acceptsNaNFromPython() throws {
        let notebook = try parse(oneCell("{\"output_type\":\"execute_result\",\"data\":{\"application/json\":{\"x\":NaN},\"text/plain\":\"nan\"}}"))
        #expect(notebook.cells.count == 1)
    }

    @Test func promptShowsExecutionCount() throws {
        #expect(try page(oneCell("")).contains("[7]"))
    }

    @Test func codeIsHighlightedOrEscaped() throws {
        #expect(try page(oneCell("", source: "\"a<b\"")).contains("a&lt;b"))
        let highlighted = try page(oneCell(""), highlight: { code, language in "<i>\(language):\(code)</i>" })
        #expect(highlighted.contains("<i>python:x</i>"))
    }

    @Test func streamsJoinAndSettle() throws {
        let html = try page(oneCell("""
        {"output_type":"stream","name":"stdout","text":"10%\\r50%"},
        {"output_type":"stream","name":"stdout","text":"\\r100%\\ndone\\n"},
        {"output_type":"stream","name":"stderr","text":"warn <x>\\n"}
        """))
        #expect(html.contains("100%\ndone"))
        #expect(!html.contains("50%"))
        #expect(html.contains("nb-stderr\""))
        #expect(html.contains("warn &lt;x&gt;"))
    }

    @Test func errorsMapColors() throws {
        let html = try page(oneCell("{\"output_type\":\"error\",\"ename\":\"E\",\"evalue\":\"v\",\"traceback\":[\"\\u001b[0;31mE<\\u001b[0m: v\"]}"))
        #expect(html.contains("<span class=\"ansi-fg31\">E&lt;</span>: v"))
        #expect(!html.contains("\u{1B}"))
        let bare = try page(oneCell("{\"output_type\":\"error\",\"ename\":\"E\",\"evalue\":\"v\",\"traceback\":[]}"))
        #expect(bare.contains("E: v"))
    }

    private func display(_ data: String, metadata: String = "{}") -> String {
        oneCell("{\"output_type\":\"display_data\",\"metadata\":\(metadata),\"data\":\(data)}")
    }

    @Test func picksTheRichestOutput() throws {
        let html = try page(display("{\"text/html\":\"<b>rich</b>\",\"text/plain\":\"poor\"}"))
        #expect(html.contains("<b>rich</b>"))
        #expect(!html.contains("poor"))
        let image = try page(display("{\"image/png\":\"QUJD\\n\",\"text/plain\":\"<Figure>\"}"))
        #expect(image.contains("src=\"data:image/png;base64,QUJD\""))
        #expect(!image.contains("Figure"))
        #expect(try page(display("{\"image/jpeg\":\"QUJD\"}")).contains("data:image/jpeg;base64,QUJD"))
    }

    @Test func aPictureBeatsHTMLThatNeedsScripts() throws {
        let html = try page(display("{\"text/html\":\"<script>x()</script>\",\"image/png\":\"QUJD\"}"))
        #expect(html.contains("data:image/png"))
        #expect(!html.contains("x()"))
    }

    @Test func scriptsNeverReachThePage() throws {
        let html = try page(display("{\"text/html\":\"<SCRIPT src=a>bad()</SCRIPT ><iframe src=x></iframe><div>kept</div>\"}"))
        #expect(!html.contains("bad()"))
        #expect(!html.lowercased().contains("<iframe"))
        #expect(html.contains("<div>kept</div>"))
        #expect(html.contains("needs scripts"))
        #expect(html.contains("default-src 'none'"))
    }

    @Test func htmlOutputStaysInItsShadowRoot() throws {
        let html = try page(display("{\"text/html\":\"<style>body{color:red}</style>a</TEMPLATE><h1>b</h1><template>c\"}"))
        #expect(html.contains("<template shadowrootmode=\"open\">"))
        #expect(html.components(separatedBy: "</template>").count == 2)
        #expect(html.contains("&lt;/TEMPLATE>"))
    }

    @Test func svgGoesInAsAnImage() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><script>x()</script></svg>"
        let html = try page(display("{\"image/svg+xml\":\"\(svg)\"}"))
        #expect(html.contains("data:image/svg+xml;base64,"))
        #expect(!html.contains("<script>x()"))
    }

    @Test func imagesKeepTheirMetadataSize() throws {
        let html = try page(display("{\"image/png\":\"QUJD\"}", metadata: "{\"image/png\":{\"width\":360,\"height\":200}}"))
        #expect(html.contains("width=\"360\""))
    }

    @Test func aBadImageDoesntReachTheAttribute() throws {
        let html = try page(display("{\"image/png\":\"a\\\" onerror=\\\"x\"}"))
        #expect(!html.contains("onerror"))
        #expect(html.contains("can't be read"))
    }

    @Test func latexOutputRenders() throws {
        let html = try page(display("{\"text/latex\":\"$\\\\int x$\",\"text/plain\":\"Integral\"}"))
        #expect(html.contains("<m d>\\int x</m>"))
        let failed = try page(display("{\"text/latex\":\"$BAD$\",\"text/plain\":\"plain answer\"}"))
        #expect(failed.contains("plain answer"))
    }

    @Test func unknownOutputSaysSo() throws {
        let html = try page(display("{\"application/vnd.jupyter.widget-view+json\":{\"model_id\":\"m\"}}"))
        #expect(html.contains("isn't shown here"))
    }

    @Test func longTextIsCutAndSaysSo() throws {
        var limits = NotebookRenderer.Limits()
        limits.text = 1000
        let long = String(repeating: "line\\n", count: 5000)
        let html = try page(oneCell("{\"output_type\":\"stream\",\"name\":\"stdout\",\"text\":\"START\\n\(long)END\"}"), limits: limits)
        #expect(html.contains("START"))
        #expect(html.contains("END"))
        #expect(html.contains("of output not shown"))
        #expect(html.utf8.count < 30_000)
    }

    @Test func hugeImagesAndHTMLSaySo() throws {
        var limits = NotebookRenderer.Limits()
        limits.image = 8
        limits.html = 8
        #expect(try page(display("{\"image/png\":\"QUJDQUJDQUJD\"}"), limits: limits).contains("Image not shown"))
        #expect(try page(display("{\"text/html\":\"<b>0123456789</b>\"}"), limits: limits).contains("HTML output not shown"))
    }

    @Test func aPageHasABudget() throws {
        var limits = NotebookRenderer.Limits()
        limits.page = 100
        let output = "{\"output_type\":\"display_data\",\"data\":{\"image/png\":\"\(String(repeating: "A", count: 400))\"}}"
        let html = try page(oneCell([output, output, output].joined(separator: ",")), limits: limits)
        #expect(html.contains("2 more outputs not shown"))
    }

    @Test func markdownCellsGetMathAndAttachments() throws {
        let html = try page("""
        {"nbformat":4,"cells":[{"cell_type":"markdown","source":"$a_b$ costs $5 and $10 ![p](attachment:p.png)","attachments":{"p.png":{"image/png":"QUJD"}}}]}
        """)
        #expect(html.contains("<m>a_b</m>"))
        #expect(html.contains("$5 and $10"))
        #expect(html.contains("src=\"data:image/png;base64,QUJD\""))
    }

    @Test func diagramsInMarkdownCells() throws {
        let rendered = NotebookRenderer.render(try parse("{\"nbformat\":4,\"cells\":[{\"cell_type\":\"markdown\",\"source\":\"```mermaid\\ngraph TD\\nA-->B\\n```\"}]}"), baseHref: nil)
        #expect(rendered.hasPendingDiagrams)
    }

    @Test func emptyNotebooksSaySo() throws {
        #expect(try page("{\"nbformat\":4,\"cells\":[]}").contains("no cells"))
    }

    @Test func emptyCellsAreLeftOut() throws {
        let html = try page("{\"nbformat\":4,\"cells\":[{\"cell_type\":\"code\",\"source\":\" \",\"outputs\":[]},{\"cell_type\":\"raw\",\"source\":\"r\"}]}")
        #expect(html.contains("data-line=\"1\""))
        #expect(!html.contains("data-line=\"0\""))
    }

    @Test func classifiedAsNotebooks() {
        #expect(FileClassifier.classify(path: "a.ipynb") == .notebook)
        #expect(FileClassifier.classify(path: "A.IPYNB") == .notebook)
    }
}

@Suite struct TerminalTextTests {
    @Test func settlesCarriageReturnsAndBackspaces() {
        #expect(TerminalText.settled("a\rb\nc") == "b\nc")
        #expect(TerminalText.settled("line\r\nnext") == "line\nnext")
        #expect(TerminalText.settled("abc\u{8}\u{8}d") == "ad")
        #expect(TerminalText.settled("plain") == "plain")
    }

    @Test func dropsOtherSequences() {
        #expect(TerminalText.html("a\u{1B}[2Kb") == "ab")
        #expect(TerminalText.html("\u{1B}]0;title\u{7}after") == "after")
        #expect(TerminalText.html("\u{1B}]8;;http://x\u{1B}\\link") == "link")
        #expect(TerminalText.html("cut\u{1B}[") == "cut")
    }

    @Test(arguments: [
        ("\u{1B}[32mg\u{1B}[0m", "<span class=\"ansi-fg32\">g</span>"),
        ("\u{1B}[1;91mb\u{1B}[m", "<span class=\"ansi-fg91 ansi-bold\">b</span>"),
        ("\u{1B}[41mx\u{1B}[49my", "<span class=\"ansi-bg41\">x</span>y"),
        // 256-color and true color change to suit the theme: too dark for dark mode here...
        ("\u{1B}[38;5;21mx\u{1B}[39my", "<span style=\"color:light-dark(rgb(0,0,255),rgb(125,125,255))\">x</span>y"),
        ("\u{1B}[38;2;1;2;3mx", "<span style=\"color:light-dark(rgb(1,2,3),rgb(140,140,141))\">x</span>"),
        // ...and too bright for white here.
        ("\u{1B}[38;2;255;255;0mx", "<span style=\"color:light-dark(rgb(144,144,0),rgb(255,255,0))\">x</span>"),
        ("\u{1B}[48;5;240mx", "<span style=\"background:rgb(88,88,88)\">x</span>"),
        ("\u{1B}[31m<b>", "<span class=\"ansi-fg31\">&lt;b&gt;</span>"),
        ("no color <b>", "no color &lt;b&gt;"),
        ("\u{1B}[31m\u{1B}[32mx", "<span class=\"ansi-fg32\">x</span>"),
    ])
    func mapsColors(source: String, expected: String) {
        #expect(TerminalText.html(source) == expected)
    }
}

@Suite struct NotebookEditingTests {
    // As nbformat writes them, with one space per level.
    private let file = """
    {
     "cells": [
      {
       "cell_type": "markdown",
       "id": "m1",
       "metadata": {},
       "source": [
        "# Title \\"quoted\\" ]}\\n",
        "more"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 3,
       "id": "c1",
       "metadata": {"a": [1, {"b": "]"}]},
       "outputs": [
        {"name": "stdout", "output_type": "stream", "text": ["hi\\n"]}
       ],
       "source": [
        "x = 1\\n",
        "x"
       ]
      }
     ],
     "metadata": {"language_info": {"name": "python"}},
     "nbformat": 4,
     "nbformat_minor": 5
    }

    """

    private var data: Data { Data(file.utf8) }

    @Test func changingACellChangesNothingElse() throws {
        let result = try NotebookEditing.replacingSource(in: data, cell: 1, expecting: "x = 1\nx", with: "y = 2\n")
        let text = String(decoding: result, as: UTF8.self)
        let expected = file.replacingOccurrences(of: "\"x = 1\\n\",\n    \"x\"", with: "\"y = 2\\n\"")
        #expect(text == expected)
        #expect(try Notebook.parse(result).cells[1].source == "y = 2\n")
    }

    @Test func textOfEveryKindSurvives() throws {
        let source = "print(\"a\\tb\")\n# 中文 🎉\n\ttab\n"
        let result = try NotebookEditing.replacingSource(in: data, cell: 1, expecting: nil, with: source)
        #expect(try Notebook.parse(result).cells[1].source == source)
        #expect(String(decoding: result, as: UTF8.self).contains("中文"))
    }

    @Test func anEditCantOverwriteSomeoneElses() {
        #expect(throws: NotebookEditing.Failure.changedMeanwhile) {
            try NotebookEditing.replacingSource(in: data, cell: 1, expecting: "what I saw", with: "z")
        }
        #expect(throws: NotebookEditing.Failure.noSuchCell) {
            try NotebookEditing.replacingSource(in: data, cell: 9, expecting: nil, with: "z")
        }
        #expect(throws: NotebookEditing.Failure.notANotebook) {
            try NotebookEditing.replacingSource(in: Data("{\"a\": 1}".utf8), cell: 0, expecting: nil, with: "z")
        }
    }

    @Test func addingACell() throws {
        for (after, position) in [(-1, 0), (0, 1), (1, 2)] {
            let result = try Notebook.parse(NotebookEditing.insertingCell(in: data, after: after, kind: .code))
            #expect(result.cells.count == 3)
            #expect(result.cells[position].kind == .code)
            #expect(result.cells[position].source.isEmpty)
            #expect(result.cells[position].id?.isEmpty == false)
        }
        let markdown = try Notebook.parse(NotebookEditing.insertingCell(in: data, after: 0, kind: .markdown))
        #expect(markdown.cells[1].kind == .markdown)
    }

    @Test func addingToAnEmptyNotebookAndOneTooOldForIDs() throws {
        let empty = Data("{\n \"cells\": [],\n \"metadata\": {},\n \"nbformat\": 4,\n \"nbformat_minor\": 2\n}\n".utf8)
        let result = try Notebook.parse(NotebookEditing.insertingCell(in: empty, after: -1, kind: .code))
        #expect(result.cells.count == 1)
        #expect(result.cells[0].id == nil)
    }

    @Test func deletingACell() throws {
        let first = try NotebookEditing.deletingCell(in: data, cell: 0)
        #expect(try Notebook.parse(first).cells.map(\.id) == ["c1"])
        let last = try NotebookEditing.deletingCell(in: data, cell: 1)
        #expect(try Notebook.parse(last).cells.map(\.id) == ["m1"])
        let none = try NotebookEditing.deletingCell(in: first, cell: 0)
        #expect(try Notebook.parse(none).cells.isEmpty)
    }

    @Test func clearingOutputs() throws {
        let result = try Notebook.parse(NotebookEditing.clearingOutputs(in: data))
        #expect(result.cells[1].outputs.isEmpty)
        #expect(result.cells[1].executionCount == nil)
        #expect(result.cells[1].source == "x = 1\nx")
        #expect(result.cells[0].source.hasPrefix("# Title"))
    }

    @Test func emptyCellsOnlyShowWhereTheyCanBeTyped() {
        let notebook = Notebook(cells: [Notebook.Cell(kind: .code, source: "", executionCount: nil, outputs: [], attachments: [:])], language: "python")
        #expect(NotebookRenderer.render(notebook, baseHref: nil).html.contains("nb-cell\" ") == false)
        let interactive = NotebookRenderer.render(notebook, baseHref: nil, interactive: true).html
        #expect(interactive.contains("nb-run"))
        #expect(interactive.contains("nb-add-code"))
    }
}
