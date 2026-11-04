import Foundation

/// Which agent something is. Comparing these is fine. Asking what an agent can do is what
/// `profile` is for, so that the next agent doesn't mean changing every place that asks.
public struct AgentIdentity: Hashable, Sendable, RawRepresentable, CaseIterable {
    public let rawValue: String

    /// Only for agents Tiri knows, or `other`. Anything else from a command line isn't an agent.
    public init?(rawValue: String) {
        guard rawValue == Self.other.rawValue || AgentCatalog.profile(id: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(known: String) { rawValue = known }

    public static let claude = AgentIdentity(known: "claude")
    public static let codex = AgentIdentity(known: "codex")
    public static let grok = AgentIdentity(known: "grok")
    /// One Tiri has no entry for, like something you've added to the New Terminal menu. It can
    /// still be handed lines and files, as plain text.
    public static let other = AgentIdentity(known: "other")

    /// The agents whose hooks Tiri can install.
    public static var allCases: [AgentIdentity] {
        AgentCatalog.all.filter { $0.hookInstall != nil }.map { AgentIdentity(known: $0.id) }
    }

    public var profile: AgentProfile? { AgentCatalog.profile(id: rawValue) }
    public var title: String { profile?.title ?? "Agent" }
}

/// Everything Tiri needs to know about one CLI agent.
///
/// **To support another agent, add one entry to `AgentCatalog.all`.** Recognizing it, quoting to
/// it, resuming it, its hooks, the settings screen, the empty screen and the CLI all read from
/// here. Read its own docs for hook payloads, and check them against a real run: the documents
/// of two agents that look alike can hide real differences.
public struct AgentProfile: Sendable, Identifiable {
    /// How lines of a file are written after its path.
    public enum LineStyle: Sendable {
        /// `a.ts#L12-20`
        case hash
        /// `a.ts:12-20`
        case colon
    }

    /// How Tiri's hooks get into an agent's configuration. These are the agent's own files, and
    /// other people's entries in them can matter a great deal.
    public enum HookInstall: Sendable, Equatable {
        /// Entries merged into a JSON settings file.
        case jsonSettings(file: String)
        /// A marked section added to a TOML file.
        case tomlSection(file: String)
        /// A file of Tiri's own, in a folder the agent reads. The simplest and the safest.
        case ownFile(String)
    }

    public var id: String
    public var title: String
    /// What the New Terminal menu runs.
    public var command: String
    public var website: String
    public var symbol: String

    // Recognizing it among running processes.
    public var executableNames: Set<String>
    /// For an install whose executable isn't named after the agent, like one named after its version.
    public var pathFragments: [String]

    // Quoting to it.
    public var mentionPrefix: String
    public var lineStyle: LineStyle
    /// Whether it connects to Tiri as it would to an editor, and takes real mentions and diagnostics.
    public var speaksEditorProtocol: Bool

    // Bringing it back after a relaunch.
    public var continueCommand: String?
    /// With `{id}` where the session goes.
    public var resumeCommand: String?
    public var resumingFlags: Set<String>
    public var resumingSubcommands: Set<String>
    /// Runs that do one thing and leave, with nothing to come back to.
    public var oneShotFlags: Set<String>
    public var oneShotSubcommands: Set<String>

    // Hearing from it.
    /// The folder its configuration is in, from home, and the variable that moves it.
    public var configDirectory: String
    public var configDirectoryVariable: String?
    public var hookInstall: HookInstall?
    public var hookEvents: [String]
    public var parseHook: (@Sendable (Data) -> AgentHookEvent?)?
    /// Whether a hook's payload is really from this agent, whichever command it came through.
    public var claimsHookPayload: (@Sendable (Data) -> Bool)?
    /// An agent whose configured hooks this one runs as well, so hooks for that one report here too.
    public var alsoRunsHooksOf: String?
    /// For `tiri hooks <agent>`.
    public var hookExample: String?

    /// What it prints when there really is no conversation to come back to. Anything else that stops
    /// a resume, like a network or login failure, leaves the conversation worth keeping.
    public var nothingToResume: [String] = []

    // Its past conversations, in its own files, under its configuration folder.
    public var conversationFiles: String? = nil
    public var conversationFormat: ConversationFormat? = nil
    /// Which lines of one say what it's about. The first prompt can be megabytes in.
    public var conversationStart: String? = nil

    public var hookCommand: String { "tiri hook \(id) 2>/dev/null || true" }

    /// How to write a file and maybe some of its lines, which count from zero here.
    public func mention(_ shown: String, firstLine: Int?, lastLine: Int?) -> String {
        AgentProfile.mention(shown, firstLine: firstLine, lastLine: lastLine, prefix: mentionPrefix, style: lineStyle)
    }

    static func mention(_ shown: String, firstLine: Int?, lastLine: Int?, prefix: String, style: LineStyle) -> String {
        var text = shown
        if let first = firstLine {
            let last = lastLine ?? first
            switch style {
            case .hash:
                text += last == first ? "#L\(first + 1)" : "#L\(first + 1)-\(last + 1)"
            case .colon:
                text += last == first ? ":\(first + 1)" : ":\(first + 1)-\(last + 1)"
            }
        }
        if text.contains(" ") { text = "\"" + text + "\"" }
        return prefix + text + " "
    }
}

public enum AgentCatalog {
    public static let all: [AgentProfile] = [
        AgentProfile(
            id: "claude", title: "Claude Code", command: "claude", website: "https://claude.com/product/claude-code", symbol: "sparkle",
            executableNames: ["claude"], pathFragments: ["/claude/versions/", "claude-code/"],
            mentionPrefix: "@", lineStyle: .hash, speaksEditorProtocol: true,
            continueCommand: "claude --continue", resumeCommand: "claude --resume {id}",
            resumingFlags: ["--continue", "--resume", "-c", "-r"], resumingSubcommands: [],
            oneShotFlags: ["-p", "--print"], oneShotSubcommands: [],
            configDirectory: ".claude", configDirectoryVariable: "CLAUDE_CONFIG_DIR",
            hookInstall: .jsonSettings(file: "settings.json"),
            hookEvents: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Notification", "Stop", "StopFailure"],
            parseHook: { AgentHookEvent.parseClaude($0) }, claimsHookPayload: nil, alsoRunsHooksOf: nil,
            hookExample: AgentGuide.claudeHooks, nothingToResume: ["No conversation found"],
            conversationFiles: "projects/*/*.jsonl", conversationFormat: .claude,
            conversationStart: "\"type\": ?\"user\""),
        AgentProfile(
            id: "codex", title: "Codex", command: "codex", website: "https://github.com/openai/codex",
            symbol: "chevron.left.forwardslash.chevron.right",
            executableNames: ["codex"], pathFragments: ["/@openai/codex/"],
            mentionPrefix: "", lineStyle: .colon, speaksEditorProtocol: false,
            continueCommand: "codex resume --last", resumeCommand: "codex resume {id}",
            resumingFlags: ["--continue", "--resume", "-c"], resumingSubcommands: ["resume"],
            oneShotFlags: ["-p", "--print"], oneShotSubcommands: ["exec"],
            configDirectory: ".codex", configDirectoryVariable: "CODEX_HOME",
            hookInstall: .tomlSection(file: "config.toml"), hookEvents: ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest"],
            parseHook: { AgentHookEvent.parseCodex($0) }, claimsHookPayload: nil, alsoRunsHooksOf: nil,
            hookExample: AgentGuide.codexHooks, nothingToResume: ["No saved session found"],
            conversationFiles: "sessions/*/*/*/*.jsonl", conversationFormat: .codex,
            conversationStart: "\"type\": ?\"session_meta\"|\"role\": ?\"user\""),
        AgentProfile(
            id: "grok", title: "Grok", command: "grok", website: "https://x.ai/cli", symbol: "bolt",
            executableNames: ["grok"], pathFragments: ["/.grok/downloads/grok-", "/.grok/bin/"],
            mentionPrefix: "@", lineStyle: .colon, speaksEditorProtocol: false,
            continueCommand: "grok --continue", resumeCommand: "grok --resume {id}",
            resumingFlags: ["--continue", "--resume", "-c", "-r"], resumingSubcommands: [],
            oneShotFlags: ["-p", "--single", "--prompt-file", "--prompt-json"], oneShotSubcommands: ["agent"],
            configDirectory: ".grok", configDirectoryVariable: "GROK_HOME",
            hookInstall: .ownFile("hooks/tiri.json"),
            hookEvents: ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "StopFailure", "StopCancelled"],
            parseHook: { AgentHookEvent.parseGrok($0) },
            // Only Grok sends this key, and it runs Claude Code's configured hooks too.
            claimsHookPayload: { $0.range(of: Data("\"hookEventName\"".utf8)) != nil },
            alsoRunsHooksOf: "claude", hookExample: AgentGuide.grokHooks,
            // It looks on a server too, so a network failure here must not look like this.
            nothingToResume: ["session get failed: 404"],
            conversationFiles: "sessions/*/*/chat_history.jsonl", conversationFormat: .grok,
            conversationStart: "\"type\": ?\"user\""),
    ]

    /// Whether a resume that just failed said there's nothing to come back to. An agent with no entry
    /// here can't say, so it's never assumed.
    public static func hasNothingToResume(command: String, output: String) -> Bool {
        guard let name = command.split(separator: " ").first.map({ ($0 as NSString).lastPathComponent }),
              let profile = profile(executable: name) else { return false }
        return profile.nothingToResume.contains { output.contains($0) }
    }

    /// Whether the nearest agent above a hook is a one-shot run, like a `codex exec` an agent started
    /// for itself. Those aren't the session in the terminal, and mustn't speak for it. Nearest first.
    public static func isOneShotRun(ancestors: [[String]]) -> Bool {
        for commandLine in ancestors {
            for (index, token) in commandLine.prefix(3).enumerated() {
                let name = (token as NSString).lastPathComponent.lowercased()
                guard let profile = all.first(where: { $0.executableNames.contains(name) || $0.pathFragments.contains(where: token.lowercased().contains) }) else { continue }
                let rest = commandLine.dropFirst(index + 1)
                return rest.contains(where: profile.oneShotFlags.contains) || rest.first.map(profile.oneShotSubcommands.contains) == true
            }
        }
        return false
    }

    public static func profile(id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    /// The profile for a program's name, as it's typed.
    public static func profile(executable name: String) -> AgentProfile? {
        all.first { $0.executableNames.contains(name) }
    }

    /// From what's running: the executable and arguments, then the terminal's own command. An
    /// agent started by node appears as node with the agent as its first argument. `custom` are
    /// program names to count as agents besides the known ones.
    public static func identify(commandLine: [String], command: String?, custom: Set<String> = []) -> AgentIdentity? {
        var tokens = Array(commandLine.prefix(3))
        if let command, let first = command.split(separator: " ").first { tokens.append(String(first)) }
        for token in tokens.map({ $0.lowercased() }) {
            let name = (token as NSString).lastPathComponent
            for profile in all where profile.executableNames.contains(name) || profile.pathFragments.contains(where: token.contains) {
                return AgentIdentity(rawValue: profile.id)
            }
            if custom.contains(name) { return .other }
        }
        return nil
    }

    /// Who really sent a hook's payload. One agent can run another's configured hooks, so the
    /// command it came through isn't enough to go on.
    public static func owner(ofHookPayload data: Data, reportedAs stated: AgentIdentity) -> AgentIdentity {
        for profile in all where profile.claimsHookPayload?(data) == true {
            return AgentIdentity(rawValue: profile.id) ?? stated
        }
        return stated
    }

    /// What the New Terminal menu starts with.
    public static var defaultPresets: [TerminalPreset] {
        [TerminalPreset(name: "Shell", command: "")] + all.map { TerminalPreset(name: $0.title, command: $0.command) }
    }

    /// How each agent comes back after a relaunch, unless settings say otherwise.
    public static var defaultResume: [String: String] {
        var map: [String: String] = [:]
        for profile in all {
            if let command = profile.continueCommand, let name = profile.executableNames.sorted().first { map[name] = command }
        }
        return map
    }

    /// Agents Tiri supported before it started keeping track. Anyone with a settings file already
    /// has these, or chose not to.
    public static let alwaysKnown: Set<String> = ["claude", "codex"]

    /// A settings file can list the menu in full, which would hide an agent added since. So each
    /// new agent joins the list once, and after that the list is yours: remove it and it stays gone.
    public static func adopting(into presets: [TerminalPreset], resume: [String: String], known: Set<String>)
        -> (presets: [TerminalPreset], resume: [String: String], known: Set<String>) {
        var presets = presets
        var resume = resume
        for profile in all where !known.contains(profile.id) {
            if !presets.contains(where: { $0.command.split(separator: " ").first.map(String.init) == profile.command }) {
                presets.append(TerminalPreset(name: profile.title, command: profile.command))
            }
            if let command = profile.continueCommand, let name = profile.executableNames.sorted().first, resume[name] == nil {
                resume[name] = command
            }
        }
        return (presets, resume, known.union(all.map(\.id)))
    }
}
