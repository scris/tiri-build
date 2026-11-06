import Foundation
import Testing
@testable import TiriCore

/// Real repositories, because what matters here is what git says about real history.
struct ScratchRepository {
    let base: String
    let root: String

    init(branch: String = "main", commit: Bool = true) throws {
        base = Git.real(FileManager.default.temporaryDirectory.appendingPathComponent("tiri-history-\(UUID().uuidString)").path)
        root = base + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", branch)
        if commit {
            try write("a.txt", "one\ntwo\nthree\n")
            try commitAll("first")
        }
    }

    func write(_ name: String, _ text: String) throws {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try run(arguments, in: root)
    }

    @discardableResult
    func run(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func commitAll(_ message: String) throws -> String {
        try git("add", "-A")
        try git("commit", "-qm", message, "--allow-empty")
        return try git("rev-parse", "HEAD")
    }

    /// A bare remote with origin/HEAD set, the way a clone has it.
    func addOrigin(defaultBranch: String = "main") throws {
        try run(["init", "-q", "--bare", "-b", defaultBranch, base + "/origin.git"], in: base)
        try git("remote", "add", "origin", base + "/origin.git")
        try git("push", "-q", "origin", defaultBranch)
        try git("fetch", "-q", "origin")
        try git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/\(defaultBranch)")
    }
}

@Suite struct BranchBaseTests {
    @Test func prefersTheRemotesDefaultBranch() {
        let refs: [(name: String, symref: String)] = [
            ("refs/heads/main", ""), ("refs/remotes/origin/HEAD", "refs/remotes/origin/develop"), ("refs/remotes/origin/main", ""),
        ]
        #expect(BranchBase.chooseBase(refs: refs) == "refs/remotes/origin/develop")
    }

    @Test func prefersTheRemotesMainToALocalOne() {
        #expect(BranchBase.chooseBase(refs: [("refs/heads/main", ""), ("refs/remotes/origin/main", "")]) == "refs/remotes/origin/main")
        #expect(BranchBase.chooseBase(refs: [("refs/heads/master", "")]) == "refs/heads/master")
        #expect(BranchBase.chooseBase(refs: []) == nil)
    }

    @Test func aFeatureBranchComparesWithOrigin() throws {
        let repo = try ScratchRepository()
        try repo.addOrigin()
        let forkPoint = try repo.git("rev-parse", "HEAD")
        // The base moves on, and it doesn't count as this branch's work.
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.write("b.txt", "new\n")
        try repo.commitAll("on the branch")
        try repo.write("a.txt", "one\nTWO\nthree\n")
        try repo.write("untracked.txt", "hello\n")

        let found = Git.branchChanges(in: [repo.root])
        #expect(found.bases.count == 1)
        #expect(found.bases[0].state == .found(name: "origin/main", commit: forkPoint, shortCommit: String(forkPoint.prefix(7))))
        #expect(found.bases[0].description.contains("origin/main"))
        #expect(found.files.map(\.relative) == ["a.txt", "b.txt", "untracked.txt"])
        #expect(found.files.map(\.status) == [.modified, .added, .untracked])
    }

    @Test func theMergeBaseIsWhereItLeft() throws {
        let repo = try ScratchRepository()
        let forkPoint = try repo.git("rev-parse", "HEAD")
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.write("b.txt", "new\n")
        try repo.commitAll("on the branch")
        try repo.git("checkout", "-q", "main")
        try repo.write("main-only.txt", "x\n")
        try repo.commitAll("on main")
        try repo.git("checkout", "-q", "feature")
        #expect(Git.branchBase(root: repo.root).commit == forkPoint)
        #expect(Git.branchChanges(in: [repo.root]).files.map(\.relative) == ["b.txt"])
    }

    @Test func onTheBaseItselfOnlyUncommittedWorkShows() throws {
        let repo = try ScratchRepository()
        try repo.write("a.txt", "changed\n")
        let found = Git.branchChanges(in: [repo.root])
        #expect(found.bases[0].state == .isBase(name: "main"))
        #expect(found.files.map(\.relative) == ["a.txt"])
    }

    @Test func aBranchWithNothingOnItIsEmpty() throws {
        let repo = try ScratchRepository()
        try repo.addOrigin()
        try repo.git("checkout", "-q", "-b", "fresh")
        let found = Git.branchChanges(in: [repo.root])
        #expect(found.files.isEmpty)
        #expect(found.bases[0].emptyDescription == "Nothing changed since origin/main.")
    }

