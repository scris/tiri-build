import Foundation

/// Adds Tiri's status hooks to an agent's own config, and takes them out again. Nothing here
/// runs without the user saying yes on screen: these are the agent's files, not Tiri's.
/// Other hooks in those files can matter a great deal to whoever put them there, so everything
/// that isn't Tiri's is kept exactly as it means, and a copy of the file is left beside it.
public enum AgentHooks {
    public typealias Tool = AgentIdentity

    public enum Failure: Error, CustomStringConvertible {
        case notAnObject

        public var description: String { String(localized: "The file isn't a JSON object, so Tiri left it alone.") }
    }

    public static func configURL(for tool: Tool, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let profile = tool.profile, let install = profile.hookInstall else { return home }
        let directory = profile.configDirectoryVariable.flatMap { environment[$0] }.map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(profile.configDirectory)
        switch install {
        case .jsonSettings(let file), .tomlSection(let file), .ownFile(let file):
            return directory.appendingPathComponent(file)
        }
    }

    public static func isInstalled(_ tool: Tool, in text: String) -> Bool {
        switch tool.profile?.hookInstall {
        case .jsonSettings, .ownFile: text.contains("tiri hook \(tool.rawValue)")
        case .tomlSection: text.contains(codexStart)
        case nil: false
        }
    }

    public static func installing(_ tool: Tool, in text: String) throws -> String {
        switch tool.profile?.hookInstall {
        case .jsonSettings: try claudeInstalling(in: text)
        case .tomlSection: codexInstalling(in: text)
        case .ownFile: try ownFile(for: tool)
        case nil: text
        }
    }

    public static func removing(_ tool: Tool, from text: String) throws -> String {
        switch tool.profile?.hookInstall {
        case .jsonSettings: try claudeRemoving(from: text)
        case .tomlSection: codexRemoving(from: text)
        // The whole file is Tiri's. Nothing left means the file goes.
        case .ownFile: ""
        case nil: text
        }
    }

    /// What's going in, in words and in the config's own format, for the question on screen.
    public static func summary(of tool: Tool) -> String {
        switch tool.profile?.hookInstall {
        case .jsonSettings: String(localized: "Adds this to each of \(claudeEvents.joined(separator: ", ")):\n\n\(claudeCommand)\n\nYour other hooks and settings stay.")
        case .tomlSection: codexBlock
        case .ownFile: String(localized: "A file of Tiri's own, which runs this on each of \((tool.profile?.hookEvents ?? []).joined(separator: ", ")):\n\n\(tool.profile?.hookCommand ?? "")\n\nNone of your files change.")
        case nil: ""
        }
    }

    // MARK: A file of Tiri's own

    private static func ownFile(for tool: Tool) throws -> String {
        guard let profile = tool.profile else { return "" }
        var hooks: [String: Any] = [:]
        for event in profile.hookEvents {
            hooks[event] = [["hooks": [["type": "command", "command": profile.hookCommand]]]]
        }
        return try render(["hooks": hooks])
    }

    // MARK: Claude Code

    public static var claudeEvents: [String] { AgentCatalog.profile(id: "claude")?.hookEvents ?? [] }
    /// Quiet and harmless where Tiri isn't installed, because these run in every Claude session.
    public static let claudeCommand = "tiri hook claude 2>/dev/null || true"

    private static func parseClaude(_ text: String) throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw Failure.notAnObject }
        return object
    }

    private static func render(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func claudeInstalling(in text: String) throws -> String {
        var root = try parseClaude(text)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let present = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("tiri hook claude") == true } == true
            }
            if !present {
                entries.append(["hooks": [["type": "command", "async": true, "command": claudeCommand]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try render(root)
    }

    private static func claudeRemoving(from text: String) throws -> String {
        var root = try parseClaude(text)
        guard var hooks = root["hooks"] as? [String: Any] else { return text }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
                let remaining = inner.filter { ($0["command"] as? String)?.contains("tiri hook claude") != true }
                if remaining.count == inner.count { return entry }
                if remaining.isEmpty { return nil }
                var updated = entry
                updated["hooks"] = remaining
                return updated
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try render(root)
    }

    // MARK: Codex

    private static let codexStart = "# Added by Tiri, for agent status. Settings can remove it."
    private static let codexEnd = "# End of Tiri's section."
    private static let codexBlock = """
    \(codexStart)
    [[hooks.SessionStart]]
    [[hooks.SessionStart.hooks]]
    type = "command"
    command = "tiri hook codex 2>/dev/null || true"

    [[hooks.UserPromptSubmit]]
    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "tiri hook codex 2>/dev/null || true"

    [[hooks.PostToolUse]]
    [[hooks.PostToolUse.hooks]]
    type = "command"
    command = "tiri hook codex 2>/dev/null || true"

    [[hooks.PermissionRequest]]
    [[hooks.PermissionRequest.hooks]]
    type = "command"
    command = "tiri hook codex 2>/dev/null || true"
    \(codexEnd)
    """
    private static let codexNotify = "notify = [\"tiri\", \"hook\", \"codex\"] # Added by Tiri"

    private static func codexInstalling(in text: String) -> String {
        guard !isInstalled(.codex, in: text) else { return text }
        var result = text
        // A top-level key has to come before any table. Someone else's notify stays as it is.
        let hasNotify = text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }
        if !hasNotify { result = codexNotify + "\n" + result }
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + "\n" + codexBlock + "\n"
    }

    private static func codexRemoving(from text: String) -> String {
        var result = text
        if let start = result.range(of: codexStart), let end = result.range(of: codexEnd, range: start.upperBound..<result.endIndex) {
            var upper = end.upperBound
            if upper < result.endIndex, result[upper] == "\n" { upper = result.index(after: upper) }
            result.removeSubrange(start.lowerBound..<upper)
        }
        result = result.replacingOccurrences(of: codexNotify + "\n", with: "")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
}
