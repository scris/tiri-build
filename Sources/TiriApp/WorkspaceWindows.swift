import AppKit
import SwiftUI
import TiriCore

// Each window shows a workspace of its own. The one in front is `activeID`, so commands, the palette, `tiri` and
// shortcuts all act on what's in front, as they did with one window. A window behind still draws its own
// workspace: its views read it through `WindowModel`, from the scope its window puts in the environment, and
// what's worked out about a workspace (Changes, the tree, repositories) is kept per workspace, in `WorkspaceLive`.

/// The window a view is in, and the workspace that window shows.
struct WindowScope: Equatable {
    var window: String
    var workspace: WorkspaceID
}

extension EnvironmentValues {
    @Entry var windowScope: WindowScope? = nil
}

/// What Tiri has worked out about a workspace that's showing in a window. Made when a window shows it, and let go
/// when none does, so another workspace's changes can't show here, even for a moment.
@MainActor
@Observable
final class WorkspaceLive {
    let id: WorkspaceID
    var changes: [ChangedFile] = [] {
        didSet {
            changedPaths = Set(changes.map(\.path))
            fileTree.changesUpdated(changes)
        }
    }
    /// Each repository the workspace's folders are in, for the status bar.
    var repositories: [RepositoryStatus] = []
    /// Whether this workspace has repositories, as of the last look. See `AppModel.barHasRepositories`.
    var barHasRepositories = false
    /// A folder here is a repository, but this Mac has no git to read it with until Apple's tools are installed.
    var needsGit = false
    /// Open files that aren't there any more.
    var deletedFiles: Set<String> = []
    /// False while a privacy check for the workspace's paths is outstanding.
    var accessReady = false
    var changesScope: ChangesScope = .sinceCommit
    var turnChanges: [ChangedFile] = []
    var branchBases: [BranchBase] = []
    var recentCommits: [CommitSummary] = []
    var otherWork: [WorkLine] = []
    var scopeIsLoading = false
    /// The list isn't everything there is: too many changes, or git too slow to say.
    var changesNotice: ChangesNotice?

    @ObservationIgnored let fileTree = FileTreeController()
    @ObservationIgnored var treeFolders: [String]?
    @ObservationIgnored var watchedFolders: [String]?
    @ObservationIgnored var changesTokens: [FileWatchHub.Token] = []
    @ObservationIgnored var repositoryTokens: [String: FileWatchHub.Token] = [:]
    @ObservationIgnored var changesWork: DispatchWorkItem?
    @ObservationIgnored var changesInFlight = false
    @ObservationIgnored var changesAgain = false
    @ObservationIgnored var turnChangesInFlight = false
    @ObservationIgnored var otherWorkInFlight = false
    @ObservationIgnored var otherWorkAt: Double = 0
    @ObservationIgnored var otherWorkLooked = false
    @ObservationIgnored var changesQuietUntil: Date?
    /// Past the limit, files changing don't ask git again: only someone asking does. See ChangesNotice.
    @ObservationIgnored var changesPaused = false
    /// The same paths as `changes`, to ask about one without going through ten thousand.
    @ObservationIgnored var changedPaths: Set<String> = []
    @ObservationIgnored var changesBackoff: TimeInterval = 0

    init(id: WorkspaceID, model: AppModel) {
        self.id = id
        fileTree.model = model
    }

    /// The tree shows these folders, read again only when they've changed or `force` says so.
    func bindTree(_ workspace: Workspace, force: Bool = false) {
        guard force || treeFolders != workspace.folders else { return }
        treeFolders = workspace.folders
        fileTree.bind(workspace)
    }

    /// Nothing more to watch or look at. The tree remembers what was open in it.
    func retire() {
        fileTree.clear()
        changesWork?.cancel()
        changesTokens = []
        repositoryTokens = [:]
    }
}

/// The model, as one window sees it: its own workspace in place of the one in front, and everything else as it is.
/// Views that draw a workspace read through this, under the name they always used, so they need no other change.
@MainActor
@dynamicMemberLookup
struct WindowModel {
    let app: AppModel
    let scope: WindowScope?

    init(app: AppModel, scope: WindowScope?) {
        self.app = app
        self.scope = scope
    }

    var activeID: WorkspaceID {
        guard let scope, app.workspaces.contains(where: { $0.id == scope.workspace }) else { return app.activeID }
        return scope.workspace
    }

    var active: Workspace { app.workspaces.first { $0.id == activeID } ?? app.active }
    /// This window is the one in front.
    var isCurrent: Bool { activeID == app.activeID }
    var live: WorkspaceLive { app.lives[activeID] ?? app.live(activeID) }

