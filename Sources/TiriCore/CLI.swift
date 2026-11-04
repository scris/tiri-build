import Foundation

/// Turns `tiri …` arguments into a control request. Pure, so it can be tested without an app.
public enum CLIParser {
    public enum Parsed: Equatable, Sendable {
        case request(ControlRequest, json: Bool)
        case printText(String)
        /// `tiri notify` outside a Tiri terminal: succeed quietly so hooks never break elsewhere.
        case quietSuccess
    }

    public struct UsageError: Error, CustomStringConvertible, Equatable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    public struct Environment: Sendable {
        public var cwd: String
        public var itemID: String?
        public var workspace: String?
        /// `CLAUDE_CODE_ENTRYPOINT`, which Claude Code sets for its own hooks.
        public var claudeEntrypoint: String?
        /// The command lines above this process, nearest first. Asked for only by hooks.
        public var ancestors: @Sendable () -> [[String]]
        public var fileExists: @Sendable (String) -> Bool
        public var readStdin: @Sendable () -> Data
        /// In a terminal on a server: where its absolute paths really are, and its home folder.
        public var translate: (@Sendable (String) -> String)?
        public var home: String?
        public init(cwd: String, itemID: String?, workspace: String? = nil, claudeEntrypoint: String? = nil,
                    ancestors: @escaping @Sendable () -> [[String]] = { [] },
                    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                    readStdin: @escaping @Sendable () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) {
            self.cwd = cwd
            self.itemID = itemID
            self.workspace = workspace
            self.claudeEntrypoint = claudeEntrypoint
            self.ancestors = ancestors
            self.fileExists = fileExists
            self.readStdin = readStdin
        }
    }

