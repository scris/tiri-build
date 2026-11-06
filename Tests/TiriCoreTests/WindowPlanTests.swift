import Foundation
import Testing
@testable import TiriCore

@Suite struct WindowPlanTests {
    @Test func noSavedWindowsIsTheMainWindowOnWhatWasActive() {
        let plan = WindowPlan.restore([], workspaces: ["a", "b"], active: "b")
        #expect(plan == [SavedWindow(id: WindowPlan.main, workspace: "b")])
    }

    @Test func savedWindowsComeBackMainFirst() {
        let saved = [SavedWindow(id: "w2", workspace: "b", frame: [10, 20, 800, 600]), SavedWindow(id: WindowPlan.main, workspace: "a")]
        let plan = WindowPlan.restore(saved, workspaces: ["a", "b"], active: "b")
        #expect(plan.map(\.id) == [WindowPlan.main, "w2"])
        #expect(plan.map(\.workspace) == ["a", "b"])
        #expect(plan[1].frame == [10, 20, 800, 600])
    }

    @Test func aWorkspaceIsInOneWindowAtMost() {
        let saved = [SavedWindow(id: WindowPlan.main, workspace: "a"), SavedWindow(id: "w2", workspace: "a"),
                     SavedWindow(id: "w3", workspace: "b"), SavedWindow(id: "w4", workspace: "b")]
        let plan = WindowPlan.restore(saved, workspaces: ["a", "b"], active: "a")
        #expect(plan.map(\.id) == [WindowPlan.main, "w3"])
    }

    @Test func windowsOnDeletedWorkspacesDontComeBack() {
        let saved = [SavedWindow(id: WindowPlan.main, workspace: "gone"), SavedWindow(id: "w2", workspace: "gone too"), SavedWindow(id: "w3", workspace: "b")]
        let plan = WindowPlan.restore(saved, workspaces: ["a", "b"], active: "a")
        #expect(plan.map(\.workspace) == ["a", "b"])
    }

    @Test func theMainWindowFallsBackToAnyWorkspace() {
        let plan = WindowPlan.restore([], workspaces: ["a"], active: "missing")
        #expect(plan.first?.workspace == "a")
    }

    @Test func aWindowWithoutAWorkspaceGetsOneNoWindowHas() {
        #expect(WindowPlan.unshown(["a", "b", "c"], shown: ["a"]) == "b")
        #expect(WindowPlan.unshown(["a", "b", "c"], shown: ["a"], preferring: "c") == "c")
        #expect(WindowPlan.unshown(["a", "b", "c"], shown: ["a", "c"], preferring: "c") == "b")
        #expect(WindowPlan.unshown(["a"], shown: ["a"]) == nil)
    }

    @Test func findingTheWindowThatShowsAWorkspace() {
        let windows = ["z": "b", WindowPlan.main: "a", "y": "c"]
        #expect(WindowPlan.window(showing: "a", in: windows) == WindowPlan.main)
        #expect(WindowPlan.window(showing: "c", in: windows) == "y")
        #expect(WindowPlan.window(showing: "d", in: windows) == nil)
    }

    @Test func storeKeepsWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let one = Workspace(name: "one", folders: ["/a"])
        let two = Workspace(name: "two", folders: ["/b"])
        let windows = [SavedWindow(id: WindowPlan.main, workspace: one.id), SavedWindow(id: "w2", workspace: two.id, frame: [1, 2, 3, 4])]
        let snapshot = WorkspaceStore.Snapshot(workspaces: [one, two], activeID: two.id, windows: windows)
        try store.save(snapshot)
        #expect(store.load() == snapshot)
    }

    /// What one window wrote, before there could be more, still reads.
    @Test func storeWithoutWindowsStillReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let one = Workspace(name: "one", folders: ["/a"])
        try store.save(.init(workspaces: [one], activeID: one.id))
        let index = try String(contentsOf: directory.appendingPathComponent("workspaces.json"), encoding: .utf8)
        #expect(!index.contains("windows"))
        #expect(store.load()?.windows == [])
    }

    @Test func windowCommands() throws {
        let environment = CLIParser.Environment(cwd: "/work", itemID: nil, fileExists: { _ in false })
        func request(_ arguments: String...) throws -> ControlRequest {
            guard case .request(let request, _) = try CLIParser.parse(arguments, environment: environment) else { throw CLIParser.UsageError("not a request") }
            return request
        }
        #expect(try request("window", "list").cmd == "window.list")
        #expect(try request("window", "new").cmd == "window.new")
        #expect(try request("window", "new").args["workspace"] == nil)
        #expect(try request("window", "new", "api").args["workspace"] == "api")
        #expect(try request("window", "focus", "api").cmd == "window.focus")
        #expect(try request("window", "close", "w2").args["window"] == "w2")
        #expect(throws: CLIParser.UsageError.self) { try request("window", "focus") }
        #expect(throws: CLIParser.UsageError.self) { try request("window", "nonsense") }
    }

    @Test func windowListReads() {
        let response = ControlResponse.success(id: "1", .array([
            .object(["id": "main", "workspace": "api", "current": true]),
            .object(["id": "w2", "workspace": "web", "current": false]),
        ]))
        let text = CLIOutput.text(request: ControlRequest(cmd: "window.list"), response: response)
        #expect(text == "* main\tapi\n  w2\tweb\n")
    }
}
