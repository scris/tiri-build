import Foundation
import Testing
@testable import TiriCore

@Suite struct AgentStatusRecordsTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agent-status-\(UUID().uuidString)", isDirectory: true)
    }

    private func notify(_ item: String, _ state: String?, message: String? = nil) -> ControlRequest {
        var args: [String: JSONValue] = ["item": .string(item), "tool": "claude", "hook": true]
        if let state { args["state"] = .string(state) }
        if let message { args["message"] = .string(message) }
        return ControlRequest(cmd: "notify", args: args)
    }

    @Test func keepsReadsAndDrops() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = AgentStatusRecord(state: "working", at: 100, since: 90)
        AgentStatusRecords.write(record, for: "i-abc", in: folder)
        #expect(AgentStatusRecords.read("i-abc", in: folder) == record)
        #expect(AgentStatusRecords.all(in: folder) == ["i-abc"])
        AgentStatusRecords.remove("i-abc", in: folder)
        #expect(AgentStatusRecords.read("i-abc", in: folder) == nil)
        AgentStatusRecords.write(record, for: "../escape", in: folder)
        #expect(AgentStatusRecords.all(in: folder).isEmpty)
    }

    /// Still working when Tiri comes back: working, since it started, however long Tiri was gone.
    @Test func workingComesBackWorkingSinceItStarted() throws {
        let shown = try #require(AgentStatusRecords.restored(AgentStatusRecord(state: "working", at: 500, since: 420)))
        #expect(shown.state == "working")
        #expect(shown.since == Date(timeIntervalSince1970: 420))
        #expect(!shown.unseen)
    }

    /// What `tiri hook` keeps while no Tiri is there: the last thing the agent said, and when its work began.
    @Test func whatTheHookKeepsWhileTiriIsGone() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        AgentStatusRecords.write(AgentStatusRecord(state: "working", at: 100, since: 60), for: "i-a", in: folder)
        // More work: it's still the same stretch of it.
        AgentStatusRecords.keepMissed(notify("i-a", "working"), in: folder, now: Date(timeIntervalSince1970: 200))
        let still = try #require(AgentStatusRecords.read("i-a", in: folder))
        #expect(still.since == 60)
        #expect(!still.heard)
        // Something that doesn't say what it's doing changes nothing.
        AgentStatusRecords.keepMissed(notify("i-a", nil), in: folder, now: Date(timeIntervalSince1970: 250))
        #expect(AgentStatusRecords.read("i-a", in: folder) == still)
        // It finished: that's what comes back, and nobody has seen it.
        AgentStatusRecords.keepMissed(notify("i-a", "done", message: "Storefront built"), in: folder, now: Date(timeIntervalSince1970: 300))
        let finished = try #require(AgentStatusRecords.read("i-a", in: folder))
        let done = try #require(AgentStatusRecords.restored(finished))
        #expect(done.state == "done")
        #expect(done.message == "Storefront built")
        #expect(done.unseen)
        // A new turn starts its clock again.
        AgentStatusRecords.keepMissed(notify("i-a", "working"), in: folder, now: Date(timeIntervalSince1970: 400))
        #expect(AgentStatusRecords.read("i-a", in: folder)?.since == 400)
        // Waiting for you isn't working.
        AgentStatusRecords.keepMissed(notify("i-a", "needs-input", message: "Wants to use Bash"), in: folder, now: Date(timeIntervalSince1970: 450))
        let asked = try #require(AgentStatusRecords.read("i-a", in: folder))
        let waiting = try #require(AgentStatusRecords.restored(asked))
        #expect(waiting.state == "needs-input")
        #expect(waiting.since == nil)
        #expect(waiting.unseen)
        // Only a terminal's status report is kept.
        AgentStatusRecords.keepMissed(ControlRequest(cmd: "open", args: ["item": "i-b", "state": "working"]), in: folder)
        #expect(AgentStatusRecords.read("i-b", in: folder) == nil)
    }

    /// Idle, or finished and already looked at, is how any terminal comes back anyway.
    @Test func nothingToBringBackForIdle() {
        #expect(AgentStatusRecords.restored(AgentStatusRecord(state: "idle", at: 1)) == nil)
        #expect(AgentStatusRecords.restored(AgentStatusRecord(state: "done", at: 1, unseen: false)) == nil)
        #expect(AgentStatusRecords.restored(AgentStatusRecord(state: "exited", at: 1)) == nil)
    }
}
