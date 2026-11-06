import Foundation

/// Keeping the snapshot store bounded, as VS Code's local history is: big files stay out, and what
/// no turn needs any more goes. Everything here runs git against Tiri's own store, never the repository.
extension TurnSnapshots {
    /// A file bigger than this isn't copied into a snapshot. Each version would be stored whole.
    public static let largestFile = 5 * 1024 * 1024
    /// The first line of what a snapshot holds in place of a file it left out.
    static let placeholderLine = "tiri-snapshot-placeholder: larger than 5 MB, so not copied"

    /// What changed since the last snapshot and is over `largestFile` goes in as a few lines saying so,
    /// which change when the file does. Returns the pathspecs that keep `git add` away from them.
    func leaveOutLargeFiles(root: String, environment: [String: String], store: URL) -> [String] {
        guard let listed = Git.runGit(["ls-files", "-z", "--modified", "--others", "--exclude-standard"], in: root,
                                      environment: environment, timeout: 60), listed.status == 0 else { return [] }
        var large: [(relative: String, text: String)] = []
        for relative in Set(String(decoding: listed.output, as: UTF8.self).split(separator: "\0").map(String.init)) {
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) > Self.largestFile else { continue }
            let modified = "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            large.append((relative, Self.placeholderLine + "\nsize \(info.st_size)\nmodified \(modified)\n"))
            if large.count == 500 { break }
        }
        guard !large.isEmpty else { return [] }
        let folder = store.appendingPathComponent("placeholders", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = large.indices.map { folder.appendingPathComponent("\($0)").path }
        for (file, entry) in zip(files, large) { try? Data(entry.text.utf8).write(to: URL(fileURLWithPath: file)) }
        guard let hashed = Git.runGit(["hash-object", "-w", "--no-filters", "--"] + files, in: root, environment: environment), hashed.status == 0 else { return [] }
        let ids = String(decoding: hashed.output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard ids.count == large.count else { return [] }
        let entries = zip(ids, large).flatMap { ["--cacheinfo", "100644,\($0),\($1.relative)"] }
        _ = Git.runGit(["update-index", "--add"] + entries, in: root, environment: environment)
        return large.map { ":(exclude,literal)" + $0.relative }
    }

    /// Whether a diff compares something a snapshot left out.
    static func mentionsPlaceholder(_ diff: String) -> Bool {
        guard diff.contains(placeholderLine) else { return false }
        return diff.split(separator: "\n").contains { $0.count > 1 && $0.dropFirst() == placeholderLine }
    }

    /// The store's loose objects, in bytes: what snapshots wrote since the last prune.
    public func looseSize(root: String) -> Int {
        let store = storeDirectory(for: root)
        guard RemoteRegistry.shared.connection(forLocal: root) == nil, let environment = environment(root: root, store: store),
              let result = Git.runGit(["count-objects", "-v"], in: root, environment: environment), result.status == 0 else { return 0 }
        let line = String(decoding: result.output, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("size: ") }
        return (line.flatMap { Int($0.dropFirst(6)) } ?? 0) * 1024
    }

    /// Keeps only what `trees` and the store's own index need, and drops the rest. The store is made a
    /// repository of its own for this, with a ref to each tree, so git's repack and prune see exactly
    /// what's wanted. `--local` and the store's own git directory keep both away from the repository's
    /// objects, which it only reads. Loose objects newer than `expire` stay, for a snapshot in flight.
    @discardableResult
    public func prune(root: String, keeping trees: Set<String>, expire: String = "2.minutes.ago") -> Bool {
        guard RemoteRegistry.shared.connection(forLocal: root) == nil else { return false }
        let manager = FileManager.default
        let store = storeDirectory(for: root)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard manager.fileExists(atPath: store.appendingPathComponent("objects").path),
              let environment = environment(root: root, store: store) else { return false }
        // What the next snapshot builds on.
        var wanted = trees
        var indexTree: String?
        if manager.fileExists(atPath: store.appendingPathComponent("index").path) {
            guard let tree = Git.runGit(["write-tree"], in: root, environment: environment), tree.status == 0 else { return false }
            indexTree = String(decoding: tree.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            wanted.insert(indexTree ?? "")
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let present = wanted.filter { ($0.count == 40 || $0.count == 64) && $0.unicodeScalars.allSatisfy(hex.contains) }.filter { tree in
            Git.runGit(["cat-file", "-e", tree + "^{tree}"], in: root, environment: environment)?.status == 0
        }.sorted()
        // A tree that has lost something, because the repository was made again or collected what it
        // had, can't be kept whole and would stop the prune. What the next snapshot builds on has to be whole.
        func isWhole(_ trees: [String]) -> Bool {
            guard let listed = Git.runGit(["rev-list", "--objects", "--no-object-names", "--missing=print"] + trees,
                                          in: root, environment: environment, timeout: 600), listed.status == 0 else { return false }
            return !listed.output.split(separator: 10).contains { $0.first == UInt8(ascii: "?") }
        }
        var refs = present
        if !isWhole(present) {
            refs = present.filter { isWhole([$0]) }
            if let indexTree, !refs.contains(indexTree) { return false }
        }
        let gitDirectory = store.path
        do {
            try manager.createDirectory(at: store.appendingPathComponent("refs"), withIntermediateDirectories: true)
            let head = store.appendingPathComponent("HEAD")
            if !manager.fileExists(atPath: head.path) { try Data("ref: refs/heads/main\n".utf8).write(to: head) }
            try Data("[core]\n\trepositoryformatversion = 0\n\tbare = true\n[gc]\n\tauto = 0\n".utf8).write(to: store.appendingPathComponent("config"))
            let lines = refs.enumerated().map { "\($0.element) refs/turns/\(String(format: "%06d", $0.offset))" }
            try Data((["# pack-refs with: peeled fully-peeled sorted "] + lines).joined(separator: "\n").appending("\n").utf8)
                .write(to: store.appendingPathComponent("packed-refs"), options: .atomic)
        } catch {
            return false
        }
        // The store's own index, objects and alternates, whatever Tiri's environment says.
        var own = environment
        own["GIT_DIR"] = gitDirectory
        guard let packed = Git.runGit(["--git-dir=" + gitDirectory, "repack", "-a", "-d", "-l", "-q", "--no-write-bitmap-index"],
                                      in: gitDirectory, environment: own, timeout: 600), packed.status == 0 else { return false }
        guard let pruned = Git.runGit(["--git-dir=" + gitDirectory, "prune", "--expire=" + expire],
                                      in: gitDirectory, environment: own, timeout: 600) else { return false }
        return pruned.status == 0
    }
}
