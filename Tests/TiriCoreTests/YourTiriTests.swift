import Foundation
import Testing
@testable import TiriCore

@Suite struct LaunchGateTests {
    private func choose(_ state: CopyState?, personal: Bool = false, option: Bool = false, once: Bool = false, exists: Bool = true) -> LaunchChoice {
        LaunchGate.choose(.init(state: state, isPersonalCopy: personal, optionHeld: option, plainOnce: once, personalExists: exists))
    }

    private func yours(attempts: Int = 0) -> CopyState {
        var state = CopyState()
        state.active = .personal
        state.attempts = attempts
        return state
    }

    @Test func someoneWhoNeverUsedThisJustRuns() {
        #expect(choose(nil) == .runHere)
    }

    @Test func plainStaysPlainWhenThatsTheChoice() {
        #expect(choose(CopyState()) == .runHere)
    }

    @Test func theInstalledAppHandsOverToTheirCopy() {
        #expect(choose(yours()) == .openPersonal)
    }

    @Test func optionAlwaysMeansPlainWhateverIsBroken() {
        #expect(choose(yours(attempts: 5), option: true) == .runHere)
        #expect(choose(yours(), personal: true, option: true) == .openPlain)
    }

    @Test func aSingleRunOfPlainIsNotAChoice() {
        #expect(choose(yours(), once: true) == .runHere)
    }

    @Test func twoEarlyDeathsMeanGoingBack() {
        #expect(choose(yours(attempts: 1)) == .openPersonal)
        #expect(choose(yours(attempts: 2)) == .fallBack)
    }

    @Test func aMissingCopyIsSaidSo() {
        #expect(choose(yours(), exists: false) == .personalMissing)
    }

    @Test func aPersonalCopyWithoutTheChoiceHandsBack() {
        #expect(choose(CopyState(), personal: true) == .openPlain)
        #expect(choose(nil, personal: true) == .openPlain)
        #expect(choose(yours(), personal: true) == .runHere)
    }
}

@Suite struct CopyStateTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yourtiri-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fakeApp(at url: URL, marking text: String) throws {
        let binary = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        try text.write(to: binary.appendingPathComponent("Tiri"), atomically: true, encoding: .utf8)
    }

    private func mark(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("Contents/MacOS/Tiri"), encoding: .utf8)
    }

    @Test func promotingKeepsWhatRanBefore() throws {
        let root = try folder()
        let ready = root.appendingPathComponent("ready/Tiri.app"), current = root.appendingPathComponent("current/Tiri.app"), previous = root.appendingPathComponent("previous/Tiri.app")
        try fakeApp(at: ready, marking: "one")
        #expect(try CopyFiles.promoteReady(ready: ready, current: current, previous: previous) == false)
        #expect(try mark(current) == "one")
        try fakeApp(at: ready, marking: "two")
        #expect(try CopyFiles.promoteReady(ready: ready, current: current, previous: previous) == true)
        #expect(try mark(current) == "two")
        #expect(try mark(previous) == "one")
        try fakeApp(at: ready, marking: "three")
        #expect(try CopyFiles.promoteReady(ready: ready, current: current, previous: previous) == true)
        #expect(try mark(current) == "three")
        #expect(try mark(previous) == "two")
        #expect(!FileManager.default.fileExists(atPath: ready.path))
    }

    @Test func promotingNothingFailsAndMovesNothing() throws {
        let root = try folder()
        let current = root.appendingPathComponent("current/Tiri.app")
        try fakeApp(at: current, marking: "still here")
        #expect(throws: CopyFiles.MoveFailure.self) {
            try CopyFiles.promoteReady(ready: root.appendingPathComponent("ready/Tiri.app"), current: current, previous: root.appendingPathComponent("previous/Tiri.app"))
        }
        #expect(try mark(current) == "still here")
    }

    @Test func fallingBackGoesToThePreviousCopyWhenThereIsOne() throws {
        let root = try folder()
        let current = root.appendingPathComponent("current/Tiri.app"), previous = root.appendingPathComponent("previous/Tiri.app")
        try fakeApp(at: current, marking: "broken")
        try fakeApp(at: previous, marking: "works")
        var state = CopyState()
        state.active = .personal
        state.attempts = 2
        state.trial = .init(sentence: "Do a thing", change: "c1", item: nil, startedAt: Date(), previous: .personal, hasPreviousCopy: true, firstPersonal: false)
        state.fallBack(current: current, previous: previous)
        #expect(state.active == .personal)
        #expect(try mark(current) == "works")
        #expect(state.attempts == 0)
        #expect(state.trial == nil)
        #expect(state.notice?.contains("Do a thing") == true)
        #expect(state.rejectedChange == "c1")
    }

    @Test func fallingBackWithNoCopyToGoToIsPlain() throws {
        let root = try folder()
        var state = CopyState()
        state.active = .personal
        state.attempts = 2
        state.fallBack(current: root.appendingPathComponent("current/Tiri.app"), previous: root.appendingPathComponent("previous/Tiri.app"))
        #expect(state.active == .plain)
        #expect(state.notice != nil)
    }

    @Test func aTrialExpires() {
        let trial = CopyState.Trial(sentence: "s", change: nil, item: nil, startedAt: Date(timeIntervalSinceNow: -601), previous: .plain, hasPreviousCopy: false, firstPersonal: true)
        #expect(trial.hasExpired(now: Date()))
    }

    @Test func stateSurvivesBeingWrittenAndAnOlderFileStillReads() throws {
        let file = try folder().appendingPathComponent("state.json")
        var state = CopyState()
        state.active = .personal
        state.plainPath = "/Applications/Tiri.app"
        try state.save(to: file)
        #expect(CopyState.load(from: file)?.plainPath == "/Applications/Tiri.app")
        #expect(CopyState.load(from: file.appendingPathExtension("missing")) == nil)
    }
}

