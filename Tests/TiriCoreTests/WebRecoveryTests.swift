import Foundation
import Testing
@testable import TiriCore

@Suite struct WebRecoveryTests {
    @Test func aCrashReloadsOnceThenStops() {
        var crashes = CrashRecovery()
        // Long after, it's a new crash and gets another try.
        let answers = [1000.0, 3000, 20000, 24999].map { crashes.shouldReload(at: $0) }
        #expect(answers == [true, false, true, false])
    }

    @Test func rangesAsVideoAsksForThem() {
        #expect(ByteRangeRequest.parse(nil, length: 100) == .whole)
        #expect(ByteRangeRequest.parse("bytes=0-1", length: 100) == .partial(0..<2))
        #expect(ByteRangeRequest.parse("bytes=10-", length: 100) == .partial(10..<100))
        #expect(ByteRangeRequest.parse("bytes=90-500", length: 100) == .partial(90..<100))
        #expect(ByteRangeRequest.parse("bytes=-10", length: 100) == .partial(90..<100))
        #expect(ByteRangeRequest.parse("bytes=-500", length: 100) == .partial(0..<100))
        #expect(ByteRangeRequest.parse("bytes=100-", length: 100) == .unsatisfiable)
        #expect(ByteRangeRequest.parse("bytes=0-", length: 0) == .unsatisfiable)
        #expect(ByteRangeRequest.parse("bytes=5-2", length: 100) == .whole)
        #expect(ByteRangeRequest.parse("bytes=0-1,5-6", length: 100) == .whole)
        #expect(ByteRangeRequest.parse("items=0-1", length: 100) == .whole)
        #expect(ByteRangeRequest.parse("bytes=x-1", length: 100) == .whole)
    }

    private func affect(_ changed: [String], loaded: Set<String> = []) -> Bool {
        LocalPageChanges.affect(page: "/p/site/index.html", folder: "/p/site", loaded: loaded, changed: changed, excluded: ["node_modules", ".git"])
    }

    @Test func onlyThePageAndWhatItLoaded() {
        #expect(affect(["/p/site/index.html"]))
        #expect(affect(["/p/site/css/style.css"], loaded: ["/p/site/css/style.css"]))
        #expect(!affect(["/p/site/notes.txt"]))
        #expect(!affect(["/p/site/node_modules/x/index.js", "/p/site/.git/index"]))
        // Something it loaded counts even in there.
        #expect(affect(["/p/site/node_modules/lib.js"], loaded: ["/p/site/node_modules/lib.js"]))
        // A folder holding what it loaded.
        #expect(affect(["/p/site/css"], loaded: ["/p/site/css/style.css"]))
        #expect(!affect(["/p/site/node_modules"], loaded: ["/p/site/css/style.css"]))
    }

    @Test func aFolderLookedAtAgainCounts() {
        #expect(affect(["/p/site"]))
        #expect(affect(["/p"]))
        #expect(affect([]))
        #expect(!affect(["/p/sitemap.xml"]))
    }

    @Test func headingsAreKeptForGoingToLines() {
        let source = "intro\n\n# One\n\ntext\n\n## Two\n\nmore\n\n# One\n"
        let headings = MarkdownRenderer.headings(in: source)
        #expect(headings.map(\.slug) == ["one", "two", "one-1"])
        for line in 1...12 {
            #expect(MarkdownRenderer.anchor(forLine: line, in: headings) == MarkdownRenderer.anchor(forLine: line, in: source))
        }
        let lines = source.components(separatedBy: "\n")
        #expect(MarkdownRenderer.sourceLines(blockStart: 4, blockEnd: 4, selected: "text", lines: lines)
            == MarkdownRenderer.sourceLines(blockStart: 4, blockEnd: 4, selected: "text", source: source))
    }
}
