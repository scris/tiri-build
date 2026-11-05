import Foundation

/// Whether this Mac's own model can be used right now, and what to tell someone if it can't.
public enum MacModelState: String, CaseIterable, Sendable {
    case ready, cantRun, turnedOff, gettingReady, unavailable

    private static let fallback = "titles come from your first prompt, and search finds only the words you type."

    /// Why it can't be used, and what you get instead.
    public var message: String? {
        switch self {
        case .ready: nil
        case .cantRun: "This Mac can't run Apple Intelligence, so \(Self.fallback)"
        case .turnedOff: "Apple Intelligence is off on this Mac. Until you turn it on, \(Self.fallback)"
        case .gettingReady: "Apple Intelligence is still getting ready on this Mac. Tiri starts using it when it's done. Until then, \(Self.fallback)"
        case .unavailable: "Apple Intelligence isn't working on this Mac right now. Until it is, \(Self.fallback)"
        }
    }
}

/// The parts of the settings screen, in the order it lists them.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, agents, terminal, editor, languages, plugins, files, keyboard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .terminal: "Terminal"
        case .editor: "Editor"
        case .languages: "Languages"
        case .plugins: "Plugins"
        case .files: "Files"
        case .keyboard: "Keyboard"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "sparkles"
        case .terminal: "terminal"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .languages: "curlybraces"
        case .plugins: "puzzlepiece.extension"
        case .files: "folder"
        case .keyboard: "keyboard"
        }
    }
}

/// Every setting, described once. The settings screen and `tiri settings` are both built from
/// this list, so a new setting appears in both by adding one entry here.
public struct SettingDefinition: Identifiable, Sendable {
    public struct Option: Sendable, Hashable {
        public var value: String
        public var label: String
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Kind: Sendable {
        case toggle
        case choice([Option])
        case number(min: Double, max: Double, step: Double)
        case font
        case text(placeholder: String)
        case list(placeholder: String)
        case presets
        case commandMap
    }

    public var key: String
    public var pane: SettingsPane
    /// Its heading within the pane. Empty for one that stands above them all.
    public var group: String
    public var title: String
    /// One line, shown under the title.
    public var explanation: String
    /// What's left to say, for whoever asks.
    public var note: String?
    public var kind: Kind
    public var value: @Sendable (TiriSettings) -> JSONValue
    /// The title says it all, so the screen leaves out the explanation. `tiri settings explain` keeps it.
    public var titleIsEnough = false
    /// Whether it makes any difference right now, given the other settings.
    public var applies: (@Sendable (TiriSettings) -> Bool)?
    /// The agents table shows it, on each agent's own row, so it has no row of its own.
    public var shownElsewhere = false