@Suite struct SourceRepoTests {
    /// A repository on a release, with a file to change, as `prepare` makes it.
    private func repository() throws -> SourceRepo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yourtiri-\(UUID().uuidString)", isDirectory: true)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "line one\nline two\nline three\nline four\nline five\n".write(to: tree.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("source.tar.gz")
        #expect(Tool.run("/usr/bin/tar", ["-czf", archive.path, "-C", tree.path, "."]).ok)
        let repo = SourceRepo(folder: root.appendingPathComponent("source", isDirectory: true))
        try repo.prepare(archive: archive, version: "1.0")
        return repo
    }

    private func commit(_ repo: SourceRepo, _ id: String, _ sentence: String, change: (String) -> String) throws {
        let file = repo.folder.appendingPathComponent("notes.txt")
        try change(try String(contentsOf: file, encoding: .utf8)).write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "-A"], check: true)
        try repo.git(["commit", "-q", "-m", repo.commitMessage(sentence: sentence, id: id, surface: "the notes")], check: true)
    }

    @Test func preparingMakesTheBranchesAndNoChanges() throws {
        let repo = try repository()
        #expect(try repo.head() == repo.releaseCommit())
        #expect(try repo.changes().isEmpty)
        #expect(repo.isClean)
    }

    @Test func preparingWithoutAnArchiveSaysSo() {
        let repo = SourceRepo(folder: FileManager.default.temporaryDirectory.appendingPathComponent("yourtiri-\(UUID().uuidString)"))
        #expect(throws: ChangeFailure.self) { try repo.prepare(archive: URL(fileURLWithPath: "/nonexistent/source.tar.gz"), version: "1") }
    }

    @Test func theSentenceAndTheCountsComeFromTheCommit() throws {
        let repo = try repository()
        try commit(repo, "c1", "Say it louder") { $0.replacingOccurrences(of: "line one", with: "LINE ONE") }
        let changes = try repo.changes()
        #expect(changes.count == 1)
        #expect(changes[0].id == "c1")
        #expect(changes[0].sentence == "Say it louder")
        #expect(changes[0].surface == "the notes")
        #expect(changes[0].size == "1 file, 2 lines")
        #expect(changes[0].isOn)
        #expect(!changes[0].hasCheck)
    }

    @Test func aCheckCountsAsPartOfTheChange() throws {
        let repo = try repository()
        let checks = repo.folder.appendingPathComponent("checks")
        try FileManager.default.createDirectory(at: checks, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: checks.appendingPathComponent("c1.sh"), atomically: true, encoding: .utf8)
        try commit(repo, "c1", "Say it louder") { $0.replacingOccurrences(of: "line one", with: "LINE ONE") }
        let change = try repo.change(named: "c1")
        #expect(change.hasCheck)
        // It's a script that will run at every update, so it's in what the card counts.
        #expect(change.files == 2)
    }

    @Test func turningOffAndOnKeepsTheChange() throws {
        let repo = try repository()
        try commit(repo, "c1", "First") { $0.replacingOccurrences(of: "line one", with: "ONE") }
        try commit(repo, "c2", "Second") { $0.replacingOccurrences(of: "line five", with: "FIVE") }
        try repo.turnOff(try repo.change(named: "c1"))
        var text = try String(contentsOf: repo.folder.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(!text.contains("ONE"))
        #expect(text.contains("FIVE"))
        #expect(try repo.change(named: "c1").isOn == false)
        #expect(try repo.change(named: "c1").sentence == "First")
        #expect(try repo.change(named: "c2").isOn)
        try repo.turnOn(try repo.change(named: "c1"))
        text = try String(contentsOf: repo.folder.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(text.contains("ONE"))
        #expect(try repo.changes().allSatisfy(\.isOn))
    }

    @Test func aChangeALaterOneBuildsOnCantTurnOffAlone() throws {
        let repo = try repository()
        try commit(repo, "c1", "First") { $0.replacingOccurrences(of: "line one", with: "ONE") }
        try commit(repo, "c2", "Second") { $0.replacingOccurrences(of: "ONE", with: "ONE!") }
        let head = try repo.head()
        #expect(throws: ChangeFailure.self) { try repo.turnOff(try repo.change(named: "c1")) }
        #expect(try repo.head() == head)
        #expect(repo.isClean)
    }

    @Test func asksByAPrefixOfTheCommitToo() throws {
        let repo = try repository()
        try commit(repo, "c1", "First") { $0 + "more\n" }
        let commit = try repo.head()
        #expect(try repo.change(named: String(commit.prefix(10))).id == "c1")
        #expect(throws: ChangeFailure.self) { try repo.change(named: "nothing") }
    }
}

@Suite struct ReleaseCheckTests {
    private func app(version: String, build: String = "1", id: String = "dev.tiri.app", sign: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yourtiri-\(UUID().uuidString)/Tiri.app", isDirectory: true)
        let macOS = folder.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleIdentifier": id, "CFBundleExecutable": "Tiri"]
        try info.write(to: folder.appendingPathComponent("Contents/Info.plist"))
        let binary = macOS.appendingPathComponent("Tiri")
        if sign {
            #expect(Tool.run("/bin/cp", ["/usr/bin/true", binary.path]).ok)
            #expect(Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", folder.path]).ok)
        } else {
            // A copy of a real program would bring its signature with it.
            try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
            #expect(Tool.run("/bin/chmod", ["+x", binary.path]).ok)
        }
        return folder
    }

    @Test func aNewerOneOfTheSameAppPasses() throws {
        try UpdateTools.checkRelease(try app(version: "0.2.0"), replacing: try app(version: "0.1.0"))
    }

    @Test func aNewerBuildOfTheSameVersionPasses() throws {
        try UpdateTools.checkRelease(try app(version: "0.1.0", build: "20261105091500"), replacing: try app(version: "0.1.0", build: "20261105091400"))
    }

    @Test func aBuildNumberCantMakeUpForAnOlderVersion() throws {
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.1.0", build: "99"), replacing: try app(version: "0.2.0", build: "1")) }
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.1.0", build: "5"), replacing: try app(version: "0.1.0", build: "5")) }
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.1.0", build: "4"), replacing: try app(version: "0.1.0", build: "5")) }
    }

    @Test func goingBackwardsIsRefused() throws {
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.1.0"), replacing: try app(version: "0.2.0")) }
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.2.0"), replacing: try app(version: "0.2.0")) }
    }

    @Test func anotherAppIsRefused() throws {
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "9.0", id: "com.other"), replacing: try app(version: "0.1.0")) }
    }

    @Test func aBrokenSignatureIsRefused() throws {
        let new = try app(version: "0.2.0")
        try "tampered".write(to: new.appendingPathComponent("Contents/Info.plist.extra"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: new.appendingPathComponent("Contents/Info.plist.extra"), to: new.appendingPathComponent("Contents/Resources-extra"))
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(new, replacing: try app(version: "0.1.0")) }
    }

    @Test func notBeingAbleToReadTheInstalledOneFailsClosed() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/Tiri.app")
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.2.0"), replacing: missing) }
        // Installed, and with no signature to read.
        #expect(throws: ChangeFailure.self) { try UpdateTools.checkRelease(try app(version: "0.2.0"), replacing: try app(version: "0.1.0", sign: false)) }
    }
}

