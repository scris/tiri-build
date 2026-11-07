import Foundation
import Testing
@testable import TiriCore

/// Text with its selection written in: `|` is a caret, `«` and `»` the ends of a selection.
private func parse(_ marked: String) -> (text: NSString, selection: NSRange) {
    var text = ""
    var start: Int?
    var end: Int?
    var count = 0
    for character in marked {
        switch character {
        case "|": start = count; end = count
        case "«": start = count
        case "»": end = count
        default:
            text.append(character)
            count += String(character).utf16.count
        }
    }
    return (text as NSString, NSRange(location: start ?? 0, length: (end ?? 0) - (start ?? 0)))
}

private func render(_ text: NSString, _ edit: TextEdit?) -> String {
    guard let edit else { return "(nothing)" }
    let result = NSMutableString(string: text as String)
    for change in edit.changes.reversed() { result.replaceCharacters(in: change.range, with: change.text) }
    let selection = edit.selection
    if selection.length == 0 {
        result.insert("|", at: selection.location)
    } else {
        result.insert("»", at: NSMaxRange(selection))
        result.insert("«", at: selection.location)
    }
    return result as String
}

private func expectEdit(_ marked: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation,
                        _ command: (NSString, NSRange) -> TextEdit?) {
    let (text, selection) = parse(marked)
    #expect(render(text, command(text, selection)) == expected, sourceLocation: sourceLocation)
}

private let slashes = CommentSyntax(line: "//", block: ("/*", "*/"))
private let markup = CommentSyntax(block: ("<!--", "-->"))
private let four = IndentStyle.spaces(4)