    public static func parse(_ arguments: [String], environment: Environment) throws -> Parsed {
        var args = arguments
        var json = false
        if let index = args.firstIndex(of: "--json") {
            json = true
            args.remove(at: index)
        }
        guard let command = args.first else { return .printText(usage) }
        args.removeFirst()

        func request(_ cmd: String, _ payload: [String: JSONValue] = [:]) -> Parsed {
            .request(ControlRequest(cmd: cmd, args: payload), json: json)
        }

        switch command {
        case "--help", "-h", "help":
            return .printText(usage)
        case "--version", "-v":
            return .printText("tiri \(TiriCoreVersion.string)")
        case "--skill":
            return .printText(AgentGuide.markdown)

        case "ping":
            return request("ping")
        case "items":
            return request("items")
        case "layout":
            return request("layout")
        case "commands":
            return request("commands")
        case "perf":
            return request("perf")
        case "tree":
            return request("tree")

        case "open":
            var options = Options(args)
            let split = try options.split()
            let pin = options.flag("--pin")
            let peek = options.flag("--peek")
            let tab = options.flag("--tab")
            guard let raw = options.positional() else { throw UsageError("usage: tiri open <path>[:line] [--peek | --tab | --split right|down] [--pin]") }
            try options.finish()
            let location = parseLocation(raw, environment: environment)
            var payload: [String: JSONValue] = ["path": .string(location.path)]
            if let line = location.line { payload["line"] = .int(line) }
            if let col = location.col { payload["col"] = .int(col) }
            if let split { payload["split"] = .string(split) }
            if pin { payload["pin"] = true }
            if peek { payload["mode"] = "peek" }
            if tab { payload["mode"] = "tab" }
            // Sent from a Tiri terminal: the app floats it as a Peek rather than adding a tab.
            if let item = environment.itemID { payload["source"] = .string(item) }
            return request("open", payload)

        case "askpass":
            // ssh runs this when it has a question: a passphrase, a password, an unknown host.
            return request("askpass", ["prompt": .string(args.joined(separator: " ")),
                                       "host": .string(ProcessInfo.processInfo.environment["TIRI_ASKPASS_HOST"] ?? "")])

        case "dev-change":
            guard args.count >= 1, let row = Int(args[0]) else { throw UsageError("usage: tiri dev-change <row> [undo|ask]   (test copies only)") }
            var payload: [String: JSONValue] = ["row": .int(row)]
            if args.count > 1 { payload["action"] = .string(args[1]) }
            return request("dev.change", payload)

        case "dev-page":
            guard args.count == 1 else { throw UsageError("usage: tiri dev-page <script>   (test copies only)") }
            return request("dev.page", ["script": .string(args[0])])

        case "notebook":
            let usage = "usage: tiri notebook status|interrupt|restart|stop <path> | run <path> [--cell N]   (cells count from 0; results go in the file)"
            var options = Options(args)
            let rawCell = try options.value("--cell")
            guard let action = options.positional(), ["status", "run", "interrupt", "restart", "stop"].contains(action), let path = options.positional() else {
                throw UsageError(usage)
            }
            try options.finish()
            var payload: [String: JSONValue] = ["path": .string(absolute(path, environment))]
            if let rawCell {
                guard action == "run", let cell = Int(rawCell), cell >= 0 else { throw UsageError(usage) }
                payload["cell"] = .int(cell)
            }
            return request("notebook." + action, payload)

        case "conversations":
            let usage = "usage: tiri conversations [words] | open <session> | reopen <session> | hand <session> <agent>"
            if args.first == "open" || args.first == "reopen" {
                guard args.count == 2 else { throw UsageError(usage) }
                return request("conversations", [args[0]: .string(args[1])])
            }
            if args.first == "hand" {
                guard args.count == 3 else { throw UsageError(usage) }
                return request("conversations", ["hand": .string(args[1]), "to": .string(args[2])])
            }
            return request("conversations", args.isEmpty ? [:] : ["query": .string(args.joined(separator: " "))])

        case "work":
            guard args.isEmpty else { throw UsageError("usage: tiri work   (branches and worktrees besides this one, in plain terms)") }
            return request("work")

        case "activity":
            guard args.isEmpty else { throw UsageError("usage: tiri activity   (what every running agent is doing)") }
            return request("activity")

        case "worktree":
            guard args.count == 1 else { throw UsageError("usage: tiri worktree <branch>   (a second checkout, as a workspace, for another agent)") }
            var payload: [String: JSONValue] = ["branch": .string(args[0])]
            if let item = environment.itemID { payload["source"] = .string(item) }
            return request("worktree.add", payload)

        case "remote":
            let usage = "usage: tiri remote [connect <host> [<folder>] | disconnect <host> | ports | forward <port>]"
            switch args.first {
            case nil:
                return request("remote.list")
            case "connect":
                guard args.count == 2 || args.count == 3 else { throw UsageError(usage) }
                var payload: [String: JSONValue] = ["host": .string(args[1])]
                if args.count == 3 { payload["folder"] = .string(args[2]) }
                return request("remote.connect", payload)
            case "disconnect":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("remote.disconnect", ["host": .string(args[1])])
            case "ports":
                guard args.count == 1 else { throw UsageError(usage) }
                return request("remote.ports")
            case "forward":
                guard args.count == 2, let port = Int(args[1]) else { throw UsageError(usage) }
                return request("remote.forward", ["port": .int(port)])
            default:
                throw UsageError(usage)
            }

        case "search":
            guard !args.isEmpty else { throw UsageError("usage: tiri search <text>") }
            return request("search", ["query": .string(args.joined(separator: " "))])

        case "select":
            var options = Options(args)
            let to = try options.value("--to")
            guard let item = options.positional(), let text = options.positional() else {
                throw UsageError("usage: tiri select <item-id> <text> [--to <text>]   (selects it in the file, diff or page)")
            }
            try options.finish()
            var payload: [String: JSONValue] = ["item": .string(item), "text": .string(text)]
            if let to { payload["to"] = .string(to) }
            return request("select", payload)

        case "changes":
            let usage = "usage: tiri changes [--branch | --commit <rev> | --turn <id|latest>]"
            var options = Options(args)
            let turn = try options.value("--turn")
            let commit = try options.value("--commit")
            let branch = options.flag("--branch")
            try options.finish()
            guard [turn != nil, commit != nil, branch].filter({ $0 }).count <= 1 else { throw UsageError(usage) }
            if branch { return request("changes.branch") }
            if let commit { return request("changes.commit", ["commit": .string(commit)]) }
            return request("changes", turn.map { ["turn": .string($0)] } ?? [:])

        case "log":
            var options = Options(args)
            let rawLimit = try options.value("--limit")
            let limit = rawLimit.flatMap(Int.init)
            if rawLimit != nil, (limit ?? 0) < 1 { throw UsageError("--limit must be a positive number") }
            try options.finish()
            return request("log", limit.map { ["limit": .int($0)] } ?? [:])

        case "turns":
            guard args.isEmpty else { throw UsageError("usage: tiri turns") }
            return request("turns")

        case "diagnostics":
            var options = Options(args)
            var paths: [JSONValue] = []
            while let raw = options.positional() { paths.append(.string(absolute(raw, environment))) }
            try options.finish()
            return request("diagnostics", paths.isEmpty ? [:] : ["paths": .array(paths)])

        case "languages":
            guard args.isEmpty else { throw UsageError("usage: tiri languages") }
            return request("languages")

        case "agents":
            let usage = "usage: tiri agents [on <agent> | off <agent> | add <name> <command> | remove <agent>]"
            switch args.first {
            case nil:
                return request("agents.list")
            case "on", "off":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("agents.set", ["agent": .string(args[1]), "on": .bool(args[0] == "on")])
            case "add":
                guard args.count >= 3 else { throw UsageError(usage) }
                return request("agents.add", ["name": .string(args[1]), "command": .string(args[2...].joined(separator: " "))])
            case "remove":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("agents.remove", ["agent": .string(args[1])])
            default:
                throw UsageError(usage)
            }

        case "git":
            guard args.isEmpty else { throw UsageError("usage: tiri git") }
            return request("git")

        case "diff":
            var options = Options(args)
            let tab = options.flag("--tab")
            let turn = try options.value("--turn")
            let commit = try options.value("--commit")
            let branch = options.flag("--branch")
            let usage = "usage: tiri diff <path> [--tab] [--branch | --commit <rev> | --turn <id|latest>]"
            guard let raw = options.positional() else { throw UsageError(usage) }
            try options.finish()
            guard [turn != nil, commit != nil, branch].filter({ $0 }).count <= 1 else { throw UsageError(usage) }
            var payload: [String: JSONValue] = ["path": .string(absolute(raw, environment))]
            if tab { payload["mode"] = "tab" }
            if let turn { payload["turn"] = .string(turn) }
            if let commit { payload["commit"] = .string(commit) }
            if branch { payload["branch"] = true }
            return request("diff", payload)

        case "review":
            let usage = "usage: tiri review [add <path>[:line[-line]] <text> | remove <id> | clear | send [--to <item-id>]]"
            switch args.first {
            case nil:
                return request("review.list")
            case "add":
                guard args.count >= 3 else { throw UsageError(usage) }
                var payload: [String: JSONValue] = ["text": .string(args[2...].joined(separator: " "))]
                let target = args[1]
                if let match = target.wholeMatch(of: /(.+):(\d+)-(\d+)/), !environment.fileExists(absolute(target, environment)) {
                    payload["path"] = .string(absolute(String(match.1), environment))
                    payload["line"] = .int(Int(match.2) ?? 1)
                    payload["lastLine"] = .int(Int(match.3) ?? 1)
                } else {
                    let location = parseLocation(target, environment: environment)
                    payload["path"] = .string(location.path)
                    if let line = location.line { payload["line"] = .int(line) }
                }
                if let item = environment.itemID { payload["source"] = .string(item) }
                return request("review.add", payload)
            case "remove":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("review.remove", ["id": .string(args[1])])
            case "clear":
                guard args.count == 1 else { throw UsageError(usage) }
                return request("review.clear")
            case "send":
                var options = Options(Array(args.dropFirst()))
                let target = try options.value("--to")
                try options.finish()
                return request("review.send", target.map { ["item": .string($0)] } ?? [:])
            default:
                throw UsageError(usage)
            }

        case "reveal":
            var options = Options(args)
            guard let raw = options.positional() else { throw UsageError("usage: tiri reveal <path>") }
            try options.finish()
            return request("reveal", ["path": .string(absolute(raw, environment))])

        case "preview":
            var options = Options(args)
            let split = try options.split()
            guard let raw = options.positional() else { throw UsageError("usage: tiri preview <url-or-path> [--split right]") }
            try options.finish()
            var payload: [String: JSONValue] = ["target": .string(normalizeWebTarget(raw, environment))]
            if let split { payload["split"] = .string(split) }
            if let item = environment.itemID { payload["source"] = .string(item) }
            return request("preview", payload)

        case "term":
            var options = Options(args)
            let split = try options.split()
            let cwd = try options.value("--cwd")
            let cmd = try options.value("--cmd")
            try options.finish()
            var payload: [String: JSONValue] = ["cwd": .string(absolute(cwd ?? environment.cwd, environment))]
            if let cmd { payload["cmd"] = .string(cmd) }
            if let split { payload["split"] = .string(split) }
            if let item = environment.itemID { payload["source"] = .string(item) }
            return request("term", payload)

        case "workspace":
            guard let sub = args.first else { throw UsageError(workspaceUsage) }
            var options = Options(Array(args.dropFirst()))
            switch sub {
            case "list":
                try options.finish()
                return request("workspace.list")
            case "switch":
                guard let name = options.positional() else { throw UsageError("usage: tiri workspace switch <name>") }
                try options.finish()
                return request("workspace.switch", ["name": .string(name)])
            case "new":
                let folders = try options.values("--folder").map { JSONValue.string(absolute($0, environment)) }
                guard let name = options.positional() else { throw UsageError("usage: tiri workspace new <name> [--folder DIR ...]") }
                try options.finish()
                return request("workspace.new", ["name": .string(name), "folders": .array(folders)])
            case "add-folder":
                guard let folder = options.positional() else { throw UsageError("usage: tiri workspace add-folder <DIR>") }
                try options.finish()
                var payload: [String: JSONValue] = ["folder": .string(absolute(folder, environment))]
                if let item = environment.itemID { payload["source"] = .string(item) }
                return request("workspace.add-folder", payload)
            case "remove-folder":
                guard let folder = options.positional() else { throw UsageError("usage: tiri workspace remove-folder <DIR>") }
                try options.finish()
                var payload: [String: JSONValue] = ["folder": .string(absolute(folder, environment))]
                if let item = environment.itemID { payload["source"] = .string(item) }
                return request("workspace.remove-folder", payload)
            case "import":
                guard let file = options.positional() else { throw UsageError("usage: tiri workspace import <file.code-workspace>") }
                try options.finish()
                return request("workspace.import", ["file": .string(absolute(file, environment))])
            case "rename":
                guard let name = options.positional() else { throw UsageError("usage: tiri workspace rename <new-name> [<workspace>]") }
                let target = options.positional()
                try options.finish()
                var payload: [String: JSONValue] = ["name": .string(name)]
                if let target { payload["workspace"] = .string(target) }
                return request("workspace.rename", payload)
            case "delete":
                guard let name = options.positional() else { throw UsageError("usage: tiri workspace delete <name>") }
                try options.finish()
                return request("workspace.delete", ["name": .string(name)])
            default:
                throw UsageError(workspaceUsage)
            }

        case "focus", "close":
            var options = Options(args)
            guard let id = options.positional() else { throw UsageError("usage: tiri \(command) <item-id>") }
            try options.finish()
            return request(command, ["item": .string(id)])

        case "notify":
            var options = Options(args)
            let message = try options.value("--message")
            let explicit = try options.value("--item")
            guard let state = options.positional() else { throw UsageError("usage: tiri notify <working|needs-input|done> [--message TEXT]") }
            try options.finish()
            guard ["working", "needs-input", "done"].contains(state) else {
                throw UsageError("notify state must be working, needs-input or done")
            }
            guard let item = explicit ?? environment.itemID else { return .quietSuccess }
            var payload: [String: JSONValue] = ["state": .string(state), "item": .string(item)]
            if let message { payload["message"] = .string(message) }
            return request("notify", payload)

        case "hook":
            // Reads the agent's payload. Never fails loudly: a hook must not disturb the agent.
            guard let tool = args.first, let stated = AgentIdentity(rawValue: tool), stated.profile?.parseHook != nil else {
                throw UsageError("usage: tiri hook \(hookAgents) [payload]   (reads the payload from stdin)")
            }
            guard let item = environment.itemID else { return .quietSuccess }
            let payload = args.count > 1 ? Data(args[1].utf8) : environment.readStdin()
            // Grok runs Claude Code's hooks too. It's still Grok that's talking.
            let agent = AgentCatalog.owner(ofHookPayload: payload, reportedAs: stated)
            if agent == .claude, AgentHookEvent.isOneShotClaude(entrypoint: environment.claudeEntrypoint) { return .quietSuccess }
            if AgentCatalog.isOneShotRun(ancestors: environment.ancestors()) { return .quietSuccess }
            guard let event = agent.profile?.parseHook?(payload) else { return .quietSuccess }
            var body: [String: JSONValue] = ["item": .string(item), "tool": .string(agent.rawValue)]
            if let state = event.state { body["state"] = .string(state) }
            if let message = event.message { body["message"] = .string(message) }
            if let session = event.sessionID { body["session"] = .string(session) }
            if let turn = event.turn { body["turn"] = .string(turn.rawValue) }
            if let prompt = event.prompt { body["prompt"] = .string(prompt) }
            if let activity = event.activity { body["activity"] = .string(activity) }
            if let file = event.file { body["file"] = .string(file) }
            body["hook"] = true
            return request("notify", body)

        case "hooks":
            if args.count == 2, args[0] == "install" || args[0] == "remove", AgentHooks.Tool(rawValue: args[1])?.profile?.hookInstall != nil {
                return request("hooks.\(args[0])", ["tool": .string(args[1])])
            }
            guard args.count == 1, let example = args.first.flatMap(AgentIdentity.init(rawValue:))?.profile?.hookExample else {
                throw UsageError("usage: tiri hooks install|remove \(hookAgents)   (Tiri asks you first)\n       tiri hooks \(hookAgents)   (prints the config)")
            }
            return .printText(example)

        case "theme":
            guard args.count == 1, ThemeMode(rawValue: args[0]) != nil else { throw UsageError("usage: tiri theme light|dark|system") }
            return request("theme", ["mode": .string(args[0])])

        case "web-dark":
            guard let mode = args.first, mode == "on" || mode == "off", args.count <= 2 else {
                throw UsageError("usage: tiri web-dark on|off [<item-id>]")
            }
            var payload: [String: JSONValue] = ["on": .bool(mode == "on")]
            if args.count == 2 { payload["item"] = .string(args[1]) }
            return request("web-dark", payload)

        case "keys":
            let usage = "usage: tiri keys [set <command> <key> | unset <command> | reset <command>]   (keys look like cmd+shift+p, or cmd+k cmd+s)"
            switch args.first {
            case nil:
                return request("commands")
            case "set":
                guard args.count >= 3 else { throw UsageError(usage) }
                return request("keys.set", ["command": .string(args[1]), "key": .string(args[2...].joined(separator: " "))])
            case "unset":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("keys.unset", ["command": .string(args[1])])
            case "reset":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("keys.reset", ["command": .string(args[1])])
            default:
                throw UsageError(usage)
            }

        case "quit":
            guard args.isEmpty else { throw UsageError("usage: tiri quit") }
            return request("quit")

        case "follow":
            guard args.count == 3, let row = Int(args[1]), let col = Int(args[2]) else {
                throw UsageError("usage: tiri follow <item-id> <row> <col>   (what ⌘-click does; counts from 0)")
            }
            return request("follow", ["item": .string(args[0]), "row": .int(row), "col": .int(col)])

        case "settings":
            let usage = "usage: tiri settings [explain [<key>] | get <key> | set <key> <value> | reset <key> | open]"
            switch args.first {
            case nil:
                return request("settings.list")
            case "explain":
                guard args.count <= 2 else { throw UsageError(usage) }
                return request("settings.explain", args.count == 2 ? ["key": .string(args[1])] : [:])
            case "get":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("settings.get", ["key": .string(args[1])])
            case "set":
                guard args.count >= 3 else { throw UsageError(usage) }
                return request("settings.set", ["key": .string(args[1]), "value": .string(args[2...].joined(separator: " "))])
            case "reset":
                guard args.count == 2 else { throw UsageError(usage) }
                return request("settings.reset", ["key": .string(args[1])])
            case "open":
                guard args.count == 1 else { throw UsageError(usage) }
                return request("settings.open")
            default:
                throw UsageError(usage)
            }

        case "run":
            guard args.count == 1 else { throw UsageError("usage: tiri run <command-id>   (see tiri commands)") }
            return request("run", ["command": .string(args[0])])

        case "send":
            var options = Options(args)
            let enter = options.flag("--enter")
            guard let id = options.positional(), let text = options.positional() else {
                throw UsageError("usage: tiri send <item-id> <text> [--enter]")
            }
            try options.finish()
            return request("send", ["item": .string(id), "text": .string(enter ? text + "\r" : text)])

        case "read":
            var options = Options(args)
            let rawLines = try options.value("--lines")
            let lines = rawLines.flatMap(Int.init)
            if rawLines != nil, (lines ?? 0) < 1 { throw UsageError("--lines must be a positive number") }
            guard let id = options.positional() else { throw UsageError("usage: tiri read <item-id> [--lines N]") }
            try options.finish()
            var payload: [String: JSONValue] = ["item": .string(id)]
            if let lines { payload["lines"] = .int(lines) }
            return request("read", payload)

        default:
            throw UsageError("Unknown command \"\(command)\". Run tiri --help.")
        }
    }

