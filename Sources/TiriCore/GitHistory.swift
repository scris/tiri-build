import Foundation

/// What a diff compares.
public enum DiffTarget: Hashable, Sendable {
    /// Everything since the last commit.
    case head
    /// Everything since the branch left its base, uncommitted work included.
    case branch
    /// What one commit did, by its full hash.
    case commit(String)
    /// What a branch that isn't checked out here has done: from where it left its base, to its tip.
    case range(from: String, to: String)
}

/// A branch or a worktree besides the one in front, usually an agent's, in plain terms.
public struct WorkLine: Hashable, Identifiable, Sendable {
    public var root: String
    public var branch: String
    /// Where it's checked out, if it is.
    public var worktree: String?
    public var base: String
    /// Where it left its base, and its newest commit.
    public var from: String
    public var tip: String
    public var commits: Int
    public var files: Int
    /// Changed in its worktree and not committed.
    public var uncommitted: Int
    public var merged: Bool
    public var subject: String
    public var date: Date

    public var id: String { root + "#" + branch }

    public init(root: String, branch: String, worktree: String?, base: String, from: String, tip: String, commits: Int, files: Int,
                uncommitted: Int, merged: Bool, subject: String, date: Date) {
        self.root = root
        self.branch = branch
        self.worktree = worktree
        self.base = base
        self.from = from
        self.tip = tip
        self.commits = commits
        self.files = files
        self.uncommitted = uncommitted
        self.merged = merged
        self.subject = subject
        self.date = date
    }

    /// Whether there's anything to bring in.
    public var isUnfinished: Bool { !merged || uncommitted > 0 }

    public var summary: String {
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file changed" : "\(files) files changed") }
        if uncommitted > 0 { parts.append("\(uncommitted) not committed") }
        if merged, uncommitted == 0 {
            parts.append("merged into \(base)")
        } else if commits > 0 {
            parts.append(commits == 1 ? "1 commit, not merged" : "\(commits) commits, not merged")
        } else if parts.isEmpty {
            parts.append("nothing yet")
        }
        return parts.joined(separator: " · ")
    }

    /// `git worktree list --porcelain`: stanzas with `worktree`, `HEAD`, and `branch` or `detached`.
    static func parseWorktrees(_ output: String) -> [(path: String, branch: String?)] {
        var found: [(path: String, branch: String?)] = []
        var path: String?
        var branch: String?
        func finish() {
            if let path { found.append((path, branch)) }
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                finish()
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        finish()
        return found
    }

    /// The agent's request, since Git is its job.
    public var mergeRequest: String {
        var text = "Please merge the branch `\(branch)` into `\(base)`"
        if uncommitted > 0, let worktree { text += ", including what's not committed yet in \(worktree)" }
        text += ". Resolve any conflicts, and tell me if anything needs my decision."
        if let worktree { text += " Remove the worktree at \(worktree) once it's in." }
        return text
    }

    public var cleanUpRequest: String {
        if let worktree { return "The branch `\(branch)` is already merged into `\(base)`. Please remove its worktree at \(worktree) and delete the branch." }
        return "The branch `\(branch)` is already merged into `\(base)`. Please delete it."
    }
}

/// One row of the commit list.
public struct CommitSummary: Hashable, Identifiable, Sendable {
    public var root: String
    public var oid: String
    public var shortOID: String
    public var subject: String
    public var author: String
    public var date: Date
    public var parents: [String]
    public var id: String { root + "@" + oid }
    public var isMerge: Bool { parents.count > 1 }

