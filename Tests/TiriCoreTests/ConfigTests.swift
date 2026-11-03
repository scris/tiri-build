import Foundation
import Testing
@testable import TiriCore

@Suite struct GitChangesTests {
    @Test func statusCoversEveryKind() {
        let output = " M a.swift\0A  new.swift\0 D gone.swift\0?? fresh/x.md\0R  to.swift\0from.swift\0UU clash.swift\0"
        let found = GitStatusParser.parse(output, root: "/r")
        #expect(found.map(\.status) == [.modified, .added, .deleted, .untracked, .renamed, .conflicted])
        #expect(found[3].path == "/r/fresh/x.md")
        #expect(found[4].relative == "to.swift")
        #expect(found[4].oldRelative == "from.swift")
    }

    @Test func aPathWithSpacesIsKept() {
        #expect(GitStatusParser.parse(" M my file.txt\0", root: "/r").first?.relative == "my file.txt")
    }

    @Test func diffNumbersBothSides() {
        let diff = DiffParser.parse("""
        diff --git a/a b/a
        index 1..2 100644
        --- a/a
        +++ b/a
        @@ -10,3 +10,4 @@ func main
         same
        -old
        +new
        +extra
         end
        """.replacingOccurrences(of: "\n        ", with: "\n"))
        #expect(diff.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context])
        #expect(diff.lines[1].oldLine == 10 && diff.lines[1].newLine == 10)
        #expect(diff.lines[2].oldLine == 11 && diff.lines[2].newLine == nil)
        #expect(diff.lines[4].newLine == 12)
        #expect(diff.lines[5].oldLine == 12 && diff.lines[5].newLine == 13)
        #expect(diff.additions == 2 && diff.deletions == 1)
    }

    @Test func headerLinesThatLookLikeChangesAreNot() {
        let diff = DiffParser.parse("--- a/x\n+++ b/x\n")
        #expect(diff.isEmpty)
    }

    @Test func noNewlineMarkerIsNotALine() {
        let diff = DiffParser.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n")
        #expect(diff.lines.map(\.kind) == [.hunk, .removed, .added])
    }

    @Test func binaryIsSaid() {
        #expect(DiffParser.parse("Binary files a/x.png and b/x.png differ\n").isBinary)
    }

    @Test func aNewFileIsAllAdded() {
        let diff = FileDiff.allAdded("one\ntwo\n")
        #expect(diff.lines.map(\.newLine) == [1, 2])
        #expect(diff.additions == 2)
    }

    @Test func aRealRepository() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tiri-git-\(UUID().uuidString)").path
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: root) }
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try "one\ntwo\n".write(toFile: root + "/kept.txt", atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "first")
        try "one\nTWO\n".write(toFile: root + "/kept.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: root + "/fresh.txt", atomically: true, encoding: .utf8)
        let changes = Git.changes(in: root)
        #expect(Set(changes.map(\.status)) == [.modified, .untracked])
        let modified = Git.diff(path: root + "/kept.txt")
        #expect(modified.additions == 1 && modified.deletions == 1)
        #expect(Git.diff(path: root + "/fresh.txt").additions == 1)
        #expect(Git.changes(in: manager.temporaryDirectory.path).isEmpty)
        // A deleted file whose folder went with it still has something to show.
        try manager.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try "gone\n".write(toFile: root + "/docs/gone.md", atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "second")
        try manager.removeItem(atPath: root + "/docs")
        #expect(Git.diff(path: root + "/docs/gone.md").deletions == 1)
    }
}

@Suite struct AgentHooksTests {
    @Test func claudeInstallKeepsWhatWasThere() throws {
        // A hook someone relies on, like a gate in front of production credentials, must survive.
        let original = #"{ "model": "opus", "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "gate.sh" }] }], "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }] } }"#
        let updated = try AgentHooks.installing(.claude, in: original)
        let object = try JSONSerialization.jsonObject(with: Data(updated.utf8)) as! [String: Any]
        #expect(object["model"] as? String == "opus")
        let hooks = object["hooks"] as! [String: [[String: Any]]]
        #expect(hooks["Stop"]?.count == 2)
        #expect(Set(hooks.keys) == Set(AgentHooks.claudeEvents + ["PreToolUse"]))
        #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "Bash")
        #expect(updated.contains("gate.sh"))
        #expect(AgentHooks.isInstalled(.claude, in: updated))
    }

    @Test func claudeInstallTwiceChangesNothing() throws {
        let once = try AgentHooks.installing(.claude, in: "")
        #expect(try AgentHooks.installing(.claude, in: once) == once)
    }

