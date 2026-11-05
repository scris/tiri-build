import CryptoKit
import Foundation

// MARK: - Checking a plugin

public struct PluginIssue: Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Severity: String, Sendable, Codable { case error, warning }
    public var severity: Severity
    public var message: String
    public var description: String { "\(severity.rawValue): \(message)" }

    static func error(_ message: String) -> PluginIssue { PluginIssue(severity: .error, message: message) }
    static func warning(_ message: String) -> PluginIssue { PluginIssue(severity: .warning, message: message) }
}

public enum PluginValidator {
    private static func isPlainID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first, (first >= 97 && first <= 122) || (first >= 48 && first <= 57), name.utf8.count <= 64 else { return false }
        return name.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// A path inside the plugin, however it's written. Nil if it would leave the folder.
    public static func resolve(_ relative: String, in folder: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let target = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root || target.path.hasPrefix(root + "/") else { return nil }
        return target
    }

    /// Whether the first word of a command is one of the plugin's own files.
    static func isOwnProgram(_ word: String) -> Bool {
        word.hasPrefix("${plugin}/") || (word.contains("/") && !word.hasPrefix("/") && !word.hasPrefix("~"))
    }

    public static func validate(_ manifest: PluginManifest, folder: URL, tiriVersion: String = TiriCoreVersion.string) -> [PluginIssue] {
        var issues: [PluginIssue] = []
        func error(_ text: String) { issues.append(.error(text)) }
        func warn(_ text: String) { issues.append(.warning(text)) }

        if !isValidName(manifest.name) { error("name \"\(manifest.name)\" should be lowercase letters, numbers and dashes") }
        if PluginVersion(manifest.version) == nil { error("version \"\(manifest.version)\" isn't a version like 1.2.3") }
        if manifest.apiVersion != PluginManifest.currentAPI {
            error("it's written for plugin API \(manifest.apiVersion), and this Tiri speaks \(PluginManifest.currentAPI)")
        }
        if let range = manifest.tiri {
            switch PluginVersionRange.contains(tiriVersion, range: range) {
            case nil: error("tiri \"\(range)\" isn't a version range like >=0.1.0 <2")
            case false?: error("it needs Tiri \(range), and this is \(tiriVersion)")
            default: break
            }
        } else {
            warn("it doesn't say which versions of Tiri it works with: add \"tiri\": \">=\(tiriVersion)\"")
        }

        func checkProgram(_ words: [String], _ place: String) {
            guard let first = words.first, !first.isEmpty else {
                error("\(place) has nothing to run")
                return
            }
            let path = first.hasPrefix("${plugin}/") ? String(first.dropFirst(10)) : first
            guard isOwnProgram(first) else { return }
            if PluginTree.isInSkippedFolder(path) {
                error("\(place) runs \(first), inside a folder that isn't part of what's approved")
                return
            }
            guard let file = resolve(path, in: folder) else {
                error("\(place) runs \(first), which is outside the plugin")
                return
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                error("\(place) runs \(first), which doesn't exist")
                return
            }
            if !FileManager.default.isExecutableFile(atPath: file.path) { error("\(place) runs \(first), which isn't executable: chmod +x it") }
        }

        func checkFile(_ relative: String, _ place: String) {
            if PluginTree.isInSkippedFolder(relative) {
                error("\(place): \(relative) is inside a folder that isn't part of what's approved")
                return
            }
            guard let file = resolve(relative, in: folder) else {
                error("\(place): \(relative) is outside the plugin")
                return
            }
            if !FileManager.default.fileExists(atPath: file.path) { error("\(place): \(relative) doesn't exist") }
        }

        func checkUnique(_ ids: [String], _ what: String) {
            var seen = Set<String>()
            for id in ids where !seen.insert(id).inserted { error("two \(what) are called \"\(id)\"") }
            for id in ids where !isPlainID(id) { error("\(what) id \"\(id)\" should be letters, numbers, dashes and underscores") }
        }

        let commands = manifest.commands ?? []
        let processes = manifest.processes ?? []
        let panels = manifest.panels ?? []
        checkUnique(commands.map(\.id), "commands")
        checkUnique(processes.map(\.id), "processes")
        checkUnique(panels.map(\.id), "panels")
        let commandIDs = Set(commands.map(\.id))
        let processIDs = Set(processes.map(\.id))
        let panelIDs = Set(panels.map(\.id))

        func isOwnCommand(_ id: String) -> Bool {
            commandIDs.contains(id.hasPrefix(manifest.name + ".") ? String(id.dropFirst(manifest.name.count + 1)) : id)
        }

        func checkOwnCommand(_ id: String, _ place: String) {
            if !isOwnCommand(id) { error("\(place) runs \"\(id)\", which isn't one of its own commands") }
        }

        func checkProvider(_ provider: PluginManifest.Provider, _ place: String) {
            switch (provider.exec, provider.process) {
            case (let exec?, nil): checkProgram(exec, place)
            case (nil, let process?):
                if !processIDs.contains(process) { error("\(place) asks process \"\(process)\", which isn't declared") }
                if provider.method == nil { error("\(place) asks a process, and needs a \"method\"") }
            default: error("\(place) needs either \"exec\" or \"process\"")
            }
        }

        func checkRefresh(_ refresh: PluginManifest.Refresh?, _ place: String) {
            if let every = refresh?.every, every < 30 { error("\(place) refreshes every \(Int(every)) seconds, and 30 is the shortest allowed") }
        }

        for command in commands {
            let place = "command \"\(command.id)\""
            if command.actions.count != 1 { error("\(place) should do one thing: one of exec, terminal, panel, ask or process") }
            if let exec = command.exec { checkProgram(exec, place) }
            if let line = command.terminal, let first = line.split(separator: " ").first.map(String.init) {
                checkProgram([first], place)
                if PluginTemplate.hasQuotedValue(line) { error("\(place) has ${…} inside quotes. Values are quoted for you, and quotes around them let a value run as a command") }
            }
            if let panel = command.panel, !panelIDs.contains(panel) { error("\(place) opens panel \"\(panel)\", which isn't declared") }
            if let process = command.process {
                if !processIDs.contains(process) { error("\(place) asks process \"\(process)\", which isn't declared") }
                if command.method == nil { error("\(place) asks a process, and needs a \"method\"") }
            }
            if let key = command.key {
                if let problem = Keymap.problem(with: key, command: command.id, bindings: []) { error("\(place): \(problem)") }
                else if let strokes = Keymap.parseStrokes(key), Keymap.defaults.contains(where: { Keymap.parseStrokes($0.0) == strokes }) {
                    warn("\(place) wants \(key), which Tiri already uses, so it won't get it")
                }
            }
        }

        var settingKeys = Set<String>()
        for setting in manifest.settings ?? [] {
            let place = "setting \"\(setting.key)\""
            if !settingKeys.insert(setting.key).inserted { error("two settings are called \"\(setting.key)\"") }
            if !isPlainID(setting.key.replacingOccurrences(of: ".", with: "_")) { error("\(place) should be letters, numbers, dots, dashes and underscores") }
            if setting.type == .choice, setting.options?.isEmpty != false { error("\(place) is a choice, and needs \"options\"") }
            if setting.type == .number, let low = setting.min, let high = setting.max, low >= high { error("\(place) has min at or above max") }
        }

        var scopes = Set<String>()
        for grammar in manifest.grammars ?? [] {
            let place = "grammar \(grammar.scope)"
            scopes.insert(grammar.scope)
            if PluginTree.isInSkippedFolder(grammar.path) { error("\(place): \(grammar.path) is inside a folder that isn't part of what's approved") }
            guard let file = resolve(grammar.path, in: folder) else {
                error("\(place): \(grammar.path) is outside the plugin")
                continue
            }
            guard let data = try? Data(contentsOf: file) else {
                error("\(place): can't read \(grammar.path)")
                continue
            }
            guard let parsed = PluginGrammars.parse(data) else {
                error("\(place): \(grammar.path) isn't a JSON or property list grammar")
                continue
            }
            if let stated = parsed["scopeName"] as? String, stated != grammar.scope {
                error("\(place): the file says its scope is \(stated)")
            }
        }

        let known = Set(LanguageCatalog.all.compactMap(\.grammar))
        var languageIDs = Set<String>()
        for language in manifest.languages ?? [] {
            let place = "language \"\(language.id)\""
            if !languageIDs.insert(language.id).inserted { error("two languages are called \"\(language.id)\"") }
            if !isPlainID(language.id) { error("\(place) id should be letters, numbers, dashes and underscores") }
            if (language.extensions ?? []).isEmpty, (language.fileNames ?? []).isEmpty, (language.interpreters ?? []).isEmpty,
               LanguageCatalog.language(id: language.id) == nil {
                error("\(place) doesn't say which files it's for")
            }
            for ext in language.extensions ?? [] where ext.hasPrefix(".") { error("\(place): write the extension \(ext) without its dot") }
            if let scope = language.grammar, !scopes.contains(scope), !known.contains(scope) {
                error("\(place) uses grammar \(scope), which neither this plugin nor Tiri has")
            }
            if let block = language.comment?.block, block.count != 2 { error("\(place): a block comment is [opening, closing]") }
            if let server = language.server {
                if server.commands.isEmpty { error("\(place) has a server with no commands") }
                for command in server.commands { checkProgram(command, "\(place)'s server") }
            }
        }

        for panel in panels {
            let place = "panel \"\(panel.id)\""
            checkFile(panel.entry, place)
            if !panel.entry.hasSuffix(".html") && !panel.entry.hasSuffix(".htm") { warn("\(place): \(panel.entry) doesn't look like a page") }
            if let page = resolve(panel.entry, in: folder).flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
               page.range(of: #"<script(?![^>]*\bsrc=)[^>]*>\s*\S"#, options: .regularExpression) != nil {
                error("\(place): \(panel.entry) has a script inside the page, and panels only run scripts from their own files")
            }
            for address in panel.allow?.network ?? [] where PluginNetwork.source(address) == nil {
                error("\(place): \"\(address)\" isn't an address like https://example.com")
            }
            for process in panel.allow?.processes ?? [] where !processIDs.contains(process) {
                error("\(place) is allowed process \"\(process)\", which isn't declared")
            }
            for command in panel.allow?.commands ?? [] where !isOwnCommand(command) {
                warn("\(place) can run \"\(command)\", which isn't one of its own. tiri plugin verify checks it against this Tiri")
            }
        }
        for viewer in manifest.viewers ?? [] {
            if !panelIDs.contains(viewer.panel) { error("a viewer uses panel \"\(viewer.panel)\", which isn't declared") }
            if viewer.patterns.isEmpty { error("the viewer for \"\(viewer.panel)\" has no file patterns") }
        }
        checkUnique((manifest.sidebar ?? []).map(\.id), "sidebar sections")
        for section in manifest.sidebar ?? [] {
            let place = "sidebar section \"\(section.id)\""
            if let provider = section.provider { checkProvider(provider, place) } else { warn("\(place) has no provider, so it fills only through tiri plugin update") }
            checkRefresh(section.refresh, place)
            for button in section.buttons ?? [] { checkOwnCommand(button.command, place) }
        }
        checkUnique((manifest.statusBar ?? []).map(\.id), "status bar items")
        for item in manifest.statusBar ?? [] {
            let place = "status bar item \"\(item.id)\""
            if item.text == nil, item.provider == nil { warn("\(place) has no text and no provider, so it fills only through tiri plugin update") }
            if let provider = item.provider { checkProvider(provider, place) }
            checkRefresh(item.refresh, place)
            if let command = item.command { checkOwnCommand(command, place) }
        }
        for button in manifest.fileButtons ?? [] {
            if button.patterns.isEmpty { error("button \"\(button.title)\" has no file patterns") }
            checkOwnCommand(button.command, "button \"\(button.title)\"")
        }
        for process in processes { checkProgram(process.exec, "process \"\(process.id)\"") }
        if let test = manifest.test { checkProgram(test, "test") }
        if let claude = manifest.agent?.claude {
            if PluginTree.isInSkippedFolder(claude) { error("agent.claude: \(claude) is inside a folder that isn't part of what's approved") }
            if let folder = resolve(claude, in: folder) {
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                    error("agent.claude: \(claude) isn't a folder")
                }
            } else {
                error("agent.claude: \(claude) is outside the plugin")
            }
        }
        // Whatever it installs is pinned, or it could change after you approved it.
        if let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (package["dependencies"] as? [String: Any])?.isEmpty == false,
           !FileManager.default.fileExists(atPath: folder.appendingPathComponent("package-lock.json").path) {
            error("package.json has dependencies with no package-lock.json. Run npm install --package-lock-only --ignore-scripts")
        }
        for link in PluginTree.escapingLinks(in: folder) { error("\(link) is a link that leaves the plugin") }
        for special in PluginTree.specialFiles(in: folder) { error("\(special) isn't a regular file") }
        return issues
    }
}

