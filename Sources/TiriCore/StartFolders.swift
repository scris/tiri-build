import Foundation

/// What starts a folder's project, as Tiri guesses it: a dev server, mostly. Someone confirms one, types their own,
/// or has their agent find it, and it's kept in `start.commands`.
public struct StartGuess: Equatable, Sendable, Identifiable {
    public var command: String
    /// Where it came from, as a file name: `package.json`, `.claude/launch.json`.
    public var source: String
    /// What it runs underneath, when that says more than the command: a package script's body.
    public var detail: String?

    public var id: String { command }

    public init(command: String, source: String, detail: String? = nil) {
        self.command = command
        self.source = source
        self.detail = detail
    }
}

public enum StartFolders {
    /// Best first. Files are read, never run.
    public static func guesses(in folder: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [StartGuess] {
        func file(_ name: String) -> String? { read((folder as NSString).appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { file(name) != nil }
        var found: [StartGuess] = []
        func add(_ guess: StartGuess) { if !found.contains(where: { $0.command == guess.command }) { found.append(guess) } }

        // What Claude Code's own preview already worked out for this folder.
        if let text = file(".claude/launch.json"), let launch = json(JSONC.strip(text)),
           let configurations = launch["configurations"] as? [[String: Any]] {
            for configuration in configurations {
                guard let command = launchCommand(configuration) else { continue }
                add(StartGuess(command: command, source: ".claude/launch.json", detail: configuration["name"] as? String))
            }
        }

        if let text = file("package.json"), let package = json(text), let scripts = package["scripts"] as? [String: Any] {
            let runner = packageRunner(exists)
            for name in ["dev", "start", "serve", "develop", "preview"] {
                guard let body = scripts[name] as? String else { continue }
                add(StartGuess(command: runner(name), source: "package.json", detail: body))
            }
        }

        if let text = file("Procfile") {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, !line.hasPrefix("#") else { continue }
                let command = parts[1].trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { add(StartGuess(command: command, source: "Procfile", detail: String(parts[0]))) }
            }
        }

        if exists("manage.py") { add(StartGuess(command: "python3 manage.py runserver", source: "manage.py")) }
        if let text = file("Makefile") {
            for target in ["dev", "run", "serve", "start"] where text.range(of: "(?m)^\(target):", options: .regularExpression) != nil {
                add(StartGuess(command: "make \(target)", source: "Makefile"))
            }
        }
        if exists("Cargo.toml") { add(StartGuess(command: "cargo run", source: "Cargo.toml")) }
        if exists("go.mod"), exists("main.go") { add(StartGuess(command: "go run .", source: "go.mod")) }
        for name in ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"] where exists(name) {
            add(StartGuess(command: "docker compose up", source: name))
            break
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
    public static func printedPort(in output: String) -> Int? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[\w.-]+\.localhost):(\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.matches(in: output, range: range).last, let digits = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[digits]).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// Which of the ports a server listens on is its page: the one it printed, or the lowest.
    /// Dev servers often open a second for reloading, always above the first.
    public static func pagePort(listening: [Int], printed: Int?) -> Int? {
        if let printed, listening.isEmpty || listening.contains(printed) { return printed }
        return listening.min()
    }

    /// A short name for a command, for its terminal's tab: `pnpm dev`, not its whole line.
    public static func title(of command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace).filter { !$0.contains("=") }
        let afterCd = words.firstIndex(of: "&&").map { Array(words[($0 + 1)...]) } ?? words
        return afterCd.prefix(3).joined(separator: " ")
    }
}
