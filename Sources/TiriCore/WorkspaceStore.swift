import Foundation

/// `workspaces.json` holds the list. Each workspace's items and layout live in
/// `layouts/<id>.json`, so a noisy workspace only rewrites its own file.
public struct WorkspaceStore: Sendable {
    public struct Index: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var id: WorkspaceID
            public var name: String
            public var folders: [String]
            public var remote: String?
        }
        public var version: Int
        public var activeID: WorkspaceID?
        public var workspaces: [Entry]
        /// Each window and its workspace. Missing before there could be more than one.
        public var windows: [SavedWindow]?
    }

    struct LayoutFile: Codable {
        var items: [SavedItem]
        var layout: PaneNode
        var focusedGroup: GroupID
        var closed: [SavedItem]
        var expandedFolders: [String]?
        var recentFiles: [String]?
        var groupMRU: [GroupID]?
        var review: [ReviewComment]?
        /// ▶ Start's list. Missing before there was one, and in a workspace that hasn't looked at it yet.
        var starts: [StartEntry]?
        var hiddenStartSuggestions: [String]?
        /// What wrote it. Missing before there was one.
        var version: Int?
    }

    /// The shape of what's saved. A copy of Tiri that saves something this one wouldn't keep raises it, and this one
    /// then reads what it can and writes nothing over it.
    public static let formatVersion = 1

    public struct NewerFormat: Error, CustomStringConvertible {
        public var description: String { String(localized: "A newer Tiri saved these workspaces, so this one won't save over them.") }
    }

    public struct Snapshot: Equatable, Sendable {
        public var workspaces: [Workspace]
        public var activeID: WorkspaceID?
        public var windows: [SavedWindow]
        public init(workspaces: [Workspace], activeID: WorkspaceID?, windows: [SavedWindow] = []) {
            self.workspaces = workspaces
            self.activeID = activeID
            self.windows = windows
        }
    }

    public let directory: URL
    private let written = WrittenFiles()

    public init(directory: URL = TiriPaths.supportDirectory) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appendingPathComponent("workspaces.json") }
    private var layoutsURL: URL { directory.appendingPathComponent("layouts", isDirectory: true) }
    private func layoutURL(_ id: WorkspaceID) -> URL { layoutsURL.appendingPathComponent("\(id).json") }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// What was saved last time, or nil if nothing was. `damaged` says some of it couldn't be read,
    /// so what came back is the last copy that could be, or less: nothing should be taken as gone.
    public func load() -> Snapshot? { loadRecovering().snapshot }

    public func loadRecovering() -> (snapshot: Snapshot?, damaged: Bool) {
        guard let data = try? Data(contentsOf: indexURL) else { return (nil, false) }
        let manager = FileManager.default
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else {
            // The next save starts over, so keep everything it would otherwise replace or
            // delete, layouts included.
            let backup = directory.appendingPathComponent("workspaces.corrupt.json")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: indexURL, to: backup)
            let layoutsBackup = directory.appendingPathComponent("layouts.corrupt", isDirectory: true)
            try? manager.removeItem(at: layoutsBackup)
            try? manager.copyItem(at: layoutsURL, to: layoutsBackup)
            // A crash or a power cut mid-write leaves a file empty or cut short. The last good copy comes back.
            let previous = WorkspaceStore(directory: lastGoodURL)
            guard let recovered = previous.read() else { return (nil, true) }
            return (recovered.snapshot, true)
        }
        let read = read(index: index, fallback: WorkspaceStore(directory: lastGoodURL))
        if !read.damaged { keepLastGood() }
        return (read.snapshot, read.damaged)
    }

    /// Reads without keeping backups or falling back: for the last good copy itself.
    private func read() -> (snapshot: Snapshot, damaged: Bool)? {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        return read(index: index, fallback: nil)
    }

    private func read(index: Index, fallback: WorkspaceStore?) -> (snapshot: Snapshot, damaged: Bool) {
        var damaged = false
        var workspaces: [Workspace] = []
        for entry in index.workspaces {
            var workspace = Workspace(id: entry.id, name: entry.name, folders: entry.folders)
            workspace.remote = entry.remote
            if let data = try? Data(contentsOf: layoutURL(entry.id)) {
                var layout = try? JSONDecoder().decode(LayoutFile.self, from: data)
                if layout == nil {
                    damaged = true
                    // Its old layout shouldn't vanish with the next save.
                    let backup = directory.appendingPathComponent("\(entry.id).layout.corrupt.json")
                    try? FileManager.default.removeItem(at: backup)
                    try? FileManager.default.copyItem(at: layoutURL(entry.id), to: backup)
                    // The last good copy of it, or else this workspace comes back empty.
                    layout = fallback.flatMap { try? Data(contentsOf: $0.layoutURL(entry.id)) }
                        .flatMap { try? JSONDecoder().decode(LayoutFile.self, from: $0) }
                }
                if let layout { workspace.apply(layout) }
            }
            workspaces.append(workspace)
        }
        return (Snapshot(workspaces: workspaces, activeID: index.activeID, windows: index.windows ?? []), damaged)
    }

    /// A copy of what was last read or written whole, to come back to if the files are ever damaged.
    private var lastGoodURL: URL { directory.appendingPathComponent("last-good", isDirectory: true) }

    private func keepLastGood() {
        let manager = FileManager.default
        let staging = directory.appendingPathComponent("last-good.new", isDirectory: true)
        try? manager.removeItem(at: staging)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            try manager.copyItem(at: indexURL, to: staging.appendingPathComponent("workspaces.json"))
            if manager.fileExists(atPath: layoutsURL.path) {
                try manager.copyItem(at: layoutsURL, to: staging.appendingPathComponent("layouts", isDirectory: true))
            }
            // Swapped whole, so a crash part way leaves the old copy or the new one, never half of each.
            if manager.fileExists(atPath: lastGoodURL.path) {
                _ = try manager.replaceItemAt(lastGoodURL, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: lastGoodURL)
            }
        } catch {
            try? manager.removeItem(at: staging)
        }
    }

    /// The version the saved index says it is, if it can be read at all.
    public func savedVersion() -> Int? {
        struct Version: Decodable { var version: Int }
        return (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(Version.self, from: $0) }?.version
    }

    public func save(_ snapshot: Snapshot) throws {
        if let saved = savedVersion(), saved > Self.formatVersion { throw NewerFormat() }
        try FileManager.default.createDirectory(at: layoutsURL, withIntermediateDirectories: true)
        let index = Index(
            version: Self.formatVersion,
            activeID: snapshot.activeID,
            workspaces: snapshot.workspaces.map { .init(id: $0.id, name: $0.name, folders: $0.folders, remote: $0.remote) },
            windows: snapshot.windows.isEmpty ? nil : snapshot.windows
        )
        let encoder = Self.encoder()
        try written.write(encoder.encode(index), to: indexURL)
        for workspace in snapshot.workspaces {
            let saved = workspace.savedForm()
            let layout = LayoutFile(items: saved.items, layout: saved.layout,
                                    focusedGroup: workspace.focusedGroup, closed: saved.closed,
                                    expandedFolders: workspace.expandedFolders, recentFiles: workspace.recentFiles, groupMRU: workspace.groupMRU,
                                    review: workspace.review.isEmpty ? nil : workspace.review, starts: workspace.starts,
                                    hiddenStartSuggestions: workspace.hiddenStartSuggestions, version: Self.formatVersion)
            try written.write(encoder.encode(layout), to: layoutURL(workspace.id))
        }
        if Self.lastGoodDue(lastGoodURL) { keepLastGood() }
        // Drop layouts for workspaces that no longer exist.
        let live = Set(snapshot.workspaces.map { "\($0.id).json" })
        if let files = try? FileManager.default.contentsOfDirectory(atPath: layoutsURL.path) {
            for file in files where !live.contains(file) {
                try? FileManager.default.removeItem(at: layoutsURL.appendingPathComponent(file))
            }
        }
    }
}

