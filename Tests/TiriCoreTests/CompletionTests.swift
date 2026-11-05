import Foundation
import Testing
@testable import TiriCore

@Suite struct CompletionMatchingTests {
    private func top(_ query: String, _ labels: [String], recent: [String] = [], nearby: Set<String> = []) -> [String] {
        CompletionRanker.rank(labels.map { CompletionItem(label: $0) }, query: query, recent: recent, nearby: nearby).map(\.item.label)
    }

    @Test func camelCaseFindsIt() {
        let found = CompletionMatcher.match(query: "cra", in: "createApplication")
        #expect(found != nil)
        #expect(found?.positions == [0, 1, 6])
        #expect(CompletionMatcher.match(query: "cA", in: "createApplication")?.positions == [0, 6])
        #expect(CompletionMatcher.match(query: "xyz", in: "createApplication") == nil)
    }

    @Test func underscoresCountAsWordsToo() {
        #expect(CompletionMatcher.match(query: "ca", in: "create_app")?.positions == [0, 7])
    }

    @Test func aStartBeatsTheMiddleAndARunBeatsScatteredLetters() {
        #expect(top("app", ["wrapper", "appendChild", "myApp"]) == ["appendChild", "myApp", "wrapper"])
        #expect(top("str", ["substring", "string"]).first == "string")
    }

    @Test func caseDoesNotHaveToMatch() {
        #expect(CompletionMatcher.match(query: "HTTP", in: "httpClient") != nil)
        #expect(CompletionMatcher.match(query: "http", in: "HTTPClient") != nil)
    }

    @Test func whatYouUsedRecentlyAndNamesNearbyComeFirst() {
        #expect(top("val", ["value", "validate"]).first == "validate")
        #expect(top("val", ["value", "validate"], recent: ["value"]).first == "value")
        #expect(top("val", ["value", "validate"], nearby: ["value"]).first == "value")
    }

    @Test func ifScoresTieTheServersOrderDecides() {
        let items = [CompletionItem(label: "bb", sortText: "2"), CompletionItem(label: "ba", sortText: "9"), CompletionItem(label: "bc", sortText: "1")]
        #expect(CompletionRanker.rank(items, query: "b").map(\.item.label) == ["bc", "bb", "ba"])
    }

