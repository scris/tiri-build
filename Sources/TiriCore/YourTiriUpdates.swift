import Foundation

/// Where an update stands. What people see is one line and one button, which appears only when the new
/// copy already has their changes, is built, and has passed their checks.
public struct UpdateStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Someone's change is in the way, and this starts again when it's done.
        case waiting
        case replaying, building, checking
        /// An agent could mend what's left. See `needsRepair`.
        case needsRepair
        case ready
        case failed
    }

    public struct Named: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var sentence: String
        public var why: String?
        public init(id: String, sentence: String, why: String? = nil) {
            self.id = id
            self.sentence = sentence
            self.why = why
        }
    }

    public var version: String
    public var newRelease: String
    public var phase: Phase
    /// The new release of the app, signed by whoever makes Tiri, waiting beside the installed one.
    public var app: String
    public var message: String?
    public var carried: [Named] = []
    public var repaired: [Named] = []
    public var needsRepair: [Named] = []
    public var leftOut: [Named] = []
    public var retired: [Named] = []
    public var notes: String?
    /// The same version as the one installed, only built later. It's news, but not a new version, and isn't called one.
    public var sameVersion: Bool?

    /// What it's called, to start a sentence.
    public var name: String { sameVersion == true ? "A new build of Tiri" : "Tiri \(version)" }
    /// What it's called, inside one.
    public var inSentence: String { sameVersion == true ? "the new build of Tiri" : "Tiri \(version)" }
    /// The same two, in the words people read. `name` and `inSentence` go to agents, and stay English.
    public var shownName: String { sameVersion == true ? String(localized: "A new build of Tiri") : String(localized: "Tiri \(version)") }
    public var shownInSentence: String { sameVersion == true ? String(localized: "the new build of Tiri") : String(localized: "Tiri \(version)") }

    public init(version: String, newRelease: String, phase: Phase, app: String) {
        self.version = version
        self.newRelease = newRelease
        self.phase = phase
        self.app = app
    }

    public static var file: URL { YourTiri.updates.appendingPathComponent("status.json") }

    public static func load(from file: URL = UpdateStatus.file) -> UpdateStatus? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? CopyState.decoder.decode(UpdateStatus.self, from: data)
    }

    public func save(to file: URL = UpdateStatus.file) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// The line beside the button.
    public var line: String {
        let name = shownName
        switch phase {
        case .waiting: return String(localized: "\(name) will start when the change being made is finished.")
        case .replaying, .building, .checking: return String(localized: "Getting \(shownInSentence) ready, with your changes.")
        case .needsRepair:
            let names = UpdateStatus.names(needsRepair)
            return needsRepair.count == 1 ? String(localized: "\(name) is almost ready. \(names) has to be redone to fit it.")
                : String(localized: "\(name) is almost ready. \(names) have to be redone to fit it.")
        case .ready:
            let count = carried.count + repaired.count
            var text = count == 0 ? String(localized: "\(name) is ready.") : count == 1 ? String(localized: "\(name) is ready, with your change.")
                : String(localized: "\(name) is ready, with your \(count) changes.")
            if let rest = readyAfterChanges { text += " " + rest }
            return text
        case .failed: return message ?? String(localized: "\(name) couldn't be got ready.")
        }
    }

    /// What follows "… is ready": for a toast whose title says that much already. Nil when there's nothing more.
    public var readyDetail: String? {
        let count = carried.count + repaired.count
        let with = count == 0 ? nil : count == 1 ? String(localized: "With your change.") : String(localized: "With your \(count) changes.")
        let parts = [with, readyAfterChanges].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What's retired and what's left out, after the line about the changes that came along.
    private var readyAfterChanges: String? {
        var parts: [String] = []
        if let retiredLine { parts.append(retiredLine) }
        if !leftOut.isEmpty { parts.append(String(localized: "\(UpdateStatus.names(leftOut)) stays off for now.")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Good news, and the one thing about an update someone can't otherwise tell: what they asked for is Tiri's own now.
    public var retiredLine: String? {
        guard !retired.isEmpty else { return nil }
        let names = UpdateStatus.names(retired)
        return retired.count == 1 ? String(localized: "It does \(names) itself now, so your change isn't needed any more.")
            : String(localized: "It does \(names) itself now, so those changes aren't needed any more.")
    }

    public static func names(_ list: [Named]) -> String {
        L10n.list(list.map { String(localized: "“\($0.sentence)”") })
    }
}

/// One entry of a release feed: a small JSON file somewhere, naming a zip of the app.
public struct ReleaseEntry: Codable, Equatable, Sendable {
    public var version: String
    /// CFBundleVersion: a new build of the same version is still an update.
    public var build: String?
    public var url: String
    public var sha256: String
    public var notes: String?
}

/// `tiri update`: what carries someone's changes onto the next release, out of sight, beside what's running.
public enum UpdateTools {
    public enum Action: Equatable, Sendable {
        case status
        /// Asks the feed.
        case check(feed: String?)
        /// A new release of the app, from a folder or a zip.
        case prepare(String, notes: String?)
        case repair(String)
        case repaired
        case retire(String)
        case leaveOut(String)
    }

    public static func run(_ action: Action, context: ChangeTools.Context) -> PluginTools.Outcome {
        do {
            // Anything that moves things holds this for as long as it runs. It goes when the process does,
            // however that happens, which is how a stopped update is told from a running one.
            if action != .status, holdLock() == nil { throw ChangeFailure("An update is being got ready already.") }
            return PluginTools.Outcome(output: try perform(action, context: context))
        } catch {
            return PluginTools.Outcome(errors: "\(error)\n", code: 1)
        }
    }

    static var updateBranch: String { "update" }

    private static var lockFile: URL { YourTiri.updates.appendingPathComponent("lock") }
    nonisolated(unsafe) private static var heldLock: Int32?

    private static func holdLock() -> Int32? {
        if let heldLock { return heldLock }
        try? FileManager.default.createDirectory(at: YourTiri.updates, withIntermediateDirectories: true)
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        heldLock = descriptor
        return descriptor
    }

    /// An update stopped halfway by a quit, a restart or a crash. The working files go back to where they
    /// were, and it starts again. True if there was one.
    public static func recoverIfInterrupted(repo: SourceRepo = SourceRepo()) -> Bool {
        guard var status = UpdateStatus.load(), [.replaying, .building, .checking].contains(status.phase) else { return false }
        guard let held = holdLock() else { return false }
        defer {
            close(held)
            heldLock = nil
        }
        restoreWorkingFiles(repo: repo)
        status.phase = .waiting
        try? status.save()
        return true
    }

    /// Off the update's branch and onto the person's own, with nothing half-done left behind.
    static func restoreWorkingFiles(repo: SourceRepo) {
        guard repo.exists else { return }
        _ = try? repo.git(["cherry-pick", "--abort"])
        _ = try? repo.git(["rebase", "--abort"])
        _ = try? repo.git(["reset", "--hard", "-q"])
        _ = try? repo.git(["clean", "-fdq"])
        _ = try? repo.git(["checkout", "-q", "-f", "personal"])
        _ = try? repo.git(["branch", "-D", updateBranch])
        try? FileManager.default.removeItem(at: repairMarker)
    }

    /// What was being repaired goes away, and the files are as the update left them.
    private static func clearRepair(repo: SourceRepo) throws {
        try repo.git(["reset", "--hard", "-q"], check: true)
        try repo.git(["clean", "-fdq"], check: true)
        try? FileManager.default.removeItem(at: repairMarker)
    }

    private static func perform(_ action: Action, context: ChangeTools.Context) throws -> String {
        let repo = SourceRepo()
        switch action {
        case .status:
            guard let status = UpdateStatus.load() else { return "No update waiting.\n" }
            var text = status.line + "\n"
            for entry in status.needsRepair { text += "needs repair: \(entry.id)  \(entry.sentence)  (\(entry.why ?? ""))\n" }
            for entry in status.leftOut { text += "left out: \(entry.id)  \(entry.sentence)  (\(entry.why ?? ""))\n" }
            for entry in status.retired { text += "retired: \(entry.sentence)\n" }
            return text

        case .check(let feed):
            guard let address = feed ?? configuredFeed(), !address.isEmpty else { return "No feed is set, so there's nothing to ask.\n" }
            return try checkFeed(address, repo: repo, context: context)

        case .prepare(let path, let notes):
            return try prepare(release: URL(fileURLWithPath: path), notes: notes, repo: repo, context: context)

        case .repair(let id):
            return try beginRepair(id, repo: repo)

        case .repaired:
            return try finishRepair(repo: repo, context: context)

        case .retire(let id):
            var status = try requireUpdate(phase: .needsRepair)
            guard let entry = status.needsRepair.first(where: { $0.id == id }) else { throw ChangeFailure("\(id) isn't waiting for repair.") }
            status.needsRepair.removeAll { $0.id == id }
            status.retired.append(entry)
            try clearRepair(repo: repo)
            try status.save()
            return try carryOn(status, repo: repo, context: context)

        case .leaveOut(let id):
            var status = try requireUpdate(phase: .needsRepair)
            guard var entry = status.needsRepair.first(where: { $0.id == id }) else { throw ChangeFailure("\(id) isn't waiting for repair.") }
            if entry.why == nil { entry.why = "couldn't be repaired" }
            status.needsRepair.removeAll { $0.id == id }
            status.leftOut.append(entry)
            try clearRepair(repo: repo)
            try status.save()
            return try carryOn(status, repo: repo, context: context)
        }
    }

    private static func requireUpdate(phase: UpdateStatus.Phase) throws -> UpdateStatus {
        guard let status = UpdateStatus.load(), status.phase == phase else { throw ChangeFailure("There's no update waiting for this.") }
        return status
    }

    static func configuredFeed() -> String? {
        ProcessInfo.processInfo.environment["TIRI_UPDATE_FEED"]
    }

    // MARK: The new release

    /// https only. A test copy may also use a feed on this Mac, so a whole update can be tried without publishing one.
    static func isFeedAddress(_ address: String) -> Bool {
        if address.hasPrefix("https://") { return true }
        return ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1" && address.hasPrefix("http://127.0.0.1:")
    }

    private static func checkFeed(_ address: String, repo: SourceRepo, context: ChangeTools.Context) throws -> String {
        guard isFeedAddress(address), let url = URL(string: address), let data = try? Data(contentsOf: url) else { throw ChangeFailure("Couldn't read \(address). A feed has to be https.") }
        guard let entry = try? JSONDecoder().decode(ReleaseEntry.self, from: data), isFeedAddress(entry.url),
              !entry.version.isEmpty, entry.version.allSatisfy({ $0.isNumber || $0 == "." }) else { throw ChangeFailure("\(address) isn't a release feed.") }
        let state = try ChangeTools.facts()
        if let running = state.plainVersion, !isNewer(entry.version, than: running) {
            let runningBuild = state.plainPath.flatMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
            let newerBuild = entry.version == running && entry.build.map { build in runningBuild.map { isNewer(build, than: $0) } ?? false } == true
            if !newerBuild { return "Tiri \(running) is the newest.\n" }
        }
        if let waiting = UpdateStatus.load(), waiting.version == entry.version { return waiting.line + "\n" }
        let folder = YourTiri.updates.appendingPathComponent(entry.version, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("Tiri.zip")
        let download = Tool.run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", zip.path, entry.url])
        guard download.ok else { throw ChangeFailure("Couldn't download Tiri \(entry.version).") }
        let hash = Tool.run("/usr/bin/shasum", ["-a", "256", zip.path]).output.split(separator: " ").first.map(String.init)
        guard hash == entry.sha256 else {
            try? FileManager.default.removeItem(at: zip)
            throw ChangeFailure("Tiri \(entry.version) didn't arrive whole.")
        }
        // A feed's notes aren't passed on. They'd reach an agent's prompt, and all that vouches for them is the feed.
        // The ones inside the release are signed with it, and `prepare` reads those.
        return try prepare(release: zip, notes: nil, repo: repo, context: context)
    }

    public static func isNewer(_ candidate: String, than running: String) -> Bool {
        candidate.compare(running, options: .numeric) == .orderedDescending
    }

    /// Only the next release of this app, from whoever made the one installed. The signature is the one thing here an
    /// agent or a download can't arrange. A self-signed certificate can claim any team name, so this asks for Apple's
    /// chain as well. It's checked before the release goes anywhere, and again when it's used.
    public static func checkRelease(_ new: URL, replacing installed: URL) throws {
        guard let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String,
              FileManager.default.isExecutableFile(atPath: new.appendingPathComponent("Contents/MacOS/Tiri").path) else {
            throw ChangeFailure(String(localized: "That isn't a copy of Tiri."))
        }
        guard let current = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")),
              let currentVersion = current["CFBundleShortVersionString"] as? String else {
            throw ChangeFailure(String(localized: "Can't find the Tiri that's installed, so there's nothing to compare this with."))
        }
        guard info["CFBundleIdentifier"] as? String == current["CFBundleIdentifier"] as? String else {
            throw ChangeFailure(String(localized: "That isn't a copy of this Tiri."))
        }
        let isNewerBuild = version == currentVersion && isNewer(info["CFBundleVersion"] as? String ?? "0", than: current["CFBundleVersion"] as? String ?? "0")
        guard isNewer(version, than: currentVersion) || isNewerBuild else { throw ChangeFailure(String(localized: "That copy of Tiri \(version) isn't newer than the \(currentVersion) you have.")) }
        guard Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]).ok else {
            throw ChangeFailure(String(localized: "That copy of Tiri isn't signed properly."))
        }
        let details = Tool.run("/usr/bin/codesign", ["-dvv", installed.path])
        guard details.ok else { throw ChangeFailure(String(localized: "Can't read the signature of the Tiri that's installed.")) }
        let team = details.output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        // A build from source has no team, and neither does its update. There's no maker to hold it to.
        guard let team, team != "not set" else { return }
        guard team.allSatisfy({ $0.isLetter || $0.isNumber }),
              Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"", new.path]).ok else {
            throw ChangeFailure(String(localized: "That copy of Tiri wasn't signed by whoever made the one you have."))
        }
    }

    public static let notesFile = "release-notes.txt"

    /// Read only once the release's signature has been checked, because this goes to an agent.
    static func notesInside(_ app: URL) -> String? {
        guard let text = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/\(notesFile)"), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(4000))
    }

    public static func prepare(release: URL, notes: String?, repo: SourceRepo, context: ChangeTools.Context) throws -> String {
        let state = try ChangeTools.facts()
        guard let installed = state.plainPath else { throw ChangeFailure("Tiri has to be open for this.") }
        let app = try unpackRelease(release, replacing: URL(fileURLWithPath: installed))
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let commit = info?[YourTiri.commitKey] as? String ?? "unknown"
        // One release at a time, always: replaying only ever crosses one step.
        var status = UpdateStatus(version: version, newRelease: commit, phase: .replaying, app: app.path)
        if version == state.plainVersion { status.sameVersion = true }
        status.notes = notes ?? notesInside(app)
        guard repo.exists else {
            // Nobody's changes to carry. The app as it came is the whole update, and there's nothing to build.
            status.phase = .ready
            try status.save()
            ChangeTools.tellTheApp()
            return status.line + "\n"
        }
        if ChangeTools.loadDraft() != nil || !repo.isClean {
            status.phase = .waiting
            try status.save()
            return status.line + "\n"
        }
        try status.save()
        let archive = app.appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive)
        let newRelease = try commitRelease(archive: archive, version: version, repo: repo)
        try replay(onto: newRelease, status: &status, repo: repo)
        // All of them off: there's no copy to build, but the source still has to move on with the app.
        if try repo.changes().allSatisfy({ !$0.isOn }) {
            status.phase = .ready
            try status.save()
            ChangeTools.tellTheApp()
            return status.line + "\n"
        }
        return try carryOn(status, repo: repo, context: context)
    }

    /// Whichever form it came in, ending as an app in the updates folder.
    static func unpackRelease(_ release: URL, replacing installed: URL) throws -> URL {
        let manager = FileManager.default
        let holding = YourTiri.updates.appendingPathComponent("incoming-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try manager.createDirectory(at: holding, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: holding) }
        let app = holding.appendingPathComponent("Tiri.app", isDirectory: true)
        if release.pathExtension == "zip" {
            let unzipped = Tool.run("/usr/bin/ditto", ["-x", "-k", release.path, holding.path])
            guard unzipped.ok else { throw ChangeFailure("Couldn't open \(release.lastPathComponent).") }
        } else {
            let copied = Tool.run("/usr/bin/ditto", [release.path, app.path])
            guard copied.ok else { throw ChangeFailure("Couldn't copy \(release.lastPathComponent).") }
        }
        // Before it takes the place of whatever's waiting: something refused here changes nothing.
        try checkRelease(app, replacing: installed)
        let final = YourTiri.updates.appendingPathComponent("waiting/Tiri.app", isDirectory: true)
        try CopyFiles.move(app, to: final)
        return final
    }

    /// The new source as the next commit on `release`, without touching any working files.
    static func commitRelease(archive: URL, version: String, repo: SourceRepo) throws -> String {
        guard FileManager.default.fileExists(atPath: archive.path) else { throw ChangeFailure("That copy of Tiri doesn't carry its source.") }
        let manager = FileManager.default
        let tree = YourTiri.updates.appendingPathComponent("tree-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try manager.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: tree) }
        guard Tool.run("/usr/bin/tar", ["-xzf", archive.path, "-C", tree.path]).ok else { throw ChangeFailure("Couldn't unpack the new source.") }
        let index = tree.path + ".index"
        defer { try? manager.removeItem(atPath: index) }
        let environment = ["GIT_DIR": repo.folder.appendingPathComponent(".git").path, "GIT_WORK_TREE": tree.path, "GIT_INDEX_FILE": index]
        guard Tool.run("/usr/bin/git", ["add", "-A"], in: tree, environment: environment).ok else { throw ChangeFailure("Couldn't read the new source.") }
        let written = Tool.run("/usr/bin/git", ["write-tree"], in: tree, environment: environment)
        guard written.ok else { throw ChangeFailure("Couldn't read the new source.") }
        let treeID = written.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try repo.text(["commit-tree", treeID, "-p", "release", "-m", "Tiri \(version)"])
        try repo.git(["update-ref", "refs/tiri/next-release", commit], check: true)
        return commit
    }

    // MARK: Replay, by Git and then by a merge that knows Swift. No agent, no tokens.

    static func replay(onto newRelease: String, status: inout UpdateStatus, repo: SourceRepo) throws {
        let changes = try repo.changes().filter(\.isOn)
        try repo.installMergeDriver()
        try repo.git(["checkout", "-q", "-B", updateBranch, newRelease], check: true)
        status.carried = []
        status.retired = []
        status.needsRepair = []
        status.leftOut = []
        for change in changes {
            let named = UpdateStatus.Named(id: change.id, sentence: change.sentence)
            let pick = try repo.git(["cherry-pick", "--allow-empty-message", change.commit])
            if pick.ok {
                // Its check always comes along, so what counts is whether anything else did. If not, Tiri does this now.
                if try repo.text(["diff", "--name-only", "HEAD^", "HEAD", "--", ".", ":(exclude)checks"]).isEmpty {
                    try repo.git(["reset", "--hard", "-q", "HEAD^"], check: true)
                    status.retired.append(named)
                } else {
                    status.carried.append(named)
                }
            } else if try repo.text(["diff", "--name-only", "--diff-filter=U"]).isEmpty, repo.isClean {
                // Tiri learned to do this itself. It replays to nothing, and so it's done. Read from the state of
                // the files: Git's words for this sit beside the commit's subject, which could say anything.
                try repo.git(["cherry-pick", "--skip"])
                status.retired.append(named)
            } else {
                try repo.git(["cherry-pick", "--abort"])
                var waiting = named
                waiting.why = "it conflicts with the new version"
                status.needsRepair.append(waiting)
            }
        }
        try status.save()
    }

    /// What follows the replay, and follows each repair: repairs first, then build, check and make the copy.
    private static func carryOn(_ incoming: UpdateStatus, repo: SourceRepo, context: ChangeTools.Context) throws -> String {
        do {
            return try carry(incoming, repo: repo, context: context)
        } catch {
            // Whatever went wrong, people's changes and new changes aren't held up by it.
            var status = UpdateStatus.load() ?? incoming
            status.phase = .failed
            status.message = status.message ?? "\(status.name) couldn't be got ready: \(error)"
            try? status.save()
            restoreWorkingFiles(repo: repo)
            ChangeTools.tellTheApp()
            throw error
        }
    }

    private static func carry(_ incoming: UpdateStatus, repo: SourceRepo, context: ChangeTools.Context) throws -> String {
        var status = incoming
        // Changes with no way to tell that they still work are never repaired silently, and never carried silently.
        guard status.needsRepair.isEmpty else {
            status.phase = .needsRepair
            try status.save()
            ChangeTools.tellTheApp()
            return status.line + "\n"
        }
        status.phase = .building
        try status.save()
        // A build that fails has to be somebody's fault, found by halving, and that one goes back to waiting.
        let build = ChangeTools.fastBuild(in: repo)
        if !build.ok {
            if try findBreakingChange(status: &status, repo: repo) {
                return try carry(status, repo: repo, context: context)
            }
            status.phase = .failed
            status.message = "\(status.name) didn't build, and none of your changes is why."
            try status.save()
            throw ChangeFailure(ChangeTools.trimmedBuildOutput(build.output))
        }
        status.phase = .checking
        try status.save()
        // Which checks exist is read from the tree that's about to ship, so a retired change's check has gone with it.
        let checks = status.carried + status.repaired
        let scripts = checks.compactMap { entry -> URL? in
            let script = repo.folder.appendingPathComponent("checks/\(entry.id).sh")
            return FileManager.default.fileExists(atPath: script.path) ? script : nil
        }
        if !scripts.isEmpty {
            let failed = try ChangeTools.runChecks(scripts, in: repo, echo: context.echo)
            if !failed.isEmpty {
                for script in failed {
                    let id = script.deletingPathExtension().lastPathComponent
                    guard let entry = checks.first(where: { $0.id == id }) else { continue }
                    try moveToRepair(entry, why: "its check fails on the new version", status: &status, repo: repo)
                }
                return try carry(status, repo: repo, context: context)
            }
        }
        status.phase = .building
        try status.save()
        let head = try repo.text(["rev-parse", "HEAD"])
        // The copy's release is the new one, which isn't called `release` until the switch.
        try repo.git(["update-ref", "refs/tiri/previous-release", "release"], check: true)
        try repo.git(["branch", "-f", "release", "refs/tiri/next-release"], check: true)
        defer { _ = try? repo.git(["branch", "-f", "release", "refs/tiri/previous-release"]) }
        let note = ReadyCopy(kind: .update, sentence: status.line, change: nil, item: nil, size: "", checkPassed: true, builtAt: Date(), commit: head)
        try ChangeTools.makeCopy(in: repo, note: note, echo: context.echo)
        status.phase = .ready
        try status.save()
        ChangeTools.tellTheApp()
        return status.line + "\n"
    }

    /// Takes a change's commit back out of the update, leaving later ones in place.
    private static func moveToRepair(_ entry: UpdateStatus.Named, why: String, status: inout UpdateStatus, repo: SourceRepo) throws {
        let commit = try repo.text(["log", "--format=%H", "--grep", "Tiri-Change: \(entry.id)", "-1", "HEAD"])
        guard !commit.isEmpty else { return }
        let rebase = try repo.git(["rebase", "-q", "--onto", commit + "^", commit])
        if !rebase.ok {
            // A later change builds on it. They can't stay without it, so they wait with it.
            try repo.git(["rebase", "--abort"])
            let later = try repo.text(["rev-list", "--reverse", commit + "..HEAD"]).split(separator: "\n").map(String.init)
            let laterIDs = try later.map { try repo.text(["log", "-1", "--format=%(trailers:key=Tiri-Change,valueonly)", $0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            try repo.git(["reset", "--hard", "-q", commit + "^"], check: true)
            for id in laterIDs {
                guard var dependent = (status.carried + status.repaired).first(where: { $0.id == id }) else { continue }
                status.carried.removeAll { $0.id == id }
                status.repaired.removeAll { $0.id == id }
                dependent.why = "it builds on “\(entry.sentence)”"
                status.needsRepair.append(dependent)
            }
        }
        status.carried.removeAll { $0.id == entry.id }
        status.repaired.removeAll { $0.id == entry.id }
        var waiting = entry
        waiting.why = why
        status.needsRepair.append(waiting)
        try status.save()
    }

    /// With many changes, halves them to find the one that breaks the build. True if it found one.
    private static func findBreakingChange(status: inout UpdateStatus, repo: SourceRepo) throws -> Bool {
        let commits = try repo.text(["rev-list", "--reverse", "refs/tiri/next-release..HEAD"]).split(separator: "\n").map(String.init)
        guard !commits.isEmpty else { return false }
        let tip = try repo.text(["rev-parse", "HEAD"])
        defer { _ = try? repo.git(["checkout", "-q", "-B", updateBranch, tip]) }
        // The release alone has to build, or it's nothing to do with anyone's change.
        try repo.git(["checkout", "-q", "refs/tiri/next-release"], check: true)
        guard ChangeTools.fastBuild(in: repo).ok else { return false }
        var low = 0, high = commits.count - 1
        while low < high {
            let middle = (low + high) / 2
            try repo.git(["checkout", "-q", commits[middle]], check: true)
            if ChangeTools.fastBuild(in: repo).ok { low = middle + 1 } else { high = middle }
        }
        let culprit = commits[low]
        let id = try repo.text(["log", "-1", "--format=%(trailers:key=Tiri-Change,valueonly)", culprit]).trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.git(["checkout", "-q", "-B", updateBranch, tip], check: true)
        guard let entry = (status.carried + status.repaired).first(where: { $0.id == id }) else { return false }
        try moveToRepair(entry, why: "it doesn't build on the new version", status: &status, repo: repo)
        return true
    }

    // MARK: Repair, by the person's own agent

    /// The prompt carries the sentence, the old diff and the release notes.
    public static func repairPrompt(_ entry: UpdateStatus.Named, status: UpdateStatus) -> String {
        var text = "\(status.name) is out, and one of my changes needs mending to go with it. The change, in my words: \(entry.sentence). The trouble: \(entry.why ?? "it doesn't fit any more"). This folder is Tiri's source, on the new version with my other changes on it."
        if let notes = status.notes, !notes.isEmpty { text += " What's new in \(status.inSentence): \(notes)" }
        text += " Run `tiri update repair \(entry.id)`, which puts the old change into these files with any conflicts marked and shows its old diff. Keep what the sentence asks for, and keep what's new in \(status.inSentence). Run `tiri change build`, then `tiri update repaired`. If the new version already does what the sentence asks, run `tiri update retire \(entry.id)`. If it really can't be done, run `tiri update leave-out \(entry.id)`. Say what you touched. Change nothing else."
        return text
    }

    private static func beginRepair(_ id: String, repo: SourceRepo) throws -> String {
        let status = try requireUpdate(phase: .needsRepair)
        guard status.needsRepair.contains(where: { $0.id == id }) else { throw ChangeFailure("\(id) isn't waiting for repair.") }
        if FileManager.default.fileExists(atPath: repairMarker.path) {
            throw ChangeFailure("Something is being repaired already. Finish it with tiri update repaired, or give it up with tiri update leave-out.")
        }
        let commit = try oldCommit(id, repo: repo)
        let pick = try repo.git(["cherry-pick", "--no-commit", commit])
        let diff = try repo.git(["show", "--format=%B", commit], check: true).output
        var text = pick.ok ? "It applies, and may only need adapting. It's in your working files.\n" : "It's in your working files, with conflicts marked.\n"
        try "\(id)\n".write(to: repairMarker, atomically: true, encoding: .utf8)
        text += "\nThe change as it was:\n\n" + diff
        return text
    }

    private static var repairMarker: URL { YourTiri.updates.appendingPathComponent("repairing") }

    /// From the line of changes as it was before this update began.
    private static func oldCommit(_ id: String, repo: SourceRepo) throws -> String {
        let commit = try repo.text(["log", "--format=%H", "--grep", "Tiri-Change: \(id)", "-1", "personal"])
        guard !commit.isEmpty else { throw ChangeFailure("Can't find \(id).") }
        return commit
    }

    private static func finishRepair(repo: SourceRepo, context: ChangeTools.Context) throws -> String {
        var status = try requireUpdate(phase: .needsRepair)
        guard let id = (try? String(contentsOf: repairMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              let entry = status.needsRepair.first(where: { $0.id == id }) else {
            throw ChangeFailure("Nothing is being repaired. Start with tiri update repair <id>.")
        }
        let unresolved = try repo.text(["diff", "--name-only", "--diff-filter=U"])
        let touched = try repo.text(["diff", "HEAD", "--name-only"]).split(separator: "\n").map(String.init)
        let marked = touched.contains { name in
            let text = (try? String(contentsOf: repo.folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.contains("\n<<<<<<< ") || text.contains("\n>>>>>>> ")
        }
        guard unresolved.isEmpty || !marked, !marked else { throw ChangeFailure("There are conflicts still marked.") }
        let build = ChangeTools.fastBuild(in: repo)
        guard build.ok else { throw ChangeFailure(ChangeTools.trimmedBuildOutput(build.output)) }
        let old = try oldCommit(id, repo: repo)
        try repo.git(["add", "-A"], check: true)
        let mended = try filesRepairChanged(from: old, repo: repo)
        let message = try repairMessage(old: repo.text(["log", "-1", "--format=%B", old]), version: status.version, touched: mended)
        try repo.git(["commit", "-q", "--allow-empty", "-m", message], check: true)
        // Its check has to pass again, on the repair, or this isn't repaired.
        if try ChangeTools.runCheck(id: id, in: repo, echo: context.echo) == false {
            try repo.git(["reset", "--soft", "-q", "HEAD^"], check: true)
            try repo.git(["reset", "-q"])
            throw ChangeFailure("Its check still fails. Fix it, and run tiri update repaired again.")
        }
        try? FileManager.default.removeItem(at: repairMarker)
        status.needsRepair.removeAll { $0.id == id }
        status.repaired.append(entry)
        try status.save()
        return try carryOn(status, repo: repo, context: context)
    }

    /// What a person is shown: where the repair made the change differ, leaving aside where it merely moved.
    private static func filesRepairChanged(from old: String, repo: SourceRepo) throws -> [String] {
        func changedLines(_ arguments: [String]) throws -> [Substring] {
            try repo.git(["diff"] + arguments, check: true).output.split(separator: "\n").filter {
                ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---"))
            }
        }
        let before = try repo.text(["diff", "--name-only", old + "^", old]).split(separator: "\n").map(String.init)
        let after = try repo.text(["diff", "--cached", "--name-only", "HEAD"]).split(separator: "\n").map(String.init)
        return try Set(before + after).sorted().filter { file in
            try changedLines([old + "^", old, "--", file]) != changedLines(["--cached", "HEAD", "--", file])
        }
    }

    /// Only the latest repair is what's said about it. These join the block of trailers, since one that
    /// follows a blank line isn't read as a trailer.
    static func repairMessage(old: String, version: String, touched: [String]) -> String {
        let kept = old.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("Tiri-Repair") }.joined(separator: "\n")
        var message = kept.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\(SourceRepo.trailerRepaired): \(version)\n"
        for file in touched { message += "\(SourceRepo.trailerRepairTouched): \(file)\n" }
        return message
    }

    // MARK: Pressing Update

    /// Everything but the app itself: this is about to be what's real. Says where the app goes next.
    public static func commitToUpdate(repo: SourceRepo = SourceRepo()) throws {
        guard let status = UpdateStatus.load(), status.phase == .ready else { throw ChangeFailure(String(localized: "There's no update ready.")) }
        var state = CopyState.load() ?? CopyState()
        // Changes were carried, so there has to be the copy that carries them, or the app would go backwards.
        let carriesChanges = !status.carried.isEmpty || !status.repaired.isEmpty
        let hasCopy = FileManager.default.fileExists(atPath: YourTiri.ready.path) && ReadyCopy.load()?.kind == .update
        if carriesChanges, !hasCopy { throw ChangeFailure(String(localized: "The copy with your changes in it has gone. This update has to be got ready again.")) }
        if repo.exists, try repo.git(["rev-parse", "-q", "--verify", updateBranch]).ok {
            // What was left out stays around, turned off, for when it can come back.
            for entry in status.leftOut {
                let old = try oldCommit(entry.id, repo: repo)
                try repo.git(["update-ref", "refs/tiri/off/\(entry.id)", old], check: true)
            }
            for entry in status.retired { try repo.git(["update-ref", "-d", "refs/tiri/off/\(entry.id)"]) }
            try repo.git(["checkout", "-q", "personal"], check: true)
            try repo.git(["reset", "--hard", "-q", updateBranch], check: true)
            try repo.git(["branch", "-f", "release", "refs/tiri/next-release"], check: true)
            try repo.git(["branch", "-D", updateBranch])
            try repo.git(["update-ref", "-d", "refs/tiri/next-release"])
            try repo.git(["update-ref", "-d", "refs/tiri/previous-release"])
        }
        if hasCopy {
            try CopyFiles.promoteReady()
            try? FileManager.default.removeItem(at: YourTiri.readyNote)
            state.active = .personal
        } else {
            // What's in `current` was built on the old release. Nothing's on, so the new app is the whole of it.
            state.active = .plain
        }
        state.trial = nil
        state.attempts = 0
        // Said once, by the copy that comes up: good news, so not where trouble is said.
        var news: [String] = []
        let count = status.carried.count + status.repaired.count
        // Written by the app at the switch, so in its language: the copy that says it is in the same one.
        if count > 0 { news.append(count == 1 ? String(localized: "Your change came along.") : String(localized: "Your \(count) changes came along.")) }
        if !status.retired.isEmpty {
            // What happened first, then their words, which are long and can be cut.
            let names = UpdateStatus.names(status.retired)
            news.append(status.retired.count == 1 ? String(localized: "Your change is retired, since Tiri does it itself now: \(names).")
                : String(localized: "Those changes are retired, since Tiri does them itself now: \(names)."))
        }
        if !status.leftOut.isEmpty { news.append(String(localized: "\(UpdateStatus.names(status.leftOut)) stays off for now, and is kept.")) }
        state.news = CopyState.News(title: status.sameVersion == true ? String(localized: "Tiri is up to date") : String(localized: "Updated to Tiri \(status.version)"),
                                    detail: news.isEmpty ? nil : news.joined(separator: " "), retired: !status.retired.isEmpty)
        state.notice = nil
        try state.save()
    }
}