extension WorkspaceStore {
    /// While Tiri runs, the last good copy follows along, but not on every save.
    static func lastGoodDue(_ url: URL) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return modified.map { Date().timeIntervalSince($0) > 600 } ?? true
    }
}

extension Workspace {
    fileprivate mutating func apply(_ layout: WorkspaceStore.LayoutFile) {
        self.layout = layout.layout
        focusedGroup = layout.focusedGroup
        take(items: layout.items, closed: layout.closed)
        expandedFolders = layout.expandedFolders ?? []
        recentFiles = layout.recentFiles ?? []
        groupMRU = layout.groupMRU ?? []
        review = layout.review ?? []
        starts = layout.starts
        hiddenStartSuggestions = layout.hiddenStartSuggestions
    }
}

// MARK: - .code-workspace import

public enum CodeWorkspaceImporter {
    public enum ImportError: Error, CustomStringConvertible {
        case unreadable(String)
        case noFolders

        public var description: String {
            switch self {
            case .unreadable(let why): String(localized: "Could not read the workspace file: \(why)")
            case .noFolders: String(localized: "The workspace file lists no folders Tiri can open")
            }
        }
    }

    public struct Imported: Equatable, Sendable {
        public var name: String
        public var folders: [String]
        /// A workspace on a server, as Remote-SSH writes it. `folders` are then paths on that server.
        public var remote: String?
        /// Folders left out because they're on a server and this workspace has local ones.
        public var skipped = 0
    }