    @Test func claudeRemoveLeavesOnlyWhatWasThere() throws {
        let original = #"{ "hooks": { "PreToolUse": [{ "hooks": [{ "type": "command", "command": "gate.sh" }] }], "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }] }, "model": "opus" }"#
        let removed = try AgentHooks.removing(.claude, from: try AgentHooks.installing(.claude, in: original))
        #expect(!AgentHooks.isInstalled(.claude, in: removed))
        let object = try JSONSerialization.jsonObject(with: Data(removed.utf8)) as! [String: Any]
        let hooks = object["hooks"] as! [String: [[String: Any]]]
        #expect(Set(hooks.keys) == ["Stop", "PreToolUse"])
        #expect(removed.contains("gate.sh"))
        #expect(object["model"] as? String == "opus")
    }

    @Test func aBrokenClaudeFileIsLeftAlone() {
        #expect(throws: (any Error).self) { try AgentHooks.installing(.claude, in: "{ nope") }
    }

    @Test func codexRoundTrips() throws {
        let original = "model = \"gpt\"\n\n[tui]\nnotifications = true\n"
        let installed = try AgentHooks.installing(.codex, in: original)
        #expect(installed.hasPrefix("notify = "))
        #expect(installed.contains("[tui]"))
        #expect(try AgentHooks.installing(.codex, in: installed) == installed)
        #expect(try AgentHooks.removing(.codex, from: installed) == original)
    }

    @Test func someoneElsesCodexNotifyStays() throws {
        let installed = try AgentHooks.installing(.codex, in: "notify = [\"mine\"]\n")
        #expect(installed.hasPrefix("notify = [\"mine\"]"))
        #expect(installed.components(separatedBy: "notify =").count == 2)
    }

    @Test func configPathsFollowTheEnvironment() {
        let home = URL(fileURLWithPath: "/h")
        #expect(AgentHooks.configURL(for: .claude, environment: [:], home: home).path.hasPrefix("/h/.claude/"))
        #expect(AgentHooks.configURL(for: .claude, environment: ["CLAUDE_CONFIG_DIR": "/c"], home: home).path.hasPrefix("/c/"))
        #expect(AgentHooks.configURL(for: .codex, environment: ["CODEX_HOME": "/x"], home: home).path == "/x/config.toml")
    }
}

@Suite struct SettingsSchemaTests {
    @Test func everySettingBelongsToASectionAndHasWords() {
        for definition in SettingsSchema.all {
            #expect(SettingsSchema.sections.contains(definition.section), "\(definition.key)")
            #expect(!definition.title.isEmpty && !definition.explanation.isEmpty, "\(definition.key)")
        }
        #expect(Set(SettingsSchema.all.map(\.key)).count == SettingsSchema.all.count)
    }

    /// A setting whose key doesn't match the parser would look fine and silently do nothing.
    @Test func everySettingRoundTripsThroughTheFile() throws {
        for definition in SettingsSchema.all {
            let value = definition.value(TiriSettings())
            let text = SettingsFile.setting(definition.key, toJSON: SettingsSchema.json(value), in: TiriSettings.defaultFileContents)
            let parsed = definition.value(try TiriSettings.parse(text))
            #expect(parsed == value || (parsed.numberValue != nil && parsed.numberValue == value.numberValue), "\(definition.key)")
        }
    }

