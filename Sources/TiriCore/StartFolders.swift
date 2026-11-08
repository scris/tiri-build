import Foundation

/// One of a workspace's starts: a name, a command, and the folder it runs in. A workspace keeps its own list,
/// which people add to by hand, from Tiri's suggestions, or by asking their agent.
public struct StartEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    /// One of the workspace's folders, or a folder inside one.
    public var folder: String

    public init(id: String = TiriID.make("s"), name: String, command: String, folder: String) {
        self.id = id
        self.name = name
        self.command = command
        self.folder = folder
    }
}

/// What might start something in a folder, as Tiri guesses it from the files: a dev server, mostly.
public struct StartGuess: Equatable, Sendable, Identifiable {
    /// What it'd be called in the list: the subproject, the script, the launch configuration.
    public var name: String
    public var command: String
    /// Where it runs.
    public var folder: String
    /// Where it came from, as a file name: `package.json`, `scripts/start-home.sh`.
    public var source: String
    /// What it runs underneath, when that says more than the command: a package script's body.
    public var detail: String?

    public var id: String { folder + "\u{1}" + command }

    public init(name: String, command: String, folder: String, source: String, detail: String? = nil) {
        self.name = name
        self.command = command
        self.folder = folder
        self.source = source
        self.detail = detail
    }

    public var entry: StartEntry { StartEntry(name: name, command: command, folder: folder) }
}