// MARK: - Network addresses

public enum PluginNetwork {
    /// What a content policy calls this address. Nil if it isn't a plain origin.
    public static func source(_ address: String) -> String? {
        guard let parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(), ["https", "http", "wss", "ws"].contains(scheme),
              parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty, parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil else { return nil }
        guard host.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 42 }) else { return nil }
        // A star only as a whole left-hand label, as content policies mean it.
        if host.contains("*"), !(host.hasPrefix("*.") && !host.dropFirst(2).contains("*")) { return nil }
        return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    }

    /// Scripts come only from the plugin. Nothing here reaches anywhere that wasn't declared.
    public static func contentPolicy(allowing addresses: [String], scheme: String) -> String {
        let sources = addresses.compactMap(source).joined(separator: " ")
        let extra = sources.isEmpty ? "" : " " + sources
        return [
            "default-src 'none'",
            "script-src \(scheme):",
            "style-src \(scheme): 'unsafe-inline'",
            "img-src \(scheme): data: blob:\(extra)",
            "font-src \(scheme): data:",
            "media-src \(scheme): blob:\(extra)",
            "connect-src \(scheme):\(extra)",
            "frame-src 'none'",
            "object-src 'none'",
            "worker-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }
}

// MARK: - A plugin's files

public enum PluginTree {
    /// Only at the plugin's top level, and nothing it declares can live inside them. `node_modules` and
    /// `.venv` are rebuilt from a lockfile, and watched separately, by `dependencyFingerprint`.
    static let skippedAtTop: Set<String> = [".git", "node_modules", ".venv"]

    /// Whether a path the manifest names would escape being hashed.
    static func isInSkippedFolder(_ relative: String) -> Bool {
        let first = relative.split(separator: "/").first { $0 != "." }.map(String.init) ?? ""
        return skippedAtTop.contains(first)
    }

    public struct Listing: Sendable, Equatable {
        /// Relative path to a cheap stand-in for its contents: size and modification time.
        public var stats: [String: String]
    }

    public static func list(_ folder: URL) -> Listing {
        var stats: [String: String] = [:]
        let root = folder.resolvingSymlinksInPath().path
        func walk(_ path: String, _ relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in names where name != ".DS_Store" && !(relative.isEmpty && skippedAtTop.contains(name)) {
                let full = path + "/" + name
                let inner = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    walk(full, inner)
                } else {
                    stats[inner] = "\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)-\(info.st_mode)"
                }
            }
        }
        walk(root, "")
        return Listing(stats: stats)
    }

    /// Sizes and times of what's installed from a lockfile, which is too much to hash at each launch.
    /// Empty when there's nothing installed.
    public static func dependencyFingerprint(_ folder: URL) -> String {
        var hash = SHA256()
        var found = false
        let root = folder.resolvingSymlinksInPath().path
        for name in ["node_modules", ".venv"] {
            guard let walker = FileManager.default.enumerator(atPath: root + "/" + name) else { continue }
            var entries: [String] = []
            while let inner = walker.nextObject() as? String {
                if inner.hasPrefix(".cache") { walker.skipDescendants(); continue }
                if inner == ".package-lock.json" { continue }
                var info = stat()
                guard lstat(root + "/" + name + "/" + inner, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
                entries.append("\(inner)-\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)-\(info.st_mode)")
            }
            for entry in entries.sorted() {
                found = true
                hash.update(data: Data(entry.utf8))
            }
        }
        return found ? hash.finalize().map { String(format: "%02x", $0) }.joined() : ""
    }

    /// Everything that says whether anything's changed, cheaply: for right before something runs.
    public static func fullFingerprint(_ folder: URL) -> String {
        fingerprint(list(folder)) + "|" + dependencyFingerprint(folder)
    }

    public static func fingerprint(_ listing: Listing) -> String {
        var hash = SHA256()
        for key in listing.stats.keys.sorted() {
            hash.update(data: Data(key.utf8))
            hash.update(data: Data((listing.stats[key] ?? "").utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Each file's hash. A link counts as where it points, and a program as being one.
    public static func hashes(_ folder: URL, listing: Listing) -> [String: String] {
        var hashes: [String: String] = [:]
        let root = folder.resolvingSymlinksInPath().path
        for relative in listing.stats.keys {
            let full = root + "/" + relative
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            var hash = SHA256()
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                hash.update(data: Data(((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "").utf8))
                hash.update(data: Data("link".utf8))
            case S_IFREG:
                if let data = try? Data(contentsOf: URL(fileURLWithPath: full), options: .mappedIfSafe) { hash.update(data: data) }
                hash.update(data: Data((info.st_mode & 0o111 != 0 ? "x" : "-").utf8))
            default:
                // A pipe would never finish being read. The validator refuses a plugin that has one.
                hash.update(data: Data("special".utf8))
            }
            hashes[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    public static func treeHash(_ hashes: [String: String]) -> String {
        var hash = SHA256()
        for key in hashes.keys.sorted() {
            hash.update(data: Data(key.utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data((hashes[key] ?? "").utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pipes, sockets and devices: nothing a plugin has any use for, and reading one could hang.
    static func specialFiles(in folder: URL) -> [String] {
        let root = folder.resolvingSymlinksInPath().path
        return list(folder).stats.keys.sorted().filter { relative in
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0 else { return false }
            let kind = info.st_mode & S_IFMT
            return kind != S_IFREG && kind != S_IFLNK
        }
    }

    static func escapingLinks(in folder: URL) -> [String] {
        let root = folder.resolvingSymlinksInPath().path
        return list(folder).stats.keys.sorted().filter { relative in
            let full = root + "/" + relative
            var info = stat()
            guard lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return false }
            let target = URL(fileURLWithPath: full).resolvingSymlinksInPath().standardizedFileURL.path
            return !(target == root || target.hasPrefix(root + "/"))
        }
    }
}

// MARK: - Grammars

/// Which grammars plugins have added, for the highlighter to find.
public enum PluginGrammars {
    public struct Entry: Sendable, Equatable {
        public var scope: String
        public var file: URL
        public var injectTo: [String]
        public init(scope: String, file: URL, injectTo: [String]) {
            self.scope = scope
            self.file = file
            self.injectTo = injectTo
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    public static func set(_ list: [Entry]) {
        lock.withLock { entries = Dictionary(list.map { ($0.scope, $0) }, uniquingKeysWith: { _, last in last }) }
    }

    public static var all: [Entry] { lock.withLock { Array(entries.values) } }

    /// Its text as JSON, which is all the engine reads.
    public static func json(scope: String) -> String? {
        guard let entry = lock.withLock({ entries[scope] }), let data = try? Data(contentsOf: entry.file) else { return nil }
        if let text = String(data: data, encoding: .utf8), text.first(where: { !$0.isWhitespace }) == "{" { return text }
        guard let parsed = parse(data), let json = try? JSONSerialization.data(withJSONObject: parsed) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    /// JSON, or the property list VS Code extensions often use instead.
    public static func parse(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

// MARK: - One plugin, as found

public struct InstalledPlugin: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case off
        case on
        /// It was on, and its files aren't the ones you approved.
        case changed(PluginChanges)
        /// It can't run: its manifest is wrong, or it's for another version of Tiri.
        case broken(String)
    }

    public var name: String
    public var folder: URL
    public var manifest: PluginManifest?
    public var issues: [PluginIssue]
    public var hash: String
    public var files: [String: String]
    public var state: State
    /// Sizes and times, to tell cheaply that nothing has changed since it was hashed.
    public var fingerprint = ""

    public var id: String { name }
    public var title: String { manifest?.displayName ?? name }
    public var isOn: Bool { state == .on }
}

public struct PluginChanges: Sendable, Equatable {
    public var added: [String]
    public var changed: [String]
    public var removed: [String]
    /// What's installed from its lockfile isn't what was installed when you approved it.
    public var dependencies = false

    public init(from old: [String: String], to new: [String: String]) {
        added = new.keys.filter { old[$0] == nil }.sorted()
        removed = old.keys.filter { new[$0] == nil }.sorted()
        changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
    }

    public var summary: String {
        var lines: [String] = []
        func show(_ word: String, _ list: [String]) {
            guard !list.isEmpty else { return }
            lines.append("\(word): " + list.prefix(8).joined(separator: ", ") + (list.count > 8 ? " and \(list.count - 8) more" : ""))
        }
        show("Changed", changed)
        show("Added", added)
        show("Removed", removed)
        if dependencies { lines.append("Its installed dependencies changed") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The folder, and what's been approved

public enum PluginLibrary {
    /// Plugins live here, on this Mac. Nothing in a project or on a server is ever loaded.
    public static var folder: URL { TiriPaths.configDirectory.appendingPathComponent("plugins", isDirectory: true) }

    private static var approvalsFile: URL { TiriPaths.supportDirectory.appendingPathComponent("plugin-approvals.json") }
    private static var cacheFile: URL { TiriPaths.supportDirectory.appendingPathComponent("plugin-cache.json") }

    public struct Approval: Codable, Sendable, Equatable {
        public var hash: String
        public var version: String
        public var files: [String: String]
        public var enabled: Bool
        public var dependencies: String?
    }

    /// What a folder was, while nothing in it changes: its hash, and what checking its manifest found.
    /// Only for this version of Tiri, since a new one might read the same manifest differently.
    private struct CachedTree: Codable {
        var fingerprint: String
        var hash: String
        var files: [String: String]
        var checkedBy: String?
        var manifest: PluginManifest?
        var issues: [PluginIssue]?
    }

    public static func approvals() -> [String: Approval] {
        guard let data = try? Data(contentsOf: approvalsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Approval].self, from: data)) ?? [:]
    }

    private static func write(_ approvals: [String: Approval]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(approvals) else { return }
        try? FileManager.default.createDirectory(at: TiriPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: approvalsFile, options: .atomic)
    }

    /// Only ever called after a person said yes in Tiri.
    public static func approve(_ plugin: InstalledPlugin) {
        var all = approvals()
        all[plugin.name] = Approval(hash: plugin.hash, version: plugin.manifest?.version ?? "", files: plugin.files, enabled: true,
                                    dependencies: PluginTree.dependencyFingerprint(plugin.folder))
        write(all)
    }

    /// Turned off. The record stays, so turning it on again can say what changed since.
    public static func turnOff(_ name: String) {
        var all = approvals()
        all[name]?.enabled = false
        write(all)
    }

    public static func forget(_ name: String) {
        var all = approvals()
        all[name] = nil
        write(all)
    }

    /// Reads every plugin. Off the main thread. Hashing is skipped for folders that haven't changed,
    /// so this costs a directory walk per plugin. What each one's allowed to do is decided here.
    /// `trustingCache: false` is for the moment of approving: what's hashed is what's really there.
    public static func scan(trustingCache: Bool = true) -> [InstalledPlugin] {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let approved = approvals()
        var cache = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: CachedTree].self, from: $0) } ?? [:]
        var cacheChanged = false
        var found: [InstalledPlugin] = []
        for entry in names {
            let directory = folder.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard manager.fileExists(atPath: PluginManifest.url(in: directory).path) else { continue }
            let listing = PluginTree.list(directory)
            let fingerprint = PluginTree.fingerprint(listing)
            var tree: CachedTree
            if trustingCache, let known = cache[entry], known.fingerprint == fingerprint {
                tree = known
            } else {
                let hashes = PluginTree.hashes(directory, listing: listing)
                tree = CachedTree(fingerprint: fingerprint, hash: PluginTree.treeHash(hashes), files: hashes)
            }
            // Reading and checking a manifest only happens when its folder has changed.
            if tree.checkedBy != checkVersion || tree.manifest == nil {
                if let manifest = try? PluginManifest.load(from: directory) {
                    tree.manifest = manifest
                    tree.issues = PluginValidator.validate(manifest, folder: directory)
                    tree.checkedBy = checkVersion
                }
                cache[entry] = tree
                cacheChanged = true
            }
            var plugin = examine(directory: directory, entry: entry, tree: tree, approved: approved)
            plugin.fingerprint = fingerprint + "|" + PluginTree.dependencyFingerprint(directory)
            found.append(plugin)
        }
        for name in cache.keys where !names.contains(name) {
            cache[name] = nil
            cacheChanged = true
        }
        if cacheChanged, let data = try? JSONEncoder().encode(cache) {
            try? manager.createDirectory(at: TiriPaths.supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return found
    }

    /// A build's checks can change as well as its number, so a debug copy never trusts another's.
    private static let checkVersion = "\(TiriCoreVersion.string)-\(PluginManifest.currentAPI)-\(LanguageCatalog.all.count)"

    private static func examine(directory: URL, entry: String, tree: CachedTree, approved: [String: Approval]) -> InstalledPlugin {
        let hash = tree.hash
        let files = tree.files
        guard let manifest = tree.manifest else {
            var why = "Couldn't read it"
            do { _ = try PluginManifest.load(from: directory) } catch { why = PluginManifest.explain(error) }
            return InstalledPlugin(name: entry, folder: directory, manifest: nil, issues: [.error(why)], hash: hash, files: files, state: .broken(why))
        }
        var issues = tree.issues ?? []
        // Only a folder with the right name can claim it, so a stray copy can't take a plugin's place.
        guard manifest.name == entry else {
            let why = "its folder is \(entry), and its manifest says it's called \(manifest.name)"
            issues.append(.error(why))
            return InstalledPlugin(name: entry, folder: directory, manifest: manifest, issues: issues, hash: hash, files: files, state: .broken(why))
        }
        let state: InstalledPlugin.State
        if let first = issues.first(where: { $0.severity == .error }) {
            state = .broken(first.message)
        } else if let approval = approved[manifest.name], approval.enabled {
            let installed = PluginTree.dependencyFingerprint(directory)
            if approval.hash == hash, (approval.dependencies ?? "") == installed {
                state = .on
            } else {
                var changes = PluginChanges(from: approval.files, to: files)
                changes.dependencies = (approval.dependencies ?? "") != installed
                state = .changed(changes)
            }
        } else {
            state = .off
        }
        return InstalledPlugin(name: manifest.name, folder: directory, manifest: manifest, issues: issues, hash: hash, files: files, state: state)
    }

    // MARK: Languages

    public static func languages(of plugin: InstalledPlugin) -> [LanguageDefinition] {
        (plugin.manifest?.languages ?? []).map { language in
            var comment: CommentSyntax?
            if language.comment?.line != nil || language.comment?.block?.count == 2 {
                let block = language.comment?.block
                comment = CommentSyntax(line: language.comment?.line, block: block?.count == 2 ? (block![0], block![1]) : nil)
            }
            var definition = LanguageDefinition(
                id: language.id, name: language.name ?? "", grammar: language.grammar,
                extensions: Set((language.extensions ?? []).map { $0.lowercased() }), fileNames: Set((language.fileNames ?? []).map { $0.lowercased() }),
                interpreters: Set(language.interpreters ?? []), aliases: Set((language.aliases ?? []).map { $0.lowercased() }), comment: comment,
                server: language.server == nil ? nil : serverID(plugin: plugin.name, language: language.id), lspID: language.server?.languageID)
            if definition.name.isEmpty, LanguageCatalog.language(id: language.id) == nil { definition.name = language.id }
            definition.colonOpensBlock = language.colonOpensBlock ?? false
            definition.isProse = language.isProse ?? false
            definition.isCertainlyText = true
            return definition
        }
    }

    public static func serverID(plugin: String, language: String) -> String { "\(plugin).\(language)" }

    public static func servers(of plugin: InstalledPlugin) -> [LanguageServerDefinition] {
        (plugin.manifest?.languages ?? []).compactMap { language in
            guard let server = language.server else { return nil }
            let commands = server.commands.map { command -> [String] in
                guard let first = command.first, PluginValidator.isOwnProgram(first) else { return command }
                let relative = first.hasPrefix("${plugin}/") ? String(first.dropFirst(10)) : first
                return [plugin.folder.appendingPathComponent(relative).path] + command.dropFirst()
            }
            return LanguageServerDefinition(id: serverID(plugin: plugin.name, language: language.id), language: language.name ?? language.id,
                                            commands: commands, rootMarkers: server.rootMarkers ?? [], localBins: server.localBins ?? [],
                                            installHint: server.installHint ?? "See the \(plugin.title) plugin")
        }
    }

    public static func grammars(of plugin: InstalledPlugin) -> [PluginGrammars.Entry] {
        (plugin.manifest?.grammars ?? []).compactMap { grammar in
            PluginValidator.resolve(grammar.path, in: plugin.folder).map {
                PluginGrammars.Entry(scope: grammar.scope, file: $0, injectTo: grammar.injectTo ?? [])
            }
        }
    }
}

// MARK: - Settings

/// One small file per plugin, beside Tiri's own settings. It stays when a plugin is turned off.
public enum PluginSettingsStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: [String: JSONValue]] = [:]

    private static func file(_ plugin: String) -> URL {
        TiriPaths.configDirectory.appendingPathComponent("plugin-settings/\(plugin).json")
    }

    public static func values(_ plugin: String) -> [String: JSONValue] {
        lock.withLock {
            if let known = cached[plugin] { return known }
            let read = (try? Data(contentsOf: file(plugin))).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            cached[plugin] = read
            return read
        }
    }

    public static func set(_ plugin: String, key: String, to value: JSONValue?) {
        lock.withLock {
            var current = cached[plugin] ?? (try? Data(contentsOf: file(plugin))).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            current[key] = value
            cached[plugin] = current
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(current) else { return }
            try? FileManager.default.createDirectory(at: file(plugin).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file(plugin), options: .atomic)
        }
    }

    public static func remove(_ plugin: String) {
        lock.withLock {
            cached[plugin] = nil
            try? FileManager.default.removeItem(at: file(plugin))
        }
    }

    /// For a program or a panel: every setting with its value, defaults filled in.
    public static func resolved(_ manifest: PluginManifest) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let stored = values(manifest.name)
        for setting in manifest.settings ?? [] { result[setting.key] = stored[setting.key] ?? setting.default ?? .null }
        return result
    }
}

extension SettingsSchema {
    private static let pluginLock = NSLock()
    nonisolated(unsafe) private static var pluginDefinitions: [SettingDefinition] = []

    public static func setPluginDefinitions(_ definitions: [SettingDefinition]) {
        pluginLock.withLock { pluginDefinitions = definitions }
    }

    public static var fromPlugins: [SettingDefinition] { pluginLock.withLock { pluginDefinitions } }

    /// Everything that can be set right now, Tiri's own and those of plugins that are on.
    public static var everything: [SettingDefinition] { all + fromPlugins }

    public static func pluginKey(_ plugin: String, _ key: String) -> String { "plugin.\(plugin).\(key)" }

    /// `plugin.leetcode.language` is setting `language` of plugin `leetcode`.
    public static func splitPluginKey(_ key: String) -> (plugin: String, key: String)? {
        guard key.hasPrefix("plugin.") else { return nil }
        let rest = key.dropFirst(7)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return (String(rest[..<dot]), String(rest[rest.index(after: dot)...]))
    }

    public static func definitions(for manifest: PluginManifest) -> [SettingDefinition] {
        (manifest.settings ?? []).map { setting in
            let kind: SettingDefinition.Kind
            switch setting.type {
            case .toggle: kind = .toggle
            case .choice: kind = .choice((setting.options ?? []).map { .init($0.value, $0.label ?? $0.value) })
            case .number: kind = .number(min: setting.min ?? 0, max: setting.max ?? 1_000_000, step: setting.step ?? 1)
            case .text: kind = .text(placeholder: setting.placeholder ?? "")
            case .list: kind = .list(placeholder: setting.placeholder ?? "")
            }
            let name = manifest.name
            let key = setting.key
            let fallback = setting.default ?? emptyValue(setting.type)
            return SettingDefinition(key: pluginKey(name, key), pane: .plugins, group: manifest.displayName, title: setting.title, explanation: setting.explanation ?? "", kind: kind,
                                     value: { _ in PluginSettingsStore.values(name)[key] ?? fallback })
        }
    }

    private static func emptyValue(_ kind: PluginManifest.Setting.Kind) -> JSONValue {
        switch kind {
        case .toggle: .bool(false)
        case .number: .int(0)
        case .choice, .text: .string("")
        case .list: .array([])
        }
    }
}
