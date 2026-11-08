import Foundation
import Testing
@testable import TiriCore

@Suite struct StartFoldersTests {
    private func guesses(_ files: [String: String]) -> [StartGuess] {
        StartFolders.guesses(in: "/p") { path in files[String(path.dropFirst("/p/".count))] }
    }

    @Test func packageScriptsUseTheLockfilesRunner() {
        let package = #"{ "scripts": { "build": "vite build", "dev": "vite", "start": "node server.js" } }"#
        #expect(guesses(["package.json": package]).map(\.command) == ["npm run dev", "npm start"])
        #expect(guesses(["package.json": package, "pnpm-lock.yaml": ""]).map(\.command) == ["pnpm dev", "pnpm start"])
        #expect(guesses(["package.json": package, "yarn.lock": ""]).first?.command == "yarn dev")
        #expect(guesses(["package.json": package, "bun.lock": ""]).first?.command == "bun run dev")
        #expect(guesses(["package.json": package]).first?.detail == "vite")
    }

    @Test func claudesLaunchFileComesFirst() {
        let launch = """
        { "version": "0.0.1", // comments are allowed
          "configurations": [
            { "name": "web", "runtimeExecutable": "pnpm", "runtimeArgs": ["dev", "--port", "3001"], "cwd": "apps/web" },
            { "name": "api", "program": "server.js", "env": { "PORT": "8080" } }
          ] }
        """
        let found = guesses([".claude/launch.json": launch, "package.json": #"{"scripts":{"dev":"next dev"}}"#])
        #expect(found.map(\.name) == ["web", "api", "p"])
        #expect(found.map(\.command) == ["cd apps/web && pnpm dev --port 3001", "PORT=8080 node server.js", "npm run dev"])
        #expect(found.first?.source == ".claude/launch.json")
    }

    @Test func otherKindsOfProject() {
        #expect(guesses(["Procfile": "web: bundle exec rails s\n# not this\nworker: sidekiq"]).map(\.command) == ["bundle exec rails s", "sidekiq"])
        #expect(guesses(["manage.py": ""]).map(\.command) == ["python3 manage.py runserver"])
        #expect(guesses(["Makefile": "build:\n\tcc a.c\ndev:\n\t./run\n"]).map(\.command) == ["make dev"])
        #expect(guesses(["Cargo.toml": ""]).map(\.command) == ["cargo run"])
        #expect(guesses(["go.mod": "", "main.go": ""]).map(\.command) == ["go run ."])
        #expect(guesses(["go.mod": ""]).isEmpty)
        #expect(guesses(["compose.yaml": ""]).map(\.command) == ["docker compose up"])
        #expect(guesses(["README.md": "hi"]).isEmpty)
        #expect(guesses(["package.json": "not json"]).isEmpty)
    }

    @Test func theAddressAServerPrinted() {
        let vite = "  VITE v5.4.0  ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose"
        #expect(StartFolders.printedPort(in: vite) == 5173)
        #expect(StartFolders.printedPort(in: "Listening on http://127.0.0.1:8000\nnow http://0.0.0.0:8001") == 8001)
        #expect(StartFolders.printedPort(in: "   - Local:        http://localhost:3000") == 3000)
        #expect(StartFolders.printedPort(in: "see https://example.com:443/docs") == nil)
        #expect(StartFolders.printedPort(in: "https://myapp.localhost:1355") == 1355)
        #expect(StartFolders.printedPort(in: "nothing here") == nil)
    }

    @Test func thePagesPortIsWhatItPrintedOrTheLowest() {
        #expect(StartFolders.pagePort(listening: [5173, 24678], printed: nil) == 5173)
        #expect(StartFolders.pagePort(listening: [3000, 3001], printed: 3001) == 3001)
        // It printed one it isn't listening on, as a proxy's target: what it listens on wins.
        #expect(StartFolders.pagePort(listening: [4000], printed: 3000) == 4000)
        #expect(StartFolders.pagePort(listening: [], printed: 3000) == 3000)
        #expect(StartFolders.pagePort(listening: [], printed: nil) == nil)
        // A script bringing up a site and its API, the API ready first or last: the lower is the page.
        #expect(StartFolders.pagePort(listening: [5410, 5411], printed: [5411, 5410]) == 5410)
        #expect(StartFolders.printedPorts(in: "API on http://localhost:5411/\nSite on http://localhost:5410/") == [5411, 5410])
    }

    @Test func aTabTitleIsTheCommandsStart() {
        #expect(StartFolders.title(of: "pnpm dev") == "pnpm dev")
        #expect(StartFolders.title(of: "cd apps/web && pnpm dev --port 3001") == "pnpm dev --port")
        #expect(StartFolders.title(of: "PORT=8080 node server.js") == "node server.js")
    }

    @Test func theSettingKeepsOnlyRealCommands() throws {
        let settings = try TiriSettings.parse(#"{ "start.commands": { "/a": "pnpm dev", "/b": "  " } }"#)
        #expect(settings.startCommands == ["/a": "pnpm dev"])
    }

    @Test func theCommandLineNamesAStartOrSaysWhatToDo() throws {
        let environment = CLIParser.Environment(cwd: "/p/src", itemID: "i-1", fileExists: { _ in false }, readStdin: { Data() })
        func parsed(_ args: [String]) throws -> ControlRequest? {
            guard case .request(let request, _) = try CLIParser.parse(args, environment: environment) else { return nil }
            return request
        }
        let plain = try #require(try parsed(["start"]))
        #expect(plain.cmd == "start" && plain.args["action"] == nil && plain.args["name"] == nil && plain.args["source"]?.stringValue == "i-1")
        #expect(try parsed(["start", "web"])?.args["name"]?.stringValue == "web")
        let add = try #require(try parsed(["start", "add", "web", "pnpm dev", "--folder", "/p/apps/web"]))
        #expect(add.args["action"]?.stringValue == "add" && add.args["name"]?.stringValue == "web" && add.args["command"]?.stringValue == "pnpm dev")
        #expect(add.args["folder"]?.stringValue == "/p/apps/web")
        let logs = try #require(try parsed(["start", "logs", "web", "--lines", "40"]))
        #expect(logs.args["name"]?.stringValue == "web" && logs.args["lines"]?.intValue == 40)
        #expect(try parsed(["start", "list"])?.args["action"]?.stringValue == "list")
        #expect(throws: (any Error).self) { try parsed(["start", "add", "web"]) }
        #expect(throws: (any Error).self) { try parsed(["start", "remove"]) }
    }

    @Test func aMonorepoSuggestsItsPartsAndItsOwnScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-start-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        func write(_ path: String, _ text: String) throws {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        try write("scripts/start-trainhub.sh", "#!/bin/sh")
        try write("scripts/start-home.sh", "#!/bin/sh")
        try write("scripts/test.sh", "#!/bin/sh")
        try write("Frontend/package.json", #"{"scripts":{"dev":"vite","start":"vite preview"}}"#)
        try write("Frontend/yarn.lock", "")
        try write("Backend/pom.xml", "<plugin>spring-boot-maven-plugin</plugin>")
        try write("Backend/mvnw", "")
        try write("node_modules/x/package.json", #"{"scripts":{"dev":"no"}}"#)
        try write("notes/README.md", "hi")
        let found = StartFolders.suggestions(for: [root])
        #expect(found.map(\.name) == ["home", "trainhub", "Backend", "Frontend"])
        #expect(found.first { $0.name == "Frontend" }?.command == "yarn dev")
        #expect(found.first { $0.name == "Frontend" }?.folder == (root as NSString).appendingPathComponent("Frontend"))
        #expect(found.first { $0.name == "Backend" }?.command == "./mvnw spring-boot:run")
        #expect(found.first { $0.name == "trainhub" }?.command == "scripts/start-trainhub.sh")
        #expect(found.first { $0.name == "trainhub" }?.folder == root)
    }

    @Test func aWorkspacesStartsAreSavedWithItAndComeBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-starts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        var workspace = Workspace(name: "w", folders: ["/p"])
        workspace.starts = [StartEntry(id: "s-1", name: "web", command: "pnpm dev", folder: "/p/web")]
        workspace.hiddenStartSuggestions = ["/p\u{1}make dev"]
        try store.save(.init(workspaces: [workspace], activeID: workspace.id, windows: []))
        let loaded = store.load()?.workspaces.first
        #expect(loaded?.starts == workspace.starts)
        #expect(loaded?.hiddenStartSuggestions == ["/p\u{1}make dev"])
    }

    @Test func aStartEntrySurvivesSavingAndAWorkspaceWithoutOneLoads() throws {
        var workspace = Workspace(name: "w", folders: ["/p"])
        workspace.starts = [StartEntry(id: "s-1", name: "web", command: "pnpm dev", folder: "/p")]
        let data = try JSONEncoder().encode(workspace)
        #expect(try JSONDecoder().decode(Workspace.self, from: data).starts == workspace.starts)
        let older = try JSONEncoder().encode(Workspace(name: "old", folders: []))
        #expect(try JSONDecoder().decode(Workspace.self, from: older).starts == nil)
    }

    @Test func theKernelSaysWhatAProgramListensOn() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(ListeningPorts.under(getpid()).contains(port))
    }
}