@Suite struct TextEditingTests {
    @Test(arguments: [
        ("a|b", "// a|b"),
        ("// a|b", "a|b"),
        ("//a|b", "a|b"),
        ("  x|", "  // x|"),
        ("  // x|", "  x|"),
        // Comments go at the shallowest indent, blank lines stay blank.
        ("«  a\n\n    b»", "«  // a\n\n  //   b»"),
        ("«  // a\n\n  //   b»", "«  a\n\n    b»"),
        // Mixed lines: comment them all.
        ("«// a\nb»", "«// // a\n// b»"),
        // A selection ending at the start of a line leaves that line out.
        ("«a\n»b", "«// a\n»b"),
        // An empty line starts a comment there.
        ("|", "// |"),
        ("  |", "  // |"),
        // The caret after the end of a comment stays with its text.
        ("x|\ny", "// x|\ny"),
    ])
    func lineComments(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.toggleLineComment(in: $0, selection: $1, syntax: slashes) }
    }

    @Test(arguments: [
        ("a|b", "<!-- a|b -->"),
        ("<!-- a|b -->", "a|b"),
        ("<!--ab-->|", "ab|"),
        ("  «a\nb»  ", "  «<!-- a\nb -->»  "),
    ])
    func blockComments(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.toggleLineComment(in: $0, selection: $1, syntax: markup) }
    }

    @Test func commentSyntaxByFile() {
        #expect(CommentSyntax.forFile("/a/b.swift")?.line == "//")
        #expect(CommentSyntax.forFile("/a/b.py")?.line == "#")
        #expect(CommentSyntax.forFile("/a/Makefile")?.line == "#")
        #expect(CommentSyntax.forFile("/a/.env.local")?.line == "#")
        #expect(CommentSyntax.forFile("/a/q.sql")?.line == "--")
        #expect(CommentSyntax.forFile("/a/b.css")?.block?.open == "/*")
        #expect(CommentSyntax.forFile("/a/b.html")?.block?.close == "-->")
        #expect(CommentSyntax.forFile("/a/b.json") == nil)
        #expect(CommentSyntax.forFile("/a/b.txt") == nil)
    }

    @Test(arguments: [
        ("a|", "    a|"),
        // Up to the next stop.
        ("  a|", "    a|"),
        ("     a|", "        a|"),
        ("«a\n\nb»", "«    a\n\n    b»"),
        // Nothing to indent on an empty line.
        ("|", "(nothing)"),
    ])
    func indenting(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.indent(in: $0, selection: $1, style: four) }
    }

    @Test func indentingWithTabs() {
        expectEdit("a|", "\ta|") { TextEditing.indent(in: $0, selection: $1, style: .tabs(width: 4)) }
        expectEdit("\ta|", "a|") { TextEditing.outdent(in: $0, selection: $1, style: .tabs(width: 4)) }
    }

    @Test(arguments: [
        ("    a|", "a|"),
        // Back to the previous stop.
        ("      a|", "    a|"),
        ("  a|", "a|"),
        ("a|", "(nothing)"),
        ("«    a\nb\n    c»", "«a\nb\nc»"),
        // A caret inside what goes stays at the line's start.
        ("  |  a", "|a"),
    ])
    func outdenting(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.outdent(in: $0, selection: $1, style: four) }
    }

    @Test(arguments: [
        // Nothing selected, or part of one line: insert up to the next stop.
        ("|a", "    |a"),
        ("ab|", "ab  |"),
        ("a«b»c", "a   |c"),
        // A whole line, or several: indent them.
        ("«abc»", "«    abc»"),
        ("a«b\nc»d", "    a«b\n    c»d"),
    ])
    func tabKey(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.tab(in: $0, selection: $1, style: four) }
    }

    @Test(arguments: [
        ("a|", "a\n|"),
        ("  a|", "  a\n  |"),
        ("  a|b", "  a\n  |b"),
        // Inside the indent, the new line gets what's before the cursor.
        ("  |  a", "  \n  |  a"),
        // After an opening bracket, one level in.
        ("f {|", "f {\n    |"),
        ("  f(|", "  f(\n      |"),
        // Between a pair, three lines with the cursor in the middle.
        ("f {|}", "f {\n    |\n}"),
        ("  [|]", "  [\n      |\n  ]"),
        ("f { |  }", "f { \n    |\n}"),
        // A line of nothing but indent gives up its spaces on the way past.
        ("    |", "\n    |"),
        ("    |  ", "\n    |"),
        // A selection is replaced.
        ("a«bc»d", "a\n|d"),
        // The file's own line endings.
        ("x\r\n  a|", "x\r\n  a\r\n  |"),
    ])
    func newlines(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.newline(in: $0, selection: $1, style: four) }
    }

    @Test func colonsOpenBlocksWhereTheyDo() {
        expectEdit("def f():|", "def f():\n    |") { TextEditing.newline(in: $0, selection: $1, style: four, colonOpensBlock: true) }
        expectEdit("case 1:|", "case 1:\n|") { TextEditing.newline(in: $0, selection: $1, style: four) }
        #expect(CommentSyntax.colonOpensBlock("/a/b.py"))
        #expect(!CommentSyntax.colonOpensBlock("/a/b.swift"))
    }

    @Test(arguments: [
        ("a\nb|\nc\n", "b|\na\nc\n"),
        ("a\n«b\nc»\nd\n", "«b\nc»\na\nd\n"),
        // The first line has nowhere to go.
        ("a|\nb\n", "(nothing)"),
        // The last line, with no line ending of its own.
        ("a\nb|", "b|\na"),
        // An empty last line can move up, as in VS Code.
        ("a\n|", "|\na"),
        ("x\r\na|\r\n", "a|\r\nx\r\n"),
    ])
    func moveUp(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.moveLines(in: $0, selection: $1, up: true) }
    }

    @Test(arguments: [
        ("a|\nb\nc\n", "b\na|\nc\n"),
        ("«a\nb»\nc\nd\n", "c\n«a\nb»\nd\n"),
        // The last line stays, and a file's final line ending stays where it is.
        ("a\nb|", "(nothing)"),
        ("a\nb|\n", "(nothing)"),
        // Past a last line with no line ending.
        ("a|\nb", "b\na|"),
    ])
    func moveDown(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.moveLines(in: $0, selection: $1, up: false) }
    }

    @Test(arguments: [
        ("a|\nb\n", "a|\na\nb\n"),
        ("«a\nb»\nc", "«a\nb»\na\nb\nc"),
        ("a\nb|", "a\nb|\nb"),
    ])
    func copyUp(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.copyLines(in: $0, selection: $1, up: true) }
    }

    @Test(arguments: [
        ("a|\nb\n", "a\na|\nb\n"),
        ("«a\nb»\nc", "a\nb\n«a\nb»\nc"),
        ("a\nb|", "a\nb\nb|"),
    ])
    func copyDown(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.copyLines(in: $0, selection: $1, up: false) }
    }

    @Test(arguments: [
        ("a\nbb|\nc\n", "a\nc|\n"),
        ("a|b\ncd\n", "c|d\n"),
        ("«a\nb»\nc\n", "|c\n"),
        // The last line: the one before gives up its line ending.
        ("ab\ncd|", "ab|"),
        ("a|", "|"),
        ("a\n|", "|a"),
        ("|", "(nothing)"),
    ])
    func deleting(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.deleteLines(in: $0, selection: $1) }
    }

    @Test(arguments: [
        ("a|bc\nd", "abc\n|\nd"),
        ("  a|b", "  ab\n  |"),
        ("f {|}", "f {}\n|"),
        ("f { x|", "f { x\n|"),
        ("f {|\n}", "f {\n    |\n}"),
        ("«a\nb»\nc", "a\nb\n|\nc"),
    ])
    func insertBelow(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.insertLineBelow(in: $0, selection: $1, style: four) }
    }

    @Test(arguments: [
        ("a|bc", "|\nabc"),
        ("x\n  a|b", "x\n  |\n  ab"),
        ("x\r\na|", "x\r\n|\r\na"),
    ])
    func insertAbove(marked: String, expected: String) {
        expectEdit(marked, expected) { TextEditing.insertLineAbove(in: $0, selection: $1) }
    }

    @Test(arguments: [
        ("a\n  b\n  c\n    d\n", IndentStyle.spaces(2)),
        ("a\n    b\n        c\n", IndentStyle.spaces(4)),
        ("a\n    b\n\nc\n        d\n", IndentStyle.spaces(4)),
        ("a\n\tb\n\t\tc\n", IndentStyle.tabs(width: 4)),
        ("no indent here\nat all\n", IndentStyle.spaces(4)),
        ("", IndentStyle.spaces(4)),
        ("\n\n\n", IndentStyle.spaces(4)),
    ])
    func indentDetection(text: String, expected: IndentStyle) {
        #expect(IndentStyle.detect(in: text as NSString) == expected)
    }

    @Test func oneChangeForALotOfThem() {
        let text = "aXbXc" as NSString
        let edit = TextSearch.replaceAll(TextSearch.ranges(of: "X", in: text, caseSensitive: true), with: "yy", selection: NSRange(location: 0, length: 0))
        let one = edit.coalesced(in: text)
        #expect(one == TextChange(range: NSRange(location: 1, length: 3), text: "yybyy"))
    }
}

