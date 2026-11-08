import Foundation

public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// What cmd-clicking a file in a terminal does.
public enum LinkOpenTarget: String, Codable, Sendable {
    case peek, tab, external
}

/// How terminals draw. Metal draws on the graphics chip, off the main thread; the CPU is Core Graphics.
public enum TerminalRenderer: String, Codable, Sendable {
    /// Metal, and the CPU wherever Metal can't start.
    case automatic, metal, cpu
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
    /// The language of Tiri's own words. A change shows after a restart.
    public var language = AppLanguage.system
    public var theme: ThemeMode = .system
    /// The themes for each look, by name: built in, or one in the themes folder.
    public var darkTheme = Theme.tiriDark.name
    public var lightTheme = Theme.tiriLight.name
    public var highContrastDarkTheme = Theme.tiriHighContrastDark.name
    public var highContrastLightTheme = Theme.tiriHighContrastLight.name

    public mutating func setThemeName(_ name: String, for slot: ThemeSlot) {
        switch slot {
        case .dark: darkTheme = name
        case .light: lightTheme = name
        case .highContrastDark: highContrastDarkTheme = name
        case .highContrastLight: highContrastLightTheme = name
        }
    }

    public func themeName(for slot: ThemeSlot) -> String {
        switch slot {
        case .dark: darkTheme
        case .light: lightTheme
        case .highContrastDark: highContrastDarkTheme
        case .highContrastLight: highContrastLightTheme
        }
    }
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
    /// Whether anything in the app offers to change Tiri. Off, nothing about it appears anywhere, now or later.
    public var changeEntries = true
    /// Whether Tiri looks for a new version by itself. Off, it never goes online unless you ask.
    public var updatesCheck = true
    public var perTurnDiffs = true
    public var diffSideBySide = false
    public var conversationsUseMacModel = true
    public var conversationsSummarizeAll = false
    public var languageServers = true
    public var terminalLinkOpens = LinkOpenTarget.peek
    public var terminalEditor = true
    public var terminalRenderer = TerminalRenderer.automatic
    public var codeFontFamily = "SF Mono"
    public var codeFontSize = 12.0
    public var editorWordWrap = WordWrap.off
    public var editorWordWrapColumn = 120
    public var editorCompletion = true
    /// ▶ above files Tiri knows how to run. ⌃⌥N runs them either way.
    public var runButton = true
    public var runOpensIn = RunPlacement.below
    /// Changed commands, by language id or `.ext` for an added kind of file. See `RunCommands`.
    public var runCommands: [String: String] = [:]
    /// Languages and `.ext`s that don't run.
    public var runOff: [String] = []
    /// What ▶ Start runs for each folder, by its path. See `StartFolders`.
    public var startCommands: [String: String] = [:]
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
    /// Sites that open in the person's own browser, not in Tiri. See `BrowserRules`.
    public var webOpenInBrowser: [String] = []
    public var documentsForceDark = true
    public var notificationsEnabled = true

    public init() {}