    /// `claude|codex|grok`, as it stands.
    private static var hookAgents: String {
        AgentCatalog.all.filter { $0.parseHook != nil }.map(\.id).joined(separator: "|")
    }

    private static let workspaceUsage = "usage: tiri workspace list | switch <name> | new <name> [--folder DIR ...] | add-folder <DIR> | remove-folder <DIR> | import <file.code-workspace> | rename <new-name> [<workspace>] | delete <name>"

    public static let usage = """
    tiri — control a running Tiri

      tiri open <path>[:line] [--peek | --tab | --split right|down] [--pin]
      tiri reveal <path>
      tiri preview <url-or-path> [--split right]
      tiri term [--cwd DIR] [--cmd "claude"] [--split right]
      tiri worktree <branch>       (a second checkout, as a workspace, so another agent's edits stay apart)
      tiri remote                  (servers in use, and how their connections are)
      tiri remote connect <host> [<folder>]   (a workspace on a server, over SSH)
      tiri remote disconnect <host> | ports | forward <port>
      tiri workspace list | switch <name> | new <name> [--folder DIR ...] | add-folder <DIR>
                     remove-folder <DIR> | import <file.code-workspace> | rename <new-name> | delete <name>
      tiri items
      tiri focus <item-id> | close <item-id>
      tiri notify <working|needs-input|done> [--message TEXT]
      tiri hook <agent>         (for agent hooks: reads the payload, prints nothing)
      tiri hooks install|remove <agent>   (Tiri asks you first)
      tiri hooks <agent>        (prints the hooks config)
                                (agents with hooks: claude, codex, grok)
      tiri theme light|dark|system
      tiri web-dark on|off [<item-id>]
      tiri search <text>           (across the workspace's files, as ⌘⇧F does)
      tiri select <item-id> <text> [--to <text>]   (select it in a file, diff or page, to point at it)
      tiri changes [--branch | --commit <rev> | --turn <id|latest>]
                                   (files changed since the last commit, since the branch left its base, in one commit, or in one agent's turn)
      tiri log [--limit N]         (recent commits)
      tiri turns                   (agents' recent turns)
      tiri git                     (each repository's branch, and commits to pull and push)
      tiri diff <path> [--tab] [--branch | --commit <rev> | --turn <id|latest>]
                                   (what changed in one file; floats as a Peek)
      tiri review [add <path>[:line[-line]] <text> | remove <id> | clear | send [--to <item-id>]]
                                   (comments waiting to go to an agent, all at once)
      tiri diagnostics [<path> ...]   (errors and warnings; without paths, in files changed since the last commit)
      tiri languages               (which language servers Tiri can find)
      tiri agents [on <agent> | off <agent> | add <name> <command> | remove <agent>]
                                   (which agents Tiri offers, everywhere it offers them)
      tiri follow <item-id> <row> <col>   (what ⌘-click does, on a terminal's path or a file's name)
      tiri quit                    (terminals keep running, and Tiri comes back to them)
      tiri keys [set <command> <key> | unset <command> | reset <command>]
      tiri settings [explain [<key>] | get <key> | set <key> <value> | reset <key> | open]
      tiri send <item-id> <text> [--enter]
      tiri read <item-id> [--lines N]
      tiri layout | tree | commands | run <command-id> | perf
      tiri ping
      tiri --skill      markdown guide for agents

    Add --json to print the raw response.
    """

