import Foundation
import Testing
@testable import TiriCore
@testable import TiriHighlight

private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
private let engine = HighlightEngine(resources: resources)

/// Collects what a document sends, as a viewer would, with its own copy of the lines.
private final class Listener: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int: LineTokens] = [:]
    private var sequence = 0

    func receive(_ update: HighlightDocument.Update) {
        lock.withLock {
            for (offset, line) in update.lines.enumerated() { tokens[update.first + offset] = line }
            sequence = max(sequence, update.sequence)
        }
    }

    func line(_ index: Int) -> LineTokens? { lock.withLock { tokens[index] } }

    func clear() { lock.withLock { tokens = [:] } }

    func kinds(_ index: Int, of line: String) -> [String: TokenKind] {
        guard let entries = self.line(index) else { return [:] }
        let text = line as NSString
        var found: [String: TokenKind] = [:]
        for (position, entry) in entries.enumerated() {
            let start = TokenKind.start(of: entry)
            let end = position + 1 < entries.count ? TokenKind.start(of: entries[position + 1]) : text.length
            guard end > start, end <= text.length else { continue }
            found[text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)] = TokenKind.of(entry)
        }
        return found
    }
}

private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite(.serialized) struct HighlightEngineTests {
    @Test func theEngineStartsOnAQueueWithNoRunLoop() {
        #expect(engine.queue.sync { engine.load() })
    }

    @Test func kindsComeOutOfARealGrammar() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.rust") { listener.receive($0) }
        defer { document.close() }
        let line = "fn main() { let x: i32 = 42; /* why */ println!(\"hi\"); }"
        document.replaceAll(line, sequence: 0)
        #expect(await waitUntil { listener.line(0) != nil })
        let kinds = listener.kinds(0, of: line)
        #expect(kinds["fn"] == .keyword)
        #expect(kinds["main"] == .function)
        #expect(kinds["i32"] == .type)
        #expect(kinds["42"] == .number)
        #expect(kinds["/* why */"] == .comment)
        #expect(kinds["\"hi\""] == .string)
    }

    @Test func typingRedoesOnlyTheLineItIsOn() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.python") { listener.receive($0) }
        defer { document.close() }
        let text = (0..<2_000).map { "value_\($0) = \($0)" }.joined(separator: "\n")
        document.replaceAll(text, sequence: 0)
        #expect(await waitUntil { listener.line(1_999) != nil })
        listener.clear()
        let at = (text as NSString).range(of: "value_1000").location
        document.edit(range: NSRange(location: at, length: 0), replacement: "x", sequence: 1)
        #expect(await waitUntil { listener.line(1_000) != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(listener.line(1_001) == nil || listener.line(1_002) == nil)
        #expect(listener.line(1_500) == nil)
        #expect(listener.line(1_999) == nil)
    }

    @Test func openingAStringGoesOnUntilItCloses() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.python") { listener.receive($0) }
        defer { document.close() }
        let text = "a = 1\nb = 2\nc = 3\nd = 4\n"
        document.replaceAll(text, sequence: 0)
        #expect(await waitUntil { listener.line(3) != nil })
        #expect(listener.kinds(2, of: "c = 3")["3"] == .number)
        document.edit(range: NSRange(location: 0, length: 0), replacement: "\"\"\"\n", sequence: 1)
        #expect(await waitUntil { listener.kinds(3, of: "c = 3")["c = 3"] == .string })
    }

    @Test func linesInsertedAndRemovedStayInStep() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.python") { listener.receive($0) }
        defer { document.close() }
        document.replaceAll("x = 1\ny = 2\n", sequence: 0)
        #expect(await waitUntil { listener.line(1) != nil })
        listener.clear()
        document.edit(range: NSRange(location: 6, length: 0), replacement: "# one\n# two\n", sequence: 1)
        #expect(await waitUntil { listener.kinds(2, of: "# two")["# two"] == .comment })
        listener.clear()
        document.edit(range: NSRange(location: 6, length: 12), replacement: "", sequence: 2)
        #expect(await waitUntil { listener.line(1) != nil })
        #expect(listener.kinds(1, of: "y = 2")["2"] == .number)
    }

    @Test func aLineFarAheadGetsAGuessFirst() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.python") { listener.receive($0) }
        defer { document.close() }
        let text = String(repeating: "# a comment\n", count: 200_000)
        document.show(lines: 150_000..<150_060)
        document.replaceAll(text, sequence: 0)
        #expect(await waitUntil(1) { listener.line(150_030) != nil })
        #expect(listener.line(100_000) == nil)
    }

    @Test func everyGrammarLoadsAndTokenizes() {
        let sample = "function main(a, b) { // comment\n  let x = \"hi\" + 42; if (x) return x; }\nclass Foo: pass\n# note\n<div a=\"1\">t</div>\n"
        var failures: [String] = []
        var count = 0
        for language in LanguageCatalog.all {
            guard let scope = language.grammar else { continue }
            count += 1
            let good: Bool = engine.queue.sync {
                let id = engine.newID()
                guard engine.open(id: id, scope: scope) else { return false }
                defer { engine.close(id: id) }
                return engine.tokenize(id: id, start: 0, text: sample, count: 6, budget: 0, dirtyUntil: 0, peek: false).lines.count == 6
            }
            if !good { failures.append(language.id) }
        }
        #expect(count > 220)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func pagesGetMarkedUpCode() {
        let html = engine.html(code: "let a = \"<b>\" // note\nlet b = 2\n", language: "swift")
        #expect(html?.contains("<span class=\"tk-keyword\">let</span>") == true)
        #expect(html?.contains("&lt;b&gt;") == true)
        #expect(html?.contains("tk-comment") == true)
        #expect(html?.contains("\n") == true)
        #expect(engine.html(code: "x", language: "not-a-language") == nil)
        #expect(engine.html(code: "plain words", language: "txt") == nil)
    }

    @Test func aVSCodeGrammarFromElsewhereWouldWorkTheSame() async {
        let listener = Listener()
        let document = HighlightDocument(engine: engine, scope: "source.gleam") { listener.receive($0) }
        defer { document.close() }
        let line = "pub fn main() { io.println(\"hello\") }"
        document.replaceAll(line, sequence: 0)
        #expect(await waitUntil { listener.line(0) != nil })
        #expect(listener.kinds(0, of: line)["fn"] == .keyword)
    }
}

