import Foundation
import Testing
@testable import TiriCore

/// A pretend disk, so resolution is tested without touching the real one.
private let disk: [String: Bool] = [
    "/repo": true,
    "/repo/README.md": false,
    "/repo/src": true,
    "/repo/src/main.swift": false,
    "/repo/src/app.ts": false,
    "/repo/My Documents": true,
    "/repo/My Documents/report final.pdf": false,
    "/repo/app/(tabs)/index.tsx": false,
    "/repo/Makefile": false,
    "/repo/foo.swift": false,
    "/repo/foo(1).txt": false,
    "/repo/a/foo.swift": false,
    "/repo/1/src/main.swift": false,
    "/other": true,
    "/other/lib.py": false,
    "/abs/dir": true,
    "/abs/dir/file.txt": false,
    "/Users/me/notes.md": false,
    "/Users/me/projects": true,
]

private func resolver(cwd: String? = "/repo", folders: [String] = ["/other"]) -> PathResolver {
    PathResolver(cwd: cwd, workspaceFolders: folders, home: "/Users/me", probe: { disk[$0] })
}

/// Column of the first occurrence of `needle`, plus a small offset so it lands inside it.
private func column(of needle: String, in line: String) -> Int {
    let stripped = PathLinkDetector.stripANSI(line)
    guard let range = stripped.range(of: needle) else { return 0 }
    return stripped.distance(from: stripped.startIndex, to: range.lowerBound) + 1
}

struct LinkCase: Sendable, CustomTestStringConvertible {
    var line: String
    var hover: String
    var path: String?
    var isDirectory: Bool = false
    var lineNumber: Int? = nil
    var col: Int? = nil
    var testDescription: String { line }
}

