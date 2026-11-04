import Foundation

/// One agent as this person has it: on or off, under what name, run by what command.
public struct AgentEntry: Sendable, Equatable, Identifiable {
    /// The program's name, which is what the rest of Tiri knows it by.
    public var id: String
    public var name: String
    public var command: String
    public var isEnabled: Bool
    /// Nil for something Tiri has no catalog entry for.
    public var agent: AgentIdentity?

    public var profile: AgentProfile? { agent?.profile }
    /// One of Tiri's own can only be turned off. Your own can go altogether.
    public var isCustom: Bool { agent == nil }
}

/// There is one list of agents: the New Terminal presets, each on or off. The menus, the empty
/// screen, the Ask buttons and the command palette all read it, so there's nothing to keep in step.
public enum AgentRoster {
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// The program a command runs.
    public static func tool(of command: String) -> String? {
        command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent.lowercased() }
    }

    /// Everything in the list, then any agent Tiri knows that isn't, which shows as off.
    public static func entries(_ presets: [TerminalPreset]) -> [AgentEntry] {
        var found: [AgentEntry] = []
        for preset in presets {
            guard let tool = tool(of: preset.command), !found.contains(where: { $0.id == tool }) else { continue }
            found.append(AgentEntry(id: tool, name: preset.name, command: preset.command, isEnabled: preset.isEnabled,
                                    agent: AgentCatalog.profile(executable: tool).flatMap { AgentIdentity(rawValue: $0.id) }))
        }
        for profile in AgentCatalog.all where !found.contains(where: { $0.agent?.rawValue == profile.id }) {
            found.append(AgentEntry(id: profile.command, name: profile.title, command: profile.command, isEnabled: false,
                                    agent: AgentIdentity(rawValue: profile.id)))
        }
        return found
    }

    /// By its program, its name or, for one of Tiri's own, its catalog name, in any case.
    public static func find(_ query: String, in presets: [TerminalPreset]) -> AgentEntry? {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries(presets).first { entry in
            [entry.id, entry.name.lowercased(), entry.agent?.rawValue ?? "", entry.profile?.title.lowercased() ?? ""].contains(wanted)
        }
    }

    private static func index(of entry: AgentEntry, in presets: [TerminalPreset]) -> Int? {
        presets.firstIndex { tool(of: $0.command) == entry.id }
    }

    public static func setEnabled(_ on: Bool, _ query: String, in presets: [TerminalPreset]) throws -> [TerminalPreset] {
        guard let entry = find(query, in: presets) else { throw Problem("No agent called \"\(query)\". Run tiri agents to see them all.") }
        var presets = presets
        if let index = index(of: entry, in: presets) {
            presets[index].isEnabled = on
        } else if on {
            presets.append(TerminalPreset(name: entry.name, command: entry.command))
        }
        return presets
    }

    /// Adding something already there just turns it on, wherever it was.
    public static func add(name: String, command: String, to presets: [TerminalPreset]) throws -> [TerminalPreset] {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard let tool = tool(of: command) else { throw Problem("An agent needs a command to run.") }
        if let existing = entries(presets).first(where: { $0.id == tool }) {
            return try setEnabled(true, existing.id, in: presets)
        }
        let given = name.trimmingCharacters(in: .whitespaces)
        let chosen = given.isEmpty ? (AgentCatalog.profile(executable: tool)?.title ?? tool) : given
        if presets.contains(where: { $0.name.caseInsensitiveCompare(chosen) == .orderedSame }) {
            throw Problem("There's already something called \(chosen).")
        }
        return presets + [TerminalPreset(name: chosen, command: command)]
    }

    /// One of Tiri's own stays in the list, turned off, so turning it back on is one switch.
    public static func remove(_ query: String, from presets: [TerminalPreset]) throws -> [TerminalPreset] {
        guard let entry = find(query, in: presets) else { throw Problem("No agent called \"\(query)\". Run tiri agents to see them all.") }
        if !entry.isCustom { return try setEnabled(false, entry.id, in: presets) }
        return presets.filter { tool(of: $0.command) != entry.id }
    }

    public static func update(_ id: String, name: String, command: String, in presets: [TerminalPreset]) throws -> [TerminalPreset] {
        guard let entry = entries(presets).first(where: { $0.id == id }) else { throw Problem("No agent called \"\(id)\".") }
        let name = name.trimmingCharacters(in: .whitespaces)
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Problem("An agent needs a name.") }
        guard let newTool = tool(of: command) else { throw Problem("An agent needs a command to run.") }
        if newTool != id, entries(presets).contains(where: { $0.id == newTool }) { throw Problem("\(newTool) is already in the list.") }
        if presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && tool(of: $0.command) != id }) {
            throw Problem("There's already something called \(name).")
        }
        var presets = presets
        if let index = index(of: entry, in: presets) {
            presets[index].name = name
            presets[index].command = command
        } else {
            presets.append(TerminalPreset(name: name, command: command, isEnabled: false))
        }
        return presets
    }
}
