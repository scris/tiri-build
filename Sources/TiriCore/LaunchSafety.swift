import Foundation

/// One Tiri for one state folder. Held from the first moment of a launch until the process ends, however it ends, so
/// a second launch can tell a running Tiri from a crashed one without asking it anything. A Tiri that's busy, behind a
/// permission prompt or a long save, still holds it. Test copies have their own state folder, and so their own lock.
public enum InstanceLock {
    public static var file: URL { TiriPaths.supportDirectory.appendingPathComponent("instance.lock") }
    nonisolated(unsafe) private static var held: Int32?

    /// True if this process has it now. Never closed: it goes when the process does. Not passed on to anything Tiri
    /// starts, or a terminal's program would hold it after Tiri had gone.
    public static func claim(at url: URL = file) -> Bool {
        if held != nil { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true } // Can't tell: better to run than to refuse.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        held = fd
        // Who has it, for a second launch to bring forward without asking anything of this one.
        let pid = Array("\(getpid())\n".utf8)
        ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return true
    }

    /// This process has it: no other Tiri is running on this state folder, whatever a socket seems to say.
    public static var isHeld: Bool { held != nil }

    /// The process that has it, as it wrote itself down.
    public static func holder(at url: URL = file) -> pid_t? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Launches that haven't finished, as Firefox counts them: begun when Tiri starts, cleared once it has stayed up a
/// while or quit on purpose. Two unfinished in a row and the next launch starts safely, without what's most likely to
/// have stopped it.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var unfinished = 0
    /// The version an update replaced, and the one it put in place, until a launch of the new one finishes.
    public var updatedFrom: String?
    public var updatedTo: String?

    public init() {}

    public static var file: URL { TiriPaths.supportDirectory.appendingPathComponent("launching.json") }
    public static let safeAfter = 2

    public static func load(from file: URL = LaunchRecord.file) -> LaunchRecord {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LaunchRecord.self, from: $0) } ?? LaunchRecord()
    }

    public func save(to file: URL = LaunchRecord.file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? DurableFile.write(data, to: file) }
    }

    /// At the start of a launch: whether it should start safely, and the record from before it.
    public static func begin(file: URL = LaunchRecord.file) -> (safe: Bool, before: LaunchRecord) {
        let before = load(from: file)
        var now = before
        now.unfinished += 1
        now.save(to: file)
        return (before.unfinished >= safeAfter, before)
    }

    /// It stayed up, or quit on purpose.
    public static func finish(file: URL = LaunchRecord.file) {
        let record = load(from: file)
        guard record != LaunchRecord() else { return }
        LaunchRecord().save(to: file)
    }

    /// Written by an update as it puts the new release in place, for the launches that follow it.
    public static func updated(from old: String?, to new: String?, file: URL = LaunchRecord.file) {
        var record = load(from: file)
        record.updatedFrom = old
        record.updatedTo = new
        record.unfinished = 0
        record.save(to: file)
    }
}

/// Where the app is, and whether an update could ever be put there. Asked before an update is fetched, as Sparkle does,
/// so one that can't go in place is never downloaded and offered.
public enum InstallPlace {
    public enum Problem: Equatable, Sendable {
        /// macOS runs an app opened straight from Downloads from a temporary, read-only place.
        case translocated
        /// A disk image, or any volume that can't be written.
        case readOnly
        /// The folder it's in, or the app itself, can't be changed by this user.
        case notWritable(String)

        /// Moving it to Applications puts this right.
        public var isMovable: Bool { self == .translocated || self == .readOnly }

        public var shown: String {
            switch self {
            case .translocated, .readOnly: String(localized: "Updates can't go where it's running now.")
            case .notWritable(let folder): String(localized: "Tiri can't change \((folder as NSString).abbreviatingWithTildeInPath).")
            }
        }

        /// For `tiri`, which speaks English.
        public var english: String {
            switch self {
            case .translocated, .readOnly: "Tiri is running from a disk image or a read-only place, where it can't be updated. Move it to Applications first."
            case .notWritable(let folder): "Tiri can't change \(folder), so it can't update itself there."
            }
        }
    }

    public static func problem(appPath: String) -> Problem? {
        if appPath.contains("/AppTranslocation/") { return .translocated }
        var volume = statfs()
        if statfs(appPath, &volume) == 0, volume.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnly }
        let folder = (appPath as NSString).deletingLastPathComponent
        // Moving a folder from one place to another changes its `..`, so the app itself has to be writable too.
        if access(folder, W_OK) != 0 { return .notWritable(folder) }
        if access(appPath, W_OK) != 0 { return .notWritable(appPath) }
        return nil
    }

    /// Whether two paths are on one volume, where a rename can swap them.
    public static func sameVolume(_ first: String, _ second: String) -> Bool {
        var a = stat(), b = stat()
        guard stat(first, &a) == 0, stat(second, &b) == 0 else { return false }
        return a.st_dev == b.st_dev
    }
}

/// Back to the release an update replaced, when the new one won't start. Asked for, never automatic, because the normal
/// update check only ever goes forward. The release that wouldn't start is kept from being offered again.
public enum UpdateRollback {
    public static var previous: URL { YourTiri.updates.appendingPathComponent("previous/Tiri.app", isDirectory: true) }

    /// The version that can be gone back to, if there's one.
    public static func available(installed: URL, expected: String?, previous: URL = UpdateRollback.previous) -> String? {
        guard let info = NSDictionary(contentsOf: previous.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String,
              let current = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == current["CFBundleIdentifier"] as? String,
              FileManager.default.isExecutableFile(atPath: previous.appendingPathComponent("Contents/MacOS/Tiri").path) else { return nil }
        if let expected, version != expected { return nil }
        return version
    }

    /// The previous release goes back in place, and what's installed now takes its place in `previous`, never to be run
    /// again from there. Returns the version that wouldn't start.
    @discardableResult
    public static func run(installed: URL, previous: URL = UpdateRollback.previous) throws -> String? {
        guard available(installed: installed, expected: nil, previous: previous) != nil else {
            throw ChangeFailure(String(localized: "There's no earlier Tiri to go back to."))
        }
        let failed = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        // Only what whoever made this one signed: an agent can write in the updates folder.
        try UpdateTools.checkSignature(previous, against: installed)
        try CopyFiles.swap(previous, installed)
        if var state = CopyState.load() {
            state.plainVersion = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            state.rolledBack = failed
            try? state.save()
        }
        LaunchRecord().save()
        return failed
    }

    /// A release that was gone back from sits where an earlier one would. Removed once the earlier one is running.
    public static func tidy(running version: String, previous: URL = UpdateRollback.previous) {
        guard let info = NSDictionary(contentsOf: previous.appendingPathComponent("Contents/Info.plist")),
              let kept = info["CFBundleShortVersionString"] as? String,
              UpdateTools.isNewer(kept, than: version) else { return }
        try? FileManager.default.removeItem(at: previous)
    }
}