@Suite struct PathResolutionTable {
    static let cases: [LinkCase] = [
        // Plain and relative
        LinkCase(line: "see README.md for details", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "./src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "../repo/README.md", hover: "README", path: "/repo/README.md"),
        // Absolute and home
        LinkCase(line: "wrote /abs/dir/file.txt", hover: "file.txt", path: "/abs/dir/file.txt"),
        LinkCase(line: "~/notes.md is ready", hover: "notes", path: "/Users/me/notes.md"),
        // Directories
        LinkCase(line: "cd src", hover: "src", path: "/repo/src", isDirectory: true),
        LinkCase(line: "created src/ directory", hover: "src", path: "/repo/src", isDirectory: true),
        LinkCase(line: "/abs/dir/ exists", hover: "abs", path: "/abs/dir", isDirectory: true),
        LinkCase(line: "~/projects", hover: "projects", path: "/Users/me/projects", isDirectory: true),
        // Line and column
        LinkCase(line: "src/main.swift:42", hover: "main", path: "/repo/src/main.swift", lineNumber: 42),
        LinkCase(line: "src/main.swift:42:7", hover: "main", path: "/repo/src/main.swift", lineNumber: 42, col: 7),
        LinkCase(line: "src/main.swift:42:7: error: nope", hover: "main", path: "/repo/src/main.swift", lineNumber: 42, col: 7),
        LinkCase(line: "src/app.ts(12,5): error TS2322", hover: "app", path: "/repo/src/app.ts", lineNumber: 12, col: 5),
        LinkCase(line: "src/app.ts#L9", hover: "app", path: "/repo/src/app.ts", lineNumber: 9),
        LinkCase(line: "File \"src/app.ts\", line 88, in foo", hover: "app", path: "/repo/src/app.ts", lineNumber: 88),
        // Trailing punctuation
        LinkCase(line: "Updated README.md.", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "Updated README.md, and more", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "(see src/main.swift)", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "[src/main.swift]", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "at src/main.swift:42.", hover: "main", path: "/repo/src/main.swift", lineNumber: 42),
        LinkCase(line: "open README.md:", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "really src/main.swift?", hover: "main", path: "/repo/src/main.swift"),
        // Quotes and spaces
        LinkCase(line: "\"My Documents/report final.pdf\"", hover: "report", path: "/repo/My Documents/report final.pdf"),
        LinkCase(line: "'My Documents/report final.pdf' saved", hover: "final", path: "/repo/My Documents/report final.pdf"),
        LinkCase(line: "`src/main.swift`", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "saved to My\\ Documents/report\\ final.pdf now", hover: "report", path: "/repo/My Documents/report final.pdf"),
        LinkCase(line: "saved My Documents/report final.pdf", hover: "report", path: "/repo/My Documents/report final.pdf"),
        // Brackets that belong to the name
        LinkCase(line: "app/(tabs)/index.tsx", hover: "index", path: "/repo/app/(tabs)/index.tsx"),
        LinkCase(line: "see foo(1).txt", hover: "foo", path: "/repo/foo(1).txt"),
        // ANSI noise
        LinkCase(line: "\u{1B}[32msrc/main.swift\u{1B}[0m:\u{1B}[33m42\u{1B}[0m", hover: "main", path: "/repo/src/main.swift", lineNumber: 42),
        LinkCase(line: "\u{1B}[1;31merror\u{1B}[0m in \u{1B}[4mREADME.md\u{1B}[24m", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "\u{1B}]8;;file:///x\u{07}README.md\u{1B}]8;;\u{07}", hover: "README", path: "/repo/README.md"),
        // Diffs and tool output
        LinkCase(line: "+++ b/src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "--- a/README.md", hover: "README", path: "/repo/README.md"),
        LinkCase(line: "  ⎿  Wrote src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "│ src/main.swift │", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "--file=src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "file:///abs/dir/file.txt", hover: "file.txt", path: "/abs/dir/file.txt"),
        // ls-style bare names need the existence check to work
        LinkCase(line: "Makefile  README.md  src", hover: "Makefile", path: "/repo/Makefile"),
        LinkCase(line: "Makefile  README.md  src", hover: "src", path: "/repo/src", isDirectory: true),
        // Falls back to workspace folders
        LinkCase(line: "lib.py", hover: "lib", path: "/other/lib.py"),
        // VS Code's location formats: glued to the path
        LinkCase(line: "src/app.ts:12:const x = 1", hover: "app", path: "/repo/src/app.ts", lineNumber: 12),
        LinkCase(line: "src/app.ts:12:3:const x", hover: "app", path: "/repo/src/app.ts", lineNumber: 12, col: 3),
        LinkCase(line: "foo.swift:12:in `bar'", hover: "foo", path: "/repo/foo.swift", lineNumber: 12),
        LinkCase(line: "foo.swift:339:12-789", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift:339.12-341.789", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift#339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift#339:12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift(339, 12)", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift(339:12)", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift[339,12]", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift[339]", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift:line 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        // …and separate from it
        LinkCase(line: "foo.swift 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift, 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift (339)", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift, line 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift on line 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "foo.swift 339:12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift (339,12)", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift: (339, 12)", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift: line 339, col 12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift line 339 column 12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "foo.swift\u{A0}339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "\"foo.swift\",339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "\"foo.swift\",339:12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "\"foo.swift\":line 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "\"foo.swift\" on line 339", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "\"foo.swift\", lines 339-341", hover: "foo", path: "/repo/foo.swift", lineNumber: 339),
        LinkCase(line: "\"foo.swift\", line 339, col 12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        LinkCase(line: "\"foo.swift\", line 339, character 12", hover: "foo", path: "/repo/foo.swift", lineNumber: 339, col: 12),
        // Query strings and climbing
        LinkCase(line: "foo.swift?raw", hover: "foo", path: "/repo/foo.swift"),
        LinkCase(line: "../src/app.ts", hover: "app", path: "/repo/src/app.ts"),
        // Diff prefixes only count on diff headers, where they beat a literal match
        LinkCase(line: "--- i/src/app.ts", hover: "app", path: "/repo/src/app.ts"),
        LinkCase(line: "--- w/src/app.ts", hover: "app", path: "/repo/src/app.ts"),
        LinkCase(line: "--- a/foo.swift", hover: "foo", path: "/repo/foo.swift"),
        LinkCase(line: "diff --git 1/src/main.swift 2/src/main.swift", hover: "main", path: "/repo/src/main.swift"),
        LinkCase(line: "see a/foo.swift here", hover: "foo", path: "/repo/a/foo.swift"),
        // Things that aren't there
        LinkCase(line: "nothing/here.swift", hover: "here", path: nil),
        LinkCase(line: "and/or something", hover: "and", path: nil),
        LinkCase(line: "https://example.com/README.md", hover: "example", path: nil),
    ]

    @Test(arguments: Self.cases)
    func resolves(_ testCase: LinkCase) {
        let result = resolver().resolve(atColumn: column(of: testCase.hover, in: testCase.line), in: testCase.line)
        #expect(result?.path == testCase.path)
        if testCase.path != nil {
            #expect(result?.isDirectory == testCase.isDirectory)
            #expect(result?.line == testCase.lineNumber)
            #expect(result?.col == testCase.col)
        }
    }

    @Test func cwdWinsOverWorkspaceFolders() {
        let resolver = PathResolver(cwd: "/repo", workspaceFolders: ["/other"], home: "/h") { path in
            path == "/repo/shared.txt" || path == "/other/shared.txt" ? false : nil
        }
        #expect(resolver.resolve(atColumn: 1, in: "shared.txt")?.path == "/repo/shared.txt")
    }

    @Test func noCwdUsesFolders() {
        let result = resolver(cwd: nil, folders: ["/repo"]).resolve(atColumn: 1, in: "README.md")
        #expect(result?.path == "/repo/README.md")
    }

    @Test func outOfBoundsColumnIsNil() {
        #expect(resolver().resolve(atColumn: 99, in: "README.md") == nil)
        #expect(resolver().resolve(atColumn: -1, in: "README.md") == nil)
    }

    @Test func rangeCoversLocationButNotPunctuation() {
        let line = "at src/main.swift:42."
        let result = resolver().resolve(atColumn: 5, in: line)
        #expect(result?.range == 3..<20)
    }

    @Test func searchFallbackFindsFileElsewhere() {
        var resolver = resolver()
        resolver.search = { suffix in suffix == "main.swift" ? ["/repo/src/main.swift"] : [] }
        #expect(resolver.resolve(atColumn: 1, in: "main.swift:3")?.path == "/repo/src/main.swift")
        #expect(resolver.resolve(atColumn: 1, in: "main.swift:3")?.line == 3)
        #expect(resolver.resolve(atColumn: 1, in: "other.swift") == nil)
    }

    @Test func searchFallbackIgnoresBareWords() {
        var resolver = resolver()
        resolver.search = { _ in ["/repo/src/main.swift"] }
        #expect(resolver.resolve(atColumn: 1, in: "hello") == nil)
    }

    @Test func hoveringWhitespaceFindsNothing() {
        #expect(resolver().resolve(atColumn: 8, in: "Makefile  README.md") == nil)
    }
}

@Suite struct ToolCallPathTests {
    /// What Claude Code actually prints above a diff.
    @Test func theArgumentOfAToolCallIsThePath() {
        let line = "Update(resume/opportunities.html)"
        #expect(PathLinkDetector.candidates(in: line).map(\.path) == ["resume/opportunities.html"])
        #expect(PathLinkDetector.candidates(atColumn: 12, in: line).first?.path == "resume/opportunities.html")
        #expect(PathLinkDetector.candidates(atColumn: 12, in: line).first?.range == 7..<32)
        // Clicking the word `Update` means the same thing.
        #expect(PathLinkDetector.candidates(atColumn: 2, in: line).first?.path == "resume/opportunities.html")
    }

    @Test func aLocationInsideAToolCallIsKept() {
        let found = PathLinkDetector.candidates(in: "⏺ Read(src/a.ts:12)")
        #expect(found.first?.path == "src/a.ts")
        #expect(found.first?.line == 12)
    }

    @Test func searchFindsAToolCallPath() {
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0 == "/w/site/resume/opportunities.html" ? false : nil },
                                    search: { path in path == "resume/opportunities.html" ? ["/w/site/resume/opportunities.html"] : [] })
        let found = resolver.resolveAll(atColumn: 12, in: "Update(resume/opportunities.html)")
        #expect(found.map(\.path) == ["/w/site/resume/opportunities.html"])
    }

    @Test func aSearchNeverOpensAnotherFileOnTheLine() {
        // The index knows app.ts but not shot.png. A click on shot.png must not land on app.ts.
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0 == "/p/src/app.ts" ? false : nil },
                                    search: { path in path.hasSuffix("app.ts") ? ["/p/src/app.ts"] : [] })
        #expect(resolver.resolveAll(atColumn: 8, in: "Saved shot.png and src/app.ts").isEmpty)
        #expect(resolver.resolveAll(atColumn: 22, in: "Saved shot.png and src/app.ts").map(\.path) == ["/p/src/app.ts"])
    }

    @Test func aSearchStillFindsANameWithSpaces() {
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0 == "/w/My Notes.md" ? false : nil },
                                    search: { path in path == "My Notes.md" ? ["/w/My Notes.md"] : [] })
        #expect(resolver.resolveAll(atColumn: 9, in: "Wrote My Notes.md").map(\.path) == ["/w/My Notes.md"])
    }

    @Test func aFileWithBracketsInItsNameStillOpens() {
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0 == "/p/report(final).pdf" ? false : nil })
        #expect(resolver.resolve(atColumn: 9, in: "report(final).pdf")?.path == "/p/report(final).pdf")
    }

    @Test func plainBracketsAroundWordsAreNotPaths() {
        #expect(PathLinkDetector.candidates(in: "Bash(ls)").allSatisfy { $0.path != "ls" })
    }
}

