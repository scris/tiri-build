import Foundation
import Testing
@testable import TiriCore

/// A real repository, because what matters here is what git does and doesn't touch.
private struct Repository {
    let root: String
    let store: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-turn-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = Git.real(folder.path)
        store = base.appendingPathComponent("snapshots")
        try git("init", "-q", "-b", "main")
        try write("a.txt", "one\ntwo\n")
        try write(".gitignore", "ignored.txt\n")
        try git("add", ".")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first")
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func listing(_ relative: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root + "/" + relative)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }
}

// One at a time: each runs git many times, and a busy machine slows down tests that have time limits.
@Suite(.serialized) struct TurnSnapshotTests {
    @Test func aTurnShowsOnlyWhatItChanged() throws {
        let repo = try Repository()
        // Uncommitted work from before the turn isn't the turn's.
        try repo.write("before.txt", "already here\n")
        let snapshots = TurnSnapshots(directory: repo.store)
        let start = try #require(snapshots.snapshot(root: repo.root))
        try repo.write("a.txt", "one\nTWO\n")
        try repo.write("new.txt", "fresh\n")
        let end = try #require(snapshots.snapshot(root: repo.root))
        let changes = snapshots.changes(root: repo.root, from: start, to: end)
        #expect(changes.map(\.relative) == ["a.txt", "new.txt"])
        #expect(changes.map(\.status) == [.modified, .added])
        let diff = snapshots.diff(root: repo.root, relative: "a.txt", from: start, to: end)
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
    }

    @Test func aDeletedFileIsReportedAndItsOldTextIsStillThere() throws {
        let repo = try Repository()
        let snapshots = TurnSnapshots(directory: repo.store)
        let start = try #require(snapshots.snapshot(root: repo.root))
        try FileManager.default.removeItem(atPath: repo.root + "/a.txt")
        let end = try #require(snapshots.snapshot(root: repo.root))
        #expect(snapshots.changes(root: repo.root, from: start, to: end).map(\.status) == [.deleted])
        #expect(snapshots.diff(root: repo.root, relative: "a.txt", from: start, to: end).deletions == 2)
    }

    @Test func leavesTheRepositoryExactlyAsItWas() throws {
        let repo = try Repository()
        try repo.write("a.txt", "staged\n")
        try repo.git("add", "a.txt")
        try repo.write("untracked.txt", "not staged\n")
        let status = try repo.git("status", "--porcelain=v1")
        let refs = try repo.git("for-each-ref")
        let stash = try repo.git("stash", "list")
        let objects = repo.listing(".git/objects")
        let index = try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index"))

        let snapshots = TurnSnapshots(directory: repo.store)
        let tree = try #require(snapshots.snapshot(root: repo.root))
        try repo.write("later.txt", "more\n")
        _ = snapshots.snapshot(root: repo.root)

        #expect(try repo.git("for-each-ref") == refs)
        #expect(try repo.git("stash", "list") == stash)
        #expect(repo.listing(".git/objects") == objects)
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index")) == index)
        try FileManager.default.removeItem(atPath: repo.root + "/later.txt")
        #expect(try repo.git("status", "--porcelain=v1") == status)
        // The snapshot itself isn't something the repository knows about.
        #expect(try repo.git("cat-file", "-t", tree).isEmpty)
    }

    @Test func leavesOutWhatGitIgnores() throws {
        let repo = try Repository()
        let snapshots = TurnSnapshots(directory: repo.store)
        let start = try #require(snapshots.snapshot(root: repo.root))
        try repo.write("ignored.txt", "secret\n")
        let end = try #require(snapshots.snapshot(root: repo.root))
        #expect(start == end)
    }

    @Test func anOpenTurnComparesAgainstTheFilesAsTheyAreNow() throws {
        let repo = try Repository()
        let snapshots = TurnSnapshots(directory: repo.store)
        let start = try #require(snapshots.snapshot(root: repo.root))
        let turn = AgentTurn(workspace: "w", item: "i", title: "claude", startTrees: [repo.root: start])
        try repo.write("a.txt", "changed\n")
        #expect(snapshots.changes(in: turn, folders: [repo.root]).map(\.relative) == ["a.txt"])
        let diff = try #require(snapshots.diff(path: repo.root + "/a.txt", in: turn))
        #expect(diff.additions == 1)
    }

    @Test func aFileOutsideTheTurnsRepositoriesHasNoAnswer() throws {
        let repo = try Repository()
        let turn = AgentTurn(workspace: "w", item: "i", title: "claude", ended: Date(), startTrees: ["/elsewhere": "abc"])
        #expect(TurnSnapshots(directory: repo.store).diff(path: repo.root + "/a.txt", in: turn) == nil)
    }

    @Test func removingStoresKeepsTheOnesStillNeeded() throws {
        let one = try Repository()
        let other = try Repository()
        let snapshots = TurnSnapshots(directory: one.store)
        let kept = try #require(snapshots.snapshot(root: one.root))
        _ = snapshots.snapshot(root: other.root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: one.store.path).count == 2)
        snapshots.removeStores(except: [one.root])
        #expect(try FileManager.default.contentsOfDirectory(atPath: one.store.path).count == 1)
        try one.write("a.txt", "x\n")
        let end = try #require(snapshots.snapshot(root: one.root))
        #expect(snapshots.changes(root: one.root, from: kept, to: end).count == 1)
    }

    @Test func snapshotOutsideARepositoryIsNil() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-norepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(TurnSnapshots(directory: folder.appendingPathComponent("s")).snapshot(root: folder.path) == nil)
    }
}

