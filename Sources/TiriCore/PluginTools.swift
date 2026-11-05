import Foundation

/// The parts of `tiri plugin` that work on files and need no app: an agent can write and check a
/// plugin with Tiri closed, and none of this turns anything on.
public enum PluginTools {
    public enum Action: Equatable, Sendable {
        case validate(String)
        case new(name: String, folder: String?)
        case test(String)
        case importVSIX(file: String, folder: String?)
        case install(String)
        case verify(name: String?, runTests: Bool)
    }

    public struct Outcome: Sendable, Equatable {
        public var output: String
        public var errors: String
        public var code: Int32
        public init(output: String = "", errors: String = "", code: Int32 = 0) {
            self.output = output
            self.errors = errors
            self.code = code
        }
    }

    public static func run(_ action: Action, cwd: String) -> Outcome {
        switch action {
        case .validate(let target):
            guard let folder = locate(target, cwd: cwd) else { return Outcome(errors: "No plugin at \(target).\n", code: 1) }
            return validate(folder)
        case .new(let name, let folder):
            return scaffold(name: name, parent: folder.map { URL(fileURLWithPath: CLIParser.absolute($0, cwd: cwd)) } ?? PluginLibrary.folder)
        case .test(let target):
            guard let folder = locate(target, cwd: cwd) else { return Outcome(errors: "No plugin at \(target).\n", code: 1) }
            return test(folder)
        case .importVSIX(let file, let folder):
            let parent = folder.map { URL(fileURLWithPath: CLIParser.absolute($0, cwd: cwd)) } ?? PluginLibrary.folder
            do {
                let report = try VSIXImporter.importFile(CLIParser.absolute(file, cwd: cwd), into: parent)
                return Outcome(output: report.text + askAppToLookAgain())
            } catch {
                return Outcome(errors: "\(error)\n", code: 1)
            }
        case .install(let target):
            return install(CLIParser.absolute(target, cwd: cwd))
        case .verify(let name, let runTests):
            return verify(name: name, runTests: runTests)
        }
    }

    /// A folder, or the name of an installed plugin.
    static func locate(_ target: String, cwd: String) -> URL? {
        let direct = URL(fileURLWithPath: CLIParser.absolute(target, cwd: cwd), isDirectory: true)
        if FileManager.default.fileExists(atPath: PluginManifest.url(in: direct).path) { return direct }
        let installed = PluginLibrary.folder.appendingPathComponent(target, isDirectory: true)
        return FileManager.default.fileExists(atPath: PluginManifest.url(in: installed).path) ? installed : nil
    }

    // MARK: Skills