/// Minified output and logs: one line of ten thousand characters.
@Suite struct LongLinePathTests {
    static func longLine(around path: String, filler: String) -> (line: String, column: Int) {
        var before = ""
        while before.count < 5_000 { before += filler }
        var after = ""
        while after.count < 5_000 { after += filler }
        return (before + path + after, before.count + 2)
    }

    @Test(arguments: ["x.ts ", "{\"a.b\":\"c/d\"},", "word word word ", "a:1"])
    func aPathInsideALongLineStillResolves(filler: String) {
        let (line, column) = Self.longLine(around: " src/main.swift:42 ", filler: filler)
        let found = resolver().resolve(atColumn: column, in: line)
        #expect(found?.path == "/repo/src/main.swift")
        #expect(found?.line == 42)
        // The range is in the whole line's columns, not the part that was looked at.
        let start = line.distance(from: line.startIndex, to: line.range(of: "src/main.swift")!.lowerBound)
        #expect(found?.range == start..<(start + "src/main.swift:42".count))
    }

    @Test func aQuotedPathInsideALongLineStillResolves() {
        let (line, column) = Self.longLine(around: " \"My Documents/report final.pdf\" ", filler: "{\"a.b\":\"c/d\"},")
        #expect(resolver().resolve(atColumn: column + 1, in: line)?.path == "/repo/My Documents/report final.pdf")
    }

