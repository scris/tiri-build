import Foundation

/// Your Tiri: the copies of this app that someone's own agent made for them, and which one runs.
///
/// The app they installed is never touched. It stays where it is, signed as it was, as Plain Tiri. A personal
/// copy sits beside it under its own bundle ID, because macOS keeps folder permissions per bundle ID: sharing
/// one would ask again on every move between the two, and a personal build replacing a notarized bundle would
/// also meet macOS's App Management protection. So going back never needs anything from a build that may be broken.
public enum YourTiri {
    public static var root: URL { TiriPaths.supportDirectory.appendingPathComponent("your-tiri", isDirectory: true) }
    public static var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    public static var copies: URL { root.appendingPathComponent("copies", isDirectory: true) }
    /// Stable paths, because a running terminal has `current`'s `bin` on its PATH for as long as it lives.
    public static var current: URL { copies.appendingPathComponent("current/Tiri.app", isDirectory: true) }
    public static var previous: URL { copies.appendingPathComponent("previous/Tiri.app", isDirectory: true) }
    public static var ready: URL { copies.appendingPathComponent("ready/Tiri.app", isDirectory: true) }
    public static var readyNote: URL { copies.appendingPathComponent("ready/ready.json") }
    public static var building: URL { copies.appendingPathComponent("building", isDirectory: true) }
    /// A copy someone went back from, with nothing before it. Never run again, and replaced by the next one.
    public static var rejected: URL { copies.appendingPathComponent("rejected/Tiri.app", isDirectory: true) }
    public static var identity: URL { root.appendingPathComponent("identity", isDirectory: true) }
    public static var draftFile: URL { root.appendingPathComponent("draft.json") }
    public static var stateFile: URL { root.appendingPathComponent("state.json") }
    public static var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }
    public static var updates: URL { root.appendingPathComponent("updates", isDirectory: true) }
    public static var testCopies: URL { root.appendingPathComponent("test-copy", isDirectory: true) }

    /// What marks a build as a personal copy, in its Info.plist.
    public static let copyKey = "TiriCopy"
    public static let commitKey = "TiriSourceCommit"
    public static let releaseKey = "TiriReleaseCommit"
    public static let sourceArchive = "source.tar.gz"

    public static func personalBundleID(plain: String) -> String { plain + ".personal" }

    /// A trial can be undone for this long, and after that it's simply what you use.
    public static let trialLength: TimeInterval = 600
    /// Stays up this long and it counts as having started.
    public static let healthyAfter: TimeInterval = 10
}

/// Which copy runs, read at the very start of every launch once someone has made a change.
/// Nobody else has this file, and for them a launch costs one failed open.
public struct CopyState: Codable, Equatable, Sendable {
    public enum Active: String, Codable, Sendable { case plain, personal }

    public struct Trial: Codable, Equatable, Sendable {
        public var sentence: String
        public var change: String?
        public var item: String?
        public var startedAt: Date
        /// What Back goes to.
        public var previous: Active
        public var hasPreviousCopy: Bool
        public var firstPersonal: Bool
        /// A copy built by turning a change on or off is undone the other way round.
        public var wasTurnedOff = false

        public init(sentence: String, change: String?, item: String?, startedAt: Date, previous: Active, hasPreviousCopy: Bool, firstPersonal: Bool) {
            self.sentence = sentence
            self.change = change
            self.item = item
            self.startedAt = startedAt
            self.previous = previous
            self.hasPreviousCopy = hasPreviousCopy
            self.firstPersonal = firstPersonal
        }

        public func hasExpired(now: Date) -> Bool { now.timeIntervalSince(startedAt) > YourTiri.trialLength }
    }

    public var active: Active = .plain
    public var plainPath: String?
    public var plainBundleID: String?
    public var plainVersion: String?
    public var trial: Trial?
    /// Launches of the personal copy since one last stayed up.
    public var attempts = 0
    public var lastAttempt: Date?
    /// Said once, by whichever copy next has a window.
    public var notice: String?
    /// The change that kept a copy from starting. It's turned off the next time a copy has its window,
    /// or else the next copy built would have it too.
    public var rejectedChange: String?
    /// Asked once, the first time an update has something to mend. Nil until then.
    public var repairsAllowed: Bool?

    public init() {}

    public static func load(from file: URL = YourTiri.stateFile) -> CopyState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(CopyState.self, from: data)
    }

    public func save(to file: URL = YourTiri.stateFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Two early deaths are enough to say it isn't going to work.
    public var isCrashLooping: Bool { attempts >= 2 }

    /// Back to what ran before, with nothing asked of the broken copy.
    public mutating func fallBack(fileManager: FileManager = .default, current: URL = YourTiri.current, previous: URL = YourTiri.previous) {
        let sentence = trial?.sentence
        let back = trial?.previous ?? .plain
        let usesPrevious = back == .personal && (trial?.hasPreviousCopy ?? false) && fileManager.fileExists(atPath: previous.path)
        if usesPrevious, (try? CopyFiles.swap(current, previous)) != nil {
            active = .personal
        } else {
            active = .plain
        }
        rejectedChange = trial?.change
        let what = sentence.map { "“\($0)”" } ?? "Your latest change"
        notice = "\(what) kept Tiri from starting, so Tiri went back. Nothing is lost."
        trial = nil
        attempts = 0
        lastAttempt = nil
    }
}