    public static let defaultFileContents = """
    {
      // Tiri settings. Saved changes apply immediately.
      // Tiri's own words: "system", "en", "zh-Hans" or "zh-Hant". Shows after a restart.
      "language": "system",
      // "system", "light" or "dark"
      "theme": "system",
      // Colors for terminals, the editor and highlights, by look. `tiri theme` lists them and brings more in.
      "theme.dark": "System Dark",
      "theme.light": "System Light",
      "theme.highContrastDark": "High Contrast Dark",
      "theme.highContrastLight": "High Contrast Light",

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
      // Show diffs as old and new side by side, rather than in one column.
      "diff.sideBySide": false,
      "conversations.useMacModel": true,
      "conversations.summarizeAll": false,
      "code.languageServers": true,
      // What cmd-clicking a file in a terminal does: "peek", "tab" or "external".
      "terminal.linkOpens": "peek",
      // Programs in terminals that ask for an editor (git commit, Claude Code's Ctrl-G, a dev server's
      // "open in editor") get Tiri, unless your shell sets EDITOR itself.
      "terminal.editor": true,
      // How terminals draw: "automatic" (Metal, or the CPU where Metal can't start), "metal" or "cpu".
      "terminal.renderer": "automatic",

      "code.fontFamily": "SF Mono",
      "code.fontSize": 12,
      // "off", "on" (at the pane's edge) or "bounded" (at editor.wordWrapColumn).
      "editor.wordWrap": "off",
      "editor.wordWrapColumn": 120,
      "editor.completion": true,

      // ▶ above files Tiri can run, like a .py or .cpp. ⌃⌥N runs the file in front either way.
      "run.button": true,
      // Where the Run terminal opens: "below", "right" or "tab".
      "run.opensIn": "below",
      // Your own command for a language, or for a ".ext" Tiri doesn't know. $file is the file, $name it without
      // its extension, $dir its folder and $out a place in /tmp for a compiled program. `tiri settings explain run.commands`.
      "run.commands": {},
      // Languages or ".ext"s that don't run, like "php".
      "run.off": [],
      // What Start runs for a folder, usually its dev server, by the folder's path. `tiri start set` changes it.
      "start.commands": {},

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
      // Sites that open in your own browser instead of in Tiri, like ones you're signed in to there.
      // "github.com" covers all of it, "github.com/acme" one place on it.
      "web.openInBrowser": [],
      // In dark mode, show PDF and Office pages dark too. The moon button shows true colors.
      "documents.forceDark": true,

      "notifications.enabled": true,

      // Look for a newer Tiri every few hours. Off, Tiri never goes online by itself.
      "updates.check": true
    }

    """

    public enum ParseError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        case wrongType(key: String, expected: String)

        public var description: String {
            switch self {
            case .invalidJSON(let why): String(localized: "Invalid JSON: \(why)")
            case .notAnObject: String(localized: "The top level must be an object")
            case .wrongType(let key, let expected): String(localized: "\"\(key)\" must be \(expected)")
            }
        }

