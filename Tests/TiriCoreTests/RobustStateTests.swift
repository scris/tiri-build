import Foundation
import Testing
@testable import TiriCore

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-robust-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite struct ItemContentCodingTests {
    /// What older builds wrote, from Swift's own coding, has to read and write exactly the same.
    @Test func sameShapeAsBefore() throws {
        #expect(try json(ItemContent.settings) == #"{"settings":{}}"#)
        #expect(try json(ItemContent.web(WebSpec(url: "https://a.b"))) == #"{"web":{"_0":{"url":"https://a.b"}}}"#)
        #expect(try json(ItemContent.diff(DiffSpec(path: "/x"))) == #"{"diff":{"_0":{"path":"/x"}}}"#)
        let all: [ItemContent] = [.terminal(TerminalSpec(command: "claude", cwd: "/w", sessionID: "s")), .file(FileSpec(path: "/a", line: 3)),
                                  .web(WebSpec(url: "u", forceDark: true)), .settings, .diff(DiffSpec(path: "/d", turn: "t")),
                                  .plugin(PluginPanelSpec(plugin: "p", panel: "q", args: ["n": 1]))]
        for content in all {
            let data = try JSONEncoder().encode(content)
            #expect(try JSONDecoder().decode(ItemContent.self, from: data) == content)
        }
    }

    @Test func unknownKindIsKeptAsItCame() throws {
        let text = #"{"timer":{"_0":{"minutes":25,"label":"focus","nested":[1,true,null,"x"]}}}"#
        let content = try JSONDecoder().decode(ItemContent.self, from: Data(text.utf8))
        #expect(content.isUnknown)
        #expect(content.kindName == "timer")
        #expect(try json(content) == #"{"timer":{"_0":{"label":"focus","minutes":25,"nested":[1,true,null,"x"]}}}"#)
    }
}

@Suite struct KeptLayoutTests {
    private func layout(items: String, tabs: String, closed: String = "[]") -> String {
        #"{"items":\#(items),"layout":{"group":{"_0":{"id":"g-1","tabs":\#(tabs),"active":"i-file","mru":["i-file"]}}},"focusedGroup":"g-1","closed":\#(closed)}"#
    }

    private func write(_ directory: URL, layout text: String) throws {
        try #"{"version":1,"activeID":"w-1","workspaces":[{"id":"w-1","name":"one","folders":["/p"]}]}"#
            .write(to: directory.appendingPathComponent("workspaces.json"), atomically: true, encoding: .utf8)
        let layouts = directory.appendingPathComponent("layouts", isDirectory: true)
        try FileManager.default.createDirectory(at: layouts, withIntermediateDirectories: true)
        try text.write(to: layouts.appendingPathComponent("w-1.json"), atomically: true, encoding: .utf8)
    }

    private let fileItem = #"{"id":"i-file","content":{"file":{"_0":{"path":"/p/a.txt"}}},"isPreview":false}"#
    private let timerItem = #"{"id":"i-timer","content":{"timer":{"_0":{"minutes":25}}},"isPreview":false,"pinnedBy":"me"}"#
    private let broken = #"{"id":"i-bad","content":{"file":{"_0":{"path":42}}},"isPreview":false}"#

