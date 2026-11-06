import Foundation
import TiriCore

extension AppModel {
    /// Snapshots written since the last prune past this, and the store is pruned when a turn ends.
    nonisolated static let looseSnapshotBudget = 64 * 1024 * 1024

    /// Old turns go, and once any have, or the store has grown, so do the copies only they needed.
    func trimTurns(roots: [String]) {
        let before = turns.count
        turns = turns.trimmed()
        pruneSnapshots(roots: Set(roots), always: turns.count < before)
    }

    /// Each root's store keeps what the turns still name. Away from the main thread, one root at a time.
    func pruneSnapshots(roots: Set<String>? = nil, always: Bool = true) {
        var keep: [String: Set<String>] = [:]
        for turn in turns {
            for (root, tree) in turn.startTrees { keep[root, default: []].insert(tree) }
            for (root, tree) in turn.endTrees { keep[root, default: []].insert(tree) }
        }
        let wanted = roots ?? Set(keep.keys)
        let snapshots = self.snapshots
        Task.detached(priority: .background) {
            for root in wanted.sorted() {
                guard always || snapshots.looseSize(root: root) > AppModel.looseSnapshotBudget else { continue }
                snapshots.prune(root: root, keeping: keep[root] ?? [])
            }
        }
    }
}
