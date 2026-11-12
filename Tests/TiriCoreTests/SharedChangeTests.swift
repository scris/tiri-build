import Foundation
import Testing
@testable import TiriCore

/// A change kept in one person's Tiri, shared as a file, and opened in another's.
@Suite struct SharedChangeTests {
    private let ann = (name: "Ann Example", email: "ann@example.com")

    /// A repository on a release, as `prepare` makes it, from the given notes.
    private func repository(_ notes: String = "line one\nline two\nline three\nline four\nline five\n", version: String = "1.0") throws -> SourceRepo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yourtiri-share-\(UUID().uuidString)", isDirectory: true)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try notes.write(to: tree.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("source.tar.gz")
        #expect(Tool.run("/usr/bin/tar", ["-czf", archive.path, "-C", tree.path, "."]).ok)
        let repo = SourceRepo(folder: root.appendingPathComponent("source", isDirectory: true))
        try repo.prepare(archive: archive, version: version)
        return repo
    }

    /// A change with a check, the way `tiri change ready` commits one.
    @discardableResult
    private func commit(_ repo: SourceRepo, _ id: String, _ sentence: String, check: Bool = true, change: (String) -> String) throws -> PersonalChange {
        let file = repo.folder.appendingPathComponent("notes.txt")
        try change(try String(contentsOf: file, encoding: .utf8)).write(to: file, atomically: true, encoding: .utf8)
        if check {
            let checks = repo.folder.appendingPathComponent("checks")
            try FileManager.default.createDirectory(at: checks, withIntermediateDirectories: true)
            try "#!/bin/sh\ngrep -q LOUD \"$TIRI_SOURCE/notes.txt\"\n".write(to: checks.appendingPathComponent("\(id).sh"), atomically: true, encoding: .utf8)
        }
        try repo.git(["add", "-A"], check: true)
        try repo.git(["commit", "-q", "-m", repo.commitMessage(sentence: sentence, id: id, surface: "the notes")], check: true)
        return try repo.change(named: id)
    }

    private func file(_ repo: SourceRepo, _ name: String = "shared.tirichange") -> URL {
        repo.folder.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func notes(_ repo: SourceRepo) throws -> String {
        try String(contentsOf: repo.folder.appendingPathComponent("notes.txt"), encoding: .utf8)
    }

    private func message(_ work: () throws -> Void) -> String {
        do {
            try work()
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test func aChangeGoesFromOneTiriToAnotherAndArrivesOff() throws {
        let mine = try repository()
        let change = try commit(mine, "c1a2b3c", "Say line two LOUD") { $0.replacingOccurrences(of: "line two", with: "line two LOUD") }
        let out = file(mine)
        let shared = try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", "abc123"))

        // Plain text, readable, with what it was made on and the change and nothing else.
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.contains("Subject: [PATCH] Say line two LOUD"))
        #expect(text.contains("From: Ann Example <ann@example.com>"))
        #expect(text.contains("X-Tiri-Release: 1.0 abc123"))
        #expect(text.contains("Tiri-Change: c1a2b3c"))
        #expect(text.contains("Tiri-Surface: the notes"))
        #expect(text.contains("checks/c1a2b3c.sh"))
        #expect(!text.contains("line five\n+"))
        #expect(shared.files.map(\.path).sorted() == ["checks/c1a2b3c.sh", "notes.txt"])
        #expect(shared.hasCheck)

        let theirs = try repository()
        let read = try SharedChange.read(out)
        #expect(read == shared)
        #expect(read.sentence == "Say line two LOUD")
        #expect(read.from == "Ann Example")
        #expect(read.madeOn == "1.0")
        #expect(read.madeOnCommit == "abc123")
        #expect(read.added == 3 && read.removed == 1)
        #expect(try theirs.alreadyHas(read) == nil)

        let staged = try theirs.stage(read)
        #expect(staged.fits)
        #expect(staged.id == "c1a2b3c")
        #expect(staged.preview?.sentence == "Say line two LOUD")
        // Staged is nothing yet: no change in the list, and the files are as they were.
        #expect(try theirs.changes().isEmpty)
        #expect(theirs.isClean)
        #expect(try !notes(theirs).contains("LOUD"))

        let arrived = try theirs.add(staged)
        #expect(!arrived.isOn)
        #expect(arrived.hasCheck)
        #expect(arrived.from == "Ann Example")
        #expect(arrived.surface == "the notes")
        #expect(!arrived.needsRedo)
        #expect(try theirs.text(["rev-parse", arrived.commit + "^"]) == theirs.releaseCommit())
        #expect(try !notes(theirs).contains("LOUD"))
        // The worktree it was put together in is gone.
        #expect(try !theirs.text(["worktree", "list"]).contains("sharing-"))

        // On, it's the same change.
        try theirs.turnOn(arrived)
        #expect(try notes(theirs).contains("line two LOUD"))
        #expect(FileManager.default.fileExists(atPath: theirs.folder.appendingPathComponent("checks/c1a2b3c.sh").path))
    }

    @Test func theSameFileTwiceIsAlreadyHere() throws {
        let mine = try repository()
        let change = try commit(mine, "c1", "Say it LOUD") { $0.replacingOccurrences(of: "line one", with: "LOUD") }
        let out = file(mine)
        try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", nil))
        // Back to where it came from, it's already there.
        #expect(try mine.alreadyHas(try SharedChange.read(out))?.id == "c1")
        let theirs = try repository()
        try theirs.add(try theirs.stage(try SharedChange.read(out)))
        #expect(try theirs.alreadyHas(try SharedChange.read(out))?.id == "c1")
    }

    @Test func aTakenIDGetsAFreshOneAndItsCheckGoesWithIt() throws {
        let mine = try repository()
        let change = try commit(mine, "c1", "Say line two LOUD") { $0.replacingOccurrences(of: "line two", with: "line two LOUD") }
        let out = file(mine)
        try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", nil))

        let theirs = try repository()
        try commit(theirs, "c1", "Something of their own", check: false) { $0 + "more\n" }
        let staged = try theirs.stage(try SharedChange.read(out))
        #expect(staged.id != "c1")
        let arrived = try theirs.add(staged)
        #expect(arrived.id == staged.id)
        #expect(arrived.hasCheck)
        #expect(try theirs.text(["ls-tree", "-r", "--name-only", arrived.commit, "checks/"]) == "checks/\(arrived.id).sh")
        #expect(try theirs.text(["log", "-1", "--format=%(trailers:key=Tiri-Change,valueonly)", arrived.commit]) == arrived.id)
        #expect(try theirs.change(named: "c1").sentence == "Something of their own")
    }

    @Test func aFileThatChangedOrIsntOneIsRefused() throws {
        let mine = try repository()
        let change = try commit(mine, "c1", "Say it LOUD") { $0.replacingOccurrences(of: "line one", with: "LOUD") }
        let out = file(mine)
        try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", nil))
        let text = try String(contentsOf: out, encoding: .utf8)

        let tampered = file(mine, "tampered.tirichange")
        try text.replacingOccurrences(of: "+LOUD", with: "+rm -rf ~").write(to: tampered, atomically: true, encoding: .utf8)
        #expect(message { _ = try SharedChange.read(tampered) }.contains("changed after it was shared"))

        let cut = file(mine, "cut.tirichange")
        try String(text.prefix(text.count - 20)).write(to: cut, atomically: true, encoding: .utf8)
        #expect(message { _ = try SharedChange.read(cut) }.contains("changed after it was shared"))

        let plain = file(mine, "plain.tirichange")
        try mine.git(["format-patch", "-1", "--output", plain.path, change.commit], check: true)
        #expect(message { _ = try SharedChange.read(plain) }.contains("isn't a shared change"))

        let junk = file(mine, "junk.tirichange")
        try "not a patch".write(to: junk, atomically: true, encoding: .utf8)
        #expect(message { _ = try SharedChange.read(junk) }.contains("isn't a shared change"))
    }

    @Test func oneMadeOnAnotherVersionArrivesNeedingToBeRedone() throws {
        let mine = try repository()
        let change = try commit(mine, "c1", "Say line two LOUD") { $0.replacingOccurrences(of: "line two", with: "line two LOUD") }
        let out = file(mine)
        try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", nil))

        // Their Tiri has that line differently, so it doesn't go on.
        let theirs = try repository("line one\nthe second line\nline three\nline four\nline five\n", version: "2.0")
        let staged = try theirs.stage(try SharedChange.read(out))
        #expect(!staged.fits)
        #expect(theirs.isClean)
        let arrived = try theirs.add(staged)
        #expect(arrived.needsRedo)
        #expect(!arrived.isOn)
        #expect(arrived.madeOn == "1.0")
        #expect(arrived.sentence == "Say line two LOUD")
        #expect(arrived.from == "Ann Example")
        #expect(arrived.files == 0)
        // It can't just be turned on: that would be nothing.
        #expect(message { try theirs.turnOn(arrived) }.contains("redone"))
        // Its file is kept, whole, for whoever redoes it, and the same file again is already here.
        #expect(theirs.sharedText(of: arrived) == (try String(contentsOf: out, encoding: .utf8)))
        #expect(try theirs.alreadyHas(try SharedChange.read(out))?.id == arrived.id)
        // Nor can it be shared on before it's been made again.
        #expect(message { try SharedChange.export(arrived, in: theirs, to: file(theirs, "again.tirichange"), sender: ann, release: ("2.0", nil)) }.contains("redone"))

        // Redoing says where their diff is, and shows it. With nothing in common to merge from, none of it goes on.
        let said = try theirs.beginRedo(arrived)
        #expect(said.contains("None of it goes on"))
        #expect(said.contains(".tiri-shared-\(arrived.id).patch"))
        #expect(said.contains("+line two LOUD"))
        #expect(theirs.isClean)
        theirs.finishRedo(id: arrived.id)
        #expect(theirs.sharedText(of: arrived) == nil)
        #expect(!FileManager.default.fileExists(atPath: theirs.folder.appendingPathComponent(".tiri-shared-\(arrived.id).patch").path))
    }

    @Test func onAVersionThatGrewFromTheSameOneARedoStartsWithConflictsMarked() throws {
        let mine = try repository()
        let change = try commit(mine, "c1", "Say line two LOUD") { $0.replacingOccurrences(of: "line two", with: "line two LOUD") }
        let out = file(mine)
        try SharedChange.export(change, in: mine, to: out, sender: ann, release: ("1.0", nil))

        // Their Tiri was 1.0 too, and an update changed that line.
        let theirs = try repository()
        try "line one\nthe second line\nline three\nline four\nline five\n".write(to: theirs.folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try theirs.git(["commit", "-q", "-am", "Tiri 2.0"], check: true)
        try theirs.git(["branch", "-f", "release", "personal"], check: true)
        let staged = try theirs.stage(try SharedChange.read(out))
        #expect(!staged.fits)
        let arrived = try theirs.add(staged)
        let said = try theirs.beginRedo(arrived)
        #expect(said.contains("conflicts marked"))
        #expect(try notes(theirs).contains("<<<<<<<"))
        #expect(FileManager.default.fileExists(atPath: theirs.folder.appendingPathComponent("checks/c1.sh").path))
    }

    @Test func idsFromAFileAreUsedOnlyIfTheyreIDs() {
        #expect(SharedChange.isUsableID("c1a2b3c"))
        #expect(!SharedChange.isUsableID("../../x"))
        #expect(!SharedChange.isUsableID(""))
        #expect(!SharedChange.isUsableID("c1 rm"))
    }

    @Test func repairsOnSomeoneElsesMacDontComeAlong() {
        let old = "Say it\n\nTiri-Change: c1\nTiri-Surface: tabs\nTiri-Repaired: 0.3.0\nTiri-Repair-Touched: a.swift\n"
        #expect(SourceRepo.arrivedMessage(old, id: "c9") == "Say it\n\nTiri-Change: c9\nTiri-Surface: tabs\n")
        #expect(SourceRepo.arrivedMessage("Say it", id: "c9") == "Say it\n\nTiri-Change: c9\n")
    }

    @Test func theFileIsNamedByItsFirstWords() {
        func named(_ sentence: String) -> String {
            SharedChange.fileName(for: PersonalChange(id: "c1", sentence: sentence, commit: "", date: Date(), surface: nil, files: 0, added: 0, removed: 0,
                                                      isOn: true, hasCheck: false, repairedFor: nil, repairTouched: []))
        }
        #expect(named("Show how long each agent has been working") == "show-how-long-each-agent-has.tirichange")
        #expect(named("Put Changes above Explorer!") == "put-changes-above-explorer.tirichange")
        #expect(named("…") == "c1.tirichange")
    }

    @Test func theCommandsTakePathsFromWhereTheyreRun() throws {
        let environment = CLIParser.Environment(cwd: "/tmp", itemID: nil)
        #expect(try CLIParser.parse(["change", "share", "c1"], environment: environment) == .change(.share("c1", to: "/tmp")))
        #expect(try CLIParser.parse(["change", "share", "c1", "x.tirichange"], environment: environment) == .change(.share("c1", to: "/tmp/x.tirichange")))
        #expect(try CLIParser.parse(["change", "import", "x.tirichange"], environment: environment) == .change(.importShared("/tmp/x.tirichange")))
        #expect(throws: CLIParser.UsageError.self) { try CLIParser.parse(["change", "import"], environment: environment) }
    }
}
