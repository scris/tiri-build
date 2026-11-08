import CryptoKit
import Foundation

/// One thing someone asked to be different, which is one commit on top of a release.
/// Git is what holds these. The sentence is the commit's subject, and there's no other list to get out of step.
public struct PersonalChange: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sentence: String
    public var commit: String
    public var date: Date
    public var surface: String?
    public var files: Int
    public var added: Int
    public var removed: Int
    public var isOn: Bool
    public var hasCheck: Bool
    /// The version an update's repair made this fit, and the files where the repair made it differ from before.
    public var repairedFor: String?
    public var repairTouched: [String]

    public var lines: Int { added + removed }
    public var size: String { Self.size(files: files, lines: lines) }

    /// `tiri change list` prints this too, in English, since the command has no tables.
    public static func size(files: Int, lines: Int) -> String {
        switch (files == 1, lines == 1) {
        case (true, true): String(localized: "1 file, 1 line")
        case (true, false): String(localized: "1 file, \(lines) lines")
        case (false, true): String(localized: "\(files) files, 1 line")
        case (false, false): String(localized: "\(files) files, \(lines) lines")
        }
    }
}

/// The change an agent is making now, before it's a commit.
public struct ChangeDraft: Codable, Equatable, Sendable {
    public var id: String
    public var sentence: String
    public var surface: String?
    public var item: String?
    public var startedAt: Date
    /// Reopened after it was made: `ready` replaces the commit.
    public var replacing: String?
}

/// A build waiting for someone to try it. An agent can get this far and no further.
public struct ReadyCopy: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case change, toggled, update }
    public var kind: Kind
    public var sentence: String
    public var change: String?
    public var item: String?
    public var size: String
    /// Nil when there's no check to run.
    public var checkPassed: Bool?
    public var builtAt: Date
    public var commit: String

    public static func load(from file: URL = YourTiri.readyNote) -> ReadyCopy? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? CopyState.decoder.decode(ReadyCopy.self, from: data)
    }

    /// `tiri change` writes the note, in English, and "Turn off:" is also how a trial knows which way to undo.
    /// These are its words as people read them.
    public static func shown(_ sentence: String) -> String {
        if sentence.hasPrefix("Turn off: ") { return String(localized: "Turn off: \(String(sentence.dropFirst("Turn off: ".count)))") }
        if sentence.hasPrefix("Turn on: ") { return String(localized: "Turn on: \(String(sentence.dropFirst("Turn on: ".count)))") }
        return sentence
    }

    public var shownSentence: String { Self.shown(sentence) }

    /// The size, read back from the English the note was written with.
    public var shownSize: String {
        let numbers = size.split { !$0.isNumber }.compactMap { Int($0) }
        switch kind {
        case .toggled where numbers.count == 1:
            return numbers[0] == 1 ? String(localized: "1 change on") : String(localized: "\(numbers[0]) changes on")
        case .change where numbers.count == 2:
            return PersonalChange.size(files: numbers[0], lines: numbers[1])
        default:
            return size
        }
    }

    func save(to file: URL = YourTiri.readyNote) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(encoder.encode(self), to: file)
    }
}

public struct ChangeFailure: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// The source of the Tiri someone is running, as a repository they never have to see.
public struct SourceRepo: Sendable {
    public var folder: URL