@Suite struct AgentTurnTests {
    private let start = Date(timeIntervalSince1970: 1000)

    private func turn(_ id: String, item: String = "a", from: Double, to: Double?, roots: [String] = ["/r"], workspace: String = "w") -> AgentTurn {
        var trees: [String: String] = [:]
        for root in roots { trees[root] = id }
        return AgentTurn(id: id, workspace: workspace, item: item, title: id, started: start.addingTimeInterval(from),
                         ended: to.map { start.addingTimeInterval($0) }, startTrees: trees, endTrees: to == nil ? [:] : trees.mapValues { $0 + "e" })
    }

    @Test func overlapNeedsAnotherAgentAtTheSameTimeInTheSamePlace() {
        let one = turn("1", item: "a", from: 0, to: 10)
        #expect(one.overlaps(turn("2", item: "b", from: 5, to: 15)))
        #expect(!one.overlaps(turn("3", item: "b", from: 11, to: 15)))
        #expect(!one.overlaps(turn("4", item: "a", from: 5, to: 15)))
        #expect(!one.overlaps(turn("5", item: "b", from: 5, to: 15, roots: ["/other"])))
        #expect(one.overlaps(turn("6", item: "b", from: 5, to: nil), now: start.addingTimeInterval(20)))
    }

    @Test func aTurnThatOnlyTalkedChangedNothing() {
        var quiet = turn("1", from: 0, to: 1)
        quiet.endTrees = quiet.startTrees
        #expect(quiet.changedNothing)
        #expect(!turn("2", from: 0, to: 1).changedNothing)
        #expect(!turn("3", from: 0, to: nil).changedNothing)
    }

    @Test func scopesResolveWithinAWorkspace() {
        var quiet = turn("quiet", from: 5, to: 6)
        quiet.endTrees = quiet.startTrees
        let turns = [turn("1", from: 0, to: 1), turn("other", from: 2, to: 3, workspace: "x"), quiet]
        #expect(turns.resolving(.latestTurn, in: "w")?.id == "1")
        #expect(turns.resolving(.turn("other"), in: "w")?.id == "other")
        #expect(turns.resolving(.sinceCommit, in: "w") == nil)
        #expect([AgentTurn]().resolving(.latestTurn, in: "w") == nil)
    }

    @Test func oldTurnsGoAndAnOpenOneStays() {
        let now = start.addingTimeInterval(8 * 24 * 3600)
        let turns = [turn("old", from: 0, to: 1), turn("open", from: 0, to: nil), turn("new", from: 8 * 24 * 3600 - 10, to: 8 * 24 * 3600 - 5)]
        #expect(turns.trimmed(now: now).map(\.id) == ["open", "new"])
    }

    @Test func eachWorkspaceKeepsItsNewest() {
        let turns = (0..<5).map { turn("\($0)", from: Double($0), to: Double($0) + 1) } + [turn("x", from: 0, to: 1, workspace: "x")]
        #expect(turns.trimmed(now: start, perWorkspace: 2).map(\.id) == ["3", "4", "x"])
    }

    @Test func aLongPromptIsCut() {
        #expect(AgentTurn.shortPrompt("  fix it\nand more") == "fix it")
        #expect(AgentTurn.shortPrompt(String(repeating: "x", count: 100))?.count == 72)
        #expect(AgentTurn.shortPrompt("   ") == nil)
        #expect(AgentTurn.shortPrompt(nil) == nil)
    }

    @Test func theStoreRemembers() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-turns-\(UUID().uuidString).json")
        let store = TurnStore(file: file)
        #expect(store.load().isEmpty)
        let saved = [turn("1", from: 0, to: 1)]
        store.save(saved)
        #expect(store.load().map(\.id) == ["1"])
        #expect(store.load().first?.endTrees == ["/r": "1e"])
    }
}

@Suite struct TurnHookTests {
    @Test func claudesPromptStartsATurnAndStopEndsIt() {
        let start = AgentHookEvent.parseClaude(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"fix it"}"#.utf8))
        #expect(start?.turn == .start)
        #expect(start?.prompt == "fix it")
        #expect(AgentHookEvent.parseClaude(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8))?.turn == .end)
        #expect(AgentHookEvent.parseClaude(Data(#"{"hook_event_name":"StopFailure","error":"x"}"#.utf8))?.turn == .end)
        #expect(AgentHookEvent.parseClaude(Data(#"{"hook_event_name":"PostToolUse"}"#.utf8))?.turn == nil)
    }

    @Test func workStillRunningInTheBackgroundDoesNotEndATurn() {
        let event = AgentHookEvent.parseClaude(Data(#"{"hook_event_name":"Stop","background_tasks":[{}]}"#.utf8))
        #expect(event?.turn == nil)
    }

    @Test func codexEndsATurn() {
        #expect(AgentHookEvent.parseCodex(Data(#"{"type":"agent-turn-complete","thread-id":"t"}"#.utf8))?.turn == .end)
    }

    @Test func theHookCommandPassesItOn() throws {
        let environment = CLIParser.Environment(cwd: "/p", itemID: "i-1", fileExists: { _ in false }, readStdin: { Data() })
        let payload = #"{"hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#
        guard case .request(let request, _) = try CLIParser.parse(["hook", "claude", payload], environment: environment) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.args["turn"]?.stringValue == "start")
        #expect(request.args["prompt"]?.stringValue == "fix it")
    }
}
