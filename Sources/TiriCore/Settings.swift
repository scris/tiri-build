import Foundation

public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// What cmd-clicking a file in a terminal does.
public enum LinkOpenTarget: String, Codable, Sendable {
    case peek, tab, external
}

public struct TerminalPreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var command: String
    /// Off keeps it in the list, and out of everything that offers agents.
    public var isEnabled: Bool
    public var id: String { name }
    public init(name: String, command: String, isEnabled: Bool = true) {
        self.name = name
        self.command = command
        self.isEnabled = isEnabled
    }

    /// As settings store it. Being on is the usual case, and isn't written down.
    public static func json(_ presets: [TerminalPreset]) -> JSONValue {
        .array(presets.map { preset in
            var object: [String: JSONValue] = ["name": .string(preset.name), "command": .string(preset.command)]
            if !preset.isEnabled { object["enabled"] = false }
            return .object(object)
        })
    }
}

/// How long lines show in a file.
public enum WordWrap: String, Codable, Sendable, CaseIterable {
    /// Scroll sideways.
    case off
    /// At the edge of the pane.
    case on
    /// At a column, or the pane's edge if that comes first.
    case bounded
}

/// Settings use the flat dotted keys Cursor users already know. Unknown keys are ignored
/// so a newer settings file can't break an older app.
public struct TiriSettings: Equatable, Sendable {
    public var theme: ThemeMode = .system
    public var terminalFontFamily = "SF Mono"
    public var terminalFontSize = 13.0
    public var terminalTranslucent = false
    public var terminalScrollback = 10_000
    public var terminalShell = ""
    public var terminalPresets = AgentCatalog.defaultPresets
    public var terminalResume = AgentCatalog.defaultResume
    /// What Tiri offers: everything else that asks about agents goes through this.
    public var activePresets: [TerminalPreset] { terminalPresets.filter(\.isEnabled) }
    public var terminalRestoreWithResume = true
    public var terminalKeepRunning = true
    public var perTurnDiffs = true
    public var languageServers = true
    public var terminalLinkOpens = LinkOpenTarget.peek
    public var codeFontFamily = "SF Mono"
    public var codeFontSize = 12.0
    public var editorWordWrap = WordWrap.off
    public var editorWordWrapColumn = 120
    /// Steps of ⌘+ and ⌘-. Each is one point of text, in terminals and in files.
    public var zoomLevel = 0
    public var terminalFontSizeZoomed: Double { Self.zoomed(terminalFontSize, level: zoomLevel) }
    public var codeFontSizeZoomed: Double { Self.zoomed(codeFontSize, level: zoomLevel) }
    public static let zoomRange = -6...16
    private static func zoomed(_ size: Double, level: Int) -> Double { min(max(size + Double(level), 6), 72) }
    public var externalEditors = ["zed", "code", "cursor"]
    public var filesExclude = [".git", "node_modules", ".build", ".DS_Store"]
    public var explorerAutoReveal = true
    public var explorerCompactFolders = true
    public var webForceDark = true
    public var documentsForceDark = true
    public var notificationsEnabled = true

    public init() {}

    public static let defaultFileContents = """
    {
      // Tiri settings. Saved changes apply immediately.
      // "system", "light" or "dark"
      "theme": "system",

      "terminal.fontFamily": "SF Mono",
      "terminal.fontSize": 13,
      "terminal.translucent": false,
      "terminal.scrollback": 10000,
      // Empty means your login shell ($SHELL).
      "terminal.shell": "",
      "terminal.presets": [
        { "name": "Shell", "command": "" },
        { "name": "Claude Code", "command": "claude" },
        { "name": "Codex", "command": "codex" },
        { "name": "Grok", "command": "grok" }
      ],
      // How agent terminals come back after a relaunch. Keyed by tool name.
      "terminal.resume": {
        "claude": "claude --continue",
        "codex": "codex resume --last",
        "grok": "grok --continue"
      },
      "terminal.restoreWithResume": true,
      // Terminals keep running when Tiri quits, and it comes back to them.
      "terminal.keepRunning": true,
      "changes.perTurn": true,
      "code.languageServers": true,
      // What cmd-clicking a file in a terminal does: "peek", "tab" or "external".
      "terminal.linkOpens": "peek",

      "code.fontFamily": "SF Mono",
      "code.fontSize": 12,
      // "off", "on" (at the pane's edge) or "bounded" (at editor.wordWrapColumn).
      "editor.wordWrap": "off",
      "editor.wordWrapColumn": 120,

      // Steps of ⌘+ and ⌘-.
      "window.zoomLevel": 0,

      // "Open in External Editor" uses the first of these that is installed.
      "externalEditors": ["zed", "code", "cursor"],

      // Names or globs hidden from the tree and quick open.
      "files.exclude": [".git", "node_modules", ".build", ".DS_Store"],
      "explorer.autoReveal": true,
      // One row for folders that only hold another folder, as in src/main/java.
      "explorer.compactFolders": true,

      // In dark mode, darken web previews that have no dark mode of their own.
      "web.forceDark": true,
      // In dark mode, show PDF and Office pages dark too. The moon button shows true colors.
      "documents.forceDark": true,

      "notifications.enabled": true
    }

    """