    /// Where a Remote-SSH folder is: `vscode-remote://ssh-remote+host/path`. The host can be a plain
    /// name, percent-encoded, or hex-encoded JSON, as VS Code writes when it has more to say.
    public static func remoteFolder(uri: String) -> (host: String, path: String)? {
        guard uri.hasPrefix("vscode-remote://") else { return nil }
        let rest = uri.dropFirst("vscode-remote://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = String(rest[..<slash]).removingPercentEncoding ?? String(rest[..<slash])
        guard authority.hasPrefix("ssh-remote+") else { return nil }
        var host = String(authority.dropFirst("ssh-remote+".count))
        if host.count % 2 == 0, host.allSatisfy(\.isHexDigit) {
            var bytes = Data()
            var index = host.startIndex
            while index < host.endIndex {
                let next = host.index(index, offsetBy: 2)
                bytes.append(UInt8(host[index..<next], radix: 16) ?? 0)
                index = next
            }
            if let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let name = json["hostName"] as? String {
                host = (json["user"] as? String).map { $0 + "@" + name } ?? name
            }
        }
        let path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
        guard !host.isEmpty, let destination = SSHConfigFile.destination(from: host) else { return nil }
        return (destination, path)
    }

    /// Read the `folders` list of a Cursor/VS Code workspace. Relative paths are resolved
    /// against the file. Virtual folders (`uri` with any other scheme) are skipped.
    public static func read(fileAt url: URL) throws -> Imported {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        return try parse(data: data, fileURL: url)
    }

    public static func parse(data: Data, fileURL: URL) throws -> Imported {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadable(String(localized: "not UTF-8"))
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8))
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        guard let object = root as? [String: Any], let list = object["folders"] as? [[String: Any]] else {
            throw ImportError.noFolders
        }
        let base = fileURL.deletingLastPathComponent()
        var folders: [String] = []
        var onServers: [(host: String, path: String)] = []
        for entry in list {
            var resolved: String?
            if let uri = entry["uri"] as? String, let found = remoteFolder(uri: uri) { onServers.append(found) }
            if let path = entry["path"] as? String {
                if path.hasPrefix("~/") {
                    resolved = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
                } else if path.hasPrefix("/") {
                    resolved = path
                } else {
                    resolved = base.appendingPathComponent(path).path
                }
            } else if let uri = entry["uri"] as? String, let url = URL(string: uri), url.isFileURL {
                resolved = url.path
            }
            if let resolved {
                let standard = URL(fileURLWithPath: resolved).standardizedFileURL.path
                if !folders.contains(standard) { folders.append(standard) }
            }
        }
        let name = fileURL.deletingPathExtension().lastPathComponent
        // A workspace is on this Mac or on one server. Local folders win if it's a mixture.
        if folders.isEmpty, let host = onServers.first?.host {
            let same = onServers.filter { $0.host == host }
            return Imported(name: name, folders: same.map(\.path), remote: host, skipped: onServers.count - same.count)
        }
        guard !folders.isEmpty else { throw ImportError.noFolders }
        return Imported(name: name, folders: folders, skipped: onServers.count)
    }
}