    public init(folder: URL = YourTiri.source) {
        self.folder = folder
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) }

    @discardableResult
    func git(_ arguments: [String], check: Bool = false) throws -> Tool.Result {
        let result = Tool.run("/usr/bin/git", arguments, in: folder, environment: ["GIT_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"])
        if check, !result.ok { throw ChangeFailure("git \(arguments.first ?? "") failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return result
    }

    func text(_ arguments: [String]) throws -> String {
        try git(arguments, check: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isClean: Bool { (try? text(["status", "--porcelain"]))?.isEmpty == true }

    /// From the archive inside the app. It takes about a second, and the agent can start reading straight after.
    /// `changeUnderway` is a change being made in the folder right now, which keeps it as it is.
    public func prepare(archive: URL, version: String, changeUnderway: Bool = false) throws {
        if exists {
            guard try isStale(archive: archive), !changeUnderway else { return }
            try FileManager.default.removeItem(at: folder)
        }
        guard FileManager.default.fileExists(atPath: archive.path) else { throw ChangeFailure(String(localized: "This copy of Tiri doesn't carry its source, so it can't be changed.")) }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let unpacked = Tool.run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        guard unpacked.ok else { throw ChangeFailure(String(localized: "Couldn't unpack Tiri's source: \(unpacked.output)")) }
        try git(["init", "-q", "-b", "personal"], check: true)
        try configure()
        try git(["add", "-A"], check: true)
        try git(["commit", "-q", "-m", "Tiri \(version)"], check: true)
        try git(["branch", "release"], check: true)
        if let digest = Self.digest(of: archive) { try git(["config", Self.archiveKey, digest], check: true) }
    }

    private static let archiveKey = "tiri.archive"

    private static func digest(of archive: URL) -> String? {
        guard let data = try? Data(contentsOf: archive, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacked from another Tiri than the one running, as after an update when nothing of theirs was kept. A change
    /// made on it would build a copy of that older Tiri, undoing the update. Only replaced when there's nothing of
    /// theirs in it: no changes, on or off, and nothing edited. With changes, an update carries them over instead.
    func isStale(archive: URL) throws -> Bool {
        guard let digest = Self.digest(of: archive), (try? text(["config", Self.archiveKey])) != digest else { return false }
        return try changes().isEmpty && isClean
    }

    /// Whatever someone has set up for their own repositories doesn't apply in here.
    func configure() throws {
        for (key, value) in [("user.name", "Your Tiri"), ("user.email", "your-tiri@localhost"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", "/dev/null"), ("core.autocrlf", "false"), ("merge.conflictStyle", "diff3")] {
            try git(["config", key, value], check: true)
        }
        try installMergeDriver()
    }

    /// Git's own merge, helped by one that understands Swift when that's on this Mac. See `Merging` in the update steps.
    func installMergeDriver() throws {
        guard let tool = Self.mergeTool() else { return }
        try git(["config", "merge.mergiraf.name", "mergiraf"], check: true)
        try git(["config", "merge.mergiraf.driver", "\"\(tool)\" merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L"], check: true)
        let attributes = folder.appendingPathComponent(".git/info/attributes")
        try FileManager.default.createDirectory(at: attributes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.swift merge=mergiraf\n".write(to: attributes, atomically: true, encoding: .utf8)
    }

    public static func mergeTool() -> String? {
        let own = YourTiri.tools.appendingPathComponent("mergiraf").path
        return FileManager.default.isExecutableFile(atPath: own) ? own : nil
    }

    // MARK: Reading changes

    private static let trailerID = "Tiri-Change"
    private static let trailerSurface = "Tiri-Surface"
    static let trailerRepaired = "Tiri-Repaired"
    static let trailerRepairTouched = "Tiri-Repair-Touched"

    /// The newest last, as they apply. Off ones come after.
    public func changes() throws -> [PersonalChange] {
        guard exists else { return [] }
        let on = try text(["rev-list", "--reverse", "release..personal"]).split(separator: "\n").map(String.init)
        let off = try text(["for-each-ref", "--format=%(objectname)", "refs/tiri/off/"]).split(separator: "\n").map(String.init)
        let tree = try Set(text(["ls-tree", "-r", "--name-only", "personal", "checks/"]).split(separator: "\n").map(String.init))
        return try on.map { try change(commit: $0, isOn: true, checks: tree) } + off.map { try change(commit: $0, isOn: false, checks: tree) }
    }

    private func change(commit: String, isOn: Bool, checks: Set<String>) throws -> PersonalChange {
        let fields = try text(["log", "-1", "--format=%s%x00%aI%x00%(trailers:key=\(Self.trailerID),valueonly)%x00%(trailers:key=\(Self.trailerSurface),valueonly)%x00%(trailers:key=\(Self.trailerRepaired),valueonly)%x00%(trailers:key=\(Self.trailerRepairTouched),valueonly)", commit]).components(separatedBy: "\0")
        let sentence = fields[0]
        let date = ISO8601DateFormatter().date(from: fields.count > 1 ? fields[1] : "") ?? Date()
        let id = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let surface = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let repaired = fields.count > 4 ? fields[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let repairTouched = fields.count > 5 ? fields[5].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
        var files = 0, added = 0, removed = 0
        for line in try text(["diff", "--numstat", commit + "^", commit]).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 3 else { continue }
            files += 1
            added += Int(parts[0]) ?? 0
            removed += Int(parts[1]) ?? 0
        }
        let realID = id.isEmpty ? String(commit.prefix(8)) : id
        let hasCheck = isOn ? checks.contains("checks/\(realID).sh") : ((try? text(["ls-tree", "--name-only", commit, "checks/\(realID).sh"]))?.isEmpty == false)
        return PersonalChange(id: realID, sentence: sentence, commit: commit, date: date, surface: surface.isEmpty ? nil : surface,
                              files: files, added: added, removed: removed, isOn: isOn, hasCheck: hasCheck,
                              repairedFor: repaired.isEmpty ? nil : repaired, repairTouched: repairTouched)
    }

    public func change(named id: String) throws -> PersonalChange {
        let all = try changes()
        if let found = all.first(where: { $0.id == id || $0.commit.hasPrefix(id) }) { return found }
        throw ChangeFailure("No change called \(id). Run tiri change list.")
    }

    public func head() throws -> String { try text(["rev-parse", "personal"]) }
    public func releaseCommit() throws -> String { try text(["rev-parse", "release"]) }

    // MARK: Moving changes

    /// Out of the line of changes, without being lost. A later change that needed it stops this, and nothing moves.
    public func turnOff(_ change: PersonalChange) throws {
        guard change.isOn else { return }
        let rebase = try git(["rebase", "-q", "--onto", change.commit + "^", change.commit, "personal"])
        guard rebase.ok else {
            try git(["rebase", "--abort"])
            throw ChangeFailure("“\(change.sentence)” can't be turned off alone, because a later change builds on it.")
        }
        try git(["update-ref", "refs/tiri/off/\(change.id)", change.commit], check: true)
    }

    public func turnOn(_ change: PersonalChange) throws {
        guard !change.isOn else { return }
        let pick = try git(["cherry-pick", change.commit])
        guard pick.ok else {
            try git(["cherry-pick", "--abort"])
            throw ChangeFailure("“\(change.sentence)” no longer fits. Ask an agent to make it again.")
        }
        try git(["update-ref", "-d", "refs/tiri/off/\(change.id)"], check: true)
    }

    func commitMessage(sentence: String, id: String, surface: String?) -> String {
        var message = sentence + "\n\n\(Self.trailerID): \(id)\n"
        if let surface, !surface.isEmpty { message += "\(Self.trailerSurface): \(surface)\n" }
        return message
    }
}

/// `tiri change`: what an agent uses to change Tiri. People never see any of this, only cards and switches.
public enum ChangeTools {
    public enum Action: Equatable, Sendable {
        case start(sentence: String, surface: String?)
        case build
        case check
        case ready
        case list(json: Bool)
        case status
        case show(String)
        case off(String, build: Bool)
        case on(String)
        case revise(String?)
        case drop
    }

    public struct Context: Sendable {
        public var item: String?
        public var echo: Bool
        public init(item: String?, echo: Bool = true) {
            self.item = item
            self.echo = echo
        }
    }

    public static func run(_ action: Action, context: Context) -> PluginTools.Outcome {
        do {
            return PluginTools.Outcome(output: try perform(action, context: context))
        } catch {
            return PluginTools.Outcome(errors: "\(error)\n", code: 1)
        }
    }

    /// What's known about the app people installed: the app itself says, the first time.
    public static func facts() throws -> CopyState {
        if let state = CopyState.load(), state.plainPath != nil { return state }
        guard let client = try? ControlClient(path: TiriPaths.socket, timeout: 5), let answer = try? client.send(ControlRequest(cmd: "change.facts")), answer.ok,
              let state = CopyState.load(), state.plainPath != nil else {
            throw ChangeFailure("Tiri has to be open for this.")
        }
        return state
    }

    private static func perform(_ action: Action, context: Context) throws -> String {
        let repo = SourceRepo()
        switch action {
        case .start(let sentence, let surface):
            let state = try facts()
            try requireNoUpdateUnderway(repo)
            let app = URL(fileURLWithPath: state.plainPath ?? "")
            try repo.prepare(archive: app.appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive), version: state.plainVersion ?? "",
                             changeUnderway: loadDraft() != nil)
            if let draft = loadDraft() {
                if draft.sentence == sentence { return startText(draft, repo: repo) }
                throw ChangeFailure("Another change is being made: “\(draft.sentence)”. Finish it with tiri change ready, or give it up with tiri change drop.")
            }
            let draft = ChangeDraft(id: newID(), sentence: sentence, surface: surface, item: context.item, startedAt: Date(), replacing: nil)
            try save(draft)
            return startText(draft, repo: repo)

        case .build:
            try requireRepo(repo)
            let started = Date()
            let result = fastBuild(in: repo)
            guard result.ok else { throw ChangeFailure(trimmedBuildOutput(result.output)) }
            return String(format: "Built in %.0f s.\n", Date().timeIntervalSince(started))

        case .check:
            let draft = try requireDraft()
            let outcome = try runCheck(id: draft.id, in: repo, echo: context.echo)
            switch outcome {
            case nil: return "No check yet. Write checks/\(draft.id).sh. See CHANGING.md.\n"
            case true?: return "Check passed.\n"
            case false?: throw ChangeFailure("Check failed.")
            }

        case .ready:
            return try ready(in: repo, context: context)

        case .list(let json):
            let changes = try repo.changes()
            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return String(decoding: try encoder.encode(changes), as: UTF8.self) + "\n"
            }
            guard !changes.isEmpty else { return "No changes yet.\n" }
            return changes.map { "\($0.id)  \($0.isOn ? "on " : "off")  \($0.sentence)  (\($0.size)\($0.hasCheck ? ", check" : ", no check")\($0.repairedFor.map { ", repaired for \($0)" } ?? ""))" }.joined(separator: "\n") + "\n"

        case .status:
            var lines: [String] = []
            if let draft = loadDraft() { lines.append("Being made: \(draft.id) “\(draft.sentence)”") }
            if let ready = ReadyCopy.load() { lines.append("Ready to try: “\(ready.sentence)”. It's waiting for the person to press Try It.") }
            if let state = CopyState.load() {
                lines.append("Running: \(state.active == .personal ? "their own copy" : "Plain Tiri")")
                if let trial = state.trial { lines.append("Being tried: “\(trial.sentence)”") }
            }
            lines.append("Changes: \((try? repo.changes().count) ?? 0)")
            return lines.joined(separator: "\n") + "\n"

        case .show(let id):
            let change = try repo.change(named: id)
            return try repo.git(["show", "--format=%B", change.commit], check: true).output

        case .off(let id, let build):
            try requireQuiet(repo)
            let change = try repo.change(named: id)
            try repo.turnOff(change)
            guard build else { return "Turned off.\n" }
            do {
                return try buildToggled(in: repo, sentence: "Turn off: \(change.sentence)", change: change, context: context)
            } catch {
                // What's left might not build without it. Nothing moves, then, and the error says why.
                try? repo.turnOn(try repo.change(named: id))
                throw error
            }

        case .on(let id):
            try requireQuiet(repo)
            let change = try repo.change(named: id)
            try repo.turnOn(change)
            do {
                return try buildToggled(in: repo, sentence: "Turn on: \(change.sentence)", change: change, context: context)
            } catch {
                // An old change can go on cleanly and still not compile, and it mustn't stop every change after it.
                try? repo.turnOff(try repo.change(named: id))
                throw error
            }

        case .revise(let id):
            try requireRepo(repo)
            try requireNoUpdateUnderway(repo)
            guard loadDraft() == nil else { throw ChangeFailure("Another change is being made. Finish it first.") }
            let all = try repo.changes()
            guard let change = try id.map({ try repo.change(named: $0) }) ?? all.last(where: \.isOn) else { throw ChangeFailure("There's no change to reopen.") }
            guard repo.isClean else { throw ChangeFailure("The source has edits that aren't part of any change.") }
            if change.isOn {
                guard try repo.head() == change.commit else {
                    throw ChangeFailure("Only the newest change can be reopened. Make this a new change on top of it.")
                }
            } else {
                let pick = try repo.git(["cherry-pick", "-n", change.commit])
                guard pick.ok else {
                    try repo.git(["reset", "--hard", "-q"])
                    throw ChangeFailure("That change no longer fits. Make it again as a new change.")
                }
                // It stays off in the list until it's really back, so giving this up loses nothing.
            }
            let draft = ChangeDraft(id: change.id, sentence: change.sentence, surface: change.surface, item: context.item ?? nil, startedAt: Date(), replacing: change.isOn ? change.commit : nil)
            try save(draft)
            return "Reopened “\(change.sentence)”. Edit, then tiri change build, check and ready.\n"

        case .drop:
            guard let draft = loadDraft() else { return "Nothing is being made.\n" }
            try requireNoUpdateUnderway(repo)
            try repo.git(["reset", "--hard", "-q"], check: true)
            try repo.git(["clean", "-fdq"], check: true)
            try? FileManager.default.removeItem(at: YourTiri.draftFile)
            return "Gave up “\(draft.sentence)”.\n"
        }
    }

    private static func startText(_ draft: ChangeDraft, repo: SourceRepo) -> String {
        """
        Making \(draft.id): “\(draft.sentence)”
        The source is at \(repo.folder.path). cd there. CHANGING.md says how it's laid out.
        Then: tiri change build   (after each edit, about 5 s)
              checks/\(draft.id).sh   (write it: how to tell this keeps working)
              tiri change check
              tiri change ready   (builds the copy the person will try. Takes a minute or two)

        """
    }

    private static func newID() -> String {
        "c" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(7))
    }

    public static func loadDraft() -> ChangeDraft? {
        guard let data = try? Data(contentsOf: YourTiri.draftFile) else { return nil }
        return try? CopyState.decoder.decode(ChangeDraft.self, from: data)
    }

    private static func save(_ draft: ChangeDraft) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try DurableFile.write(encoder.encode(draft), to: YourTiri.draftFile)
    }

    private static func requireRepo(_ repo: SourceRepo) throws {
        guard repo.exists else { throw ChangeFailure("There's no source yet. Start with tiri change start \"…\".") }
    }

    private static func requireDraft() throws -> ChangeDraft {
        guard let draft = loadDraft() else { throw ChangeFailure("Nothing is being made. Start with tiri change start \"…\".") }
        return draft
    }

    /// An update has the working files to itself, from its replay until it's been pressed.
    private static func requireNoUpdateUnderway(_ repo: SourceRepo) throws {
        guard repo.exists, (try? repo.text(["symbolic-ref", "--short", "HEAD"])) == UpdateTools.updateBranch else { return }
        throw ChangeFailure("An update is being got ready. Change this after it's been applied: \(UpdateStatus.load()?.line ?? "")")
    }

    private static func requireQuiet(_ repo: SourceRepo) throws {
        try requireRepo(repo)
        try requireNoUpdateUnderway(repo)
        if let draft = loadDraft() { throw ChangeFailure("“\(draft.sentence)” is being made. Finish it first.") }
        guard repo.isClean else { throw ChangeFailure("The source has edits that aren't part of any change.") }
    }

    /// The same flags as the check's test copy, so one doesn't rebuild the other.
    static let fastFlags = "-Xswiftc -O"

    static func fastBuild(in repo: SourceRepo) -> Tool.Result {
        Tool.shell("""
        set -e
        source scripts/swift-setup.sh
        swift build -c debug \(fastFlags) --product TiriApp
        swift build -c debug \(fastFlags) --product tiri
        swift build -c debug \(fastFlags) --product tiri-session
        """, in: repo.folder)
    }

    /// A build's errors are what's useful, and there can be thousands of lines around them.
    static func trimmedBuildOutput(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let errors = lines.filter { $0.contains("error:") && !$0.hasPrefix("error: fatalError") }
        var seen = Set<String>()
        let unique = errors.filter { seen.insert($0).inserted }
        if unique.isEmpty { return "The build failed:\n" + lines.suffix(30).joined(separator: "\n") }
        return "The build failed:\n" + unique.prefix(40).joined(separator: "\n")
    }

    /// Nil if there's no check. An invisible test copy, with its own state, and `tiri` on the PATH for the script.
    public static func runCheck(id: String, in repo: SourceRepo, echo: Bool) throws -> Bool? {
        let script = repo.folder.appendingPathComponent("checks/\(id).sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return try runChecks([script], in: repo, echo: echo).isEmpty
    }

    /// Which of them failed. They share one test copy, because starting one is the slow part.
    static func runChecks(_ scripts: [URL], in repo: SourceRepo, echo: Bool) throws -> [URL] {
        let environment = ["TIRI_DEV_ROOT": YourTiri.testCopies.path, "TIRI_DEV_SWIFT_FLAGS": fastFlags]
        // Its socket goes by this name, so it can't be shared with another Tiri's checks on this Mac.
        let name = "check-" + String(abs(YourTiri.root.path.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }) % 1_000_000)
        // Not being able to start the test copy says nothing about any change.
        let started = Tool.shell("mkdir -p \"$TIRI_DEV_ROOT\" && scripts/dev-app.sh start \(name)", in: repo.folder, environment: environment, echo: echo)
        guard started.ok else { throw ChangeFailure("Couldn't start a test copy to check this with:\n" + started.output.split(separator: "\n").suffix(8).joined(separator: "\n")) }
        defer { Tool.shell("scripts/dev-app.sh stop \(name)", in: repo.folder, environment: environment) }
        var failed: [URL] = []
        for script in scripts {
            let run = Tool.shell("""
            eval "$(scripts/dev-app.sh env \(name))"
            SOURCE="$PWD"
            mkdir -p "$TIRI_HOME/check" && cd "$TIRI_HOME/check"
            TIRI_SOURCE="$SOURCE" bash "\(script.path)"
            """, in: repo.folder, environment: environment, echo: echo)
            if !run.ok { failed.append(script) }
        }
        return failed
    }

    private static func ready(in repo: SourceRepo, context: Context) throws -> String {
        let draft = try requireDraft()
        try requireNoUpdateUnderway(repo)
        let before = try repo.head()
        guard !repo.isClean || draft.replacing != nil else { throw ChangeFailure("Nothing has been edited yet.") }
        let checked = try runCheck(id: draft.id, in: repo, echo: context.echo)
        if checked == false { throw ChangeFailure("Check failed, so this isn't ready. Fix it, or fix checks/\(draft.id).sh if the check is wrong.") }

        try repo.git(["add", "-A"], check: true)
        let message = repo.commitMessage(sentence: draft.sentence, id: draft.id, surface: draft.surface)
        try repo.git(["commit", "-q", "--allow-empty"] + (draft.replacing != nil ? ["--amend"] : []) + ["-m", message], check: true)
        do {
            let change = try repo.change(named: draft.id)
            let note = ReadyCopy(kind: .change, sentence: draft.sentence, change: draft.id, item: draft.item ?? context.item, size: change.size,
                                 checkPassed: checked, builtAt: Date(), commit: change.commit)
            try makeCopy(in: repo, note: note, echo: context.echo)
        } catch {
            // The edits go back to being edits, so they can be fixed and `ready` run again.
            try repo.git(["reset", "--soft", "-q", before], check: true)
            try repo.git(["reset", "-q"])
            throw error
        }
        // Reopened from being off, and now it's on again.
        _ = try? repo.git(["update-ref", "-d", "refs/tiri/off/\(draft.id)"])
        try? FileManager.default.removeItem(at: YourTiri.draftFile)
        tellTheApp()
        var text = "Ready. There's a card on your tab for the person to press Try It. You can't switch to it yourself.\n"
        if checked == nil { text += "It has no check, so at updates it'll be marked as needing a look. Write checks/\(draft.id).sh and run this again after tiri change revise.\n" }
        return text
    }

    private static func buildToggled(in repo: SourceRepo, sentence: String, change: PersonalChange, context: Context) throws -> String {
        let all = try repo.changes().filter(\.isOn)
        let note = ReadyCopy(kind: .toggled, sentence: sentence, change: change.id, item: context.item,
                             size: "\(all.count) \(all.count == 1 ? "change" : "changes") on", checkPassed: nil, builtAt: Date(), commit: try repo.head())
        try makeCopy(in: repo, note: note, echo: context.echo)
        tellTheApp()
        return "Ready to try.\n"
    }

    /// The real thing, in the background, signed with this Mac's own identity, beside whatever's running.
    public static func makeCopy(in repo: SourceRepo, note: ReadyCopy, echo: Bool) throws {
        let state = try facts()
        guard let plainID = state.plainBundleID else { throw ChangeFailure("Tiri has to be open for this.") }
        let identity = Tool.run(repo.folder.appendingPathComponent("scripts/personal-identity.sh").path, [YourTiri.identity.path])
        guard identity.ok else { throw ChangeFailure("Couldn't get this Mac's signing identity ready: \(identity.output)") }
        let hash = identity.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let building = YourTiri.building
        try? FileManager.default.removeItem(at: building)
        let environment = ["TIRI_BUILD_DIR": building.path, "TIRI_SIGN_IDENTITY": hash,
                           "TIRI_SIGN_KEYCHAIN": YourTiri.identity.appendingPathComponent("personal.keychain-db").path,
                           "TIRI_COPY": "personal", "TIRI_BUNDLE_ID": YourTiri.personalBundleID(plain: plainID),
                           "TIRI_RELEASE_COMMIT": try repo.releaseCommit()]
        // Always a release build, except in the update suites, where `TIRI_DEV_COPY_CONFIG=debug` makes a copy in a
        // fraction of the time: what they test is carrying changes over, not the compiler's optimizer.
        let config = ProcessInfo.processInfo.environment["TIRI_DEV_COPY_CONFIG"] == "debug" ? "debug" : "release"
        let build = Tool.run(repo.folder.appendingPathComponent("build.sh").path, [config], in: repo.folder, environment: environment)
        guard build.ok else { throw ChangeFailure(trimmedBuildOutput(build.output)) }
        // Nothing half-made is ever in `ready`.
        try CopyFiles.move(building.appendingPathComponent("Tiri.app"), to: YourTiri.ready)
        try? FileManager.default.removeItem(at: building)
        try note.save()
    }

    /// Best effort. It looks by itself the next time it starts.
    static func tellTheApp() {
        guard let client = try? ControlClient(path: TiriPaths.socket, timeout: 2) else { return }
        _ = try? client.send(ControlRequest(cmd: "change.refresh"))
    }
}
