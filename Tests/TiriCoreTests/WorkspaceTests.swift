import Foundation
import Testing
@testable import TiriCore

private func file(_ name: String, preview: Bool = false) -> Item {
    Item(id: name, content: .file(FileSpec(path: "/w/\(name)")), isPreview: preview)
}

@Suite struct LayoutTests {
    @Test func newWorkspaceStartsWithTerminalInFirstFolder() {
        var workspace = Workspace(name: "w", folders: ["/a", "/b"])
        workspace.addInitialTerminal(fallbackCwd: "/home")
        guard case .terminal(let spec) = workspace.items.first?.content else {
            Issue.record("expected terminal")
            return
        }
        #expect(spec.cwd == "/a")
        #expect(workspace.focused.tabs == [workspace.items[0].id])
    }

    @Test func noFolderTerminalUsesFallback() {
        var workspace = Workspace(name: "w")
        workspace.addInitialTerminal(fallbackCwd: "/home")
        if case .terminal(let spec) = workspace.items[0].content {
            #expect(spec.cwd == "/home")
        }
    }

    @Test func previewReplacesPreviewInPlace() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("pinned"))
        workspace.openFile(path: "/w/one", preview: true)
        let pinnedIndex = workspace.focused.tabs.firstIndex(of: "pinned")!
        let previewID = workspace.focused.active!
        #expect(workspace.item(previewID)?.isPreview == true)

        workspace.openFile(path: "/w/two", preview: true)
        #expect(workspace.focused.tabs.count == 2)
        #expect(workspace.fileItem(path: "/w/one") == nil)
        #expect(workspace.items.count == 2)
        #expect(workspace.focused.tabs.firstIndex(of: "pinned") == pinnedIndex)
        #expect(workspace.activeItem?.filePath == "/w/two")
    }

    @Test func closingReturnsToMostRecentlyUsed() {
        var workspace = Workspace(name: "w")
        for name in ["a", "b", "c", "d"] { workspace.addItem(file(name)) }
        workspace.activate("a")
        workspace.activate("d")
        workspace.close("d")
        #expect(workspace.activeItem?.id == "a")
    }

    @Test func closingLastInGroupReturnsToMostRecentGroup() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        let first = workspace.focusedGroup
        workspace.addItem(file("b"), split: .right)
        let second = workspace.focusedGroup
        workspace.addItem(file("c"), split: .right)
        workspace.focusGroup(id: first)
        workspace.focusGroup(id: second)
        workspace.focusGroup(id: workspace.groups[2].id)
        workspace.close("c")
        #expect(workspace.focusedGroup == second)
    }

    @Test func previewLandsRightOfActiveTab() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.openFile(path: "/w/p", preview: true)
        workspace.addItem(file("b"))
        #expect(workspace.focused.tabs.count == 3)
        workspace.openFile(path: "/w/x", preview: true)
        #expect(workspace.focused.tabs.count == 3)
        #expect(workspace.focused.tabs[0] == "a")
        #expect(workspace.focused.tabs[1] == "b")
        #expect(workspace.activeItem?.filePath == "/w/x")
    }

    @Test func movingATabPinsIt() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("p", preview: true))
        workspace.moveTab("p", toGroup: workspace.focusedGroup, index: 0)
        #expect(workspace.item("p")?.isPreview == false)
        workspace.addItem(file("q", preview: true))
        workspace.moveTab("q", splitting: workspace.focusedGroup, direction: .right)
        #expect(workspace.item("q")?.isPreview == false)
    }

    @Test func pinnedTabSurvivesNextPreview() {
        var workspace = Workspace(name: "w")
        workspace.openFile(path: "/w/one", preview: true)
        workspace.pin(workspace.focused.active!)
        workspace.openFile(path: "/w/two", preview: true)
        #expect(workspace.focused.tabs.count == 2)
    }

    @Test func doubleClickPinsExistingPreview() {
        var workspace = Workspace(name: "w")
        workspace.openFile(path: "/w/one", preview: true)
        let id = workspace.focused.active!
        let result = workspace.openFile(path: "/w/one", preview: false)
        #expect(result == .revealedExisting(id))
        #expect(workspace.item(id)?.isPreview == false)
    }

    @Test func openExistingFocusesItsGroup() {
        var workspace = Workspace(name: "w")
        workspace.openFile(path: "/w/one", preview: false)
        let first = workspace.focusedGroup
        workspace.openFile(path: "/w/two", preview: false, split: .right)
        #expect(workspace.groups.count == 2)
        workspace.openFile(path: "/w/one", line: 9, preview: true)
        #expect(workspace.focusedGroup == first)
        if case .file(let spec) = workspace.fileItem(path: "/w/one")!.content {
            #expect(spec.line == 9)
        }
    }

    @Test func splitRightFlattensIntoOneSplit() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"), split: .right)
        workspace.addItem(file("c"), split: .right)
        #expect(workspace.groups.map(\.tabs) == [["a"], ["b"], ["c"]])
        guard case .split(let split) = workspace.layout else {
            Issue.record("expected split")
            return
        }
        #expect(split.children.count == 3)
        #expect(abs(split.ratios.reduce(0, +) - 1) < 0.001)
    }

    @Test func splitDownNestsInsideHorizontal() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"), split: .right)
        workspace.addItem(file("c"), split: .down)
        guard case .split(let root) = workspace.layout, case .split(let inner) = root.children[1] else {
            Issue.record("expected nested split")
            return
        }
        #expect(root.axis == .horizontal)
        #expect(inner.axis == .vertical)
        #expect(workspace.groups.map(\.tabs) == [["a"], ["b"], ["c"]])
    }

    @Test func closingLastTabCollapsesGroup() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"), split: .right)
        workspace.close("b")
        #expect(workspace.groups.count == 1)
        guard case .group = workspace.layout else {
            Issue.record("split should collapse")
            return
        }
        #expect(workspace.focused.tabs == ["a"])
    }

    @Test func closingEverythingLeavesEmptyGroup() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.close("a")
        #expect(workspace.groups.count == 1)
        #expect(workspace.focused.tabs.isEmpty)
        #expect(workspace.items.isEmpty)
        #expect(workspace.popClosed()?.id == "a")
    }

    @Test func closeInUnfocusedGroupKeepsFocus() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        let first = workspace.focusedGroup
        workspace.addItem(file("b"), split: .right)
        workspace.focusGroup(id: first)
        workspace.close("b")
        #expect(workspace.focusedGroup == first)
    }

    @Test func moveTabBetweenGroups() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("a2"))
        let first = workspace.focusedGroup
        workspace.addItem(file("b"), split: .right)
        workspace.moveTab("a2", toGroup: workspace.focusedGroup, index: 0)
        #expect(workspace.groups.map(\.tabs) == [["a"], ["a2", "b"]])
        #expect(workspace.activeItem?.id == "a2")
        workspace.moveTab("a", toGroup: workspace.focusedGroup)
        #expect(workspace.groups.count == 1)
        #expect(workspace.group(id: first) == nil)
    }

    @Test func reorderWithinGroup() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"))
        workspace.addItem(file("c"))
        let group = workspace.focusedGroup
        workspace.moveTab("a", toGroup: group, index: 3)
        #expect(workspace.focused.tabs == ["b", "c", "a"])
        workspace.moveTab("c", toGroup: group, index: 0)
        #expect(workspace.focused.tabs == ["c", "b", "a"])
    }

    @Test func dragTabToEdgeSplits() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"))
        workspace.moveTab("b", splitting: workspace.focusedGroup, direction: .left)
        #expect(workspace.groups.map(\.tabs) == [["b"], ["a"]])
    }

    @Test func dragOnlyTabToOwnEdgeIsNoOp() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        let before = workspace.layout
        workspace.moveTab("a", splitting: workspace.focusedGroup, direction: .right)
        #expect(workspace.layout == before)
    }

    @Test func dragOnlyTabToOtherGroupEdgeRemovesSource() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        let first = workspace.focusedGroup
        workspace.addItem(file("b"), split: .right)
        workspace.moveTab("b", splitting: first, direction: .down)
        #expect(workspace.groups.map(\.tabs) == [["a"], ["b"]])
        guard case .split(let split) = workspace.layout else {
            Issue.record("expected split")
            return
        }
        #expect(split.axis == .vertical)
    }

    @Test func cycleWraps() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"))
        workspace.cycleTab(by: 1)
        #expect(workspace.activeItem?.id == "a")
        workspace.cycleTab(by: -1)
        #expect(workspace.activeItem?.id == "b")
    }

    @Test func ratiosNormalize() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"), split: .right)
        guard case .split(let split) = workspace.layout else { return }
        workspace.setRatios(splitID: split.id, ratios: [3, 1])
        guard case .split(let updated) = workspace.layout else { return }
        #expect(updated.ratios == [0.75, 0.25])
    }

    @Test func relativePathsUseLongestFolder() {
        let workspace = Workspace(name: "w", folders: ["/a", "/a/b"])
        #expect(workspace.relativePath("/a/b/c.txt") == "c.txt")
        #expect(workspace.relativePath("/a/x.txt") == "x.txt")
        #expect(workspace.relativePath("/other/x.txt") == "/other/x.txt")
        #expect(workspace.folder(containing: "/ab/x") == nil)
    }
}