/// VS Code's config dialect: JSON with comments and trailing commas.
public enum JSONC {
    public static func strip(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let chars = Array(text)
        var index = 0
        var inString = false
        while index < chars.count {
            let character = chars[index]
            if inString {
                out.append(character)
                if character == "\\", index + 1 < chars.count {
                    out.append(chars[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index += 1
            } else if character == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
            } else if character == "," {
                // A comma followed only by whitespace/comments then a closer is dropped.
                var lookahead = index + 1
                while lookahead < chars.count {
                    let next = chars[lookahead]
                    if next.isWhitespace {
                        lookahead += 1
                    } else if next == "/", lookahead + 1 < chars.count, chars[lookahead + 1] == "/" {
                        while lookahead < chars.count, chars[lookahead] != "\n" { lookahead += 1 }
                    } else if next == "/", lookahead + 1 < chars.count, chars[lookahead + 1] == "*" {
                        lookahead += 2
                        while lookahead + 1 < chars.count, !(chars[lookahead] == "*" && chars[lookahead + 1] == "/") { lookahead += 1 }
                        lookahead += 2
                    } else {
                        break
                    }
                }
                if lookahead < chars.count, chars[lookahead] == "}" || chars[lookahead] == "]" {
                    index += 1
                } else {
                    out.append(character)
                    index += 1
                }
            } else {
                out.append(character)
                index += 1
            }
        }
        return out
    }
}

// MARK: - Session restore

public enum TerminalRestore {
    public enum Plan: Equatable, Sendable {
        /// A login shell.
        case shell
        /// Run this straight away: an interactive agent coming back.
        case run(String)
        /// A shell with this typed at the prompt, not run. Re-running `./deploy.sh` because the
        /// app relaunched would be a disaster; `npm run dev` is one Return away.
        case prefill(String)
    }

    /// What to do with a terminal's command after a relaunch. Only agents with a resume form
    /// restart by themselves. Prefers the agent's exact session (`claude --resume <id>`), then its
    /// resume form (`claude --continue`), and never replays a prompt given on the command line.
    public static func plan(for original: String?, sessionID: String? = nil,
                            resume: [String: String], enabled: Bool) -> Plan {
        guard let original else { return .shell }
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .shell }
        let tokens = trimmed.split(separator: " ").map(String.init)
        let tool = tokens[0]
        let name = (tool as NSString).lastPathComponent
        guard let template = resume[name], !template.isEmpty else { return .prefill(trimmed) }
        let profile = AgentCatalog.profile(executable: name)
        let subcommand = tokens.dropFirst().first
        // One-shot runs have nothing to come back to. An agent Tiri has no entry for gets the usual spellings.
        let oneShotFlags = profile?.oneShotFlags ?? ["-p", "--print"]
        let oneShotSubcommands = profile?.oneShotSubcommands ?? ["exec"]
        if tokens.contains(where: oneShotFlags.contains) || subcommand.map(oneShotSubcommands.contains) == true {
            return .prefill(trimmed)
        }
        let resumingFlags = profile?.resumingFlags ?? ["--continue", "--resume", "-c"]
        let resumingSubcommands = profile?.resumingSubcommands ?? ["resume"]
        let alreadyResuming = tokens.contains(where: resumingFlags.contains) || subcommand.map(resumingSubcommands.contains) == true
        let flags = safeFlags(in: Array(tokens.dropFirst()), rawArguments: trimmed)

        guard enabled else { return .run(name + flags) }
        if let sessionID, !sessionID.isEmpty, sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            let extra = alreadyResuming ? "" : flags
            if let command = profile?.resumeCommand {
                return .run(command.replacingOccurrences(of: "{id}", with: sessionID) + extra)
            }
        }
        if alreadyResuming { return .run(trimmed) }
        return .run(template + flags)
    }