@Suite struct UpdateTests {
    @Test func versionsCompareAsNumbers() {
        #expect(UpdateTools.isNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateTools.isNewer("0.9.0", than: "0.10.0"))
        #expect(!UpdateTools.isNewer("1.0.0", than: "1.0.0"))
    }

    @Test func theLineNamesWhatsLeftOut() {
        var status = UpdateStatus(version: "0.3", newRelease: "abc", phase: .ready, app: "/x")
        status.carried = [.init(id: "a", sentence: "One"), .init(id: "b", sentence: "Two")]
        #expect(status.line == "Tiri 0.3 is ready, with your 2 changes.")
        status.leftOut = [.init(id: "c", sentence: "Timer on tabs")]
        #expect(status.line.contains("“Timer on tabs” stays off for now."))
        status.carried = []
        status.leftOut = []
        #expect(status.line == "Tiri 0.3 is ready.")
    }

    @Test func aRepairPromptCarriesTheSentenceAndTheCommands() {
        var status = UpdateStatus(version: "0.3", newRelease: "abc", phase: .needsRepair, app: "/x")
        status.notes = "Tabs were rewritten."
        let prompt = UpdateTools.repairPrompt(.init(id: "c1", sentence: "Timer on tabs", why: "it conflicts"), status: status)
        #expect(prompt.contains("Timer on tabs"))
        #expect(prompt.contains("Tabs were rewritten."))
        #expect(prompt.contains("tiri update repair c1"))
        #expect(prompt.contains("tiri update retire c1"))
    }
}