    @Test func detachedHeadStillHasABase() throws {
        let repo = try ScratchRepository()
        try repo.write("b.txt", "x\n")
        try repo.commitAll("second")
        let first = try repo.git("rev-parse", "HEAD~1")
        try repo.git("checkout", "-q", "--detach", "HEAD")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD") == "HEAD")
        // Detached, main is someone else's, and it's level with here.
        #expect(Git.branchBase(root: repo.root).state != .noCommits)
        try repo.git("checkout", "-q", "--detach", first)
        try repo.write("c.txt", "x\n")
        try repo.commitAll("on no branch")
        let found = Git.branchChanges(in: [repo.root])
        #expect(found.bases[0].commit == first)
        #expect(found.files.map(\.relative) == ["c.txt"])
    }

    @Test func noCommitsIsAllNew() throws {
        let repo = try ScratchRepository(commit: false)
        try repo.write("new.txt", "x\n")
        let found = Git.branchChanges(in: [repo.root])
        #expect(found.bases[0].state == .noCommits)
        #expect(found.files.map(\.status) == [.untracked])
        #expect(Git.recentCommits(in: [repo.root]).isEmpty)
        #expect(try #require(Git.diff(path: repo.root + "/new.txt", target: .branch)).additions == 1)
    }

    @Test func noBaseBranchSaysSo() throws {
        let repo = try ScratchRepository(branch: "dev")
        try repo.write("a.txt", "changed\n")
        let found = Git.branchChanges(in: [repo.root])
        #expect(found.bases[0].state == .none)
        #expect(found.files.map(\.relative) == ["a.txt"])
    }

    @Test func unrelatedHistoryIsNotCompared() throws {
        let repo = try ScratchRepository()
        try repo.git("checkout", "-q", "--orphan", "other")
        try repo.write("b.txt", "x\n")
        try repo.commitAll("unrelated")
        #expect(Git.branchBase(root: repo.root).state == .unrelated(name: "main"))
    }
}

@Suite struct CommitHistoryTests {
    @Test func theLogHasWhatRowsNeed() throws {
        let repo = try ScratchRepository()
        try repo.write("b.txt", "x\n")
        let oid = try repo.commitAll("Subject with | and \"quotes\"")
        let commits = Git.recentCommits(in: [repo.root])
        #expect(commits.count == 2)
        #expect(commits[0].oid == oid)
        #expect(commits[0].subject == "Subject with | and \"quotes\"")
        #expect(commits[0].shortOID == String(oid.prefix(commits[0].shortOID.count)))
        #expect(commits[0].parents.count == 1)
        #expect(commits[1].parents.isEmpty)
        #expect(Git.recentCommits(in: [repo.root], limit: 1).count == 1)
    }

    @Test func aRootCommitIsComparedWithNothing() throws {
        let repo = try ScratchRepository()
        let root = try repo.git("rev-parse", "HEAD")
        let files = Git.commitChanges(root, root: repo.root, in: [repo.root])
        #expect(files.map(\.status) == [.added])
        let diff = try #require(Git.diff(path: repo.root + "/a.txt", target: .commit(root)))
        #expect(diff.additions == 3)
        #expect(diff.deletions == 0)
    }

    @Test func aMergeShowsWhatItBroughtIn() throws {
        let repo = try ScratchRepository()
        try repo.git("checkout", "-q", "-b", "side")
        try repo.write("side.txt", "x\n")
        try repo.commitAll("on the side")
        try repo.git("checkout", "-q", "main")
        try repo.write("main.txt", "y\n")
        try repo.commitAll("on main")
        try repo.git("merge", "-q", "--no-ff", "side", "-m", "Merge")
        let merge = try repo.git("rev-parse", "HEAD")
        let commit = try #require(Git.commitSummary(merge, in: repo.root))
        #expect(commit.isMerge)
        #expect(Git.commitChanges(merge, root: repo.root, in: [repo.root]).map(\.relative) == ["side.txt"])
        #expect(try #require(Git.diff(path: repo.root + "/side.txt", target: .commit(merge))).additions == 1)
        #expect(Git.recentCommits(in: [repo.root]).contains { $0.oid == merge })
    }

