import Foundation
import Testing
@testable import TiriCore

@Suite struct ChangedTextTests {
    private func applied(_ changes: [TextChange], to text: String) -> String {
        let result = NSMutableString(string: text)
        for change in changes.reversed() { result.replaceCharacters(in: change.range, with: change.text) }
        return result as String
    }

    @Test func separateEditsStaySeparateAndTheRestIsLeftAlone() {
        let old = (1...40).map { "line \($0)\n" }.joined()
        var lines = (1...40).map { "line \($0)\n" }
        lines[2] = "changed 3\n"
        lines.insert("added\n", at: 30)
        lines.remove(at: 38)
        let new = lines.joined()
        let changes = ChangedText.changes(from: old as NSString, to: new as NSString)
        #expect(changes.count == 3)
        #expect(applied(changes, to: old) == new)
        // A cursor on line 20 is still on line 20; one after the added line moves with it.
        let line20 = (old as NSString).range(of: "line 20").location
        #expect((new as NSString).substring(from: ChangedText.moved(line20, by: changes)).hasPrefix("line 20"))
        let line35 = (old as NSString).range(of: "line 35").location
        #expect((new as NSString).substring(from: ChangedText.moved(line35, by: changes)).hasPrefix("line 35"))
    }

    @Test func givesBackTheNewTextWhateverTheChange() {
        let cases: [(String, String)] = [
            ("", "new"), ("old", ""), ("same", "same!"), ("a\nb\nc", "a\nB\nc"), ("a\r\nb\r\nc\r\n", "a\r\nb\r\nx\r\nc\r\n"),
            ("x\r\ny", "x\rz"), ("no newline", "no newline\n"), ("é中文😀\n1\n", "é中文😀\n2\n"), ("a\na\na\n", "a\na\n"),
            ("one\ntwo\n", "zero\none\ntwo\nthree\n"),
        ]
        for (old, new) in cases {
            let changes = ChangedText.changes(from: old as NSString, to: new as NSString)
            #expect(applied(changes, to: old) == new, "\(old.debugDescription) → \(new.debugDescription)")
        }
        #expect(ChangedText.changes(from: "same", to: "same").isEmpty)
    }

    @Test func comparedLineByLineAsGitWould() {
        let old = (1...30).map { "line \($0)\n" }.joined()
        var lines = (1...30).map { "line \($0)\n" }
        lines[1] = "two\n"
        lines[24] = "twenty-five\n"
        let diff = ChangedText.fileDiff(from: old, to: lines.joined())
        #expect(diff.lines.filter { $0.kind == .hunk }.map(\.text) == ["@@ -1,5 +1,5 @@", "@@ -22,7 +22,7 @@"])
        #expect(diff.additions == 2)
        #expect(diff.deletions == 2)
        #expect(diff.lines.first { $0.kind == .added }?.text == "two")
        #expect(diff.lines.first { $0.kind == .removed }?.oldLine == 2)
        // What git would make of the same two files reads the same.
        #expect(diff.lines.filter { $0.kind != .hunk }.count == 5 + 7 + 2)
        #expect(ChangedText.fileDiff(from: old, to: old).isEmpty)
        let fresh = ChangedText.fileDiff(from: "", to: "a\nb\n")
        #expect(fresh.lines.map(\.kind) == [.hunk, .added, .added])
    }

    @Test func quickEvenWhenEveryLineDiffers() {
        // The worst case under the limit, and a big file with a small change, as an agent's rewrite might be.
        let old = (1...3_000).map { "old line \($0)\n" }.joined(), new = (1...3_000).map { "new line \($0)\n" }.joined()
        let big = String(repeating: "let value = something(here)\n", count: 120_000)
        let bigChanged = big.replacingOccurrences(of: "let value = something(here)\nlet", with: "let value = changed\nlet", options: [], range: big.index(big.startIndex, offsetBy: 1_000_000)..<big.index(big.startIndex, offsetBy: 1_000_100))
        let started = Date()
        #expect(applied(ChangedText.changes(from: old as NSString, to: new as NSString), to: old) == new)
        let changes = ChangedText.changes(from: big as NSString, to: bigChanged as NSString)
        #expect(changes.count == 1)
        #expect(applied(changes, to: big) == bigChanged)
        // About 0.4 s alone in a debug build; the bound only catches a quadratic slide, not a busy machine.
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func pastTheLimitTheMiddleIsOneChange() {
        let old = (1...100).map { "\($0)\n" }.joined()
        let new = (1...100).map { $0 % 10 == 0 ? "x\n" : "\($0)\n" }.joined()
        let changes = ChangedText.changes(from: old as NSString, to: new as NSString, lineLimit: 10)
        #expect(changes.count == 1)
        #expect(applied(changes, to: old) == new)
    }
}
