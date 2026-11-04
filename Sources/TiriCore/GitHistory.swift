import Foundation

/// What a diff compares.
public enum DiffTarget: Hashable, Sendable {
    /// Everything since the last commit.
    case head
    /// Everything since the branch left its base, uncommitted work included.
    case branch
    /// What one commit did, by its full hash.
    case commit(String)
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
