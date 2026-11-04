import Foundation
import Testing
@testable import TiriCore

@Suite struct DiffRowsTests {
    private func lines(_ kinds: String) -> [DiffLine] {
        var (old, new) = (1, 1)
        return kinds.map { kind in
            switch kind {
            case "-": defer { old += 1 }; return DiffLine(kind: .removed, oldLine: old, text: "r")
            case "+": defer { new += 1 }; return DiffLine(kind: .added, newLine: new, text: "a")
            case "@": return DiffLine(kind: .hunk, text: "@@")
            default: defer { old += 1; new += 1 }; return DiffLine(kind: .context, oldLine: old, newLine: new, text: "c")
            }
        }
    }

    @Test func changesLineUpWithBlanksForTheShorterSide() {
        let rows = DiffRows.sideBySide(lines("@c--+c++c"))
        #expect(rows == [
            SideBySideRow(left: 0, right: 0), SideBySideRow(left: 1, right: 1),
            SideBySideRow(left: 2, right: 4), SideBySideRow(left: 3, right: nil),
            SideBySideRow(left: 5, right: 5),
            SideBySideRow(left: nil, right: 6), SideBySideRow(left: nil, right: 7),
            SideBySideRow(left: 8, right: 8),
        ])
    }

    @Test func aChangeAtTheEndIsntLost() {
        #expect(DiffRows.sideBySide(lines("c-+")) == [SideBySideRow(left: 0, right: 0), SideBySideRow(left: 1, right: 2)])
    }

    @Test func removedRowsPairWithWhatTheyBecame() {
        let pairs = DiffRows.pairs(lines("c--+c"))
        #expect(pairs[1] == 3)
        #expect(pairs[3] == 1)
        #expect(pairs[2] == nil)
        #expect(pairs[0] == nil)
    }

    @Test func eachRunOfChangesHasOneStart() {
        #expect(DiffRows.changeStarts(lines("c-+c@c+-c")) == [1, 6])
        #expect(DiffRows.changeStarts(lines("cc")).isEmpty)
    }

    @Test func aFilesLineFindsItsChange() {
        // Rows:  0 @, 1 c(1), 2 -, 3 +(2), 4 c(3), 5 +(4)
        let rows = lines("@c-+c+")
        #expect(DiffRows.changeRow(atOrAfterLine: 1, in: rows) == 2)
        #expect(DiffRows.changeRow(atOrAfterLine: 2, in: rows) == 2)
        #expect(DiffRows.changeRow(atOrAfterLine: 4, in: rows) == 5)
        #expect(DiffRows.changeRow(atOrAfterLine: 9, in: rows) == nil)
    }
}

@Suite struct WordDiffTests {
    private func parts(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test func onlyTheChangedWord() {
        let old = "let greeter = Greeter(name: \"world\")"
        let new = "let greeter = Greeter(name: \"everyone\")"
        let ranges = WordDiff.ranges(old: old, new: new)
        #expect(parts(old, ranges.old) == ["world"])
        #expect(parts(new, ranges.new) == ["everyone"])
    }

    @Test func anInsertionHasNothingOnTheOldSide() {
        let ranges = WordDiff.ranges(old: "return name", new: "return name + suffix")
        #expect(ranges.old.isEmpty)
        #expect(parts("return name + suffix", ranges.new) == [" + suffix"])
    }

    @Test func nothingInCommonGetsNoHighlight() {
        #expect(WordDiff.ranges(old: "completely different words here", new: "nothing the same at all, honestly") == WordDiff.Ranges())
    }

    @Test func aVeryLongLineIsNotCompared() {
        let long = String(repeating: "x ", count: WordDiff.longestLine)
        #expect(WordDiff.ranges(old: long, new: long + "y") == WordDiff.Ranges())
    }

    @Test func offsetsAreInUTF16() {
        let old = "😀 said hello"
        let new = "😀 said goodbye"
        let ranges = WordDiff.ranges(old: old, new: new)
        #expect(parts(old, ranges.old) == ["hello"])
        #expect(parts(new, ranges.new) == ["goodbye"])
    }

    @Test func identicalLinesHaveNothing() {
        #expect(WordDiff.ranges(old: "same", new: "same") == WordDiff.Ranges())
    }

    @Test func aSpaceBetweenChangedWordsJoinsThem() {
        let ranges = WordDiff.ranges(old: "a one two b c d e f", new: "a uno dos b c d e f")
        #expect(parts("a one two b c d e f", ranges.old) == ["one two"])
    }
}
