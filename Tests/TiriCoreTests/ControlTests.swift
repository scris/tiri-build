import Foundation
import Testing
@testable import TiriCore

@Suite struct ProtocolTests {
    @Test func requestRoundTrip() throws {
        let request = ControlRequest(id: "1", cmd: "open", args: ["path": "/a b", "line": 3, "pin": true])
        let line = try ControlCoding.encodeLine(request)
        #expect(line.last == 0x0A)
        #expect(try ControlCoding.decodeRequest(line.dropLast()) == request)
    }

    @Test func requestFromHandwrittenJSON() throws {
        let request = try ControlCoding.decodeRequest(Data(#"{"cmd":"ping"}"#.utf8))
        #expect(request.cmd == "ping")
        #expect(request.args.isEmpty)
    }

    @Test func responseShapes() throws {
        let success = ControlResponse.success(id: "1", .object(["item": "i-1"]))
        let encoded = String(decoding: try ControlCoding.encodeLine(success), as: UTF8.self)
        #expect(encoded.contains(#""ok":true"#))
        #expect(!encoded.contains("error"))
        #expect(try ControlCoding.decodeResponse(Data(encoded.utf8).dropLast()) == success)

        let failure = ControlResponse.failure(id: "2", "nope")
        #expect(try ControlCoding.decodeResponse(try ControlCoding.encodeLine(failure).dropLast()) == failure)
    }

    @Test func nestedValues() throws {
        let value: JSONValue = .object(["list": .array([1, "two", .double(3.5), .null, false])])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}

@Suite struct ControlServerIntegrationTests {
    private func socketPath() -> String {
        // sun_path is short, so keep this out of the long default temp directory.
        "/tmp/tiri-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func clientDrivesServerInProcess() throws {
        let path = socketPath()
        let server = ControlServer(path: path) { request in
            switch request.cmd {
            case "ping": return .success(id: request.id, .object(["pong": true]))
            case "echo": return .success(id: request.id, request.args["value"] ?? .null)
            default: return .failure(id: request.id, "unknown command \(request.cmd)")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = try ControlClient(path: path)
        let pong = try client.send(ControlRequest(id: "a", cmd: "ping"))
        #expect(pong.id == "a")
        #expect(pong.ok)
        #expect(pong.result?["pong"] == true)

        let echo = try client.send(ControlRequest(id: "b", cmd: "echo", args: ["value": "héllo\nworld"]))
        #expect(echo.result == "héllo\nworld")

        let bad = try client.send(ControlRequest(id: "c", cmd: "nope"))
        #expect(!bad.ok)
        #expect(bad.error?.contains("nope") == true)
    }

    @Test func socketIsPrivate() throws {
        let path = socketPath()
        let server = ControlServer(path: path) { .success(id: $0.id) }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func malformedLineGetsErrorAndConnectionSurvives() throws {
        let path = socketPath()
        let server = ControlServer(path: path) { .success(id: $0.id) }
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8))
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        let payload = Array("garbage\n{\"id\":\"ok\",\"cmd\":\"ping\"}\n".utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while collected.filter({ $0 == 0x0A }).count < 2 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            collected.append(contentsOf: chunk[0..<count])
        }
        let lines = collected.split(separator: 0x0A).map { try? ControlCoding.decodeResponse(Data($0)) }
        #expect(lines.count == 2)
        #expect(lines[0]?.ok == false)
        #expect(lines[1]?.ok == true)
        #expect(lines[1]?.id == "ok")
    }

    @Test func concurrentClients() async throws {
        let path = socketPath()
        let server = ControlServer(path: path) { .success(id: $0.id, $0.args["n"] ?? .null) }
        try server.start()
        defer { server.stop() }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let client = try ControlClient(path: path)
                    let response = try client.send(ControlRequest(id: "\(index)", cmd: "x", args: ["n": .int(index)]))
                    return response.result == .int(index) && response.id == "\(index)"
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    @Test func secondServerRefusesLiveSocket() throws {
        let path = socketPath()
        let first = ControlServer(path: path) { .success(id: $0.id) }
        try first.start()
        defer { first.stop() }
        #expect(throws: ControlSocketError.self) {
            try ControlServer(path: path) { .success(id: $0.id) }.start()
        }
        #expect(ControlClient.isAlive(path: path))
    }

    @Test func staleSocketIsReplaced() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = ControlServer(path: path) { .success(id: $0.id) }
        try server.start()
        defer { server.stop() }
        #expect(ControlClient.isAlive(path: path))
    }

    @Test func connectingWithoutServerThrows() {
        #expect(throws: ControlSocketError.self) {
            try ControlClient(path: "/tmp/tiri-nothing-here.sock")
        }
    }
}

@Suite struct CLIParserTests {
    private let environment = CLIParser.Environment(cwd: "/work", itemID: "i-self", fileExists: { _ in false })

    private func request(_ arguments: String...) throws -> ControlRequest {
        guard case .request(let request, _) = try CLIParser.parse(arguments, environment: environment) else {
            throw CLIParser.UsageError("not a request")
        }
        return request
    }

    @Test func openWithLineAndSplit() throws {
        let parsed = try request("open", "src/a.swift:12:3", "--split", "right", "--pin")
        #expect(parsed.cmd == "open")
        #expect(parsed.args["path"] == "/work/src/a.swift")
        #expect(parsed.args["line"] == 12)
        #expect(parsed.args["col"] == 3)
        #expect(parsed.args["split"] == "right")
        #expect(parsed.args["pin"] == true)
    }

    @Test func openPeekAndTabFlags() throws {
        #expect(try request("open", "a.md", "--peek").args["mode"] == "peek")
        #expect(try request("open", "a.md", "--tab").args["mode"] == "tab")
        // Inside a Tiri terminal a plain `open` carries its source, so the app can float it.
        #expect(try request("open", "a.md").args["source"] == "i-self")
    }

    @Test func literalColonFileWins() throws {
        let env = CLIParser.Environment(cwd: "/work", itemID: nil, fileExists: { $0 == "/work/odd:12" })
        guard case .request(let parsed, _) = try CLIParser.parse(["open", "odd:12"], environment: env) else {
            Issue.record("expected request")
            return
        }
        #expect(parsed.args["path"] == "/work/odd:12")
        #expect(parsed.args["line"] == nil)
    }

    @Test func previewTargets() throws {
        #expect(try request("preview", "https://a.dev/x").args["target"] == "https://a.dev/x")
        #expect(try request("preview", "localhost:3000/a").args["target"] == "http://localhost:3000/a")
        #expect(try request("preview", "dist/i.html").args["target"] == "file:///work/dist/i.html")
    }

    @Test func termDefaultsCwd() throws {
        #expect(try request("term").args["cwd"] == "/work")
        let parsed = try request("term", "--cwd", "/x", "--cmd", "claude", "--split", "down")
        #expect(parsed.args["cwd"] == "/x")
        #expect(parsed.args["cmd"] == "claude")
        #expect(parsed.args["split"] == "down")
    }

    @Test func workspaceCommands() throws {
        #expect(try request("workspace", "list").cmd == "workspace.list")
        #expect(try request("workspace", "switch", "api").args["name"] == "api")
        let new = try request("workspace", "new", "api", "--folder", "a", "--folder", "/b")
        #expect(new.args["folders"] == .array(["/work/a", "/b"]))
        #expect(try request("workspace", "add-folder", "x").args["folder"] == "/work/x")
        #expect(try request("workspace", "import", "t.code-workspace").args["file"] == "/work/t.code-workspace")
    }

    @Test func notifyUsesEnvironmentItem() throws {
        let parsed = try request("notify", "needs-input", "--message", "pick one")
        #expect(parsed.args["item"] == "i-self")
        #expect(parsed.args["state"] == "needs-input")
        #expect(parsed.args["message"] == "pick one")
    }

    @Test func notifyOutsideTiriIsQuiet() throws {
        let outside = CLIParser.Environment(cwd: "/", itemID: nil)
        #expect(try CLIParser.parse(["notify", "done"], environment: outside) == .quietSuccess)
    }

    @Test func notifyRejectsUnknownState() {
        #expect(throws: CLIParser.UsageError.self) { try request("notify", "sleeping") }
    }

    @Test func hookReadsPayloadAndCarriesSession() throws {
        let env = CLIParser.Environment(cwd: "/", itemID: "i-1", fileExists: { _ in false }, readStdin: {
            Data(#"{"hook_event_name":"Stop","session_id":"s9","last_assistant_message":"ok"}"#.utf8)
        })
        guard case .request(let parsed, _) = try CLIParser.parse(["hook", "claude"], environment: env) else {
            Issue.record("expected request")
            return
        }
        #expect(parsed.cmd == "notify")
        #expect(parsed.args["state"] == "done")
        #expect(parsed.args["session"] == "s9")
        #expect(parsed.args["item"] == "i-1")
    }

    @Test func codexHookTakesPayloadArgument() throws {
        let parsed = try request("hook", "codex", #"{"type":"agent-turn-complete","thread-id":"t1"}"#)
        #expect(parsed.args["state"] == "done")
        #expect(parsed.args["session"] == "t1")
    }

    @Test func hookOutsideTiriIsQuiet() throws {
        let outside = CLIParser.Environment(cwd: "/", itemID: nil)
        #expect(try CLIParser.parse(["hook", "claude"], environment: outside) == .quietSuccess)
    }

    @Test func hooksPrintsValidConfig() throws {
        guard case .printText(let text) = try CLIParser.parse(["hooks", "claude"], environment: environment) else {
            Issue.record("expected text")
            return
        }
        #expect(try JSONSerialization.jsonObject(with: Data(text.utf8)) is [String: Any])
    }

    @Test func themeValidated() throws {
        #expect(try request("theme", "dark").args["mode"] == "dark")
        #expect(throws: CLIParser.UsageError.self) { try request("theme", "blue") }
    }

    @Test func webDark() throws {
        #expect(try request("web-dark", "on").args["on"] == true)
        let parsed = try request("web-dark", "off", "i-1")
        #expect(parsed.args["on"] == false)
        #expect(parsed.args["item"] == "i-1")
    }

    @Test func agentCommandsCarryTheirSource() throws {
        #expect(try request("term").args["source"] == "i-self")
        #expect(try request("preview", "http://a.dev").args["source"] == "i-self")
        #expect(try request("workspace", "add-folder", "x").args["source"] == "i-self")
    }

    @Test func readRejectsBadLineCounts() {
        #expect(throws: CLIParser.UsageError.self) { try request("read", "i-1", "--lines", "-1") }
        #expect(throws: CLIParser.UsageError.self) { try request("read", "i-1", "--lines", "many") }
    }

    @Test func sendAppendsReturn() throws {
        #expect(try request("send", "i-1", "ls", "--enter").args["text"] == "ls\r")
        #expect(try request("send", "i-1", "ls").args["text"] == "ls")
    }

    @Test func badSplitRejected() {
        #expect(throws: CLIParser.UsageError.self) { try request("open", "a", "--split", "sideways") }
    }

    @Test func unknownCommandRejected() {
        #expect(throws: CLIParser.UsageError.self) { try request("frobnicate") }
    }

    @Test func extraArgumentRejected() {
        #expect(throws: CLIParser.UsageError.self) { try request("reveal", "a", "b") }
    }

    @Test func skillAndHelpPrint() throws {
        guard case .printText(let skill) = try CLIParser.parse(["--skill"], environment: environment) else {
            Issue.record("expected text")
            return
        }
        #expect(skill.contains("tiri notify"))
        #expect(skill.contains("TIRI_ITEM_ID"))
        guard case .printText = try CLIParser.parse([], environment: environment) else {
            Issue.record("expected usage")
            return
        }
    }

    @Test func jsonFlagAnywhere() throws {
        guard case .request(_, let json) = try CLIParser.parse(["items", "--json"], environment: environment) else {
            Issue.record("expected request")
            return
        }
        #expect(json)
    }
}