    public enum ParseError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        case wrongType(key: String, expected: String)

        public var description: String {
            switch self {
            case .invalidJSON(let why): "Invalid JSON: \(why)"
            case .notAnObject: "The top level must be an object"
            case .wrongType(let key, let expected): "\"\(key)\" must be \(expected)"
            }
        }
    }

    /// Parse the settings file. Any error leaves the caller holding the last good settings.
    public static func parse(_ text: String) throws -> TiriSettings {
        let stripped = JSONC.strip(text)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return TiriSettings() }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(stripped.utf8))
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ParseError.invalidJSON(message)
        }
        guard let object = root as? [String: Any] else { throw ParseError.notAnObject }

        func string(_ key: String, _ apply: (String) -> Void) throws {
            guard let value = object[key] else { return }
            guard let text = value as? String else { throw ParseError.wrongType(key: key, expected: "a string") }
            apply(text)
        }
        func number(_ key: String, _ apply: (Double) -> Void) throws {
            guard let value = object[key] else { return }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ParseError.wrongType(key: key, expected: "a number")
            }
            apply(number.doubleValue)
        }
        func bool(_ key: String, _ apply: (Bool) -> Void) throws {
            guard let value = object[key] else { return }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ParseError.wrongType(key: key, expected: "true or false")
            }
            apply(number.boolValue)
        }
        func strings(_ key: String, _ apply: ([String]) -> Void) throws {
            guard let value = object[key] else { return }
            guard let list = value as? [String] else { throw ParseError.wrongType(key: key, expected: "a list of strings") }
            apply(list)
        }

        var settings = TiriSettings()
        try string("theme") { _ in }
        if let raw = object["theme"] as? String {
            guard let theme = ThemeMode(rawValue: raw) else {
                throw ParseError.wrongType(key: "theme", expected: "\"system\", \"light\" or \"dark\"")
            }
            settings.theme = theme
        }
        try string("terminal.fontFamily") { settings.terminalFontFamily = $0 }
        try number("terminal.fontSize") { settings.terminalFontSize = min(max($0, 6), 72) }
        try bool("terminal.translucent") { settings.terminalTranslucent = $0 }
        try number("terminal.scrollback") { settings.terminalScrollback = max(Int($0), 0) }
        try string("terminal.shell") { settings.terminalShell = $0 }
        if let value = object["terminal.presets"] {
            guard let list = value as? [[String: Any]] else {
                throw ParseError.wrongType(key: "terminal.presets", expected: "a list of { name, command }")
            }
            settings.terminalPresets = try list.map { entry in
                guard let name = entry["name"] as? String else {
                    throw ParseError.wrongType(key: "terminal.presets", expected: "a list of { name, command }")
                }
                return TerminalPreset(name: name, command: entry["command"] as? String ?? "", isEnabled: entry["enabled"] as? Bool ?? true)
            }
        }
        if let value = object["terminal.resume"] {
            guard let map = value as? [String: String] else {
                throw ParseError.wrongType(key: "terminal.resume", expected: "an object of tool → command")
            }
            settings.terminalResume = map
        }
        try bool("terminal.restoreWithResume") { settings.terminalRestoreWithResume = $0 }
        if let raw = object["terminal.linkOpens"] {
            guard let text = raw as? String, let target = LinkOpenTarget(rawValue: text) else {
                throw ParseError.wrongType(key: "terminal.linkOpens", expected: "\"peek\", \"tab\" or \"external\"")
            }
            settings.terminalLinkOpens = target
        }
        try string("code.fontFamily") { settings.codeFontFamily = $0 }
        try number("code.fontSize") { settings.codeFontSize = min(max($0, 6), 72) }
        // The older on-or-off setting still counts, until the new one is set.
        try bool("code.wordWrap") { settings.editorWordWrap = $0 ? .on : .off }
        if let raw = object["editor.wordWrap"] {
            guard let text = raw as? String, let wrap = WordWrap(rawValue: text) else {
                throw ParseError.wrongType(key: "editor.wordWrap", expected: "\"off\", \"on\" or \"bounded\"")
            }
            settings.editorWordWrap = wrap
        }
        try number("editor.wordWrapColumn") { settings.editorWordWrapColumn = min(max(Int($0), 20), 1_000) }
        try number("window.zoomLevel") { settings.zoomLevel = min(max(Int($0), Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }
        try strings("externalEditors") { settings.externalEditors = $0 }
        try strings("files.exclude") { settings.filesExclude = $0 }
        try bool("explorer.autoReveal") { settings.explorerAutoReveal = $0 }
        try bool("explorer.compactFolders") { settings.explorerCompactFolders = $0 }
        try bool("web.forceDark") { settings.webForceDark = $0 }
        try bool("documents.forceDark") { settings.documentsForceDark = $0 }
        try bool("terminal.keepRunning") { settings.terminalKeepRunning = $0 }
        try bool("changes.perTurn") { settings.perTurnDiffs = $0 }
        try bool("code.languageServers") { settings.languageServers = $0 }
        try bool("notifications.enabled") { settings.notificationsEnabled = $0 }
        return settings
    }
}

