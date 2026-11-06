import Foundation

// MARK: - What Tiri knows about servers

/// How Tiri can install a server itself, with one click: exact versions and hashes that came with
/// the app. A server you installed yourself always comes first.
public struct ManagedServer: Sendable, Equatable {
    public enum Tool: String, Sendable {
        /// A virtual environment, from `requirements.txt` in Resources/language-servers/`lock`.
        case uv
        /// `npm ci` with no install scripts, from a `package-lock.json` in the same place.
        case npm
        /// `go install` at this exact version, which Go checks against its checksum database.
        case go
    }

    public var tool: Tool
    public var lock: String
    /// Changing it installs again, beside the old one.
    public var version: String
    public var megabytes: Int
    /// The name of the server, for saying what's about to be installed.
    public var title: String
    public var package: String?

    public init(tool: Tool, lock: String, version: String, megabytes: Int, title: String, package: String? = nil) {
        self.tool = tool
        self.lock = lock
        self.version = version
        self.megabytes = megabytes
        self.title = title
        self.package = package
    }

    /// Where its programs end up, inside its own folder.
    public var binaryFolder: String {
        switch tool {
        case .uv: "venv/bin"
        case .npm: "node_modules/.bin"
        case .go: "bin"
        }
    }
}

/// A language server Tiri knows how to find. They aren't bundled: this says what to look for.
public struct LanguageServerDefinition: Sendable, Identifiable, Equatable {
    public var id: String
    public var language: String
    /// Tried in order. The first word is the program's name.
    public var commands: [[String]]
    /// Files that mark a project's root, nearest first.
    public var rootMarkers: [String]
    /// Folders inside a project that can hold its own copy.
    public var localBins: [String]
    /// How to get it, for the prompt to your agent.
    public var installHint: String
    public var managed: ManagedServer?
    /// For servers known from elsewhere: the extensions they said they cover.
    public var extraExtensions: [String: String] = [:]

    public func languageID(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if let own = extraExtensions[ext] { return own }
        return LanguageCatalog.language(forPath: path)?.languageServerID ?? ext
    }
}

extension LanguageServerDefinition {
    /// The files it answers for, like "For .py and .pyi files." Only the ones Tiri lists by hand:
    /// grammars claim plenty of extensions nobody would recognize here.
    public var filesLine: String? {
        let entries = LanguageCatalog.curated.filter { $0.server == id }.map { $0.extensions.split(separator: " ").map(String.init) }
        var seen = Set<String>()
        // The main one of each language first, then the rest.
        let found = (entries.compactMap(\.first) + entries.flatMap { $0 }).filter { seen.insert($0).inserted }.map { "." + $0 }
        switch found.count {
        case 0: return nil
        case 1: return String(localized: "For \(found[0]) files.")
        case 2: return String(localized: "For \(found[0]) and \(found[1]) files.")
        case 3: return String(localized: "For \(found[0]), \(found[1]) and \(found[2]) files.")
        case 4: return String(localized: "For \(found[0]), \(found[1]), \(found[2]) and \(found[3]) files.")
        default: return String(localized: "For \(found[0]), \(found[1]), \(found[2]), \(found[3]) and more.")
        }
    }

    /// The others that one install brings, since they share it.
    public var sharesInstallWith: [LanguageServerDefinition] {
        guard let managed, !managed.lock.isEmpty else { return [] }
        return LanguageServerCatalog.all.filter { $0.id != id && $0.managed?.lock == managed.lock }
    }

    /// What pressing Add does, in words.
    public var addLine: String? {
        guard let managed else { return nil }
        // Its first name is enough here: "CSS", not "CSS, SCSS and Less".
        let others = sharesInstallWith.map { $0.language.split(separator: ",").first.map(String.init) ?? $0.language }
        guard !others.isEmpty else { return String(localized: "Installs \(managed.title), \(managed.megabytes) MB.") }
        let names = L10n.list(others.map(L10n.display))
        return String(localized: "Installs \(managed.title), \(managed.megabytes) MB. Also covers \(names).")
    }
}