    public var id: String { key }
    public var section: String { pane.title }
    public var fullExplanation: String { [explanation, note].compactMap { $0 }.joined(separator: " ") }
}

public enum SettingsSchema {
    private static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    public static let all: [SettingDefinition] = [
        .init(key: "theme", pane: .general, group: "Appearance", title: "Theme",
              explanation: "Follow your Mac, or always use light or dark.",
              kind: .choice([.init("system", "System"), .init("light", "Light"), .init("dark", "Dark")]),
              value: { .string($0.theme.rawValue) }),
        .init(key: "window.zoomLevel", pane: .general, group: "Appearance", title: "Zoom",
              explanation: "Makes text in terminals and files bigger or smaller, on top of their font sizes.",
              note: "Web pages and rendered markdown scale to match. ⌘+ and ⌘- change it, and ⌘0 puts it back.",
              kind: .number(min: Double(TiriSettings.zoomRange.lowerBound), max: Double(TiriSettings.zoomRange.upperBound), step: 1),
              value: { .int($0.zoomLevel) }),
        .init(key: "web.forceDark", pane: .general, group: "Appearance", title: "Darken web pages",
              explanation: "In dark mode, darken web previews that have no dark mode of their own.",
              kind: .toggle, value: { .bool($0.webForceDark) }),
        .init(key: "documents.forceDark", pane: .general, group: "Appearance", title: "Darken documents",
              explanation: "In dark mode, show PDF and Office pages dark too.",
              note: "The moon button above a file shows its true colors.",
              kind: .toggle, value: { .bool($0.documentsForceDark) }),

        .init(key: "terminal.presets", pane: .agents, group: "", title: "New terminal menu",
              explanation: "What the + button offers. Each entry is a name and the command it runs. Adding `\"enabled\": false` keeps an entry but hides it. `tiri agents` is the easy way to change this.",
              kind: .presets,
              value: { TerminalPreset.json($0.terminalPresets) }, shownElsewhere: true),
        .init(key: "terminal.resume", pane: .agents, group: "", title: "Resume commands",
              explanation: "The command that brings each agent back, by tool name.",
              kind: .commandMap, value: { .object($0.terminalResume.mapValues(JSONValue.string)) }, shownElsewhere: true),
        .init(key: "notifications.enabled", pane: .agents, group: "While They Work", title: "Notifications",
              explanation: "Tell you when an agent finishes or needs input in a terminal you aren't looking at.",
              kind: .toggle, value: { .bool($0.notificationsEnabled) }),
        .init(key: "changes.perTurn", pane: .agents, group: "While They Work", title: "Remember what each turn changed",
              explanation: "Lets Changes show what one agent turn did, rather than everything since the last commit.",
              note: "Takes a snapshot when an agent starts and stops. They stay in Tiri's folder for a week, and nothing changes in your repository.",
              kind: .toggle, value: { .bool($0.perTurnDiffs) }),
        .init(key: "terminal.keepRunning", pane: .agents, group: "When Tiri Quits", title: "Keep terminals running",
              explanation: "Agents carry on while Tiri is closed or updating, and Tiri comes back to them.",
              note: "They stop when you close their tab.",
              kind: .toggle, value: { .bool($0.terminalKeepRunning) }),
        .init(key: "terminal.restoreWithResume", pane: .agents, group: "When Tiri Quits", title: "Resume agents after a relaunch",
              explanation: "When Tiri reopens, bring agent terminals back in their conversations.",
              kind: .toggle, value: { .bool($0.terminalRestoreWithResume) }),
        .init(key: "conversations.useMacModel", pane: .agents, group: "Past Conversations", title: "Titles and search with Apple Intelligence",
              explanation: "Gives each conversation a short title, and lets search try related words. Nothing leaves this Mac.",
              note: "Off, or without Apple Intelligence, titles come from your first prompt and search finds only the words you type.",
              kind: .toggle, value: { .bool($0.conversationsUseMacModel) }),
        .init(key: "conversations.summarizeAll", pane: .agents, group: "Past Conversations", title: "Title every conversation in advance",
              explanation: "Otherwise each one gets its title when it first comes into view. Runs only while plugged in.",
              note: "It takes a second or two each, so a long history can take most of an hour. It picks up where it left off.",
              kind: .toggle, value: { .bool($0.conversationsSummarizeAll) },
              applies: { $0.conversationsUseMacModel }),

        .init(key: "terminal.fontFamily", pane: .terminal, group: "Appearance", title: "Font",
              explanation: "The font terminals use.",
              kind: .font, value: { .string($0.terminalFontFamily) }, titleIsEnough: true),
        .init(key: "terminal.fontSize", pane: .terminal, group: "Appearance", title: "Font size",
              explanation: "The text size in terminals.",
              kind: .number(min: 8, max: 32, step: 1), value: { .double($0.terminalFontSize) }, titleIsEnough: true),
        .init(key: "terminal.translucent", pane: .terminal, group: "Appearance", title: "Translucent background",
              explanation: "Let what's behind the window show through, blurred. Text stays solid.",
              kind: .toggle, value: { .bool($0.terminalTranslucent) }),
        .init(key: "terminal.shell", pane: .terminal, group: "Behavior", title: "Shell",
              explanation: "The program new terminals run. Leave it empty to use your login shell.",
              kind: .text(placeholder: "Your login shell"), value: { .string($0.terminalShell) }),
        .init(key: "terminal.scrollback", pane: .terminal, group: "Behavior", title: "Scrollback lines",
              explanation: "How many lines of output each terminal keeps.",
              kind: .number(min: 1_000, max: 200_000, step: 1_000), value: { .int($0.terminalScrollback) }),
        .init(key: "terminal.linkOpens", pane: .terminal, group: "Behavior", title: "⌘-click on a file",
              explanation: "Where a file opens when you ⌘-click its path.",
              kind: .choice([.init("peek", "Peek"), .init("tab", "Tab"), .init("external", "External editor")]),
              value: { .string($0.terminalLinkOpens.rawValue) }),

        .init(key: "code.fontFamily", pane: .editor, group: "Appearance", title: "Font",
              explanation: "The font code and plain text files use.",
              kind: .font, value: { .string($0.codeFontFamily) }, titleIsEnough: true),
        .init(key: "code.fontSize", pane: .editor, group: "Appearance", title: "Font size",
              explanation: "The text size in code and plain text files.",
              kind: .number(min: 8, max: 32, step: 1), value: { .double($0.codeFontSize) }, titleIsEnough: true),
        .init(key: "editor.wordWrap", pane: .editor, group: "Editing", title: "Wrap long lines",
              explanation: "Off scrolls sideways. On wraps at the pane's edge. Bounded wraps at the column below.",
              note: "⌥Z switches it for the file in front. Bounded still wraps at the pane's edge if that comes first.",
              kind: .choice([.init("off", "Off"), .init("on", "On"), .init("bounded", "Bounded")]),
              value: { .string($0.editorWordWrap.rawValue) }),
        .init(key: "editor.wordWrapColumn", pane: .editor, group: "Editing", title: "Wrap column",
              explanation: "Where lines wrap when wrapping is Bounded.",
              kind: .number(min: 20, max: 1_000, step: 10), value: { .int($0.editorWordWrapColumn) },
              applies: { $0.editorWordWrap == .bounded }),
        .init(key: "editor.completion", pane: .editor, group: "Editing", title: "Suggest as you type",
              explanation: "Offer names from the language server, or words from your open files.",
              note: "⌃Space asks either way.",
              kind: .toggle, value: { .bool($0.editorCompletion) }),
        .init(key: "diff.sideBySide", pane: .editor, group: "Diffs", title: "Show diffs side by side",
              explanation: "Old on the left and new on the right, rather than in one column.",
              note: "In a narrow pane they stay in one column.",
              kind: .toggle, value: { .bool($0.diffSideBySide) }),

        .init(key: "code.languageServers", pane: .languages, group: "", title: "Use language servers",
              explanation: "They power Go to Definition, errors and suggestions. Off, Tiri searches the files instead.",
              note: "They start when you look at a file for a moment, and stop after 10 minutes unused. Some servers run a project's build scripts, as building it would.",
              kind: .toggle, value: { .bool($0.languageServers) }),

        .init(key: "explorer.autoReveal", pane: .files, group: "Explorer", title: "Follow the open file",
              explanation: "Reveal the file you're looking at in the explorer.",
              kind: .toggle, value: { .bool($0.explorerAutoReveal) }),
        .init(key: "explorer.compactFolders", pane: .files, group: "Explorer", title: "Compact folders",
              explanation: "Show a folder that only holds another folder on one row with it, like src/main/java.",
              kind: .toggle, value: { .bool($0.explorerCompactFolders) }),
        .init(key: "files.exclude", pane: .files, group: "Explorer", title: "Hidden files",
              explanation: "Names or patterns hidden from the explorer and quick open.",
              kind: .list(placeholder: "Add a name or pattern"), value: { strings($0.filesExclude) }),
        .init(key: "externalEditors", pane: .files, group: "Opening Files", title: "External editors",
              explanation: "\"Open in External Editor\" uses the first of these that's installed.",
              kind: .list(placeholder: "Add a command"), value: { strings($0.externalEditors) }),
    ]