public enum SettingsFile {
    /// Change one key in place, keeping any comments and formatting around it.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        setting(key, toJSON: SettingsSchema.json(.string(value)), in: text)
    }

    public static func setting(_ key: String, toJSON encoded: String, in text: String) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        if let regex = try? NSRegularExpression(pattern: "\"\(escapedKey)\"\\s*:\\s*"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(match.range, in: text),
           let end = endOfValue(in: text, from: whole.upperBound) {
            return text.replacingCharacters(in: whole.upperBound..<end, with: encoded)
        }
        if let brace = text.firstIndex(of: "{") {
            let after = text.index(after: brace)
            let rest = text[after...].trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = rest.hasPrefix("}") ? "" : ","
            return text[..<after] + "\n  \"\(key)\": \(encoded)\(separator)" + text[after...]
        }
        return "{\n  \"\(key)\": \(encoded)\n}\n"
    }

    /// Where the JSON value starting here ends: a string, a nested list or object, or a bare word.
    private static func endOfValue(in text: String, from start: String.Index) -> String.Index? {
        guard start < text.endIndex else { return nil }
        var index = start
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    inString = false
                    if depth == 0 { return next }
                }
            } else {
                switch character {
                case "\"": inString = true
                case "[", "{": depth += 1
                case "]", "}":
                    if depth == 0 { return index }
                    depth -= 1
                    if depth == 0 { return next }
                case ",", "\n", " ", "\t":
                    if depth == 0 { return index }
                default: break
                }
            }
            index = next
        }
        return depth == 0 && !inString ? text.endIndex : nil
    }
}

// MARK: - Keybindings

public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public var modifiers: Modifiers
    /// Lowercase base character, or a name: tab, enter, escape, backspace, delete, space, up, f1…
    public var key: String

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    /// `cmd+shift+p`. Also accepts ctrl, alt/opt/option, shift, and the macOS glyphs' word forms.
    public init?(parsing text: String) {
        var modifiers: Modifiers = []
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // `cmd++` means the plus key.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts = Array(parts.dropLast(2)) + ["+"]
        }
        guard let key = parts.last, !key.isEmpty else { return nil }
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta", "super": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        self.init(modifiers: modifiers, key: key)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// `⌃⇧⌘P`
    public var symbol: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        let names = ["tab": "⇥", "enter": "↩", "escape": "⎋", "backspace": "⌫", "delete": "⌦",
                     "space": "Space", "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return out + (names[key] ?? key.uppercased())
    }
}

public struct Keybinding: Equatable, Sendable {
    public var strokes: [KeyStroke]
    public var command: String
    public init(strokes: [KeyStroke], command: String) {
        self.strokes = strokes
        self.command = command
    }
    public var symbol: String { strokes.map(\.symbol).joined(separator: " ") }
}