    var fileTree: FileTreeController { live.fileTree }
    var changes: [ChangedFile] { live.changes }
    var repositories: [RepositoryStatus] { live.repositories }
    var barHasRepositories: Bool { live.barHasRepositories }
    var needsGit: Bool { live.needsGit }
    var deletedFiles: Set<String> { live.deletedFiles }
    var accessReady: Bool { live.accessReady }
    var changesScope: ChangesScope { live.changesScope }
    var branchBases: [BranchBase] { live.branchBases }
    var recentCommits: [CommitSummary] { live.recentCommits }
    var otherWork: [WorkLine] { live.otherWork }
    var scopeIsLoading: Bool { live.scopeIsLoading }
    var visibleChanges: [ChangedFile] { app.visibleChanges(in: activeID) }
    var visibleChangesCount: Int { app.visibleChangesCount(in: activeID) }
    var scopedTurn: AgentTurn? { app.scopedTurn(in: activeID) }
    var offeredTurns: [AgentTurn] { app.offeredTurns(in: activeID) }
    var emptyChangesText: String { app.emptyChangesText(in: activeID) }
    func hasChanges(_ path: String) -> Bool {
        // Read for SwiftUI to follow. The set answers.
        _ = live.changes
        return live.changedPaths.contains(path)
    }

    /// The same terms as the window in front's, with this one's repositories and server, so the bar doesn't come
    /// and go, resizing every terminal, as windows take turns in front.
    var statusBarHasContent: Bool {
        _ = app.controllerRevision
        return app.yourTiri.waiting != nil || live.barHasRepositories || app.languageHasNews || active.remote != nil
            || !app.plugins.statusItems.isEmpty || app.unknownLanguageExtension != nil
    }

    // What the sidebar asks for. A click in a window brings it in front first, so these act on its workspace.
    func addFolderInteractive() { app.addFolderInteractive() }
    func openConversationPicker() { app.openConversationPicker() }

    subscript<T>(dynamicMember keyPath: KeyPath<AppModel, T>) -> T { app[keyPath: keyPath] }
}

// MARK: - Per-workspace state, for the workspace in front

extension AppModel {
    /// What's been worked out about a workspace, made if it's needed.
    func live(_ id: WorkspaceID) -> WorkspaceLive {
        if let existing = lives[id] { return existing }
        let made = WorkspaceLive(id: id, model: self)
        lives[id] = made
        return made
    }

    private var frontLive: WorkspaceLive { live(activeID) }

    var fileTree: FileTreeController { frontLive.fileTree }
    var changes: [ChangedFile] {
        get { lives[activeID]?.changes ?? [] }
        set { frontLive.changes = newValue }
    }
    var repositories: [RepositoryStatus] {
        get { lives[activeID]?.repositories ?? [] }
        set { frontLive.repositories = newValue }
    }
    var barHasRepositories: Bool {
        get { lives[activeID]?.barHasRepositories ?? false }
        set { frontLive.barHasRepositories = newValue }
    }
    var needsGit: Bool {
        get { lives[activeID]?.needsGit ?? false }
        set { frontLive.needsGit = newValue }
    }
    var deletedFiles: Set<String> { lives[activeID]?.deletedFiles ?? [] }
    var accessReady: Bool { lives[activeID]?.accessReady ?? false }
    var changesScope: ChangesScope {
        get { lives[activeID]?.changesScope ?? .sinceCommit }
        set { frontLive.changesScope = newValue }
    }
    var turnChanges: [ChangedFile] {
        get { lives[activeID]?.turnChanges ?? [] }
        set { frontLive.turnChanges = newValue }
    }
    var branchBases: [BranchBase] {
        get { lives[activeID]?.branchBases ?? [] }
        set { frontLive.branchBases = newValue }
    }
    var recentCommits: [CommitSummary] {
        get { lives[activeID]?.recentCommits ?? [] }
        set { frontLive.recentCommits = newValue }
    }
    var otherWork: [WorkLine] {
        get { lives[activeID]?.otherWork ?? [] }
        set { frontLive.otherWork = newValue }
    }
    var scopeIsLoading: Bool {
        get { lives[activeID]?.scopeIsLoading ?? false }
        set { frontLive.scopeIsLoading = newValue }
    }

    /// The workspaces in a window, and the one in front even while its window is still opening.
    var shownWorkspaces: Set<WorkspaceID> { Set(windowWorkspaces.values).union([activeID]) }

    /// Lets go of what's known about workspaces no window shows any more.
    func pruneLives() {
        let shown = shownWorkspaces
        for (id, live) in lives where !shown.contains(id) {
            live.retire()
            lives[id] = nil
        }
    }

    /// The window showing a workspace, if one is.
    func window(showing workspace: WorkspaceID) -> String? {
        WindowPlan.window(showing: workspace, in: windowWorkspaces)
    }
}

// MARK: - Windows

extension AppModel {
    static let workspaceWindowScene = "workspace"

