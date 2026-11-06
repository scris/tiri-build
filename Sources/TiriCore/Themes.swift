import Foundation

// MARK: - A theme

/// The colors of terminals and the editor, together. Every color is a hex string (`#rrggbb`, or `#rrggbbaa` with
/// transparency), so a theme file reads and edits as plainly as a person or an agent would write it.
public struct Theme: Codable, Equatable, Sendable {
    public var name: String
    public var terminal: TerminalColors
    public var editor: EditorColors
    /// Where it came from, for the list: "Ghostty", "iTerm2", "VS Code", a file name.
    public var source: String?
    /// The color Tiri marks things with (selections, switches, tabs), as one of the Mac's own accent colors.
    /// None follows the Mac's.
    public var accent: ThemeAccent?

    public struct TerminalColors: Codable, Equatable, Sendable {
        public var background: String
        public var foreground: String
        public var cursor: String
        public var selection: String
        /// Black, red, green, yellow, blue, magenta, cyan, white, then the same bright.
        public var ansi: [String]

        public init(background: String, foreground: String, cursor: String, selection: String, ansi: [String]) {
            self.background = background
            self.foreground = foreground
            self.cursor = cursor
            self.selection = selection
            self.ansi = ansi
        }
    }

    public struct EditorColors: Codable, Equatable, Sendable {
        public var background: String
        public var foreground: String
        public var cursor: String
        public var selection: String
        public var comment: String
        public var string: String
        public var number: String
        public var keyword: String
        public var function: String
        public var type: String
        public var attribute: String

        public init(background: String, foreground: String, cursor: String, selection: String, comment: String, string: String,
                    number: String, keyword: String, function: String, type: String, attribute: String) {
            self.background = background
            self.foreground = foreground
            self.cursor = cursor
            self.selection = selection
            self.comment = comment
            self.string = string
            self.number = number
            self.keyword = keyword
            self.function = function
            self.type = type
            self.attribute = attribute
        }
    }

    public init(name: String, terminal: TerminalColors, editor: EditorColors, source: String? = nil, accent: ThemeAccent? = nil) {
        self.name = name
        self.terminal = terminal
        self.editor = editor
        self.source = source
        self.accent = accent
    }

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.name == name } }

    public var isDark: Bool { (ThemeColor(editor.background) ?? .black).luminance < 0.4 }

    // MARK: Colors by name, for `tiri theme set` and Settings

    public static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                                   "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]

    public static let editorKeys = ["background", "foreground", "cursor", "selection", "comment", "string", "number", "keyword", "function", "type", "attribute"]

    /// Every color a theme has, as `terminal.background`, `terminal.brightRed`, `editor.comment` and so on.
    public static var colorKeys: [String] {
        ["terminal.background", "terminal.foreground", "terminal.cursor", "terminal.selection"]
            + ansiNames.map { "terminal." + $0 } + editorKeys.map { "editor." + $0 }
    }

    public subscript(key: String) -> String? {
        get {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "terminal":
                switch parts[1] {
                case "background": return terminal.background
                case "foreground": return terminal.foreground
                case "cursor": return terminal.cursor
                case "selection": return terminal.selection
                default: return Self.ansiIndex(parts[1]).map { terminal.ansi[$0] }
                }
            case "editor":
                guard let path = Self.editorPath(parts[1]) else { return nil }
                return editor[keyPath: path]
            default: return nil
            }
        }
        set {
            guard let newValue else { return }
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "terminal":
                switch parts[1] {
                case "background": terminal.background = newValue
                case "foreground": terminal.foreground = newValue
                case "cursor": terminal.cursor = newValue
                case "selection": terminal.selection = newValue
                default: if let index = Self.ansiIndex(parts[1]) { terminal.ansi[index] = newValue }
                }
            case "editor":
                if let path = Self.editorPath(parts[1]) { editor[keyPath: path] = newValue }
            default: break
            }
        }
    }

    private static func ansiIndex(_ name: String) -> Int? {
        if let index = ansiNames.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return index }
        if let number = Int(name), (0..<16).contains(number) { return number }
        return nil
    }

    private static func editorPath(_ name: String) -> WritableKeyPath<EditorColors, String>? {
        switch name.lowercased() {
        case "background": \.background
        case "foreground": \.foreground
        case "cursor": \.cursor
        case "selection": \.selection
        case "comment": \.comment
        case "string": \.string
        case "number": \.number
        case "keyword": \.keyword
        case "function": \.function
        case "type": \.type
        case "attribute": \.attribute
        default: nil
        }
    }

    /// Sets one color by name. Says what was wrong, or nil.
    public mutating func set(_ key: String, to value: String) -> String? {
        if key == "accent" {
            if ["mac", "none", "system", ""].contains(value.lowercased()) {
                accent = nil
                return nil
            }
            guard let chosen = ThemeAccent(rawValue: value.lowercased()) else {
                return "The accent is one of the Mac's: mac, \(ThemeAccent.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            accent = chosen
            return nil
        }
        guard self[key] != nil else {
            return "There's no color called \(key). Colors: \(Self.colorKeys.joined(separator: ", "))"
        }
        guard let color = ThemeColor(value) else { return "\(value) isn't a color. Use a hex color like #1e1e2e." }
        self[key] = color.hex
        return nil
    }
}

