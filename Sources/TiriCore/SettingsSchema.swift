import Foundation

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
    public var section: String
    public var title: String
    public var explanation: String
    public var kind: Kind
    public var value: @Sendable (TiriSettings) -> JSONValue
    public var id: String { key }
}

public enum SettingsSchema {
    public static let sections = ["Appearance", "Terminal", "Agents", "Code", "Files", "Notifications"]

    private static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    public static let all: [SettingDefinition] = [
        .init(key: "theme", section: "Appearance", title: "Theme",
              explanation: "Follow your Mac, or always use light or dark.",
              kind: .choice([.init("system", "System"), .init("light", "Light"), .init("dark", "Dark")]),
              value: { .string($0.theme.rawValue) }),
        .init(key: "window.zoomLevel", section: "Appearance", title: "Zoom",
              explanation: "How much bigger text is in terminals and files, in points, on top of their font sizes. Web pages and rendered markdown scale to match. ⌘+ and ⌘- change it, and ⌘0 puts it back.",
              kind: .number(min: Double(TiriSettings.zoomRange.lowerBound), max: Double(TiriSettings.zoomRange.upperBound), step: 1),
              value: { .int($0.zoomLevel) }),
        .init(key: "web.forceDark", section: "Appearance", title: "Darken web pages",
              explanation: "In dark mode, darken web previews that have no dark mode of their own.",
              kind: .toggle, value: { .bool($0.webForceDark) }),
        .init(key: "documents.forceDark", section: "Appearance", title: "Darken documents",
              explanation: "In dark mode, show PDF and Office pages dark too. The moon button above a file shows its true colors.",
              kind: .toggle, value: { .bool($0.documentsForceDark) }),

        .init(key: "terminal.fontFamily", section: "Terminal", title: "Font",
              explanation: "The font terminals use.",
              kind: .font, value: { .string($0.terminalFontFamily) }),
        .init(key: "terminal.fontSize", section: "Terminal", title: "Font size",
              explanation: "The text size in terminals.",
              kind: .number(min: 8, max: 32, step: 1), value: { .double($0.terminalFontSize) }),
        .init(key: "terminal.translucent", section: "Terminal", title: "Translucent background",
              explanation: "Let the window behind show through terminals.",
              kind: .toggle, value: { .bool($0.terminalTranslucent) }),
        .init(key: "terminal.scrollback", section: "Terminal", title: "Scrollback lines",
              explanation: "How many lines of output each terminal keeps.",
              kind: .number(min: 1_000, max: 200_000, step: 1_000), value: { .int($0.terminalScrollback) }),
        .init(key: "terminal.shell", section: "Terminal", title: "Shell",
              explanation: "The program new terminals run. Leave it empty to use your login shell.",
              kind: .text(placeholder: "Your login shell"), value: { .string($0.terminalShell) }),
        .init(key: "terminal.linkOpens", section: "Terminal", title: "⌘-click on a file",
              explanation: "Where a file opens when you ⌘-click its path in a terminal.",
              kind: .choice([.init("peek", "Peek"), .init("tab", "Tab"), .init("external", "External editor")]),
              value: { .string($0.terminalLinkOpens.rawValue) }),

        .init(key: "terminal.presets", section: "Agents", title: "New terminal menu",
              explanation: "What the + button offers. Each entry is a name and the command it runs. Adding `\"enabled\": false` keeps an entry but hides it. `tiri agents` is the easy way to change this.",
              kind: .presets,
              value: { TerminalPreset.json($0.terminalPresets) }),
        .init(key: "changes.perTurn", section: "Agents", title: "Remember what each turn changed",
              explanation: "Take a snapshot when an agent starts and stops, so Changes can show one turn. They stay in Tiri's folder for a week, and nothing changes in your repository.",
              kind: .toggle, value: { .bool($0.perTurnDiffs) }),
        .init(key: "terminal.keepRunning", section: "Agents", title: "Keep terminals running when Tiri quits",
              explanation: "Agents carry on working while Tiri is closed or updating, and Tiri comes back to them. They stop when you close their tab.",
              kind: .toggle, value: { .bool($0.terminalKeepRunning) }),
        .init(key: "terminal.restoreWithResume", section: "Agents", title: "Resume agents after a relaunch",
              explanation: "When Tiri reopens, bring agent terminals back in their conversations.",
              kind: .toggle, value: { .bool($0.terminalRestoreWithResume) }),
        .init(key: "terminal.resume", section: "Agents", title: "Resume commands",
              explanation: "The command that brings each agent back, by tool name.",
              kind: .commandMap, value: { .object($0.terminalResume.mapValues(JSONValue.string)) }),

        .init(key: "code.fontFamily", section: "Code", title: "Font",
              explanation: "The font code and plain text files use.",
              kind: .font, value: { .string($0.codeFontFamily) }),
        .init(key: "code.fontSize", section: "Code", title: "Font size",
              explanation: "The text size in code and plain text files.",
              kind: .number(min: 8, max: 32, step: 1), value: { .double($0.codeFontSize) }),
        .init(key: "code.languageServers", section: "Code", title: "Use language servers",
              explanation: "Run the language servers already on this Mac, for what a name is, where it's defined, and errors. They start when you look at a file for a moment, and stop after 10 minutes unused. Some servers run a project's build scripts, as building it would. Off, Tiri searches the files instead.",
              kind: .toggle, value: { .bool($0.languageServers) }),
        .init(key: "editor.wordWrap", section: "Code", title: "Wrap long lines",
              explanation: "Off scrolls sideways. On wraps at the edge of the pane. Bounded wraps at the column below, or at the edge of the pane if that comes first. ⌥Z switches it for the file in front.",
              kind: .choice([.init("off", "Off"), .init("on", "On"), .init("bounded", "Bounded")]),
              value: { .string($0.editorWordWrap.rawValue) }),
        .init(key: "editor.wordWrapColumn", section: "Code", title: "Wrap column",
              explanation: "Where lines wrap when wrapping is Bounded.",
              kind: .number(min: 20, max: 1_000, step: 10), value: { .int($0.editorWordWrapColumn) }),

        .init(key: "externalEditors", section: "Files", title: "External editors",
              explanation: "\"Open in External Editor\" uses the first of these that's installed.",
              kind: .list(placeholder: "zed, code, cursor"), value: { strings($0.externalEditors) }),
        .init(key: "files.exclude", section: "Files", title: "Hidden files",
              explanation: "Names or patterns hidden from the explorer and quick open.",
              kind: .list(placeholder: ".git, node_modules"), value: { strings($0.filesExclude) }),
        .init(key: "explorer.autoReveal", section: "Files", title: "Follow the open file",
              explanation: "Reveal the file you're looking at in the explorer.",
              kind: .toggle, value: { .bool($0.explorerAutoReveal) }),

        .init(key: "explorer.compactFolders", section: "Files", title: "Compact folders",
              explanation: "Show a folder that only holds another folder on one row with it, like src/main/java.",
              kind: .toggle, value: { .bool($0.explorerCompactFolders) }),

        .init(key: "notifications.enabled", section: "Notifications", title: "Agent notifications",
              explanation: "Notify you when an agent finishes or needs input in a terminal you aren't looking at.",
              kind: .toggle, value: { .bool($0.notificationsEnabled) }),
    ]

    public static func definition(for key: String) -> SettingDefinition? {
        all.first { $0.key == key }
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

    static func format(_ number: Double) -> String {
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