    @Test func anEmptyCommitChangesNothing() throws {
        let repo = try ScratchRepository()
        let oid = try repo.commitAll("nothing")
        #expect(Git.commitChanges(oid, root: repo.root, in: [repo.root]).isEmpty)
        #expect(try #require(Git.diff(path: repo.root + "/a.txt", target: .commit(oid))).isEmpty)
    }

    @Test func aRenameComesWithWhereItWas() throws {
        let repo = try ScratchRepository()
        try repo.git("mv", "a.txt", "b.txt")
        try repo.write("b.txt", "one\ntwo\nthree\nfour\n")
        let oid = try repo.commitAll("rename")
        let files = Git.commitChanges(oid, root: repo.root, in: [repo.root])
        #expect(files.map(\.status) == [.renamed])
        #expect(files[0].oldRelative == "a.txt")
        let diff = try #require(Git.diff(path: repo.root + "/b.txt", target: .commit(oid)))
        #expect(diff.oldRelative == "a.txt")
        #expect(diff.additions == 1)
        #expect(diff.deletions == 0)
    }

    @Test func aPureRenameHasNoLinesToShow() throws {
        let repo = try ScratchRepository()
        try repo.git("mv", "a.txt", "b.txt")
        let oid = try repo.commitAll("rename only")
        let diff = try #require(Git.diff(path: repo.root + "/b.txt", target: .commit(oid)))
        #expect(diff.isEmpty)
        #expect(diff.oldRelative == "a.txt")
    }

    @Test func aFileThatsGoneStillHasItsDiff() throws {
        let repo = try ScratchRepository()
        try repo.git("rm", "-q", "a.txt")
        let oid = try repo.commitAll("delete")
        #expect(Git.commitChanges(oid, root: repo.root, in: [repo.root]).map(\.status) == [.deleted])
        #expect(try #require(Git.diff(path: repo.root + "/a.txt", target: .commit(oid))).deletions == 3)
    }

    @Test func binaryFilesAndTheirVersions() throws {
        let repo = try ScratchRepository()
        let first = Data([0, 1, 2, 3])
        let second = Data([9, 8, 7, 0])
        try first.write(to: URL(fileURLWithPath: repo.root + "/b.bin"))
        try repo.commitAll("add")
        try second.write(to: URL(fileURLWithPath: repo.root + "/b.bin"))
        let oid = try repo.commitAll("change")
        let path = repo.root + "/b.bin"
        #expect(try #require(Git.diff(path: path, target: .commit(oid))).isBinary)
        let versions = Git.versions(path: path, target: .commit(oid))
        #expect(versions.old == first)
        #expect(versions.new == second)
        // On disk, against the last commit.
        let third = Data([5, 5, 0])
        try third.write(to: URL(fileURLWithPath: path))
        let now = Git.versions(path: path, target: .head)
        #expect(now.old == second)
        #expect(now.new == third)
    }

    @Test func aRevisionMustBeACommitHere() throws {
        let repo = try ScratchRepository()
        let head = try repo.git("rev-parse", "HEAD")
        #expect(Git.resolveCommit("HEAD", in: repo.root) == head)
        #expect(Git.resolveCommit("nope", in: repo.root) == nil)
        #expect(Git.resolveCommit("--all", in: repo.root) == nil)
        #expect(Git.resolveCommit("", in: repo.root) == nil)
        #expect(Git.findCommit(String(head.prefix(7)), in: [repo.root])?.oid == head)
        #expect(Git.diff(path: repo.root + "/a.txt", target: .commit(String(repeating: "a", count: 40))) == nil)
    }

    @Test func aFolderInsideARepositoryKeepsToItself() throws {
        let repo = try ScratchRepository()
        try repo.write("sub/in.txt", "x\n")
        try repo.write("out.txt", "y\n")
        let oid = try repo.commitAll("both")
        let folder = repo.root + "/sub"
        #expect(Git.commitChanges(oid, root: repo.root, in: [folder]).map(\.relative) == ["sub/in.txt"])
        try repo.write("out2.txt", "z\n")
        let later = try repo.commitAll("only outside")
        #expect(!Git.recentCommits(in: [folder]).contains { $0.oid == later })
        #expect(Git.recentCommits(in: [repo.root]).contains { $0.oid == later })
    }

