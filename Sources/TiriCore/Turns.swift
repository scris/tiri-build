import CryptoKit
import Foundation

/// One turn of an agent's conversation: from your prompt until it stopped. "Changed since the
/// last commit" blurs several turns and several agents together. This is what one of them did.
public struct AgentTurn: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workspace: WorkspaceID
    /// The terminal it ran in.
    public var item: ItemID
    public var title: String
    public var prompt: String?
    public var started: Date
    public var ended: Date?
    /// Each repository's tree when the turn started, and when it ended.
    public var startTrees: [String: String]
    public var endTrees: [String: String]

    public init(id: String = TiriID.make("t"), workspace: WorkspaceID, item: ItemID, title: String, prompt: String? = nil,
                started: Date = Date(), ended: Date? = nil, startTrees: [String: String] = [:], endTrees: [String: String] = [:]) {
        self.id = id
        self.workspace = workspace
        self.item = item
        self.title = title
        self.prompt = prompt
        self.started = started
        self.ended = ended
        self.startTrees = startTrees
        self.endTrees = endTrees
    }

    public var isOpen: Bool { ended == nil }
    /// A turn that only talked changed nothing, and isn't worth offering.
    public var changedNothing: Bool { !isOpen && startTrees == endTrees }

    /// Whether another agent's turn ran at the same time in the same repository, which means
    /// either could have made any of the changes.
    public func overlaps(_ other: AgentTurn, now: Date = Date()) -> Bool {
        guard other.id != id, other.item != item else { return false }
        guard !Set(startTrees.keys).isDisjoint(with: other.startTrees.keys) else { return false }
        return started < (other.ended ?? now) && other.started < (ended ?? now)
    }

    /// The first line of the prompt, cut to fit a menu.
    public static func shortPrompt(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line.count > 72 ? String(line.prefix(71)) + "…" : line
    }
}

/// Which changes the sidebar is showing.
public enum ChangesScope: Hashable, Sendable {
    case sinceCommit
    /// Whichever turn is newest, as they come.
    case latestTurn
    case turn(String)
    /// Everything since the branch left its base, uncommitted work included.
    case branch
    /// The list of recent commits.
    case recentCommits
    /// What one commit changed.
    case commit(CommitSummary)
    /// Branches and worktrees besides this one, usually agents'.
    case otherWork
    /// What one of those has changed.
    case work(WorkLine)
}

extension Array where Element == AgentTurn {
    /// The turn a scope means, among one workspace's turns.
    public func resolving(_ scope: ChangesScope, in workspace: WorkspaceID) -> AgentTurn? {
        switch scope {
        case .sinceCommit, .branch, .recentCommits, .commit, .otherWork, .work:
            return nil
        case .latestTurn:
            return last { $0.workspace == workspace && !$0.changedNothing }
        case .turn(let id):
            return first { $0.id == id }
        }
    }

    /// Old turns go, and each workspace keeps a limited number.
    public func trimmed(now: Date = Date(), maximumAge: TimeInterval = 7 * 24 * 3600, perWorkspace: Int = 40) -> [AgentTurn] {
        var kept = filter { $0.isOpen || now.timeIntervalSince($0.ended ?? now) < maximumAge }
        for workspace in Set(kept.map(\.workspace)) {
            let mine = kept.filter { $0.workspace == workspace }
            guard mine.count > perWorkspace else { continue }
            let dropped = Set(mine.prefix(mine.count - perWorkspace).map(\.id))
            kept.removeAll { dropped.contains($0.id) }
        }
        return kept
    }
}

/// Copies of the working tree, kept in Tiri's own folder. Git's own index and object store are
/// pointed elsewhere while it runs, so nothing changes in the repository: no branch, no stash, no
/// staged change and no new object. Only git's view of what's already in the repository is shared.
public final class TurnSnapshots: Sendable {
    public let directory: URL
    /// One index per repository, and an index can't be shared. Nothing here needs to be quick,
    /// and one lock is simpler than one per repository.
    private static let lock = NSLock()