    @Test(arguments: ["x.ts ", "{\"a.b\":\"c/d\"},", "a:1", "a."])
    func aLongLineResolvesInAFewMilliseconds(filler: String) {
        var line = ""
        while line.count < 10_000 { line += filler }
        let clock = ContinuousClock()
        let resolver = resolver()
        _ = resolver.resolveAll(atColumn: line.count / 2, in: line)
        let elapsed = clock.measure {
            for column in stride(from: 4_000, to: 6_000, by: 400) { _ = resolver.resolveAll(atColumn: column, in: line) }
        }
        // Five hovers. Each took about a second before it looked only around the column.
        #expect(elapsed < .milliseconds(250))
    }

    @Test func aScanOfAWholeLongLineIsBounded() {
        var line = ""
        while line.count < 50_000 { line += "x.ts " }
        let clock = ContinuousClock()
        var found: [PathCandidate] = []
        let elapsed = clock.measure { found = PathLinkDetector.candidates(in: line) }
        #expect(found.count == PathLinkDetector.maxScannedLength / 5)
        #expect(elapsed < .seconds(1))
    }
}

@Suite struct ShortcutEditingTests {
    func bindings(_ user: [(key: String, command: String)]) -> [Keybinding] { Keymap.build(user: user) }

    @Test func reboundReplacesTheDefaults() {
        let user = Keymap.rebound(user: [], command: "nextTab", key: "cmd+j")
        let keys = bindings(user).filter { $0.command == "nextTab" }.map(\.symbol)
        #expect(keys == [Keymap.parseStrokes("cmd+j")![0].symbol])
    }

    @Test func aKeyMovesToTheNewCommand() {
        let user = Keymap.rebound(user: [], command: "splitDown", key: "cmd+b")
        let built = bindings(user)
        #expect(built.first { $0.strokes == Keymap.parseStrokes("cmd+b") }?.command == "splitDown")
        #expect(!built.contains { $0.command == "toggleSidebar" })
    }

    @Test func unsetLeavesNoKey() {
        let user = Keymap.rebound(user: [], command: "toggleSidebar", key: nil)
        #expect(!bindings(user).contains { $0.command == "toggleSidebar" })
    }

    @Test func resetRestoresTheDefaults() {
        var user = Keymap.rebound(user: [], command: "toggleSidebar", key: "cmd+j")
        user = Keymap.reset(user: user, command: "toggleSidebar")
        #expect(user.isEmpty)
        #expect(bindings(user).contains { $0.command == "toggleSidebar" && $0.strokes == Keymap.parseStrokes("cmd+b") })
    }