    public init(root: String, oid: String, shortOID: String, subject: String, author: String, date: Date, parents: [String]) {
        self.root = root
        self.oid = oid
        self.shortOID = shortOID
        self.subject = subject
        self.author = author
        self.date = date
        self.parents = parents
    }
}

/// What a repository's branch is compared with.
public struct BranchBase: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// `name` at `commit`, the point where this branch left it.
        case found(name: String, commit: String, shortCommit: String)
        /// This is the base branch, so there's nothing to compare it with.
        case isBase(name: String)
        /// It has no main or master, and no origin/HEAD.
        case none
        /// `name` exists, but shares no history with this branch.
        case unrelated(name: String)
        case noCommits
    }

    public var root: String
    public var state: State

    public init(root: String, state: State) {
        self.root = root
        self.state = state
    }

    public var commit: String? {
        if case .found(_, let commit, _) = state { return commit }
        return nil
    }

    /// Plain words, for the Changes section and `tiri changes --branch`.
    public var description: String {
        switch state {
        case .found(let name, _, let short): "Since \(name) (\(short))"
        case .isBase(let name): "This is \(name), so only uncommitted work shows"
        case .none: "No main branch to compare with, so only uncommitted work shows"
        case .unrelated(let name): "Shares no history with \(name), so only uncommitted work shows"
        case .noCommits: "No commits yet, so everything is new"
        }
    }

    /// What the Changes section says when there's nothing to list.
    public var emptyDescription: String {
        switch state {
        case .found(let name, _, _): "Nothing changed since \(name)."
        case .noCommits: "No commits yet, and no files."
        default: "No uncommitted changes."
        }
    }

    /// Which ref to compare with, from the names that exist: the remote's default branch first,
    /// then main or master there, then here. A local main can be behind the remote's, and using
    /// it would count other people's commits as this branch's.
    static func chooseBase(refs: [(name: String, symref: String)]) -> String? {
        if let head = refs.first(where: { $0.name == "refs/remotes/origin/HEAD" }), !head.symref.isEmpty {
            return head.symref
        }
        let order = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        return order.first { wanted in refs.contains { $0.name == wanted } }
    }

    /// `refs/remotes/origin/main` as a person would say it.
    static func shortName(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }
}

public enum GitNameStatusParser {
    /// `git diff --name-status -z`: `M\0path\0`, or `R100\0old\0new\0` for a rename.
    public static func parse(_ output: String, root: String) -> [ChangedFile] {
        var result: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let code = fields.popFirst(), let first = code.first {
            var old: String?
            if first == "R" || first == "C" { old = fields.popFirst() }
            guard let relative = fields.popFirst() else { break }
            let status: ChangeStatus = switch first {
            case "A", "C": .added
            case "D": .deleted
            case "R": .renamed
            case "U": .conflicted
            default: .modified
            }
            result.append(ChangedFile(path: root + "/" + relative, root: root, relative: relative, status: status,
                                      oldRelative: first == "R" ? old : nil))
        }
        return result
    }
}

public enum CommitLogParser {
    static let format = "%H%x1f%h%x1f%ct%x1f%P%x1f%an%x1f%s"

    /// `git log -z --format=…`, one commit per field.
    public static func parse(_ output: String, root: String) -> [CommitSummary] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
            let parts = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6, let seconds = TimeInterval(parts[2]) else { return nil }
            return CommitSummary(root: root, oid: parts[0], shortOID: parts[1],
                                 subject: parts[5...].joined(separator: " "), author: parts[4],
                                 date: Date(timeIntervalSince1970: seconds),
                                 parents: parts[3].split(separator: " ").map(String.init))
        }
    }
}

public enum RelativeTime {
    /// "just now", "5 minutes ago", "yesterday"; past a month, the date.
    public static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = days < 300 ? "MMM d" : "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// Lines of a file that differ from the last commit, for the marks beside its line numbers.
public struct LineChanges: Equatable, Sendable {
    public enum Kind: Sendable { case added, modified }
    /// Counting from 1.
    public var lines: [Int: Kind] = [:]
    /// Lines were deleted just before this one. Can be one past the end of the file.
    public var deletions: Set<Int> = []
    /// Where each change starts, in order.
    public var starts: [Int] = []
    public var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    public init() {}