public enum LanguageServerCatalog {
    private static let builtIn: [LanguageServerDefinition] = [
        .init(id: "typescript", language: "TypeScript and JavaScript",
              commands: [["typescript-language-server", "--stdio"]], rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
              localBins: ["node_modules/.bin"], installHint: "npm install -g typescript typescript-language-server",
              managed: .init(tool: .npm, lock: "typescript", version: "6.0.3", megabytes: 26, title: "typescript-language-server")),
        .init(id: "python", language: "Python",
              commands: [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"], ["jedi-language-server"], ["ty", "server"]],
              rootMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
              localBins: [".venv/bin", "venv/bin", "node_modules/.bin"], installHint: "uv tool install basedpyright, or npm install -g pyright",
              managed: .init(tool: .uv, lock: "python", version: "1.40.2", megabytes: 283, title: "basedpyright")),
        .init(id: "rust", language: "Rust", commands: [["rust-analyzer"]], rootMarkers: ["Cargo.toml"],
              localBins: [], installHint: "rustup component add rust-analyzer"),
        .init(id: "go", language: "Go", commands: [["gopls"]], rootMarkers: ["go.mod"],
              localBins: [], installHint: "go install golang.org/x/tools/gopls@latest",
              managed: .init(tool: .go, lock: "", version: "v0.24.0", megabytes: 41, title: "gopls", package: "golang.org/x/tools/gopls")),
        .init(id: "swift", language: "Swift", commands: [["sourcekit-lsp"]], rootMarkers: ["Package.swift"],
              localBins: [], installHint: "It comes with Xcode: xcode-select --install"),
        .init(id: "c", language: "C, C++ and Objective-C",
              commands: [["clangd"]], rootMarkers: ["compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile"],
              localBins: [], installHint: "It comes with Xcode: xcode-select --install"),
        .init(id: "bash", language: "Shell scripts", commands: [["bash-language-server", "start"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g bash-language-server",
              managed: .init(tool: .npm, lock: "bash", version: "5.8.1", megabytes: 26, title: "bash-language-server")),
        .init(id: "yaml", language: "YAML", commands: [["yaml-language-server", "--stdio"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g yaml-language-server",
              managed: .init(tool: .npm, lock: "yaml", version: "2.0.0", megabytes: 19, title: "yaml-language-server")),
        .init(id: "json", language: "JSON", commands: [["vscode-json-language-server", "--stdio"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g vscode-langservers-extracted",
              managed: .init(tool: .npm, lock: "web", version: "4.10.0", megabytes: 94, title: "VS Code's web language servers")),
        .init(id: "html", language: "HTML", commands: [["vscode-html-language-server", "--stdio"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g vscode-langservers-extracted",
              managed: .init(tool: .npm, lock: "web", version: "4.10.0", megabytes: 94, title: "VS Code's web language servers")),
        .init(id: "css", language: "CSS, SCSS and Less", commands: [["vscode-css-language-server", "--stdio"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g vscode-langservers-extracted",
              managed: .init(tool: .npm, lock: "web", version: "4.10.0", megabytes: 94, title: "VS Code's web language servers")),
        .init(id: "ruby", language: "Ruby", commands: [["ruby-lsp"], ["solargraph", "stdio"]], rootMarkers: ["Gemfile"],
              localBins: ["bin"], installHint: "gem install ruby-lsp"),
        .init(id: "lua", language: "Lua", commands: [["lua-language-server"]], rootMarkers: [".luarc.json"],
              localBins: [], installHint: "brew install lua-language-server"),
        .init(id: "java", language: "Java", commands: [["jdtls"]], rootMarkers: ["pom.xml", "build.gradle", "build.gradle.kts"],
              localBins: [], installHint: "brew install jdtls"),
        .init(id: "kotlin", language: "Kotlin", commands: [["kotlin-lsp", "--stdio"]], rootMarkers: ["settings.gradle.kts", "build.gradle.kts", "build.gradle", "pom.xml"],
              localBins: [], installHint: "brew install JetBrains/utils/kotlin-lsp"),
        .init(id: "scala", language: "Scala", commands: [["metals"]], rootMarkers: ["build.sbt", "build.sc"],
              localBins: [], installHint: "cs install metals"),
        .init(id: "csharp", language: "C#", commands: [["csharp-ls"]], rootMarkers: ["global.json"],
              localBins: [], installHint: "dotnet tool install --global csharp-ls"),
        .init(id: "php", language: "PHP", commands: [["intelephense", "--stdio"]], rootMarkers: ["composer.json"],
              localBins: ["vendor/bin", "node_modules/.bin"], installHint: "npm install -g intelephense"),
        .init(id: "dart", language: "Dart", commands: [["dart", "language-server", "--protocol=lsp"]], rootMarkers: ["pubspec.yaml"],
              localBins: [], installHint: "It comes with the Dart SDK: brew install dart"),
        .init(id: "zig", language: "Zig", commands: [["zls"]], rootMarkers: ["build.zig"],
              localBins: [], installHint: "brew install zls"),
        .init(id: "elixir", language: "Elixir", commands: [["elixir-ls"], ["lexical"]], rootMarkers: ["mix.exs"],
              localBins: [], installHint: "brew install elixir-ls"),
        .init(id: "haskell", language: "Haskell", commands: [["haskell-language-server-wrapper", "--lsp"]], rootMarkers: ["stack.yaml", "cabal.project", "hie.yaml"],
              localBins: [], installHint: "ghcup install hls"),
        .init(id: "ocaml", language: "OCaml", commands: [["ocamllsp"]], rootMarkers: ["dune-project"],
              localBins: [], installHint: "opam install ocaml-lsp-server"),
        .init(id: "terraform", language: "Terraform", commands: [["terraform-ls", "serve"]], rootMarkers: [".terraform"],
              localBins: [], installHint: "brew install hashicorp/tap/terraform-ls"),
        .init(id: "docker", language: "Dockerfiles", commands: [["docker-langserver", "--stdio"]], rootMarkers: [],
              localBins: ["node_modules/.bin"], installHint: "npm install -g dockerfile-language-server-nodejs"),
        .init(id: "toml", language: "TOML", commands: [["taplo", "lsp", "stdio"]], rootMarkers: [],
              localBins: [], installHint: "brew install taplo"),
        .init(id: "vue", language: "Vue", commands: [["vue-language-server", "--stdio"]], rootMarkers: ["package.json"],
              localBins: ["node_modules/.bin"], installHint: "npm install -g @vue/language-server"),
        .init(id: "svelte", language: "Svelte", commands: [["svelteserver", "--stdio"]], rootMarkers: ["package.json"],
              localBins: ["node_modules/.bin"], installHint: "npm install -g svelte-language-server"),
    ]

    private static let shipped: [LanguageServerDefinition] = builtIn + ClaudeLanguagePlugins.servers(known: builtIn)
    private static let storage = NSLock()
    nonisolated(unsafe) private static var fromPlugins: [LanguageServerDefinition] = []

    public static var all: [LanguageServerDefinition] {
        // A plugin's own server comes first, so one you turned on is the one that's used.
        storage.withLock { fromPlugins } + shipped
    }

    /// What plugins add, all of them at once.
    public static func setPluginServers(_ servers: [LanguageServerDefinition]) {
        storage.withLock { fromPlugins = servers }
    }

    public static func definition(for path: String) -> LanguageServerDefinition? {
        let everything = all
        if let server = LanguageCatalog.language(forPath: path)?.server {
            return everything.first { $0.id == server }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return everything.first { $0.extraExtensions[ext] != nil }
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

    /// What Tiri can do with a server's answers.
    /// `processID` is nil over SSH, where a server would look for it, not find it, and exit.
    public static func initializeParams(root: String, processID: Int32?) -> JSONValue {
        .object([
            "processId": processID.map { .int(Int($0)) } ?? .null,
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
                    "synchronization": .object(["didSave": true, "willSave": false, "dynamicRegistration": false]),
                    // Plain text only: snippets are decided against, and so is anything that types by itself.
                    "completion": .object([
                        "dynamicRegistration": false,
                        "contextSupport": true,
                        "completionItem": .object([
                            "snippetSupport": false,
                            "commitCharactersSupport": false,
                            "insertReplaceSupport": false,
                            "labelDetailsSupport": true,
                            "preselectSupport": true,
                            "deprecatedSupport": true,
                            "documentationFormat": .array(["plaintext", "markdown"]),
                            "resolveSupport": .object(["properties": .array(["documentation", "detail", "additionalTextEdits"])]),
                        ]),
                        "completionItemKind": .object(["valueSet": .array((1...25).map { .int($0) })]),
                    ]),
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
        /// A server over SSH knows files by their paths there. Everything said to it, and everything
        /// it says, goes through this. Local paths are all Tiri ever sees.
        public var remoteMap: RemotePathMap?
        public init(executable: String, arguments: [String], directory: String, path: String?, remoteMap: RemotePathMap? = nil) {
            self.remoteMap = remoteMap
            self.executable = executable
            self.arguments = arguments
            self.directory = directory
            self.path = path
        }
    }

    /// For taking back a question nobody wants the answer to any more.
    public final class RequestToken: @unchecked Sendable {
        fileprivate var id: Int?
        public init() {}
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
            let translated = launch.remoteMap.map { LSP.fromServer(message, map: $0) } ?? message
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: translated) else { continue }
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
        guard let input, var body = try? JSONEncoder().encode(message) else { return }
        if let map = launch.remoteMap { body = LSP.toServer(body, map: map) }
        try? input.write(contentsOf: LSPFramer.frame(body))
    }

    public func notify(_ method: String, _ params: JSONValue) {
        queue.async { self.write(.object(["jsonrpc": "2.0", "method": .string(method), "params": params])) }
    }

    /// The answer arrives exactly once: nil for an error, an exit or running out of time.
    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 10, token: RequestToken? = nil, answer: @escaping @Sendable (JSONValue?) -> Void) {
        queue.async {
            guard !self.exited else {
                answer(nil)
                return
            }
            let id = self.nextID
            self.nextID += 1
            token?.id = id
            self.pending[id] = answer
            self.write(.object(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.pending.removeValue(forKey: id)?(nil)
            }
        }
    }

    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 10, token: RequestToken? = nil) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            request(method, params, timeout: timeout, token: token) { continuation.resume(returning: $0) }
        }
    }

    public func cancel(_ token: RequestToken) {
        queue.async {
            guard let id = token.id, self.pending[id] != nil else { return }
            self.write(.object(["jsonrpc": "2.0", "method": "$/cancelRequest", "params": .object(["id": .int(id)])]))
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

// MARK: - Over SSH

extension LSP {
    private static func replacing(_ data: Data, _ pairs: [(String, String)]) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for (from, to) in pairs { text = text.replacingOccurrences(of: from, with: to) }
        return Data(text.utf8)
    }

    /// JSON may write slashes as `\/`, so both are handled.
    static func toServer(_ data: Data, map: RemotePathMap) -> Data {
        let root = map.localRoot
        let escaped = root.replacingOccurrences(of: "/", with: "\\/")
        return replacing(data, [(escaped + "\\/", "\\/"), (root + "/", "/")])
    }

    static func fromServer(_ data: Data, map: RemotePathMap) -> Data {
        let escaped = map.localRoot.replacingOccurrences(of: "/", with: "\\/")
        return replacing(data, [("file:\\/\\/\\/", "file:\\/\\/" + escaped + "\\/"), ("file:///", "file://" + map.localRoot + "/")])
    }
}

// MARK: - Servers you already set up for Claude Code

/// Claude Code's language plugins name a command for some extensions. A server set up there works
/// here too, with nothing else to do. Ones Tiri already knows by the same command aren't listed twice.
public enum ClaudeLanguagePlugins {
    public static func servers(known: [LanguageServerDefinition], home: String = NSHomeDirectory()) -> [LanguageServerDefinition] {
        let plugins = home + "/.claude/plugins"
        guard let installed = readJSON(plugins + "/installed_plugins.json")?["plugins"] as? [String: Any] else { return [] }
        var found: [LanguageServerDefinition] = []
        let knownCommands = Set(known.flatMap { $0.commands.compactMap(\.first) })
        for key in installed.keys.sorted() {
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let catalog = readJSON(plugins + "/marketplaces/\(parts[1])/.claude-plugin/marketplace.json")?["plugins"] as? [[String: Any]]
            guard let entry = catalog?.first(where: { $0["name"] as? String == parts[0] }),
                  let servers = entry["lspServers"] as? [String: Any] else { continue }
            found += parse(servers, plugin: parts[0], knownCommands: knownCommands)
        }
        return found
    }

    /// `{"name": {"command": "x", "args": [...], "extensionToLanguage": {".x": "x"}}}`
    public static func parse(_ servers: [String: Any], plugin: String, knownCommands: Set<String>) -> [LanguageServerDefinition] {
        servers.keys.sorted().compactMap { name in
            guard let server = servers[name] as? [String: Any], let command = server["command"] as? String, !knownCommands.contains(command),
                  let languages = server["extensionToLanguage"] as? [String: String], !languages.isEmpty else { return nil }
            var extensions: [String: String] = [:]
            for (ext, language) in languages { extensions[ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()] = language }
            return LanguageServerDefinition(id: "claude-\(name)", language: name, commands: [[command] + (server["args"] as? [String] ?? [])], rootMarkers: [], localBins: [],
                                            installHint: "It comes from the Claude Code plugin \(plugin). See its README.", extraExtensions: extensions)
        }
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
