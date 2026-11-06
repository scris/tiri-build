import Foundation

/// What the user's own shell can run. An app opened from Finder doesn't have their PATH, and agents
/// are often installed somewhere only their shell setup knows about, or as an alias. So this asks
/// that shell, the same way a terminal starts it.
/// On a Mac without Apple's Command Line Tools, `/usr/bin` still has git, clangd, python3 and dozens more, all one
/// small stand-in program. Running any of them puts up Apple's "install the developer tools" window, so Tiri never
/// runs one by itself: plain Tiri shouldn't need developer tools, and only asks for them when you ask for something that does.
public enum DeveloperTools {
    /// `TIRI_DEV_NO_DEVELOPER_TOOLS=1` makes a test copy act as if the Mac had none, and `=all` as if it had no git at all.
    public static var pretendMissing: Bool { ["1", "all"].contains(ProcessInfo.processInfo.environment["TIRI_DEV_NO_DEVELOPER_TOOLS"]) }
    static var pretendNoGit: Bool { ProcessInfo.processInfo.environment["TIRI_DEV_NO_DEVELOPER_TOOLS"] == "all" }

    /// Whether Apple's tools are installed: `xcode-select -p` names a folder that holds them. That only reads a setting.
    public static var areInstalled: Bool {
        if pretendMissing { return false }
        installedLock.lock()
        defer { installedLock.unlock() }
        if foundInstalled { return true }
        let folder = Tool.run("/usr/bin/xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a yes is kept, so installing them is noticed without a relaunch.
        foundInstalled = !folder.isEmpty && FileManager.default.isExecutableFile(atPath: folder + "/usr/bin/git")
        return foundInstalled
    }
    private static let installedLock = NSLock()
    nonisolated(unsafe) private static var foundInstalled = false

    /// One of the stand-ins: the same file as `/usr/bin/git`, which on macOS is always one.
    public static func isStandIn(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard resolved.hasPrefix("/usr/bin/") else { return false }
        var file = stat(), git = stat()
        guard stat(resolved, &file) == 0, stat("/usr/bin/git", &git) == 0 else { return false }
        return file.st_ino == git.st_ino && file.st_dev == git.st_dev
    }

    /// False only for a stand-in when the tools aren't there.
    public static func canRun(_ path: String) -> Bool {
        !isStandIn(path) || areInstalled
    }

    /// The git to run, or nil when the only one is Apple's stand-in. Any other counts, wherever it came from.
    public static var git: String? {
        if canRun("/usr/bin/git") { return "/usr/bin/git" }
        if pretendNoGit { return nil }
        let path = [shellPath, ProcessInfo.processInfo.environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return gitCandidates(path: path).first { FileManager.default.isExecutableFile(atPath: $0) && !isStandIn($0) }
    }

    /// The PATH of the person's own shell, once the app has asked it. A Mac app opened from Finder doesn't have it.
    nonisolated(unsafe) public static var shellPath: String?

    /// Their shell's PATH first, since that's the git their terminals use. Then where git's installers put it, for
    /// before the shell has answered: Homebrew, MacPorts, git-scm.com, Nix, and GitHub Desktop's own copy.
    static func gitCandidates(path: String) -> [String] {
        let home = NSHomeDirectory()
        let fromPath = path.split(separator: ":").map { "\($0)/git" }
        let known = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git", "/usr/local/git/bin/git",
                     "\(home)/.nix-profile/bin/git", "/run/current-system/sw/bin/git", "/nix/var/nix/profiles/default/bin/git",
                     "/Applications/GitHub Desktop.app/Contents/Resources/app/git/bin/git"]
        var seen = Set<String>()
        return (fromPath + known).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
}

public enum ShellLookup {
    private static let marker = "tiri-found:"

    /// A name that's safe to put in a script. A preset can hold anything, so anything else isn't asked about.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
    }

    /// One line per name, so a failure in one can't hide another. Written to work in fish too.
    public static func script(for names: [String]) -> String {
        names.filter(isPlainName)
            .map { "command -v \($0) >/dev/null 2>&1 && echo \(marker)\($0)" }
            .joined(separator: "; ")
    }

    /// Shell setup can print anything, so only whole lines with the marker count.
    public static func found(in output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker) {
            names.insert(String(line.dropFirst(marker.count)))
        }
        return names
    }