    /// The window in front, where sheets go and keys are read.
    var window: NSWindow? {
        workspaceWindows[currentWindow] ?? workspaceWindows[WindowPlan.main] ?? workspaceWindows.values.first
    }

    /// From `init`: the main window shows what it showed, and the others open once SwiftUI can open them.
    func prepareWindows(saved: [SavedWindow]) {
        let plan = WindowPlan.restore(saved, workspaces: workspaces.map(\.id), active: activeID)
        activeID = plan[0].workspace
        windowWorkspaces = [WindowPlan.main: activeID]
        windowOrder = [WindowPlan.main]
        windowsToRestore = Array(plan.dropFirst())
    }

    /// The main window's view hands over how SwiftUI opens windows. Windows saved at the last quit open now.
    func adoptOpenWindow(_ action: OpenWindowAction) {
        openWindowAction = action
        let restoring = windowsToRestore
        windowsToRestore = []
        for placement in restoring where workspaces.contains(where: { $0.id == placement.workspace }) && window(showing: placement.workspace) == nil {
            windowWorkspaces[placement.id] = placement.workspace
            windowOrder.append(placement.id)
            if let frame = placement.frame { pendingFrames[placement.id] = frame }
            enterWorkspace(placement.workspace, focus: false)
            action(id: Self.workspaceWindowScene, value: placement.id)
        }
        syncWatchRoots()
    }

    /// File → New Window, a workspace's Open in New Window and `tiri window new`. A workspace that's already in a
    /// window comes forward there instead, since its terminals can only be in one place. With none named, the new
    /// window starts a workspace of its own, at the start screen.
    @discardableResult
    func openNewWindow(showing requested: WorkspaceID? = nil) -> String? {
        if let requested, let showing = window(showing: requested) {
            focusWindow(showing)
            return showing
        }
        guard let open = openWindowAction else { return nil }
        let workspace = requested ?? createWorkspace(name: Workspace.placeholderName, folders: [], activating: false, initialTerminal: false).id
        let id = UUID().uuidString
        let previous = activeID
        windowWorkspaces[id] = workspace
        windowOrder.append(id)
        if let front = window { pendingFrames[id] = Self.cascaded(from: front.frame, within: front.screen?.visibleFrame) }
        windowBecameCurrent(id)
        open(id: Self.workspaceWindowScene, value: id)
        dropIfUnused(previous)
        scheduleSave()
        return id
    }

    /// A little down and to the right of the window in front, and still on its screen.
    private static func cascaded(from frame: NSRect, within screen: NSRect?) -> [Double] {
        var next = frame.offsetBy(dx: 36, dy: -36)
        if let screen {
            next.size.width = min(next.width, screen.width)
            next.size.height = min(next.height, screen.height)
            next.origin.x = min(max(next.minX, screen.minX), screen.maxX - next.width)
            next.origin.y = min(max(next.minY, screen.minY), screen.maxY - next.height)
        }
        return [next.minX, next.minY, next.width, next.height].map(Double.init)
    }

    /// Brings a window to the front, and its workspace with it.
    func focusWindow(_ id: String) {
        windowBecameCurrent(id)
        guard let window = workspaceWindows[id] else { return }
        // A test copy never comes forward: someone may be using this Mac. What's in front moves all the same.
        guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] != "1" else { return }
        Self.bringAppForward()
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow(_ id: String) {
        guard let window = workspaceWindows[id] else {
            windowClosed(id)
            return
        }
        window.performClose(nil)
        // A window that won't close by asking, as a hidden one may not, closes anyway.
        if workspaceWindows[id] != nil { window.close() }
        if workspaceWindows[id] != nil { windowClosed(id) }
    }

    /// The window in front changed, by a click, the keyboard or a command. Its workspace is now the one everything acts on.
    func windowBecameCurrent(_ id: String) {
        guard id != currentWindow, let workspace = windowWorkspaces[id] else { return }
        // A Peek, the palette and find belong to the window in front, and don't follow you to another.
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        if let index = workspaces.firstIndex(where: { $0.id == activeID }) { workspaces[index].dismissPeek() }
        find = nil
        if palette != nil { closePalette(restoreFocus: false) }
        sidebarVisibilities[currentWindow] = sidebarVisibility
        currentWindow = id
        let visibility = sidebarVisibilities[id] ?? .all
        if sidebarVisibility != visibility { sidebarVisibility = visibility }
        guard workspace != activeID else { return }
        activeID = workspace
        syncWatchRoots()
        enterWorkspace(workspace, focus: false)
        refreshDeletedFiles()
        scheduleSave()
        markActiveItemSeen()
    }

