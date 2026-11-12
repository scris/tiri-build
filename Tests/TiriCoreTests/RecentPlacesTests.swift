import Foundation
import Testing
@testable import TiriCore

struct RecentPlacesTests {
    let home = "/Users/someone"
    func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }
    func rank(_ sightings: [RecentPlaces.Sighting], closed: [ClosedWorkspace] = [], hidden: [String: Date] = [:],
              open: [String] = [], missing: Set<String> = []) -> [RecentPlace] {
        RecentPlaces.rank(sightings: sightings, closed: closed, hidden: hidden, openFolders: open, home: home, exists: { !missing.contains($0) })
    }

    @Test func newestFirstAndOneEntryPerFolder() {
        let places = rank([
            .init(path: home + "/a", date: day(1)),
            .init(path: home + "/b", date: day(3)),
            .init(path: home + "/a", date: day(5)),
        ])
        #expect(places.map(\.name) == ["a", "b"])
        #expect(places[0].lastUsed == day(5))
    }

    @Test func whatIsntAProjectIsLeftOut() {
        let places = rank([
            .init(path: home, date: day(9)),
            .init(path: home + "/Documents", date: day(9)),
            .init(path: home + "/Downloads", date: day(9)),
            .init(path: "/private/tmp/scratch", date: day(9)),
            .init(path: "/tmp/x", date: day(9)),
            .init(path: "/var/folders/ab/T/y", date: day(9)),
            .init(path: home + "/.codex/memories", date: day(9)),
            .init(path: home + "/Library/Application Support/Tiri/your-tiri/source", date: day(9)),
            .init(path: home + "/gone", date: day(9)),
            .init(path: home + "/Documents/app", date: day(2)),
        ], missing: [home + "/gone"])
        #expect(places.map(\.path) == [home + "/Documents/app"])
    }

    @Test func aSubfolderCountsAsItsProject() {
        let places = rank([
            .init(path: home + "/work/api", date: day(1)),
            .init(path: home + "/work/api/third_party/lib", date: day(4)),
            .init(path: home + "/work/api/docs", date: day(2)),
        ])
        #expect(places.map(\.path) == [home + "/work/api"])
        #expect(places[0].lastUsed == day(4))
    }

    @Test func whatsOpenInTheSidebarIsntRepeated() {
        let places = rank([
            .init(path: home + "/Documents/tiri", date: day(5)),
            .init(path: home + "/Documents/chores/coding", date: day(5)),
            .init(path: home + "/Documents/other", date: day(1)),
        ], open: [home + "/Documents/tiri", home + "/Documents/chores"])
        #expect(places.map(\.name) == ["other"])
    }

    @Test func aRemovedFolderStaysAwayUntilItsUsedAgain() {
        let sightings: [RecentPlaces.Sighting] = [.init(path: home + "/a", date: day(3))]
        #expect(rank(sightings, hidden: [home + "/a": day(4)]).isEmpty)
        #expect(rank(sightings + [.init(path: home + "/a", date: day(6))], hidden: [home + "/a": day(4)]).count == 1)
    }

    @Test func aClosedWorkspaceStandsForItsFolders() {
        let workspace = Workspace(name: "Fluentide", folders: [home + "/radio", home + "/mobile"])
        let places = rank([
            .init(path: home + "/radio", date: day(8)),
            .init(path: home + "/mobile/ios", date: day(2)),
            .init(path: home + "/elsewhere", date: day(5)),
        ], closed: [ClosedWorkspace(workspace: workspace, closedAt: day(3))])
        #expect(places.map(\.name) == ["Fluentide", "elsewhere"])
        #expect(places[0].kind == .closed(workspace.id))
        #expect(places[0].lastUsed == day(8))
    }

    @Test func codeWorkspaceFilesKeepTheirKindAndName() {
        let places = rank([.init(path: home + "/site/resume/TQ.code-workspace", date: day(1), isCodeWorkspace: true),
                           .init(path: home + "/site", date: day(2))])
        #expect(places.map(\.name) == ["site", "TQ"])
        #expect(places[1].kind == .codeWorkspace(home + "/site/resume/TQ.code-workspace"))
    }

    @Test func undatedEntriesGoLast() {
        let places = rank([.init(path: home + "/old", date: nil), .init(path: home + "/new", date: day(1))])
        #expect(places.map(\.name) == ["new", "old"])
        #expect(RecentPlaces.age(of: .distantPast) == "")
    }

    @Test func theStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var store = RecentStore()
        store.closed = [ClosedWorkspace(workspace: Workspace(name: "W", folders: ["/x"]), closedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        store.hidden = ["/y": Date(timeIntervalSince1970: 1_800_000_100)]
        store.save(to: url)
        #expect(RecentStore.load(from: url) == store)
    }

    @Test func findsWhereAConversationRanPastAVeryLongFirstLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let picture = String(repeating: "A", count: 700_000)
        let text = #"{"type":"summary","image":""# + picture + "\"}\n" + #"{"type":"user","cwd":"/Users/someone/my \"site\""}"# + "\n"
        try Data(text.utf8).write(to: file)
        // Past what's read: so it's not found, rather than found wrong.
        #expect(RecentPlaces.firstValue(of: "cwd", in: file.path) == nil)
        try Data((#"{"type":"user","cwd":"/Users/someone/my \"site\"","x":1}"# + "\n").utf8).write(to: file)
        #expect(RecentPlaces.firstValue(of: "cwd", in: file.path) == "/Users/someone/my \"site\"")
    }

    @Test func readsAnEditorsRecentList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recent-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("state.vscdb").path
        let json = #"{"entries":[{"folderUri":"file:///Users/someone/proj%20one"},{"fileUri":"file:///Users/someone/a.txt"},{"workspace":{"id":"x","configPath":"file:///Users/someone/w.code-workspace"}},{"folderUri":"vscode-remote://ssh-remote%2Bbox/home/me"}]}"#
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        make.arguments = [database, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB); INSERT INTO ItemTable VALUES ('history.recentlyOpenedPathsList', '\(json)');"]
        try make.run()
        make.waitUntilExit()
        let entries = RecentPlaces.recentlyOpened(database: database)
        #expect(entries.map(\.path) == ["/Users/someone/proj one", "/Users/someone/w.code-workspace"])
        #expect(entries.map(\.isCodeWorkspace) == [false, true])
    }
}