@Suite struct PeekTests {
    @Test func peekDoesNotTouchTabs() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        let result = workspace.peekFile(path: "/w/report.md", line: 3)
        guard case .peeking(let id, replaced: nil) = result else {
            Issue.record("expected a new peek")
            return
        }
        #expect(workspace.peek?.id == id)
        #expect(workspace.focused.tabs == ["a"])
        #expect(workspace.items.count == 1)
    }

    @Test func newPeekReplacesOld() {
        var workspace = Workspace(name: "w")
        guard case .peeking(let first, _) = workspace.peekFile(path: "/w/one") else { return }
        let result = workspace.peekFile(path: "/w/two")
        guard case .peeking(_, replaced: let replaced) = result else {
            Issue.record("expected a new peek")
            return
        }
        #expect(replaced == first)
        #expect(workspace.peek?.filePath == "/w/two")
    }

    @Test func peekOfOpenFileFocusesItsTab() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"))
        let result = workspace.peekFile(path: "/w/a", line: 7)
        #expect(result == .revealedExisting("a"))
        #expect(workspace.peek == nil)
        #expect(workspace.activeItem?.id == "a")
    }

    @Test func revealingATabClosesThePeek() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.peekFile(path: "/w/other")
        #expect(workspace.peekFile(path: "/w/a") == .revealedExisting("a"))
        #expect(workspace.peek == nil)
    }

    @Test func agentPeekNeverSwitchesTabs() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.addItem(file("b"))
        let result = workspace.peekFile(path: "/w/a", revealExisting: false)
        guard case .peeking = result else {
            Issue.record("expected a peek")
            return
        }
        #expect(workspace.activeItem?.id == "b")
        #expect(workspace.peek?.filePath == "/w/a")
    }

    @Test func promoteKeepsIDAndPins() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        guard case .peeking(let id, _) = workspace.peekFile(path: "/w/report.md") else { return }
        #expect(workspace.promotePeek() == id)
        #expect(workspace.peek == nil)
        #expect(workspace.focused.tabs == ["a", id])
        #expect(workspace.item(id)?.isPreview == false)
        #expect(workspace.focused.active == id)
    }

    @Test func promoteToSideSplits() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("a"))
        workspace.peekFile(path: "/w/report.md")
        let id = workspace.promotePeek(split: .right)!
        #expect(workspace.groups.map(\.tabs) == [["a"], [id]])
    }

    @Test func dismissRemovesEverything() {
        var workspace = Workspace(name: "w")
        workspace.peekFile(path: "/w/report.md")
        #expect(workspace.dismissPeek() != nil)
        #expect(workspace.peek == nil)
        #expect(workspace.items.isEmpty)
        #expect(workspace.closed.isEmpty)
    }

    @Test func promoteWithNoPeekIsNoOp() {
        var workspace = Workspace(name: "w")
        #expect(workspace.promotePeek() == nil)
    }
}