    @Test func theFileParsesBack() throws {
        let user = Keymap.rebound(user: [], command: "splitDown", key: "cmd+k cmd+d")
        let parsed = try Keymap.parseUserFile(Keymap.fileContents(user: user))
        #expect(bindings(parsed).contains { $0.command == "splitDown" && $0.strokes.count == 2 })
    }

    @Test func badKeysAreExplained() {
        let all = bindings([])
        #expect(Keymap.problem(with: "cmd+j", command: "splitDown", bindings: all) == nil)
        #expect(Keymap.problem(with: "f5", command: "splitDown", bindings: all) == nil)
        #expect(Keymap.problem(with: "a", command: "splitDown", bindings: all) != nil)
        #expect(Keymap.problem(with: "shift+a", command: "splitDown", bindings: all) != nil)
        #expect(Keymap.problem(with: "cmd+k", command: "find", bindings: all) != nil)
        #expect(Keymap.problem(with: "cmd+b cmd+x", command: "find", bindings: all) != nil)
        #expect(Keymap.problem(with: "not a key!!", command: "find", bindings: all) != nil)
        // ⌘K alone clears a terminal, and a two-press shortcut can still start with it.
        #expect(Keymap.problem(with: "cmd+k cmd+j", command: "find", bindings: all) == nil)
        #expect(Keymap.problem(with: "cmd+k", command: "clearTerminal", bindings: all) == nil)
    }
}

@Suite struct LocationUnderPathTests {
    private struct Case: Sendable {
        var rows: [String]
        var row: Int
        var column: Int
        var path: String?
        var line: Int?
        var col: Int?
        var range: Range<Int>?
    }

    @Test(arguments: [
        // ripgrep with headings.
        Case(rows: ["src/app.ts", "16:5:  const x = 1"], row: 1, column: 0, path: "src/app.ts", line: 16, col: 5, range: 0..<4),
        Case(rows: ["src/app.ts", "16:5:  const x = 1"], row: 1, column: 3, path: "src/app.ts", line: 16, col: 5, range: 0..<4),
        // Off the number isn't a link.
        Case(rows: ["src/app.ts", "16:5:  const x = 1"], row: 1, column: 4),
        Case(rows: ["src/app.ts", "16:5:  const x = 1"], row: 1, column: 9),
        // Line only, and further down a group.
        Case(rows: ["src/app.ts", "16:const x", "20:const y"], row: 2, column: 1, path: "src/app.ts", line: 20, range: 0..<3),
        // eslint: indented, and a path with no slash.
        Case(rows: ["app.js", "  3:10  error  no", "  9:1  warning  no"], row: 2, column: 3, path: "app.js", line: 9, col: 1, range: 2..<5),
        // Between groups of context lines.
        Case(rows: ["a.rs", "1:x", "--", "9:y"], row: 3, column: 0, path: "a.rs", line: 9, range: 0..<2),
        // A path with spaces, as the whole line.
        Case(rows: ["My Documents/report final.md", "2:1:x"], row: 1, column: 0, path: "My Documents/report final.md", line: 2, col: 1, range: 0..<3),
        // Nothing above to say where.
        Case(rows: ["16:5: x"], row: 0, column: 1),
        Case(rows: ["", "16:5: x"], row: 1, column: 1),
        // Not a location at all.
        Case(rows: ["src/app.ts", "hello 16:5"], row: 1, column: 7),
        Case(rows: ["src/app.ts", "16"], row: 1, column: 0),
        Case(rows: ["src/app.ts"], row: 5, column: 0),
    ])
    private func finds(_ test: Case) {
        let found = PathLinkDetector.locationUnderPath(atColumn: test.column, row: test.row, in: test.rows)
        #expect(found?.candidates.first?.path == test.path)
        #expect(found?.candidates.first?.line == test.line)
        #expect(found?.candidates.first?.col == test.col)
        #expect(found?.range == test.range)
    }

    @Test func aDecoratedLineStillGivesThePath() {
        let found = PathLinkDetector.locationUnderPath(atColumn: 0, row: 1, in: ["⎿  src/app.ts", "16:5: x"])
        #expect(found?.candidates.map(\.path) == ["⎿  src/app.ts", "src/app.ts"])
    }

    @Test func itResolvesLikeAnyOtherPath() {
        let found = PathLinkDetector.locationUnderPath(atColumn: 0, row: 1, in: ["src/main.swift", "7:2:x"])
        let resolver = PathResolver(cwd: "/repo", workspaceFolders: [], probe: { disk[$0] })
        let resolved = found.flatMap { resolver.resolve($0.candidates[0]) }
        #expect(resolved?.path == "/repo/src/main.swift" && resolved?.line == 7 && resolved?.col == 2)
    }
}