    @Test func diffSpecsSurviveARelaunch() throws {
        let spec = DiffSpec(path: "/a/b.txt", commit: "abc1234567")
        let data = try JSONEncoder().encode(ItemContent.diff(spec))
        #expect(try JSONDecoder().decode(ItemContent.self, from: data) == .diff(spec))
        #expect(Item(content: .diff(spec)).defaultTitle == "b.txt (abc1234)")
        #expect(Item(content: .diff(DiffSpec(path: "/a/b.txt", branch: true))).defaultTitle == "b.txt (branch)")
        #expect(Item(content: .diff(DiffSpec(path: "/a/b.txt"))).defaultTitle == "b.txt (changes)")
        // Written before commits and branches existed.
        let old = #"{"diff":{"_0":{"path":"/a/b.txt"}}}"#
        #expect(try JSONDecoder().decode(ItemContent.self, from: Data(old.utf8)) == .diff(DiffSpec(path: "/a/b.txt")))
    }

    @Test func relativeTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RelativeTime.text(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(RelativeTime.text(now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(RelativeTime.text(now.addingTimeInterval(-7200), now: now) == "2 hours ago")
        #expect(RelativeTime.text(now.addingTimeInterval(-90000), now: now) == "yesterday")
        #expect(RelativeTime.text(now.addingTimeInterval(-5 * 86400), now: now) == "5 days ago")
        #expect(RelativeTime.text(now.addingTimeInterval(-60 * 86400), now: now).contains(" "))
    }
}

@Suite struct LargeDiffTests {
    @Test func aDiffPastTheBudgetIsTooLargeAndGitIsStopped() throws {
        let repo = try ScratchRepository()
        // Ten megabytes of changed lines, under the file limit but over the output budget.
        try repo.write("a.txt", String(repeating: "a changed line, long enough to add up quickly\n", count: 230_000))
        let started = Date()
        let diff = Git.diff(path: repo.root + "/a.txt")
        #expect(diff.isTooLarge)
        #expect(diff.lines.isEmpty)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try #require(Git.diff(path: repo.root + "/a.txt", target: .head)).isTooLarge)
    }

    @Test func aSmallDiffIsStillRead() throws {
        let repo = try ScratchRepository()
        try repo.write("a.txt", "one\nTWO\nthree\n")
        let diff = Git.diff(path: repo.root + "/a.txt")
        #expect(!diff.isTooLarge)
        #expect(diff.additions == 1)
    }

    @Test func outputPastTheLimitStopsTheCommand() throws {
        let repo = try ScratchRepository()
        try repo.write("a.txt", String(repeating: "x\n", count: 200_000))
        let result = try #require(Git.runGit(["diff"], in: repo.root, outputLimit: 1000))
        #expect(result.output.count > 1000)
        #expect(result.output.count <= 1000 + 65536)
    }
}

@Suite struct QuickOpenIndexTests {
    @Test func aRepositoryIndexesWhatGitDoesNotIgnore() throws {
        let repo = try ScratchRepository()
        try repo.write(".gitignore", "target/\n")
        try repo.write("target/debug/out.o", "")
        try repo.write("src/new.rs", "fresh\n")
        try repo.write("node_modules/x.js", "")
        let found = FileIndexer.index(roots: [repo.root], excludes: ExcludeMatcher(patterns: ["node_modules"]))
        #expect(Set(found.files.map(\.relative)) == [".gitignore", "a.txt", "src/new.rs"])
        #expect(found.files.first { $0.relative == "src/new.rs" }?.name == "new.rs")
        #expect(!found.reachedLimit)
        #expect(FileIndexer.index(roots: [repo.root], excludes: ExcludeMatcher(patterns: []), limit: 2).reachedLimit)
    }

    @Test func aFolderOutsideARepositoryIsWalked() throws {
        let folder = Git.real(FileManager.default.temporaryDirectory.appendingPathComponent("tiri-index-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        try "x".write(toFile: folder + "/sub/a.txt", atomically: true, encoding: .utf8)
        #expect(FileIndexer.index(roots: [folder], excludes: ExcludeMatcher(patterns: [])).files.map(\.relative) == ["sub/a.txt"])
    }

    @Test func aRepositoryInsideIsListedByItsOwnGit() throws {
        let repo = try ScratchRepository()
        let inner = repo.root + "/vendor/lib"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try repo.run(["init", "-q", "-b", "main"], in: inner)
        try ".build/\n".write(toFile: inner + "/.gitignore", atomically: true, encoding: .utf8)
        try "x".write(toFile: inner + "/lib.c", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: inner + "/.build", withIntermediateDirectories: true)
        try "x".write(toFile: inner + "/.build/junk.o", atomically: true, encoding: .utf8)
        let found = Set(FileIndexer.index(roots: [repo.root], excludes: ExcludeMatcher(patterns: [])).files.map(\.relative))
        #expect(found == ["a.txt", "vendor/lib/.gitignore", "vendor/lib/lib.c"])
    }
}

@Suite struct ReviewFromCommitTests {
    @Test func aCommentSaysWhichCommit() {
        let comment = ReviewComment(path: "/p/a.txt", commit: "abcdef1234567", text: "Why?")
        #expect(ReviewMessage.text(comments: [comment], cwd: "/p", fileText: { _ in "" }).contains("a.txt (in commit abcdef1)"))
    }

    @Test func aQuoteSaysWhichCommit() {
        let rows = [DiffLine(kind: .added, newLine: 1, text: "x")]
        #expect(DiffQuote.text(path: "/p/a.txt", rows: rows, commit: "abc1234").contains("in commit abc1234"))
        #expect(!DiffQuote.text(path: "/p/a.txt", rows: rows).contains("commit"))
    }
}

@Suite struct OtherWorkTests {
    @Test func branchesAndWorktreesInPlainTerms() throws {
        let repository = try ScratchRepository()
        let worktree = repository.base + "/feat"
        try repository.git("worktree", "add", "-q", "-b", "feat/login", worktree)
        try "one\nTWO\nthree\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        try repository.run(["add", "."], in: worktree)
        try repository.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "Fix the login"], in: worktree)
        try "new\n".write(toFile: worktree + "/c.txt", atomically: true, encoding: .utf8)
        try repository.git("branch", "already-merged")
        try repository.git("checkout", "-q", "-b", "fix/typo")
        try repository.write("b.txt", "y\n")
        try repository.commitAll("Fix a typo")
        try repository.git("checkout", "-q", "main")

        let lines = Git.otherWork(in: [repository.root])
        #expect(Set(lines.map(\.branch)) == ["feat/login", "fix/typo"])
        let login = try #require(lines.first { $0.branch == "feat/login" })
        #expect(login.worktree == worktree)
        #expect(login.commits == 1)
        #expect(login.files == 1)
        #expect(login.uncommitted == 1)
        #expect(login.summary == "1 file changed · 1 not committed · 1 commit, not merged")
        #expect(login.mergeRequest.contains("`feat/login` into `main`"))
        #expect(login.mergeRequest.contains(worktree))

        let typo = try #require(lines.first { $0.branch == "fix/typo" })
        #expect(typo.worktree == nil)
        let files = Git.changes(of: typo)
        #expect(files.map(\.relative) == ["b.txt"])
        // A branch that isn't checked out: its file doesn't exist here, and its diff still reads.
        let diff = try #require(Git.diff(path: repository.root + "/b.txt", target: .range(from: typo.from, to: typo.tip)))
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "y" })
        #expect(Git.versions(path: repository.root + "/b.txt", target: .range(from: typo.from, to: typo.tip)).new == Data("y\n".utf8))
    }

    @Test func anOldMergedBranchIsNotWork() throws {
        let repository = try ScratchRepository()
        try repository.git("branch", "old")
        #expect(Git.otherWork(in: [repository.root]).isEmpty)
    }

    @Test func aMergedWorktreeOffersACleanUp() throws {
        let repository = try ScratchRepository()
        let worktree = repository.base + "/old"
        try repository.git("worktree", "add", "-q", "-b", "old", worktree)
        let line = try #require(Git.otherWork(in: [repository.root]).first)
        #expect(line.merged)
        #expect(!line.isUnfinished)
        #expect(line.summary == "merged into main")
        #expect(line.cleanUpRequest.contains(worktree))
    }

    @Test func aWorktreeThatIsTheWorkspaceIsNotOtherWork() throws {
        let repository = try ScratchRepository()
        let worktree = repository.base + "/feat"
        try repository.git("worktree", "add", "-q", "-b", "feat", worktree)
        #expect(!Git.otherWork(in: [worktree]).contains { $0.branch == "feat" })
    }
}