public enum StartFolders {
    /// What a workspace's folders suggest, best first: each folder's own, then its subprojects one level down,
    /// as in a monorepo. Files are read, never run.
    public static func suggestions(for folders: [String], read: (String) -> String? = readFile,
                                   subfolders: (String) -> [String] = listSubfolders) -> [StartGuess] {
        var found: [StartGuess] = []
        for folder in folders {
            found += guesses(in: folder, read: read)
            for sub in subfolders(folder).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                // A subproject's best one is enough: the list is for choosing, not for every script there is.
                if let best = guesses(in: sub, read: read, scriptsToo: false).first { found.append(best) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    public static func readFile(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 512_000 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Folders one level down that could be projects: not hidden, not dependencies or build output.
    public static func listSubfolders(_ folder: String) -> [String] {
        let skip: Set<String> = ["node_modules", "build", "dist", "target", "out", "vendor", "venv", "env", "__pycache__", "docs", "tmp", "logs"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") && !skip.contains($0.lowercased()) }.prefix(60).compactMap { name in
            let path = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
    }

    /// One folder's own, best first.
    public static func guesses(in folder: String, read: (String) -> String? = readFile, scriptsToo: Bool = true) -> [StartGuess] {
        func file(_ name: String) -> String? { read((folder as NSString).appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { file(name) != nil }
        let here = (folder as NSString).lastPathComponent
        var found: [StartGuess] = []
        func add(_ name: String, _ command: String, _ source: String, _ detail: String? = nil) {
            if !found.contains(where: { $0.command == command }) {
                found.append(StartGuess(name: name, command: command, folder: folder, source: source, detail: detail))
            }
        }

        // What Claude Code's own preview already worked out for this folder.
        if let text = file(".claude/launch.json"), let launch = json(JSONC.strip(text)),
           let configurations = launch["configurations"] as? [[String: Any]] {
            for configuration in configurations {
                guard let command = launchCommand(configuration) else { continue }
                add(configuration["name"] as? String ?? here, command, ".claude/launch.json")
            }
        }

        // The project's own way to start, when it has one: `scripts/start-home.sh`, `bin/dev`.
        if scriptsToo {
            for script in startScripts(in: folder, read: read) {
                add(script.name, script.path, script.path)
            }
        }

        if let text = file("package.json"), let package = json(text), let scripts = package["scripts"] as? [String: Any] {
            let runner = packageRunner(exists)
            for name in ["dev", "start", "serve", "develop", "preview"] {
                guard let body = scripts[name] as? String else { continue }
                add(name == "dev" || found.isEmpty ? here : "\(here) \(name)", runner(name), "package.json", body)
            }
        }

        if let text = file("Procfile") {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, !line.hasPrefix("#") else { continue }
                let command = parts[1].trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { add(String(parts[0]), command, "Procfile") }
            }
        }

        if exists("manage.py") { add(here, "python3 manage.py runserver", "manage.py") }
        if let text = file("Makefile") {
            for target in ["dev", "run", "serve", "start"] where text.range(of: "(?m)^\(target):", options: .regularExpression) != nil {
                add(here, "make \(target)", "Makefile")
            }
        }
        // Spring Boot: its wrapper when the project has one.
        if let pom = file("pom.xml"), pom.contains("spring-boot-maven-plugin") {
            add(here, exists("mvnw") ? "./mvnw spring-boot:run" : "mvn spring-boot:run", "pom.xml")
        }
        if let gradle = file("build.gradle.kts") ?? file("build.gradle"), gradle.contains("org.springframework.boot") {
            add(here, exists("gradlew") ? "./gradlew bootRun" : "gradle bootRun", exists("build.gradle.kts") ? "build.gradle.kts" : "build.gradle")
        }
        if exists("Cargo.toml") { add(here, "cargo run", "Cargo.toml") }
        if exists("go.mod"), exists("main.go") { add(here, "go run .", "go.mod") }
        for name in ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"] where exists(name) {
            add(here, "docker compose up", name)
            break
        }
        return found
    }

    /// `scripts/start-home.sh` is "home", `bin/dev` is "dev". Only ones that say they start something.
    static func startScripts(in folder: String, read: (String) -> String?) -> [(name: String, path: String)] {
        var found: [(String, String)] = []
        for path in ["bin/dev", "bin/start", "script/server", "start.sh", "dev.sh"] where read((folder as NSString).appendingPathComponent(path)) != nil {
            found.append(((path as NSString).lastPathComponent.replacingOccurrences(of: ".sh", with: ""), path))
        }
        for directory in ["scripts", "script", "bin"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: (folder as NSString).appendingPathComponent(directory))) ?? []
            for name in names.sorted() where name.hasPrefix("start") && name.hasSuffix(".sh") {
                let path = "\(directory)/\(name)"
                guard !found.contains(where: { $0.1 == path }) else { continue }
                var short = String(name.dropLast(3).dropFirst(5))
                while short.hasPrefix("-") || short.hasPrefix("_") { short.removeFirst() }
                found.append((short.isEmpty ? (folder as NSString).lastPathComponent : short, path))
            }
        }
        return found
    }

    /// `pnpm dev`, `yarn dev`, `bun run dev` or `npm run dev`, by the lockfile that's there.
    private static func packageRunner(_ exists: (String) -> Bool) -> (String) -> String {
        if exists("pnpm-lock.yaml") { return { "pnpm \($0)" } }
        if exists("yarn.lock") { return { "yarn \($0)" } }
        if exists("bun.lockb") || exists("bun.lock") { return { "bun run \($0)" } }
        return { $0 == "start" ? "npm start" : "npm run \($0)" }
    }

    private static func launchCommand(_ configuration: [String: Any]) -> String? {
        let words: [String]
        if let executable = configuration["runtimeExecutable"] as? String {
            words = [executable] + (configuration["runtimeArgs"] as? [String] ?? [])
        } else if let program = configuration["program"] as? String {
            words = ["node", program] + (configuration["args"] as? [String] ?? [])
        } else {
            return nil
        }
        var command = words.map(ShellQuote.quote).joined(separator: " ")
        // Only names a shell takes as a variable: anything else would be a command of its own.
        if let env = (configuration["env"] as? [String: String])?.filter({ $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
           !env.isEmpty {
            command = env.keys.sorted().map { "\($0)=\(ShellQuote.quote(env[$0] ?? ""))" }.joined(separator: " ") + " " + command
        }
        if let cwd = configuration["cwd"] as? String {
            let relative = cwd.replacingOccurrences(of: "${workspaceFolder}", with: ".")
            if !relative.isEmpty, relative != ".", relative != "./" { command = "cd \(ShellQuote.quote(relative)) && " + command }
        }
        return command
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// The port in the last local address a server printed, like `http://localhost:5173/`.
    public static func printedPort(in output: String) -> Int? { printedPorts(in: output).last }

    /// Every local address's port it printed, in the order printed.
    public static func printedPorts(in output: String) -> [Int] {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[\w.-]+\.localhost):(\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            Range(match.range(at: 1), in: output).flatMap { Int(output[$0]) }.flatMap { (1...65535).contains($0) ? $0 : nil }
        }
    }

    /// Which of the ports it listens on is the page: one it printed, the lowest of those if it printed several (a start
    /// script bringing up a site and its API prints both, in whatever order they're ready), or else the lowest it listens on.
    /// Dev servers open a second port for reloading, always above the first.
    public static func pagePort(listening: [Int], printed: [Int]) -> Int? {
        if listening.isEmpty { return printed.last }
        let both = printed.filter(listening.contains)
        return both.min() ?? listening.min()
    }

    public static func pagePort(listening: [Int], printed: Int?) -> Int? {
        pagePort(listening: listening, printed: printed.map { [$0] } ?? [])
    }

    /// A short name for a command, for its terminal's tab: `pnpm dev`, not its whole line.
    public static func title(of command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace).filter { !$0.contains("=") }
        let afterCd = words.firstIndex(of: "&&").map { Array(words[($0 + 1)...]) } ?? words
        return afterCd.prefix(3).joined(separator: " ")
    }
}