// MARK: - The accent

/// The Mac's own accent colors, which Tiri can use as its own whatever the Mac's is set to.
public enum ThemeAccent: String, Codable, Sendable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, graphite

    /// As `AppleAccentColor` and `AppleHighlightColor` store them.
    public var system: (number: Int, highlight: String) {
        switch self {
        case .red: (0, "1.000000 0.733333 0.721569 Red")
        case .orange: (1, "1.000000 0.874510 0.701961 Orange")
        case .yellow: (2, "1.000000 0.937255 0.690196 Yellow")
        case .green: (3, "0.752941 0.964706 0.678431 Green")
        case .blue: (4, "0.698039 0.843137 1.000000 Blue")
        case .purple: (5, "0.968627 0.831373 1.000000 Purple")
        case .pink: (6, "1.000000 0.749020 0.823529 Pink")
        case .graphite: (-1, "0.847059 0.847059 0.862745 Graphite")
        }
    }

    /// Roughly what it looks like, for a swatch.
    public var hex: String {
        switch self {
        case .blue: "#0a84ff"
        case .purple: "#a550a7"
        case .pink: "#f74f9e"
        case .red: "#ff5257"
        case .orange: "#f7821b"
        case .yellow: "#ffc600"
        case .green: "#62ba46"
        case .graphite: "#8c8c8c"
        }
    }
}

// MARK: - The built-in themes

/// Which theme is for which: like VS Code, one for dark, one for light, and one of each for when Increase Contrast is on.
public enum ThemeSlot: String, CaseIterable, Sendable {
    case dark, light, highContrastDark, highContrastLight

    public var settingKey: String {
        switch self {
        case .dark: "theme.dark"
        case .light: "theme.light"
        case .highContrastDark: "theme.highContrastDark"
        case .highContrastLight: "theme.highContrastLight"
        }
    }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .highContrastDark: "High Contrast Dark"
        case .highContrastLight: "High Contrast Light"
        }
    }

    public var isDark: Bool { self == .dark || self == .highContrastDark }

    public static func current(dark: Bool, increaseContrast: Bool) -> ThemeSlot {
        increaseContrast ? (dark ? .highContrastDark : .highContrastLight) : (dark ? .dark : .light)
    }

    /// Where a theme goes when nobody says: by how it looks.
    public static func natural(for theme: Theme) -> ThemeSlot {
        let contrast = (ThemeColor(theme.editor.background) ?? .black).contrast(with: ThemeColor(theme.editor.foreground) ?? .white)
        let high = theme.name.localizedCaseInsensitiveContains("high contrast") || contrast >= 18
        return high ? (theme.isDark ? .highContrastDark : .highContrastLight) : (theme.isDark ? .dark : .light)
    }
}

extension Theme {
    public static let tiriDark = tiri(dark: true, name: "System Dark", accent: nil)
    public static let tiriLight = tiri(dark: false, name: "System Light", accent: nil)
    public static let tiriPinkDark = tiri(dark: true, name: "Tiri Pink Dark", accent: .pink)
    public static let tiriPinkLight = tiri(dark: false, name: "Tiri Pink Light", accent: .pink)

    public static let builtIns: [Theme] = [tiriDark, tiriLight, tiriPinkDark, tiriPinkLight, tiriHighContrastDark, tiriHighContrastLight]