    // MARK: Helpers

    /// A path as the person typing it means it, wherever they're typing it.
    public static func absolute(_ path: String, _ environment: Environment) -> String {
        if let translate = environment.translate {
            if path == "~" || path.hasPrefix("~/") { return translate((environment.home ?? "") + path.dropFirst(1)) }
            if path.hasPrefix("/") { return translate(path) }
            return RemotePathMap.lexical(environment.cwd + "/" + path)
        }
        return absolute(path, cwd: environment.cwd)
    }

    public static func absolute(_ path: String, cwd: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = NSHomeDirectory()
        } else if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + expanded.dropFirst(1)
        }
        if !expanded.hasPrefix("/") {
            expanded = (cwd as NSString).appendingPathComponent(expanded)
        }
        return (expanded as NSString).standardizingPath
    }

    /// A URL stays as it is; `localhost:3000` gets a scheme; anything else is a file path.
    public static func normalizeWebTarget(_ raw: String, cwd: String) -> String {
        if raw.contains("://") { return raw }
        if raw.wholeMatch(of: /(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/.*)?/) != nil { return "http://" + raw }
        return URL(fileURLWithPath: absolute(raw, cwd: cwd)).absoluteString
    }

    public static func normalizeWebTarget(_ raw: String, _ environment: Environment) -> String {
        if raw.contains("://") || raw.wholeMatch(of: /(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/.*)?/) != nil {
            return normalizeWebTarget(raw, cwd: environment.cwd)
        }
        return URL(fileURLWithPath: absolute(raw, environment)).absoluteString
    }

    /// `path:12:3`, unless a file literally has that name.
    static func parseLocation(_ raw: String, environment: Environment) -> (path: String, line: Int?, col: Int?) {
        let whole = absolute(raw, environment)
        if environment.fileExists(whole) { return (whole, nil, nil) }
        if let match = raw.wholeMatch(of: /(.+?):(\d+):(\d+)/) {
            return (absolute(String(match.1), environment), Int(match.2), Int(match.3))
        }
        if let match = raw.wholeMatch(of: /(.+?):(\d+)/) {
            return (absolute(String(match.1), environment), Int(match.2), nil)
        }
        return (whole, nil, nil)
    }

    private struct Options {
        var args: [String]
        init(_ args: [String]) { self.args = args }

        mutating func flag(_ name: String) -> Bool {
            guard let index = args.firstIndex(of: name) else { return false }
            args.remove(at: index)
            return true
        }

        mutating func value(_ name: String) throws -> String? {
            if let index = args.firstIndex(where: { $0.hasPrefix(name + "=") }) {
                let value = String(args[index].dropFirst(name.count + 1))
                args.remove(at: index)
                return value
            }
            guard let index = args.firstIndex(of: name) else { return nil }
            guard index + 1 < args.count else { throw UsageError("\(name) needs a value") }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }

        mutating func values(_ name: String) throws -> [String] {
            var out: [String] = []
            while let value = try value(name) { out.append(value) }
            return out
        }

        mutating func split() throws -> String? {
            guard let direction = try value("--split") else { return nil }
            guard SplitDirection(rawValue: direction) != nil else { throw UsageError("--split must be right or down") }
            return direction
        }

        mutating func positional() -> String? {
            guard let index = args.firstIndex(where: { !$0.hasPrefix("--") || $0 == "--" }) else { return nil }
            return args.remove(at: index)
        }

        func finish() throws {
            if let extra = args.first { throw UsageError("Unexpected argument: \(extra)") }
        }
    }
}

