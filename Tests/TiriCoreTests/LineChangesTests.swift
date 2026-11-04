import Foundation
import Testing
@testable import TiriCore

@Suite struct LineChangesTests {
    @Test func headersBecomeMarks() {
        let changes = LineChanges.parse("""
        diff --git a/a b/a
        @@ -3 +3 @@ context
        -old
        +new
        @@ -10,0 +11,2 @@
        +added
        +added
        @@ -20,2 +22,0 @@
        -gone
        -gone
        @@ -1,2 +0,0 @@
        """)
        #expect(changes.lines[3] == .modified)
        #expect(changes.lines[11] == .added)
        #expect(changes.lines[12] == .added)
        #expect(changes.deletions.contains(23))
        #expect(changes.deletions.contains(1))
        #expect(changes.starts == [3, 11, 23, 1])
    }

    @Test func aRealFile() throws {
        let repo = try ScratchRepository()
        try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
        let changes = Git.lineChanges(relative: "a.txt", root: repo.root)
        #expect(changes.lines[2] == .modified)
        #expect(changes.lines[4] == .added)
        try repo.write("new.txt", "x\n")
        #expect(Git.lineChanges(relative: "new.txt", root: repo.root).isEmpty)
    }
}