    @Test func changingAValueIsSeenByTheParser() throws {
        var text = TiriSettings.defaultFileContents
        text = SettingsFile.setting("code.wordWrap", toJSON: "true", in: text)
        text = SettingsFile.setting("code.fontSize", toJSON: "15", in: text)
        text = SettingsFile.setting("files.exclude", toJSON: #"[".git","dist"]"#, in: text)
        text = SettingsFile.setting("terminal.presets", toJSON: #"[{"command":"x, y","name":"A"}]"#, in: text)
        text = SettingsFile.setting("terminal.resume", toJSON: #"{"claude":"claude -c"}"#, in: text)
        let parsed = try TiriSettings.parse(text)
        #expect(parsed.codeWordWrap && parsed.codeFontSize == 15)
        #expect(parsed.filesExclude == [".git", "dist"])
        #expect(parsed.terminalPresets == [TerminalPreset(name: "A", command: "x, y")])
        #expect(parsed.terminalResume == ["claude": "claude -c"])
        #expect(text.contains("// Tiri settings"))
    }

    @Test func typedValuesAreChecked() throws {
        #expect(try SettingsSchema.value(from: "on", for: "code.wordWrap") == .bool(true))
        #expect(try SettingsSchema.value(from: "tab", for: "terminal.linkOpens") == .string("tab"))
        #expect(try SettingsSchema.value(from: "14", for: "code.fontSize") == .int(14))
        #expect(try SettingsSchema.value(from: "zed, code", for: "externalEditors") == .array([.string("zed"), .string("code")]))
        #expect(throws: SettingsSchema.InvalidValue.self) { try SettingsSchema.value(from: "maybe", for: "code.wordWrap") }
        #expect(throws: SettingsSchema.InvalidValue.self) { try SettingsSchema.value(from: "sideways", for: "terminal.linkOpens") }
        #expect(throws: SettingsSchema.InvalidValue.self) { try SettingsSchema.value(from: "500", for: "code.fontSize") }
        #expect(throws: SettingsSchema.InvalidValue.self) { try SettingsSchema.value(from: "x", for: "no.such.setting") }
    }

    @Test func thePromptTellsAnAgentWhatToRun() {
        #expect(SettingsSchema.agentPrompt.contains("tiri settings explain"))
        #expect(SettingsSchema.agentPrompt.contains("tiri settings set"))
    }
}

@Suite struct SettingsTests {
    @Test func shippedDefaultFileParsesToDefaults() throws {
        #expect(try TiriSettings.parse(TiriSettings.defaultFileContents) == TiriSettings())
    }

    @Test func emptyFileIsDefaults() throws {
        #expect(try TiriSettings.parse("") == TiriSettings())
        #expect(try TiriSettings.parse("{}") == TiriSettings())
    }

    @Test func valuesAndCommentsAndTrailingCommas() throws {
        let settings = try TiriSettings.parse(#"""
        {
          // comment
          "theme": "dark",
          "terminal.fontSize": 15,
          "files.exclude": ["dist", "*.log"],
          "unknown.key": 42,
        }
        """#)
        #expect(settings.theme == .dark)
        #expect(settings.terminalFontSize == 15)
        #expect(settings.filesExclude == ["dist", "*.log"])
    }

    @Test(arguments: [
        #"{ "theme": "dark""#,
        #"{ "theme": "chartreuse" }"#,
        #"{ "theme": 3 }"#,
        #"{ "terminal.fontSize": "big" }"#,
        #"{ "explorer.autoReveal": 1 }"#,
        #"[1,2]"#,
        #"{ "terminal.presets": "nope" }"#,
    ])
    func invalidThrows(text: String) {
        #expect(throws: TiriSettings.ParseError.self) { try TiriSettings.parse(text) }
    }

    @Test func fontSizeIsClamped() throws {
        #expect(try TiriSettings.parse(#"{ "terminal.fontSize": 400 }"#).terminalFontSize == 72)
    }

    @Test func editingKeepsComments() throws {
        let original = TiriSettings.defaultFileContents
        let updated = SettingsFile.setting("theme", to: "dark", in: original)
        #expect(updated.contains("// Tiri settings."))
        #expect(try TiriSettings.parse(updated).theme == .dark)
    }

    @Test func editingInsertsMissingKey() throws {
        #expect(try TiriSettings.parse(SettingsFile.setting("theme", to: "light", in: "{ \"code.fontSize\": 14 }")).theme == .light)
        #expect(try TiriSettings.parse(SettingsFile.setting("theme", to: "light", in: "{}")).theme == .light)
        #expect(try TiriSettings.parse(SettingsFile.setting("theme", to: "light", in: "")).theme == .light)
    }
}

@Suite struct KeybindingTests {
    private func stroke(_ text: String) -> KeyStroke { KeyStroke(parsing: text)! }

    @Test func parsesModifiersInAnyOrder() {
        #expect(stroke("cmd+shift+p") == stroke("shift+cmd+P"))
        #expect(stroke("ctrl+`").modifiers == [.control])
        #expect(KeyStroke(parsing: "hyper+p") == nil)
        #expect(KeyStroke(parsing: "cmd+") == nil)
    }

    @Test func parsesPlusKey() {
        #expect(stroke("cmd++").key == "+")
    }

    @Test func allSpecDefaultsResolve() {
        var resolver = KeyResolver(bindings: Keymap.build(user: []))
        let table = [
            ("cmd+p", "quickOpen"), ("cmd+shift+p", "commandPalette"), ("cmd+b", "toggleSidebar"),
            ("cmd+shift+e", "focusExplorer"), ("ctrl+`", "newTerminal"), ("cmd+\\", "splitRight"),
            ("cmd+w", "closeItem"), ("cmd+shift+t", "reopenClosed"), ("ctrl+tab", "nextTab"),
            ("ctrl+shift+tab", "previousTab"), ("cmd+shift+]", "nextTab"), ("cmd+shift+[", "previousTab"),
            ("cmd+1", "focusGroup1"), ("cmd+9", "focusGroup9"), ("ctrl+1", "switchWorkspace1"),
            ("ctrl+9", "switchWorkspace9"), ("cmd+f", "find"), ("cmd+,", "openSettings"),
        ]
        for (key, command) in table {
            #expect(resolver.handle(stroke(key)) == .command(command), "\(key)")
        }
    }

    @Test func chordSplitDown() {
        var resolver = KeyResolver(bindings: Keymap.build(user: []))
        #expect(resolver.handle(stroke("cmd+k")) == .pending)
        #expect(resolver.isPending)
        #expect(resolver.handle(stroke("cmd+\\")) == .command("splitDown"))
        #expect(!resolver.isPending)
    }

    @Test func abandonedChordIsSwallowedOnce() {
        var resolver = KeyResolver(bindings: Keymap.build(user: []))
        _ = resolver.handle(stroke("cmd+k"))
        #expect(resolver.handle(stroke("x")) == .cancelledChord)
        #expect(resolver.handle(stroke("x")) == .passThrough)
    }

    @Test func unboundKeysPassThrough() {
        var resolver = KeyResolver(bindings: Keymap.build(user: []))
        #expect(resolver.handle(stroke("ctrl+c")) == .passThrough)
        #expect(resolver.handle(stroke("a")) == .passThrough)
    }

    @Test func userBindingOverridesAndUnbinds() throws {
        let user = try Keymap.parseUserFile(#"""
        // mine
        [
          { "key": "cmd+b", "command": "-toggleSidebar" },
          { "key": "cmd+p", "command": "commandPalette" },
          { "key": "cmd+k cmd+k", "command": "toggleSidebar" },
        ]
        """#)
        var resolver = KeyResolver(bindings: Keymap.build(user: user))
        #expect(resolver.handle(stroke("cmd+b")) == .passThrough)
        #expect(resolver.handle(stroke("cmd+p")) == .command("commandPalette"))
        #expect(resolver.handle(stroke("cmd+k")) == .pending)
        #expect(resolver.handle(stroke("cmd+k")) == .command("toggleSidebar"))
    }

    @Test func shippedTemplateParses() throws {
        #expect(try Keymap.parseUserFile(Keymap.defaultFileContents).isEmpty)
    }

    @Test(arguments: [#"{ "key": "a" }"#, #"[{ "key": "a" }]"#, #"[{ "key": "nope+a", "command": "x" }]"#, "[,"])
    func invalidFilesThrow(text: String) {
        #expect(throws: Keymap.ParseError.self) { try Keymap.parseUserFile(text) }
    }

    @Test func symbols() {
        #expect(stroke("cmd+shift+p").symbol == "⇧⌘P")
        #expect(Keybinding(strokes: [stroke("cmd+k"), stroke("cmd+\\")], command: "x").symbol == "⌘K ⌘\\")
    }
}

@Suite struct FuzzyTests {
    @Test func subsequenceRequired() {
        #expect(FuzzyMatcher.match(query: "xyz", candidate: "src/main.swift") == nil)
        #expect(FuzzyMatcher.match(query: "msw", candidate: "src/main.swift") != nil)
    }

    @Test func caseInsensitiveAndSpacesIgnored() {
        #expect(FuzzyMatcher.match(query: "MAIN sw", candidate: "src/main.swift") != nil)
    }

    @Test func positionsAreInOrderAndCorrect() throws {
        let match = try #require(FuzzyMatcher.match(query: "mai", candidate: "src/main.swift"))
        #expect(match.positions == [4, 5, 6])
    }

    private func score(_ query: String, _ candidate: String) -> Int {
        FuzzyMatcher.match(query: query, candidate: candidate)?.score ?? .min
    }

    @Test func filenameBeatsDirectory() {
        #expect(score("app", "src/app.ts") > score("app", "app/zzz/other.ts"))
    }

    @Test func consecutiveBeatsScattered() {
        #expect(score("read", "docs/README.md") > score("read", "r/e/a/d.txt"))
    }

    @Test func wordBoundaryBeatsMiddle() {
        #expect(score("ws", "src/WorkspaceStore.swift") > score("ws", "src/drawsome.swift"))
    }

    @Test func emptyQueryMatches() {
        #expect(FuzzyMatcher.match(query: "", candidate: "a")?.score == 0)
    }

    @Test func nonASCIIDoesNotCrash() {
        #expect(FuzzyMatcher.match(query: "日本", candidate: "docs/日本語.md") != nil)
    }
}

@Suite struct CSVTests {
    @Test func plain() {
        let table = CSVParser.parse("a,b\n1,2\n3,4\n")
        #expect(table.header == ["a", "b"])
        #expect(table.rows == [["1", "2"], ["3", "4"]])
    }

    @Test func quotedCommasNewlinesAndDoubledQuotes() {
        let table = CSVParser.parse("name,note\n\"Doe, J\",\"said \"\"hi\"\"\nthen left\"\n")
        #expect(table.rows == [["Doe, J", "said \"hi\"\nthen left"]])
    }

    @Test func crlfAndNoTrailingNewline() {
        let table = CSVParser.parse("a,b\r\n1,2")
        #expect(table.rows == [["1", "2"]])
    }

    @Test func detectsDelimiter() {
        #expect(CSVParser.parse("a\tb\n1\t2\n").header == ["a", "b"])
        #expect(CSVParser.parse("a;b\n1;2\n").rows == [["1", "2"]])
    }

    @Test func truncatesAtLimit() {
        let table = CSVParser.parse("a\n1\n2\n3\n4\n", maxRows: 2)
        #expect(table.truncated)
    }

    @Test func emptyInput() {
        #expect(CSVParser.parse("").header.isEmpty)
    }
}

@Suite struct MarkdownTests {
    @Test func rendersCoreSyntax() {
        let page = MarkdownRenderer.page(markdown: "# Title\n\nSome *em* and `code`.\n\n- a\n- b\n", baseHref: nil)
        #expect(page.contains(#"<h1 id="title">Title</h1>"#))
        #expect(page.contains("<em>em</em>"))
        #expect(page.contains("<code>code</code>"))
        #expect(page.contains("<li>"))
    }

    @Test func tablesAndCodeBlocks() {
        let page = MarkdownRenderer.page(markdown: "|a|b|\n|-|-|\n|1|2|\n\n```swift\nlet x = 1\n```\n", baseHref: nil)
        #expect(page.contains("<table>"))
        #expect(page.contains("<td"))
        #expect(page.contains("let x = 1"))
    }

    @Test func taskLists() {
        let page = MarkdownRenderer.page(markdown: "- [ ] todo\n- [x] done\n", baseHref: nil)
        #expect(page.contains(#"<li class="task"><input type="checkbox" disabled="" />"#))
        #expect(page.contains(#"<li class="task"><input type="checkbox" disabled="" checked="" />"#))
    }

    @Test func frontMatterIsSeparated() {
        let page = MarkdownRenderer.page(markdown: "---\ntitle: X\n---\n# Real\n", baseHref: nil)
        #expect(page.contains("front-matter"))
        #expect(page.contains(#"<h1 id="real">"#))
    }

    @Test func duplicateHeadingsGetUniqueAnchors() {
        let page = MarkdownRenderer.page(markdown: "# A\n\n# A\n", baseHref: nil)
        #expect(page.contains(#"id="a""#))
        #expect(page.contains(#"id="a-1""#))
    }

    @Test func lineMapsToItsSection() {
        let source = "intro\n\n# One\n\ntext\n\n## Two\n\nmore\n\n# One\n\nend\n"
        #expect(MarkdownRenderer.anchor(forLine: 1, in: source) == nil)
        #expect(MarkdownRenderer.anchor(forLine: 5, in: source) == "one")
        #expect(MarkdownRenderer.anchor(forLine: 9, in: source) == "two")
        #expect(MarkdownRenderer.anchor(forLine: 13, in: source) == "one-1")
    }

    @Test func lineMappingAccountsForFrontMatter() {
        let source = "---\na: 1\n---\n# One\n\ntext\n"
        #expect(MarkdownRenderer.anchor(forLine: 3, in: source) == nil)
        #expect(MarkdownRenderer.anchor(forLine: 6, in: source) == "one")
    }

    @Test func pagesCarryAContentSecurityPolicy() {
        let page = MarkdownRenderer.page(markdown: "<meta http-equiv=refresh content='0;url=https://evil'>", baseHref: nil)
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.range(of: "Content-Security-Policy")!.lowerBound < page.range(of: "evil")!.lowerBound)
    }

    @Test func baseHrefIsEscaped() {
        let page = MarkdownRenderer.page(markdown: "x", baseHref: "tiri-file:///a\"b/")
        #expect(page.contains("&quot;"))
    }

    @Test func noExternalResourcesInChrome() {
        let page = MarkdownRenderer.page(markdown: "x", baseHref: nil)
        #expect(!page.contains("http://"))
        #expect(!page.contains("https://"))
    }
}

@Suite struct FileKindTests {
    @Test(arguments: [
        ("a.md", FileKind.markdown), ("A.MARKDOWN", .markdown), ("a.png", .image), ("a.HEIC", .image), ("a.gif", .image),
        ("a.svg", .svg), ("a.pdf", .pdf), ("a.mp4", .media), ("a.mp3", .media), ("a.html", .html), ("a.csv", .csv),
        ("a.pptx", .office), ("a.docx", .office), ("a.xlsx", .office), ("a.key", .office), ("a.pages", .office), ("a.numbers", .office),
        ("a.swift", .text), ("Makefile", .text), (".gitignore", .text), ("LICENSE", .text),
    ])
    func classifies(path: String, kind: FileKind) {
        #expect(FileClassifier.classify(path: path) == kind)
    }

    @Test func unknownExtensionSniffsBytes() {
        #expect(FileClassifier.classify(path: "a.xyz") { Data("hello".utf8) } == .text)
        #expect(FileClassifier.classify(path: "a.xyz") { Data([0, 1, 2, 0xFF]) } == .quickLook)
        #expect(FileClassifier.classify(path: "a.xyz") { nil } == .quickLook)
        // Quick Look draws these on white, so they're dark-capable like Office files.
        #expect(FileClassifier.classify(path: "a.ttf") { nil } == .office)
        #expect(FileClassifier.classify(path: "a.webarchive") { nil } == .office)
        #expect(FileClassifier.isAudioOnly(path: "a.WAV"))
        #expect(!FileClassifier.isAudioOnly(path: "a.mp4"))
    }

    @Test func truncatedMultibyteIsStillText() {
        var data = Data(repeating: 0x61, count: 8190)
        data.append(contentsOf: Array("日".utf8))
        #expect(FileClassifier.isLikelyText(data))
    }
}

@Suite struct FileSystemTests {
    private func fixture() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-fs-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for name in ["file10.txt", "file2.txt", "src/a.swift", "src/deep/b.swift", "node_modules/x/y.js", ".git/config", "debug.log"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        return root.resolvingSymlinksInPath().path
    }

    private let excludes = ExcludeMatcher(patterns: [".git", "node_modules", "*.log"])

    @Test func listSortsFoldersFirstNaturally() throws {
        let root = try fixture()
        let entries = try LocalFileSystem().list(directory: root, excludes: excludes)
        #expect(entries.map(\.name) == ["src", "file2.txt", "file10.txt"])
        #expect(entries[0].isDirectory)
    }

    @Test func indexerWalksAndExcludes() throws {
        let root = try fixture()
        let files = FileIndexer.walk(roots: [root], excludes: excludes)
        #expect(Set(files.map(\.relative)) == ["file10.txt", "file2.txt", "src/a.swift", "src/deep/b.swift"])
    }

    @Test func indexerRespectsLimit() throws {
        let root = try fixture()
        #expect(FileIndexer.walk(roots: [root], excludes: excludes, limit: 1).count <= 2)
    }

    @Test func excludeGlobs() {
        let matcher = ExcludeMatcher(patterns: ["**/dist", "*.tmp", "build/*"])
        #expect(matcher.excludes(name: "dist"))
        #expect(matcher.excludes(name: "a.tmp"))
        #expect(matcher.excludes(name: "x", relativePath: "build/x"))
        #expect(!matcher.excludes(name: "src"))
    }

    @Test func externalEditorArguments() {
        #expect(ExternalEditor.arguments(editor: "code", path: "/a", line: 3, col: nil) == ["--goto", "/a:3"])
        #expect(ExternalEditor.arguments(editor: "/usr/local/bin/cursor", path: "/a", line: 3, col: 2) == ["--goto", "/a:3:2"])
        #expect(ExternalEditor.arguments(editor: "zed", path: "/a", line: 3, col: nil) == ["/a:3"])
        #expect(ExternalEditor.arguments(editor: "code", path: "/a", line: nil, col: nil) == ["/a"])
        #expect(ExternalEditor.arguments(editor: "nano", path: "/a", line: 3, col: nil) == ["/a"])
    }
}