    /// The rows of a pane under their headings, in the order they're listed above.
    public static func groups(in pane: SettingsPane, from definitions: [SettingDefinition] = all) -> [(name: String, settings: [SettingDefinition])] {
        var result: [(name: String, settings: [SettingDefinition])] = []
        for definition in definitions where definition.pane == pane && !definition.shownElsewhere {
            if let index = result.firstIndex(where: { $0.name == definition.group }) {
                result[index].settings.append(definition)
            } else {
                result.append((definition.group, [definition]))
            }
        }
        return result
    }

    /// Every word has to appear somewhere, so "terminal font" finds the terminal's font.
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            fields.contains { $0.localizedCaseInsensitiveContains(word) }
        }
    }

    public static func matches(_ query: String, _ definition: SettingDefinition) -> Bool {
        matches(query, in: [definition.title, definition.fullExplanation, definition.group, definition.pane.title, definition.key])
    }

    /// What someone means by `tiri settings open <what>`.
    public enum OpenTarget: Equatable, Sendable {
        case pane(SettingsPane)
        case setting(String)
        case search(String)
    }

    public static func openTarget(_ text: String) -> OpenTarget {
        if let key = definition(for: text)?.key { return .setting(key) }
        if let pane = SettingsPane.allCases.first(where: { $0.rawValue == text.lowercased() || $0.title.lowercased() == text.lowercased() }) { return .pane(pane) }
        return .search(text)
    }

    public static func definition(for key: String) -> SettingDefinition? {
        if key.hasPrefix("plugin.") { return fromPlugins.first { $0.key == key } }
        return all.first { $0.key == key }
    }

    public struct InvalidValue: Error, CustomStringConvertible {
        public var description: String
    }

    /// Turns what someone typed at `tiri settings set` into the setting's value.
    public static func value(from raw: String, for key: String) throws -> JSONValue {
        guard let definition = definition(for: key) else {
            throw InvalidValue(description: "No setting called \"\(key)\". Run tiri settings to see them all.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch definition.kind {
        case .toggle:
            switch trimmed.lowercased() {
            case "true", "on", "yes": return .bool(true)
            case "false", "off", "no": return .bool(false)
            default: throw InvalidValue(description: "\(key) is on or off")
            }
        case .choice(let options):
            guard options.contains(where: { $0.value == trimmed }) else {
                throw InvalidValue(description: "\(key) is one of: \(options.map(\.value).joined(separator: ", "))")
            }
            return .string(trimmed)
        case .number(let minimum, let maximum, _):
            guard let number = Double(trimmed), number >= minimum, number <= maximum else {
                throw InvalidValue(description: "\(key) is a number from \(format(minimum)) to \(format(maximum))")
            }
            return number == number.rounded() ? .int(Int(number)) : .double(number)
        case .font, .text:
            return .string(trimmed)
        case .list:
            if trimmed.hasPrefix("["), let decoded = decode(trimmed), case .array = decoded { return decoded }
            return .array(trimmed.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        case .presets:
            guard let decoded = decode(trimmed), let entries = decoded.arrayValue,
                  entries.allSatisfy({ $0["name"]?.stringValue != nil && $0["command"]?.stringValue != nil }) else {
                throw InvalidValue(description: "\(key) is a JSON list like [{\"name\":\"Shell\",\"command\":\"\"}]")
            }
            return decoded
        case .commandMap:
            guard let decoded = decode(trimmed), case .object(let entries) = decoded,
                  entries.values.allSatisfy({ $0.stringValue != nil }) else {
                throw InvalidValue(description: "\(key) is a JSON object like {\"claude\":\"claude --continue\"}")
            }
            return decoded
        }
    }

    private static func decode(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    public static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    /// A value as one short line.
    public static func display(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let on): return on ? "on" : "off"
        case .int(let number): return String(number)
        case .double(let number): return format(number)
        case .string(let text): return text.isEmpty ? "(empty)" : text
        case .array(let values) where values.allSatisfy({ $0.stringValue != nil }):
            return values.compactMap(\.stringValue).joined(separator: ", ")
        default: return json(value)
        }
    }

    public static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func allowedValues(_ kind: SettingDefinition.Kind) -> String {
        switch kind {
        case .toggle: "on or off"
        case .choice(let options): options.map(\.value).joined(separator: ", ")
        case .number(let minimum, let maximum, _): "a number from \(format(minimum)) to \(format(maximum))"
        case .font: "a font name"
        case .text: "text"
        case .list: "a comma-separated list"
        case .presets: "a JSON list of {\"name\",\"command\"}"
        case .commandMap: "a JSON object of tool name to command"
        }
    }

    /// What Tiri hands you to paste into any agent. It's all the agent needs to know.
    public static let agentPrompt = """
    Help me with my Tiri settings and keyboard shortcuts using the tiri CLI. Run `tiri settings explain` to see every \
    setting, its current value and what it does, and `tiri keys` to see every command and its shortcut. Tell me in plain \
    words what's worth changing for how I work. When I ask for a change, make it with `tiri settings set <key> <value>` \
    or `tiri keys set <command> <key>`. Turn agents on and off with `tiri agents`. Don't edit any settings file.
    """

    public static func agentPrompt(about definition: SettingDefinition) -> String {
        "Explain the Tiri setting \"\(definition.title)\" (\(definition.key)). Run `tiri settings explain \(definition.key)` to see "
            + "its current value and options, and change it with `tiri settings set \(definition.key) <value>` if I ask. Don't edit any settings file."
    }
}