public enum Keymap {
    /// The §6 table. Command ids are what `keybindings.json` and `tiri run` refer to.
    public static let defaults: [(String, String)] = {
        var table: [(String, String)] = [
            ("cmd+p", "quickOpen"),
            ("cmd+shift+p", "commandPalette"),
            ("cmd+b", "toggleSidebar"),
            ("cmd+shift+e", "focusExplorer"),
            ("ctrl+`", "newTerminal"),
            ("cmd+\\", "splitRight"),
            ("cmd+k cmd+\\", "splitDown"),
            ("cmd+w", "closeItem"),
            ("cmd+shift+t", "reopenClosed"),
            ("ctrl+tab", "nextTab"),
            ("ctrl+shift+tab", "previousTab"),
            ("cmd+shift+]", "nextTab"),
            ("cmd+shift+[", "previousTab"),
            ("cmd+f", "find"),
            ("cmd+alt+f", "findReplace"),
            ("cmd+s", "saveFile"),
            ("cmd+l", "addToAgent"),
            ("cmd+shift+l", "attachToAgent"),
            ("cmd+alt+l", "addReviewComment"),
            ("f12", "goToDefinition"),
            ("cmd+k cmd+i", "showHover"),
            ("shift+f12", "findReferences"),
            ("ctrl+-", "goBack"),
            ("cmd+alt+shift+l", "sendReview"),
            ("cmd+shift+f", "searchInFiles"),
            ("cmd+r", "webReload"),
            ("cmd+,", "openSettings"),
            // A Peek keeps ⌘↩ when it's there. Otherwise, in a file, it's a new line.
            ("cmd+enter", "promotePeek"),
            ("cmd+enter", "insertLineBelow"),
            ("cmd+shift+enter", "insertLineAbove"),
            ("cmd+/", "toggleLineComment"),
            ("cmd+]", "indentLines"),
            ("cmd+[", "outdentLines"),
            ("alt+up", "moveLinesUp"),
            ("alt+down", "moveLinesDown"),
            ("shift+alt+up", "copyLinesUp"),
            ("shift+alt+down", "copyLinesDown"),
            ("cmd+shift+k", "deleteLine"),
            ("cmd+d", "addNextOccurrence"),
            ("ctrl+g", "goToLine"),
            ("alt+z", "toggleWordWrap"),
            ("cmd+shift+o", "symbolsInFile"),
            ("cmd+t", "symbolsInWorkspace"),
            ("cmd+=", "zoomIn"),
            ("cmd+shift+=", "zoomIn"),
            ("cmd+-", "zoomOut"),
            ("cmd+0", "zoomReset"),
            // Waits a moment in case it's the start of a two-press shortcut. See commandsSoFar.
            ("cmd+k", "clearTerminal"),
            ("cmd+left", "terminalLineStart"),
            ("cmd+right", "terminalLineEnd"),
            ("cmd+backspace", "terminalDeleteToLineStart"),
            ("cmd+alt+enter", "promotePeekToSide"),
            ("cmd+shift+u", "nextAttention"),
        ]
        for number in 1...9 {
            table.append(("cmd+\(number)", "focusGroup\(number)"))
            table.append(("ctrl+\(number)", "switchWorkspace\(number)"))
        }
        return table
    }()

    public static let defaultFileContents = """
    // Tiri keybindings, in the same shape as Cursor's keybindings.json.
    // Yours are added on top of the defaults. Prefix a command with "-" to unbind it.
    // Example:
    //   { "key": "cmd+shift+\\\\", "command": "splitDown" },
    //   { "key": "cmd+b", "command": "-toggleSidebar" }
    [
    ]

    """

    public enum ParseError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case badEntry(String)

        public var description: String {
            switch self {
            case .invalidJSON(let why): "Invalid JSON: \(why)"
            case .badEntry(let why): why
            }
        }
    }

    public static func parseStrokes(_ text: String) -> [KeyStroke]? {
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        let strokes = parts.compactMap(KeyStroke.init(parsing:))
        return strokes.count == parts.count ? strokes : nil
    }

    public static func parseUserFile(_ text: String) throws -> [(key: String, command: String)] {
        let stripped = JSONC.strip(text)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(stripped.utf8))
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ParseError.invalidJSON(message)
        }
        guard let list = root as? [[String: Any]] else {
            throw ParseError.badEntry("keybindings.json must be a list of { key, command }")
        }
        return try list.map { entry in
            guard let key = entry["key"] as? String, let command = entry["command"] as? String else {
                throw ParseError.badEntry("Each keybinding needs a \"key\" and a \"command\"")
            }
            guard parseStrokes(key) != nil else {
                throw ParseError.badEntry("Can't read the key \"\(key)\"")
            }
            return (key, command)
        }
    }

    public static func build(user: [(key: String, command: String)]) -> [Keybinding] {
        var bindings = defaults.compactMap { key, command in
            parseStrokes(key).map { Keybinding(strokes: $0, command: command) }
        }
        for (key, command) in user {
            guard let strokes = parseStrokes(key) else { continue }
            if command.hasPrefix("-") {
                let name = String(command.dropFirst())
                bindings.removeAll { $0.command == name && $0.strokes == strokes }
            } else {
                // A user binding takes the key away from whatever had it.
                bindings.removeAll { $0.strokes == strokes }
                bindings.append(Keybinding(strokes: strokes, command: command))
            }
        }
        return bindings
    }
}