@Suite struct LineTableTests {
    @Test(arguments: [
        ("", [0]),
        ("a", [0]),
        ("a\n", [0, 2]),
        ("a\nb", [0, 2]),
        ("a\r\nb", [0, 3]),
        ("a\rb", [0, 2]),
        ("\n\n", [0, 1, 2]),
    ])
    func buildsFromText(text: String, starts: [Int]) {
        #expect(LineTable(text as NSString).starts == starts)
    }

    @Test func findsLines() {
        let table = LineTable("ab\ncd\n" as NSString)
        #expect(table.line(containing: 0) == 0)
        #expect(table.line(containing: 2) == 0)
        #expect(table.line(containing: 3) == 1)
        #expect(table.line(containing: 6) == 2)
    }

    /// Any edit should leave the table as if it had been built from scratch.
    @Test func updatesMatchRebuilding() {
        var random = SeededGenerator(seed: 42)
        let pieces = ["a", "bc", "\n", "\r", "\r\n", "\n\n", "x\ny", "", "🙂\n"]
        for _ in 0..<300 {
            let text = NSMutableString()
            for _ in 0..<Int.random(in: 0...12, using: &random) { text.append(pieces.randomElement(using: &random)!) }
            var table = LineTable(text)
            for _ in 0..<6 {
                let location = Int.random(in: 0...text.length, using: &random)
                let length = Int.random(in: 0...min(4, text.length - location), using: &random)
                let replacement = pieces.randomElement(using: &random)!
                text.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
                let inserted = (replacement as NSString).length
                table.update(editedRange: NSRange(location: location, length: inserted), delta: inserted - length, in: text)
                #expect(table.starts == LineTable(text).starts, "after replacing \(location),\(length) with \(replacement.debugDescription) in \((text as String).debugDescription)")
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct BracketTests {
    private func match(_ marked: String) -> [Int]? {
        let (text, selection) = parse(marked)
        return BracketMatcher.match(in: text, caret: selection.location).map { [$0.open, $0.close] }
    }

    @Test func pairs() {
        #expect(match("|(a)") == [0, 2])
        #expect(match("(a)|") == [0, 2])
        #expect(match("(a|)") == [0, 2])
        #expect(match("(|a)") == [0, 2])
        #expect(match("a|b") == nil)
        #expect(match("(|") == nil)
        // Nested, and other kinds in between.
        #expect(match("|(a(b)[c])") == [0, 8])
        #expect(match("(a(b)[c])|") == [0, 8])
        #expect(match("{[(|)]}") == [2, 3])
        // The bracket to the left wins when there's one on each side.
        #expect(match(")|(") == nil)
        #expect(match("()|()") == [0, 1])
    }

    @Test func stringsDoNotCount() {
        // `( ")" )`: the one in the string is skipped.
        let text = "( \")\" )" as NSString
        let inString = { (offset: Int) in offset >= 2 && offset <= 4 }
        #expect(BracketMatcher.match(in: text, caret: 0, isIgnored: inString)?.close == 6)
        #expect(BracketMatcher.match(in: text, caret: 0)?.close == 3)
    }

    @Test func givesUpAtTheLimit() {
        let text = ("(" + String(repeating: " ", count: 500) + ")") as NSString
        #expect(BracketMatcher.match(in: text, caret: 0, limit: 100) == nil)
        #expect(BracketMatcher.match(in: text, caret: 0, limit: 1_000)?.close == 501)
    }
}

@Suite struct TextSearchTests {
    @Test func findsEveryMatch() {
        let text = "Foo foo FOO" as NSString
        #expect(TextSearch.ranges(of: "foo", in: text, caseSensitive: false).count == 3)
        #expect(TextSearch.ranges(of: "foo", in: text, caseSensitive: true) == [NSRange(location: 4, length: 3)])
        #expect(TextSearch.ranges(of: "", in: text, caseSensitive: false).isEmpty)
        #expect(TextSearch.ranges(of: "aa", in: "aaaa" as NSString, caseSensitive: true).count == 2)
    }

    @Test func movesThroughMatches() {
        let matches = [NSRange(location: 2, length: 1), NSRange(location: 5, length: 1)]
        #expect(TextSearch.index(atOrAfter: 0, in: matches) == 0)
        #expect(TextSearch.index(atOrAfter: 3, in: matches) == 1)
        #expect(TextSearch.index(atOrAfter: 6, in: matches) == 0)
        #expect(TextSearch.index(before: 5, in: matches) == 0)
        #expect(TextSearch.index(before: 2, in: matches) == 1)
        #expect(TextSearch.index(atOrAfter: 0, in: []) == nil)
    }

    @Test func replaceAllKeepsTheCaretWithItsText() {
        let text = "a b a" as NSString
        let edit = TextSearch.replaceAll(TextSearch.ranges(of: "a", in: text, caseSensitive: true), with: "xyz", selection: NSRange(location: 2, length: 0))
        #expect(render(text, edit) == "xyz |b xyz")
    }
}

@Suite struct SymbolTests {
    private func names(_ text: String, _ path: String) -> [String] {
        SimpleSymbols.scan(text, path: path).map(\.name)
    }

    @Test func readsCode() {
        let swift = """
        import Foundation
        public struct Thing {
            private func helper() {}
            static let value = 1
        }
        extension Thing {}
        func free(a: Int) -> Int { a }
        """
        #expect(names(swift, "a.swift") == ["Thing", "helper", "Thing", "free"])
        #expect(names("def f(x):\n    pass\nclass C:\n    def m(self):\n        pass\n", "a.py") == ["f", "C", "m"])
        #expect(names("export function a() {}\nconst b = (x) => x\nconst c = 1\nclass D {}\n", "a.ts") == ["a", "b", "D"])
        #expect(names("func (t *T) Run() {\n}\nfunc main() {\n}\ntype T struct {}\n", "a.go") == ["Run", "main", "T"])
        #expect(names("pub fn run() {}\nimpl Foo {}\nstruct Bar;\n", "a.rs") == ["run", "Foo", "Bar"])
        #expect(names("int main(int argc) {\n  return f(1);\n}\n#define MAX 3\n", "a.c") == ["main", "MAX"])
        #expect(names("build() {\n  x\n}\nfunction y {\n}\n", "a.sh") == ["build"])
    }

    @Test func callsAndStatementsAreNotSymbols() {
        #expect(names("  return foo(1);\n  if (x) {\n  y(2);\n", "a.c").isEmpty)
        #expect(names("if x:\n    print(1)\n", "a.py").isEmpty)
    }

    @Test func readsHeadingsWithTheirParents() {
        let found = SimpleSymbols.scan("# One\n\ntext\n## Two\n```\n# not this\n```\n### Three\n# Four\n#nope\n", path: "a.md")
        #expect(found.map(\.name) == ["One", "Two", "Three", "Four"])
        #expect(found.map(\.container) == [nil, "One", "Two", nil])
        #expect(found.map(\.line) == [1, 4, 8, 9])
    }

    @Test func readsOtherFiles() {
        #expect(names("[tool]\nname = 1\n[[bin]]\n", "a.toml") == ["tool", "bin"])
        #expect(names("key: 1\n  sub: 2\n      deep: 3\n", "a.yml") == ["key", "sub"])
        #expect(names("all: build\n\tcc\nbuild:\n", "Makefile") == ["all", "build"])
        #expect(names(".a {\n}\n#b .c {\n}\n", "a.css") == [".a", "#b .c"])
    }

    @Test func stopsAtTheLimit() {
        let text = String(repeating: "func a() {}\n", count: 100)
        #expect(SimpleSymbols.scan(text, path: "a.swift", limit: 10).count == 10)
    }

    @Test func readsAServersTree() {
        let answer: JSONValue = .array([
            .object(["name": "Outer", "kind": 5, "range": range(0, 0), "selectionRange": range(0, 6), "children": .array([
                .object(["name": "inner", "kind": 6, "range": range(1, 2), "selectionRange": range(1, 7)]),
            ])]),
            .object(["name": "free", "kind": 12, "range": range(9, 0), "selectionRange": range(9, 5)]),
        ])
        let found = LSP.documentSymbols(from: answer)
        #expect(found.map(\.name) == ["Outer", "inner", "free"])
        #expect(found[1].container == "Outer")
        #expect(found[1].line == 2 && found[1].column == 8)
        #expect(found[0].kind == .type && found[1].kind == .method && found[2].kind == .function)
    }

    @Test func readsAServersFlatList() {
        let answer: JSONValue = .array([
            .object(["name": "b", "kind": 12, "containerName": "C", "location": .object(["uri": "file:///x/a.c", "range": range(4, 0)])]),
            .object(["name": "a", "kind": 13, "location": .object(["uri": "file:///x/a.c", "range": range(1, 0)])]),
        ])
        let found = LSP.documentSymbols(from: answer)
        #expect(found.map(\.name) == ["a", "b"])
        #expect(found[1].container == "C")
    }

    @Test func readsWorkspaceSymbols() {
        let answer: JSONValue = .array([
            .object(["name": "f", "kind": 12, "location": .object(["uri": "file:///x/a.c", "range": range(4, 2)])]),
            // A newer server can leave the range for later.
            .object(["name": "g", "kind": 12, "location": .object(["uri": "file:///x/b.c"])]),
            .object(["name": "nowhere", "kind": 12]),
        ])
        let found = LSP.workspaceSymbols(from: answer)
        #expect(found.map(\.name) == ["f", "g"])
        #expect(found[0].path == "/x/a.c" && found[0].line == 5 && found[0].column == 3)
        #expect(found[1].line == 1)
    }

    private func range(_ line: Int, _ character: Int) -> JSONValue {
        .object(["start": .object(["line": .int(line), "character": .int(character)]),
                 "end": .object(["line": .int(line), "character": .int(character + 1)])])
    }
}

@Suite struct QuickOpenQueryTests {
    private func match(_ query: String, _ path: String) -> FuzzyMatcher.Match? {
        let bytes = Array(path.utf8)
        let name = (path as NSString).lastPathComponent
        return FuzzyMatcher.match(pieces: FuzzyMatcher.pieces(query), candidate: bytes, nameStart: bytes.count - name.utf8.count)
    }

    @Test func spacesMeanAnd() {
        #expect(match("app view", "src/view/app.swift") != nil)
        #expect(match("view app", "src/view/app.swift") != nil)
        #expect(match("app nope", "src/view/app.swift") == nil)
        #expect(match("  app   view ", "src/view/app.swift") != nil)
        #expect(match("APP", "src/view/app.swift") != nil)
    }

    @Test func bothWordsShowAsMatched() {
        let positions = Set(match("src app", "src/app.swift")?.positions ?? [])
        #expect(positions.isSuperset(of: [0, 1, 2, 4, 5, 6]))
    }

    @Test func oneWordScoresAsItAlwaysDid() {
        let path = Array("src/app.swift".utf8)
        let single = FuzzyMatcher.match(query: FuzzyMatcher.normalize("app"), candidate: path, nameStart: 4)
        #expect(match("app", "src/app.swift") == single)
    }

    @Test func aLineIsPartOfTheQuery() {
        #expect(PaletteQuery.location("main.swift:12") == ("main.swift", 12, nil))
        #expect(PaletteQuery.location("main.swift:12:3") == ("main.swift", 12, 3))
        #expect(PaletteQuery.location("a b:7") == ("a b", 7, nil))
        #expect(PaletteQuery.location("main.swift:") == ("main.swift", nil, nil))
        #expect(PaletteQuery.location("main.swift") == ("main.swift", nil, nil))
    }
}

@Suite struct MultiCursorTests {
    private func cursors(_ ranges: (Int, Int)...) -> [TextCursor] {
        ranges.map { TextCursor(anchor: $0.0, head: $0.1) }
    }

    private func applied(_ text: String, _ changes: [TextChange]) -> String {
        let result = NSMutableString(string: text)
        for change in changes.reversed() { result.replaceCharacters(in: change.range, with: change.text) }
        return result as String
    }

    @Test func typingReplacesEverySelection() {
        let result = MultiCursor.inserting("xy", at: cursors((0, 1), (4, 5), (8, 9)))
        #expect(applied("a b a b a", result.changes) == "xy b xy b xy")
        #expect(result.cursors == cursors((2, 2), (7, 7), (12, 12)))
    }

    @Test func typingGoesInAtEveryCaret() {
        let result = MultiCursor.inserting("z", at: cursors((1, 1), (3, 3)))
        #expect(applied("abc\n", result.changes) == "azbcz\n")
        #expect(result.cursors == cursors((2, 2), (5, 5)))
    }

    @Test func deletingMovesCursorsBack() {
        let result = MultiCursor.deleting([NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
        #expect(applied("abcd", result.changes) == "bc")
        #expect(result.cursors == cursors((0, 0), (2, 2)))
    }

    @Test func cursorsThatMeetBecomeOne() {
        let result = MultiCursor.deleting([NSRange(location: 0, length: 2), NSRange(location: 1, length: 2)])
        #expect(applied("abcd", result.changes) == "d")
        #expect(result.cursors == cursors((0, 0)))
        #expect(MultiCursor.normalized(cursors((3, 3), (1, 1), (3, 3))) == cursors((1, 1), (3, 3)))
        #expect(MultiCursor.normalized(cursors((1, 3), (3, 3))) == cursors((1, 3)))
        #expect(MultiCursor.normalized(cursors((1, 3), (2, 4))) == cursors((1, 4)))
        // Selections side by side stay separate, as they do when ⌘D finds `aa` in `aaaa`.
        #expect(MultiCursor.normalized(cursors((0, 2), (2, 4))) == cursors((0, 2), (2, 4)))
    }

    // MARK: Line commands at every cursor

    private func lineCommand(_ text: String, _ at: [TextCursor], _ placing: MultiCursor.LineCursors,
                             _ edit: (NSString, NSRange) -> TextEdit?) -> (text: String, cursors: [TextCursor])? {
        let string = text as NSString
        guard let result = MultiCursor.lineEdit(at: at, in: string, cursors: placing, edit: { edit(string, $0) }) else { return nil }
        return (applied(text, result.changes), result.cursors)
    }

    @Test func commentingKeepsEveryCursor() throws {
        // ⌘D on `x` in three lines, then ⌘/.
        let text = "let x = 1\nlet y = 2\nlet x = 3\nx()\n"
        let result = try #require(lineCommand(text, cursors((4, 5), (24, 25), (30, 31)), .follow) {
            TextEditing.toggleLineComment(in: $0, selection: $1, syntax: CommentSyntax(line: "//"))
        })
        #expect(result.text == "// let x = 1\nlet y = 2\n// let x = 3\n// x()\n")
        #expect(result.cursors == cursors((7, 8), (30, 31), (39, 40)))
        // And back.
        let back = try #require(lineCommand(result.text, result.cursors, .follow) {
            TextEditing.toggleLineComment(in: $0, selection: $1, syntax: CommentSyntax(line: "//"))
        })
        #expect(back.text == text)
        #expect(back.cursors == cursors((4, 5), (24, 25), (30, 31)))
    }

    @Test func twoCursorsOnOneLineCommentItOnce() throws {
        let text = "a(x, x)\nb\n"
        let result = try #require(lineCommand(text, cursors((2, 3), (5, 6)), .follow) {
            TextEditing.toggleLineComment(in: $0, selection: $1, syntax: CommentSyntax(line: "#"))
        })
        #expect(result.text == "# a(x, x)\nb\n")
        #expect(result.cursors == cursors((4, 5), (7, 8)))
    }

