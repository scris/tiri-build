import Foundation

/// What an agent in a terminal last said about itself, kept beside Tiri's state. A Tiri that comes back to an agent
/// still running, after a quit, a crash or Try It, shows what it's doing from its first frame, rather than calling it
/// idle until it speaks again. Tiri writes one whenever a terminal whose agent reports through hooks changes status,
/// and `tiri hook` writes one when no Tiri is there to hear it, so an agent that finished or started waiting for you
/// in between isn't still called working.
public struct AgentStatusRecord: Codable, Equatable, Sendable {
    /// working, needs-input, done or idle.
    public var state: String
    public var message: String?
    /// When it was said, in seconds since 1970.
    public var at: Double
    /// When it started working, while it is.
    public var since: Double?
    /// Said while nobody was looking, and not looked at since.
    public var unseen: Bool
    /// False when `tiri hook` wrote it, because no Tiri was there.
    public var heard: Bool

    public init(state: String, message: String? = nil, at: Double, since: Double? = nil, unseen: Bool = false, heard: Bool = true) {
        self.state = state
        self.message = message
        self.at = at
        self.since = since
        self.unseen = unseen
        self.heard = heard
    }
}

public enum AgentStatusRecords {
    public static var directory: URL { TiriPaths.supportDirectory.appendingPathComponent("agent-status", isDirectory: true) }

    private static func url(_ item: String, _ folder: URL) -> URL { folder.appendingPathComponent(item + ".json") }

    /// Only Tiri's own ids make file names here.
    private static func isPlain(_ item: String) -> Bool {
        !item.isEmpty && item.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whole or not at all: a crash halfway leaves the one before.
    public static func write(_ record: AgentStatusRecord, for item: String, in folder: URL = directory) {
        guard isPlain(item), let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url(item, folder), options: .atomic)
    }

    public static func read(_ item: String, in folder: URL = directory) -> AgentStatusRecord? {
        guard isPlain(item), let data = try? Data(contentsOf: url(item, folder)) else { return nil }
        return try? JSONDecoder().decode(AgentStatusRecord.self, from: data)
    }

    public static func remove(_ item: String, in folder: URL = directory) {
        guard isPlain(item) else { return }
        try? FileManager.default.removeItem(at: url(item, folder))
    }

    /// Every terminal with a record.
    public static func all(in folder: URL = directory) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// What `tiri hook` or `tiri notify` keeps when Tiri can't be reached. Nothing, for a report that doesn't
    /// change what the agent is doing.
    public static func missed(state: String?, message: String?, previous: AgentStatusRecord?, now: Date = Date()) -> AgentStatusRecord? {
        guard let state, ["working", "needs-input", "done", "idle"].contains(state) else { return nil }
        let at = now.timeIntervalSince1970
        var since: Double?
        if state == "working" { since = previous?.state == "working" ? (previous?.since ?? previous?.at ?? at) : at }
        // Working again, the message from before stays, as it does in Tiri.
        let kept = state == previous?.state ? previous?.message : nil
        return AgentStatusRecord(state: state, message: message ?? kept, at: at, since: since,
                                 unseen: state == "needs-input" || state == "done", heard: false)
    }

    /// The same, from the request `tiri` couldn't deliver. Only a terminal's status report counts.
    public static func keepMissed(_ request: ControlRequest, in folder: URL = directory, now: Date = Date()) {
        guard request.cmd == "notify", let item = request.args["item"]?.stringValue else { return }
        let previous = read(item, in: folder)
        guard let record = missed(state: request.args["state"]?.stringValue, message: request.args["message"]?.stringValue,
                                  previous: previous, now: now) else { return }
        write(record, for: item, in: folder)
    }

    /// What a terminal whose program kept running comes back showing. Nothing: it's idle, as it would be anyway.
    public static func restored(_ record: AgentStatusRecord) -> (state: String, message: String?, since: Date?, unseen: Bool)? {
        switch record.state {
        case "working":
            return ("working", record.message, Date(timeIntervalSince1970: record.since ?? record.at), false)
        case "needs-input":
            return ("needs-input", record.message, nil, record.unseen)
        case "done":
            // Finished and already seen is just idle.
            return record.unseen ? ("done", record.message, nil, true) : nil
        default:
            return nil
        }
    }
}