/// What to do in the first moments of a launch. Pure, so every path can be tried without launching anything.
public enum LaunchChoice: Equatable, Sendable {
    /// Be the app.
    case runHere
    case openPersonal
    /// A personal copy that shouldn't be running: hand over to the app people installed.
    case openPlain
    /// The personal copy keeps dying. Go back, then look again.
    case fallBack
    /// It's meant to run and it isn't there.
    case personalMissing
}

public enum LaunchGate {
    public struct Input: Equatable, Sendable {
        public var state: CopyState?
        public var isPersonalCopy: Bool
        public var optionHeld: Bool
        public var plainOnce: Bool
        public var personalExists: Bool

        public init(state: CopyState?, isPersonalCopy: Bool, optionHeld: Bool, plainOnce: Bool, personalExists: Bool) {
            self.state = state
            self.isPersonalCopy = isPersonalCopy
            self.optionHeld = optionHeld
            self.plainOnce = plainOnce
            self.personalExists = personalExists
        }
    }

    public static func choose(_ input: Input) -> LaunchChoice {
        guard let state = input.state else {
            return input.isPersonalCopy ? .openPlain : .runHere
        }
        if input.isPersonalCopy {
            return input.optionHeld || state.active == .plain ? .openPlain : .runHere
        }
        if input.optionHeld || input.plainOnce || state.active == .plain { return .runHere }
        guard input.personalExists else { return .personalMissing }
        return state.isCrashLooping ? .fallBack : .openPersonal
    }
}

/// Moving whole app bundles around, each step atomic on one volume.
public enum CopyFiles {
    public struct MoveFailure: Error, CustomStringConvertible {
        public var description: String
    }

    public static func swap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { a in second.path.withCString { b in renamex_np(a, b, UInt32(RENAME_SWAP)) } }
        if result != 0 { throw MoveFailure(description: "Couldn't swap \(first.lastPathComponent): \(String(cString: strerror(errno)))") }
    }

    /// `to` is replaced if it's there.
    public static func move(_ from: URL, to: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: to.path) {
            try swap(from, to)
            try manager.removeItem(at: from)
        } else {
            try manager.moveItem(at: from, to: to)
        }
    }

    /// `ready` becomes `current`, and what was `current` becomes `previous`. Whichever copy is running keeps
    /// running: it's only the name of its folder that changes. Says whether there's a previous copy now.
    @discardableResult
    public static func promoteReady(ready: URL = YourTiri.ready, current: URL = YourTiri.current, previous: URL = YourTiri.previous) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: ready.appendingPathComponent("Contents/MacOS/Tiri").path) else {
            throw MoveFailure(description: "There's no copy ready to try.")
        }
        guard manager.fileExists(atPath: current.path) else {
            try move(ready, to: current)
            return false
        }
        try swap(ready, current)
        // What's in `ready` now is what ran before.
        try move(ready, to: previous)
        return true
    }
}

/// Apple's tools are what builds Tiri. `xcode-select -p` only reads a setting, where running `swift` itself
/// would put up Apple's installer on a Mac without them.
public enum SwiftTools {
    public static func areHere(developerDirectory: String? = nil) -> Bool {
        let found = developerDirectory ?? Tool.run("/usr/bin/xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !found.isEmpty else { return false }
        // The Command Line Tools keep it in `usr/bin`, and Xcode keeps it in its toolchain.
        return ["/usr/bin/swift", "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"].contains {
            FileManager.default.isExecutableFile(atPath: found + $0)
        }
    }
}

/// A program run to the end, for the parts of this that are made of other programs.
public enum Tool {
    public struct Result: Sendable {
        public var code: Int32
        public var output: String
        public var ok: Bool { code == 0 }
    }

    /// Output is mixed, and also shown as it comes when `echo` is on, because a build's progress is the point of it.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:], echo: Bool = false) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Result(code: 127, output: "Couldn't run \(tool).") }
        var collected = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
            if echo { fputs(String(decoding: chunk, as: UTF8.self), stdout); fflush(stdout) }
        }
        process.waitUntilExit()
        return Result(code: process.terminationStatus, output: String(decoding: collected, as: UTF8.self))
    }

    /// `swift` is wherever the person's agent found it, so it's looked up rather than assumed.
    public static func shell(_ script: String, in directory: URL? = nil, environment: [String: String] = [:], echo: Bool = false) -> Result {
        run("/bin/bash", ["-c", script], in: directory, environment: environment, echo: echo)
    }
}