    public static func defaultName(for slot: ThemeSlot) -> String {
        switch slot {
        case .dark: tiriDark.name
        case .light: tiriLight.name
        case .highContrastDark: tiriHighContrastDark.name
        case .highContrastLight: tiriHighContrastLight.name
        }
    }

    /// Tiri's own colors, the ones it draws with system colors when no other theme is chosen.
    public var isTiriStandard: Bool { [Self.tiriDark.name, Self.tiriLight.name, Self.tiriPinkDark.name, Self.tiriPinkLight.name].contains(name) }

    static func tiri(dark: Bool, name: String = "Tiri", accent: ThemeAccent? = nil) -> Theme {
        dark
            ? Theme(name: name,
                    terminal: .init(background: "#1c1c1e", foreground: "#e6e6eb", cursor: "#e45c9c", selection: "#e45c9c73",
                                    ansi: ["#1c1c1e", "#ff6b6b", "#5fd38d", "#e5c07b", "#5aa5ff", "#c792ea", "#56c8d8", "#d8d8dc",
                                           "#6e6e73", "#ff8585", "#7be3a5", "#f2d08f", "#7dbbff", "#d7a9f2", "#7adbe8", "#ffffff"]),
                    editor: .init(background: "#1e1e1e", foreground: "#dfdfdf", cursor: "#e45c9c", selection: "#e45c9c66",
                                  comment: "#a1a1a6", string: "#73d48f", number: "#e6bf7a", keyword: "#c791eb",
                                  function: "#82b5fa", type: "#6bd1d1", attribute: "#ed9e78"),
                    source: "Tiri", accent: accent)
            : Theme(name: name,
                    terminal: .init(background: "#ffffff", foreground: "#1c1c1f", cursor: "#c8417f", selection: "#c8417f4d",
                                    ansi: ["#1d1d1f", "#c4262e", "#1a7f37", "#8f6500", "#0a66d6", "#8e44ad", "#0b7c8c", "#6e6e73",
                                           "#55555a", "#d93a42", "#22963f", "#a67800", "#2b7de9", "#a056c5", "#1293a6", "#1d1d1f"]),
                    editor: .init(background: "#ffffff", foreground: "#262626", cursor: "#c8417f", selection: "#c8417f40",
                                  comment: "#6e6e73", string: "#177a33", number: "#996600", keyword: "#8733ad",
                                  function: "#1a57bf", type: "#07707a", attribute: "#a6450f"),
                    source: "Tiri", accent: accent)
    }

    public static let tiriHighContrastDark = Theme(
        name: "High Contrast Dark",
        terminal: .init(background: "#000000", foreground: "#ffffff", cursor: "#ffffff", selection: "#ffffff59",
                        ansi: ["#000000", "#ff6e6e", "#5fff87", "#ffff5f", "#6eb4ff", "#ff87ff", "#5fffff", "#e4e4e4",
                               "#a8a8a8", "#ff9090", "#90ffb0", "#ffff90", "#90ccff", "#ffb0ff", "#90ffff", "#ffffff"]),
        editor: .init(background: "#000000", foreground: "#ffffff", cursor: "#ffffff", selection: "#ffffff59",
                      comment: "#c8c8c8", string: "#7dff9a", number: "#ffd75f", keyword: "#ff9cf7",
                      function: "#8fd0ff", type: "#6ff0f0", attribute: "#ffb27a"),
        source: "Tiri")

    public static let tiriHighContrastLight = Theme(
        name: "High Contrast Light",
        terminal: .init(background: "#ffffff", foreground: "#000000", cursor: "#000000", selection: "#0050e04d",
                        ansi: ["#000000", "#b00000", "#006b00", "#6b5000", "#0040c0", "#8000a0", "#006070", "#4a4a4a",
                               "#303030", "#d00000", "#008000", "#7a5c00", "#0050e0", "#9a00c0", "#007080", "#000000"]),
        editor: .init(background: "#ffffff", foreground: "#000000", cursor: "#000000", selection: "#0050e04d",
                      comment: "#444444", string: "#006b20", number: "#7a4a00", keyword: "#7a00a0",
                      function: "#0040b0", type: "#005f6a", attribute: "#9a3000"),
        source: "Tiri")
}

// MARK: - Colors