@Suite struct RetargetTests {
    @Test func renameKeepsTabsInPlace() {
        var workspace = Workspace(name: "w")
        workspace.addItem(file("t1"))
        let first = workspace.focusedGroup
        workspace.addItem(file("a", preview: true), split: .right)
        workspace.addItem(file("b"))
        workspace.focusGroup(id: first)
        let before = workspace.groups.map(\.tabs)
        #expect(workspace.retargetFiles(from: "/w/a", to: "/w/z.md") == ["a"])
        #expect(workspace.groups.map(\.tabs) == before)
        #expect(workspace.focusedGroup == first)
        #expect(workspace.item("a")?.filePath == "/w/z.md")
        #expect(workspace.item("a")?.isPreview == true)
    }

    @Test func folderRenameMovesChildrenAndPeek() {
        var workspace = Workspace(name: "w")
        workspace.addItem(Item(id: "x", content: .file(FileSpec(path: "/w/dir/x.md", line: 4))))
        workspace.peekFile(path: "/w/dir/y.md")
        workspace.retargetFiles(from: "/w/dir", to: "/w/new")
        #expect(workspace.item("x")?.filePath == "/w/new/x.md")
        #expect(workspace.peek?.filePath == "/w/new/y.md")
        if case .file(let spec) = workspace.item("x")!.content { #expect(spec.line == 4) }
    }

    @Test func similarNamesAreLeftAlone() {
        var workspace = Workspace(name: "w")
        workspace.addItem(Item(id: "x", content: .file(FileSpec(path: "/w/dir2/x.md"))))
        #expect(workspace.retargetFiles(from: "/w/dir", to: "/w/new").isEmpty)
    }
}

@Suite struct PersistenceTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-test-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func workspaceJSONRoundTrip() throws {
        var workspace = Workspace(name: "api", folders: ["/a", "/b"])
        workspace.addItem(Item(content: .terminal(TerminalSpec(command: "claude", cwd: "/a", title: "agent"))))
        workspace.addItem(file("x", preview: true), split: .right)
        workspace.addItem(Item(content: .web(WebSpec(url: "http://localhost:3000", forceDark: true))), split: .down)
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == workspace)
    }

    @Test func storeRoundTripWithTwoFolders() throws {
        let directory = temporaryDirectory()
        let store = WorkspaceStore(directory: directory)
        var one = Workspace(name: "one", folders: ["/a", "/b"])
        one.addInitialTerminal(fallbackCwd: "/")
        one.addItem(file("readme"), split: .right)
        let two = Workspace(name: "two")
        let snapshot = WorkspaceStore.Snapshot(workspaces: [one, two], activeID: one.id)
        try store.save(snapshot)
        let loaded = store.load()
        #expect(loaded == snapshot)
    }

    @Test func peekIsNotPersisted() throws {
        let store = WorkspaceStore(directory: temporaryDirectory())
        var workspace = Workspace(name: "one")
        workspace.peekFile(path: "/w/x")
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        #expect(store.load()?.workspaces.first?.peek == nil)
    }

    @Test func corruptIndexKeepsLayoutsThroughTheNextSave() throws {
        let directory = temporaryDirectory()
        let store = WorkspaceStore(directory: directory)
        let workspace = Workspace(name: "precious", folders: ["/a"])
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        try "{ not json".write(to: directory.appendingPathComponent("workspaces.json"), atomically: true, encoding: .utf8)
        #expect(store.load() == nil)
        // What the app does next: start fresh, and save.
        try store.save(.init(workspaces: [Workspace(name: "Home")], activeID: nil))
        let kept = directory.appendingPathComponent("layouts.corrupt/\(workspace.id).json")
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func corruptLayoutIsBackedUp() throws {
        let directory = temporaryDirectory()
        let store = WorkspaceStore(directory: directory)
        let workspace = Workspace(name: "w", folders: ["/a"])
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let layout = directory.appendingPathComponent("layouts/\(workspace.id).json")
        try "garbage".write(to: layout, atomically: true, encoding: .utf8)
        #expect(store.load()?.workspaces.first?.folders == ["/a"])
        let backup = directory.appendingPathComponent("\(workspace.id).layout.corrupt.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "garbage")
    }

    @Test func deletedWorkspaceLosesItsLayout() throws {
        let directory = temporaryDirectory()
        let store = WorkspaceStore(directory: directory)
        let workspace = Workspace(name: "gone")
        try store.save(.init(workspaces: [workspace], activeID: nil))
        let layout = directory.appendingPathComponent("layouts/\(workspace.id).json")
        #expect(FileManager.default.fileExists(atPath: layout.path))
        try store.save(.init(workspaces: [], activeID: nil))
        #expect(!FileManager.default.fileExists(atPath: layout.path))
    }

    @Test func corruptIndexIsBackedUpNotLost() throws {
        let directory = temporaryDirectory()
        let index = directory.appendingPathComponent("workspaces.json")
        try "{ not json".write(to: index, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(directory: directory).load() == nil)
        let backup = directory.appendingPathComponent("workspaces.corrupt.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test func missingLayoutStillLoadsWorkspace() throws {
        let directory = temporaryDirectory()
        let store = WorkspaceStore(directory: directory)
        let workspace = Workspace(name: "w", folders: ["/a"])
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("layouts/\(workspace.id).json"))
        let loaded = store.load()
        #expect(loaded?.workspaces.first?.folders == ["/a"])
        #expect(loaded?.workspaces.first?.groups.count == 1)
    }
}

@Suite struct CodeWorkspaceImportTests {
    private let fileURL = URL(fileURLWithPath: "/projects/team/team.code-workspace")

    private func parse(_ text: String) throws -> CodeWorkspaceImporter.Imported {
        try CodeWorkspaceImporter.parse(data: Data(text.utf8), fileURL: fileURL)
    }

    @Test func relativeAndAbsoluteFolders() throws {
        let imported = try parse(#"""
        {
          "folders": [
            { "path": "." },
            { "path": "../api" },
            { "name": "Docs", "path": "/abs/docs" }
          ],
          "settings": {}
        }
        """#)
        #expect(imported.name == "team")
        #expect(imported.folders == ["/projects/team", "/projects/api", "/abs/docs"])
    }

    @Test func commentsAndTrailingCommas() throws {
        let imported = try parse(#"""
        {
          // Cursor writes these
          "folders": [
            { "path": "a" }, /* inline */
            { "path": "b" },
          ],
        }
        """#)
        #expect(imported.folders == ["/projects/team/a", "/projects/team/b"])
    }

    @Test func fileURIsKeptRemoteSkipped() throws {
        let imported = try parse(#"""
        { "folders": [
          { "uri": "file:///Users/me/thing" },
          { "uri": "vscode-remote://ssh-remote+host/home/me" }
        ] }
        """#)
        #expect(imported.folders == ["/Users/me/thing"])
    }

    @Test func duplicatesCollapse() throws {
        let imported = try parse(#"{ "folders": [ {"path":"a"}, {"path":"./a"} ] }"#)
        #expect(imported.folders == ["/projects/team/a"])
    }

    @Test func tildeExpands() throws {
        let imported = try parse(#"{ "folders": [ {"path":"~/x"} ] }"#)
        #expect(imported.folders == [NSHomeDirectory() + "/x"])
    }

    @Test func noFoldersIsAnError() {
        #expect(throws: CodeWorkspaceImporter.ImportError.self) { try parse(#"{ "folders": [] }"#) }
        #expect(throws: CodeWorkspaceImporter.ImportError.self) { try parse(#"{ "settings": {} }"#) }
    }

    @Test func slashesInsideStringsSurviveCommentStripping() throws {
        let imported = try parse(#"{ "folders": [ {"path":"//server/share // not comment"} ] }"#)
        #expect(imported.folders.count == 1)
    }
}

@Suite struct RestoreTests {
    private let resume = ["claude": "claude --continue", "codex": "codex resume --last"]
    private func plan(_ command: String?, session: String? = nil, enabled: Bool = true) -> TerminalRestore.Plan {
        TerminalRestore.plan(for: command, sessionID: session, resume: resume, enabled: enabled)
    }

    @Test(arguments: [
        ("claude", "claude --continue"),
        ("codex", "codex resume --last"),
        ("claude --model opus", "claude --continue --model opus"),
        ("claude --continue", "claude --continue"),
        ("claude --resume abc", "claude --resume abc"),
        ("codex resume --last", "codex resume --last"),
        ("/usr/local/bin/claude", "claude --continue"),
    ])
    func agentsResume(input: String, expected: String) {
        #expect(plan(input) == .run(expected))
    }

    @Test func storedSessionWins() {
        #expect(plan("claude", session: "abc-1") == .run("claude --resume abc-1"))
        #expect(plan("claude --model x", session: "abc") == .run("claude --resume abc --model x"))
        #expect(plan("codex", session: "t1") == .run("codex resume t1"))
        #expect(plan("claude --continue", session: "abc") == .run("claude --resume abc"))
    }

    @Test func oddSessionIDIsNotPutInACommand() {
        #expect(plan("claude", session: "x; rm -rf /") == .run("claude --continue"))
    }

    @Test(arguments: [
        "claude \"delete old migrations\"",
        "claude 'do it'",
        "claude fix the bug",
        "claude --model opus \"do it\"",
        "claude --model opus fix it",
    ])
    func promptsAreNeverReplayed(command: String) {
        #expect(plan(command) == .run("claude --continue"))
        #expect(plan(command, session: "s1") == .run("claude --resume s1"))
    }

    @Test(arguments: ["./deploy.sh", "npm run dev", "rm -rf build", "make"])
    func otherCommandsWaitAtThePrompt(command: String) {
        #expect(plan(command) == .prefill(command))
        #expect(plan(command, session: "abc") == .prefill(command))
    }

    @Test(arguments: ["claude -p hello", "claude --print hello", "codex exec fix"])
    func oneShotAgentRunsWaitAtThePrompt(command: String) {
        #expect(plan(command) == .prefill(command))
    }

    @Test func disabledRunsThePlainAgent() {
        #expect(plan("claude", enabled: false) == .run("claude"))
        #expect(plan("claude \"do it\"", enabled: false) == .run("claude"))
    }

    @Test func shellStaysShell() {
        #expect(plan(nil) == .shell)
        #expect(plan("  ") == .shell)
    }
}

@Suite struct AgentHookTests {
    private func claude(_ json: String) -> AgentHookEvent? { AgentHookEvent.parseClaude(Data(json.utf8)) }
    private func codex(_ json: String) -> AgentHookEvent? { AgentHookEvent.parseCodex(Data(json.utf8)) }

    @Test func claudeLifecycle() {
        #expect(claude(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#) == AgentHookEvent(sessionID: "s1"))
        #expect(claude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#)?.state == "working")
        #expect(claude(#"{"hook_event_name":"PostToolUse"}"#)?.state == "working")
        #expect(claude(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#) == AgentHookEvent(state: "needs-input", message: "Wants to use Bash"))
        #expect(claude(#"{"hook_event_name":"Stop","last_assistant_message":"All done.\nMore."}"#) == AgentHookEvent(state: "done", message: "All done."))
    }

    @Test func claudeIdleNotificationDoesNotAskForAttention() {
        #expect(claude(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting"}"#)?.state == nil)
        #expect(claude(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow?"}"#)?.state == "needs-input")
    }

    @Test func claudeStopWithBackgroundTasksIsStillWorking() {
        #expect(claude(#"{"hook_event_name":"Stop","background_tasks":[{"id":"1"}]}"#)?.state == "working")
        #expect(claude(#"{"hook_event_name":"Stop","background_tasks":[]}"#)?.state == "done")
    }

    @Test func claudeFailureEndsTheTurn() {
        #expect(claude(#"{"hook_event_name":"StopFailure","error":"rate limited"}"#) == AgentHookEvent(state: "done", message: "rate limited"))
    }

    @Test func garbageIsIgnored() {
        #expect(claude("nope") == nil)
        #expect(claude(#"{"hook_event_name":"Whatever"}"#) == nil)
        #expect(codex("nope") == nil)
    }

    @Test func codexNotifyAndHooks() {
        #expect(codex(#"{"type":"agent-turn-complete","thread-id":"t1","last-assistant-message":"Done"}"#) == AgentHookEvent(state: "done", message: "Done", sessionID: "t1"))
        #expect(codex(#"{"hook_event_name":"PermissionRequest","tool_name":"shell"}"#)?.state == "needs-input")
        #expect(codex(#"{"hook_event_name":"Interrupt"}"#)?.state == "done")
    }

    @Test func longMessagesAreTrimmed() {
        let long = String(repeating: "x", count: 500)
        let event = claude(#"{"hook_event_name":"Stop","last_assistant_message":"\#(long)"}"#)
        #expect(event?.message?.count == 140)
    }
}