        /// The one setting it's about, if it's about one.
        public var key: String? {
            if case .wrongType(let key, _) = self { return key }
            return nil
        }
    }

    /// Parse the settings file. A file that isn't JSON leaves the caller holding the last good settings. A value of the
    /// wrong kind is only that one setting at its default: see `parseReporting`.
    public static func parse(_ text: String) throws -> TiriSettings {
        try parseReporting(text).settings
    }

    /// What was read, and the settings that couldn't be, each left at its default, as VS Code does with one it can't read.
    public static func parseReporting(_ text: String) throws -> (settings: TiriSettings, problems: [ParseError]) {
        let stripped = JSONC.strip(text)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (TiriSettings(), []) }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(stripped.utf8))
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ParseError.invalidJSON(message)
        }
        guard let object = root as? [String: Any] else { throw ParseError.notAnObject }
        var problems: [ParseError] = []
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch let problem as ParseError { problems.append(problem) } catch {}
        }

        func string(_ key: String, _ apply: (String) -> Void) {
            attempt {
                guard let value = object[key] else { return }
                guard let text = value as? String else { throw ParseError.wrongType(key: key, expected: String(localized: "a string")) }
                apply(text)
            }
        }
        func number(_ key: String, _ apply: (Double) -> Void) {
            attempt {
                guard let value = object[key] else { return }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    throw ParseError.wrongType(key: key, expected: String(localized: "a number"))
                }
                apply(number.doubleValue)
            }
        }
        func bool(_ key: String, _ apply: (Bool) -> Void) {
            attempt {
                guard let value = object[key] else { return }
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw ParseError.wrongType(key: key, expected: String(localized: "true or false"))
                }
                apply(number.boolValue)
            }
        }
        func strings(_ key: String, _ apply: ([String]) -> Void) {
            attempt {
                guard let value = object[key] else { return }
                guard let list = value as? [String] else { throw ParseError.wrongType(key: key, expected: String(localized: "a list of strings")) }
                apply(list)
            }
        }

        var settings = TiriSettings()
        attempt {
            if let raw = object["language"] {
                guard let text = raw as? String, let language = AppLanguage(rawValue: text) else {
                    throw ParseError.wrongType(key: "language", expected: AppLanguage.settingValues)
                }
                settings.language = language
            }
        }
        string("theme") { _ in }
        attempt {
            if let raw = object["theme"] as? String {
                guard let theme = ThemeMode(rawValue: raw) else {
                    throw ParseError.wrongType(key: "theme", expected: String(localized: "\"system\", \"light\" or \"dark\""))
                }
                settings.theme = theme
            }
        }
        // Before themes, "colorTheme": "pink" meant Tiri's pink in place of the Mac's accent.
        if object["colorTheme"] as? String == "pink" {
            settings.darkTheme = Theme.tiriPinkDark.name
            settings.lightTheme = Theme.tiriPinkLight.name
        }
        string("theme.dark") { if !$0.isEmpty { settings.darkTheme = $0 } }
        string("theme.light") { if !$0.isEmpty { settings.lightTheme = $0 } }
        string("theme.highContrastDark") { if !$0.isEmpty { settings.highContrastDarkTheme = $0 } }
        string("theme.highContrastLight") { if !$0.isEmpty { settings.highContrastLightTheme = $0 } }
        string("terminal.fontFamily") { settings.terminalFontFamily = $0 }
        number("terminal.fontSize") { settings.terminalFontSize = min(max($0, 6), 72) }
        bool("terminal.translucent") { settings.terminalTranslucent = $0 }
        number("terminal.scrollback") { settings.terminalScrollback = max(Int($0), 0) }
        string("terminal.shell") { settings.terminalShell = $0 }
        attempt {
            if let value = object["terminal.presets"] {
                guard let list = value as? [[String: Any]] else {
                    throw ParseError.wrongType(key: "terminal.presets", expected: String(localized: "a list of { name, command }"))
                }
                settings.terminalPresets = try list.map { entry in
                    guard let name = entry["name"] as? String else {
                        throw ParseError.wrongType(key: "terminal.presets", expected: String(localized: "a list of { name, command }"))
                    }
                    return TerminalPreset(name: name, command: entry["command"] as? String ?? "", isEnabled: entry["enabled"] as? Bool ?? true)
                }
            }
        }
        attempt {
            if let value = object["terminal.resume"] {
                guard let map = value as? [String: String] else {
                    throw ParseError.wrongType(key: "terminal.resume", expected: String(localized: "an object of tool → command"))
                }
                settings.terminalResume = map
            }
        }
        bool("terminal.restoreWithResume") { settings.terminalRestoreWithResume = $0 }
        bool("terminal.editor") { settings.terminalEditor = $0 }
        attempt {
            if let raw = object["terminal.linkOpens"] {
                guard let text = raw as? String, let target = LinkOpenTarget(rawValue: text) else {
                    throw ParseError.wrongType(key: "terminal.linkOpens", expected: String(localized: "\"peek\", \"tab\" or \"external\""))
                }
                settings.terminalLinkOpens = target
            }
        }
        attempt {
            if let raw = object["terminal.renderer"] {
                guard let text = raw as? String, let renderer = TerminalRenderer(rawValue: text) else {
                    throw ParseError.wrongType(key: "terminal.renderer", expected: String(localized: "\"automatic\", \"metal\" or \"cpu\""))
                }
                settings.terminalRenderer = renderer
            }
        }
        string("code.fontFamily") { settings.codeFontFamily = $0 }
        number("code.fontSize") { settings.codeFontSize = min(max($0, 6), 72) }
        // The older on-or-off setting still counts, until the new one is set.
        bool("code.wordWrap") { settings.editorWordWrap = $0 ? .on : .off }
        attempt {
            if let raw = object["editor.wordWrap"] {
                guard let text = raw as? String, let wrap = WordWrap(rawValue: text) else {
                    throw ParseError.wrongType(key: "editor.wordWrap", expected: String(localized: "\"off\", \"on\" or \"bounded\""))
                }
                settings.editorWordWrap = wrap
            }
        }
        bool("editor.completion") { settings.editorCompletion = $0 }
        bool("run.button") { settings.runButton = $0 }
        attempt {
            if let raw = object["run.opensIn"] {
                guard let text = raw as? String, let placement = RunPlacement(rawValue: text) else {
                    throw ParseError.wrongType(key: "run.opensIn", expected: String(localized: "\"below\", \"right\" or \"tab\""))
                }
                settings.runOpensIn = placement
            }
        }
        attempt {
            if let value = object["run.commands"] {
                guard let map = value as? [String: String] else {
                    throw ParseError.wrongType(key: "run.commands", expected: String(localized: "an object of language → command"))
                }
                var commands: [String: String] = [:]
                for (key, command) in map {
                    // A kind of file someone added is always its tidy `.ext`.
                    if key.hasPrefix(".") { if let ext = RunCommands.tidyExtension(key) { commands[ext] = command } } else { commands[key] = command }
                }
                settings.runCommands = commands
            }
        }
        strings("run.off") { settings.runOff = $0 }
        attempt {
            if let value = object["start.commands"] {
                guard let map = value as? [String: String] else {
                    throw ParseError.wrongType(key: "start.commands", expected: String(localized: "an object of folder → command"))
                }
                settings.startCommands = map.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        number("editor.wordWrapColumn") { settings.editorWordWrapColumn = min(max(Int($0), 20), 1_000) }
        number("window.zoomLevel") { settings.zoomLevel = min(max(Int($0), Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }
        strings("externalEditors") { settings.externalEditors = $0 }
        strings("files.exclude") { settings.filesExclude = $0 }
        bool("explorer.autoReveal") { settings.explorerAutoReveal = $0 }
        bool("explorer.compactFolders") { settings.explorerCompactFolders = $0 }
        bool("web.forceDark") { settings.webForceDark = $0 }
        strings("web.openInBrowser") { settings.webOpenInBrowser = $0.compactMap(BrowserRules.tidy) }
        bool("documents.forceDark") { settings.documentsForceDark = $0 }
        bool("terminal.keepRunning") { settings.terminalKeepRunning = $0 }
        bool("change.offer") { settings.changeEntries = $0 }
        bool("updates.check") { settings.updatesCheck = $0 }
        bool("changes.perTurn") { settings.perTurnDiffs = $0 }
        bool("diff.sideBySide") { settings.diffSideBySide = $0 }
        bool("conversations.useMacModel") { settings.conversationsUseMacModel = $0 }
        bool("conversations.summarizeAll") { settings.conversationsSummarizeAll = $0 }
        bool("code.languageServers") { settings.languageServers = $0 }
        bool("notifications.enabled") { settings.notificationsEnabled = $0 }
        return (settings, problems)
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
            ("ctrl+alt+n", "runFile"),
            ("ctrl+alt+s", "startFolder"),
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
            ("f7", "nextChange"),
            ("shift+f7", "previousChange"),
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
            // ⌃Space is often the input source switcher, so there's a second way.
            ("ctrl+space", "triggerCompletion"),
            ("alt+escape", "triggerCompletion"),
            ("ctrl+g", "goToLine"),
            ("alt+z", "toggleWordWrap"),
            ("cmd+shift+o", "symbolsInFile"),
            ("cmd+t", "symbolsInWorkspace"),
            ("cmd+shift+h", "conversations"),
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
            ("cmd+shift+n", "newWindow"),
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
            case .invalidJSON(let why): String(localized: "Invalid JSON: \(why)")
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
            throw ParseError.badEntry(String(localized: "keybindings.json must be a list of { key, command }"))
        }
        return try list.map { entry in
            guard let key = entry["key"] as? String, let command = entry["command"] as? String else {
                throw ParseError.badEntry(String(localized: "Each keybinding needs a \"key\" and a \"command\""))
            }
            guard parseStrokes(key) != nil else {
                throw ParseError.badEntry(String(localized: "Can't read the key \"\(key)\""))
            }
            return (key, command)
        }
    }

    /// `plugins` are their default keys. Whatever already has a key keeps it: a plugin can't take
    /// one from Tiri or from another plugin, or change what your hands already know.
    public static func build(user: [(key: String, command: String)], plugins: [(key: String, command: String)] = []) -> [Keybinding] {
        var bindings = defaults.compactMap { key, command in
            parseStrokes(key).map { Keybinding(strokes: $0, command: command) }
        }
        for (key, command) in plugins {
            guard let strokes = parseStrokes(key), problem(with: key, command: command, bindings: bindings) == nil,
                  !bindings.contains(where: { $0.strokes == strokes }) else { continue }
            bindings.append(Keybinding(strokes: strokes, command: command))
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
    /// Why this key can't be used for this command, if there's a reason. In English, for `tiri keys`.
    public static func problem(with key: String, command: String, bindings: [Keybinding]) -> String? {
        keyProblem(with: key, command: command, bindings: bindings)?.english
    }

    /// The same, in Tiri's language, for the screen.
    public static func shownProblem(with key: String, command: String, bindings: [Keybinding]) -> String? {
        keyProblem(with: key, command: command, bindings: bindings)?.shown
    }

    private enum KeyProblem {
        case unreadable(String)
        case tooLong
        case needsModifier
        case startsLonger(keys: String, longer: String, command: String)
        case alreadyTaken(keys: String, command: String)

        var english: String {
            switch self {
            case .unreadable(let key): "Can't read the key \"\(key)\". Write it like cmd+shift+p."
            case .tooLong: "A shortcut can be at most two key presses."
            case .needsModifier: "A shortcut needs ⌘, ⌃ or ⌥, or typing that key would stop working."
            case .startsLonger(let keys, let longer, let command): "\(keys) already starts \(longer) (\(command))."
            case .alreadyTaken(let keys, let command): "\(keys) is already \(command), so it can't start a longer shortcut."
            }
        }

        var shown: String {
            switch self {
            case .unreadable(let key): String(localized: "Can't read the key \"\(key)\". Write it like cmd+shift+p.")
            case .tooLong: String(localized: "A shortcut can be at most two key presses.")
            case .needsModifier: String(localized: "A shortcut needs ⌘, ⌃ or ⌥, or typing that key would stop working.")
            case .startsLonger(let keys, let longer, let command): String(localized: "\(keys) already starts \(longer) (\(command)).")
            case .alreadyTaken(let keys, let command): String(localized: "\(keys) is already \(command), so it can't start a longer shortcut.")
            }
        }
    }

    private static func keyProblem(with key: String, command: String, bindings: [Keybinding]) -> KeyProblem? {
        guard let strokes = parseStrokes(key) else { return .unreadable(key) }
        guard strokes.count <= 2 else { return .tooLong }
        let first = strokes[0]
        let isFunctionKey = first.key.hasPrefix("f") && first.key.count > 1 && first.key.dropFirst().allSatisfy(\.isNumber)
        if first.modifiers.subtracting(.shift).isEmpty, !isFunctionKey {
            return .needsModifier
        }
        for binding in bindings where binding.command != command && command != "clearTerminal" {
            // ⌘K can be both: it waits a moment to see whether a second press follows.
            if binding.command == "clearTerminal" { continue }
            if binding.strokes.count > strokes.count, Array(binding.strokes.prefix(strokes.count)) == strokes {
                return .startsLonger(keys: strokes.map(\.symbol).joined(separator: " "), longer: binding.symbol, command: binding.command)
            }
            if strokes.count > binding.strokes.count, Array(strokes.prefix(binding.strokes.count)) == binding.strokes {
                return .alreadyTaken(keys: binding.symbol, command: binding.command)
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