extension Keymap {
    /// Why this key can't be used for this command, if there's a reason.
    public static func problem(with key: String, command: String, bindings: [Keybinding]) -> String? {
        guard let strokes = parseStrokes(key) else { return "Can't read the key \"\(key)\". Write it like cmd+shift+p." }
        guard strokes.count <= 2 else { return "A shortcut can be at most two key presses." }
        let first = strokes[0]
        let isFunctionKey = first.key.hasPrefix("f") && first.key.count > 1 && first.key.dropFirst().allSatisfy(\.isNumber)
        if first.modifiers.subtracting(.shift).isEmpty, !isFunctionKey {
            return "A shortcut needs ⌘, ⌃ or ⌥, or typing that key would stop working."
        }
        for binding in bindings where binding.command != command && command != "clearTerminal" {
            // ⌘K can be both: it waits a moment to see whether a second press follows.
            if binding.command == "clearTerminal" { continue }
            if binding.strokes.count > strokes.count, Array(binding.strokes.prefix(strokes.count)) == strokes {
                return "\(strokes.map(\.symbol).joined(separator: " ")) already starts \(binding.symbol) (\(binding.command))."
            }
            if strokes.count > binding.strokes.count, Array(strokes.prefix(binding.strokes.count)) == binding.strokes {
                return "\(binding.symbol) is already \(binding.command), so it can't start a longer shortcut."
            }
        }
        return nil
    }

    /// The user's list with this command on this key, or on no key if it's nil. Its default keys
    /// are switched off, so the command ends up on exactly what was asked for.
    public static func rebound(user: [(key: String, command: String)], command: String, key: String?) -> [(key: String, command: String)] {
        var result = user.filter { $0.command != command && $0.command != "-" + command }
        for (defaultKey, defaultCommand) in defaults where defaultCommand == command {
            result.append((defaultKey, "-" + command))
        }
        if let key {
            let strokes = parseStrokes(key)
            // Whoever had this key loses it, so there's no stale entry left behind.
            result.removeAll { !$0.command.hasPrefix("-") && parseStrokes($0.key) == strokes }
            result.append((key, command))
        }
        return result
    }

    public static func reset(user: [(key: String, command: String)], command: String) -> [(key: String, command: String)] {
        user.filter { $0.command != command && $0.command != "-" + command }
    }

    public static func fileContents(user: [(key: String, command: String)]) -> String {
        let entries = user.map { "  " + SettingsSchema.json(.object(["key": .string($0.key), "command": .string($0.command)])) }
        return "// Tiri saves your keyboard shortcuts here. Change them in Settings or with tiri keys.\n[\n"
            + entries.joined(separator: ",\n") + (entries.isEmpty ? "" : "\n") + "]\n"
    }
}

/// Resolves key presses, including two-stroke chords like ⌘K ⌘\.
public struct KeyResolver: Sendable {
    public enum Outcome: Equatable, Sendable {
        case passThrough
        case pending
        /// `otherwise` is who else wants this key, in order, if the first can't take it right now.
        case command(String, otherwise: [String] = [])
        case cancelledChord
    }

    private var exact: [[KeyStroke]: [String]] = [:]
    private var prefixes: Set<[KeyStroke]> = []
    private var pending: [KeyStroke] = []

    public init(bindings: [Keybinding]) {
        for binding in bindings {
            exact[binding.strokes, default: []].append(binding.command)
            if binding.strokes.count > 1 {
                for length in 1..<binding.strokes.count {
                    prefixes.insert(Array(binding.strokes.prefix(length)))
                }
            }
        }
    }

    public var isPending: Bool { !pending.isEmpty }

    /// While waiting for a second press: what the presses so far would do on their own.
    public var commandsSoFar: [String] { exact[pending] ?? [] }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        let sequence = pending + [stroke]
        if prefixes.contains(sequence) {
            pending = sequence
            return .pending
        }
        if let commands = exact[sequence], let first = commands.first {
            pending = []
            return .command(first, otherwise: Array(commands.dropFirst()))
        }
        if !pending.isEmpty {
            pending = []
            return .cancelledChord
        }
        return .passThrough
    }

    public mutating func reset() { pending = [] }
}