    /// A tab kind from a personal copy: Plain shows the others, hides it, and saves it back where it was.
    @Test func unknownTabIsHiddenAndSavedBack() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, layout: layout(items: "[\(fileItem),\(timerItem)]", tabs: #"["i-timer","i-file"]"#))
        let store = WorkspaceStore(directory: directory)
        let loaded = try #require(store.loadRecovering().snapshot)
        #expect(store.loadRecovering().damaged == false)
        var workspace = loaded.workspaces[0]
        #expect(workspace.items.map(\.id) == ["i-file"])
        #expect(workspace.groups[0].tabs == ["i-file"])
        #expect(workspace.kept?.first?.index == 0)
        // Plain goes on: a new tab, and a save.
        _ = workspace.addItem(Item(id: "i-new", content: .settings))
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let saved = try String(contentsOf: directory.appendingPathComponent("layouts/w-1.json"), encoding: .utf8)
        #expect(saved.contains(#""pinnedBy" : "me""#))
        #expect(saved.contains(#""minutes" : 25"#))
        // The copy that made it reads it back in its place.
        let raw = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: Any]
        let group = ((raw["layout"] as! [String: Any])["group"] as! [String: Any])["_0"] as! [String: Any]
        #expect(group["tabs"] as! [String] == ["i-timer", "i-file", "i-new"])
        #expect((raw["items"] as! [[String: Any]]).compactMap { $0["id"] as? String }.sorted() == ["i-file", "i-new", "i-timer"])
        #expect(raw["version"] as? Int == 1)
        // And Plain again, still without it on screen.
        #expect(store.load()?.workspaces[0].items.map(\.id).sorted() == ["i-file", "i-new"])
    }

    @Test func oneUnreadableItemDoesNotTakeTheRest() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, layout: layout(items: "[\(broken),\(fileItem)]", tabs: #"["i-bad","i-file"]"#, closed: "[\(timerItem)]"))
        let store = WorkspaceStore(directory: directory)
        let result = store.loadRecovering()
        #expect(result.damaged == false)
        let workspace = try #require(result.snapshot?.workspaces.first)
        #expect(workspace.items.map(\.id) == ["i-file"])
        #expect(workspace.closed.isEmpty)
        #expect(workspace.kept?.count == 2)
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let saved = try String(contentsOf: directory.appendingPathComponent("layouts/w-1.json"), encoding: .utf8)
        #expect(saved.contains(#""path" : 42"#))
        #expect(saved.contains("i-timer"))
    }

    @Test func aTabOnItsOwnGoesBackIntoAGroup() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = #"{"items":[\#(fileItem),\#(timerItem)],"layout":{"split":{"_0":{"id":"s-1","axis":"horizontal","ratios":[0.5,0.5],"children":[{"group":{"_0":{"id":"g-1","tabs":["i-file"],"active":"i-file","mru":["i-file"]}}},{"group":{"_0":{"id":"g-2","tabs":["i-timer"],"active":"i-timer","mru":["i-timer"]}}}]}}},"focusedGroup":"g-2","closed":[]}"#
        try write(directory, layout: text)
        let store = WorkspaceStore(directory: directory)
        let workspace = try #require(store.load()?.workspaces.first)
        // Its group had nothing else, so there's no empty pane where it was.
        #expect(workspace.groups.map(\.id) == ["g-1"])
        try store.save(.init(workspaces: [workspace], activeID: workspace.id))
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("layouts/w-1.json"))) as! [String: Any]
        #expect(String(describing: again["layout"]!).contains("i-timer"))
    }

    @Test func newerFormatIsNeverOverwritten() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, layout: layout(items: "[\(fileItem)]", tabs: #"["i-file"]"#))
        let index = directory.appendingPathComponent("workspaces.json")
        let newer = #"{"version":2,"activeID":"w-1","workspaces":[{"id":"w-1","name":"one","folders":["/p"],"color":"red"}]}"#
        try newer.write(to: index, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(directory: directory)
        let workspace = try #require(store.load()?.workspaces.first)
        #expect(workspace.items.count == 1)
        #expect(throws: WorkspaceStore.NewerFormat.self) { try store.save(.init(workspaces: [workspace], activeID: workspace.id)) }
        #expect(try String(contentsOf: index, encoding: .utf8) == newer)
    }
}

@Suite struct DurableFileTests {
    @Test func writesThroughALinkAndKeepsPermissions() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        let link = directory.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")
        try DurableFile.write(#"{"a":1}"#, to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/settings.json")
        #expect(try String(contentsOf: real, encoding: .utf8) == #"{"a":1}"#)
        #expect((try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        // Nothing left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path) == ["settings.json"])
    }

    @Test func aLinkToNothingGetsItsFile() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("keybindings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: directory.appendingPathComponent("real.json").path)
        try DurableFile.write("[]", to: link)
        #expect(try String(contentsOf: directory.appendingPathComponent("real.json"), encoding: .utf8) == "[]")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func copyStateComesBackFromItsLastGoodCopy() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        var state = CopyState()
        state.active = .personal
        state.plainPath = "/Applications/Tiri.app"
        try state.save(to: file)
        try Data("{\"active\": ".utf8).write(to: file)
        #expect(CopyState.load(from: file) == state)
    }
}

