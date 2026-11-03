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
        resolver.search = { suffix in suffix == "main.swift" ? "/repo/src/main.swift" : nil }
        #expect(resolver.resolve(atColumn: 1, in: "main.swift:3")?.path == "/repo/src/main.swift")
        #expect(resolver.resolve(atColumn: 1, in: "main.swift:3")?.line == 3)
        #expect(resolver.resolve(atColumn: 1, in: "other.swift") == nil)
    }

    @Test func searchFallbackIgnoresBareWords() {
        var resolver = resolver()
        resolver.search = { _ in "/repo/src/main.swift" }
        #expect(resolver.resolve(atColumn: 1, in: "hello") == nil)
    }

    @Test func hoveringWhitespaceFindsNothing() {
        #expect(resolver().resolve(atColumn: 8, in: "Makefile  README.md") == nil)
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
