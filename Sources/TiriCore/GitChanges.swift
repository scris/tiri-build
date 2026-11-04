import Foundation

public enum ChangeStatus: String, Sendable, Equatable {
    case modified, added, deleted, renamed, untracked, conflicted

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }
}

public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var path: String
    public var root: String
    public var relative: String
    public var status: ChangeStatus
    /// Where a renamed file came from, relative to the repository.
    public var oldRelative: String?
    public var id: String { path }

    public init(path: String, root: String, relative: String, status: ChangeStatus, oldRelative: String? = nil) {
        self.path = path
        self.root = root
        self.relative = relative
        self.status = status
        self.oldRelative = oldRelative
    }
}

public enum GitStatusParser {
    /// `git status --porcelain=v1 -z`: `XY path\0`, with a rename's old path as the next field.
    public static func parse(_ output: String, root: String) -> [ChangedFile] {
        var result: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst() {
            guard field.count > 3 else { continue }
            let codes = Array(field.prefix(2))
            let relative = String(field.dropFirst(3))
            var old: String?
            if codes.contains("R") || codes.contains("C") { old = fields.popFirst() }
            result.append(ChangedFile(path: root + "/" + relative, root: root, relative: relative,
                                      status: status(codes), oldRelative: old))
        }
        return result
    }

    private static func status(_ codes: [Character]) -> ChangeStatus {
        let (index, tree) = (codes[0], codes[1])
        if index == "?" { return .untracked }
        if index == "U" || tree == "U" || (index == "A" && tree == "A") || (index == "D" && tree == "D") { return .conflicted }
        if index == "R" || tree == "R" { return .renamed }
        if index == "D" || tree == "D" { return .deleted }
        if index == "A" { return .added }
        return .modified
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed, hunk }
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String

    public init(kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public struct FileDiff: Sendable, Equatable {
    public var lines: [DiffLine]
    public var isBinary: Bool
    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
    public var isEmpty: Bool { lines.isEmpty && !isBinary }

    public init(lines: [DiffLine] = [], isBinary: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
    }

    /// A file git doesn't track yet: all of it is new.
    public static func allAdded(_ text: String) -> FileDiff {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return FileDiff(lines: lines.enumerated().map { DiffLine(kind: .added, newLine: $0.offset + 1, text: $0.element) })
    }
}

public enum DiffParser {
    public static func parse(_ output: String) -> FileDiff {
        var diff = FileDiff()
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                diff.isBinary = true
                continue
            }
            if line.hasPrefix("@@") {
                if let (old, new) = hunkStart(line) {
                    oldLine = old
                    newLine = new
                    inHunk = true
                    diff.lines.append(DiffLine(kind: .hunk, text: line))
                }
                continue
            }
            guard inHunk, let first = line.first else { continue }
            let text = String(line.dropFirst())
            switch first {
            case "+":
                diff.lines.append(DiffLine(kind: .added, newLine: newLine, text: text))
                newLine += 1
            case "-":
                diff.lines.append(DiffLine(kind: .removed, oldLine: oldLine, text: text))
                oldLine += 1
            case " ":
                diff.lines.append(DiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: text))
                oldLine += 1
                newLine += 1
            case "\\":
                break  // "\ No newline at end of file"
            case "d":
                inHunk = false  // The next file's header.
            default:
                break
            }
        }
        return diff
    }

    /// `@@ -12,3 +14,5 @@ optional context`
    private static func hunkStart(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }
}

/// Where a repository stands: what the status bar shows.
public struct RepositoryStatus: Sendable, Equatable, Identifiable {
    public var root: String
    /// Nil when HEAD is detached.
    public var branch: String?
    public var shortOID: String?
    /// What the branch tracks, like `origin/main`. Nil if it doesn't track anything yet.
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var isDirty = false
    /// Where fetching and pushing go: what the branch tracks, or else `origin`, or else the only choice.
    public var remote: String?
    /// Git's own folders, which can be outside the workspace.
    public var gitDirectories: [String] = []
    public var id: String { root }

    public init(root: String) { self.root = root }

    public var name: String { (root as NSString).lastPathComponent }
    public var title: String { branch ?? shortOID ?? "No commits" }
    /// Pushing needs a branch with something on it, and somewhere to send it.
    public var canPublish: Bool { branch != nil && upstream == nil && remote != nil && shortOID != nil }
    public var canPush: Bool { branch != nil && upstream != nil && ahead > 0 }
    public var canPull: Bool { branch != nil && upstream != nil }
    /// `git push` with what it has to know: a new branch names where to go, and remembers it.
    public var pushArguments: [String] { upstream != nil ? ["push"] : ["push", "-u", remote ?? "origin", "HEAD"] }

