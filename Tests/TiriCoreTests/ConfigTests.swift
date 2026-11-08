import Foundation
import Testing
@testable import TiriCore

@Suite struct RenderedSelectionTests {
    @Test func blocksSayWhichLinesTheyCameFrom() {
        let page = MarkdownRenderer.page(markdown: "# Title\n\nFirst paragraph\nstill first.\n\n- one\n- two\n", baseHref: nil)
        #expect(page.contains("data-line=\"0\" data-line-end=\"0\""))
        #expect(page.contains("data-line=\"2\" data-line-end=\"3\""))
        #expect(page.contains("data-line=\"5\" data-line-end=\"6\""))
        #expect(page.contains("<h1 id=\"title\">Title</h1>"))
    }

    @Test func frontMatterIsCounted() {
        let page = MarkdownRenderer.page(markdown: "---\na: 1\n---\n\nBody\n", baseHref: nil)
        #expect(page.contains("data-line=\"4\" data-line-end=\"4\""))
    }

    @Test func aSelectionNarrowsToTheLinesItCovers() {
        let source = "# Title\n\n- first item\n- **second** item\n- third item\n- fourth item\n"
        let lines = MarkdownRenderer.sourceLines(blockStart: 2, blockEnd: 5, selected: "second item\nthird item", source: source)
        #expect(lines.first == 3 && lines.last == 4)
    }

    @Test func textThatCantBeFoundKeepsTheWholeBlock() {
        let lines = MarkdownRenderer.sourceLines(blockStart: 0, blockEnd: 1, selected: "nothing like it", source: "a\nb\n")
        #expect(lines.first == 0 && lines.last == 1)
    }

    @Test func quotationsAreMarkedAsQuotes() {
        #expect(AgentReference.quotation(from: "page.html", text: " one\ntwo\n") == "\nFrom page.html:\n> one\n> two\n")
    }
}

@Suite struct AgentReferenceTests {
    @Test func whichAgentIsRunning() {
        #expect(AgentReference.agent(commandLine: ["claude"], command: nil) == .claude)
        // How Claude Code really appears once installed.
        #expect(AgentReference.agent(commandLine: ["/Users/r/.local/share/claude/versions/2.1.317", "claude"], command: nil) == .claude)
        #expect(AgentReference.agent(commandLine: ["/opt/node", "/lib/node_modules/@anthropic-ai/claude-code/cli.js"], command: nil) == .claude)
        #expect(AgentReference.agent(commandLine: ["/opt/node", "/x/bin/codex"], command: nil) == .codex)
        #expect(AgentReference.agent(commandLine: [], command: "codex resume --last") == .codex)
        #expect(AgentReference.agent(commandLine: ["/bin/zsh"], command: nil) == nil)
        // A program that only has the word in an argument isn't an agent.
        #expect(AgentReference.agent(commandLine: ["/usr/bin/vim", "claude.md"], command: "vim claude.md") == nil)
    }

    @Test func claudeGetsAtMentionsAndCodexGetsPaths() {
        #expect(AgentReference.text(path: "/p/src/a.ts", cwd: "/p", firstLine: 11, lastLine: 19, agent: .claude) == "@src/a.ts#L12-20 ")
        #expect(AgentReference.text(path: "/p/src/a.ts", cwd: "/p", firstLine: 11, lastLine: 11, agent: .claude) == "@src/a.ts#L12 ")
        #expect(AgentReference.text(path: "/p/src/a.ts", cwd: "/p", firstLine: 11, lastLine: 19, agent: .codex) == "src/a.ts:12-20 ")
        #expect(AgentReference.text(path: "/p/a.ts", cwd: "/p", firstLine: nil, lastLine: nil, agent: .codex) == "a.ts ")
    }

    @Test func outsideTheFolderIsAbsoluteAndSpacesAreQuoted() {
        #expect(AgentReference.text(path: "/q/a.ts", cwd: "/p", firstLine: nil, lastLine: nil, agent: .codex) == "/q/a.ts ")
        #expect(AgentReference.text(path: "/p/my file.ts", cwd: "/p", firstLine: nil, lastLine: nil, agent: .claude) == "@\"my file.ts\" ")
    }