    @Test func indentingMovesEachCursorWithItsLine() throws {
        let text = "a\nb\nc\n"
        let result = try #require(lineCommand(text, cursors((1, 1), (5, 5)), .follow) {
            TextEditing.indent(in: $0, selection: $1, style: .spaces(2))
        })
        #expect(result.text == "  a\nb\n  c\n")
        #expect(result.cursors == cursors((3, 3), (9, 9)))
    }

    @Test func movingCarriesEveryCursor() throws {
        let text = "1\n2\n3\n4\n5\n"
        // Cursors on lines 2 and 4 move down, each over the line below it.
        let result = try #require(lineCommand(text, cursors((2, 2), (6, 6)), .travel) {
            TextEditing.moveLines(in: $0, selection: $1, up: false)
        })
        #expect(result.text == "1\n3\n2\n5\n4\n")
        #expect(result.cursors == cursors((4, 4), (8, 8)))
        // Lines next to each other move as one block, cursors and all.
        let block = try #require(lineCommand(text, cursors((2, 3), (4, 4)), .travel) {
            TextEditing.moveLines(in: $0, selection: $1, up: true)
        })
        #expect(block.text == "2\n3\n1\n4\n5\n")
        #expect(block.cursors == cursors((0, 1), (2, 2)))
    }

    @Test func copyingDownPutsCursorsOnTheCopies() throws {
        let text = "a\nb\nc\n"
        let result = try #require(lineCommand(text, cursors((0, 0), (4, 4)), .travel) {
            TextEditing.copyLines(in: $0, selection: $1, up: false)
        })
        #expect(result.text == "a\na\nb\nc\nc\n")
        #expect(result.cursors == cursors((2, 2), (8, 8)))
    }

    @Test func deletingLeavesACursorWhereEachBlockWas() throws {
        let text = "a\nb\nc\nd\n"
        let result = try #require(lineCommand(text, cursors((0, 0), (4, 4)), .one) {
            TextEditing.deleteLines(in: $0, selection: $1)
        })
        #expect(result.text == "b\nd\n")
        #expect(result.cursors == cursors((0, 0), (2, 2)))
    }

    @Test func aBlockThatCantMoveStaysWhileTheOthersDo() throws {
        let text = "1\n2\n3\n4\n"
        let result = try #require(lineCommand(text, cursors((0, 0), (6, 6)), .travel) {
            TextEditing.moveLines(in: $0, selection: $1, up: true)
        })
        #expect(result.text == "1\n2\n4\n3\n")
        #expect(result.cursors == cursors((0, 0), (4, 4)))
        #expect(lineCommand("1\n2\n", cursors((0, 0), (0, 1)), .travel) { TextEditing.moveLines(in: $0, selection: $1, up: true) } == nil)
    }

    @Test func aSelectionKnowsItsOwnDirection() {
        #expect(TextCursor(anchor: 5, head: 2).range == NSRange(location: 2, length: 3))
    }

    @Test func combinesEditsWorkedOutAlone() {
        let text = "ab\ncd" as NSString
        let first = TextEditing.newline(in: text, selection: NSRange(location: 1, length: 0), style: .spaces(4))
        let second = TextEditing.newline(in: text, selection: NSRange(location: 4, length: 0), style: .spaces(4))
        let result = MultiCursor.combining([first, second])
        #expect(applied(text as String, result.changes) == "a\nb\nc\nd")
        #expect(result.cursors == cursors((2, 2), (6, 6)))
    }

    private func next(_ needle: String, _ text: String, after: Int, existing: [NSRange] = [], wholeWord: Bool = false) -> Int? {
        MultiCursor.nextOccurrence(of: needle, in: text as NSString, after: after, existing: existing, wholeWord: wholeWord)?.location
    }

    @Test func findsTheNextOne() {
        #expect(next("a", "a b a", after: 1) == 4)
        // Round to the top.
        #expect(next("a", "a b a", after: 5, existing: [NSRange(location: 4, length: 1)]) == 0)
        // Not one that's taken.
        #expect(next("a", "a b a", after: 1, existing: [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)]) == nil)
        // The case has to match.
        #expect(next("foo", "foo Foo foo", after: 3) == 8)
        // A word chosen by ⌘D matches whole.
        #expect(next("in", "in print in", after: 2, wholeWord: true) == 9)
        #expect(next("in", "in print in", after: 2) == 5)
        #expect(next("", "abc", after: 0) == nil)
    }

    @Test func pastingSpreadsLinesOverCursors() {
        #expect(MultiCursor.pieces(forPasting: "a\nb", cursors: 2) == ["a", "b"])
        #expect(MultiCursor.pieces(forPasting: "a\nb", cursors: 3) == ["a\nb", "a\nb", "a\nb"])
        #expect(MultiCursor.pieces(forPasting: "x", cursors: 2) == ["x", "x"])
    }
}
