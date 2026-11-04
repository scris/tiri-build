import Foundation
import Testing
@testable import TiriCore

@Suite struct LSPFramerTests {
    @Test func readsAWholeMessage() {
        var framer = LSPFramer()
        #expect(framer.feed(LSPFramer.frame(Data("{}".utf8))) == [Data("{}".utf8)])
    }

    @Test func readsAMessageThatArrivesInPieces() {
        var framer = LSPFramer()
        let whole = LSPFramer.frame(Data(#"{"a":1}"#.utf8))
        var out: [Data] = []
        for byte in whole { out += framer.feed(Data([byte])) }
        #expect(out == [Data(#"{"a":1}"#.utf8)])
    }

    @Test func readsSeveralAtOnce() {
        var framer = LSPFramer()
        let both = LSPFramer.frame(Data("1".utf8)) + LSPFramer.frame(Data("22".utf8))
        #expect(framer.feed(both) == [Data("1".utf8), Data("22".utf8)])
    }

    @Test func countsBytesNotCharacters() {
        var framer = LSPFramer()
        let body = Data(#""é""#.utf8)
        #expect(framer.feed(LSPFramer.frame(body) + LSPFramer.frame(Data("x".utf8))) == [body, Data("x".utf8)])
    }

    @Test func readsOtherHeaders() {
        var framer = LSPFramer()
        let data = Data("Content-Type: x\r\nContent-Length: 2\r\n\r\nhi".utf8)
        #expect(framer.feed(data) == [Data("hi".utf8)])
    }

    @Test func aBadHeaderDoesNotStopWhatFollows() {
        var framer = LSPFramer()
        #expect(framer.feed(Data("nonsense\r\n\r\n".utf8) + LSPFramer.frame(Data("ok".utf8))) == [Data("ok".utf8)])
    }
}

@Suite struct LSPMessageTests {
    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func urisRoundTripWithSpaces() {
        #expect(LSP.path(from: LSP.uri(for: "/a b/c.py")) == "/a b/c.py")
        #expect(LSP.path(from: "https://example.com/x") == nil)
    }

    @Test func aDefinitionCanBeOneLocation() throws {
        let found = LSP.locations(from: try value(#"{"uri":"file:///a.py","range":{"start":{"line":2,"character":4},"end":{"line":2,"character":5}}}"#))
        #expect(found.map(\.path) == ["/a.py"])
        #expect(found.first?.line == 2)
        #expect(found.first?.character == 4)
    }

    @Test func aDefinitionCanBeALink() throws {
        let found = LSP.locations(from: try value(#"[{"targetUri":"file:///b.ts","targetRange":{"start":{"line":9,"character":0},"end":{"line":20,"character":0}},"targetSelectionRange":{"start":{"line":10,"character":6},"end":{"line":10,"character":9}}}]"#))
        #expect(found.first?.path == "/b.ts")
        #expect(found.first?.line == 10)
    }

    @Test func noAnswerIsNoLocations() throws {
        #expect(LSP.locations(from: nil).isEmpty)
        #expect(LSP.locations(from: .null).isEmpty)
        #expect(LSP.locations(from: try value("[]")).isEmpty)
    }

    @Test func readsDiagnostics() throws {
        let found = LSP.diagnostics(from: try value(#"[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"severity":2,"message":"careful","source":"x"},{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":1}},"message":"no severity"},{"message":"no range"}]"#))
        #expect(found.count == 2)
        #expect(found[0].severity == .warning)
        #expect(found[0].source == "x")
        #expect(found[1].severity == .error)
    }

    @Test func printsTheWayACompilerDoes() {
        let problem = LSPDiagnostic(line: 11, character: 2, endLine: 11, endCharacter: 3, severity: .error, message: "nope")
        #expect(problem.printed(path: "src/a.py") == "src/a.py:12:3: error: nope")
    }

    @Test func hoverCanBeMarkdownWithCode() throws {
        let blocks = LSP.hover(from: try value(#"{"contents":{"kind":"markdown","value":"```python\ndef f(): ...\n```\n---\nDoes things."}}"#))
        #expect(blocks == [LSPHoverBlock(text: "def f(): ...", isCode: true), LSPHoverBlock(text: "Does things.", isCode: false)])
    }

    @Test func headingsAreBoldInHoverAndRulesGo() {
        #expect(LSP.markdownBlocks("### function add\n---\nDoes things.") == [LSPHoverBlock(text: "**function add**\nDoes things.", isCode: false)])
        // In code they're just code.
        #expect(LSP.markdownBlocks("```\n# comment\n---\n```") == [LSPHoverBlock(text: "# comment\n---", isCode: true)])
    }

    @Test func aMultilineProblemPrintsOnOneLine() {
        let problem = LSPDiagnostic(line: 0, character: 0, endLine: 0, endCharacter: 1, severity: .error, message: "too few\n\nsrc/calc.h:5:5:\n  note: here")
        #expect(problem.printed(path: "a.c") == "a.c:1:1: error: too few src/calc.h:5:5: note: here")
    }

    @Test func hoverCanBeACodeBlockOrAList() throws {
        #expect(LSP.hover(from: try value(#"{"contents":{"language":"go","value":"func F()"}}"#)) == [LSPHoverBlock(text: "func F()", isCode: true)])
        #expect(LSP.hover(from: try value(#"{"contents":["plain",{"language":"c","value":"int a"}]}"#)).count == 2)
        #expect(LSP.hover(from: try value(#"{"contents":{"kind":"plaintext","value":"```not code"}}"#)) == [LSPHoverBlock(text: "```not code", isCode: false)])
        #expect(LSP.hover(from: nil).isEmpty)
        #expect(LSP.hover(from: try value(#"{"contents":""}"#)).isEmpty)
    }

    @Test func aDiffAnswersOnlyForWhatItAdded() {
        let rows = [
            DiffLine(kind: .context, oldLine: 1, newLine: 1, text: "a"),
            DiffLine(kind: .removed, oldLine: 2, text: "b"),
            DiffLine(kind: .added, newLine: 2, text: "c"),
        ]
        func problem(_ line: Int) -> LSPDiagnostic {
            LSPDiagnostic(line: line, character: 0, endLine: line, endCharacter: 1, severity: .error, message: "\(line)")
        }
        // Lines count from 0 here and from 1 in a diff. Line 8 isn't in the diff at all.
        #expect(LSP.onAddedRows([problem(0), problem(1), problem(8)], rows: rows).map(\.line) == [1])
    }
}

@Suite struct LanguageServerCatalogTests {
    @Test func findsTheServerForAFile() {
        #expect(LanguageServerCatalog.definition(for: "/a/b.tsx")?.id == "typescript")
        #expect(LanguageServerCatalog.definition(for: "/a/b.PY")?.id == "python")
        #expect(LanguageServerCatalog.definition(for: "/a/Package.swift")?.id == "swift")
        #expect(LanguageServerCatalog.definition(for: "/a/notes.md") == nil)
        #expect(LanguageServerCatalog.definition(for: "/a/Makefile") == nil)
    }

    @Test func namesEachLanguageTheWayServersExpect() throws {
        let typescript = try #require(LanguageServerCatalog.definition(for: "a.ts"))
        #expect(typescript.languageID(for: "a.tsx") == "typescriptreact")
        #expect(typescript.languageID(for: "a.mjs") == "javascript")
        let c = try #require(LanguageServerCatalog.definition(for: "a.c"))
        #expect(c.languageID(for: "a.cpp") == "cpp")
        #expect(c.languageID(for: "a.mm") == "objective-cpp")
    }

    @Test func theRootIsTheNearestProject() throws {
        let rust = try #require(LanguageServerCatalog.definition(for: "a.rs"))
        let markers: Set<String> = ["/w/crates/one/Cargo.toml", "/w/Cargo.toml"]
        let root = LanguageServerCatalog.root(for: "/w/crates/one/src/a.rs", definition: rust, folders: ["/w"], exists: { markers.contains($0) })
        #expect(root == "/w/crates/one")
    }

    @Test func withNoProjectTheRootIsTheWorkspaceFolder() throws {
        let rust = try #require(LanguageServerCatalog.definition(for: "a.rs"))
        #expect(LanguageServerCatalog.root(for: "/w/src/a.rs", definition: rust, folders: ["/w", "/other"], exists: { _ in false }) == "/w")
    }

    @Test func theSearchStopsAtTheWorkspaceFolder() throws {
        let rust = try #require(LanguageServerCatalog.definition(for: "a.rs"))
        let root = LanguageServerCatalog.root(for: "/w/in/a.rs", definition: rust, folders: ["/w/in"], exists: { $0 == "/w/Cargo.toml" })
        #expect(root == "/w/in")
    }

    @Test func aFileOutsideEveryFolderUsesItsOwnFolder() throws {
        let rust = try #require(LanguageServerCatalog.definition(for: "a.rs"))
        #expect(LanguageServerCatalog.root(for: "/x/y/a.rs", definition: rust, folders: ["/w"], exists: { _ in false }) == "/x/y")
    }

    @Test func readsWhereTheShellFoundThings() {
        let output = "welcome to my shell\ntiri-found:clangd=/usr/bin/clangd\ntiri-found:ll=alias ll='ls -l'\ntiri-found:go=/a=b/go\n"
        #expect(ShellLookup.locations(in: output) == ["clangd": "/usr/bin/clangd", "go": "/a=b/go"])
    }
}

@Suite struct EditorDiagnosticsTests {
    private func call(_ host: EditorProtocol.Host) throws -> JSONValue {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"getDiagnostics","arguments":{"uri":"file:///a.py"}}}"#.utf8)
        let response = try #require(EditorProtocol.respond(to: request, host: host))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: response)
        let text = try #require(decoded["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func host(diagnostics: @escaping (String?) -> [(path: String, diagnostics: [LSPDiagnostic])]) -> EditorProtocol.Host {
        EditorProtocol.Host(selection: { nil }, diagnostics: diagnostics, openFiles: { [] }, folders: { [] }, isDirty: { _ in false }, openFile: { _ in })
    }

    @Test func claudeGetsTheProblemsInTheShapeItExpects() throws {
        var asked: String?
        let result = try call(host { uri in
            asked = uri
            return [("/a.py", [LSPDiagnostic(line: 1, character: 2, endLine: 1, endCharacter: 4, severity: .warning, message: "careful", source: "ruff")])]
        })
        #expect(asked == "file:///a.py")
        let file = try #require(result.arrayValue?.first)
        #expect(file["uri"]?.stringValue == "file:///a.py")
        let problem = try #require(file["diagnostics"]?.arrayValue?.first)
        #expect(problem["message"]?.stringValue == "careful")
        #expect(problem["severity"]?.stringValue == "Warning")
        #expect(problem["source"]?.stringValue == "ruff")
        #expect(problem["range"]?["start"]?["line"]?.intValue == 1)
        #expect(problem["range"]?["end"]?["character"]?.intValue == 4)
    }

    @Test func nothingKnownIsAnEmptyList() throws {
        #expect(try call(host { _ in [] }).arrayValue?.isEmpty == true)
    }

    @Test func toolsNoLongerClaimThereAreNone() {
        #expect(EditorProtocol.tools.first { $0.name == "getDiagnostics" }?.description.contains("has none") == false)
    }
}

/// Real framing, a real process and real pipes, with a tiny server written for the test.
@Suite struct LSPClientTests {
    private static let server = #"""
    import json, sys
    def read():
        length = 0
        while True:
            line = sys.stdin.buffer.readline()
            if not line: sys.exit(0)
            if line == b"\r\n": break
            if line.lower().startswith(b"content-length:"): length = int(line.split(b":")[1])
        return json.loads(sys.stdin.buffer.read(length))
    def write(message):
        body = json.dumps(message).encode()
        sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        sys.stdout.buffer.flush()
    while True:
        m = read()
        method = m.get("method")
        if method == "echo": write({"jsonrpc": "2.0", "id": m["id"], "result": m["params"]})
        elif method == "fail": write({"jsonrpc": "2.0", "id": m["id"], "error": {"code": 1, "message": "no"}})
        elif method == "silence": pass
        elif method == "ask":
            write({"jsonrpc": "2.0", "id": 99, "method": "workspace/configuration", "params": {"items": [{}, {}]}})
            answer = read()
            write({"jsonrpc": "2.0", "id": m["id"], "result": answer["result"]})
        elif method == "tell":
            write({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": "file:///a", "diagnostics": []}})
        elif method == "die": sys.exit(3)
        elif method == "shutdown": write({"jsonrpc": "2.0", "id": m["id"], "result": None})
        elif method == "exit": sys.exit(0)
    """#

    private func client() throws -> LSPClient {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-lsp-\(UUID().uuidString).py")
        try Self.server.write(to: file, atomically: true, encoding: .utf8)
        let client = LSPClient(launch: .init(executable: "/usr/bin/python3", arguments: [file.path], directory: "/tmp", path: nil))
        try client.start()
        return client
    }

    @Test func getsAnAnswer() async throws {
        let client = try client()
        defer { client.stop() }
        #expect(await client.request("echo", .object(["a": 1]), timeout: 20)?["a"]?.intValue == 1)
    }

    @Test func anErrorIsNoAnswer() async throws {
        let client = try client()
        defer { client.stop() }
        #expect(await client.request("fail", .null, timeout: 20) == nil)
    }

    @Test func runningOutOfTimeIsNoAnswer() async throws {
        let client = try client()
        defer { client.stop() }
        #expect(await client.request("silence", .null, timeout: 0.3) == nil)
    }

    @Test func answersAServersQuestions() async throws {
        let client = try client()
        defer { client.stop() }
        let answer = await client.request("ask", .null, timeout: 20)
        #expect(answer?.arrayValue?.count == 2)
    }

    @Test func passesOnNotifications() async throws {
        let client = try client()
        defer { client.stop() }
        let method = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            client.onNotification = { method, _ in continuation.resume(returning: method) }
            client.notify("tell", .null)
        }
        #expect(method == "textDocument/publishDiagnostics")
    }

    @Test func aServerThatDiesAnswersEveryoneWaitingAndSaysSo() async throws {
        let client = try client()
        let exited = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            client.onExit = { continuation.resume(returning: true) }
            client.notify("die", .null)
        }
        #expect(exited)
        // Writing to it afterwards has to be harmless, and asking gets nothing, straight away.
        client.notify("anything", .null)
        #expect(await client.request("echo", .null, timeout: 20) == nil)
    }

    @Test func stoppingEndsTheProcess() async throws {
        let client = try client()
        let pid = try #require(client.processIdentifier)
        _ = await client.request("echo", .null, timeout: 20)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.onExit = { continuation.resume() }
            client.stop()
        }
        #expect(kill(pid, 0) != 0)
    }
}
