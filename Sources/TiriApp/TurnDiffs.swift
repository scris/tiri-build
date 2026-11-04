import AppKit
import SwiftUI
import TiriCore

extension AppModel {
    func loadTurns() {
        turns = turnStore.load().trimmed()
        // A terminal that's gone can't finish its turn, and nothing says what it had changed by then.
        let items = Set(workspaces.flatMap { $0.items.map(\.id) })
        for index in turns.indices where turns[index].isOpen && !items.contains(turns[index].item) {
            turns[index].ended = Date()
            turns[index].endTrees = turns[index].startTrees
        }
        let snapshots = self.snapshots
        let needed = Set(turns.flatMap { Array($0.startTrees.keys) })
        Task.detached(priority: .background) { snapshots.removeStores(except: needed) }
    }

    private func saveTurns() {
        turnStore.save(turns)
    }

    /// The repositories a turn could touch: where the terminal is, and its workspace's folders.
    private func turnRoots(for item: ItemID) -> (workspace: Workspace, folders: [String])? {
        guard let workspace = workspace(containing: item) else { return nil }
        var folders = workspace.folders
        if let cwd = (existingController(for: item) as? TerminalController)?.currentDirectory { folders.append(cwd) }
        return (workspace, folders)
    }

    /// An agent took a prompt. What's there now is what the turn starts from.
    func turnStarted(item: ItemID, prompt: String?) {
        guard settings.perTurnDiffs, let (workspace, folders) = turnRoots(for: item), let source = anyItem(item) else { return }
        let turn = AgentTurn(workspace: workspace.id, item: item, title: title(for: source), prompt: AgentTurn.shortPrompt(prompt))
        let previous = turns.last { $0.item == item && $0.isOpen }?.id
        turns.append(turn)
        let snapshots = self.snapshots
        Task.detached(priority: .userInitiated) { [weak self] in
            let roots = folders.compactMap(Git.repositoryRoot(of:))
            let trees = snapshots.snapshotAll(roots: roots)
            await MainActor.run {
                guard let self else { return }
                if let index = self.turns.firstIndex(where: { $0.id == turn.id }) { self.turns[index].startTrees = trees }
                // Interrupting doesn't tell anyone. The turn before really ended when this one began.
                if let index = self.turns.firstIndex(where: { $0.id == previous && $0.isOpen }) {
                    self.turns[index].ended = Date()
                    self.turns[index].endTrees = trees
                }
                self.turns = self.turns.trimmed()
                self.saveTurns()
                self.refreshChanges()
            }
        }
    }

    /// An agent stopped. With no turn open, like Codex's first, this at least gives the next one
    /// something to start from, and a later one starts where the last ended.
    func turnEnded(item: ItemID) {
        guard settings.perTurnDiffs, let (workspace, folders) = turnRoots(for: item), let source = anyItem(item) else { return }
        let snapshots = self.snapshots
        let open = turns.last { $0.item == item && $0.isOpen }?.id
        let last = turns.last { $0.item == item && !$0.isOpen }
        let name = title(for: source)
        Task.detached(priority: .userInitiated) { [weak self] in
            let roots = folders.compactMap(Git.repositoryRoot(of:))
            let trees = snapshots.snapshotAll(roots: roots)
            await MainActor.run {
                guard let self else { return }
                if let open, let index = self.turns.firstIndex(where: { $0.id == open }) {
                    self.turns[index].ended = Date()
                    self.turns[index].endTrees = trees
                } else {
                    self.turns.append(AgentTurn(workspace: workspace.id, item: item, title: name, started: last?.ended ?? Date(), ended: Date(),
                                                startTrees: last?.endTrees ?? trees, endTrees: trees))
                }
                self.turns = self.turns.trimmed()
                self.saveTurns()
                self.refreshChanges()
            }
        }
    }

    /// The turn the sidebar is showing, if it's showing one.
    var scopedTurn: AgentTurn? {
        turns.resolving(changesScope, in: activeID)
    }

    var visibleChanges: [ChangedFile] {
        changesScope == .sinceCommit ? changes : turnChanges
    }

    func setChangesScope(_ scope: ChangesScope) {
        changesScope = scope
        turnChanges = []
        refreshChanges()
    }

    /// Looked at along with everything else that compares against the files.
    func refreshTurnChanges() {
        guard let turn = scopedTurn else {
            if !turnChanges.isEmpty { turnChanges = [] }
            return
        }
        guard !turnChangesInFlight else { return }
        turnChangesInFlight = true
        let snapshots = self.snapshots
        let folders = active.folders
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = snapshots.changes(in: turn, folders: folders)
            await MainActor.run {
                guard let self else { return }
                self.turnChangesInFlight = false
                if self.scopedTurn?.id == turn.id, self.turnChanges != found { self.turnChanges = found }
            }
        }
    }

    /// Turns from this workspace worth offering, newest first, a few for each terminal.
    var offeredTurns: [AgentTurn] {
        var seen: [ItemID: Int] = [:]
        return turns.reversed().filter { turn in
            guard turn.workspace == activeID, !turn.changedNothing else { return false }
            seen[turn.item, default: 0] += 1
            return seen[turn.item]! <= 5
        }
    }

    func turnOverlaps(_ turn: AgentTurn) -> Bool {
        turns.contains { turn.overlaps($0) }
    }

    /// For a diff tab of a turn that may have aged away.
    func turn(id: String) -> AgentTurn? {
        turns.first { $0.id == id }
    }

    static func describe(_ turn: AgentTurn) -> String {
        turn.prompt.map { "“\($0)”" } ?? turn.title
    }
}

/// Choose between everything since the last commit and one agent's turn.
struct ChangesScopeMenu: View {
    @Environment(AppModel.self) private var model

    private var label: String {
        switch model.changesScope {
        case .sinceCommit: "Since commit"
        case .latestTurn: "Latest turn"
        case .turn: "One turn"
        }
    }

    var body: some View {
        Menu {
            scopeButton("Since Last Commit", .sinceCommit)
            scopeButton("Latest Turn", .latestTurn)
            let offered = model.offeredTurns
            if !offered.isEmpty {
                Divider()
                ForEach(offered) { turn in
                    scopeButton(AppModel.describe(turn) + (turn.isOpen ? " (working)" : ""), .turn(turn.id))
                }
            }
        } label: {
            Text(label)
                .font(.system(size: 10.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show everything since the last commit, or what one agent's turn changed")
    }

    private func scopeButton(_ title: String, _ scope: ChangesScope) -> some View {
        Button {
            model.setChangesScope(scope)
        } label: {
            if model.changesScope == scope {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// What the list is showing, when that's one turn.
struct TurnCaption: View {
    let turn: AgentTurn
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppModel.describe(turn))
                .lineLimit(1)
                .truncationMode(.tail)
            if model.turnOverlaps(turn) {
                Label("Another agent worked here at the same time, so this may include its edits.", systemImage: "person.2")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 3)
    }
}