    /// Claude Code loads these by itself. Other agents have no way to be handed a folder of skills
    /// without changing their own settings, so they find them here, by reading this guide.
    public static func skillsSection() -> String {
        var lines: [String] = []
        for plugin in PluginLibrary.scan() where plugin.isOn {
            guard let claude = plugin.manifest?.agent?.claude, let root = PluginValidator.resolve(claude, in: plugin.folder) else { continue }
            let skills = root.appendingPathComponent("skills")
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: skills.path)) ?? []).sorted() {
                let file = skills.appendingPathComponent(name).appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: file.path) { lines.append("- \(name), from \(plugin.title): \(file.path)") }
            }
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n## Skills from plugins that are on\n\nRead one of these when what it's for comes up.\n\n" + lines.joined(separator: "\n")
    }

    // MARK: Validate

    static func validate(_ folder: URL) -> Outcome {
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.load(from: folder)
        } catch {
            return Outcome(errors: "error: \(PluginManifest.explain(error))\n", code: 1)
        }
        let issues = PluginValidator.validate(manifest, folder: folder)
        var lines = ["\(manifest.name) \(manifest.version)" + (manifest.title.map { " (\($0))" } ?? "")]
        lines.append("Adds: " + (manifest.additions.isEmpty ? "nothing" : manifest.additions.joined(separator: ", ")))
        if !manifest.programs.isEmpty {
            lines.append("Runs, with your full access:")
            lines += manifest.programs.map { "  " + $0 }
        }
        if !manifest.networkAddresses.isEmpty { lines.append("Panels reach: " + manifest.networkAddresses.joined(separator: ", ")) }
        lines += manifest.panelPowers
        lines += issues.map(\.description)
        let errors = issues.filter { $0.severity == .error }.count
        lines.append(errors == 0 ? "No errors. Nothing has been turned on: tiri plugin enable \(manifest.name) asks the person using Tiri." : "\(errors) error\(errors == 1 ? "" : "s").")
        return Outcome(output: lines.joined(separator: "\n") + "\n", code: errors == 0 ? 0 : 1)
    }

    // MARK: Test

    static func test(_ folder: URL) -> Outcome {
        let checked = validate(folder)
        guard checked.code == 0 else { return checked }
        guard let manifest = try? PluginManifest.load(from: folder), let command = manifest.test, let first = command.first else {
            return Outcome(output: checked.output + "It declares no tests. Add \"test\": [\"bin/test\"] to its manifest.\n")
        }
        let process = Process()
        let isOwn = PluginValidator.isOwnProgram(first)
        process.executableURL = URL(fileURLWithPath: isOwn ? folder.appendingPathComponent(first.replacingOccurrences(of: "${plugin}/", with: "")).path : "/usr/bin/env")
        process.arguments = isOwn ? Array(command.dropFirst()) : command
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["TIRI_PLUGIN_DIR"] = folder.path
        environment["TIRI_PLUGIN_NAME"] = manifest.name
        environment["TIRI_PLUGIN_SETTINGS"] = SettingsSchema.json(.object(PluginSettingsStore.resolved(manifest)))
        // A test leaving caches in the folder would turn the plugin off.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return Outcome(errors: "Couldn't run its tests: \(error)\n", code: 1)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let code = process.terminationStatus
        return Outcome(output: checked.output + text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n")
            + (code == 0 ? "Its tests passed.\n" : "Its tests failed, with code \(code).\n"), code: code == 0 ? 0 : 1)
    }

    // MARK: New

    static func scaffold(name: String, parent: URL) -> Outcome {
        guard PluginValidator.isValidName(name) else { return Outcome(errors: "A plugin's name is lowercase letters, numbers and dashes.\n", code: 2) }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return Outcome(errors: "\(folder.path) already exists.\n", code: 1) }
        let manifest = """
        {
          "name": "\(name)",
          "title": "\(name.split(separator: "-").map(\.capitalized).joined(separator: " "))",
          "version": "0.1.0",
          "apiVersion": \(PluginManifest.currentAPI),
          "tiri": ">=\(TiriCoreVersion.string)",
          "description": "What this adds, in one line.",
          "test": ["bin/test"],
          "commands": [
            { "id": "hello", "title": "Say Hello", "category": "\(name)", "exec": ["bin/hello", "${file}"] },
            { "id": "show", "title": "Show Panel", "category": "\(name)", "panel": "main" }
          ],
          "panels": [
            { "id": "main", "title": "\(name)", "entry": "panel/index.html", "allow": { "commands": ["hello"], "agent": true } }
          ]
        }
        """
        let page = """
        <!doctype html>
        <meta charset="utf-8">
        <title>\(name)</title>
        <link rel="stylesheet" href="panel.css">
        <h1>\(name)</h1>
        <p id="where"></p>
        <button id="hello">Say Hello</button>
        <button id="ask">Ask My Agent</button>
        <script src="panel.js"></script>
        """
        let script = """
        tiri.context().then((context) => {
          document.getElementById('where').textContent = 'Tiri ' + context.version + ', theme ' + context.theme;
        });
        document.getElementById('hello').addEventListener('click', () => tiri.run('hello'));
        // This waits in your agent's input until you press Return.
        document.getElementById('ask').addEventListener('click', () => tiri.ask('What does this plugin do?'));
        """
        let style = """
        :root { color-scheme: light dark; font: 13px -apple-system, sans-serif; }
        body { margin: 24px; }
        """
        let hello = """
        #!/bin/sh
        # Whatever this prints shows as a toast. It runs where the workspace is, with your full access.
        echo "Hello from \(name), about ${1:-no file}"
        """
        let tests = """
        #!/bin/sh
        # tiri plugin test runs this. Exit with anything but 0 to fail.
        set -e
        out="$("$TIRI_PLUGIN_DIR/bin/hello" a-file)"
        case "$out" in *a-file*) echo "hello works" ;; *) echo "hello said: $out"; exit 1 ;; esac
        """
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: folder.appendingPathComponent(PluginManifest.folderName), withIntermediateDirectories: true)
            try manager.createDirectory(at: folder.appendingPathComponent("panel"), withIntermediateDirectories: true)
            try manager.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try (manifest + "\n").write(to: PluginManifest.url(in: folder), atomically: true, encoding: .utf8)
            try (page + "\n").write(to: folder.appendingPathComponent("panel/index.html"), atomically: true, encoding: .utf8)
            try (script + "\n").write(to: folder.appendingPathComponent("panel/panel.js"), atomically: true, encoding: .utf8)
            try (style + "\n").write(to: folder.appendingPathComponent("panel/panel.css"), atomically: true, encoding: .utf8)
            for (file, text) in [("bin/hello", hello), ("bin/test", tests)] {
                let url = folder.appendingPathComponent(file)
                try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        } catch {
            return Outcome(errors: "Couldn't write it: \(error)\n", code: 1)
        }
        return Outcome(output: """
        Made \(folder.path).
        Edit it, then: tiri plugin validate \(name), tiri plugin test \(name), tiri plugin enable \(name)
        The manifest and panel API: tiri plugin api

        """ + askAppToLookAgain())
    }

    // MARK: Install

    static func install(_ source: String) -> Outcome {
        let from = URL(fileURLWithPath: source, isDirectory: true)
        let checked = validate(from)
        guard checked.code == 0, let manifest = try? PluginManifest.load(from: from) else { return checked }
        let target = PluginLibrary.folder.appendingPathComponent(manifest.name, isDirectory: true)
        let manager = FileManager.default
        guard from.standardizedFileURL.resolvingSymlinksInPath().path != target.standardizedFileURL.resolvingSymlinksInPath().path else {
            return Outcome(errors: "\(manifest.name) is already there.\n", code: 1)
        }
        do {
            try manager.createDirectory(at: PluginLibrary.folder, withIntermediateDirectories: true)
            // A new copy beside the old, so a failed copy leaves what's there alone. What it replaces
            // goes to the Trash, since it may be someone's work.
            let incoming = PluginLibrary.folder.appendingPathComponent(".incoming-\(manifest.name)", isDirectory: true)
            try? manager.removeItem(at: incoming)
            try manager.copyItem(at: from, to: incoming)
            if manager.fileExists(atPath: target.path) {
                if ProcessInfo.processInfo.environment["TIRI_HOME"] != nil { try manager.removeItem(at: target) } else { try manager.trashItem(at: target, resultingItemURL: nil) }
            }
            try manager.moveItem(at: incoming, to: target)
        } catch {
            return Outcome(errors: "Couldn't install it: \(error)\n", code: 1)
        }
        return Outcome(output: "Installed \(manifest.name), and it's off. tiri plugin enable \(manifest.name) asks the person using Tiri.\n" + askAppToLookAgain())
    }

    // MARK: Verify

    /// Every installed plugin against this build. With the app running, also what only it can say:
    /// whether grammars compile in the real engine, and whether commands they name exist.
    static func verify(name: String?, runTests: Bool) -> Outcome {
        var plugins = PluginLibrary.scan()
        if let name { plugins = plugins.filter { $0.name == name } }
        if let name, plugins.isEmpty { return Outcome(errors: "No plugin called \(name).\n", code: 1) }
        var lines: [String] = []
        var failed = false
        var fromApp: [String: [String]] = [:]
        var appAnswered = false
        if let client = try? ControlClient(path: TiriPaths.socket, timeout: 60),
           let response = try? client.send(ControlRequest(cmd: "plugin.verify", args: name.map { ["name": .string($0)] } ?? [:])), response.ok {
            appAnswered = true
            for (plugin, problems) in response.result?.objectValue ?? [:] {
                fromApp[plugin] = problems.arrayValue?.compactMap(\.stringValue) ?? []
            }
        }
        for plugin in plugins {
            var problems = plugin.issues.filter { $0.severity == .error }.map(\.message)
            problems += fromApp[plugin.name] ?? []
            if runTests, plugin.manifest?.test != nil {
                let result = test(plugin.folder)
                if result.code != 0 { problems.append("its tests failed: " + result.output.split(separator: "\n").suffix(3).joined(separator: " ")) }
            }
            if problems.isEmpty {
                lines.append("ok\t\(plugin.name)\t\(plugin.manifest?.version ?? "")")
            } else {
                failed = true
                lines.append("FAIL\t\(plugin.name)\t\(plugin.manifest?.version ?? "")")
                lines += problems.map { "  " + $0 }
            }
        }
        if plugins.isEmpty { lines.append("No plugins installed.") }
        lines.append(appAnswered ? "Checked against Tiri \(TiriCoreVersion.string), API \(PluginManifest.currentAPI), and the running app." :
            "Checked against Tiri \(TiriCoreVersion.string), API \(PluginManifest.currentAPI). Tiri isn't running, so grammars weren't compiled and the commands they name weren't looked up.")
        return Outcome(output: lines.joined(separator: "\n") + "\n", code: failed ? 1 : 0)
    }

    /// If the app is open, the new folder shows up right away. If it isn't, there's nothing to tell.
    private static func askAppToLookAgain() -> String {
        guard let client = try? ControlClient(path: TiriPaths.socket, timeout: 3) else { return "" }
        _ = try? client.send(ControlRequest(cmd: "plugin.reload"))
        return ""
    }
}