    /// Where each name is, for the ones the shell can find as a program. An alias isn't one.
    public static func locations(names: [String], shell: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 timeout: TimeInterval = 8) async -> [String: String]? {
        let script = names.filter(isPlainName)
            .map { "command -v \($0) 2>/dev/null | sed 's|^|\(marker)\($0)=|'" }
            .joined(separator: "; ")
        guard let text = await output(of: script, shell: shell, environment: environment, timeout: timeout) else { return nil }
        return locations(in: text)
    }

    static func locations(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(marker) {
            let parts = line.dropFirst(marker.count).split(separator: "=", maxSplits: 1)
            // Apple's stand-in for a tool that isn't installed counts as not found: running it would put up an installer.
            if parts.count == 2, parts[1].hasPrefix("/"), DeveloperTools.canRun(String(parts[1])) { found[String(parts[0])] = String(parts[1]) }
        }
        return found
    }

    /// Nil if the shell didn't answer in time. Slow or broken shell setup shouldn't look like a
    /// missing agent. Output goes to a file, because a daemon started by the shell's setup can
    /// hold a pipe open long after the shell has gone.
    public static func run(names: [String], shell: String, environment: [String: String]? = nil,
                           timeout: TimeInterval = 8) async -> Set<String>? {
        await output(of: script(for: names), shell: shell, environment: environment, timeout: timeout).map(found(in:))
    }

    private static func output(of script: String, shell: String, environment: [String: String]?, timeout: TimeInterval) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-lookup-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if let environment { process.environment = environment }

        let finished: Bool = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            process.terminationHandler = { _ in once.resume(true) }
            do {
                try process.run()
            } catch {
                once.resume(false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(false)
                if process.isRunning { process.terminate() }
            }
        }
        guard finished else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// The user's PATH, as their shell sets it up. Fish lists it with the marker on each part.
    public static func path(shell: String, environment: [String: String]? = nil, timeout: TimeInterval = 8) async -> String? {
        let pathMarker = "tiri-path:"
        guard let text = await output(of: "echo \(pathMarker)$PATH", shell: shell, environment: environment, timeout: timeout) else { return nil }
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(pathMarker) }) else { return nil }
        let value = line.dropFirst(pathMarker.count).replacingOccurrences(of: " " + pathMarker, with: ":")
        return value.isEmpty ? nil : value
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// `tiri` for terminals outside Tiri. Inside it, every terminal already has it on its PATH. This
/// is a link into the app, so updating the app updates the command.
public enum CommandLineTool {
    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// A link to a copy of Tiri that has moved or gone.
        case stale
        /// Something that isn't Tiri's link, such as the copy `build.sh` leaves.
        case otherFile
    }

    public static func link(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/tiri")
    }

    public static func state(link: URL, bundled: URL) -> State {
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
            // `fileExists` follows links, and this path isn't one.
            return manager.fileExists(atPath: link.path) ? .otherFile : .notInstalled
        }
        return destination == bundled.path ? .installed : .stale
    }

    /// Why a link made now wouldn't last. macOS runs an app opened from Downloads from a temporary
    /// place, and a disk image gets ejected.
    public static func problem(appPath: String) -> String? {
        guard appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") else { return nil }
        return "Move Tiri to your Applications folder first. From where it's running now, the link would stop working."
    }

    public static func install(link: URL, bundled: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not `fileExists`: that says no for a link whose target has gone.
        if (try? manager.attributesOfItem(atPath: link.path)) != nil { try manager.removeItem(at: link) }
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: bundled.path)
    }

    /// Only ever a link. A file that isn't one was put there by someone else.
    public static func remove(link: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try FileManager.default.removeItem(at: link)
    }
}
