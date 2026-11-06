import Foundation

/// What a plugin says about itself, in `.tiri-plugin/plugin.json`.
///
/// Reading one runs nothing. Everything a plugin adds is declared here first, so Tiri can show it
/// before it's turned on, and take all of it away again when it's turned off.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// What this build of Tiri speaks. A plugin declares the one it was written for.
    public static let currentAPI = 1

    public var name: String
    public var title: String?
    public var version: String
    public var description: String?
    public var apiVersion: Int
    /// Which versions of Tiri it works with, like `>=0.1.0 <2`.
    public var tiri: String?
    /// How `tiri plugin test` tests it.
    public var test: [String]?
    public var commands: [Command]?
    public var settings: [Setting]?
    public var languages: [Language]?
    public var grammars: [Grammar]?
    public var panels: [Panel]?
    public var viewers: [Viewer]?
    public var sidebar: [SidebarSection]?
    public var statusBar: [StatusItem]?
    public var fileButtons: [FileButton]?
    public var processes: [BackgroundProcess]?
    /// Colors on text in the editor, found by Tiri itself, one line at a time, so nothing of the
    /// plugin's runs while you type.
    public var highlights: [Highlight]?
    /// Marks beside files in the explorer.
    public var fileMarks: [FileMarks]?
    public var agent: AgentHalf?

    public var displayName: String { title ?? name }

    public init(name: String, version: String, apiVersion: Int = PluginManifest.currentAPI) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
    }

    /// Where a program runs: the workspace's machine, or always this Mac.
    public enum Place: String, Codable, Sendable { case workspace, mac }
    public enum Opening: String, Codable, Sendable { case tab, peek, right, down }
    public enum Display: String, Codable, Sendable { case toast, none }
    public enum Saving: String, Codable, Sendable { case front, all }

    /// A line of text or a choice, asked for in the palette.
    public struct Input: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case text, choice }
        /// It arrives as `${args.name}`.
        public var name: String
        public var prompt: String
        public var type: Kind?
        public var placeholder: String?
        public var `default`: String?
        public var options: [Choice]?
        /// Where the choices come from when they aren't known ahead: `exec` printing JSON, or a process.
        public var optionsFrom: Provider?

        public init(name: String, prompt: String) {
            self.name = name
            self.prompt = prompt
        }

        public var kind: Kind { type ?? (options != nil || optionsFrom != nil ? .choice : .text) }
    }

    public struct Choice: Codable, Sendable, Equatable {
        public var value: String
        public var label: String?
        public var detail: String?
        public var symbol: String?

        public init(value: String, label: String? = nil, detail: String? = nil, symbol: String? = nil) {
            self.value = value
            self.label = label
            self.detail = detail
            self.symbol = symbol
        }

        /// `["a", "b"]`, `[{"value", "label", "detail"}]` or `{"items": [...]}`, from a program.
        public static func list(from value: JSONValue, limit: Int = 5_000) -> [Choice] {
            let entries = value["items"]?.arrayValue ?? value["options"]?.arrayValue ?? value.arrayValue ?? []
            return entries.prefix(limit).compactMap { entry in
                if let text = entry.stringValue { return Choice(value: text) }
                guard let picked = entry["value"].map(PluginTemplate.text) ?? entry["label"]?.stringValue else { return nil }
                return Choice(value: picked, label: entry["label"]?.stringValue ?? entry["title"]?.stringValue,
                              detail: entry["detail"]?.stringValue, symbol: entry["symbol"]?.stringValue)
            }
        }
    }

    /// Text in the editor to color. `pattern` is a regular expression, matched within one line.
    public struct Highlight: Codable, Sendable, Equatable {
        public var pattern: String
        /// Only this group of the match is colored.
        public var group: Int?
        /// Which files, like `*.py`. All of them if left out.
        public var files: [String]?
        public var color: String?
        public var background: String?
        public var underline: Bool?
        public var strikethrough: Bool?
        public var caseInsensitive: Bool?
        /// Only where the file's language says it's a comment. In a file with no colors of its own, anywhere.
        public var onlyInComments: Bool?

        public init(pattern: String) {
            self.pattern = pattern
        }
    }

    public struct FileMarks: Codable, Sendable, Equatable {
        public var id: String
        public var provider: Provider?
        public var refresh: Refresh?
    }

    public struct Command: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var category: String?
        /// Its default shortcut. Anything already taken stays with what has it.
        public var key: String?
        /// Runs a program and waits for it. Arguments can use `${file}`, `${folder}`, `${plugin}` and `${args.name}`.
        public var exec: [String]?
        /// A line for a new terminal, where you can watch it and answer it.
        public var terminal: String?
        /// Shows one of this plugin's panels.
        public var panel: String?
        /// Words for the agent you're running. They wait in its input until you press Return.
        public var ask: String?
        /// Asks one of this plugin's background processes.
        public var process: String?
        public var method: String?
        public var `where`: Place?
        public var show: Display?
        public var open: Opening?
        public var timeout: Double?
        /// Asked for in the palette before it runs, unless they're already in its args.
        public var input: [Input]?
        /// What gets saved first: the file in front, or every file with unsaved edits.
        public var save: Saving?

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }

        var actions: [String] {
            [exec != nil ? "exec" : nil, terminal != nil ? "terminal" : nil, panel != nil ? "panel" : nil,
             ask != nil ? "ask" : nil, process != nil ? "process" : nil].compactMap { $0 }
        }
    }

    public struct Setting: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case toggle, choice, number, text, list }
        public struct Option: Codable, Sendable, Equatable {
            public var value: String
            public var label: String?
        }
        public var key: String
        public var title: String
        public var explanation: String?
        public var type: Kind
        public var options: [Option]?
        public var min: Double?
        public var max: Double?
        public var step: Double?
        public var placeholder: String?
        public var `default`: JSONValue?
    }

    public struct Language: Codable, Sendable, Equatable {
        public struct Comment: Codable, Sendable, Equatable {
            public var line: String?
            public var block: [String]?
        }
        public struct Server: Codable, Sendable, Equatable {
            /// Tried in order. The first word is a program on PATH, or a path inside the plugin.
            public var commands: [[String]]
            public var rootMarkers: [String]?
            public var localBins: [String]?
            public var installHint: String?
            /// What language servers call this language, when that isn't its id.
            public var languageID: String?
        }
        public var id: String
        public var name: String?
        public var extensions: [String]?
        public var fileNames: [String]?
        public var interpreters: [String]?
        public var aliases: [String]?
        /// A scope from this plugin's `grammars`, or one Tiri already has like `source.cpp`.
        public var grammar: String?
        public var comment: Comment?
        public var colonOpensBlock: Bool?
        public var isProse: Bool?
        public var server: Server?
    }

    /// A TextMate grammar: JSON or a `.tmLanguage` property list, as VS Code extensions ship them.
    public struct Grammar: Codable, Sendable, Equatable {
        public var scope: String
        public var path: String
        public var injectTo: [String]?
    }

    public struct Panel: Codable, Sendable, Equatable {
        public struct Allowed: Codable, Sendable, Equatable {
            /// `https://example.com` and the like. Nothing else can be reached.
            public var network: [String]?
            /// Commands it can run, by full id or this plugin's short one.
            public var commands: [String]?
            public var processes: [String]?
            /// May put words in the input of the agent you're running. They wait for your Return.
            public var agent: Bool?
            /// May open files in this workspace.
            public var openFiles: Bool?
            /// Hears which files are open, which is in front, and what's saved and changed.
            public var editor: Bool?
        }
        public var id: String
        public var title: String
        public var entry: String
        public var symbol: String?
        public var allow: Allowed?
    }

    public struct Viewer: Codable, Sendable, Equatable {
        public enum Priority: String, Codable, Sendable {
            /// Opens these files, with a button for seeing them as text.
            case `default`
            /// Text first, with a button for this.
            case option
        }
        public var panel: String
        public var patterns: [String]
        public var priority: Priority?
        /// May save changes to the file it's showing.
        public var writes: Bool?
    }

    /// Where a sidebar section or status item gets what it shows.
    public struct Provider: Codable, Sendable, Equatable {
        public var exec: [String]?
        public var process: String?
        public var method: String?
        public var `where`: Place?
        public var timeout: Double?
    }

    public struct Refresh: Codable, Sendable, Equatable {
        /// Seconds between looks, at least 30, only while the app is in front.
        public var every: Double?
        public var onSave: Bool?
        /// When a different file comes to the front.
        public var onFrontFile: Bool?
        /// When files in the workspace change on disk, by anyone. At most every few seconds.
        public var onFileChange: Bool?
    }

    /// A row's right-click menu. The row's own args go with it.
    public struct MenuItem: Codable, Sendable, Equatable {
        public var title: String
        public var command: String
        public var symbol: String?

        public init(title: String, command: String, symbol: String? = nil) {
            self.title = title
            self.command = command
            self.symbol = symbol
        }
    }

    public struct ToolbarButton: Codable, Sendable, Equatable {
        public var title: String
        public var symbol: String?
        public var command: String
    }

    public struct SidebarSection: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var provider: Provider?
        public var refresh: Refresh?
        public var emptyText: String?
        public var buttons: [ToolbarButton]?
        /// On every row's right-click menu, before the row's own.
        public var menu: [MenuItem]?
    }

    public struct StatusItem: Codable, Sendable, Equatable {
        public var id: String
        public var text: String?
        public var symbol: String?
        public var tooltip: String?
        public var command: String?
        public var provider: Provider?
        public var refresh: Refresh?
    }

    public struct FileButton: Codable, Sendable, Equatable {
        public var title: String
        public var symbol: String?
        public var patterns: [String]
        public var command: String
    }

    public struct BackgroundProcess: Codable, Sendable, Equatable {
        public var id: String
        public var exec: [String]
        public var `where`: Place?
        public var idleMinutes: Double?
        /// What it's told as it happens. Telling it starts it.
        public var events: [Event]?
    }

    public enum Event: String, Codable, Sendable, CaseIterable {
        /// `{"path"}`, or a null path when no file is in front.
        case frontFile
        /// `{"paths": [...], "front"}`, whenever the files open in the workspace change.
        case openFiles
        /// `{"path"}`, after Tiri saves a file.
        case saved
        /// `{"paths": [...]}`, files changed on disk in the workspace, a few at a time.
        case filesChanged
    }

    /// The part of a plugin that lives in the agent: skills, hooks and MCP servers.
    public struct AgentHalf: Codable, Sendable, Equatable {
        /// A folder Claude Code loads as a plugin, inside Tiri's terminals only. `.` is the plugin itself.
        public var claude: String?
    }

    // MARK: Reading

    public static let folderName = ".tiri-plugin"
    public static let fileName = "plugin.json"

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(folderName).appendingPathComponent(fileName)
    }

    public static func decode(_ data: Data) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    public static func load(from folder: URL) throws -> PluginManifest {
        try decode(Data(contentsOf: url(in: folder)))
    }

    /// Why a decode failed, in words that name the field.
    public static func explain(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func place(_ path: [CodingKey]) -> String {
            let joined = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "the file" : joined
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "\(place(context.codingPath + [key])) is missing"
        case .typeMismatch(let type, let context): return "\(place(context.codingPath)) should be a \(type)"
        case .valueNotFound(_, let context): return "\(place(context.codingPath)) is empty"
        case .dataCorrupted(let context):
            if let inner = context.underlyingError as NSError? { return "not valid JSON: \(inner.userInfo[NSDebugDescriptionErrorKey] ?? inner.localizedDescription)" }
            return "\(place(context.codingPath)): \(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }

    // MARK: What it does, for a person deciding

    /// Every program it can start, as it would be started.
    public var programs: [String] {
        var found: [String] = []
        for command in commands ?? [] {
            if let exec = command.exec { found.append(exec.joined(separator: " ")) }
            if let line = command.terminal { found.append(line) }
            for input in command.input ?? [] { if let exec = input.optionsFrom?.exec { found.append(exec.joined(separator: " ")) } }
        }
        for section in sidebar ?? [] { if let exec = section.provider?.exec { found.append(exec.joined(separator: " ")) } }
        for item in statusBar ?? [] { if let exec = item.provider?.exec { found.append(exec.joined(separator: " ")) } }
        for marks in fileMarks ?? [] { if let exec = marks.provider?.exec { found.append(exec.joined(separator: " ")) } }
        for process in processes ?? [] { found.append(process.exec.joined(separator: " ")) }
        for language in languages ?? [] { for command in language.server?.commands ?? [] { found.append(command.joined(separator: " ")) } }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// As they'll really be allowed, so `https://github.com@evil.example` can't look like something else.
    public var networkAddresses: [String] {
        var seen = Set<String>()
        return (panels ?? []).flatMap { $0.allow?.network ?? [] }.compactMap(PluginNetwork.source).filter { seen.insert($0).inserted }
    }

    /// What its panels can do outside themselves.
    public var panelPowers: [String] {
        var said: [String] = []
        let panels = panels ?? []
        if panels.contains(where: { $0.allow?.agent == true }) { said.append("Its panels can put words in your agent's input, for you to send.") }
        if panels.contains(where: { $0.allow?.openFiles == true }) { said.append("Its panels can open files in your workspace.") }
        if panels.contains(where: { $0.allow?.editor == true }) { said.append("Its panels can see which files you have open, and which change.") }
        let own = Set((commands ?? []).flatMap { [$0.id, name + "." + $0.id] })
        let others = panels.flatMap { $0.allow?.commands ?? [] }.filter { !own.contains($0) }
        if !others.isEmpty { said.append("Its panels can run these commands: " + Array(Set(others)).sorted().joined(separator: ", ") + ".") }
        for viewer in viewers ?? [] {
            let files = viewer.patterns.joined(separator: ", ")
            said.append(viewer.writes == true ? "Its viewer can read and change \(files) files you open." : "Its viewer can read \(files) files you open.")
        }
        let words = (commands ?? []).compactMap(\.ask)
        if !words.isEmpty { said.append("It can leave these words in your agent's input, for you to send:\n" + words.prefix(5).map { "• " + $0 }.joined(separator: "\n")) }
        return said
    }

    /// `panelPowers` in the language Tiri is in, for the question before turning it on. The English
    /// stays as it is for `tiri plugin validate`.
    public var shownPanelPowers: [String] {
        var said: [String] = []
        let panels = panels ?? []
        if panels.contains(where: { $0.allow?.agent == true }) { said.append(String(localized: "Its panels can put words in your agent's input, for you to send.")) }
        if panels.contains(where: { $0.allow?.openFiles == true }) { said.append(String(localized: "Its panels can open files in your workspace.")) }
        if panels.contains(where: { $0.allow?.editor == true }) { said.append(String(localized: "Its panels can see which files you have open, and which change.")) }
        let own = Set((commands ?? []).flatMap { [$0.id, name + "." + $0.id] })
        let others = panels.flatMap { $0.allow?.commands ?? [] }.filter { !own.contains($0) }
        if !others.isEmpty {
            let list = Array(Set(others)).sorted().joined(separator: ", ")
            said.append(String(localized: "Its panels can run these commands: \(list)."))
        }
        for viewer in viewers ?? [] {
            let files = viewer.patterns.joined(separator: ", ")
            said.append(viewer.writes == true ? String(localized: "Its viewer can read and change \(files) files you open.") : String(localized: "Its viewer can read \(files) files you open."))
        }
        let words = (commands ?? []).compactMap(\.ask)
        if !words.isEmpty {
            let list = words.prefix(5).map { "• " + $0 }.joined(separator: "\n")
            said.append(String(localized: "It can leave these words in your agent's input, for you to send:\n\(list)"))
        }
        return said
    }

    /// `additions` in the language Tiri is in, for the screen.
    public var shownAdditions: [String] {
        func count(_ number: Int, _ one: () -> String, _ many: (Int) -> String) -> String? {
            number == 0 ? nil : number == 1 ? one() : many(number)
        }
        return [
            count(commands?.count ?? 0, { String(localized: "1 command") }, { String(localized: "\($0) commands") }),
            count(panels?.count ?? 0, { String(localized: "1 panel") }, { String(localized: "\($0) panels") }),
            count(viewers?.count ?? 0, { String(localized: "1 file viewer") }, { String(localized: "\($0) file viewers") }),
            count(sidebar?.count ?? 0, { String(localized: "1 sidebar section") }, { String(localized: "\($0) sidebar sections") }),
            count(statusBar?.count ?? 0, { String(localized: "1 status bar item") }, { String(localized: "\($0) status bar items") }),
            count(fileButtons?.count ?? 0, { String(localized: "1 button above files") }, { String(localized: "\($0) buttons above files") }),
            count(highlights?.count ?? 0, { String(localized: "1 color in the editor") }, { String(localized: "\($0) colors in the editor") }),
            count(fileMarks?.count ?? 0, { String(localized: "marks on files in the explorer") }, { _ in String(localized: "marks on files in the explorer") }),
            count(settings?.count ?? 0, { String(localized: "1 setting") }, { String(localized: "\($0) settings") }),
            count(languages?.count ?? 0, { String(localized: "1 language") }, { String(localized: "\($0) languages") }),
            count(grammars?.count ?? 0, { String(localized: "1 grammar") }, { String(localized: "\($0) grammars") }),
            count(processes?.count ?? 0, { String(localized: "1 background process") }, { String(localized: "\($0) background processes") }),
            agent?.claude != nil ? String(localized: "a part for Claude Code") : nil,
        ].compactMap { $0 }
    }

    /// `2 commands, 1 panel`, in plain words.
    public var additions: [String] {
        func count(_ number: Int, _ one: String, _ many: String) -> String? {
            number == 0 ? nil : number == 1 ? "1 \(one)" : "\(number) \(many)"
        }
        return [
            count(commands?.count ?? 0, "command", "commands"),
            count(panels?.count ?? 0, "panel", "panels"),
            count(viewers?.count ?? 0, "file viewer", "file viewers"),
            count(sidebar?.count ?? 0, "sidebar section", "sidebar sections"),
            count(statusBar?.count ?? 0, "status bar item", "status bar items"),
            count(fileButtons?.count ?? 0, "button above files", "buttons above files"),
            count(highlights?.count ?? 0, "color in the editor", "colors in the editor"),
            (fileMarks ?? []).isEmpty ? nil : "marks on files in the explorer",
            count(settings?.count ?? 0, "setting", "settings"),
            count(languages?.count ?? 0, "language", "languages"),
            count(grammars?.count ?? 0, "grammar", "grammars"),
            count(processes?.count ?? 0, "background process", "background processes"),
            agent?.claude != nil ? "a part for Claude Code" : nil,
        ].compactMap { $0 }
    }

    /// Whether anything it declares runs outside a sandbox.
    public var runsPrograms: Bool { !programs.isEmpty }
}

// MARK: - Version ranges

/// `1.2.3`, compared number by number. A missing number counts as 0.
public struct PluginVersion: Comparable, Sendable, Equatable {
    public var parts: [Int]

    public init?(_ text: String) {
        let core = text.split(separator: "-").first.map(String.init) ?? text
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public static func < (a: PluginVersion, b: PluginVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (a: PluginVersion, b: PluginVersion) -> Bool { !(a < b) && !(b < a) }
}

public enum PluginVersionRange {
    /// Space-separated conditions, all of which must hold: `>=0.1.0 <2`. Nil if it can't be read.
    public static func contains(_ version: String, range: String) -> Bool? {
        guard let wanted = PluginVersion(version) else { return nil }
        var result = true
        let conditions = range.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !conditions.isEmpty else { return nil }
        for condition in conditions {
            let symbols = condition.prefix { "<>=".contains($0) }
            guard let bound = PluginVersion(String(condition.dropFirst(symbols.count))) else { return nil }
            switch symbols {
            case ">=": result = result && wanted >= bound
            case ">": result = result && wanted > bound
            case "<=": result = result && wanted <= bound
            case "<": result = result && wanted < bound
            case "=", "": result = result && wanted == bound
            default: return nil
            }
        }
        return result
    }
}

// MARK: - File patterns

public enum PluginPattern {
    /// `*.csv`, `Cargo.toml` or `src/**/*.rs`, against a whole path. Without a slash, the file's name.
    public static func matches(_ pattern: String, path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if !pattern.contains("/") { return wildcard(Array(pattern.lowercased().utf8)[...], Array(name.lowercased().utf8)[...]) }
        var trimmed = pattern.lowercased()
        if !trimmed.hasPrefix("**/"), !trimmed.hasPrefix("/") { trimmed = "**/" + trimmed }
        return wildcard(Array(trimmed.utf8)[...], Array(path.lowercased().utf8)[...])
    }

    private static let star = UInt8(ascii: "*")
    private static let mark = UInt8(ascii: "?")
    private static let slash = UInt8(ascii: "/")

    private static func wildcard(_ pattern: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>) -> Bool {
        guard let first = pattern.first else { return text.isEmpty }
        if first == star {
            let isDouble = pattern.dropFirst().first == star
            let rest = pattern.dropFirst(isDouble ? 2 : 1)
            // `**/` can also match nothing at all.
            if isDouble, rest.first == slash, wildcard(rest.dropFirst(), text) { return true }
            var remaining = text
            while true {
                if wildcard(rest, remaining) { return true }
                guard let next = remaining.first, isDouble || next != slash else { return false }
                remaining = remaining.dropFirst()
            }
        }
        guard let character = text.first else { return false }
        if first == mark ? character != slash : first == character {
            return wildcard(pattern.dropFirst(), text.dropFirst())
        }
        return false
    }
}

// MARK: - Filling in commands

public struct PluginContext: Sendable, Equatable {
    public var file: String?
    public var folder: String?
    public var plugin: String
    public var line: Int?
    public var selection: String?
    public var args: [String: JSONValue]

    public init(plugin: String, file: String? = nil, folder: String? = nil, line: Int? = nil, selection: String? = nil, args: [String: JSONValue] = [:]) {
        self.plugin = plugin
        self.file = file
        self.folder = folder
        self.line = line
        self.selection = selection
        self.args = args
    }
}

public enum PluginTemplate {
    /// `"${file}"`: the value's own quotes would end the author's, and the rest would run.
    public static func hasQuotedValue(_ line: String) -> Bool {
        var quote: Character?
        var previous: Character?
        for character in line {
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
                if character == "{", previous == "$" { return true }
            } else if character == "'" || character == "\"" {
                quote = character
            }
            previous = character
        }
        return false
    }

    /// Nothing that a terminal or an agent's input would take as an instruction.
    public static func plain(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !($0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)) }))
    }

    /// Fills in `${…}`. `quoting` says what happens to each value on its way in, so a value with spaces
    /// or quotes in it stays one value. What's not known becomes nothing.
    public static func fill(_ template: String, _ context: PluginContext, quoting: (String) -> String = { $0 }) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = String(rest[open.upperBound..<close])
            result += quoting(value(of: name, context) ?? "")
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    private static func value(of name: String, _ context: PluginContext) -> String? {
        switch name {
        case "file": return context.file
        case "folder": return context.folder
        case "plugin": return context.plugin
        case "line": return context.line.map(String.init)
        case "selection": return context.selection
        default:
            guard name.hasPrefix("args.") else { return nil }
            return context.args[String(name.dropFirst(5))].map(text)
        }
    }

    public static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return SettingsSchema.format(number)
        case .bool(let on): return on ? "true" : "false"
        case .null: return ""
        default: return SettingsSchema.json(value)
        }
    }
}