    /// A window's own sidebar, shown or not. The one in front is `sidebarVisibility`.
    func sidebarVisibility(ofWindow id: String) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { [unowned self] in id == self.currentWindow ? self.sidebarVisibility : self.sidebarVisibilities[id] ?? .all },
                set: { [unowned self] value in
                    if id == self.currentWindow { self.sidebarVisibility = value } else { self.sidebarVisibilities[id] = value }
                })
    }

    /// A workspace window's view is on screen. Main, or one opened since.
    func registerWindow(_ window: NSWindow, id: String) {
        guard workspaceWindows[id] !== window else { return }
        workspaceWindows[id] = window
        if windowWorkspaces[id] == nil {
            // The main window, reopened from the Window menu after it was closed.
            let workspace = WindowPlan.unshown(workspaces.map(\.id), shown: Set(windowWorkspaces.values))
                ?? createWorkspace(name: Workspace.placeholderName, folders: [], activating: false, initialTerminal: false).id
            windowWorkspaces[id] = workspace
            if !windowOrder.contains(id) { windowOrder.append(id) }
            enterWorkspace(workspace, focus: false)
            syncWatchRoots()
        }
        if let frame = pendingFrames.removeValue(forKey: id), frame.count == 4 {
            window.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: false)
        }
        let center = NotificationCenter.default
        windowObservers[id]?.forEach(center.removeObserver)
        windowObservers[id] = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameCurrent(id) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed(id) }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            },
        ]
        if window.isKeyWindow { windowBecameCurrent(id) }
    }

    /// Closing a window doesn't end anything in it. Its workspace stays in the switcher, its terminals running.
    func windowClosed(_ id: String) {
        windowObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        workspaceWindows[id] = nil
        guard let shown = windowWorkspaces.removeValue(forKey: id) else { return }
        windowOrder.removeAll { $0 == id }
        sidebarVisibilities[id] = nil
        if id == currentWindow, let next = windowOrder.first(where: { workspaceWindows[$0] != nil }) ?? windowOrder.first {
            windowBecameCurrent(next)
        }
        dropIfUnused(shown)
        pruneLives()
        syncWatchRoots()
        scheduleSave()
    }

    /// A workspace made for a new window that was never used goes when it's left, rather than piling up in the switcher.
    func dropIfUnused(_ id: WorkspaceID) {
        guard workspaces.count > 1, !shownWorkspaces.contains(id),
              let workspace = workspaces.first(where: { $0.id == id }),
              workspace.folders.isEmpty, workspace.items.isEmpty, workspace.remote == nil, workspace.review.isEmpty,
              workspace.name == Workspace.placeholderName || workspace.name.hasPrefix(Workspace.placeholderName + " ") else { return }
        workspaces.removeAll { $0.id == id }
        scheduleSave()
    }

    /// After a workspace is deleted: each window that showed it gets one no window has, or a new one.
    func rehomeWindows(from deleted: WorkspaceID) {
        for id in windowOrder where windowWorkspaces[id] == deleted && id != currentWindow {
            let workspace = WindowPlan.unshown(workspaces.map(\.id), shown: shownWorkspaces)
                ?? createWorkspace(name: Workspace.placeholderName, folders: [], activating: false, initialTerminal: false).id
            windowWorkspaces[id] = workspace
            enterWorkspace(workspace, focus: false)
        }
    }

    /// For the store: each window, main first, and where it is.
    var windowPlacements: [SavedWindow] {
        windowOrder.compactMap { id in
            guard let workspace = windowWorkspaces[id] else { return nil }
            let frame = workspaceWindows[id].map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init) } ?? pendingFrames[id]
            return SavedWindow(id: id, workspace: workspace, frame: id == WindowPlan.main ? nil : frame)
        }
    }

    /// For `tiri window list`.
    func describeWindows() -> JSONValue {
        .array(windowOrder.compactMap { id -> JSONValue? in
            guard let workspaceID = windowWorkspaces[id], let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return nil }
            var entry: [String: JSONValue] = [
                "id": .string(id), "workspace": .string(workspace.name), "workspaceID": .string(workspace.id),
                "current": .bool(id == currentWindow), "open": .bool(workspaceWindows[id] != nil),
            ]
            if let window = workspaceWindows[id] {
                entry["number"] = .int(window.windowNumber)
                entry["frame"] = .array([window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { .int(Int($0)) })
            }
            return .object(entry)
        })
    }

    /// A window by its id, or by the workspace it shows.
    func findWindow(_ name: String) -> String? {
        if windowWorkspaces[name] != nil { return name }
        guard let workspace = workspaces.first(where: { $0.name == name || $0.id == name }) else { return nil }
        return window(showing: workspace.id)
    }
}

/// A window of its own, for a workspace of its own.
struct WorkspaceWindowRoot: View {
    let windowID: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let windowID {
            RootView(windowID: windowID)
        } else {
            // SwiftUI only opens these with an id. Anything else has nothing to show, so it goes.
            Color.clear.background(WindowAccessor { window in DispatchQueue.main.async { window.close() } })
        }
    }
}