@Suite struct PathSearchTests {
    let files = ["/p/web/resume/opportunities.html", "/p/old/resume/opportunities.html", "/p/docs/opportunities.html", "/p/Makefile"]
    func named(_ name: String) -> [String] { files.filter { ($0 as NSString).lastPathComponent == name } }

    @Test func aWebRootPathFindsTheFile() {
        let found = PathSearch.matches(for: "/resume/opportunities.html", filesNamed: named)
        #expect(found == ["/p/web/resume/opportunities.html", "/p/old/resume/opportunities.html"])
    }

    @Test func theMostSpecificMatchWins() {
        #expect(PathSearch.matches(for: "web/resume/opportunities.html", filesNamed: named) == ["/p/web/resume/opportunities.html"])
        #expect(PathSearch.matches(for: "docs/opportunities.html", filesNamed: named) == ["/p/docs/opportunities.html"])
    }

    @Test func fallsBackToTheFileName() {
        #expect(PathSearch.matches(for: "nowhere/opportunities.html", filesNamed: named).count == 3)
    }

    @Test func aNameWithoutAnExtensionIsTooVagueAlone() {
        #expect(PathSearch.matches(for: "/api/Makefile", filesNamed: named).isEmpty)
        #expect(PathSearch.matches(for: "/p/Makefile", filesNamed: named) == ["/p/Makefile"])
    }

    @Test func noMatchIsEmpty() {
        #expect(PathSearch.matches(for: "missing.txt", filesNamed: named).isEmpty)
    }

    @Test func rankingPrefersOpenThenNearThenShort() {
        let ranked = PathSearch.ranked(["/a/long/name/x.md", "/b/x.md", "/near/deep/er/x.md", "/open/deep/er/x.md"],
                                       open: ["/open/deep/er/x.md"], near: "/near")
        #expect(ranked == ["/open/deep/er/x.md", "/near/deep/er/x.md", "/b/x.md", "/a/long/name/x.md"])
    }

    @Test func existingPathsBeatSearchResults() {
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0 == "/p/a.md" || $0 == "/q/a.md" ? false : nil },
                                    search: { _ in ["/q/a.md"] })
        #expect(resolver.resolveAll(PathCandidate(path: "a.md", range: 0..<4)).map(\.path) == ["/p/a.md"])
    }

    @Test func searchReachesAbsolutePathsThatDoNotExist() {
        let resolver = PathResolver(cwd: "/p", workspaceFolders: [], probe: { $0.hasPrefix("/q") ? false : nil },
                                    search: { _ in ["/q/one.html", "/q/two/one.html"] })
        #expect(resolver.resolveAll(PathCandidate(path: "/one.html", range: 0..<9)).count == 2)
        #expect(resolver.resolveAll(PathCandidate(path: "~/one.html", range: 0..<10)).isEmpty)
    }
}

@Suite struct PathCandidateTests {
    @Test func scansAllPathsInLine() {
        let found = PathLinkDetector.candidates(in: "edit src/a.swift:1 and ./b.md then /c/d, ok")
        #expect(found.map(\.path) == ["src/a.swift", "./b.md", "/c/d"])
        #expect(found[0].line == 1)
    }

    @Test func proseIsNotScanned() {
        let found = PathLinkDetector.candidates(in: "this is 1/2 of 3.14 and -v flag, https://x.dev/a.md")
        #expect(found.isEmpty)
    }

    @Test func stripANSIHandlesOSCAndCSI() {
        #expect(PathLinkDetector.stripANSI("\u{1B}[1mhi\u{1B}[0m\u{1B}]0;title\u{07}!") == "hi!")
        #expect(PathLinkDetector.stripANSI("\u{1B}]0;title\u{1B}\\ok") == "ok")
    }
}

@Suite struct ShellQuoteTests {
    @Test(arguments: [
        ("/plain/path.txt", "/plain/path.txt"),
        ("/with space/a.txt", "'/with space/a.txt'"),
        ("it's", "'it'\\''s'"),
        ("$HOME", "'$HOME'"),
        ("a;rm -rf", "'a;rm -rf'"),
        ("", "''"),
        ("日本語.txt", "'日本語.txt'"),
    ])
    func quotes(input: String, expected: String) {
        #expect(ShellQuote.quote(input) == expected)
    }

    @Test func joinsWithSpaces() {
        #expect(ShellQuote.join(["/a", "/b c"]) == "/a '/b c'")
    }
}