// MARK: - What providers answer with

/// One row in a plugin's sidebar section.
public struct PluginTreeItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var symbol: String?
    public var tooltip: String?
    /// Opening this file is what a click does, if there's no command.
    public var path: String?
    public var command: String?
    public var args: [String: JSONValue]
    public var children: [PluginTreeItem]
    /// Tints its title and symbol: a name like `orange`, or `#rrggbb`.
    public var color: String?
    /// Tints only its symbol.
    public var symbolColor: String?
    /// Its own right-click menu, after the section's.
    public var menu: [PluginManifest.MenuItem]

    /// Reads `{"items":[…]}` or a bare list. A plugin's answer isn't trusted to be well made, or small.
    public static func list(from value: JSONValue, limit: Int = 5_000) -> [PluginTreeItem] {
        var remaining = limit
        return list(value["items"]?.arrayValue ?? value.arrayValue ?? [], parent: "", depth: 0, remaining: &remaining)
    }

    private static func list(_ values: [JSONValue], parent: String, depth: Int, remaining: inout Int) -> [PluginTreeItem] {
        guard depth < 12 else { return [] }
        var items: [PluginTreeItem] = []
        var seen = Set<String>()
        for (index, value) in values.enumerated() {
            guard remaining > 0, let title = value["title"]?.stringValue else { continue }
            remaining -= 1
            var id = parent + "/" + (value["id"].map(PluginTemplate.text) ?? "\(index)")
            if !seen.insert(id).inserted { id += "#\(index)" }
            let children = list(value["children"]?.arrayValue ?? [], parent: id, depth: depth + 1, remaining: &remaining)
            let menu = (value["menu"]?.arrayValue ?? []).prefix(20).compactMap { entry -> PluginManifest.MenuItem? in
                guard let title = entry["title"]?.stringValue, let command = entry["command"]?.stringValue else { return nil }
                return PluginManifest.MenuItem(title: title, command: command, symbol: entry["symbol"]?.stringValue)
            }
            items.append(PluginTreeItem(id: id, title: title, detail: value["detail"]?.stringValue, symbol: value["symbol"]?.stringValue,
                                        tooltip: value["tooltip"]?.stringValue, path: value["path"]?.stringValue,
                                        command: value["command"]?.stringValue, args: value["args"]?.objectValue ?? [:], children: children,
                                        color: value["color"]?.stringValue, symbolColor: value["symbolColor"]?.stringValue, menu: Array(menu)))
        }
        return items
    }
}

/// What a status bar item shows right now.
public struct PluginStatusContent: Sendable, Equatable {
    public var text: String
    public var symbol: String?
    public var tooltip: String?
    public var command: String?
    public var args: [String: JSONValue]

    public init(text: String, symbol: String? = nil, tooltip: String? = nil, command: String? = nil, args: [String: JSONValue] = [:]) {
        self.text = text
        self.symbol = symbol
        self.tooltip = tooltip
        self.command = command
        self.args = args
    }

    public init?(_ value: JSONValue) {
        guard let text = value["text"]?.stringValue else { return nil }
        self.init(text: text, symbol: value["symbol"]?.stringValue, tooltip: value["tooltip"]?.stringValue,
                  command: value["command"]?.stringValue, args: value["args"]?.objectValue ?? [:])
    }
}