@Suite struct LaunchSafetyTests {
    @Test func twoUnfinishedLaunchesStartSafely() {
        let file = scratch().appendingPathComponent("launching.json")
        #expect(LaunchRecord.begin(file: file).safe == false)
        #expect(LaunchRecord.begin(file: file).safe == false)
        #expect(LaunchRecord.begin(file: file).safe == true)
        LaunchRecord.finish(file: file)
        #expect(LaunchRecord.begin(file: file).safe == false)
    }

    @Test func anUpdateIsRememberedUntilALaunchFinishes() {
        let file = scratch().appendingPathComponent("launching.json")
        LaunchRecord.updated(from: "0.1.0", to: "0.2.0", file: file)
        _ = LaunchRecord.begin(file: file)
        _ = LaunchRecord.begin(file: file)
        let third = LaunchRecord.begin(file: file)
        #expect(third.safe && third.before.updatedFrom == "0.1.0")
        LaunchRecord.finish(file: file)
        #expect(LaunchRecord.load(from: file).updatedFrom == nil)
    }

    @Test func instanceLockIsOneAtATime() {
        let file = scratch().appendingPathComponent("instance.lock")
        #expect(InstanceLock.claim(at: file))
        // Another process would open it afresh, as this does.
        let other = open(file.path, O_RDWR)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0)
    }

    @Test func installPlaces() throws {
        #expect(InstallPlace.problem(appPath: "/private/var/folders/x/AppTranslocation/ABC/d/Tiri.app") == .translocated)
        // The system volume is read-only, as a disk image is.
        #expect(InstallPlace.problem(appPath: "/System/Applications/Calculator.app") == .readOnly)
        let directory = scratch()
        defer {
            chmod(directory.path, 0o755)
            try? FileManager.default.removeItem(at: directory)
        }
        let app = directory.appendingPathComponent("Tiri.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(InstallPlace.problem(appPath: app.path) == nil)
        chmod(directory.path, 0o555)
        #expect(InstallPlace.problem(appPath: app.path) == .notWritable(directory.path))
        #expect(InstallPlace.problem(appPath: app.path)?.isMovable == false)
    }
}

@Suite struct SocketLivenessTests {
    private func socketPath() -> String { "/tmp/tiri-live-\(UUID().uuidString.prefix(8)).sock" }

    private func bound(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8))
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(result == 0)
        return fd
    }

    /// A Tiri that took the connection and never answers, its main thread stuck, still has its socket.
    @Test func aWedgedServerKeepsItsSocket() throws {
        let path = socketPath()
        defer { unlink(path) }
        let fd = bound(path)
        defer { close(fd) }
        #expect(listen(fd, 4) == 0)
        #expect(ControlClient.socketState(path: path) == .listening)
        #expect(throws: ControlSocketError.self) { try ControlServer(path: path) { .success(id: $0.id) }.start() }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// Gone without removing it, as a crash leaves it: refused, and replaced.
    @Test func aDeadServersSocketIsStale() throws {
        let path = socketPath()
        defer { unlink(path) }
        close(bound(path))
        #expect(ControlClient.socketState(path: path) == .stale)
        #expect(ControlClient.socketState(path: path + ".none") == .missing)
        let next = ControlServer(path: path) { .success(id: $0.id) }
        try next.start()
        #expect(ControlClient.isAlive(path: path))
        next.stop()
    }
}

@Suite struct SigningCheckTests {
    /// Two bundles with their own code: ad hoc signatures, whose designated requirement is the exact code.
    private func bundle(_ folder: URL, _ name: String, tweak: String) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Tiri").path)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.tiri.signing-test</string>
        <key>CFBundleExecutable</key><string>Tiri</string><key>Tweak</key><string>\(tweak)</string></dict></plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        #expect(Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).ok)
        return app
    }

    @Test func designatedRequirementOfTheInstalledApp() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try bundle(folder, "Installed", tweak: "a")
        let same = folder.appendingPathComponent("Same.app")
        #expect(Tool.run("/usr/bin/ditto", [installed.path, same.path]).ok)
        let other = try bundle(folder, "Other", tweak: "b")
        #expect(SigningCheck.meetsDesignatedRequirement(of: installed, same))
        #expect(!SigningCheck.meetsDesignatedRequirement(of: installed, other))
    }
}
