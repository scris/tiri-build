import Foundation

// MARK: - What Tiri knows about servers

/// A language server Tiri knows how to find. They aren't bundled: this says what to look for.
public struct LanguageServerDefinition: Sendable, Identifiable, Equatable {
    public var id: String
    public var language: String
    public var extensions: Set<String>
    /// Tried in order. The first word is the program's name.
    public var commands: [[String]]
    /// Files that mark a project's root, nearest first.
    public var rootMarkers: [String]
    /// Folders inside a project that can hold its own copy.
    public var localBins: [String]
    /// How to get it, for the prompt to your agent.
    public var installHint: String

    public func languageID(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "swift": return "swift"
        case "c": return "c"
        case "h": return "c"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "rb": return "ruby"
        case "lua": return "lua"
        default: return ext
        }
    }
}

public enum LanguageServerCatalog {
    public static let all: [LanguageServerDefinition] = [
        .init(id: "typescript", language: "TypeScript and JavaScript", extensions: ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"],
              commands: [["typescript-language-server", "--stdio"]], rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
              localBins: ["node_modules/.bin"], installHint: "npm install -g typescript typescript-language-server"),
        .init(id: "python", language: "Python", extensions: ["py"],
              commands: [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]],
              rootMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
              localBins: [".venv/bin", "venv/bin", "node_modules/.bin"], installHint: "npm install -g pyright"),
        .init(id: "rust", language: "Rust", extensions: ["rs"], commands: [["rust-analyzer"]], rootMarkers: ["Cargo.toml"],
              localBins: [], installHint: "rustup component add rust-analyzer"),
        .init(id: "go", language: "Go", extensions: ["go"], commands: [["gopls"]], rootMarkers: ["go.mod"],
              localBins: [], installHint: "go install golang.org/x/tools/gopls@latest"),
        .init(id: "swift", language: "Swift", extensions: ["swift"], commands: [["sourcekit-lsp"]], rootMarkers: ["Package.swift"],
              localBins: [], installHint: "It comes with Xcode: xcode-select --install"),
        .init(id: "c", language: "C, C++ and Objective-C", extensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm"],
              commands: [["clangd"]], rootMarkers: ["compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile"],
              localBins: [], installHint: "It comes with Xcode: xcode-select --install"),
        .init(id: "ruby", language: "Ruby", extensions: ["rb"], commands: [["ruby-lsp"], ["solargraph", "stdio"]], rootMarkers: ["Gemfile"],
              localBins: ["bin"], installHint: "gem install ruby-lsp"),
        .init(id: "lua", language: "Lua", extensions: ["lua"], commands: [["lua-language-server"]], rootMarkers: [".luarc.json"],
              localBins: [], installHint: "brew install lua-language-server"),
    ]

    public static func definition(for path: String) -> LanguageServerDefinition? {
        let ext = (path as NSString).pathExtension.lowercased()
        return all.first { $0.extensions.contains(ext) }
    }

    /// The project a file belongs to: the nearest folder with a marker, inside the workspace
    /// folder it's in. Without a marker, that workspace folder. Without one, its own folder.
    public static func root(for path: String, definition: LanguageServerDefinition, folders: [String],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let folder = folders.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        var current = (path as NSString).deletingLastPathComponent
        while current != "/", !current.isEmpty {
            if definition.rootMarkers.contains(where: { exists(current + "/" + $0) }) { return current }
            if current == folder { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return folder ?? (path as NSString).deletingLastPathComponent
    }
}

// MARK: - The messages

public struct LSPDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 1, warning, information, hint

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        public var word: String {
            switch self {
            case .error: "error"
            case .warning: "warning"
            case .information: "info"
            case .hint: "hint"
            }
        }

        /// How the editor protocol spells them.
        public var title: String {
            switch self {
            case .error: "Error"
            case .warning: "Warning"
            case .information: "Information"
            case .hint: "Hint"
            }
        }
    }

    /// All counting from 0.
    public var line: Int
    public var character: Int
    public var endLine: Int
    public var endCharacter: Int
    public var severity: Severity
    public var message: String
    public var source: String?

    public init(line: Int, character: Int, endLine: Int, endCharacter: Int, severity: Severity, message: String, source: String? = nil) {
        self.line = line
        self.character = character
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.severity = severity
        self.message = message
        self.source = source
    }

    /// `path:12:3: error: what's wrong`, the way compilers print it, so a ⌘-click can follow it.
    public func printed(path: String) -> String {
        let oneLine = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(path):\(line + 1):\(character + 1): \(severity.word): \(oneLine)"
    }
}

public struct LSPHoverBlock: Sendable, Equatable {
    public var text: String
    public var isCode: Bool
    public init(text: String, isCode: Bool) {
        self.text = text
        self.isCode = isCode
    }
}