// MARK: - Importing a VS Code extension

/// What a `.vsix` can give without running any of it: languages and grammars. The rest is listed, so
/// an agent can port what matters and a person can see what didn't come across.
public enum VSIXImporter {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    public struct Report: Sendable, Equatable {
        public var name: String
        public var folder: String
        public var languages: [String]
        public var grammars: [String]
        public var dropped: [String]

        public var text: String {
            var lines = ["Imported \(name) to \(folder). It's off: tiri plugin enable \(name) asks the person using Tiri."]
            lines.append("Languages: " + (languages.isEmpty ? "none" : languages.joined(separator: ", ")))
            lines.append("Grammars: " + (grammars.isEmpty ? "none" : grammars.joined(separator: ", ")))
            if !dropped.isEmpty {
                lines.append("Didn't come across, and an agent would need to port:")
                lines += dropped.map { "  " + $0 }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public static func importFile(_ file: String, into parent: URL) throws -> Report {
        guard FileManager.default.fileExists(atPath: file) else { throw Failure("No file at \(file).") }
        let listed = run("/usr/bin/unzip", ["-Z1", file])
        guard listed.code == 0 else { throw Failure("\(file) isn't a .vsix: it won't open as a zip.") }
        // Unpacked into a throwaway folder. A hostile archive can't climb out of it, and files are
        // copied from there one by one, only those the manifest names and only from inside.
        for entry in listed.output.split(whereSeparator: \.isNewline).map(String.init) {
            if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") { throw Failure("\(file) has a file outside itself: \(entry).") }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-vsix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard run("/usr/bin/unzip", ["-q", "-o", file, "-d", scratch.path]).code == 0 else { throw Failure("Couldn't unpack \(file).") }
        return try build(from: scratch.appendingPathComponent("extension", isDirectory: true), into: parent)
    }

    /// `extension` holds what an extension shipped, with `package.json` at its top.
    static func build(from source: URL, into parent: URL) throws -> Report {
        guard let data = try? Data(contentsOf: source.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: Data(JSONC.strip(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any] else {
            throw Failure("It has no readable extension/package.json, so it isn't a VS Code extension.")
        }
        let rawName = (package["name"] as? String ?? "extension").lowercased()
        let name = String(rawName.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard PluginValidator.isValidName(name) else { throw Failure("Can't make a plugin name from \"\(rawName)\".") }
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure("\(target.path) already exists. Remove it first with tiri plugin remove \(name).") }

        let contributes = package["contributes"] as? [String: Any] ?? [:]
        var dropped: [String] = []
        var manifest = PluginManifest(name: name, version: PluginVersion(package["version"] as? String ?? "") == nil ? "0.0.0" : package["version"] as? String ?? "0.0.0")
        manifest.title = package["displayName"] as? String
        manifest.description = package["description"] as? String
        manifest.tiri = ">=\(TiriCoreVersion.string)"

        let staging = parent.appendingPathComponent(".importing-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("grammars"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent(PluginManifest.folderName), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Grammars first, so a language can name the scope that really came across.
        var scopeForLanguage: [String: String] = [:]
        var grammarEntries: [PluginManifest.Grammar] = []
        var used = Set<String>()
        for entry in contributes["grammars"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String, let scope = entry["scopeName"] as? String else { continue }
            guard let file = PluginValidator.resolve(path, in: source), let bytes = try? Data(contentsOf: file) else {
                dropped.append("grammar \(scope): \(path) isn't in the extension")
                continue
            }
            guard let parsed = PluginGrammars.parse(bytes) else {
                dropped.append("grammar \(scope): \(path) isn't JSON or a property list")
                continue
            }
            var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if stem.hasSuffix(".tmLanguage") { stem = String(stem.dropLast(11)) }
            var fileName = stem + ".json"
            var suffix = 2
            while !used.insert(fileName).inserted {
                fileName = "\(stem)-\(suffix).json"
                suffix += 1
            }
            let json = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
            try json.write(to: staging.appendingPathComponent("grammars/" + fileName))
            let injectTo = entry["injectTo"] as? [String]
            grammarEntries.append(.init(scope: scope, path: "grammars/" + fileName, injectTo: injectTo))
            if let language = entry["language"] as? String { scopeForLanguage[language] = scope }
        }
        manifest.grammars = grammarEntries.isEmpty ? nil : grammarEntries

        var languages: [PluginManifest.Language] = []
        var seen = Set<String>()
        for entry in contributes["languages"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String else { continue }
            // Two entries for one language are how extensions add to each other. Here, the first says it.
            guard seen.insert(id).inserted else { continue }
            let aliases = entry["aliases"] as? [String] ?? []
            let extensions = (entry["extensions"] as? [String] ?? []).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
            let names = entry["filenames"] as? [String] ?? []
            if extensions.isEmpty, names.isEmpty, entry["filenamePatterns"] == nil, LanguageCatalog.language(id: id) == nil {
                dropped.append("language \(id): it doesn't say which files it's for")
                continue
            }
            if entry["filenamePatterns"] != nil { dropped.append("language \(id): its filenamePatterns, which Tiri doesn't read") }
            if entry["firstLine"] != nil { dropped.append("language \(id): its firstLine, which Tiri doesn't read") }
            var comment: PluginManifest.Language.Comment?
            if let configuration = entry["configuration"] as? String, let file = PluginValidator.resolve(configuration, in: source),
               let text = try? String(contentsOf: file, encoding: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8)) as? [String: Any],
               let comments = parsed["comments"] as? [String: Any] {
                var line = comments["lineComment"] as? String
                if let nested = comments["lineComment"] as? [String: Any] { line = nested["comment"] as? String }
                comment = .init(line: line, block: comments["blockComment"] as? [String])
                if comment?.line == nil, comment?.block == nil { comment = nil }
            }
            languages.append(.init(id: id, name: aliases.first, extensions: extensions.isEmpty ? nil : extensions, fileNames: names.isEmpty ? nil : names,
                                   interpreters: nil, aliases: aliases.isEmpty ? nil : aliases.map { $0.lowercased() }, grammar: scopeForLanguage[id], comment: comment,
                                   colonOpensBlock: nil, isProse: nil, server: nil))
        }
        manifest.languages = languages.isEmpty ? nil : languages

        // Everything else, said plainly.
        for key in contributes.keys.sorted() where key != "languages" && key != "grammars" {
            let value = contributes[key]
            let count = (value as? [Any])?.count ?? (value as? [String: Any])?.count ?? 1
            dropped.append("contributes.\(key): \(count) \(count == 1 ? "entry" : "entries")")
        }
        if let entry = package["main"] as? String ?? package["browser"] as? String {
            dropped.append("its code (\(entry)), which isn't run here. A language server it starts can go in the language's \"server\"")
        }
        if let depends = package["extensionDependencies"] as? [String], !depends.isEmpty {
            dropped.append("the extensions it needs: \(depends.joined(separator: ", "))")
        }

        // Grammars come with their licence.
        for license in (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [] where license.lowercased().hasPrefix("license") || license.lowercased().hasPrefix("licence") {
            if let file = PluginValidator.resolve(license, in: source) { try? FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(license)) }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: PluginManifest.url(in: staging))
        let report = Report(name: name, folder: target.path, languages: languages.map(\.id), grammars: grammarEntries.map(\.scope), dropped: dropped)
        var written = "# Importing \(package["displayName"] as? String ?? name)\n\nFrom a VS Code extension, version \(manifest.version). "
        written += "Only languages and grammars come across by themselves.\n\n"
        written += dropped.isEmpty ? "Nothing was left behind.\n" : "## What didn't come across\n\n" + dropped.map { "- " + $0 }.joined(separator: "\n") + "\n"
        try written.write(to: staging.appendingPathComponent("IMPORT-REPORT.md"), atomically: true, encoding: .utf8)
        let issues = PluginValidator.validate(manifest, folder: staging).filter { $0.severity == .error }
        guard issues.isEmpty else { throw Failure("What came across isn't a valid plugin: " + issues.map(\.message).joined(separator: "; ")) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: target)
        return report
    }
}