    /// The options on a command, or nothing if it also carries a prompt: `claude "delete old
    /// migrations"` must not run that again on every relaunch. Flags and their values are fine.
    private static func safeFlags(in arguments: [String], rawArguments: String) -> String {
        if rawArguments.contains("\"") || rawArguments.contains("'") { return "" }
        var previousWasFlag = false
        for argument in arguments {
            if argument.hasPrefix("-") {
                previousWasFlag = true
            } else if previousWasFlag {
                previousWasFlag = false
            } else {
                return ""
            }
        }
        return arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
    }
}

// MARK: - Agent hooks

/// What an agent's hook payload means for Tiri. `tiri hook claude|codex` reads the payload
/// and turns it into a status update. It prints nothing: hook stdout can enter the agent's context.
public struct AgentHookEvent: Equatable, Sendable {
    public var state: String?
    public var message: String?
    public var sessionID: String?
    /// Whether this is where an agent's turn starts or ends, for "what did this turn change".
    public var turn: Turn?
    /// What you asked for, to tell turns apart.
    public var prompt: String?
    /// What it just did, in words: "Edited auth.ts".
    public var activity: String?
    /// Files it just changed.
    public var files: [String]

    public enum Turn: String, Sendable { case start, end }

    public init(state: String? = nil, message: String? = nil, sessionID: String? = nil, turn: Turn? = nil, prompt: String? = nil,
                activity: String? = nil, files: [String] = []) {
        self.activity = activity
        self.files = files
        self.state = state
        self.message = message
        self.sessionID = sessionID
        self.turn = turn
        self.prompt = prompt
    }

    /// What a tool call amounts to. Agents name their tools differently, so this goes by what they
    /// have in common, and a tool it doesn't know is still named.
    public static func describe(tool: String?, input: [String: Any]?) -> (activity: String?, files: [String]) {
        guard let tool, !tool.isEmpty else { return (nil, []) }
        let path = (input?["file_path"] ?? input?["notebook_path"] ?? input?["path"]) as? String
        let name = path.map { ($0 as NSString).lastPathComponent }
        switch tool.lowercased() {
        case "apply_patch":
            // Codex's one tool for edits names its files inside the patch.
            let files = patchFiles((input?["command"] ?? input?["patch"] ?? input?["input"]) as? String ?? "")
            guard let first = files.first else { return ("Edited a file", []) }
            let shown = (first as NSString).lastPathComponent
            return (files.count == 1 ? "Edited \(shown)" : "Edited \(shown) and \(files.count - 1) more", files)
        case "edit", "multiedit", "notebookedit", "edit_file", "search_replace":
            return (name.map { "Edited \($0)" } ?? "Edited a file", path.map { [$0] } ?? [])
        case "write", "write_file", "create_file":
            return (name.map { "Wrote \($0)" } ?? "Wrote a file", path.map { [$0] } ?? [])
        case "read", "read_file", "view":
            return (name.map { "Read \($0)" } ?? "Read a file", [])
        case "bash", "shell", "run_terminal_cmd", "run_command", "exec", "execute":
            let command = (input?["command"] ?? input?["cmd"]) as? String
            let first = command?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let first, !first.isEmpty else { return ("Ran a command", []) }
            return ("Ran " + (first.count > 60 ? String(first.prefix(59)) + "…" : first), [])
        case "grep", "glob", "search", "ls", "list_dir", "grep_search", "file_search":
            return ("Searched the project", [])
        case "webfetch", "websearch", "web_search", "web_fetch":
            return ("Looked something up online", [])
        case "task", "agent":
            return ("Started a helper", [])
        default:
            return ("Used \(tool)", [])
        }
    }