public enum LSP {
    public static func uri(for path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    public static func path(from uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    public static func position(line: Int, character: Int) -> JSONValue {
        .object(["line": .int(line), "character": .int(character)])
    }

    public static func textPosition(path: String, line: Int, character: Int) -> JSONValue {
        .object(["textDocument": .object(["uri": .string(uri(for: path))]), "position": position(line: line, character: character)])
    }

    /// What Tiri can do with a server's answers. Asks for nothing to do with typing.
    public static func initializeParams(root: String, processID: Int32) -> JSONValue {
        .object([
            "processId": .int(Int(processID)),
            "rootUri": .string(uri(for: root)),
            "rootPath": .string(root),
            "clientInfo": .object(["name": "Tiri", "version": .string(TiriCoreVersion.string)]),
            "workspaceFolders": .array([.object(["uri": .string(uri(for: root)), "name": .string((root as NSString).lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array(["utf-16"])]),
                "workspace": .object([
                    "configuration": true,
                    "workspaceFolders": true,
                    "didChangeWatchedFiles": .object(["dynamicRegistration": false]),
                    "symbol": .object([:]),
                ]),
                "window": .object(["workDoneProgress": false]),
                "textDocument": .object([
                    "synchronization": .object(["didSave": true]),
                    "hover": .object(["contentFormat": .array(["markdown", "plaintext"])]),
                    "definition": .object(["linkSupport": true]),
                    "references": .object([:]),
                    "documentSymbol": .object(["hierarchicalDocumentSymbolSupport": true]),
                    "publishDiagnostics": .object(["relatedInformation": false]),
                    "diagnostic": .object(["dynamicRegistration": false]),
                ]),
            ]),
        ])
    }

    /// A definition's answer can be a location, a list of them, or a list of links.
    public static func locations(from result: JSONValue?) -> [(path: String, line: Int, character: Int)] {
        guard let result else { return [] }
        let list: [JSONValue]
        if let many = result.arrayValue {
            list = many
        } else if case .object = result {
            list = [result]
        } else {
            return []
        }
        return list.compactMap { entry in
            let uri = entry["uri"]?.stringValue ?? entry["targetUri"]?.stringValue
            let range = entry["range"] ?? entry["targetSelectionRange"] ?? entry["targetRange"]
            guard let uri, let path = path(from: uri), let start = range?["start"],
                  let line = start["line"]?.intValue, let character = start["character"]?.intValue else { return nil }
            return (path, line, character)
        }
    }

    public static func diagnostics(from list: JSONValue?) -> [LSPDiagnostic] {
        (list?.arrayValue ?? []).compactMap { entry in
            guard let message = entry["message"]?.stringValue, let start = entry["range"]?["start"], let end = entry["range"]?["end"],
                  let line = start["line"]?.intValue, let character = start["character"]?.intValue,
                  let endLine = end["line"]?.intValue, let endCharacter = end["character"]?.intValue else { return nil }
            // Servers may leave severity out, and the protocol then leaves it to the client.
            let severity = entry["severity"]?.intValue.flatMap(LSPDiagnostic.Severity.init(rawValue:)) ?? .error
            return LSPDiagnostic(line: line, character: character, endLine: endLine, endCharacter: endCharacter,
                                 severity: severity, message: message, source: entry["source"]?.stringValue)
        }
    }

    /// A hover's contents can be markdown, plain text, a code block, or a list of those.
    public static func hover(from result: JSONValue?) -> [LSPHoverBlock] {
        guard let contents = result?["contents"] else { return [] }
        var blocks: [LSPHoverBlock] = []
        func add(_ value: JSONValue) {
            if let text = value.stringValue {
                blocks += markdownBlocks(text)
            } else if let language = value["language"]?.stringValue, let text = value["value"]?.stringValue {
                _ = language
                blocks.append(LSPHoverBlock(text: text.trimmingCharacters(in: .newlines), isCode: true))
            } else if let text = value["value"]?.stringValue {
                if value["kind"]?.stringValue == "plaintext" {
                    blocks.append(LSPHoverBlock(text: text, isCode: false))
                } else {
                    blocks += markdownBlocks(text)
                }
            } else if let list = value.arrayValue {
                list.forEach(add)
            }
        }
        add(contents)
        return blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Fenced code apart from the words around it, because they're shown differently.
    static func markdownBlocks(_ text: String) -> [LSPHoverBlock] {
        var blocks: [LSPHoverBlock] = []
        var current: [Substring] = []
        var inCode = false
        func flush() {
            // A popover has no use for rules, and shows a heading the same as any other line.
            let lines = inCode ? current : current.filter { $0.trimmingCharacters(in: .whitespaces) != "---" }.map { line in
                var text = line
                while text.hasPrefix("#") { text = text.dropFirst() }
                return text.count == line.count ? line : "**" + text.trimmingCharacters(in: .whitespaces) + "**"
            }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(LSPHoverBlock(text: joined, isCode: inCode)) }
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Diagnostics on rows of a diff that were added: what this change is answerable for.
    public static func onAddedRows(_ diagnostics: [LSPDiagnostic], rows: [DiffLine]) -> [LSPDiagnostic] {
        let added = Set(rows.filter { $0.kind == .added }.compactMap(\.newLine))
        return diagnostics.filter { added.contains($0.line + 1) }
    }
}

/// Reads `Content-Length` frames out of a stream of bytes, however they're split up.
public struct LSPFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            var length: Int?
            for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
            guard let length, length >= 0 else {
                // Not something that can be read. What's after it might be.
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                continue
            }
            guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
            messages.append(Data(buffer[end.upperBound..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        // Slices would keep counting from where the buffer started.
        buffer = Data(buffer)
        return messages
    }
}

// MARK: - Talking to one server

/// One running language server. Everything happens on its own queue, and answers come back on it.
public final class LSPClient: @unchecked Sendable {
    public struct Launch: Sendable {
        public var executable: String
        public var arguments: [String]
        public var directory: String
        public var path: String?
        public init(executable: String, arguments: [String], directory: String, path: String?) {
            self.executable = executable
            self.arguments = arguments
            self.directory = directory
            self.path = path
        }
    }

    private let queue = DispatchQueue(label: "tiri.lsp")
    private let launch: Launch
    private var process: Process?
    private var input: FileHandle?
    private var framer = LSPFramer()
    private var nextID = 1
    private var pending: [Int: @Sendable (JSONValue?) -> Void] = [:]
    private var exited = false

    /// A notification from the server, on the client's queue.
    public var onNotification: (@Sendable (String, JSONValue?) -> Void)?
    public var onExit: (@Sendable () -> Void)?

    public init(launch: Launch) {
        self.launch = launch
    }

    public func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        var environment = ProcessInfo.processInfo.environment
        if let path = launch.path { environment["PATH"] = path }
        process.environment = environment
        let toServer = Pipe()
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        // A server that's gone shouldn't take the app with it when something's written to it.
        _ = fcntl(toServer.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.didExit() }
        }
        fromServer.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async { self.receive(data) }
        }
        try process.run()
        self.process = process
        self.input = toServer.fileHandleForWriting
    }

    private func didExit() {
        guard !exited else { return }
        exited = true
        input = nil
        let waiting = pending.values
        pending = [:]
        for answer in waiting { answer(nil) }
        onExit?()
    }

    private func receive(_ data: Data) {
        for message in framer.feed(data) {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: message) else { continue }
            handle(value)
        }
    }

    private func handle(_ message: JSONValue) {
        let method = message["method"]?.stringValue
        if let method, let id = message["id"] {
            answerServer(method: method, id: id, params: message["params"])
        } else if let method {
            onNotification?(method, message["params"])
        } else if let id = message["id"]?.intValue, let answer = pending.removeValue(forKey: id) {
            // An error is as good as nothing, and whoever asked has somewhere else to go.
            answer(message["error"] == nil ? (message["result"] ?? .null) : nil)
        }
    }

    /// Servers ask things too. Most need no more than an answer of some kind to carry on.
    private func answerServer(method: String, id: JSONValue, params: JSONValue?) {
        let result: JSONValue
        switch method {
        case "workspace/configuration":
            result = .array((params?["items"]?.arrayValue ?? []).map { _ in .null })
        case "workspace/workspaceFolders":
            result = .array([.object(["uri": .string(LSP.uri(for: launch.directory)), "name": .string((launch.directory as NSString).lastPathComponent)])])
        default:
            result = .null
        }
        write(.object(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func write(_ message: JSONValue) {
        guard let input, let body = try? JSONEncoder().encode(message) else { return }
        try? input.write(contentsOf: LSPFramer.frame(body))
    }

    public func notify(_ method: String, _ params: JSONValue) {
        queue.async { self.write(.object(["jsonrpc": "2.0", "method": .string(method), "params": params])) }
    }

    /// The answer arrives exactly once: nil for an error, an exit or running out of time.
    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 10, answer: @escaping @Sendable (JSONValue?) -> Void) {
        queue.async {
            guard !self.exited else {
                answer(nil)
                return
            }
            let id = self.nextID
            self.nextID += 1
            self.pending[id] = answer
            self.write(.object(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.pending.removeValue(forKey: id)?(nil)
            }
        }
    }

    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 10) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            request(method, params, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Asks it to leave, and insists if it doesn't.
    public func stop() {
        request("shutdown", .null, timeout: 2) { [weak self] _ in
            guard let self else { return }
            self.notify("exit", .null)
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.input = nil
                if let process = self.process, process.isRunning { process.terminate() }
            }
        }
    }

    public var processIdentifier: Int32? { process?.processIdentifier }
}
