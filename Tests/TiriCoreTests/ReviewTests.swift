import Foundation
import Testing
@testable import TiriCore

@Suite struct ReviewLocatorTests {
    private func comment(_ first: Int?, _ last: Int? = nil, excerpt: String? = nil) -> ReviewComment {
        ReviewComment(path: "/p/a.swift", firstLine: first, lastLine: last, excerpt: excerpt, text: "x")
    }

    @Test func staysWhenNothingMoved() {
        #expect(ReviewLocator.place(of: comment(2, excerpt: "b"), in: "a\nb\nc\n") == .lines(2...2))
    }

    @Test func followsLinesAnAgentMoved() {
        #expect(ReviewLocator.place(of: comment(2, 3, excerpt: "b\nc\n"), in: "new\nnew\na\nb\nc\n") == .lines(4...5))
    }

    @Test func picksTheCopyNearestToWhereItWas() {
        let text = "x\nother\nother\nother\nx\nother\n"
        #expect(ReviewLocator.place(of: comment(1, excerpt: "x"), in: text) == .lines(1...1))
        #expect(ReviewLocator.place(of: comment(6, excerpt: "x"), in: text) == .lines(5...5))
    }

    @Test func saysWhenTheLinesAreGone() {
        #expect(ReviewLocator.place(of: comment(1, excerpt: "gone"), in: "a\nb\n") == .gone)
        #expect(ReviewLocator.place(of: comment(1, 3, excerpt: "a\nb\nc"), in: "a\n") == .gone)
    }

    @Test func aCommentWithoutLinesIsOnTheWholeFile() {
        #expect(ReviewLocator.place(of: comment(nil), in: "a\n") == .wholeFile)
    }

    @Test func aRemovedRowHasNoExcerptAndKeepsItsLine() {
        #expect(ReviewLocator.place(of: comment(7), in: "a\n") == .lines(7...7))
    }
}

@Suite struct ReviewMessageTests {
    @Test func listsEachCommentWithItsCode() {
        let comments = [
            ReviewComment(path: "/p/src/a.swift", firstLine: 2, excerpt: "let b = 2", text: "Why 2?"),
            ReviewComment(path: "/p/b.md", text: "Too long"),
        ]
        let files = ["/p/src/a.swift": "let a = 1\nlet b = 2\n", "/p/b.md": "words\n"]
        let message = ReviewMessage.text(comments: comments, cwd: "/p", fileText: { files[$0] })
        #expect(message == """
        Review comments on your work. Please go through each one:

        1. src/a.swift:2
        ```swift
        let b = 2
        ```
        Why 2?

        2. b.md
        Too long

        """)
    }

    @Test func oneCommentReadsAsOne() {
        let message = ReviewMessage.text(comments: [ReviewComment(path: "/p/a", text: "Hm")], cwd: "/p", fileText: { _ in "" })
        #expect(message.hasPrefix("A review comment on your work:"))
    }

    @Test func usesTheLinesAsTheyAreNow() {
        let comment = ReviewComment(path: "/p/a.py", firstLine: 1, excerpt: "b", text: "x")
        let message = ReviewMessage.text(comments: [comment], cwd: "/p", fileText: { _ in "a\na\nb\n" })
        #expect(message.contains("1. a.py:3\n"))
    }

    @Test func saysWhenTheCodeHasChanged() {
        let comment = ReviewComment(path: "/p/a.py", firstLine: 1, excerpt: "old", text: "x")
        let message = ReviewMessage.text(comments: [comment], cwd: "/p", fileText: { _ in "new\n" })
        #expect(message.contains("a.py (this code has changed since the comment)\n```py\nold\n```"))
    }

    @Test func aFileThatsGoneDoesNotLoseTheComment() {
        let comment = ReviewComment(path: "/p/a.py", firstLine: 1, excerpt: "old", text: "keep this")
        let message = ReviewMessage.text(comments: [comment], cwd: "/p", fileText: { _ in nil })
        #expect(message.contains("changed since the comment"))
        #expect(message.contains("keep this"))
    }

    @Test func aDiffQuoteStaysADiff() {
        let comment = ReviewComment(path: "/p/a.py", firstLine: 1, excerpt: "new", quote: "-old\n+new", quoteIsDiff: true, text: "x")
        let message = ReviewMessage.text(comments: [comment], cwd: "/p", fileText: { _ in "new\n" })
        #expect(message.contains("```diff\n-old\n+new\n```"))
    }

    @Test func aPathOutsideTheSessionsFolderStaysWhole() {
        #expect(ReviewMessage.relative("/other/a", to: "/p") == "/other/a")
        #expect(ReviewMessage.relative("/p/a", to: "/p/") == "a")
        #expect(ReviewMessage.relative("/pp/a", to: "/p") == "/pp/a")
    }

    @Test func aFenceOutlastsBackticksInTheCode() {
        #expect(ReviewMessage.fenced("a ```` b", language: "md").hasPrefix("`````md\n"))
    }

    @Test func aLongExcerptIsCut() {
        let text = (1...40).map(String.init).joined(separator: "\n")
        let fenced = ReviewMessage.fenced(text, language: "")
        #expect(fenced.contains("\n30\n"))
        #expect(!fenced.contains("\n31\n"))
        #expect(fenced.contains("… 10 more lines"))
    }
}

@Suite struct ReviewPersistenceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tiri-review-\(UUID().uuidString)")
    }

    @Test func aWorkspaceSavedBeforeCommentsExistedStillLoads() throws {
        let directory = directory()
        let store = WorkspaceStore(directory: directory)
        let workspace = Workspace(name: "old")
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let file = directory.appendingPathComponent("layouts/\(workspace.id).json")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("review"))
        #expect(store.load()?.workspaces.first?.review.isEmpty == true)
    }

    @Test func commentsComeBackThroughTheRealStore() throws {
        let store = WorkspaceStore(directory: directory())
        var workspace = Workspace(name: "w")
        workspace.review.append(ReviewComment(path: "/a", firstLine: 3, excerpt: "x", text: "hello"))
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let loaded = store.load()?.workspaces.first
        #expect(loaded?.review.first?.text == "hello")
        #expect(loaded?.reviewComments(on: "/a").count == 1)
        #expect(loaded?.reviewComments(on: "/b").isEmpty == true)
    }
}

@Suite struct ReviewCLITests {
    private func parse(_ arguments: [String]) throws -> CLIParser.Parsed {
        try CLIParser.parse(arguments, environment: .init(cwd: "/p", itemID: nil, fileExists: { _ in false }, readStdin: { Data() }))
    }

    @Test func addsARange() throws {
        guard case .request(let request, _) = try parse(["review", "add", "src/a.ts:12-20", "Not", "this"]) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.cmd == "review.add")
        #expect(request.args["path"]?.stringValue == "/p/src/a.ts")
        #expect(request.args["line"]?.intValue == 12)
        #expect(request.args["lastLine"]?.intValue == 20)
        #expect(request.args["text"]?.stringValue == "Not this")
    }

    @Test func addsAWholeFile() throws {
        guard case .request(let request, _) = try parse(["review", "add", "a.ts", "Hm"]) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.args["line"] == nil)
    }

    @Test func sendsToOneSession() throws {
        guard case .request(let request, _) = try parse(["review", "send", "--to", "i-1"]) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.cmd == "review.send")
        #expect(request.args["item"]?.stringValue == "i-1")
    }

    @Test func refusesNonsense() {
        #expect(throws: CLIParser.UsageError.self) { try parse(["review", "add", "a.ts"]) }
        #expect(throws: CLIParser.UsageError.self) { try parse(["review", "nope"]) }
    }
}
