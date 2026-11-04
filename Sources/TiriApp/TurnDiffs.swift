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
        // Two hooks can report one event: an agent's own, and another's it also runs.
        if let last = turns.last(where: { $0.item == item }), last.isOpen, Date().timeIntervalSince(last.started) < 3 { return }
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
        if let last = turns.last(where: { $0.item == item }), let ended = last.ended, Date().timeIntervalSince(ended) < 3 { return }
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

    /// How many rows the Changes section is listing, whatever they are.
    var visibleChangesCount: Int {
        if case .recentCommits = changesScope { return recentCommits.count }
        return visibleChanges.count
    }

    /// What a diff opened from the list should show.
    func diffSpecForScope(path: String) -> DiffSpec {
        switch changesScope {
        case .branch: DiffSpec(path: path, branch: true)
        case .commit(let commit): DiffSpec(path: path, commit: commit.oid)
        default: DiffSpec(path: path, turn: scopedTurn?.id)
        }
    }

    var emptyChangesText: String {
        switch changesScope {
        case .sinceCommit: "No changes since the last commit."
        case .latestTurn, .turn: "This turn didn't change any files."
        case .branch: branchBases.count == 1 ? branchBases[0].emptyDescription : "Nothing changed."
        case .recentCommits: "No commits yet."
        case .commit: "This commit didn't change any files here."
        }
    }

    func setChangesScope(_ scope: ChangesScope) {
        changesScope = scope
        turnChanges = []
        branchBases = []
        scopeIsLoading = true
        refreshScopedChanges()
    }

    /// Looked at along with everything else that compares against the files. A commit doesn't
    /// change, so once is enough. The list of commits can, and a branch's files can too.
    func refreshScopedChanges() {
        let scope = changesScope
        if scope == .sinceCommit {
            scopeIsLoading = false
            if !turnChanges.isEmpty { turnChanges = [] }
            return
        }
        if case .commit = scope, !scopeIsLoading { return }
        let turn = scopedTurn
        switch scope {
        case .latestTurn, .turn:
            guard turn == nil else { break }
            scopeIsLoading = false
            if !turnChanges.isEmpty { turnChanges = [] }
            return
        default:
            break
        }
        guard !turnChangesInFlight else { return }
        turnChangesInFlight = true
        let snapshots = self.snapshots
        let folders = active.folders
        Task.detached(priority: .userInitiated) { [weak self] in
            var files: [ChangedFile] = []
            var bases: [BranchBase] = []
            var commits: [CommitSummary] = []
            switch scope {
            case .sinceCommit: break
            case .latestTurn, .turn: if let turn { files = snapshots.changes(in: turn, folders: folders) }
            case .branch: (bases, files) = Git.branchChanges(in: folders)
            case .recentCommits: commits = Git.recentCommits(in: folders)
            case .commit(let commit): files = Git.commitChanges(commit.oid, root: commit.root, in: folders)
            }
            await MainActor.run {
                guard let self else { return }
                self.turnChangesInFlight = false
                // Someone chose something else while this was looking.
                guard self.changesScope == scope else {
                    self.refreshScopedChanges()
                    return
                }
                self.scopeIsLoading = false
                if self.turnChanges != files { self.turnChanges = files }
                if self.branchBases != bases { self.branchBases = bases }
                if self.recentCommits != commits, case .recentCommits = scope { self.recentCommits = commits }
            }
        }
    }

    /// Whether what's in front has changes to go through.
    var canGoToChange: Bool {
        guard let item = active.peek ?? active.activeItem else { return false }
        if case .diff = item.content { return true }
        return false
    }

    /// F7 and ⇧F7.
    func goToChange(forward: Bool) {
        guard let item = active.peek ?? active.activeItem else { return }
        (existingController(for: item.id) as? DiffController)?.goToChange(forward: forward)
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

/// Choose what Changes shows: everything since the last commit, this branch, a commit or one agent's turn.
struct ChangesScopeMenu: View {
    @Environment(AppModel.self) private var model

    private var label: String {
        switch model.changesScope {
        case .sinceCommit: "Since commit"
        case .latestTurn: "Latest turn"
        case .turn: "One turn"
        case .branch: "This branch"
        case .recentCommits: "Recent commits"
        case .commit(let commit): commit.shortOID
        }
    }

    var body: some View {
        Menu {
            scopeButton("Since Last Commit", .sinceCommit)
            scopeButton("This Branch", .branch)
            scopeButton("Recent Commits", .recentCommits)
            let offered = model.offeredTurns
            if !offered.isEmpty || model.changesScope == .latestTurn {
                scopeButton("Latest Turn", .latestTurn)
            }
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
        .help("Show everything since the last commit, this branch, one commit, or what one agent's turn changed")
    }

    private func scopeButton(_ title: String, _ scope: ChangesScope) -> some View {
        Toggle(title, isOn: Binding(get: { model.changesScope == scope }, set: { _ in model.setChangesScope(scope) }))
    }
}

/// What the list is compared with, when it's a branch.
struct BranchCaption: View {
    let bases: [BranchBase]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bases, id: \.root) { base in
                Text(bases.count > 1 ? (base.root as NSString).lastPathComponent + ": " + base.description : base.description)
                    .lineLimit(2)
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

/// Which commit the list is showing, with a way back to the others.
struct CommitCaption: View {
    let commit: CommitSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                model.setChangesScope(.recentCommits)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Recent Commits")
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([commit.shortOID, RelativeTime.text(commit.date)] + (commit.isMerge ? ["compared with its first parent"] : [])).joined(separator: " · "))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
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