@Suite struct ChangeCLITests {
    private let environment = CLIParser.Environment(cwd: "/tmp", itemID: nil)

    @Test func startKeepsTheirWords() throws {
        let parsed = try CLIParser.parse(["change", "start", "show a timer", "--surface", "tab bar"], environment: environment)
        #expect(parsed == .change(.start(sentence: "show a timer", surface: "tab bar")))
    }

    @Test func thereIsNoWayToSwitchFromTheCommandLine() {
        for word in ["try", "keep", "switch", "activate", "use"] {
            #expect(throws: CLIParser.UsageError.self) { try CLIParser.parse(["change", word], environment: environment) }
        }
        #expect(throws: CLIParser.UsageError.self) { try CLIParser.parse(["update", "install"], environment: environment) }
    }

    @Test func askingForHelpStartsNothing() throws {
        for arguments in [["change"], ["change", "--help"], ["change", "start", "--help"], ["update", "--help"]] {
            guard case .printText = try CLIParser.parse(arguments, environment: environment) else {
                Issue.record("\(arguments) did something")
                continue
            }
        }
    }

    @Test func offCanSkipTheBuild() throws {
        #expect(try CLIParser.parse(["change", "off", "c1"], environment: environment) == .change(.off("c1", build: true)))
        #expect(try CLIParser.parse(["change", "off", "c1", "--no-build"], environment: environment) == .change(.off("c1", build: false)))
    }

    @Test func updateTakesAPathFromWhereItsRun() throws {
        #expect(try CLIParser.parse(["update", "prepare", "Tiri.zip"], environment: environment) == .update(.prepare("/tmp/Tiri.zip", notes: nil)))
    }
}

@Suite struct YourTiriRepairNotes {
    @Test func aRepairJoinsTheTrailersAndReplacesAnEarlierOne() throws {
        let old = "Show a timer\n\nTiri-Change: c1\nTiri-Repaired: 0.2.0\nTiri-Repair-Touched: Old.swift\n"
        let message = UpdateTools.repairMessage(old: old, version: "0.3.0", touched: ["A.swift", "checks/c1.sh"])
        #expect(message == "Show a timer\n\nTiri-Change: c1\nTiri-Repaired: 0.3.0\nTiri-Repair-Touched: A.swift\nTiri-Repair-Touched: checks/c1.sh\n")
    }

    @Test func notesComeFromInsideTheRelease() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        #expect(UpdateTools.notesInside(app) == nil)
        try "  \n".write(to: resources.appendingPathComponent(UpdateTools.notesFile), atomically: true, encoding: .utf8)
        #expect(UpdateTools.notesInside(app) == nil)
        try String(repeating: "x", count: 9000).write(to: resources.appendingPathComponent(UpdateTools.notesFile), atomically: true, encoding: .utf8)
        #expect(UpdateTools.notesInside(app)?.count == 4000)
    }

    @Test func swiftToolsAreLookedForWithoutRunningThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!SwiftTools.areHere(developerDirectory: folder.path))
        #expect(!SwiftTools.areHere(developerDirectory: ""))
        let bin = folder.appendingPathComponent("usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        #expect(SwiftTools.areHere(developerDirectory: folder.path))
    }

    @Test func xcodeKeepsSwiftInItsToolchain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        #expect(SwiftTools.areHere(developerDirectory: folder.path))
    }
}
