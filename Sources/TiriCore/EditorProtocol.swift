import Foundation

/// What's selected in a file. Lines and characters count from zero, as editors report them.
public struct EditorSelection: Sendable, Equatable {
    public var path: String
    public var text: String
    public var startLine: Int
    public var startCharacter: Int
    public var endLine: Int
    public var endCharacter: Int

    public init(path: String, text: String, startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) {
        self.path = path
        self.text = text
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
    }

    public var isEmpty: Bool { text.isEmpty }

    /// The last line really selected: a selection ending at the start of a line stops before it.
    public var lastLine: Int {
        endCharacter == 0 && endLine > startLine ? endLine - 1 : endLine
    }
}

/// How a reference to a file or some of its lines is written into an agent's input.
public enum AgentReference {
    public typealias Agent = AgentIdentity

    /// See `AgentCatalog.identify`.
    public static func agent(commandLine: [String], command: String?, custom: Set<String> = []) -> Agent? {
        AgentCatalog.identify(commandLine: commandLine, command: command, custom: custom)
    }

    /// A path from the terminal's folder when it's inside it, because it's shorter and is what agents print.
    public static func display(path: String, cwd: String?) -> String {
        guard let cwd else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Lines count from zero here and from one on screen. A path with a space gets quotes.
    public static func text(path: String, cwd: String?, firstLine: Int?, lastLine: Int?, agent: Agent) -> String {
        let shown = display(path: path, cwd: cwd)
        // An agent Tiri has no entry for gets what anyone could read.
        return agent.profile?.mention(shown, firstLine: firstLine, lastLine: lastLine)
            ?? AgentProfile.mention(shown, firstLine: firstLine, lastLine: lastLine, prefix: "", style: .colon)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]

    public static func isImage(path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Selected text from something without lines of its own, like a web page or a PDF.
    public static func quotation(from source: String, text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        // The blank line keeps it apart from whatever is already in the input.
        return "\nFrom \(source):\n" + lines.map { "> " + $0 }.joined(separator: "\n") + "\n"
    }

    /// Pasted, agents take an image's path as the image itself. Typed, it's only text.
    public static func bracketedPaste(_ text: String) -> String {
        // An escape inside could end the paste early, and what follows would run as if typed.
        "\u{1B}[200~" + text.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~"
    }
}

/// Claude Code's editor protocol: the one the VS Code extension and Cursor speak. MCP's JSON-RPC
/// over a local WebSocket. It lets Claude see your selection and take a file or lines into its
/// input as a real mention. Tiri offers no openDiff tool, so Claude keeps showing its own diffs
/// in the terminal rather than waiting on Tiri for an answer.
public enum EditorProtocol {
    public struct Host {
        public var selection: () -> EditorSelection?
        /// What's wrong, by path. Given a file's URI, for that file. This has to answer at once.
        public var diagnostics: (String?) -> [(path: String, diagnostics: [LSPDiagnostic])] = { _ in [] }
        public var openFiles: () -> [(path: String, isActive: Bool)]
        public var folders: () -> [String]
        public var isDirty: (String) -> Bool
        public var openFile: (String) -> Void

        public init(selection: @escaping () -> EditorSelection?, diagnostics: @escaping (String?) -> [(path: String, diagnostics: [LSPDiagnostic])] = { _ in [] }, openFiles: @escaping () -> [(path: String, isActive: Bool)],
                    folders: @escaping () -> [String], isDirty: @escaping (String) -> Bool, openFile: @escaping (String) -> Void) {
            self.selection = selection
            self.diagnostics = diagnostics
            self.openFiles = openFiles
            self.folders = folders
            self.isDirty = isDirty
            self.openFile = openFile
        }
    }

    private static func encode(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func lockFile(pid: Int32, folders: [String], token: String) -> Data {
        encode(.object(["pid": .int(Int(pid)), "workspaceFolders": .array(folders.map(JSONValue.string)), "ideName": "Tiri",
                        "transport": "ws", "runningInWindows": false, "authToken": .string(token)]))
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func selectionParams(_ selection: EditorSelection) -> JSONValue {
        .object(["text": .string(selection.text), "filePath": .string(selection.path),
                 "fileUrl": .string(URL(fileURLWithPath: selection.path).absoluteString),
                 "selection": .object([
                    "start": .object(["line": .int(selection.startLine), "character": .int(selection.startCharacter)]),
                    "end": .object(["line": .int(selection.endLine), "character": .int(selection.endCharacter)]),
                    "isEmpty": .bool(selection.isEmpty),
                 ])])
    }

    public static func selectionChanged(_ selection: EditorSelection) -> Data {
        encode(.object(["jsonrpc": "2.0", "method": "selection_changed", "params": selectionParams(selection)]))
    }

    /// Lines count from zero. Without lines, it's the whole file.
    public static func atMentioned(path: String, firstLine: Int?, lastLine: Int?) -> Data {
        var params: [String: JSONValue] = ["filePath": .string(path)]
        if let firstLine {
            params["lineStart"] = .int(firstLine)
            params["lineEnd"] = .int(lastLine ?? firstLine)
        }
        return encode(.object(["jsonrpc": "2.0", "method": "at_mentioned", "params": .object(params)]))
    }

    /// The process that just connected says who it is, once it's set up.
    public static func connectedProcess(in data: Data) -> Int32? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              message["method"]?.stringValue == "ide_connected",
              let pid = message["params"]?["pid"]?.intValue else { return nil }
        return Int32(exactly: pid)
    }

    public static let tools: [(name: String, description: String, required: [String])] = [
        ("openFile", "Show a file in Tiri", ["filePath"]),
        ("getCurrentSelection", "The selection in the file in front", []),
        ("getLatestSelection", "The most recent selection", []),
        ("getOpenEditors", "The files open in Tiri", []),
        ("getWorkspaceFolders", "The workspace's folders", []),
        ("getDiagnostics", "Errors and warnings from language servers", []),
        ("checkDocumentDirty", "Whether a file has unsaved changes", ["filePath"]),
        ("saveDocument", "Save a file", ["filePath"]),
        ("close_tab", "Close a tab", ["tab_name"]),
        ("closeAllDiffTabs", "Close diff tabs. Tiri has none of Claude's", []),
    ]

    /// The answer to one message, or nil if it doesn't take one.
    public static func respond(to data: Data, host: Host) -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let method = message["method"]?.stringValue, let id = message["id"] else { return nil }
        let params = message["params"]
        func result(_ value: JSONValue) -> Data {
            encode(.object(["jsonrpc": "2.0", "id": id, "result": value]))
        }
        func text(_ value: String) -> JSONValue {
            .object(["content": .array([.object(["type": "text", "text": .string(value)])])])
        }
        func json(_ value: JSONValue) -> JSONValue {
            text(String(decoding: encode(value), as: UTF8.self))
        }
        switch method {
        case "initialize":
            return result(.object([
                "protocolVersion": params?["protocolVersion"] ?? "2025-03-26",
                "capabilities": .object(["tools": .object(["listChanged": true])]),
                "serverInfo": .object(["name": "Tiri", "version": .string(TiriCoreVersion.string)]),
            ]))
        case "ping":
            return result(.object([:]))
        case "tools/list":
            return result(.object(["tools": .array(tools.map { tool in
                .object(["name": .string(tool.name), "description": .string(tool.description),
                         "inputSchema": .object(["type": "object", "required": .array(tool.required.map(JSONValue.string)),
                                                 "additionalProperties": true])])
            })]))
        case "resources/list":
            return result(.object(["resources": .array([])]))
        case "prompts/list":
            return result(.object(["prompts": .array([])]))
        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]
            let path = arguments?["filePath"]?.stringValue ?? ""
            switch name {
            case "openFile":
                host.openFile(path)
                return result(text("Opened file: \(path)"))
            case "getCurrentSelection", "getLatestSelection":
                guard let selection = host.selection() else {
                    return result(json(.object(["success": false, "message": "No selection available"])))
                }
                var object = selectionParams(selection).objectValue
                object["success"] = true
                return result(json(.object(object)))
            case "getOpenEditors":
                return result(json(.object(["tabs": .array(host.openFiles().map { file in
                    .object(["uri": .string(URL(fileURLWithPath: file.path).absoluteString), "isActive": .bool(file.isActive),
                             "label": .string((file.path as NSString).lastPathComponent), "isDirty": .bool(host.isDirty(file.path))])
                })])))
            case "getWorkspaceFolders":
                let folders = host.folders()
                return result(json(.object(["success": true, "rootPath": folders.first.map(JSONValue.string) ?? .null,
                                            "folders": .array(folders.map { folder in
                    .object(["name": .string((folder as NSString).lastPathComponent),
                             "uri": .string(URL(fileURLWithPath: folder).absoluteString), "path": .string(folder)])
                })])))
            case "getDiagnostics":
                let found = host.diagnostics(arguments?["uri"]?.stringValue)
                return result(json(.array(found.map { file in
                    .object(["uri": .string(LSP.uri(for: file.path)), "diagnostics": .array(file.diagnostics.map { diagnostic in
                        var object: [String: JSONValue] = [
                            "message": .string(diagnostic.message), "severity": .string(diagnostic.severity.title),
                            "range": .object(["start": LSP.position(line: diagnostic.line, character: diagnostic.character),
                                              "end": LSP.position(line: diagnostic.endLine, character: diagnostic.endCharacter)]),
                        ]
                        if let source = diagnostic.source { object["source"] = .string(source) }
                        return .object(object)
                    })])
                })))
            case "checkDocumentDirty":
                return result(json(.object(["success": true, "filePath": .string(path), "isDirty": .bool(host.isDirty(path)), "isUntitled": false])))
            case "saveDocument":
                return result(json(.object(["success": true, "filePath": .string(path), "saved": .bool(!host.isDirty(path)), "message": "Nothing to save"])))
            case "close_tab":
                return result(text("TAB_CLOSED"))
            case "closeAllDiffTabs":
                return result(text("CLOSED_0_DIFF_TABS"))
            default:
                return encode(.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": -32601, "message": .string("No tool called \(name)")])]))
            }
        default:
            return encode(.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": -32601, "message": .string("No method called \(method)")])]))
        }
    }
}