public enum AgentGuide {
    public static let claudeHooks = #"""
    {
      "hooks": {
        "SessionStart": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "PermissionRequest": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "PostToolUse": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
        "StopFailure": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }]
      }
    }
    """#

    public static let codexHooks = #"""
    # ~/.codex/config.toml
    notify = ["tiri", "hook", "codex"]

    [[hooks.PermissionRequest]]
    [[hooks.PermissionRequest.hooks]]
    type = "command"
    command = "tiri hook codex"
    """#

    public static let grokHooks = #"""
    # ~/.grok/hooks/tiri.json. Grok also runs the hooks in ~/.claude/settings.json by default.
    {
      "hooks": {
        "SessionStart": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "PostToolUse": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "StopFailure": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }],
        "StopCancelled": [{ "hooks": [{ "type": "command", "command": "tiri hook grok" }] }]
      }
    }
    """#

    public static let markdown = #"""
    # Tiri, for agents

    Tiri is the workspace the user is watching. Terminals, files and web previews are equal
    items in one tab/pane system. You can drive all of it with the `tiri` CLI. Use it to put
    your work in front of the user instead of describing where it is.

    ## Am I inside Tiri?

    Terminals launched by Tiri set these variables:

    - `TIRI_SOCKET`: control socket path
    - `TIRI_WORKSPACE`: the workspace's id
    - `TIRI_ITEM_ID`: this terminal's item id

    If `TIRI_ITEM_ID` is unset, you aren't in a Tiri terminal. `tiri ping` still tells you
    whether the app is running.

    ## Show the user your work

    ```sh
    tiri open report.md                   # floats over your terminal as a Peek
    tiri open report.md --split right     # or put it beside your terminal as a tab
    tiri open report.md --tab             # or as a tab in the current group
    tiri open src/app.swift:42            # jump to a line
    tiri open deck.pptx                   # Office, iWork, PDF, images, video all preview
    tiri preview http://localhost:3000 --split right
    tiri preview ./dist/index.html        # local HTML; reloads when the file changes
    tiri reveal src/components            # expand and select it in the file tree
    ```

    From a Tiri terminal, a plain `tiri open` shows a Peek: a floating viewer that doesn't take
    the keyboard away from your session, and one the user can promote to a tab with one button.
    Prefer it for "here's what I made"; use `--split` or `--tab` only when the user asked to
    keep something open. Outside a Tiri terminal, `open` makes a tab; `--peek` forces a Peek.

    Files that are already open get focused instead of opened twice, unless you pass `--split`.
    Open viewers update themselves when the file changes on disk, so don't reopen after editing.

    ## Report status

    The user sees your status on the tab, in the item list and on the workspace switcher, and
    gets a system notification if they aren't looking at this terminal.

    ```sh
    tiri notify working
    tiri notify needs-input --message "Which database should I use?"
    tiri notify done --message "Report is ready"
    ```

    The item defaults to `$TIRI_ITEM_ID`. Outside Tiri, `notify` quietly does nothing, so it's
    safe in hooks and scripts. For Claude Code, Codex and Grok, `tiri hook <agent>` reads the hook
    payload and does this for you, and also records the session id so a relaunch resumes exactly
    this conversation. `tiri hooks <agent>` prints the config to add.

    ## Terminals

    ```sh
    tiri term --cwd ~/project --cmd "npm run dev" --split down
    tiri items                            # ids, kinds, status, titles
    tiri send <item-id> "npm test" --enter
    tiri read <item-id> --lines 40
    tiri focus <item-id>
    tiri close <item-id>
    ```

    ## Workspaces

    ```sh
    tiri workspace list
    tiri workspace new api --folder ~/api --folder ~/shared
    tiri workspace switch api
    tiri workspace add-folder ~/docs
    tiri workspace import team.code-workspace
    ```

    ## Show what changed

    ```sh
    tiri changes                          # files changed since the last commit
    tiri changes --branch                 # everything since this branch left its base, uncommitted work included
    tiri log                              # recent commits
    tiri changes --commit HEAD~1          # what one commit changed
    tiri diff src/app.ts --commit HEAD~1  # one file's changes in it
    tiri diff src/app.ts --branch         # or on the whole branch
    tiri turns                            # recent turns, yours and other agents'
    tiri changes --turn latest            # what the latest turn changed
    tiri diff src/app.ts --turn latest    # one file's changes in it
    tiri git                              # each repository's branch, and commits to pull and push
    tiri remote connect gpu ~/project     # a workspace on a server: terminals, files, changes and search all work there
    tiri remote forward 3000              # reach a port on the server from this Mac, and print the address
    tiri notebook run report.ipynb        # run every cell; --cell N for one, counting from 0
    tiri notebook status report.ipynb     # is it still going? Results are in the file as they arrive
    tiri diff src/app.ts                  # floats what changed over your terminal
    tiri diff src/app.ts --tab            # or keeps it as a tab
    ```

    After you commit, `tiri changes` is empty. To show the user what you did, use `--branch` or
    `--commit`, and float the file that matters most. A merge shows what it brought in compared
    with its first parent.

    ## Check your work

    `tiri diagnostics` asks the language servers on this Mac. Without paths, it checks the files
    changed since the last commit, and waits for an answer. It prints what compilers print, so
    the user can ⌘-click it. `tiri languages` says which servers Tiri can find.

    ```sh
    tiri diagnostics                      # the files you've changed
    tiri diagnostics src/app.ts           # or these
    ```

    ## Review comments

    The user can comment on lines of files and diffs, then send them all to an agent at once.
    They arrive in your input as one message. You can read the ones still waiting too.

    ```sh
    tiri review                           # comments waiting to be sent
    tiri review add src/app.ts:12-20 "This doesn't handle an empty list"
    tiri review send --to <item-id>       # put them in that session's input, unsent
    ```

    ## Appearance and settings

    ```sh
    tiri theme dark                       # light, dark or system
    tiri web-dark on [<item-id>]          # force dark on a web preview, PDF or Office file
    ```

    Change settings with `tiri settings`, never by editing a file. Changes apply immediately.

    ```sh
    tiri settings                         # every setting and its current value
    tiri settings explain [<key>]         # what each one does, and what it accepts
    tiri settings get <key>
    tiri settings set <key> <value>       # for example: tiri settings set code.wordWrap on
    tiri settings reset <key>
    tiri settings open                    # open the settings screen for the user
    ```

    Which agents Tiri offers is one list, used everywhere it offers them:

    ```sh
    tiri agents                           # each agent, and whether it's on
    tiri agents off codex                 # stops offering it. Running sessions carry on
    tiri agents on grok
    tiri agents add Aider "aider --yes"   # anything can be an agent
    tiri agents remove Aider              # one of Tiri's own is only turned off
    ```

    Keyboard shortcuts work the same way:

    ```sh
    tiri keys                             # every command and its shortcut
    tiri keys set splitDown cmd+shift+d   # chords look like "cmd+k cmd+s"
    tiri keys unset toggleSidebar
    tiri keys reset splitDown
    ```

    When someone asks about their settings or shortcuts, run these, describe them in plain words, and change what they ask for.

    ## Anything else

    ```sh
    tiri commands                         # every action the user can trigger
    tiri run splitRight                   # run one by id
    tiri layout                           # the pane tree as JSON
    ```

    ## Protocol

    The CLI is a thin client. The socket at `$TIRI_SOCKET` speaks newline-delimited JSON:

    ```
    → {"id":"1","cmd":"open","args":{"path":"/abs/report.md","split":"right"}}
    ← {"id":"1","ok":true,"result":{"item":"i-abc123"}}
    ```

    Add `--json` to any CLI command to see the raw response.
    """#
}