    @Test func imagesAreKnown() {
        #expect(AgentReference.isImage(path: "/a/shot.PNG"))
        #expect(!AgentReference.isImage(path: "/a/doc.pdf"))
        // Claude Code leaves any other kind's path as words, so those go in as a PNG copy.
        #expect(AgentReference.isImageEveryAgentTakes(path: "/a/shot.JPEG"))
        #expect(AgentReference.isImage(path: "/a/photo.heic") && !AgentReference.isImageEveryAgentTakes(path: "/a/photo.heic"))
    }

    @Test func aSelectionEndingAtALineStartStopsBeforeIt() {
        let selection = EditorSelection(path: "/a", text: "x\n", startLine: 3, startCharacter: 0, endLine: 4, endCharacter: 0)
        #expect(selection.lastLine == 3)
    }
}

@Suite struct EditorProtocolTests {
    func host(selection: EditorSelection? = nil, opened: @escaping (String) -> Void = { _ in }) -> EditorProtocol.Host {
        EditorProtocol.Host(selection: { selection }, openFiles: { [("/p/a.ts", true)] }, folders: { ["/p"] },
                            isDirty: { _ in false }, openFile: opened)
    }

    func call(_ method: String, _ params: String = "{}", host: EditorProtocol.Host) throws -> JSONValue {
        let request = #"{"jsonrpc":"2.0","id":7,"method":"\#(method)","params":\#(params)}"#
        let data = try #require(EditorProtocol.respond(to: Data(request.utf8), host: host))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func initializeEchoesTheVersion() throws {
        let response = try call("initialize", #"{"protocolVersion":"2025-06-18"}"#, host: host())
        #expect(response["id"]?.intValue == 7)
        #expect(response["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(response["result"]?["serverInfo"]?["name"]?.stringValue == "Tiri")
    }

    @Test func notificationsGetNoAnswer() {
        #expect(EditorProtocol.respond(to: Data(#"{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":5}}"#.utf8), host: host()) == nil)
        #expect(EditorProtocol.connectedProcess(in: Data(#"{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":5}}"#.utf8)) == 5)
    }

    /// Offering openDiff would leave Claude waiting on Tiri to accept every edit.
    @Test func openDiffIsNotOffered() throws {
        let response = try call("tools/list", host: host())
        let names = response["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("getCurrentSelection"))
        #expect(!names.contains("openDiff"))
    }

    @Test func selectionTool() throws {
        let selection = EditorSelection(path: "/p/a.ts", text: "hi", startLine: 2, startCharacter: 1, endLine: 2, endCharacter: 3)
        let response = try call("tools/call", #"{"name":"getCurrentSelection","arguments":{}}"#, host: host(selection: selection))
        let text = try #require(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let inner = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(inner["success"]?.boolValue == true)
        #expect(inner["text"]?.stringValue == "hi")
        #expect(inner["selection"]?["start"]?["line"]?.intValue == 2)
    }

    @Test func noSelectionSaysSo() throws {
        let response = try call("tools/call", #"{"name":"getLatestSelection","arguments":{}}"#, host: host())
        #expect(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("No selection") == true)
    }

    @Test func openFileGoesToTheHost() throws {
        final class Box: @unchecked Sendable { var path: String? }
        let box = Box()
        _ = try call("tools/call", #"{"name":"openFile","arguments":{"filePath":"/p/b.ts"}}"#, host: host(opened: { box.path = $0 }))
        #expect(box.path == "/p/b.ts")
    }

    @Test func unknownThingsAreErrors() throws {
        #expect(try call("tools/call", #"{"name":"nope"}"#, host: host())["error"] != nil)
        #expect(try call("nope", host: host())["error"] != nil)
    }

    @Test func messagesClaudeReads() throws {
        let mention = try JSONDecoder().decode(JSONValue.self, from: EditorProtocol.atMentioned(path: "/p/a.ts", firstLine: 3, lastLine: 5))
        #expect(mention["method"]?.stringValue == "at_mentioned")
        #expect(mention["params"]?["lineStart"]?.intValue == 3)
        #expect(mention["params"]?["lineEnd"]?.intValue == 5)
        let lock = try JSONDecoder().decode(JSONValue.self, from: EditorProtocol.lockFile(pid: 9, folders: ["/p"], token: "t"))
        #expect(lock["ideName"]?.stringValue == "Tiri")
        #expect(lock["transport"]?.stringValue == "ws")
        #expect(EditorProtocol.newToken().count == 32)
    }
}

@Suite struct ContentSearchTests {
    func find(_ text: String, _ query: String) -> [ContentMatch] {
        ContentSearch.matches(in: Data(text.utf8), path: "/a.txt", query: query)
    }

    @Test func lineAndColumnAreRight() {
        let found = find("one\n  two three\nfour", "three")
        #expect(found.count == 1)
        #expect(found[0].line == 2 && found[0].column == 7)
        #expect(found[0].text == "two three")
        #expect(found[0].matchOffset == 4 && found[0].matchLength == 5)
    }

    @Test func lowercaseIgnoresCaseAndACapitalMeansIt() {
        #expect(find("Hello\nhello\nHELLO", "hello").count == 3)
        #expect(find("Hello\nhello\nHELLO", "Hello").count == 1)
    }

    @Test func oneResultPerLine() {
        #expect(find("aa aa aa\nbb", "aa").count == 1)
    }

    @Test func nonAsciiWorks() {
        let found = find("第一行\n这里有用户行为分析\n", "用户")
        #expect(found.first?.line == 2)
        #expect(found.first?.text == "这里有用户行为分析")
        #expect(found.first?.column == 4)
    }

    @Test func binaryFilesHaveNoMatches() {
        var data = Data("needle".utf8)
        data.append(0)
        #expect(ContentSearch.matches(in: data, path: "/a", query: "needle").isEmpty)
    }

    @Test func aMatchAtTheVeryEndIsFound() {
        #expect(find("abc", "abc").count == 1)
        #expect(find("x\nabc", "abc").first?.line == 2)
    }

    @Test func longLinesStayReadableAroundTheMatch() {
        let line = String(repeating: "x", count: 5000) + "needle" + String(repeating: "y", count: 5000)
        let found = find(line, "needle")
        #expect(found[0].text.utf8.count <= 220)
        let text = Array(found[0].text.utf8)
        #expect(String(decoding: text[found[0].matchOffset..<(found[0].matchOffset + 6)], as: UTF8.self) == "needle")
    }
}

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

    @Test func aQuotedDiffKeepsItsMarks() {
        let quote = DiffQuote.text(path: "/p/a.ts", rows: [
            DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
            DiffLine(kind: .context, oldLine: 1, newLine: 1, text: "same"),
            DiffLine(kind: .removed, oldLine: 2, text: "old"),
            DiffLine(kind: .added, newLine: 2, text: "new"),
        ])
        #expect(quote == "From the changes in a.ts:\n```diff\n same\n-old\n+new\n```\n")
    }

    @Test func gitThatFailsIsReportedAndDoesNotHang() {
        #expect(Git.repositoryRoot(of: "/") == nil)
        #expect(Git.changes(in: "/").isEmpty)
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
    @Test func everySettingHasWords() {
        for definition in SettingsSchema.all {
            #expect(!definition.title.isEmpty && !definition.explanation.isEmpty, "\(definition.key)")
        }
        #expect(Set(SettingsSchema.all.map(\.key)).count == SettingsSchema.all.count)
    }

    @Test func everySettingOnTheScreenHasAHeadingOrStandsFirst() {
        for pane in SettingsPane.allCases {
            let groups = SettingsSchema.groups(in: pane)
            #expect(groups.dropFirst().allSatisfy { !$0.name.isEmpty }, "\(pane)")
        }
        // Two lists elsewhere on the screen, three themes the Theme row shows, and Run's languages table: no rows of their own.
        #expect(Set(SettingsSchema.all.filter(\.shownElsewhere).map(\.key))
                == ["terminal.presets", "terminal.resume", "theme.light", "theme.highContrastDark", "theme.highContrastLight",
                    "run.commands", "run.off"])
    }

    /// One line under each title. Anything longer belongs in its note.
    @Test func explanationsStayShort() {
        for definition in SettingsSchema.all where !definition.shownElsewhere {
            #expect(definition.explanation.count <= 100, "\(definition.key): \(definition.explanation.count)")
        }
    }

    @Test func searchNeedsEveryWordButNotInOnePlace() throws {
        let font = try #require(SettingsSchema.definition(for: "terminal.fontFamily"))
        #expect(SettingsSchema.matches("terminal font", font))
        #expect(SettingsSchema.matches("  FONT  ", font))
        #expect(!SettingsSchema.matches("editor font", font))
        #expect(SettingsSchema.matches("", font))
    }

    @Test func notesAreSearchedAndExplained() throws {
        let zoom = try #require(SettingsSchema.definition(for: "window.zoomLevel"))
        #expect(SettingsSchema.matches("markdown", zoom))
        #expect(zoom.fullExplanation.contains(zoom.explanation) && zoom.fullExplanation.contains("markdown"))
    }

    @Test func openTakesAPaneASettingOrWords() {
        #expect(SettingsSchema.openTarget("keyboard") == .pane(.keyboard))
        #expect(SettingsSchema.openTarget("Terminal") == .pane(.terminal))
        #expect(SettingsSchema.openTarget("terminal.fontSize") == .setting("terminal.fontSize"))
        #expect(SettingsSchema.openTarget("font size") == .search("font size"))
    }

    @Test func aLanguageSaysWhatItsForAndWhatAddingDoes() throws {
        let python = try #require(LanguageServerCatalog.all.first { $0.id == "python" })
        #expect(python.filesLine?.hasPrefix("For .py") == true)
        let typescript = try #require(LanguageServerCatalog.all.first { $0.id == "typescript" })
        #expect(typescript.filesLine?.contains(".ts") == true && typescript.filesLine?.contains(".cy") == false)
        #expect(python.addLine == "Installs basedpyright, 283 MB.")
        let json = try #require(LanguageServerCatalog.all.first { $0.id == "json" })
        #expect(json.addLine == "Installs VS Code's web language servers, 94 MB. Also covers HTML and CSS.")
        #expect(json.sharesInstallWith.map(\.id) == ["html", "css"])
        // A server with no extensions of its own still reads as a sentence.
        for definition in LanguageServerCatalog.all {
            #expect(definition.filesLine?.hasPrefix("For .") ?? true, "\(definition.id)")
        }
    }

    /// Whatever the reason, it says what's wrong and what you get instead.
    @Test func withoutAppleIntelligenceItSaysWhyAndWhatStillWorks() {
        #expect(MacModelState.ready.message == nil)
        for state in MacModelState.allCases where state != .ready {
            let message = state.message ?? ""
            #expect(message.contains("Apple Intelligence"), "\(state)")
            #expect(message.contains("first prompt") && message.contains("words you type"), "\(state)")
        }
        #expect(Set(MacModelState.allCases.compactMap(\.message)).count == MacModelState.allCases.count - 1)
    }

    @Test func aSettingThatDoesNothingYetKnows() throws {
        var settings = TiriSettings()
        let column = try #require(SettingsSchema.definition(for: "editor.wordWrapColumn")?.applies)
        #expect(!column(settings))
        settings.editorWordWrap = .bounded
        #expect(column(settings))
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
        text = SettingsFile.setting("editor.wordWrap", toJSON: "\"on\"", in: text)
        text = SettingsFile.setting("code.fontSize", toJSON: "15", in: text)
        text = SettingsFile.setting("files.exclude", toJSON: #"[".git","dist"]"#, in: text)
        text = SettingsFile.setting("terminal.presets", toJSON: #"[{"command":"x, y","name":"A"}]"#, in: text)
        text = SettingsFile.setting("terminal.resume", toJSON: #"{"claude":"claude -c"}"#, in: text)
        let parsed = try TiriSettings.parse(text)
        #expect(parsed.editorWordWrap == .on && parsed.codeFontSize == 15)
        // The older setting counts until the new one says otherwise.
        #expect(try TiriSettings.parse("{\"code.wordWrap\": true}").editorWordWrap == .on)
        #expect(try TiriSettings.parse("{\"code.wordWrap\": true, \"editor.wordWrap\": \"bounded\"}").editorWordWrap == .bounded)
        #expect(try TiriSettings.parseReporting("{\"editor.wordWrap\": \"sometimes\"}").problems.first?.key == "editor.wordWrap")
        #expect(try TiriSettings.parse("{\"editor.wordWrapColumn\": 5}").editorWordWrapColumn == 20)
        #expect(try TiriSettings.parse("{\"window.zoomLevel\": 99}").zoomLevel == TiriSettings.zoomRange.upperBound)
        var zoomed = TiriSettings()
        zoomed.zoomLevel = 3
        #expect(zoomed.codeFontSizeZoomed == zoomed.codeFontSize + 3 && zoomed.terminalFontSizeZoomed == zoomed.terminalFontSize + 3)
        zoomed.zoomLevel = -100
        #expect(zoomed.codeFontSizeZoomed == 6)
        #expect(parsed.filesExclude == [".git", "dist"])
        #expect(parsed.terminalPresets == [TerminalPreset(name: "A", command: "x, y")])
        #expect(parsed.terminalResume == ["claude": "claude -c"])
        #expect(text.contains("// Tiri settings"))
    }

    @Test func typedValuesAreChecked() throws {
        #expect(try SettingsSchema.value(from: "on", for: "explorer.autoReveal") == .bool(true))
        #expect(try SettingsSchema.value(from: "tab", for: "terminal.linkOpens") == .string("tab"))
        #expect(try SettingsSchema.value(from: "14", for: "code.fontSize") == .int(14))
        #expect(try SettingsSchema.value(from: "zed, code", for: "externalEditors") == .array([.string("zed"), .string("code")]))
        #expect(throws: SettingsSchema.InvalidValue.self) { try SettingsSchema.value(from: "maybe", for: "explorer.autoReveal") }
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

    @Test func themeSlots() throws {
        let defaults = TiriSettings()
        #expect(defaults.themeName(for: .dark) == "System Dark")
        #expect(defaults.themeName(for: .highContrastLight) == "High Contrast Light")
        // Before themes, pink was its own setting: it becomes Tiri's pink themes.
        let old = try TiriSettings.parse(#"{ "colorTheme": "pink" }"#)
        #expect(old.darkTheme == "Tiri Pink Dark" && old.lightTheme == "Tiri Pink Light")
        #expect(try TiriSettings.parse(#"{ "colorTheme": "pink", "theme.dark": "Dracula" }"#).darkTheme == "Dracula")
        #expect(try TiriSettings.parse(SettingsFile.setting("theme.light", to: "Solarized Light", in: TiriSettings.defaultFileContents)).lightTheme == "Solarized Light")
        #expect(try SettingsSchema.value(from: "Nord", for: "theme.dark") == .string("Nord"))
        #expect(ThemeAccent.pink.system.number == 6)
    }

    @Test(arguments: [
        #"{ "theme": "dark""#,
        #"[1,2]"#,
    ])
    func invalidThrows(text: String) {
        #expect(throws: TiriSettings.ParseError.self) { try TiriSettings.parse(text) }
    }

    /// One value of the wrong kind is that setting at its default, and the rest as written.
    @Test(arguments: [
        (#"{ "theme": "chartreuse", "code.fontSize": 17 }"#, "theme"),
        (#"{ "theme": 3, "code.fontSize": 17 }"#, "theme"),
        (#"{ "theme.dark": 3, "code.fontSize": 17 }"#, "theme.dark"),
        (#"{ "terminal.fontSize": "big", "code.fontSize": 17 }"#, "terminal.fontSize"),
        (#"{ "explorer.autoReveal": 1, "code.fontSize": 17 }"#, "explorer.autoReveal"),
        (#"{ "terminal.presets": "nope", "code.fontSize": 17 }"#, "terminal.presets"),
    ])
    func wrongTypeSkipsOnlyThatKey(text: String, key: String) throws {
        let parsed = try TiriSettings.parseReporting(text)
        #expect(parsed.problems.map(\.key) == [key])
        #expect(parsed.settings.codeFontSize == 17)
        var expected = TiriSettings()
        expected.codeFontSize = 17
        #expect(parsed.settings == expected)
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
        // While waiting for the second press, ⌘K alone has something to do too.
        _ = resolver.handle(stroke("cmd+k"))
        #expect(resolver.commandsSoFar == ["clearTerminal"])
        resolver.reset()
        #expect(resolver.commandsSoFar.isEmpty)
        // One key, two commands: whichever can take it, in order.
        #expect(resolver.handle(stroke("cmd+enter")) == .command("promotePeek", otherwise: ["insertLineBelow"]))
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
        ("a.svg", .svg), ("a.pdf", .pdf), ("a.mp4", .media), ("a.mp3", .media), ("a.html", .html), ("a.csv", .csv), ("a.TSV", .csv),
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

    @Test func indexerWalksForOneName() throws {
        let root = try fixture()
        #expect(FileIndexer.walk(roots: [root], excludes: excludes, named: "b.swift").map(\.relative) == ["src/deep/b.swift"])
        #expect(FileIndexer.walk(roots: [root], excludes: excludes, named: "missing.txt").isEmpty)
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

@Suite struct RepositoryStatusTests {
    /// A clone of a bare repository in a temporary folder. Nothing here reaches a real remote.
    private final class Place {
        let base: String
        var origin: String { base + "/origin.git" }
        var work: String { base + "/work" }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-repo-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            try git(in: base, "init", "-q", "--bare", "-b", "main", origin)
            try git(in: base, "clone", "-q", origin, work)
            try git(in: work, "checkout", "-q", "-b", "main")
            try commit("first", in: work)
            try git(in: work, "push", "-q", "-u", "origin", "main")
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }

        func git(in directory: String, _ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func commit(_ name: String, in directory: String) throws {
            try name.write(toFile: directory + "/\(name).txt", atomically: true, encoding: .utf8)
            try git(in: directory, "add", ".")
            try git(in: directory, "commit", "-qm", name)
        }

        func secondClone() throws -> String {
            let other = base + "/other"
            try git(in: base, "clone", "-q", origin, other)
            return other
        }
    }

    private func succeeded(_ result: Result<Void, Git.TransferFailure>) -> Bool {
        if case .success = result { return true }
        return false
    }

    @Test func readsTheStatusHeaders() {
        var status = RepositoryStatus(root: "/r")
        status.read(statusOutput: """
        # branch.oid 1234567890abcdef
        # branch.head feat/native-kotlin
        # branch.upstream origin/feat/native-kotlin
        # branch.ab +17 -2
        1 .M N... 100644 100644 100644 aaa aaa file.txt
        """)
        #expect(status.branch == "feat/native-kotlin")
        #expect(status.shortOID == "1234567")
        #expect(status.upstream == "origin/feat/native-kotlin")
        #expect(status.ahead == 17 && status.behind == 2)
        #expect(status.isDirty)
        #expect(status.title == "feat/native-kotlin")
    }

    @Test func aDetachedHeadShowsItsCommitAndCantPush() {
        var status = RepositoryStatus(root: "/r")
        status.read(statusOutput: "# branch.oid abcdef1234\n# branch.head (detached)\n")
        status.remote = "origin"
        #expect(status.title == "abcdef1")
        #expect(!status.isDirty)
        #expect(!status.canPush && !status.canPublish)
    }

    @Test func aBranchWithNoCommitsHasNothingToPublish() {
        var status = RepositoryStatus(root: "/r")
        status.read(statusOutput: "# branch.oid (initial)\n# branch.head main\n")
        status.remote = "origin"
        #expect(!status.canPublish)
    }

    @Test func prefersWhatTheBranchTracksThenOrigin() {
        #expect(RepositoryStatus.chooseRemote(tracked: "fork", all: ["origin", "fork"]) == "fork")
        #expect(RepositoryStatus.chooseRemote(tracked: nil, all: ["fork", "origin"]) == "origin")
        #expect(RepositoryStatus.chooseRemote(tracked: nil, all: ["fork"]) == "fork")
        #expect(RepositoryStatus.chooseRemote(tracked: nil, all: []) == nil)
        // A branch tracking another local branch has "." as its remote.
        #expect(RepositoryStatus.chooseRemote(tracked: ".", all: ["origin"]) == "origin")
    }

    @Test func countsAheadAndPushes() throws {
        let place = try Place()
        try place.commit("second", in: place.work)
        try place.commit("third", in: place.work)
        let before = try #require(Git.repositoryStatus(of: place.work))
        #expect(before.branch == "main" && before.upstream == "origin/main" && before.remote == "origin")
        #expect(before.ahead == 2 && before.behind == 0 && !before.isDirty)
        #expect(before.canPush)
        #expect(succeeded(Git.transfer(before.pushArguments, in: place.work, path: nil)))
        let after = try #require(Git.repositoryStatus(of: place.work))
        #expect(after.ahead == 0 && !after.canPush)
    }

    @Test func fetchFindsWhatsBehind() throws {
        let place = try Place()
        let other = try place.secondClone()
        try place.commit("theirs", in: other)
        try place.git(in: other, "push", "-q")
        #expect(try #require(Git.repositoryStatus(of: place.work)).behind == 0)
        #expect(succeeded(Git.transfer(["fetch", "origin"], in: place.work, path: nil)))
        #expect(try #require(Git.repositoryStatus(of: place.work)).behind == 1)
    }

    @Test func aRefusedPushSaysWhatToDo() throws {
        let place = try Place()
        let other = try place.secondClone()
        try place.commit("theirs", in: other)
        try place.git(in: other, "push", "-q")
        try place.commit("mine", in: place.work)
        let status = try #require(Git.repositoryStatus(of: place.work))
        guard case .failure(let failure) = Git.transfer(status.pushArguments, in: place.work, path: nil) else {
            Issue.record("the push should be refused")
            return
        }
        #expect(failure.message.contains("Pull them first"))
    }

    @Test func publishesANewBranch() throws {
        let place = try Place()
        try place.git(in: place.work, "checkout", "-q", "-b", "feat/new")
        try place.commit("feature", in: place.work)
        let before = try #require(Git.repositoryStatus(of: place.work))
        #expect(before.upstream == nil && before.canPublish && !before.canPush)
        #expect(succeeded(Git.transfer(before.pushArguments, in: place.work, path: nil)))
        let after = try #require(Git.repositoryStatus(of: place.work))
        #expect(after.upstream == "origin/feat/new" && after.ahead == 0)
    }

    @Test func aMissingRemoteFailsWithGitsReason() throws {
        let place = try Place()
        try place.git(in: place.work, "remote", "set-url", "origin", place.base + "/gone.git")
        guard case .failure(let failure) = Git.transfer(["fetch", "origin"], in: place.work, path: nil) else {
            Issue.record("the fetch should fail")
            return
        }
        #expect(failure.message.contains("fatal:"))
    }

    @Test func aFolderInsideARepositoryCountsOnce() throws {
        let place = try Place()
        let inner = place.work + "/inner"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        #expect(Git.repositoriesAcross([place.work, inner]).count == 1)
        #expect(Git.repositoriesAcross([place.base]).isEmpty)
    }

    /// Someone else pushes a commit, and this clone knows about it.
    private func moveOriginOn(_ place: Place, file: String = "theirs") throws {
        let other = place.base + "/other-\(file)"
        try place.git(in: place.base, "clone", "-q", place.origin, other)
        try place.commit(file, in: other)
        try place.git(in: other, "push", "-q")
        #expect(succeeded(Git.transfer(["fetch", "origin"], in: place.work, path: nil)))
    }

    @Test func pullsForward() throws {
        let place = try Place()
        try moveOriginOn(place)
        #expect(try #require(Git.repositoryStatus(of: place.work)).behind == 1)
        #expect(succeeded(Git.transfer(Git.pullArguments, in: place.work, path: nil)))
        let after = try #require(Git.repositoryStatus(of: place.work))
        #expect(after.behind == 0 && after.ahead == 0)
        #expect(FileManager.default.fileExists(atPath: place.work + "/theirs.txt"))
    }

    @Test func pullKeepsUncommittedWorkInOtherFiles() throws {
        let place = try Place()
        try moveOriginOn(place)
        try "mine".write(toFile: place.work + "/first.txt", atomically: true, encoding: .utf8)
        #expect(succeeded(Git.transfer(Git.pullArguments, in: place.work, path: nil)))
        #expect(try String(contentsOfFile: place.work + "/first.txt", encoding: .utf8) == "mine")
        #expect(try #require(Git.repositoryStatus(of: place.work)).isDirty)
    }

    @Test func pullWontMergeDivergedBranches() throws {
        let place = try Place()
        try moveOriginOn(place)
        try place.commit("mine", in: place.work)
        let before = try #require(Git.repositoryStatus(of: place.work))
        #expect(before.ahead == 1 && before.behind == 1)
        guard case .failure(let failure) = Git.transfer(Git.pullArguments, in: place.work, path: nil) else {
            Issue.record("the pull should be refused")
            return
        }
        #expect(failure.message.contains("have moved on"))
        // Nothing changed: not merged, and no merge left half done.
        let after = try #require(Git.repositoryStatus(of: place.work))
        #expect(after.ahead == 1 && after.behind == 1 && !after.isDirty && after.shortOID == before.shortOID)
    }

    @Test func pullWontOverwriteUncommittedWork() throws {
        let place = try Place()
        try moveOriginOn(place)
        try "mine".write(toFile: place.work + "/theirs.txt", atomically: true, encoding: .utf8)
        guard case .failure(let failure) = Git.transfer(Git.pullArguments, in: place.work, path: nil) else {
            Issue.record("the pull should be refused")
            return
        }
        #expect(failure.message.contains("Commit or stash"))
        #expect(try String(contentsOfFile: place.work + "/theirs.txt", encoding: .utf8) == "mine")
    }

    @Test func gitsHintsArentTheReason() {
        let message = Git.failureMessage("hint: try this\nremote: working\nfatal: could not read Username\n")
        #expect(message == "fatal: could not read Username")
    }
}