    /// `*** Add File: a.txt`, `*** Update File: b.txt`, `*** Delete File: c.txt`.
    static func patchFiles(_ patch: String) -> [String] {
        var files: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(marker) {
                let name = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !files.contains(name) { files.append(name) }
            }
        }
        return files
    }

    private static func toolEvent(_ object: [String: Any], session: String?) -> AgentHookEvent {
        let what = describe(tool: object["tool_name"] as? String, input: object["tool_input"] as? [String: Any])
        // A path in a patch is from where the agent is.
        let cwd = object["cwd"] as? String
        let files = what.files.map { file in
            file.hasPrefix("/") ? file : cwd.map { ($0 as NSString).appendingPathComponent(file) } ?? file
        }
        return AgentHookEvent(state: "working", sessionID: session, activity: what.activity, files: files)
    }

    /// Codex names each conversation with a hidden thread of its own, and that thread reports finishing
    /// too, with its own ID and a title as its whole answer. It isn't the session, and the turn isn't over.
    private static func isCodexTitleThread(_ object: [String: Any]) -> Bool {
        guard let message = object["last-assistant-message"] as? String, message.hasPrefix("{"),
              let parsed = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] else { return false }
        return parsed.count == 1 && parsed["title"] is String
    }

    public static func promptLine(_ text: String?) -> String? { snippet(text) }

    private static func snippet(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.count > 140 ? String(trimmed.prefix(139)) + "…" : trimmed
    }

    /// A `claude -p` or SDK run. Whatever started it, it isn't the conversation in this terminal,
    /// though its hooks see the same `TIRI_ITEM_ID`: it would take over the tab's status, and a
    /// relaunch would resume it instead. Like `TerminalRestore`, one-shot runs have nothing to
    /// come back to. A missing value counts as interactive, so an older Claude still reports.
    public static func isOneShotClaude(entrypoint: String?) -> Bool {
        entrypoint?.hasPrefix("sdk") == true
    }

    /// Claude Code passes JSON on stdin with `hook_event_name`.
    public static func parseClaude(_ data: Data) -> AgentHookEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let session = object["session_id"] as? String
        switch object["hook_event_name"] as? String {
        case "SessionStart":
            // A session that's just opened is waiting for you, whatever its startup output looked like.
            return AgentHookEvent(state: "idle", sessionID: session)
        case "UserPromptSubmit":
            return AgentHookEvent(state: "working", sessionID: session, turn: .start, prompt: object["prompt"] as? String)
        case "PostToolUse":
            return toolEvent(object, session: session)
        case "PreToolUse", "PostToolUseFailure", "SubagentStart":
            return AgentHookEvent(state: "working", sessionID: session)
        case "PermissionRequest":
            let tool = object["tool_name"] as? String
            return AgentHookEvent(state: "needs-input", message: tool.map { "Wants to use \($0)" }, sessionID: session)
        case "Notification":
            // idle_prompt only says the session is waiting for its next prompt, which `Stop` covers.
            let type = object["notification_type"] as? String
            if type == "idle_prompt" { return AgentHookEvent(sessionID: session) }
            return AgentHookEvent(state: "needs-input", message: snippet(object["message"] as? String), sessionID: session)
        case "Stop":
            // Background tasks still running means the turn ended but the work didn't.
            if let tasks = object["background_tasks"] as? [Any], !tasks.isEmpty {
                return AgentHookEvent(state: "working", sessionID: session)
            }
            return AgentHookEvent(state: "done", message: snippet(object["last_assistant_message"] as? String), sessionID: session, turn: .end)
        case "StopFailure":
            return AgentHookEvent(state: "done", message: snippet(object["error"] as? String) ?? "Stopped with an error", sessionID: session, turn: .end)
        default:
            return session == nil ? nil : AgentHookEvent(sessionID: session)
        }
    }

    /// Grok's payload reads a lot like Claude Code's, and these are where it doesn't. `Stop` also
    /// fires as a session closes, with a reason of `shutdown`, after the real end of its last turn.
    /// An interrupted turn gets its own event. These were read from real payloads.
    public static func parseGrok(_ data: Data) -> AgentHookEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let session = (object["session_id"] as? String) ?? (object["sessionId"] as? String)
        func text(_ names: String...) -> String? {
            for name in names { if let value = object[name] as? String { return value } }
            return nil
        }
        switch object["hook_event_name"] as? String {
        case "SessionStart":
            return AgentHookEvent(state: "idle", sessionID: session)
        case "UserPromptSubmit":
            return AgentHookEvent(state: "working", sessionID: session, turn: .start, prompt: object["prompt"] as? String)
        case "PostToolUse":
            return toolEvent(object, session: session)
        case "PreToolUse", "PostToolUseFailure", "SubagentStart":
            return AgentHookEvent(state: "working", sessionID: session)
        case "Notification":
            let type = text("notification_type", "notificationType", "type")
            // Only this one is waiting for you. A finished turn has `Stop`, and idle isn't news.
            guard type == "permission_prompt" else { return AgentHookEvent(sessionID: session) }
            return AgentHookEvent(state: "needs-input", message: snippet(text("message", "title")) ?? "Wants your permission", sessionID: session)
        case "Stop":
            if text("reason") == "shutdown" { return AgentHookEvent(sessionID: session) }
            return AgentHookEvent(state: "done", message: snippet(text("last_assistant_message", "lastAssistantMessage")), sessionID: session, turn: .end)
        case "StopFailure":
            return AgentHookEvent(state: "done", message: snippet(text("error", "message")) ?? "Stopped with an error", sessionID: session, turn: .end)
        case "StopCancelled":
            return AgentHookEvent(state: "done", message: "Stopped", sessionID: session, turn: .end)
        default:
            return session == nil ? nil : AgentHookEvent(sessionID: session)
        }
    }

    /// Codex `notify` appends one JSON argument; its hooks pass JSON on stdin.
    public static func parseCodex(_ data: Data) -> AgentHookEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let session = (object["thread-id"] as? String) ?? (object["session_id"] as? String)
        if let type = object["type"] as? String {
            if type == "agent-turn-complete" {
                if isCodexTitleThread(object) { return nil }
                return AgentHookEvent(state: "done", message: snippet(object["last-assistant-message"] as? String), sessionID: session, turn: .end, prompt: (object["input-messages"] as? [String])?.last)
            }
            return session == nil ? nil : AgentHookEvent(sessionID: session)
        }
        switch object["hook_event_name"] as? String {
        case "PermissionRequest":
            return AgentHookEvent(state: "needs-input", message: (object["tool_name"] as? String).map { "Wants to use \($0)" }, sessionID: session)
        case "UserPromptSubmit":
            return AgentHookEvent(state: "working", sessionID: session, turn: .start, prompt: object["prompt"] as? String)
        case "SessionStart":
            return AgentHookEvent(state: "idle", sessionID: session)
        case "PostToolUse":
            return toolEvent(object, session: session)
        case "PreToolUse":
            return AgentHookEvent(state: "working", sessionID: session)
        case "Interrupt":
            return AgentHookEvent(state: "done", message: "Interrupted", sessionID: session, turn: .end)
        default:
            return session == nil ? nil : AgentHookEvent(sessionID: session)
        }
    }
}