/// One color, read from what themes write: `#rgb`, `#rrggbb`, `#rrggbbaa`, with or without `#`.
public struct ThemeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public static let black = ThemeColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public init?(_ text: String) {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        self.init(red: Double((value >> (16 + shift)) & 0xFF) / 255,
                  green: Double((value >> (8 + shift)) & 0xFF) / 255,
                  blue: Double((value >> shift) & 0xFF) / 255,
                  alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    public var hex: String {
        func byte(_ value: Double) -> String { String(format: "%02x", Int((value * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 0.999 ? byte(alpha) : "")
    }

    /// Relative luminance, as WCAG defines it.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Partway from this color to another.
    public func mixed(with other: ThemeColor, _ amount: Double) -> ThemeColor {
        ThemeColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                   blue: blue + (other.blue - blue) * amount, alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> ThemeColor { ThemeColor(red: red, green: green, blue: blue, alpha: alpha) }
}

// MARK: - Bringing a theme in

public enum ThemeImport {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        /// In English, for `tiri theme`.
        public let description: String
        /// In Tiri's language, for Settings.
        public let shown: String
        public init(_ description: String, shown: String) {
            self.description = description
            self.shown = shown
        }
    }

    /// Reads a Ghostty theme, an iTerm2 `.itermcolors` file or a VS Code (or Cursor) color theme, whichever it is.
    public static func read(file url: URL) throws -> Theme {
        guard let data = try? Data(contentsOf: url) else { throw Failure("Couldn't read \(url.lastPathComponent).", shown: String(localized: "Couldn't read \(url.lastPathComponent).")) }
        var fallbackName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-color-theme", with: "").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        // "dark plus" reads better as a name than as a file.
        if fallbackName == fallbackName.lowercased() { fallbackName = fallbackName.capitalized }
        if url.pathExtension.lowercased() == "itermcolors" || data.starts(with: Array("<?xml".utf8)) || data.starts(with: Array("bplist".utf8)) {
            return try iTerm(data, name: fallbackName)
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try vsCode(data, name: fallbackName, baseURL: url.deletingLastPathComponent())
        }
        return try ghostty(text, name: fallbackName)
    }

    // MARK: Ghostty

    /// `palette = 0=#1d1f21`, `background = 1d1f21`, `cursor-color`, `selection-background`, one per line.
    public static func ghostty(_ text: String, name: String) throws -> Theme {
        var ansi = [String?](repeating: nil, count: 16)
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "palette", let inner = value.firstIndex(of: "=") {
                if let index = Int(value[..<inner].trimmingCharacters(in: .whitespaces)), (0..<16).contains(index),
                   let color = ThemeColor(String(value[value.index(after: inner)...])) {
                    ansi[index] = color.hex
                }
            } else if let color = ThemeColor(value) {
                values[key] = color.hex
            }
        }
        guard values["background"] != nil || ansi.contains(where: { $0 != nil }) else {
            throw Failure("This doesn't look like a Ghostty theme: it has no background or palette.", shown: String(localized: "This doesn't look like a Ghostty theme: it has no background or palette."))
        }
        return complete(name: name, source: "Ghostty", terminalBackground: values["background"], terminalForeground: values["foreground"],
                        cursor: values["cursor-color"], selection: values["selection-background"], ansi: ansi)
    }

    // MARK: iTerm2

    public static func iTerm(_ data: Data, name: String) throws -> Theme {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure("This doesn't look like an iTerm2 color preset.", shown: String(localized: "This doesn't look like an iTerm2 color preset."))
        }
        func color(_ key: String) -> String? {
            guard let entry = plist[key] as? [String: Any],
                  let red = (entry["Red Component"] as? NSNumber)?.doubleValue,
                  let green = (entry["Green Component"] as? NSNumber)?.doubleValue,
                  let blue = (entry["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            return ThemeColor(red: red, green: green, blue: blue).hex
        }
        let ansi = (0..<16).map { color("Ansi \($0) Color") }
        guard color("Background Color") != nil || ansi.contains(where: { $0 != nil }) else {
            throw Failure("This iTerm2 file has no colors in it.", shown: String(localized: "This iTerm2 file has no colors in it."))
        }
        return complete(name: name, source: "iTerm2", terminalBackground: color("Background Color"), terminalForeground: color("Foreground Color"),
                        cursor: color("Cursor Color"), selection: color("Selection Color"), ansi: ansi)
    }

    // MARK: VS Code

    /// A VS Code color theme: `colors` for the editor and terminal, `tokenColors` for code. Comments, trailing commas,
    /// `include` of a parent theme and token colors kept in a `.tmTheme` file all happen in real ones.
    public static func vsCode(_ data: Data, name: String, baseURL: URL?) throws -> Theme {
        var (colors, rules, kind, declaredName) = try vsCodeParts(data, baseURL: baseURL, depth: 0)
        if colors.isEmpty, rules.isEmpty { throw Failure("This JSON isn't a color theme: it has no colors or tokenColors.", shown: String(localized: "This JSON isn't a color theme: it has no colors or tokenColors.")) }
        let dark = kind.map { !$0.contains("light") && $0 != "vs" } ?? ((colors["editor.background"].flatMap(ThemeColor.init)?.luminance ?? 0) < 0.4)
        // A rule with no scope sets the whole editor's colors.
        if colors["editor.foreground"] == nil, let global = rules.first(where: { $0.selectors.isEmpty })?.foreground { colors["editor.foreground"] = global }
        let base = Theme.tiri(dark: dark)
        let background = colors["editor.background"] ?? (dark ? "#1e1e1e" : "#ffffff")
        let foreground = colors["editor.foreground"] ?? (dark ? "#d4d4d4" : "#000000")
        let scoped = rules.filter { !$0.selectors.isEmpty }
        func token(_ probes: [String], or fallback: String) -> String { match(probes, in: scoped) ?? fallback }
        let editor = Theme.EditorColors(
            background: background, foreground: foreground,
            cursor: colors["editorCursor.foreground"] ?? foreground,
            selection: colors["editor.selectionBackground"] ?? ThemeColor(foreground)!.withAlpha(0.25).hex,
            comment: token(["comment.line.double-slash", "comment.block", "comment"], or: base.editor.comment),
            string: token(["string.quoted.double", "string"], or: base.editor.string),
            number: token(["constant.numeric.integer", "constant.numeric", "constant.language"], or: base.editor.number),
            keyword: token(["keyword.control", "storage.type", "keyword", "storage"], or: base.editor.keyword),
            function: token(["entity.name.function", "support.function"], or: base.editor.function),
            type: token(["entity.name.type", "entity.name.class", "support.type", "support.class", "storage.type"], or: base.editor.type),
            attribute: token(["entity.other.attribute-name", "variable.parameter", "support.type.property-name", "entity.name.tag"], or: base.editor.attribute))
        let terminalKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let ansi = (terminalKeys.map { "terminal.ansi" + $0 } + terminalKeys.map { "terminal.ansiBright" + $0 }).map { colors[$0] }
        var theme = complete(name: declaredName ?? name, source: "VS Code",
                             terminalBackground: colors["terminal.background"] ?? background,
                             terminalForeground: colors["terminal.foreground"] ?? foreground,
                             cursor: colors["terminalCursor.foreground"] ?? editor.cursor,
                             selection: colors["terminal.selectionBackground"] ?? editor.selection, ansi: ansi, darkHint: dark)
        theme.editor = editor
        return theme
    }

    struct TokenRule {
        var selectors: [String]
        var foreground: String?
    }

    private static func vsCodeParts(_ data: Data, baseURL: URL?, depth: Int) throws -> ([String: String], [TokenRule], String?, String?) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripJSONC(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any] else {
            throw Failure("This isn't JSON a color theme could be read from.", shown: String(localized: "This isn't JSON a color theme could be read from."))
        }
        var colors: [String: String] = [:]
        var rules: [TokenRule] = []
        var kind = (object["type"] as? String)?.lowercased()
        // A parent theme first, so this one's own colors win.
        if depth < 4, let include = object["include"] as? String, let baseURL,
           let parentData = try? Data(contentsOf: baseURL.appendingPathComponent(include)) {
            let parent = try vsCodeParts(parentData, baseURL: baseURL.appendingPathComponent(include).deletingLastPathComponent(), depth: depth + 1)
            colors = parent.0
            rules = parent.1
            kind = kind ?? parent.2
        }
        for (key, value) in object["colors"] as? [String: Any] ?? [:] {
            if let text = value as? String, let color = ThemeColor(text) { colors[key] = color.hex }
        }
        if let list = object["tokenColors"] as? [[String: Any]] {
            rules += tokenRules(list)
        } else if let file = object["tokenColors"] as? String, let baseURL,
                  let plistData = try? Data(contentsOf: baseURL.appendingPathComponent(file)),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let list = plist["settings"] as? [[String: Any]] {
            rules += tokenRules(list)
        }
        return (colors, rules, kind, object["name"] as? String)
    }

    private static func tokenRules(_ list: [[String: Any]]) -> [TokenRule] {
        list.map { entry in
            let scope: [String]
            if let text = entry["scope"] as? String {
                scope = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let array = entry["scope"] as? [String] {
                scope = array.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            } else {
                scope = []
            }
            let foreground = ((entry["settings"] as? [String: Any])?["foreground"] as? String).flatMap(ThemeColor.init)?.hex
            return TokenRule(selectors: scope.filter { !$0.isEmpty }, foreground: foreground)
        }
    }

    /// The color a theme gives the first of these scopes it has a rule for. The most specific selector wins, then the
    /// later rule, as in TextMate. Selectors that need a parent scope (`meta.embedded string`) are left out: they're for
    /// code inside other code.
    static func match(_ probes: [String], in rules: [TokenRule]) -> String? {
        for probe in probes {
            var best: (length: Int, color: String)?
            for rule in rules {
                guard let color = rule.foreground else { continue }
                for selector in rule.selectors where !selector.contains(" ") && !selector.hasPrefix("-") {
                    guard probe == selector || probe.hasPrefix(selector + ".") else { continue }
                    if best == nil || selector.count >= best!.length { best = (selector.count, color) }
                }
            }
            if let best { return best.color }
        }
        return nil
    }

    /// JSON with comments and trailing commas, as VS Code writes it, made plain.
    public static func stripJSONC(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let characters = Array(text)
        var index = 0
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                out.append(character)
                if character == "\\", index + 1 < characters.count {
                    out.append(characters[index + 1])
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
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2
            } else if character == "," {
                var look = index + 1
                while look < characters.count, characters[look].isWhitespace { look += 1 }
                if look < characters.count, characters[look] == "}" || characters[look] == "]" {
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

    // MARK: Filling in what a theme leaves out

    /// A terminal theme gives the editor its colors from its own palette; anything missing comes from Tiri's.
    static func complete(name: String, source: String, terminalBackground: String?, terminalForeground: String?,
                         cursor: String?, selection: String?, ansi given: [String?], darkHint: Bool? = nil) -> Theme {
        let dark = darkHint ?? (terminalBackground.flatMap(ThemeColor.init).map { $0.luminance < 0.4 } ?? true)
        let base = Theme.tiri(dark: dark)
        let background = terminalBackground ?? base.terminal.background
        let foreground = terminalForeground ?? base.terminal.foreground
        var ansi = (0..<16).map { index in (index < given.count ? given[index] : nil) ?? base.terminal.ansi[index] }
        // A palette with only the first eight: the bright ones are the same.
        if given.count >= 8, given[8...].allSatisfy({ $0 == nil }), given[..<8].contains(where: { $0 != nil }) {
            for index in 8..<16 { ansi[index] = ansi[index - 8] }
        }
        let back = ThemeColor(background) ?? .black
        let fore = ThemeColor(foreground) ?? .white
        let selectionColor = selection ?? fore.withAlpha(0.28).hex
        // Bright black is often the background's own shade, which would hide comments.
        var comment = ThemeColor(ansi[8]) ?? fore
        if comment.contrast(with: back) < 2.2 { comment = fore.mixed(with: back, 0.45) }
        let terminal = Theme.TerminalColors(background: background, foreground: foreground, cursor: cursor ?? foreground,
                                            selection: selectionColor, ansi: ansi)
        let editor = Theme.EditorColors(background: background, foreground: foreground, cursor: cursor ?? foreground,
                                        selection: selectionColor, comment: comment.hex, string: ansi[2], number: ansi[3],
                                        keyword: ansi[5], function: ansi[4], type: ansi[6], attribute: ansi[1])
        return Theme(name: name, terminal: terminal, editor: editor, source: source)
    }
}

// MARK: - Themes kept by Tiri

/// Someone's themes, one JSON file each in `<config>/themes`.
public struct ThemeLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init() {
        self.init(directory: TiriPaths.configDirectory.appendingPathComponent("themes", isDirectory: true))
    }

    public func all() -> [Theme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A theme by name: built in, or one of these.
    public func theme(named name: String) -> Theme? {
        Theme.builtIns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Writes a theme, over one with the same name.
    @discardableResult
    public func save(_ theme: Theme) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = file(for: theme.name)
        try encoder.encode(theme).write(to: url, options: .atomic)
        return url
    }

    public func delete(named name: String) throws {
        guard let existing = all().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        try FileManager.default.removeItem(at: file(for: existing.name))
    }

    /// A name no theme has yet: "Dracula", then "Dracula 2".
    public func freeName(for name: String) -> String {
        let taken = Set(all().map { $0.name.lowercased() } + Theme.builtIns.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    public func file(for name: String) -> URL {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(safe).split(separator: "-").joined(separator: "-")
        return directory.appendingPathComponent((slug.isEmpty ? "theme" : slug) + ".json")
    }
}

// MARK: - Themes already on this Mac

/// Themes other apps on this Mac already have, so bringing one in is a click: Cursor's and VS Code's own and their
/// extensions', and Ghostty's.
public enum ThemeDiscovery {
    public struct Found: Equatable, Sendable, Identifiable {
        public var name: String
        public var path: String
        /// "Cursor", "VS Code", "Ghostty".
        public var from: String
        public var dark: Bool?
        public var id: String { from + "/" + path }
    }

    public static func available(home: String = NSHomeDirectory()) -> [Found] {
        var found: [Found] = []
        let editors: [(String, [String])] = [
            ("Cursor", ["/Applications/Cursor.app/Contents/Resources/app/extensions", home + "/.cursor/extensions"]),
            ("VS Code", ["/Applications/Visual Studio Code.app/Contents/Resources/app/extensions", home + "/.vscode/extensions"]),
        ]
        for (app, folders) in editors {
            for folder in folders { found += extensionThemes(in: folder, from: app) }
        }
        for folder in ["/Applications/Ghostty.app/Contents/Resources/ghostty/themes", home + "/.config/ghostty/themes"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where !name.hasPrefix(".") {
                found.append(Found(name: name, path: folder + "/" + name, from: "Ghostty", dark: nil))
            }
        }
        // The same theme in two places (an editor and its extensions) once.
        var seen = Set<String>()
        return found.filter { seen.insert($0.from + "/" + $0.name).inserted }
    }

    /// The theme Cursor or VS Code is using now, by name, if either says.
    public static func inUse(home: String = NSHomeDirectory()) -> [String: String] {
        var result: [String: String] = [:]
        for (app, folder) in [("Cursor", "Cursor"), ("VS Code", "Code")] {
            let path = home + "/Library/Application Support/\(folder)/User/settings.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: Data(ThemeImport.stripJSONC(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any],
                  let name = object["workbench.colorTheme"] as? String else { continue }
            result[app] = name
        }
        return result
    }

    private static func extensionThemes(in folder: String, from app: String) -> [Found] {
        let manager = FileManager.default
        let extensions = (try? manager.contentsOfDirectory(atPath: folder)) ?? []
        var found: [Found] = []
        for name in extensions where !name.hasPrefix(".") {
            let root = folder + "/" + name
            guard let data = manager.contents(atPath: root + "/package.json"),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let themes = (package["contributes"] as? [String: Any])?["themes"] as? [[String: Any]] else { continue }
            let strings = manager.contents(atPath: root + "/package.nls.json")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for theme in themes {
                guard let relative = theme["path"] as? String else { continue }
                var label = (theme["label"] as? String) ?? (theme["id"] as? String) ?? (relative as NSString).lastPathComponent
                if label.hasPrefix("%"), label.hasSuffix("%") {
                    let key = String(label.dropFirst().dropLast())
                    label = (strings[key] as? String) ?? (strings[key] as? [String: Any])?["message"] as? String ?? (theme["id"] as? String) ?? label
                }
                let ui = (theme["uiTheme"] as? String) ?? ""
                let path = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
                found.append(Found(name: label, path: path, from: app, dark: ui.isEmpty ? nil : !(ui == "vs" || ui == "hc-light")))
            }
        }
        return found
    }
}