    /// The headers of `git status --porcelain=v2 --branch`. Any other line is a change.
    mutating func read(statusOutput output: String) {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("# ") else {
                isDirty = true
                continue
            }
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 3 else { continue }
            switch fields[1] {
            case "branch.oid": shortOID = fields[2] == "(initial)" ? nil : String(fields[2].prefix(7))
            case "branch.head": branch = fields[2] == "(detached)" ? nil : fields[2]
            case "branch.upstream": upstream = fields[2]
            case "branch.ab" where fields.count >= 4:
                ahead = Int(fields[2].dropFirst()) ?? 0
                behind = Int(fields[3].dropFirst()) ?? 0
            default: break
            }
        }
    }

    static func chooseRemote(tracked: String?, all: [String]) -> String? {
        if let tracked, tracked != "." { return tracked }
        return all.contains("origin") ? "origin" : all.first
    }
}

/// Runs git, for the changes view and the status bar. Only `transfer` touches a remote.
public enum Git {
    static func runGit(_ arguments: [String], in directory: String) -> (status: Int32, output: Data)? {
        run(arguments, in: directory)
    }

    /// Spawned and waited for directly. Foundation's Process can wait forever for a child that has
    /// already exited, which would silently stop the changes list. A hung git gets killed.
    private static func run(_ arguments: [String], in directory: String, timeout: Double = 20,
                            includeErrors: Bool = false, extraEnvironment: [String: String] = [:]) -> (status: Int32, output: Data)? {
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { return nil }
        let (readEnd, writeEnd) = (pipes[0], pipes[1])
        defer { close(readEnd) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if includeErrors {
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing of Tiri's stays open in git, or a pipe might never see its end.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        for keep: Int32 in [0, 1, 2] { posix_spawn_file_actions_addinherit_np(&actions, keep) }

        var environment = ProcessInfo.processInfo.environment
        // Looking at a repository shouldn't write to it, or the watcher hears git and asks again.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment.merge(extraEnvironment) { _, new in new }
        let argv: [UnsafeMutablePointer<CChar>?] = (["git"] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else { return nil }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var wait = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)
            let ready = poll(&wait, 1, remaining)
            if ready == 0 {
                kill(pid, SIGKILL)
                break
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(readEnd, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exited = status & 0x7F == 0
        return (exited ? (status >> 8) & 0xFF : 128, output)
    }

    public static func repositoryRoot(of folder: String) -> String? {
        guard let result = run(["rev-parse", "--show-toplevel"], in: folder), result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Where a repository stands, or nil if the folder isn't in one.
    public static func repositoryStatus(of folder: String) -> RepositoryStatus? {
        guard let root = repositoryRoot(of: folder),
              let result = run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: root),
              result.status == 0 else { return nil }
        var status = RepositoryStatus(root: root)
        status.read(statusOutput: String(decoding: result.output, as: UTF8.self))
        func lines(_ arguments: [String]) -> [String] {
            guard let result = run(arguments, in: root), result.status == 0 else { return [] }
            return String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        }
        let tracked = status.branch.flatMap { lines(["config", "--get", "branch.\($0).remote"]).first }
        status.remote = RepositoryStatus.chooseRemote(tracked: tracked, all: lines(["remote"]))
        status.gitDirectories = Array(Set(lines(["rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir"]))).sorted()
        return status
    }

    /// One for each repository the workspace's folders are in, in the order of the folders.
    public static func repositoriesAcross(_ folders: [String]) -> [RepositoryStatus] {
        var seen = Set<String>()
        return folders.compactMap { folder in
            guard let status = repositoryStatus(of: folder), seen.insert(status.root).inserted else { return nil }
            return status
        }
    }

    public struct TransferFailure: Error, Equatable, Sendable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    /// Only ever moves a branch forward: a pull from here can't start a merge or leave conflicts.
    public static let pullArguments = ["pull", "--ff-only"]

    /// `git fetch`, `git pull` or `git push`. Nobody's there to answer, so a remote that needs a password fails
    /// rather than waits. `path` is the user's own, because an app opened from Finder doesn't
    /// have it, and credential helpers and push hooks do need it. Hooks can run a long time.
    public static func transfer(_ arguments: [String], in root: String, path: String?, timeout: Double = 600) -> Result<Void, TransferFailure> {
        var environment = ["GIT_TERMINAL_PROMPT": "0"]
        if let path { environment["PATH"] = path }
        guard let result = run(arguments, in: root, timeout: timeout, includeErrors: true, extraEnvironment: environment) else {
            return .failure(TransferFailure(message: "Couldn't run git."))
        }
        guard result.status != 0 else { return .success(()) }
        return .failure(TransferFailure(message: failureMessage(String(decoding: result.output, as: UTF8.self))))
    }

    /// What git said, in fewer words. Hints and progress aren't what went wrong.
    static func failureMessage(_ output: String) -> String {
        if output.contains("Not possible to fast-forward") || output.contains("Diverging branches") {
            return "Both this branch and the remote have moved on. Merge or rebase first."
        }
        if output.contains("would be overwritten by merge") {
            return "Uncommitted changes touch the same files. Commit or stash them first."
        }
        if output.contains("[rejected]") || output.contains("non-fast-forward") || output.contains("fetch first") {
            return "The remote has commits you don't have yet. Pull them first, then push."
        }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
        let reasons = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("remote: error") }
        let chosen = reasons.isEmpty ? Array(lines.suffix(2)) : Array(reasons.prefix(2))
        let text = chosen.joined(separator: " ")
        return text.isEmpty ? "Git stopped without saying why." : text
    }

    /// Changes under a workspace folder, reported by the path that folder is known by.
    public static func changes(in folder: String) -> [ChangedFile] {
        guard let root = repositoryRoot(of: folder),
              let result = run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], in: folder),
              result.status == 0 else { return [] }
        let found = GitStatusParser.parse(String(decoding: result.output, as: UTF8.self), root: root)
        let realFolder = real(folder)
        // git reports real paths. The workspace may know this folder by a link to it.
        return found.map { file in
            var file = file
            if file.path.hasPrefix(realFolder + "/") {
                file.path = folder + file.path.dropFirst(realFolder.count)
            }
            return file
        }
    }

    /// All the changes in a workspace, in the order the explorer would show them.
    public static func changesAcross(_ folders: [String]) -> [ChangedFile] {
        var seen = Set<String>()
        var result: [ChangedFile] = []
        for folder in folders {
            for file in changes(in: folder).sorted(by: { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending })
            where seen.insert(file.path).inserted {
                result.append(file)
            }
        }
        return result
    }

    public static func diff(path: String) -> FileDiff {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = FileManager.default.fileExists(atPath: parent) ? parent : nearestExistingFolder(of: parent)
        guard let root = repositoryRoot(of: directory) else { return untrackedDiff(path) }
        let realPath = real(path)
        let realRoot = real(root)
        guard realPath.hasPrefix(realRoot + "/") else { return untrackedDiff(path) }
        let relative = String(realPath.dropFirst(realRoot.count + 1))
        if let status = run(["status", "--porcelain=v1", "-z", "--", relative], in: root),
           String(decoding: status.output, as: UTF8.self).hasPrefix("??") {
            return untrackedDiff(path)
        }
        if let result = run(["diff", "HEAD", "--no-color", "--no-ext-diff", "-U3", "--", relative], in: root), result.status == 0 {
            return DiffParser.parse(String(decoding: result.output, as: UTF8.self))
        }
        // A repository with no commits yet has no HEAD to compare with.
        return untrackedDiff(path)
    }

    /// The real path, even for a file that's gone: it's the deleted ones git has most to say about.
    public static func real(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/")
    }

    private static func nearestExistingFolder(of path: String) -> String {
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }

    private static func untrackedDiff(_ path: String) -> FileDiff {
        guard let handle = FileHandle(forReadingAtPath: path) else { return FileDiff() }
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        guard FileClassifier.isLikelyText(data.prefix(8192)) else { return FileDiff(isBinary: true) }
        return .allAdded(String(decoding: data, as: UTF8.self))
    }
}

/// Selected rows of a diff, written out for an agent to read.
public enum DiffQuote {
    public static func text<Rows: Sequence>(path: String, rows: Rows) -> String where Rows.Element == DiffLine {
        let name = (path as NSString).lastPathComponent
        return "From the changes in \(name):\n```diff\n\(self.rows(rows))\n```\n"
    }

    /// The rows themselves, with their marks.
    public static func rows<Rows: Sequence>(_ rows: Rows) -> String where Rows.Element == DiffLine {
        rows.compactMap { row -> String? in
            switch row.kind {
            case .added: "+" + row.text
            case .removed: "-" + row.text
            case .context: " " + row.text
            case .hunk: nil
            }
        }.joined(separator: "\n")
    }
}
