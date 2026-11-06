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

    /// In words, for the screen.
    public var title: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .untracked: String(localized: "Untracked")
        case .conflicted: String(localized: "Conflicted")
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
    /// Where the file was before, if it was renamed.
    public var oldRelative: String?
    /// What git says about a file with no lines to compare: new and empty, or only its mode changed.
    public var note: String?
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
        var oldMode: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                diff.isBinary = true
                continue
            }
            if !inHunk {
                if line.hasPrefix("new file mode") { diff.note = String(localized: "This new file is empty.") }
                if line.hasPrefix("deleted file mode") { diff.note = String(localized: "This deleted file was empty.") }
                if line.hasPrefix("old mode ") { oldMode = String(line.dropFirst(9)) }
                if line.hasPrefix("new mode "), let oldMode { diff.note = String(localized: "Only its mode changed, from \(oldMode) to \(String(line.dropFirst(9))).") }
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
    /// Which repository, at which commit.
    public var head: String { root + "@" + (shortOID ?? "") }
    public var title: String { branch ?? shortOID ?? "No commits" }
    /// The same, for the screen. `title` is what `tiri` reports.
    public var displayTitle: String { branch ?? shortOID ?? String(localized: "No commits") }
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

/// What a look at the changes found. Empty and finished is clean. Empty and timed out is unknown.
public struct ChangesScan: Sendable, Equatable {
    public var files: [ChangedFile] = []
    /// There were more than the limit, and these are the first.
    public var limited = false
    /// git didn't finish in time, so nothing here says what's changed.
    public var timedOut = false
    public init(files: [ChangedFile] = [], limited: Bool = false, timedOut: Bool = false) {
        self.files = files
        self.limited = limited
        self.timedOut = timedOut
    }
}

/// Runs git, for the changes view and the status bar. Only `transfer` touches a remote.
public enum Git {
    static func runGit(_ arguments: [String], in directory: String, environment: [String: String] = [:], timeout: Double = 20) -> (status: Int32, output: Data)? {
        run(arguments, in: directory, timeout: timeout, extraEnvironment: environment)
    }

    private static func run(_ arguments: [String], in directory: String, timeout: Double = 20,
                            includeErrors: Bool = false, extraEnvironment: [String: String] = [:]) -> (status: Int32, output: Data)? {
        ran(arguments, in: directory, timeout: timeout, includeErrors: includeErrors, extraEnvironment: extraEnvironment).map { ($0.status, $0.output) }
    }

    /// How a run went, for the callers that need more than what it printed.
    struct Ran {
        var status: Int32
        var output: Data
        /// Killed for taking too long. What it printed is only a start.
        var timedOut = false
        /// Stopped once it had printed `records` NUL-ended fields.
        var cut = false
    }

    /// Spawned and waited for directly. Foundation's Process can wait forever for a child that has
    /// already exited, which would silently stop the changes list. A hung git gets killed.
    private static func ran(_ arguments: [String], in directory: String, timeout: Double = 20,
                            includeErrors: Bool = false, extraEnvironment: [String: String] = [:], records: Int? = nil) -> Ran? {
        if let connection = RemoteRegistry.shared.connection(forLocal: directory) {
            return runRemote(arguments, on: connection, in: directory, timeout: timeout, includeErrors: includeErrors, extraEnvironment: extraEnvironment)
                .map { Ran(status: $0.status, output: $0.output) }
        }
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { return nil }
        let (readEnd, writeEnd) = (pipes[0], pipes[1])
        // At once: a terminal started on another thread right now would take these along.
        CloseOnExec.mark(readEnd, writeEnd)
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
        // With no git but Apple's stand-in, there's no repository to see, rather than Apple's installer on every look.
        guard let git = DeveloperTools.git else {
            close(writeEnd)
            return nil
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, git, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else { return nil }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var cut = false
        var fields = 0
        while true {
            var wait = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)
            let ready = poll(&wait, 1, remaining)
            if ready == 0 {
                kill(pid, SIGKILL)
                timedOut = true
                break
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(readEnd, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                // Enough for anyone to read, so the rest isn't worth the wait or the memory.
                if let records {
                    fields += buffer[0..<count].reduce(0) { $1 == 0 ? $0 + 1 : $0 }
                    if fields >= records {
                        kill(pid, SIGKILL)
                        cut = true
                        break
                    }
                }
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exited = status & 0x7F == 0
        return Ran(status: cut ? 0 : (exited ? (status >> 8) & 0xFF : 128), output: output, timedOut: timedOut, cut: cut)
    }

    /// The same command, run where the repository is. What's said in local paths goes out in the
    /// server's, and absolute paths in `rev-parse`'s answers come back as local ones.
    private static func runRemote(_ arguments: [String], on connection: RemoteConnection, in directory: String, timeout: Double,
                                  includeErrors: Bool, extraEnvironment: [String: String]) -> (status: Int32, output: Data)? {
        guard let remote = connection.map.remote(directory) else { return nil }
        var environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        for (key, value) in extraEnvironment where key != "PATH" {
            environment[key] = value.split(separator: ":", omittingEmptySubsequences: false)
                .map { connection.map.remote(String($0)) ?? String($0) }.joined(separator: ":")
        }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(ShellQuote.quote($0.value))" }.joined(separator: " ")
        let mapped = arguments.map { connection.map.remote($0) ?? $0 }
        let script = "cd \(ShellQuote.quote(remote)) && env \(assignments) git \(RemoteShell.arguments(mapped))" + (includeErrors ? " 2>&1" : " 2>/dev/null")
        guard let result = connection.run(script, timeout: timeout) else { return nil }
        guard arguments.first == "rev-parse" else { return (result.status, result.output) }
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("/") ? connection.map.local(String(line)) : String(line)
        }
        return (result.status, Data(lines.joined(separator: "\n").utf8))
    }

    /// Without running git: a `.git` in the folder or above it. Only for saying git is missing.
    public static func looksLikeRepository(_ folder: String) -> Bool {
        var current = folder
        while !current.isEmpty, current != "/" {
            if FileManager.default.fileExists(atPath: current + "/.git") { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
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

    // MARK: Worktrees

    /// Where a branch's worktree goes: beside the repository, in a folder of its own, so it never
    /// shows up as changes in the repository itself.
    public static func worktreePath(root: String, branch: String) -> String {
        let parent = (root as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        return parent + "/" + name + ".worktrees/" + slug
    }

    /// The repository's main checkout, even from inside another worktree, which shouldn't nest.
    public static func mainWorktree(of folder: String) -> String? {
        guard let current = repositoryRoot(of: folder) else { return nil }
        guard let result = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: current), result.status == 0 else { return current }
        let common = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return common.hasSuffix("/.git") ? String(common.dropLast(5)) : current
    }

    public static func isPlausibleBranch(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasSuffix("/") && !name.hasSuffix(".lock") && !name.contains("..")
            && name.allSatisfy { !$0.isWhitespace && !"~^:?*[\\".contains($0) }
    }

    /// A second checkout of the repository, so another agent can work at the same time without
    /// their edits mixing. A branch that exists is checked out there, and otherwise it's made.
    public static func addWorktree(branch: String, in folder: String) -> Result<String, TransferFailure> {
        guard isPlausibleBranch(branch) else { return .failure(TransferFailure(message: "\(branch) can't be a branch name.")) }
        guard let root = mainWorktree(of: folder) else { return .failure(TransferFailure(message: "This folder isn't in a git repository.")) }
        let path = worktreePath(root: root, branch: branch)
        let exists = run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: root)?.status == 0
        let arguments = exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path]
        guard let result = run(arguments, in: root, timeout: 300, includeErrors: true) else {
            return .failure(TransferFailure(message: "Couldn't run git."))
        }
        guard result.status == 0 else { return .failure(TransferFailure(message: failureMessage(String(decoding: result.output, as: UTF8.self)))) }
        return .success(path)
    }

    /// Changes under a workspace folder, reported by the path that folder is known by.
    public static func changes(in folder: String) -> [ChangedFile] { scanChanges(in: folder).files }

    /// VS Code's git stops at the same number: past it, a list is no use to read, and the rest only costs.
    public static let changesLimit = 10_000

    /// Changes, and whether they're all of them. A git that took too long hasn't said there are none.
    public static func scanChanges(in folder: String, limit: Int = changesLimit, timeout: Double = 20) -> ChangesScan {
        guard let root = repositoryRoot(of: folder) else { return ChangesScan() }
        // A rename is two fields, so twice as many fields always holds `limit` changes and one more.
        guard let result = ran(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], in: folder, timeout: timeout,
                               records: 2 * limit + 2) else {
            return ChangesScan()
        }
        if result.timedOut { return ChangesScan(timedOut: true) }
        guard result.status == 0 else { return ChangesScan() }
        var output = result.output
        // A field cut off in the middle isn't a file.
        if result.cut, let end = output.lastIndex(of: 0) { output = output.prefix(through: end) }
        var found = GitStatusParser.parse(String(decoding: output, as: UTF8.self), root: root)
        let limited = result.cut || found.count > limit
        if found.count > limit { found = Array(found.prefix(limit)) }
        // What a server's git says is what a server says.
        if RemoteRegistry.shared.isRemote(folder) { found.removeAll { RemotePathMap.climbs($0.path) } }
        let realFolder = real(folder)
        // git reports real paths. The workspace may know this folder by a link to it.
        return ChangesScan(files: found.map { file in
            var file = file
            if file.path.hasPrefix(realFolder + "/") {
                file.path = folder + file.path.dropFirst(realFolder.count)
            }
            return file
        }, limited: limited)
    }

    /// All the changes in a workspace, in the order the explorer would show them.
    public static func changesAcross(_ folders: [String]) -> [ChangedFile] { scanChangesAcross(folders).files }

    /// The same, saying whether it's all of them. One folder that took too long makes the whole look
    /// untrustworthy, so it says so rather than show the others' as everything.
    public static func scanChangesAcross(_ folders: [String], limit: Int = changesLimit, timeout: Double = 20) -> ChangesScan {
        var seen = Set<String>()
        var scan = ChangesScan()
        for folder in folders {
            let found = scanChanges(in: folder, limit: limit, timeout: timeout)
            if found.timedOut { return ChangesScan(timedOut: true) }
            scan.limited = scan.limited || found.limited
            for file in found.files.sorted(by: { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending })
            where seen.insert(file.path).inserted {
                guard scan.files.count < limit else {
                    scan.limited = true
                    break
                }
                scan.files.append(file)
            }
        }
        return scan
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
        // git only sees a rename when it's asked about both names.
        let old = renameSource(of: relative, revisions: ["HEAD"], in: root)
        let paths = [relative] + (old.map { [$0] } ?? [])
        if let result = run(["diff", "HEAD", "-M", "--no-color", "--no-ext-diff", "-U3", "--"] + paths, in: root), result.status == 0 {
            var diff = DiffParser.parse(String(decoding: result.output, as: UTF8.self))
            diff.oldRelative = old
            return diff
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
        // Here it may be only a placeholder, and a new file is all contents.
        if let connection = RemoteRegistry.shared.connection(forLocal: path), let remote = connection.map.remote(path) {
            guard let result = connection.run("head -c 4194304 -- \(ShellQuote.quote(remote))", timeout: 30), result.succeeded else { return FileDiff() }
            guard FileClassifier.isLikelyText(result.output.prefix(8192)) else { return FileDiff(isBinary: true) }
            return .allAdded(result.text)
        }
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
    /// `commit` names the commit the rows are from, if they're from one.
    public static func text<Rows: Sequence>(path: String, rows: Rows, commit: String? = nil) -> String where Rows.Element == DiffLine {
        let name = (path as NSString).lastPathComponent
        let origin = commit.map { "the changes in \(name), in commit \($0)" } ?? "the changes in \(name)"
        return "From \(origin):\n```diff\n\(self.rows(rows))\n```\n"
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