@Suite struct TextMirrorTests {
    @Test func saysWhichLinesAnEditTouched() {
        let mirror = TextMirror("a\nb\nc\n")
        #expect(mirror.apply(range: NSRange(location: 2, length: 0), replacement: "x") == LineEdit(start: 1, removed: 0, inserted: 0))
        #expect(mirror.text == "a\nxb\nc\n")
        #expect(mirror.apply(range: NSRange(location: 2, length: 0), replacement: "1\n2\n") == LineEdit(start: 1, removed: 0, inserted: 2))
        #expect(mirror.lines.count == 6)
        #expect(mirror.apply(range: NSRange(location: 0, length: 2), replacement: "") == LineEdit(start: 0, removed: 1, inserted: 0))
    }

    @Test func aCarriageReturnMeetingANewlineIsOneLineEnding() {
        let mirror = TextMirror("a\rb")
        #expect(mirror.lines.count == 2)
        let edit = mirror.apply(range: NSRange(location: 2, length: 0), replacement: "\n")
        #expect(mirror.lines.count == 2)
        #expect(edit.start == 0)
    }

    @Test func positionsAreInLinesAndUTF16() {
        let mirror = TextMirror("😀a\nb")
        #expect(mirror.position(of: 3).line == 0)
        #expect(mirror.position(of: 3).character == 3)
        #expect(mirror.position(of: 4).line == 1)
    }
}