    /// `git diff -U0`: only its `@@ -12,3 +14,5 @@` headers matter.
    public static func parse(_ output: String) -> LineChanges {
        var result = LineChanges()
        for line in output.split(separator: "\n") where line.hasPrefix("@@ ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { continue }
            func range(_ part: Substring) -> (start: Int, count: Int)? {
                let numbers = part.dropFirst().split(separator: ",")
                guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
                return (start, numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1)
            }
            guard let old = range(parts[1]), let new = range(parts[2]) else { continue }
            if new.count == 0 {
                // `+4,0` means after line 4.
                result.deletions.insert(new.start + 1)
                result.starts.append(new.start + 1)
            } else {
                let kind: Kind = old.count == 0 ? .added : .modified
                for number in new.start..<(new.start + new.count) { result.lines[number] = kind }
                result.starts.append(new.start)
            }
        }
        return result
    }
}

/// A file before and after, as bytes. For what can't be compared line by line, like an image.
public struct FileVersions: Sendable {
    public var old: Data?
    public var new: Data?
    public init(old: Data? = nil, new: Data? = nil) {
        self.old = old
        self.new = new
    }
}

/// History, read through `Git.runGit` like everything else that asks git. Nothing here reads a
/// repository's files itself. The only local read is a working tree's own copy of a file, in `workingCopy`.
extension Git {
    /// Past this, a commit's copy of a file isn't fetched into memory to look at.
    static let largestVersion = 64 * 1024 * 1024