    public init(directory: URL = TiriPaths.supportDirectory.appendingPathComponent("snapshots", isDirectory: true)) {
        self.directory = directory
    }

    private func storeDirectory(for root: String) -> URL {
        let hash = SHA256.hash(data: Data(root.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        // On a server, git runs there, so its snapshots live there. Named as local paths here, and
        // translated like every other path that goes to it.
        if let connection = RemoteRegistry.shared.connection(forLocal: root), let bin = connection.binDirectory {
            let base = (bin as NSString).deletingLastPathComponent + "/snapshots/" + hash
            return URL(fileURLWithPath: connection.map.local(base), isDirectory: true)
        }
        return directory.appendingPathComponent(hash, isDirectory: true)
    }

    private func environment(root: String, store: URL) -> [String: String]? {
        guard let objects = Git.runGit(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: root),
              objects.status == 0 else { return nil }
        let shared = String(decoding: objects.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["GIT_INDEX_FILE": store.appendingPathComponent("index").path,
                "GIT_OBJECT_DIRECTORY": store.appendingPathComponent("objects").path,
                "GIT_ALTERNATE_OBJECT_DIRECTORIES": shared]
    }

    /// The working tree as a tree object, leaving out what .gitignore does. Nil if it can't be read.
    public func snapshot(root: String) -> String? {
        let manager = FileManager.default
        let store = storeDirectory(for: root)
        let index = store.appendingPathComponent("index")
        // Not under the lock below: a slow server shouldn't hold up anything else's snapshot.
        if let connection = RemoteRegistry.shared.connection(forLocal: root) {
            guard let environment = environment(root: root, store: store),
                  let remoteStore = connection.map.remote(store.path) else { return nil }
            let found = Git.runGit(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root)
            let existing = found.flatMap { connection.map.remote(String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? ""
            let quotedStore = ShellQuote.quote(remoteStore)
            _ = connection.run("mkdir -p \(quotedStore)/objects; rm -f \(quotedStore)/index.lock; [ -e \(quotedStore)/index ] || cp \(ShellQuote.quote(existing)) \(quotedStore)/index 2>/dev/null; true")
            _ = Git.runGit(["add", "-A", "--ignore-errors", "--", "."], in: root, environment: environment, timeout: 60)
            guard let tree = Git.runGit(["write-tree"], in: root, environment: environment), tree.status == 0 else { return nil }
            let id = String(decoding: tree.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? manager.createDirectory(at: store.appendingPathComponent("objects"), withIntermediateDirectories: true)
        guard let environment = environment(root: root, store: store) else { return nil }
        // Left by a run that was killed.
        try? manager.removeItem(at: store.appendingPathComponent("index.lock"))
        if !manager.fileExists(atPath: index.path),
           let found = Git.runGit(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root), found.status == 0 {
            // Knowing what git knows means it only has to read files that changed.
            let existing = String(decoding: found.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try? manager.copyItem(atPath: existing, toPath: index.path)
        }
        // A file that can't be read shouldn't cost the whole snapshot.
        _ = Git.runGit(["add", "-A", "--ignore-errors", "--", "."], in: root, environment: environment, timeout: 60)
        guard let tree = Git.runGit(["write-tree"], in: root, environment: environment), tree.status == 0 else { return nil }
        let id = String(decoding: tree.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    public func snapshotAll(roots: [String]) -> [String: String] {
        var trees: [String: String] = [:]
        for root in Set(roots) {
            if let tree = snapshot(root: root) { trees[root] = tree }
        }
        return trees
    }

    /// What's different between two snapshots, with paths given as `root/relative`.
    public func changes(root: String, from: String, to: String) -> [ChangedFile] {
        guard from != to, let environment = environment(root: root, store: storeDirectory(for: root)),
              let result = Git.runGit(["diff", "--no-renames", "--name-status", "-z", from, to], in: root, environment: environment),
              result.status == 0 else { return [] }
        let fields = String(decoding: result.output, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var found: [ChangedFile] = []
        var index = 0
        while index + 1 < fields.count {
            let relative = fields[index + 1]
            let status: ChangeStatus = switch fields[index].first {
            case "A": .added
            case "D": .deleted
            default: .modified
            }
            found.append(ChangedFile(path: root + "/" + relative, root: root, relative: relative, status: status))
            index += 2
        }
        return found
    }

    public func diff(root: String, relative: String, from: String, to: String) -> FileDiff {
        guard let environment = environment(root: root, store: storeDirectory(for: root)),
              let result = Git.runGit(["diff", "--no-color", "--no-ext-diff", "--no-renames", "-U3", from, to, "--", relative],
                                      in: root, environment: environment),
              result.status == 0 else { return FileDiff() }
        return DiffParser.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// A file before and after a turn, as bytes. For what can't be compared line by line.
    public func versions(path: String, in turn: AgentTurn) -> FileVersions? {
        let real = Git.real(path)
        guard let root = turn.startTrees.keys.first(where: { real.hasPrefix($0 + "/") }), let start = turn.startTrees[root],
              let end = turn.endTrees[root] ?? (turn.isOpen ? snapshot(root: root) : nil),
              let environment = environment(root: root, store: storeDirectory(for: root)) else { return nil }
        let relative = String(real.dropFirst(root.count + 1))
        func blob(_ tree: String) -> Data? {
            guard let result = Git.runGit(["show", tree + ":" + relative], in: root, environment: environment), result.status == 0 else { return nil }
            return result.output
        }
        return FileVersions(old: blob(start), new: blob(end))
    }

    /// What a turn changed so far, or in all. An open turn compares against the files as they are now.
    public func changes(in turn: AgentTurn, folders: [String]) -> [ChangedFile] {
        var found: [ChangedFile] = []
        for (root, start) in turn.startTrees.sorted(by: { $0.key < $1.key }) {
            guard let end = turn.endTrees[root] ?? (turn.isOpen ? snapshot(root: root) : nil) else { continue }
            found += changes(root: root, from: start, to: end).map { Self.seen(through: folders, $0) }
        }
        return found.sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
    }

    /// One file's changes in a turn, or nil if the turn doesn't cover that file's repository.
    public func diff(path: String, in turn: AgentTurn) -> FileDiff? {
        let real = Git.real(path)
        guard let root = turn.startTrees.keys.first(where: { real.hasPrefix($0 + "/") }), let start = turn.startTrees[root],
              let end = turn.endTrees[root] ?? (turn.isOpen ? snapshot(root: root) : nil) else { return nil }
        return diff(root: root, relative: String(real.dropFirst(root.count + 1)), from: start, to: end)
    }

    /// git reports real paths. The workspace may know a folder by a link to it.
    private static func seen(through folders: [String], _ file: ChangedFile) -> ChangedFile {
        var file = file
        for folder in folders {
            let real = Git.real(folder)
            if file.path.hasPrefix(real + "/") {
                file.path = folder + file.path.dropFirst(real.count)
                break
            }
        }
        return file
    }

    /// Keeps the stores these roots need. A store is only ever removed whole, because a newer
    /// snapshot can lean on anything an older one wrote.
    public func removeStores(except roots: Set<String>) {
        let manager = FileManager.default
        let keep = Set(roots.map { storeDirectory(for: $0).lastPathComponent })
        for entry in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(entry) {
            try? manager.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}

/// Where turns are remembered between launches.
public struct TurnStore: Sendable {
    public var file: URL

    public init(file: URL = TiriPaths.supportDirectory.appendingPathComponent("turns.json")) {
        self.file = file
    }

    public func load() -> [AgentTurn] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentTurn].self, from: data)) ?? []
    }

    public func save(_ turns: [AgentTurn]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(turns) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
