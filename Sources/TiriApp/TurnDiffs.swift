import AppKit
import SwiftUI
import TiriCore

extension AppModel {
    func loadTurns() {
        let stored = turnStore.load()
        turns = stored.trimmed()
        // A terminal that's gone can't finish its turn, and nothing says what it had changed by then.
        let items = Set(workspaces.flatMap { $0.items.map(\.id) })
        for index in turns.indices where turns[index].isOpen && !items.contains(turns[index].item) {
            turns[index].ended = Date()
            turns[index].endTrees = turns[index].startTrees
        }
        let snapshots = self.snapshots
        let needed = Set(turns.flatMap { Array($0.startTrees.keys) })
        Task.detached(priority: .background) { snapshots.removeStores(except: needed) }
        pruneSnapshots(always: turns.count < stored.count)
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
        let turn = AgentTurn(workspace: workspace.id, item: item, title: englishTitle(for: source), prompt: AgentTurn.shortPrompt(prompt))
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
                self.trimTurns(roots: roots)
                self.saveTurns()
                self.refreshChanges(workspace.id)
            }
        }
    }

    /// An agent appeared in a terminal. What's there now is where its first turn starts, if its hooks
    /// never say when a turn begins: Codex's `notify`, or its hooks before they're trusted.
    func agentAppeared(item: ItemID) {
        // Later turns start where the one before ended, so only a terminal's first needs this.
        guard settings.perTurnDiffs, !turns.contains(where: { $0.item == item }), let (_, folders) = turnRoots(for: item) else { return }
        let started = Date()
        let snapshots = self.snapshots
        Task.detached(priority: .utility) { [weak self] in
            let trees = snapshots.snapshotAll(roots: folders.compactMap(Git.repositoryRoot(of:)))
            await MainActor.run { self?.turnBaselines[item] = (started, trees) }
        }
    }

    /// An agent stopped. With no turn open, a turn starts where the last one ended, or where the
    /// agent appeared if that's later, as for Codex's first.
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
                    var started = last?.ended ?? Date()
                    var startTrees = last?.endTrees ?? trees
                    if let baseline = self.turnBaselines.removeValue(forKey: item), last?.ended.map({ baseline.started > $0 }) ?? true {
                        started = baseline.started
                        startTrees = baseline.trees
                    }
                    self.turns.append(AgentTurn(workspace: workspace.id, item: item, title: name, started: started, ended: Date(),
                                                startTrees: startTrees, endTrees: trees))
                }
                self.trimTurns(roots: roots)
                self.saveTurns()
                self.refreshChanges(workspace.id)
            }
        }
    }

    /// The turn the sidebar is showing, if it's showing one.
    var scopedTurn: AgentTurn? { scopedTurn(in: activeID) }

    func scopedTurn(in id: WorkspaceID) -> AgentTurn? {
        turns.resolving(lives[id]?.changesScope ?? .sinceCommit, in: id)
    }

    var visibleChanges: [ChangedFile] { visibleChanges(in: activeID) }

    func visibleChanges(in id: WorkspaceID) -> [ChangedFile] {
        guard let live = lives[id] else { return [] }
        return live.changesScope == .sinceCommit ? live.changes : live.turnChanges
    }

    /// How many rows the Changes section is listing, whatever they are.
    var visibleChangesCount: Int { visibleChangesCount(in: activeID) }

    func visibleChangesCount(in id: WorkspaceID) -> Int {
        guard let live = lives[id] else { return 0 }
        if case .recentCommits = live.changesScope { return live.recentCommits.count }
        if case .otherWork = live.changesScope { return live.otherWork.count }
        return visibleChanges(in: id).count
    }

    /// What a diff opened from the list should show.
    func diffSpecForScope(path: String) -> DiffSpec {
        switch changesScope {
        case .branch: DiffSpec(path: path, branch: true)
        case .commit(let commit): DiffSpec(path: path, commit: commit.oid)
        case .work(let work): work.worktree != nil ? DiffSpec(path: path, branch: true) : {
            var spec = DiffSpec(path: path)
            spec.range = [work.from, work.tip]
            return spec
        }()
        default: DiffSpec(path: path, turn: scopedTurn?.id)
        }
    }

    var emptyChangesText: String { emptyChangesText(in: activeID) }

    func emptyChangesText(in id: WorkspaceID) -> String {
        let bases = lives[id]?.branchBases ?? []
        return switch lives[id]?.changesScope ?? .sinceCommit {
        case .sinceCommit: String(localized: "No changes since the last commit.")
        case .latestTurn, .turn: String(localized: "This turn didn't change any files.")
        case .branch: bases.count == 1 ? bases[0].emptyDescription : String(localized: "Nothing changed.")
        case .recentCommits: String(localized: "No commits yet.")
        case .commit: String(localized: "This commit didn't change any files here.")
        case .otherWork: String(localized: "No other branches or worktrees.")
        case .work: String(localized: "Nothing changed here.")
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
    func refreshScopedChanges(_ id: WorkspaceID? = nil) {
        let workspaceID = id ?? activeID
        guard let live = lives[workspaceID], let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let scope = live.changesScope
        if scope == .sinceCommit {
            live.scopeIsLoading = false
            if !live.turnChanges.isEmpty { live.turnChanges = [] }
            return
        }
        if case .commit = scope, !live.scopeIsLoading { return }
        let turn = scopedTurn(in: workspaceID)
        switch scope {
        case .latestTurn, .turn:
            guard turn == nil else { break }
            live.scopeIsLoading = false
            if !live.turnChanges.isEmpty { live.turnChanges = [] }
            return
        default:
            break
        }
        guard !live.turnChangesInFlight else { return }
        live.turnChangesInFlight = true
        let snapshots = self.snapshots
        let folders = workspace.folders
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
            case .otherWork: break
            case .work(let work): files = Git.changes(of: work)
            }
            await MainActor.run {
                guard let self else { return }
                live.turnChangesInFlight = false
                guard self.lives[workspaceID] === live else { return }
                // Someone chose something else while this was looking.
                guard live.changesScope == scope else {
                    self.refreshScopedChanges(workspaceID)
                    return
                }
                live.scopeIsLoading = false
                if live.turnChanges != files { live.turnChanges = files }
                if live.branchBases != bases { live.branchBases = bases }
                if live.recentCommits != commits, case .recentCommits = scope { live.recentCommits = commits }
            }
        }
    }

    /// Whether what's in front has changes to go through.
    var canGoToChange: Bool {
        guard let item = active.peek ?? active.activeItem else { return false }
        if case .diff = item.content { return true }
        return textViewer(for: item.id)?.hasChangeMarks == true
    }

    /// F7 and ⇧F7, in a diff or in a file with marks beside its lines.
    func goToChange(forward: Bool) {
        guard let item = active.peek ?? active.activeItem else { return }
        if let diff = existingController(for: item.id) as? DiffController {
            diff.goToChange(forward: forward)
        } else {
            textViewer(for: item.id)?.goToChange(forward: forward)
        }
    }

    private func textViewer(for item: ItemID) -> TextController? {
        let controller = existingController(for: item)
        return controller as? TextController ?? (controller as? MarkdownController)?.shownSource
    }

    /// The repository a file is in and its path there, if it's one this workspace knows about.
    /// Those are known already, so a file outside them costs nothing to look at.
    func repositoryPlace(of path: String) -> (root: String, relative: String)? {
        // A file in a window behind is in that window's workspace's repositories.
        let known = repositories + lives.filter { $0.key != activeID }.values.flatMap(\.repositories)
        guard !known.isEmpty else { return nil }
        let real = Git.real(path)
        for repository in known {
            let root = Git.real(repository.root)
            if real.hasPrefix(root + "/") { return (repository.root, String(real.dropFirst(root.count + 1))) }
        }
        return nil
    }

    /// A commit, or a repository coming into view, changes what the files are compared with.
    func refreshChangeMarks(in id: WorkspaceID? = nil) {
        guard let workspace = workspaces.first(where: { $0.id == id ?? activeID }) else { return }
        for item in workspace.items + (workspace.peek.map { [$0] } ?? []) {
            textViewer(for: item.id)?.refreshChangeMarks()
        }
    }

    /// A mark beside a file's line: its change, floating over the file.
    func peekChange(path: String, line: Int) {
        peekDiff(DiffSpec(path: path), takeFocus: true)
        guard let peek = active.peek else { return }
        controller(for: peek.id)?.goTo(line: line, col: nil)
    }

    /// Turns from this workspace worth offering, newest first, a few for each terminal.
    var offeredTurns: [AgentTurn] { offeredTurns(in: activeID) }

    func offeredTurns(in id: WorkspaceID) -> [AgentTurn] {
        var seen: [ItemID: Int] = [:]
        return turns.reversed().filter { turn in
            guard turn.workspace == id, !turn.changedNothing else { return false }
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
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    private var label: String {
        switch here.changesScope {
        case .sinceCommit: String(localized: "Since commit")
        case .latestTurn: String(localized: "Latest turn")
        case .turn: String(localized: "One turn")
        case .branch: String(localized: "This branch")
        case .recentCommits: String(localized: "Recent commits")
        case .commit(let commit): commit.shortOID
        case .otherWork: String(localized: "Other work")
        case .work(let work): work.branch
        }
    }

    var body: some View {
        Menu {
            scopeButton(String(localized: "Since Last Commit"), .sinceCommit)
            scopeButton(String(localized: "This Branch"), .branch)
            scopeButton(String(localized: "Recent Commits"), .recentCommits)
            scopeButton(here.otherWork.isEmpty ? String(localized: "Other Work") : String(localized: "Other Work (\(here.otherWork.count))"), .otherWork)
            let offered = here.offeredTurns
            if !offered.isEmpty || here.changesScope == .latestTurn {
                scopeButton(String(localized: "Latest Turn"), .latestTurn)
            }
            if !offered.isEmpty {
                Divider()
                ForEach(offered) { turn in
                    scopeButton(turn.isOpen ? String(localized: "\(AppModel.describe(turn)) (working)") : AppModel.describe(turn), .turn(turn.id))
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
        Toggle(title, isOn: Binding(get: { here.changesScope == scope }, set: { _ in model.setChangesScope(scope) }))
    }
}

/// What the list is compared with, when it's a branch.
struct BranchCaption: View {
    let bases: [BranchBase]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bases, id: \.root) { base in
                Text(bases.count > 1 ? (base.root as NSString).lastPathComponent + ": " + base.displayDescription : base.displayDescription)
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
            .accessibilityLabel("Back to Recent Commits")
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([commit.shortOID, RelativeTime.display(commit.date)] + (commit.isMerge ? [String(localized: "compared with its first parent")] : [])).joined(separator: " · "))
                    .foregroundStyle(.faint)
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

// MARK: - Other work

extension AppModel {
    /// Agents make branches and worktrees for themselves. Nobody should have to go looking, so this
    /// is looked at along with everything else, and it's only worked out in full when something moved.
    func refreshOtherWork(_ id: WorkspaceID? = nil) {
        let workspaceID = id ?? activeID
        guard let live = lives[workspaceID], let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        // Agents save often, and each look asks git several things per branch.
        var showing = live.changesScope == .otherWork
        if case .work = live.changesScope { showing = true }
        let now = ProcessClock.now()
        let first = !live.otherWorkLooked
        live.otherWorkLooked = true
        guard !live.otherWorkInFlight, first || showing || now - live.otherWorkAt > 8000 else { return }
        live.otherWorkAt = now
        live.otherWorkInFlight = true
        let folders = workspace.folders
        Task.detached(priority: .utility) { [weak self] in
            let lines = Git.otherWork(in: folders)
            await MainActor.run {
                guard let self else { return }
                live.otherWorkInFlight = false
                guard self.lives[workspaceID] === live else { return }
                if live.otherWork != lines { live.otherWork = lines }
                // What a worktree outside the workspace's folders changed reaches nothing else.
                if case .work(let shown) = live.changesScope, let current = lines.first(where: { $0.id == shown.id }), current != shown {
                    live.changesScope = .work(current)
                    self.refreshScopedChanges(workspaceID)
                }
            }
        }
    }

    /// The agent already in that worktree, if there is one, since it knows the work. Otherwise any.
    func askAgent(aboutWork work: WorkLine, prompt: String) {
        let sessions = activeAgentSessions()
        if let worktree = work.worktree,
           let there = sessions.first(where: { EditorBridge.realPath($0.terminal.currentDirectory).hasPrefix(EditorBridge.realPath(worktree)) }) {
            focusAgent(there.terminal)
            there.terminal.send(text: AgentReference.bracketedPaste(prompt))
            return
        }
        guard !sessions.isEmpty else {
            if let preset = firstAgentPreset {
                askAgent(preset: preset, prompt: prompt)
            } else {
                showToast(title: String(localized: "No agent is running"), detail: String(localized: "Start one from the + button, then try again."), symbol: "sparkles", tint: .secondary)
            }
            return
        }
        withAgent(asking: String(localized: "Which session should do this?")) { [weak self] terminal, _ in
            self?.focusAgent(terminal)
            terminal.send(text: AgentReference.bracketedPaste(prompt))
        }
    }

    /// Who's in a worktree, for the list.
    func agentName(inWorktree worktree: String?) -> String? {
        guard let worktree else { return nil }
        let real = EditorBridge.realPath(worktree)
        return agentRows.first { $0.directory.hasPrefix(real) }?.agent
    }
}

/// A word under Changes when there's work elsewhere. It finds you, rather than the other way round.
struct OtherWorkHint: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        let unfinished = here.otherWork.filter(\.isUnfinished).count
        Button {
            model.setChangesScope(.otherWork)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(unfinished == 0 ? String(localized: "\(here.otherWork.count) merged, ready to clean up")
                     : unfinished == 1 ? String(localized: "1 more branch not merged") : String(localized: "\(unfinished) more branches not merged"))
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 3)
    }
}

struct WorkRow: View {
    let work: WorkLine
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.setChangesScope(.work(work))
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(work.branch)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(([model.agentName(inWorktree: work.worktree)].compactMap { $0 } + [work.displaySummary]).joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(work.subject)
    }
}

/// Which branch the list is showing, and the one thing to do about it: ask.
struct WorkCaption: View {
    let work: WorkLine
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    model.setChangesScope(.otherWork)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Other Work")
                .accessibilityLabel("Back to Other Work")
                VStack(alignment: .leading, spacing: 1) {
                    Text(work.displaySummary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(work.subject).foregroundStyle(.faint).lineLimit(1)
                }
            }
            Button(work.isUnfinished ? String(localized: "Ask Agent to Merge") : String(localized: "Ask Agent to Clean Up")) {
                model.askAgent(aboutWork: work, prompt: work.isUnfinished ? work.mergeRequest : work.cleanUpRequest)
            }
            .controlSize(.small)
            .padding(.leading, 20)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