    private static func text(_ arguments: [String], in directory: String) -> String? {
        guard let result = runGit(arguments, in: directory), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    private static func line(_ arguments: [String], in directory: String) -> String? {
        text(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// A file's repository and its path inside it. A deleted file's folder can be gone too.
    static func locate(_ path: String) -> (root: String, relative: String)? {
        var directory = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/" {
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard let root = repositoryRoot(of: directory) else { return nil }
        let realPath = real(path)
        let realRoot = real(root)
        guard realPath.hasPrefix(realRoot + "/") else { return nil }
        return (root, String(realPath.dropFirst(realRoot.count + 1)))
    }

    /// The repository a file is in, or was in if it's been deleted.
    public static func repositoryRoot(ofFile path: String) -> String? { locate(path)?.root }

    /// A revision as its full hash, if it's a commit in this repository.
    public static func resolveCommit(_ revision: String, in folder: String) -> String? {
        guard !revision.isEmpty, !revision.hasPrefix("-") else { return nil }
        return line(["rev-parse", "--verify", "--quiet", revision + "^{commit}"], in: folder)
    }

    /// A revision, in the first of the workspace's repositories that has it.
    public static func findCommit(_ revision: String, in folders: [String]) -> CommitSummary? {
        for folder in folders {
            if let root = repositoryRoot(of: folder), let oid = resolveCommit(revision, in: root),
               let commit = commitSummary(oid, in: root) { return commit }
        }
        return nil
    }

    /// One commit's row, for a tab or a caption that names it.
    public static func commitSummary(_ oid: String, in root: String) -> CommitSummary? {
        guard !oid.hasPrefix("-"), let output = text(["log", "-1", "-z", "--format=" + CommitLogParser.format, oid, "--"], in: root) else { return nil }
        return CommitLogParser.parse(output, root: root).first
    }

    /// The newest commits across the workspace's folders. A folder inside a repository only shows
    /// commits that touched it, the same as its changes do.
    public static func recentCommits(in folders: [String], limit: Int = 30) -> [CommitSummary] {
        var byRoot: [(root: String, paths: [String])] = []
        for folder in folders {
            guard let root = repositoryRoot(of: folder) else { continue }
            let realRoot = real(root)
            let realFolder = real(folder)
            let relative = realFolder == realRoot ? "" : String(realFolder.dropFirst(realRoot.count + 1))
            if let index = byRoot.firstIndex(where: { $0.root == root }) {
                byRoot[index].paths.append(relative)
            } else {
                byRoot.append((root, [relative]))
            }
        }
        var commits: [CommitSummary] = []
        for (root, paths) in byRoot {
            // Naming the root as a path would make git skip merges.
            let scope = paths.contains("") ? [] : paths
            let arguments = ["log", "-n", String(limit), "-z", "--format=" + CommitLogParser.format, "--"] + scope
            guard let output = text(arguments, in: root) else { continue }
            commits += CommitLogParser.parse(output, root: root)
        }
        // One repository's are already in git's order, which keeps parents after their children.
        return byRoot.count > 1 ? Array(commits.sorted { $0.date > $1.date }.prefix(limit)) : commits
    }

    /// What this repository's branch is compared with, and where it left it.
    public static func branchBase(root: String) -> BranchBase {
        guard let head = line(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root) else {
            return BranchBase(root: root, state: .noCommits)
        }
        let wanted = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        let listed = text(["for-each-ref", "--format=%(refname)%00%(symref)"] + wanted, in: root) ?? ""
        let refs: [(name: String, symref: String)] = listed.split(whereSeparator: \.isNewline).map { row in
            let parts = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        guard let ref = BranchBase.chooseBase(refs: refs) else { return BranchBase(root: root, state: .none) }
        let name = BranchBase.shortName(ref)
        if ref.hasPrefix("refs/heads/"), line(["symbolic-ref", "--quiet", "HEAD"], in: root) == ref {
            return BranchBase(root: root, state: .isBase(name: name))
        }
        guard let commit = line(["merge-base", head, ref], in: root) else {
            return BranchBase(root: root, state: .unrelated(name: name))
        }
        let short = line(["rev-parse", "--short", commit], in: root) ?? String(commit.prefix(7))
        return BranchBase(root: root, state: .found(name: name, commit: commit, shortCommit: short))
    }

    /// git reports real paths. The workspace may know this folder by a link to it.
    private static func seen(_ files: [ChangedFile], through folder: String) -> [ChangedFile] {
        let realFolder = real(folder)
        return files.map { file in
            var file = file
            if file.path.hasPrefix(realFolder + "/") { file.path = folder + file.path.dropFirst(realFolder.count) }
            return file
        }
    }

    private static func namesChanged(_ revisions: [String], in folder: String, root: String) -> [ChangedFile] {
        // Paths come back from the top of the repository, whatever someone's config says.
        guard let output = text(["diff", "--name-status", "-M", "-z", "--no-ext-diff", "--no-relative"] + revisions + ["--", "."], in: folder) else { return [] }
        return seen(GitNameStatusParser.parse(output, root: root), through: folder)
    }

    /// Everything since each repository's branch left its base, with what isn't committed yet.
    public static func branchChanges(in folders: [String]) -> (bases: [BranchBase], files: [ChangedFile]) {
        var bases: [BranchBase] = []
        var seenPaths = Set<String>()
        var files: [ChangedFile] = []
        for folder in folders {
            guard let root = repositoryRoot(of: folder) else { continue }
            let base = bases.first { $0.root == root } ?? branchBase(root: root)
            if !bases.contains(where: { $0.root == root }) { bases.append(base) }
            var found: [ChangedFile]
            if let commit = base.commit {
                found = namesChanged([commit], in: folder, root: root)
                // A diff against a commit leaves out what git doesn't track yet.
                found += changes(in: folder).filter { $0.status == .untracked }
            } else {
                found = changes(in: folder)
            }
            for file in found.sorted(by: { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending })
            where seenPaths.insert(file.path).inserted {
                files.append(file)
            }
        }
        return (bases, files)
    }

    /// Worktrees and recent unmerged branches besides what each folder has checked out.
    public static func otherWork(in folders: [String], now: Date = Date()) -> [WorkLine] {
        var roots: [String] = []
        for folder in folders {
            if let root = repositoryRoot(of: folder), !roots.contains(root) { roots.append(root) }
        }
        var lines: [WorkLine] = []
        var seen = Set<String>()
        for root in roots {
            let connection = RemoteRegistry.shared.connection(forLocal: root)
            let base: String
            switch branchBase(root: root).state {
            case .found(let name, _, _), .isBase(let name): base = name
            default: continue
            }
            let current = line(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
            let worktrees = WorkLine.parseWorktrees(text(["worktree", "list", "--porcelain"], in: root) ?? "")
            var byBranch: [String: String] = [:]
            for worktree in worktrees {
                guard let branch = worktree.branch else { continue }
                // Paths come from git, so on a server they're the server's.
                let local = connection.map { $0.learn(remote: worktree.path); return $0.map.local(worktree.path) } ?? worktree.path
                byBranch[branch] = local
            }
            let listing = text(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%00%(objectname)%00%(committerdate:unix)%00%(subject)", "refs/heads"], in: root) ?? ""
            for row in listing.split(whereSeparator: \.isNewline).prefix(200) {
                let parts = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { continue }
                let branch = parts[0]
                let tip = parts[1]
                let date = Date(timeIntervalSince1970: Double(parts[2]) ?? 0)
                guard branch != current, branch != base, !folders.contains(where: { byBranch[branch] == $0 }) else { continue }
                let worktree = byBranch[branch]
                // Without a checkout, an old branch is history rather than work.
                guard worktree != nil || now.timeIntervalSince(date) < 30 * 24 * 3600 else { continue }
                let merged = runGit(["merge-base", "--is-ancestor", tip, base], in: root)?.status == 0
                if merged, worktree == nil { continue }
                guard seen.insert(root + "#" + branch).inserted, lines.count < 20 else { continue }
                let from = line(["merge-base", base, tip], in: root) ?? tip
                let commits = line(["rev-list", "--count", base + ".." + tip], in: root).flatMap { Int($0) } ?? 0
                let files = text(["diff", "--name-only", "--no-ext-diff", from, tip], in: root)?.split(whereSeparator: \.isNewline).count ?? 0
                let uncommitted = worktree.flatMap { text(["status", "--porcelain"], in: $0)?.split(whereSeparator: \.isNewline).count } ?? 0
                lines.append(WorkLine(root: root, branch: branch, worktree: worktree, base: base, from: from, tip: tip, commits: commits,
                                      files: files, uncommitted: uncommitted, merged: merged, subject: parts[3], date: date))
            }
        }
        return lines
    }

    /// The files one of those has changed.
    public static func changes(of work: WorkLine) -> [ChangedFile] {
        if let worktree = work.worktree { return branchChanges(in: [worktree]).files }
        return namesChanged([work.from, work.tip], in: work.root, root: work.root).sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
    }

    /// What to compare a commit with. A merge is compared with its first parent, which shows
    /// what it brought in. A root commit is compared with nothing.
    static func parentForDiff(of oid: String, in root: String) -> String? {
        line(["rev-parse", "--verify", "--quiet", oid + "^1^{commit}"], in: root)
            ?? line(["hash-object", "-t", "tree", "/dev/null"], in: root)
    }

    /// What one commit changed, under the workspace's folders in its repository.
    public static func commitChanges(_ oid: String, root: String, in folders: [String]) -> [ChangedFile] {
        guard !oid.hasPrefix("-"), let parent = parentForDiff(of: oid, in: root) else { return [] }
        let realRoot = real(root)
        var seenPaths = Set<String>()
        var files: [ChangedFile] = []
        for folder in folders {
            let realFolder = real(folder)
            guard realFolder == realRoot || realFolder.hasPrefix(realRoot + "/") else { continue }
            for file in namesChanged([parent, oid], in: folder, root: root) where seenPaths.insert(file.path).inserted {
                files.append(file)
            }
        }
        return files.sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
    }

    /// The revisions a target compares, for one repository. The second is nil for the working
    /// tree. Nil altogether means the commit isn't there, or there's nothing to compare with.
    private static func revisions(of target: DiffTarget, root: String) -> (from: String, to: String?)? {
        switch target {
        case .head:
            return line(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root).map { ($0, nil) }
        case .branch:
            let base = branchBase(root: root)
            return (base.commit ?? line(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)).map { ($0, nil) }
        case .commit(let oid):
            guard resolveCommit(oid, in: root) != nil, let parent = parentForDiff(of: oid, in: root) else { return nil }
            return (parent, oid)
        case .range(let from, let to):
            return (from, to)
        }
    }

    /// One file's changes. Nil if the commit it asks about can't be found any more.
    public static func diff(path: String, target: DiffTarget) -> FileDiff? {
        if target == .head { return diff(path: path) }
        guard let (root, relative) = locate(path) else {
            if case .commit = target { return nil }
            return diff(path: path)
        }
        guard let (from, to) = revisions(of: target, root: root) else {
            if case .commit = target { return nil }
            return diff(path: path)
        }
        // What git doesn't track isn't in a diff against a commit, and it's all new anyway.
        if to == nil, let status = text(["status", "--porcelain=v1", "-z", "--", relative], in: root), status.hasPrefix("??") {
            return diff(path: path)
        }
        let revisions = [from] + (to.map { [$0] } ?? [])
        let old = renameSource(of: relative, revisions: revisions, in: root)
        let paths = [relative] + (old.map { [$0] } ?? [])
        guard let output = text(["diff", "-M", "--no-color", "--no-ext-diff", "-U3"] + revisions + ["--"] + paths, in: root) else {
            return FileDiff()
        }
        var result = DiffParser.parse(output)
        result.oldRelative = old
        return result
    }

    /// Where a file came from, if it was renamed. git only sees a rename when it's asked about both names.
    static func renameSource(of relative: String, revisions: [String], in root: String) -> String? {
        guard let output = text(["diff", "--name-status", "-M", "-z", "--no-ext-diff"] + revisions, in: root) else { return nil }
        return GitNameStatusParser.parse(output, root: root).first { $0.relative == relative }?.oldRelative
    }

    private static func blob(_ revision: String, _ relative: String, in root: String) -> Data? {
        let name = revision + ":" + relative
        guard let size = line(["cat-file", "-s", name], in: root).flatMap({ Int($0) }), size <= largestVersion,
              let result = runGit(["show", name], in: root), result.status == 0 else { return nil }
        return result.output
    }

    /// The file as it is on disk: the one thing that doesn't come from git.
    private static func workingCopy(_ path: String) -> Data? {
        // On a server, the copy here may be only a placeholder.
        if let connection = RemoteRegistry.shared.connection(forLocal: path), let remote = connection.map.remote(path) {
            guard let result = connection.run("head -c \(largestVersion) -- \(ShellQuote.quote(remote))", timeout: 120), result.succeeded else { return nil }
            return result.output
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: largestVersion)
    }

    /// The file before and after, as the diff for `target` compares them.
    public static func versions(path: String, target: DiffTarget) -> FileVersions {
        guard let (root, relative) = locate(path), let (from, to) = revisions(of: target, root: root) else {
            return FileVersions(new: workingCopy(path))
        }
        let revisions = [from] + (to.map { [$0] } ?? [])
        let oldName = renameSource(of: relative, revisions: revisions, in: root) ?? relative
        return FileVersions(old: blob(from, oldName, in: root),
                            new: to.map { blob($0, relative, in: root) } ?? workingCopy(path))
    }

    /// Which lines differ from the last commit, for a file in a repository. Nothing for a file
    /// git doesn't track. git applies the repository's filters, so line endings aren't mistaken for changes.
    public static func lineChanges(relative: String, root: String) -> LineChanges {
        guard let output = text(["diff", "HEAD", "-U0", "--no-color", "--no-ext-diff", "--", relative], in: root) else { return LineChanges() }
        return LineChanges.parse(output)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The stretch of added and removed lines a line belongs to.
public enum DiffHunks {
    public static func change(around index: Int, in lines: [DiffLine]) -> ClosedRange<Int>? {
        func isChange(_ position: Int) -> Bool { lines[position].kind == .added || lines[position].kind == .removed }
        guard lines.indices.contains(index), isChange(index) else { return nil }
        var first = index
        var last = index
        while first > 0, isChange(first - 1) { first -= 1 }
        while last + 1 < lines.count, isChange(last + 1) { last += 1 }
        return first...last
    }
}

/// What to say to an agent about a change. The agent does the work, including any Git it takes.
public enum ChangeRequest {
    public enum Kind: Sendable { case undo, ask }

    public static func prompt(_ kind: Kind, path: String, commit: String? = nil, lines: [DiffLine]?) -> String {
        let name = "`\(path)`"
        let source = commit.map { " from commit \(String($0.prefix(10)))" } ?? ""
        guard let lines, !lines.isEmpty else {
            return kind == .undo ? "Please undo your changes\(source) to \(name)." : "What did you change\(source) in \(name), and why?"
        }
        let quote = "```diff\n" + DiffQuote.rows(lines) + "\n```"
        switch kind {
        case .undo: return "Please undo this change\(source) in \(name), and leave everything else as it is:\n\(quote)"
        case .ask: return "What does this change\(source) in \(name) do, and why did you make it?\n\(quote)"
        }
    }
}

