import Foundation

/// One command as the Keyboard settings list it.
public struct ShortcutCommand: Identifiable, Hashable, Sendable {
    public var id: String
    /// As the screen shows it.
    public var title: String
    /// The heading it's under, in English, which is also how the list finds that heading.
    public var group: String
    /// The title in English, as agents and `tiri keys` know it. A search matches it too.
    public var englishTitle: String
    /// The heading as the screen shows it.
    public var shownGroup: String
    public init(id: String, title: String, group: String, englishTitle: String? = nil, shownGroup: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.englishTitle = englishTitle ?? title
        self.shownGroup = shownGroup ?? group
    }
}

public enum ShortcutFilter: String, CaseIterable, Identifiable, Sendable {
    case all, assigned, changed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: String(localized: "All")
        case .assigned: String(localized: "With Shortcuts")
        case .changed: String(localized: "Changed")
        }
    }
}

public enum ShortcutRow: Identifiable, Hashable, Sendable {
    case command(ShortcutCommand)
    /// Numbered commands that are one idea, shown as one row until someone opens it.
    case family(id: String, title: String, members: [ShortcutCommand])

    public var id: String {
        switch self {
        case .command(let command): command.id
        case .family(let id, _, _): "family:" + id
        }
    }
}

public struct ShortcutSection: Identifiable, Hashable, Sendable {
    /// In English: jumps and the list beside the page find a heading by it.
    public var name: String
    public var shownName: String
    public var rows: [ShortcutRow]
    public var id: String { name }

    /// Each command once, whether or not it's folded away.
    public var commands: [ShortcutCommand] {
        rows.flatMap { row -> [ShortcutCommand] in
            switch row {
            case .command(let command): [command]
            case .family(_, _, let members): members
            }
        }
    }
}

public enum ShortcutIndex {
    static let families = [("focusGroup", String(localized: "Focus Group 1 to 9")), ("switchWorkspace", String(localized: "Switch to Workspace 1 to 9"))]

    /// The commands to list, under their groups in the order they first appear.
    /// A query or a key looks at every command, whatever the filter says.
    public static func sections(commands: [ShortcutCommand], bindings: [Keybinding], changed: Set<String>,
                                filter: ShortcutFilter = .all, query: String = "", keys: [KeyStroke] = []) -> [ShortcutSection] {
        let boundKeys = Dictionary(grouping: bindings, by: \.command)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let searching = !trimmed.isEmpty || !keys.isEmpty
        let typedKeys = strokes(typed: trimmed)

        let kept = commands.filter { command in
            let bound = boundKeys[command.id] ?? []
            if !keys.isEmpty { return bound.contains { $0.strokes.starts(with: keys) } }
            if !trimmed.isEmpty {
                if let typedKeys, bound.contains(where: { $0.strokes.starts(with: typedKeys) }) { return true }
                let symbols = bound.map(\.symbol)
                return SettingsSchema.matches(trimmed, in: [command.title, command.shownGroup, command.englishTitle, command.group, command.id] + symbols)
            }
            switch filter {
            case .all: return true
            case .assigned: return !bound.isEmpty
            case .changed: return changed.contains(command.id)
            }
        }

        var sections: [ShortcutSection] = []
        for command in kept {
            if let index = sections.firstIndex(where: { $0.name == command.group }) {
                sections[index].rows.append(.command(command))
            } else {
                sections.append(ShortcutSection(name: command.group, shownName: command.shownGroup, rows: [.command(command)]))
            }
        }
        // What you've searched for or changed is worth seeing by itself, not inside a fold.
        guard !searching, filter != .changed else { return sections }
        return sections.map { section in
            var section = section
            for (prefix, title) in families {
                let members = section.rows.compactMap { row -> ShortcutCommand? in
                    guard case .command(let command) = row, isFamily(command.id, prefix: prefix) else { return nil }
                    return command
                }
                guard members.count > 1, let first = section.rows.firstIndex(where: { row in
                    if case .command(let command) = row { return command == members[0] }
                    return false
                }) else { continue }
                section.rows.removeAll { row in
                    if case .command(let command) = row { return members.contains(command) }
                    return false
                }
                section.rows.insert(.family(id: prefix, title: title, members: members), at: min(first, section.rows.count))
            }
            return section
        }
    }

    private static func isFamily(_ id: String, prefix: String) -> Bool {
        id.hasPrefix(prefix) && id.count == prefix.count + 1 && id.last?.isNumber == true
    }

    /// "cmd+p" typed into the search means the key. A plain word never does.
    static func strokes(typed text: String) -> [KeyStroke]? {
        guard let strokes = Keymap.parseStrokes(text), strokes.allSatisfy({ !$0.modifiers.isEmpty }) else { return nil }
        return strokes
    }

    /// The people who'd lose out if this key went to this command.
    public static func holders(of key: String, except command: String, in bindings: [Keybinding]) -> [String] {
        guard let strokes = Keymap.parseStrokes(key) else { return [] }
        return bindings.filter { $0.strokes == strokes && $0.command != command }.map(\.command)
    }

    /// Commands the user has changed in any way, from their list of changes.
    public static func changedCommands(user: [(key: String, command: String)]) -> Set<String> {
        Set(user.map { $0.command.hasPrefix("-") ? String($0.command.dropFirst()) : $0.command })
    }
}
