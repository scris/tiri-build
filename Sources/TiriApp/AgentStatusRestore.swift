import Foundation
import TiriCore

/// An agent's status lives only in this Tiri's memory, and comes from its hooks. A Tiri that comes back to an agent
/// that kept running through a quit, a crash or Try It would call it idle until its next hook, so what each one last
/// said is kept on disk (`AgentStatusRecords`) and brought back with its tab.
extension TerminalRuntime {
    /// Since when it's been working, carried along while it still is.
    mutating func keepWorkingSince(from before: TerminalRuntime?) {
        if status != .working {
            workingSince = nil
        } else if workingSince == nil {
            workingSince = before?.status == .working ? (before?.workingSince ?? Date()) : Date()
        }
    }
}

extension AppModel {
    /// After any change to a terminal's status, for one whose agent reports through hooks. A guess from a screen
    /// isn't kept: it's guessed again, and one kept could say working for good.
    func keepStatusRecord(_ id: ItemID, was before: TerminalRuntime?) {
        guard let runtime = runtimes[id], runtime.status != before?.status || runtime.message != before?.message
                || runtime.unseen != before?.unseen || runtime.workingSince != before?.workingSince else { return }
        if runtime.status == .exited {
            AgentStatusRecords.remove(id)
            return
        }
        guard let terminal = existingController(for: id) as? TerminalController, terminal.reportsByHooks, !terminal.isOnServer else { return }
        AgentStatusRecords.write(AgentStatusRecord(state: runtime.status.rawValue, message: runtime.message, at: Date().timeIntervalSince1970,
                                                   since: runtime.workingSince?.timeIntervalSince1970, unseen: runtime.unseen), for: id)
    }

    /// Each terminal whose program is still running comes back saying what its agent last said, whether Tiri heard
    /// it or `tiri hook` kept it while Tiri was gone. `finished` is the last pass at launch, which also drops records
    /// of tabs that aren't there any more.
    func restoreAgentStatus(finished: Bool) {
        let keepsRunning = settings.terminalKeepRunning || keepTerminalsThroughQuit
        for id in AgentStatusRecords.all() where runtimes[id] == nil {
            guard let item = anyItem(id) else {
                if finished { AgentStatusRecords.remove(id) }
                continue
            }
            guard case .terminal = item.content, workspace(containing: id)?.remote == nil, keepsRunning,
                  let record = AgentStatusRecords.read(id), TerminalSessions.isAlive(id) else {
                // Its program ended, so whatever comes up in its place starts again.
                AgentStatusRecords.remove(id)
                continue
            }
            guard let shown = AgentStatusRecords.restored(record), let status = TerminalStatus(rawValue: shown.state) else { continue }
            updateRuntime(id) { runtime in
                runtime.status = status
                runtime.message = shown.message
                runtime.unseen = shown.unseen
                runtime.workingSince = shown.since
            }
            // Its hooks are what's been speaking, and the checks on them apply: one that's gone quiet isn't working.
            if let terminal = existingController(for: id) as? TerminalController {
                terminal.noteHookReport(status: status)
            } else {
                restoredAgentStatus.insert(id)
            }
        }
        updateDockBadge()
    }

    /// A terminal made after its status came back.
    func adoptRestoredStatus(_ terminal: TerminalController, id: ItemID) {
        guard restoredAgentStatus.remove(id) != nil, let status = runtimes[id]?.status else { return }
        terminal.noteHookReport(status: status)
    }
}