    @Test func tenThousandNamesAreQuick() {
        let items = (0..<10_000).map { CompletionItem(label: "someLongFunctionName\($0)", isFromServer: false) }
        let start = Date()
        let ranked = CompletionRanker.rank(items, query: "sfn12")
        #expect(!ranked.isEmpty)
        // Unoptimized here. The budget is checked for real in a release build.
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite struct WordIndexTests {
    @Test func findsNamesOnly() {
        let words = WordIndex.words(in: "let fooBar = 12 + foo_baz; // x café 名字。值 7up")
        #expect(words.contains("fooBar"))
        #expect(words.contains("foo_baz"))
        #expect(words.contains("let"))
        #expect(words.contains("café"))
        #expect(words.contains("名字"))
        #expect(!words.contains("12"))
        #expect(!words.contains("x"))
        #expect(!words.contains("7up"))
        #expect(words.contains("up"))
    }

    @Test func thePrefixIsTheNameBehindTheCursor() {
        let text = "foo.barBaz(12ab" as NSString
        #expect(WordIndex.prefix(in: text, before: 7) == NSRange(location: 4, length: 3))
        #expect(WordIndex.prefix(in: text, before: 4) == nil)
        #expect(WordIndex.prefix(in: text, before: 15) == NSRange(location: 13, length: 2))
    }
}

@Suite struct CompletionAnswerTests {
    private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test func aPlainListAndACompletionListBothRead() {
        #expect(LSP.completions(from: json(#"[{"label":"a"}]"#)).items.map(\.label) == ["a"])
        let list = LSP.completions(from: json(#"{"isIncomplete":true,"items":[{"label":"b","kind":3,"detail":"fn()"}]}"#))
        #expect(list.isIncomplete)
        #expect(list.items.first?.kind == .function)
        #expect(list.items.first?.detail == "fn()")
    }

    @Test func editsAndImportsAreKept() {
        let item = LSP.completions(from: json(#"""
        [{"label":"foo","filterText":"xfoo","sortText":"1","textEdit":{"range":{"start":{"line":3,"character":1},"end":{"line":3,"character":4}},"newText":"foo()"},
          "additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import foo\n"}]}]
        """#)).items.first
        #expect(item?.textToInsert == "foo()")
        #expect(item?.replaceRange == LSPRange(startLine: 3, startCharacter: 1, endLine: 3, endCharacter: 4))
        #expect(item?.additionalEdits.first?.text == "import foo\n")
        #expect(item?.matchText == "xfoo")
    }

    @Test func insertAndReplaceEditsUseTheReplaceRange() {
        let item = LSP.completions(from: json(#"""
        [{"label":"a","textEdit":{"newText":"a","insert":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"replace":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}}]
        """#)).items.first
        #expect(item?.replaceRange?.endCharacter == 2)
    }

    @Test func sharedDefaultsApply() {
        let item = LSP.completions(from: json(#"""
        {"isIncomplete":false,"itemDefaults":{"editRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}},"items":[{"label":"a","textEditText":"aa"}]}
        """#)).items.first
        #expect(item?.replaceRange?.startLine == 1)
        #expect(item?.textToInsert == "aa")
    }

    @Test func paddingOnALabelGoes() {
        #expect(LSP.completions(from: json(#"[{"label":" across"}]"#)).items.first?.label == "across")
    }

    @Test func aModuleNameTellsApartThingsWithTheSameName() {
        let item = LSP.completions(from: json(#"[{"label":"access","detail":"Auto-import","labelDetails":{"description":"os"}}]"#)).items.first
        #expect(item?.detail == "os")
    }

    @Test func aSnippetArrivesAsPlainText() {
        #expect(Snippets.plainText(of: "foo(${1:bar}, $2)$0") == "foo(bar, )")
        #expect(Snippets.plainText(of: "${1|one,two|} \\$x ${TM_FILENAME}") == "one $x ")
        let item = LSP.completions(from: json(#"[{"label":"f","insertText":"f($1)","insertTextFormat":2}]"#)).items.first
        #expect(item?.textToInsert == "f()")
    }

    @Test func whatServersCanDo() {
        let capabilities = json(#"{"textDocumentSync":{"change":2},"completionProvider":{"triggerCharacters":[".",":"],"resolveProvider":true}}"#)
        let abilities = LSP.ServerAbilities(capabilities: capabilities)
        #expect(abilities.syncKind == 2)
        #expect(abilities.completes)
        #expect(abilities.triggerCharacters == [".", ":"])
        #expect(abilities.canResolve)
        #expect(LSP.ServerAbilities(capabilities: json(#"{"textDocumentSync":1}"#)).syncKind == 1)
        #expect(!LSP.ServerAbilities(capabilities: json("{}")).completes)
    }

    @Test func anEditIsDescribedBeforeItHappens() {
        let mirror = TextMirror("ab\ncd😀ef\n")
        let change = LSP.contentChange(range: NSRange(location: 7, length: 1), text: "X", in: mirror)
        #expect(change["range"]?["start"]?["line"]?.intValue == 1)
        #expect(change["range"]?["start"]?["character"]?.intValue == 4)
        #expect(change["range"]?["end"]?["character"]?.intValue == 5)
        #expect(change["text"]?.stringValue == "X")
    }
}

@Suite struct CompletionEditTests {
    @Test func oneCursorWithAnImportAbove() {
        let made = CompletionEdit.make(replacing: [NSRange(location: 10, length: 2)], with: "foobar", extra: [TextChange(range: NSRange(location: 0, length: 0), text: "import x\n")])
        #expect(made.changes.map(\.text) == ["import x\n", "foobar"])
        #expect(made.carets == [10 + 9 + 6])
    }

    @Test func everyCursorGetsIt() {
        let made = CompletionEdit.make(replacing: [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)], with: "abc", extra: [])
        #expect(made.changes.count == 2)
        #expect(made.carets == [5, 13])
    }

    private func applied(_ text: String, _ made: (changes: [TextChange], carets: [Int])) -> String {
        let result = NSMutableString(string: text)
        for change in made.changes.reversed() { result.replaceCharacters(in: change.range, with: change.text) }
        return result as String
    }

    @Test func anImportWhereTheNameStartsGoesBeforeIt() {
        let made = CompletionEdit.make(replacing: [NSRange(location: 4, length: 2)], with: "fooBar", extra: [TextChange(range: NSRange(location: 4, length: 0), text: "import b\n")])
        #expect(applied("a\n\n\nfo", made) == "a\n\n\nimport b\nfooBar")
        #expect(made.carets == [4 + 9 + 6])
    }

    @Test func twoCursorsInOneNameDontOverlap() {
        let ranges = CompletionEdit.ranges(heads: [1, 3], left: 3, right: 0, wordStarts: [0, 0], length: 3)
        #expect(ranges == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 2)])
        #expect(applied("bob", CompletionEdit.make(replacing: ranges, with: "cat", extra: [])) == "catcat")
    }

    @Test func aRangeNeverPassesTheEnd() {
        #expect(CompletionEdit.ranges(heads: [3], left: 1, right: 9, wordStarts: nil, length: 4) == [NSRange(location: 2, length: 2)])
        #expect(CompletionEdit.ranges(heads: [2, 5], left: 0, right: 9, wordStarts: nil, length: 8) == [NSRange(location: 2, length: 3), NSRange(location: 5, length: 3)])
    }

    @Test func sameNamesFromDifferentModulesAreDifferent() {
        #expect(CompletionItem(label: "useState", detail: "react").identity != CompletionItem(label: "useState", detail: "preact").identity)
    }

    @Test func extraEditsThatOverlapAreDropped() {
        let made = CompletionEdit.make(replacing: [NSRange(location: 2, length: 3)], with: "a", extra: [TextChange(range: NSRange(location: 3, length: 1), text: "z")])
        #expect(made.changes.count == 1)
    }
}
