import AppKit
import Observation
import SwiftUI
import TiriCore
import UniformTypeIdentifiers
import UserNotifications

enum TerminalStatus: String {
    case idle, working, needsInput = "needs-input", done, exited
}

struct TerminalRuntime: Equatable {
    var status: TerminalStatus = .idle
    var message: String?
    /// Something happened here that the user hasn't looked at yet.
    var unseen = false
    var title: String?
    var exitCode: Int32?
}

struct AppBanner: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
    var opensPrivacySettings = false
}

/// macOS can hold a file call for as long as a privacy prompt is on screen. These checks run
/// off the main thread, so the first touch of ~/Documents can't freeze the app.
enum FolderAccess {
    nonisolated static func deniedPaths(_ paths: [String]) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            paths.filter { path in
                if let directory = opendir(path) {
                    closedir(directory)
                    return false
                }
                if errno == ENOTDIR {
                    let descriptor = Darwin.open(path, O_RDONLY)
                    if descriptor >= 0 {
                        close(descriptor)
                        return false
                    }
                }
                return errno == EPERM || errno == EACCES
            }
        }.value
    }
}

struct AppToast: Identifiable {
    let id = UUID()
    var title: String
    var detail: String?
    var symbol: String
    var tint: Color
    var actionTitle: String?
    var action: (() -> Void)?
}

struct FindState: Equatable {
    var query = ""
    var targetItem: ItemID
    var notFound = false
    var focusNonce = 0
}

enum OpenIntent: Equatable {
    case preview
    case pinned
    case split(SplitDirection)
    case peek(takeFocus: Bool)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: State

    var workspaces: [Workspace] = []
    var activeID: WorkspaceID = ""
    var settings = TiriSettings()
    var keybindings: [Keybinding] = Keymap.build(user: [])
    var runtimes: [ItemID: TerminalRuntime] = [:]
    var banner: AppBanner?
    var toasts: [AppToast] = []
    var find: FindState?
    var tabDrag: TabDragState?
    var palette: PaletteModel?
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var peekHasKeyboard = false
    /// False while a privacy check for the active workspace's paths is outstanding.
    var accessReady = false
    var systemAppearanceRevision = 0
    /// Bumped when something outside SwiftUI's view (a controller) changed what headers show.
    var controllerRevision = 0

    @ObservationIgnored var keyResolver = KeyResolver(bindings: Keymap.build(user: []))
    @ObservationIgnored var window: NSWindow?
    @ObservationIgnored let layoutRegistry = LayoutRegistry()
    @ObservationIgnored let fileTree = FileTreeController()
    @ObservationIgnored let settingsStore = SettingsStore()
    @ObservationIgnored let fileIndex = FileIndexStore()
    @ObservationIgnored let terminalFolderIndex = FileIndexStore()
    @ObservationIgnored lazy var editorBridge = EditorBridge(model: self)
    @ObservationIgnored var lastAgentTerminal: ItemID?
    var turns: [AgentTurn] = []
    var changesScope: ChangesScope = .sinceCommit
    var turnChanges: [ChangedFile] = []
    @ObservationIgnored var turnChangesInFlight = false
    @ObservationIgnored let snapshots = TurnSnapshots()
    @ObservationIgnored let turnStore = TurnStore()
    var navigationStops: [NavigationStop] = []
    @ObservationIgnored var symbolHover: (view: NSTextView?, range: NSRange)?
    var languageRevision = 0
    /// Whether this workspace has repositories, as of the last look. `repositories` empties for a
    /// moment on every switch, and the bar shouldn't go and come back, resizing every terminal.
    var barHasRepositories = false
    @ObservationIgnored lazy var languageServers = LanguageServerHub(model: self)
    @ObservationIgnored let languageTrust = LanguageServerTrust()
    @ObservationIgnored var hoverPopover: NSPopover?
    @ObservationIgnored var hoverWork: DispatchWorkItem?
    @ObservationIgnored var reviewPopover: NSPopover?
    @ObservationIgnored var reviewPopoverCloser: NSObjectProtocol?
    var changes: [ChangedFile] = []
    /// Each repository the active workspace's folders are in, for the status bar.
    var repositories: [RepositoryStatus] = []
    /// Fetches and pushes under way, by repository.
    var repositoryTransfers: [String: RepositoryTransfer] = [:]
    @ObservationIgnored private var repositoryTokens: [String: FileWatchHub.Token] = [:]
    @ObservationIgnored var userPath: String?
    var detachedItems: Set<ItemID> = []
    @ObservationIgnored private var detachedWindows: [ItemID: NSWindow] = [:]
    @ObservationIgnored private var detachedDelegates: [ItemID: DetachedWindowDelegate] = [:]
    @ObservationIgnored var lastSearchQuery = ""
    @ObservationIgnored private var changesTokens: [FileWatchHub.Token] = []
    @ObservationIgnored private var changesWorkspace: WorkspaceID?
    @ObservationIgnored private var changesWork: DispatchWorkItem?
    @ObservationIgnored private var changesInFlight = false
    @ObservationIgnored private var changesAgain = false
    var recordingShortcutFor: String?
    var hooksRevision = 0
    var settingsAnchor: String?
    @ObservationIgnored private var recordedStrokes: [KeyStroke] = []
    @ObservationIgnored private var recordingWork: DispatchWorkItem?
    @ObservationIgnored var skipQuitConfirmation = false
    @ObservationIgnored var launchMilliseconds: Double?
    @ObservationIgnored var lastOpenMilliseconds: Double?
    @ObservationIgnored private var openInFlight: (item: ItemID, started: Double)?
    @ObservationIgnored var groupHosts: [GroupID: WeakView] = [:]
    @ObservationIgnored private var controllers: [ItemID: ItemController] = [:]
    @ObservationIgnored private var restoredItems: Set<ItemID> = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored let router = EventRouter()
    @ObservationIgnored private let store = WorkspaceStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var recentFiles: [WorkspaceID: [String]] = [:]
    @ObservationIgnored private var didFinishLaunching = false
    @ObservationIgnored private var checkedPaths: Set<String> = []
    @ObservationIgnored private var tabDragCommitted = false

    struct WeakView { weak var view: NSView? }

    // MARK: Lifecycle

    private init() {
        if let snapshot = store.load(), !snapshot.workspaces.isEmpty {
            workspaces = snapshot.workspaces
            activeID = snapshot.activeID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil } ?? workspaces[0].id
            // Everything that was running comes back as a fresh process.
            for workspace in workspaces {
                for item in workspace.items {
                    if case .terminal = item.content { restoredItems.insert(item.id) }
                }
            }
        } else {
            // Nothing runs until you've said where: see `startTerminal`.
            let first = Workspace(name: Workspace.placeholderName)
            workspaces = [first]
            activeID = first.id
        }
        // A settings.json tab from before Settings had a screen becomes the screen.
        let settingsFiles = [settingsStore.settingsURL.path, settingsStore.keybindingsURL.path]
        for index in workspaces.indices {
            for item in workspaces[index].items where item.filePath.map(settingsFiles.contains) == true {
                workspaces[index].updateItem(item.id) { $0.content = .settings }
            }
        }
        settingsStore.onChange = { [weak self] in self?.applySettings() }
        settingsStore.start()
        settings = settingsStore.settings
        rebuildKeybindings()
        banner = settingsStore.currentError.map { AppBanner(message: $0, isError: true) }
    }

    func finishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        editorBridge.start()
        loadTurns()
        // Whatever isn't in a tab any more has nothing to come back to.
        TerminalSessions.endAll(except: Set(workspaces.flatMap { $0.items.map(\.id) }))
        router.install(model: self)
        applyTheme()
        observeSystemAppearance()
        startServer()
        notifier.configure { [weak self] workspace, item in
            self?.focusFromNotification(workspace: workspace, item: item)
        }
        FileWatchHub.shared.excludedNames = Set(settings.filesExclude)
        FileWatchHub.shared.onChanges = { [weak self] paths in self?.filesChanged(paths) }
        syncWatchRoots()
        fileTree.model = self
        enterActiveWorkspace()
        // After launch, so the warm web view doesn't count against the launch budget.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MarkdownWebViews.warmUp() }
    }

    /// Everything that reads the active workspace's files waits here until macOS has said yes.
    private func enterActiveWorkspace() {
        let workspace = active
        var paths = workspace.folders
        for item in workspace.items {
            switch item.content {
            case .terminal(let spec): paths.append(spec.cwd)
            case .file(let spec): paths.append(spec.path)
            case .diff(let spec): paths.append((spec.path as NSString).deletingLastPathComponent)
            case .web, .settings: break
            }
        }
        let unchecked = Array(Set(paths).subtracting(checkedPaths))
        if unchecked.isEmpty {
            accessReady = true
            activeWorkspaceReady()
            return
        }
        accessReady = false
        fileTree.clear()
        Task { [weak self] in
            let denied = await FolderAccess.deniedPaths(unchecked)
            guard let self, self.activeID == workspace.id else { return }
            self.checkedPaths.formUnion(unchecked)
            self.accessReady = true
            if let first = denied.first {
                let name = (first as NSString).abbreviatingWithTildeInPath
                self.banner = AppBanner(message: "macOS is blocking Tiri from reading \(name). Allow it under Privacy & Security > Files and Folders.",
                                        isError: true, opensPrivacySettings: true)
            }
            self.activeWorkspaceReady()
        }
    }

    private func activeWorkspaceReady() {
        fileTree.bind(active)
        refreshFileIndex()
        watchForChanges()
        startActiveWorkspaceTerminals()
        requestFocus()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quick open and link fallback both read this, so it's kept warm in the background.
    func refreshFileIndex() {
        fileIndex.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.fileIndex.refreshIfNeeded(roots: self.active.folders,
                                           excludes: ExcludeMatcher(patterns: self.settings.filesExclude))
        }
    }

    func prepareForTermination() {
        saveWork?.cancel()
        saveNow()
        editorBridge.stop()
        for controller in controllers.values { controller.teardown() }
        languageServers.stopAll()
        server?.stop()
    }

    func applicationDidBecomeActive() {
        markActiveItemSeen()
    }

    func windowDidAppear(_ window: NSWindow) {
        self.window = window
        window.acceptsMouseMovedEvents = true
        window.isRestorable = false
        if launchMilliseconds == nil {
            launchMilliseconds = ProcessClock.millisecondsSinceProcessStart()
        }
        requestFocus()
    }

    private func startServer() {
        let path = TiriPaths.socket
        let server = ControlServer(path: path) { request in
            await ControlHandler.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            showBanner("Tiri's control socket isn't available: \(error)", isError: true)
        }
    }

    var socketPath: String { TiriPaths.socket }

    // MARK: Workspace access

    var active: Workspace {
        get { workspaces.first { $0.id == activeID } ?? workspaces[0] }
        set {
            if let index = workspaces.firstIndex(where: { $0.id == newValue.id }) {
                workspaces[index] = newValue
            }
        }
    }

    func updateActive(_ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == activeID }) else { return }
        change(&workspaces[index])
        afterStructureChange()
    }

    /// Change a workspace that may not be the one in front. An agent in a background workspace
    /// works there, and the user's view and keyboard are left alone.
    func update(workspace id: WorkspaceID, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaces[index])
        afterStructureChange()
    }

    private func updateWorkspace(containing item: ItemID, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.item(item) != nil || $0.peek?.id == item }) else { return }
        change(&workspaces[index])
        afterStructureChange()
    }

    func workspace(containing item: ItemID) -> Workspace? {
        workspaces.first { $0.item(item) != nil || $0.peek?.id == item }
    }

    func anyItem(_ id: ItemID) -> Item? {
        for workspace in workspaces {
            if let item = workspace.item(id) { return item }
            if workspace.peek?.id == id { return workspace.peek }
        }
        return nil
    }

    private func afterStructureChange() {
        collectGarbage()
        scheduleSave()
        markActiveItemSeen()
        autoRevealActive()
    }

    private func collectGarbage() {
        var live: Set<ItemID> = []
        for workspace in workspaces {
            for item in workspace.items { live.insert(item.id) }
            if let peek = workspace.peek { live.insert(peek.id) }
        }
        for (id, controller) in controllers where !live.contains(id) {
            bringBack(id)
            (controller as? TerminalController)?.endSession()
            controller.teardown()
            controllers[id] = nil
            runtimes[id] = nil
        }
        updateDockBadge()
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        do {
            try store.save(.init(workspaces: workspaces, activeID: activeID))
        } catch {
            showBanner("Couldn't save the workspace: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Controllers

    func controller(for id: ItemID) -> ItemController? {
        if let existing = controllers[id] { return existing }
        guard let item = anyItem(id) else { return nil }
        let controller: ItemController
        switch item.content {
        case .terminal(let spec):
            let restored = restoredItems.remove(id) != nil
            var launch = spec.command
            var prefill: String?
            // Still running from before: what's there now is what counts, so nothing is replayed.
            if settings.terminalKeepRunning, TerminalSessions.isAlive(id) {
                launch = nil
            } else if restored, spec.isShell, let typed = spec.typedAgent {
                // Typed at a prompt, so the prompt should still be there after it exits.
                if case .run(let command) = TerminalRestore.plan(for: typed, sessionID: spec.sessionID, resume: settings.terminalResume,
                                                                 enabled: settings.terminalRestoreWithResume) {
                    launch = nil
                    prefill = command + "\r"
                }
            } else if restored {
                switch TerminalRestore.plan(for: spec.command, sessionID: spec.sessionID,
                                            resume: settings.terminalResume,
                                            enabled: settings.terminalRestoreWithResume) {
                case .shell:
                    launch = nil
                case .run(let command):
                    launch = command
                case .prefill(let command):
                    launch = nil
                    prefill = command
                }
            }
            let workspaceID = workspace(containing: id)?.id ?? activeID
            controller = TerminalController(itemID: id, spec: spec, launchCommand: launch, prefill: prefill,
                                            workspaceID: workspaceID, model: self)
        case .file(let spec):
            controller = ViewerFactory.make(itemID: id, spec: spec, model: self)
        case .settings:
            controller = SettingsController(itemID: id, model: self)
        case .diff(let spec):
            controller = DiffController(itemID: id, path: spec.path, turn: spec.turn, model: self)
        case .web(let spec):
            guard let url = URL(string: spec.url) else { return nil }
            controller = WebController(itemID: id, url: url, forceDark: spec.forceDark, isFile: false, model: self)
        }
        controllers[id] = controller
        return controller
    }

    func existingController(for id: ItemID) -> ItemController? { controllers[id] }

    func discardController(_ id: ItemID) {
        controllers[id]?.teardown()
        controllers[id] = nil
    }

    var terminalControllers: [TerminalController] {
        controllers.values.compactMap { $0 as? TerminalController }
    }

    var workingTerminalCount: Int {
        runtimes.values.filter { $0.status == .working }.count
    }

    /// Terminals in the active workspace start with it. The visible one starts as soon as it has
    /// a size; the rest follow just after launch so they don't count against the launch budget.
    func startActiveWorkspaceTerminals() {
        let workspaceID = activeID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let workspace = self.workspaces.first(where: { $0.id == workspaceID }) else { return }
            for item in workspace.items {
                if case .terminal = item.content,
                   let terminal = self.controller(for: item.id) as? TerminalController {
                    terminal.startIfNeeded(fallbackSize: true)
                }
            }
        }
    }

    // MARK: Focus

    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let peek = self.active.peek, self.peekHasKeyboard {
                self.controller(for: peek.id)?.focus()
                return
            }
            // Something in its own window doesn't take the keyboard from over there.
            if let id = self.active.focused.active, !self.detachedItems.contains(id) {
                self.controller(for: id)?.focus()
            }
        }
    }

    func markActiveItemSeen() {
        guard NSApp?.isActive == true, let id = active.focused.active, var runtime = runtimes[id], runtime.unseen else { return }
        runtime.unseen = false
        if runtime.status == .done { runtime.status = .idle }
        runtimes[id] = runtime
        updateDockBadge()
    }

    func handleLeftMouseDown(_ event: NSEvent) {
        tabDrag = nil
        tabDragCommitted = false
        let point = globalPoint(event)
        // A click outside the Peek dismisses it, except a ⌘-click, which may be
        // the next link being opened. Going through a list of files should stay fluid.
        if active.peek != nil, let frame = layoutRegistry.peekFrame {
            if frame.contains(point) {
                setPeekKeyboard(true)
                return
            }
            if !event.modifierFlags.contains(.command) {
                dismissPeek(restoreFocus: false)
            }
        }
        // Clicking a pane makes its group the focused one.
        for (id, weak) in groupHosts {
            guard let view = weak.view, view.window != nil else { continue }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)), active.focusedGroup != id {
                focusGroup(id)
                break
            }
        }
    }

    func globalPoint(_ event: NSEvent) -> CGPoint {
        let height = event.window?.contentView?.bounds.height ?? 0
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }

    private func focusGroup(_ id: GroupID) {
        guard active.focusedGroup != id else { return }
        updateActive { $0.focusGroup(id: id) }
    }

    func handleEscape() -> Bool {
        if palette != nil {
            closePalette()
            return true
        }
        if find != nil, firstResponderIsFindField {
            closeFind()
            return true
        }
        if active.peek != nil, peekHasKeyboard, !firstResponderIsTerminal {
            dismissPeek()
            return true
        }
        return false
    }

    private var firstResponderIsTerminal: Bool { window?.firstResponder is TiriTerminalView }

    private var firstResponderIsFindField: Bool {
        guard let responder = window?.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor
    }

    /// `promotePeek` on ⌘↩ should only eat the key when there's a Peek to promote.
    func isCommandEnabledForKey(_ command: String) -> Bool {
        switch command {
        case "promotePeek", "promotePeekToSide": return active.peek != nil
        case "webReload": return frontWebController != nil
        case "goBack": return canGoBack
        case "goToDefinition", "findReferences", "showHover": return canAskAboutSymbols()
        default: return true
        }
    }

    // MARK: Opening

    @discardableResult
    func open(path rawPath: String, line: Int? = nil, col: Int? = nil, intent: OpenIntent,
              in workspaceID: WorkspaceID? = nil) -> ItemID? {
        let started = ProcessClock.now()
        let target = workspaceID ?? activeID
        let inFront = target == activeID
        let path = aliasedPath(rawPath, in: target)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            if inFront { showToast(title: "No such file", detail: rawPath, symbol: "questionmark.folder", tint: .orange) }
            return nil
        }
        if isDirectory.boolValue {
            if inFront { revealOrOffer(path: path) }
            return nil
        }
        if inFront { rememberRecent(path) }
        var result: ItemID?
        switch intent {
        case .preview:
            update(workspace: target) { workspace in
                result = Self.itemID(of: workspace.openFile(path: path, line: line, col: col, preview: true))
            }
        case .pinned:
            update(workspace: target) { workspace in
                result = Self.itemID(of: workspace.openFile(path: path, line: line, col: col, preview: false))
            }
        case .split(let direction):
            update(workspace: target) { workspace in
                result = Self.itemID(of: workspace.openFile(path: path, line: line, col: col, preview: false, split: direction))
            }
        case .peek(let takeFocus):
            update(workspace: target) { workspace in
                // takeFocus is a person asking. Without it an agent is showing something, and
                // doesn't get to switch tabs or take the keyboard.
                switch workspace.peekFile(path: path, line: line, col: col, revealExisting: takeFocus) {
                case .peeking(let id, _): result = id
                case .revealedExisting(let id): result = id
                }
            }
            guard inFront else { return result }
            if active.peek?.id == result {
                peekHasKeyboard = takeFocus
                if takeFocus { requestFocus() }
                existingController(for: result!)?.goTo(line: line, col: col)
                openInFlight = result.map { ($0, started) }
                return result
            }
            peekHasKeyboard = false
            requestFocus()
        }
        if let result, let controller = existingController(for: result) {
            controller.goTo(line: line, col: col)
        }
        if inFront { openInFlight = result.map { ($0, started) } }
        return result
    }

    private static func itemID(of result: Workspace.OpenResult) -> ItemID {
        switch result {
        case .opened(let id), .revealedExisting(let id): id
        }
    }

    /// The same file can be named two ways when a folder is reached through a symlink: terminals
    /// report the real path, the workspace holds the one it was added with. Everything goes
    /// by the workspace's name for it, so a file doesn't get two tabs or look like it's elsewhere.
    func aliasedPath(_ rawPath: String, in workspaceID: WorkspaceID? = nil) -> String {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard let workspace = workspaces.first(where: { $0.id == workspaceID ?? activeID }) else { return path }
        if workspace.folder(containing: path) != nil { return path }
        let real = Self.realPath(path)
        for folder in workspace.folders {
            let realFolder = Self.realPath(folder)
            if real == realFolder { return folder }
            if real.hasPrefix(realFolder + "/") { return folder + real.dropFirst(realFolder.count) }
        }
        return path
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The time an open really takes: from the request until the content is showing.
    func viewerReady(_ item: ItemID) {
        guard let flight = openInFlight, flight.item == item else { return }
        lastOpenMilliseconds = ProcessClock.now() - flight.started
        openInFlight = nil
    }

    func openFromTree(path: String, pin: Bool) {
        open(path: path, intent: pin ? .pinned : .preview)
        // A single click keeps the keyboard in the tree so arrow keys can keep browsing.
        if pin { requestFocus() }
    }

    /// A ⌘-click in terminal output. Files float as a Peek; folders reveal in the tree.
    func openFromTerminal(_ resolved: ResolvedPath, forceTab: Bool) {
        if resolved.isDirectory {
            revealOrOffer(path: resolved.path)
            return
        }
        let target = forceTab ? LinkOpenTarget.tab : settings.terminalLinkOpens
        switch target {
        case .peek:
            open(path: resolved.path, line: resolved.line, col: resolved.col, intent: .peek(takeFocus: true))
        case .tab:
            open(path: resolved.path, line: resolved.line, col: resolved.col, intent: .pinned)
            requestFocus()
        case .external:
            openExternally(path: resolved.path, line: resolved.line, col: resolved.col)
        }
    }

    /// One match opens. Several let you pick, with the likeliest first.
    func chooseFromTerminal(_ matches: [ResolvedPath], forceTab: Bool) {
        if matches.count <= 1 {
            if let match = matches.first { openFromTerminal(match, forceTab: forceTab) }
            return
        }
        let name = (matches[0].path as NSString).lastPathComponent
        let rows = matches.map { match in
            // Which project each one is in is the whole question, so the folder is always shown.
            let parent = (match.path as NSString).deletingLastPathComponent
            let detail: String
            if let folder = active.folder(containing: match.path) {
                let folderName = (folder as NSString).lastPathComponent
                let directory = (active.relativePath(match.path) as NSString).deletingLastPathComponent
                detail = directory.isEmpty ? folderName : folderName + " • " + directory
            } else {
                detail = (parent as NSString).abbreviatingWithTildeInPath
            }
            return PaletteModel.Row(id: match.path, title: (match.path as NSString).lastPathComponent,
                                    detail: detail,
                                    symbol: FileIcons.symbolName(forName: name, isDirectory: match.isDirectory)) { [weak self] alternate in
                self?.closePalette(restoreFocus: false)
                self?.openFromTerminal(match, forceTab: forceTab || alternate)
            }
        }
        openPalette(.choices(title: "\(matches.count) files match \(name). Type to narrow down.", rows: rows))
    }

    // MARK: Finding what a terminal path means

    /// Where a terminal in this workspace has been working, beyond the workspace's own folders.
    /// Your whole home folder isn't a project, so it isn't searched.
    private func extraLinkRoots(for workspace: Workspace) -> [String] {
        let home = NSHomeDirectory()
        var roots: [String] = []
        for item in workspace.items {
            guard case .terminal(let spec) = item.content else { continue }
            let cwd = (existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd
            let isAncestorOfHome = cwd == home || home.hasPrefix(cwd.hasSuffix("/") ? cwd : cwd + "/")
            // A terminal reports the real path, and a folder can be open under another name for it.
            let real = (cwd as NSString).resolvingSymlinksInPath
            let inWorkspace = workspace.folders.contains { folder in
                let realFolder = (folder as NSString).resolvingSymlinksInPath
                return real == realFolder || real.hasPrefix(realFolder + "/")
            }
            guard !isAncestorOfHome, !inWorkspace, !roots.contains(cwd) else { continue }
            roots.append(cwd)
        }
        return roots.filter { root in !roots.contains { $0 != root && root.hasPrefix($0 + "/") } }
    }

    /// Called as soon as ⌘ is held over a terminal, so underlines are ready by the time you click.
    func warmLinkIndexes(for item: ItemID) {
        guard let workspace = workspace(containing: item) else { return }
        let excludes = ExcludeMatcher(patterns: settings.filesExclude)
        fileIndex.refreshIfNeeded(roots: active.folders, excludes: excludes)
        terminalFolderIndex.ensure(roots: extraLinkRoots(for: workspace), excludes: excludes)
    }

    func rebuildLinkIndexes(for item: ItemID, then done: @escaping () -> Void) {
        fileIndex.invalidate()
        terminalFolderIndex.invalidate()
        warmLinkIndexes(for: item)
        fileIndex.whenReady { [weak self] in
            self?.terminalFolderIndex.whenReady(done)
        }
    }

    func linkMatches(for path: String, from item: ItemID) -> [String] {
        guard let workspace = workspace(containing: item) else { return [] }
        let openFiles = workspace.items.compactMap(\.filePath)
        let cwd = (existingController(for: item) as? TerminalController)?.currentDirectory
        let found = PathSearch.matches(for: path) { name in
            fileIndex.paths(named: name) + terminalFolderIndex.paths(named: name)
                + openFiles.filter { ($0 as NSString).lastPathComponent == name }
        }
        // The same file reached by two names is one match.
        var seen = Set<String>()
        return PathSearch.ranked(found, open: Set(openFiles), near: cwd).filter {
            seen.insert(($0 as NSString).resolvingSymlinksInPath).inserted
        }
    }

    func openWebFromTerminal(_ url: URL, forceTab: Bool) {
        if forceTab || settings.terminalLinkOpens == .tab {
            openWeb(url: url.absoluteString, split: nil)
            return
        }
        if settings.terminalLinkOpens == .external {
            NSWorkspace.shared.open(url)
            return
        }
        updateActive { $0.peekWeb(url: url.absoluteString) }
        peekHasKeyboard = true
        requestFocus()
    }

    @discardableResult
    func openWeb(url: String, split: SplitDirection?, in workspaceID: WorkspaceID? = nil) -> ItemID {
        let target = workspaceID ?? activeID
        let item = Item(content: .web(WebSpec(url: url)))
        update(workspace: target) { $0.addItem(item, split: split) }
        if target == activeID { requestFocus() }
        return item.id
    }

    func revealOrOffer(path rawPath: String) {
        // Asking to see something in the explorer means opening it.
        SidebarSection.explorer.open()
        let path = aliasedPath(rawPath)
        if active.folder(containing: path) != nil {
            revealInTree(path)
        } else {
            let name = (path as NSString).lastPathComponent
            showToast(title: "\(name) isn't in this workspace", detail: path, symbol: "folder.badge.plus", tint: .accentColor,
                      actionTitle: "Add Folder") { [weak self] in
                self?.addFolder(path)
                self?.revealInTree(path)
            }
        }
    }

    func revealInTree(_ path: String) {
        if sidebarVisibility == .detailOnly { sidebarVisibility = .all }
        fileTree.reveal(path: path, expand: true)
    }

    private func autoRevealActive() {
        guard settings.explorerAutoReveal, let path = active.activeItem?.filePath else { return }
        fileTree.reveal(path: path, expand: false, quiet: true)
    }

    private func rememberRecent(_ path: String) {
        var list = recentFiles[activeID] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > 50 { list.removeLast() }
        recentFiles[activeID] = list
    }

    var recentFilesInActive: [String] { recentFiles[activeID] ?? [] }

    // MARK: Peek

    func setPeekKeyboard(_ value: Bool) {
        if peekHasKeyboard != value { peekHasKeyboard = value }
    }

    func promotePeek(split: SplitDirection? = nil) {
        guard active.peek != nil else { return }
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        updateActive { $0.promotePeek(split: split) }
        requestFocus()
    }

    func dismissPeek(restoreFocus: Bool = true, keepStops: Bool = false) {
        guard active.peek != nil else { return }
        // Places inside a Peek go with it. Nothing's left to go back through.
        if !keepStops { navigationStops.removeAll(where: \.inPeek) }
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        updateActive { $0.dismissPeek() }
        if restoreFocus { requestFocus() }
    }

    // MARK: Terminals

    @discardableResult
    func newTerminal(command: String? = nil, cwd: String? = nil, split: SplitDirection? = nil,
                     in workspaceID: WorkspaceID? = nil) -> ItemID {
        let target = workspaceID ?? activeID
        let directory = cwd ?? defaultTerminalDirectory()
        let trimmed = command?.trimmingCharacters(in: .whitespaces)
        let spec = TerminalSpec(command: trimmed?.isEmpty == true ? nil : trimmed, cwd: directory)
        let item = Item(content: .terminal(spec))
        update(workspace: target) { $0.addItem(item, split: split) }
        if target == activeID { requestFocus() }
        return item.id
    }

    /// What every "new terminal" control in the app uses. An agent started in the wrong folder
    /// does real work in the wrong place, so a workspace without a folder asks for one first.
    /// Cancelling starts nothing. Agents using `tiri term` go straight to `newTerminal`.
    func startTerminal(command: String? = nil, split: SplitDirection? = nil, named name: String? = nil) {
        guard active.folders.isEmpty else {
            newTerminal(command: command, split: split)
            return
        }
        let purpose = name ?? settings.terminalPresets.first { $0.command == command && command?.isEmpty == false }?.name
        chooseFolderForActiveWorkspace(for: purpose) { [weak self] folder in
            self?.newTerminal(command: command, cwd: folder, split: split)
        }
    }

    func chooseFolderForActiveWorkspace(for purpose: String? = nil, then start: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder \(purpose ?? "this terminal") will work in"
        panel.prompt = "Choose Folder"
        let workspaceID = activeID
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let folder = panel.url?.path,
                  self.workspaces.contains(where: { $0.id == workspaceID }) else { return }
            self.addFolder(folder, in: workspaceID)
            if workspaceID == self.activeID { start(folder) }
        }
        if let window {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(panel.runModal())
        }
    }

    private func defaultTerminalDirectory() -> String {
        if let item = active.activeItem {
            switch item.content {
            case .terminal(let spec):
                return (existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd
            case .file(let spec):
                return active.folder(containing: spec.path) ?? (spec.path as NSString).deletingLastPathComponent
            case .diff(let spec):
                return active.folder(containing: spec.path) ?? (spec.path as NSString).deletingLastPathComponent
            case .web, .settings:
                break
            }
        }
        return active.folders.first ?? NSHomeDirectory()
    }

    /// What's running at a shell's prompt, so it can be picked up again after a reboot.
    func terminalTypedAgentChanged(item: ItemID, agent: String?) {
        guard let index = workspaces.firstIndex(where: { $0.item(item) != nil }) else { return }
        workspaces[index].updateItem(item) { item in
            if case .terminal(var spec) = item.content, spec.isShell, spec.typedAgent != agent {
                spec.typedAgent = agent
                item.content = .terminal(spec)
            }
        }
        scheduleSave()
    }

    func terminalCwdChanged(item: ItemID, cwd: String) {
        guard let index = workspaces.firstIndex(where: { $0.item(item) != nil }) else { return }
        workspaces[index].updateItem(item) { item in
            if case .terminal(var spec) = item.content, spec.cwd != cwd {
                spec.cwd = cwd
                item.content = .terminal(spec)
            }
        }
        scheduleSave()
    }

    func updateRuntime(_ id: ItemID, _ change: (inout TerminalRuntime) -> Void) {
        var runtime = runtimes[id] ?? TerminalRuntime()
        change(&runtime)
        if runtimes[id] != runtime { runtimes[id] = runtime }
    }

    func isLookingAt(_ id: ItemID) -> Bool {
        guard NSApp.isActive, window?.isKeyWindow == true,
              workspaces.first(where: { $0.id == activeID })?.item(id) != nil else { return false }
        return active.focused.active == id
    }

    func setStatus(_ id: ItemID, _ status: TerminalStatus, message: String? = nil, notify: Bool = true) {
        let previous = runtimes[id]?.status
        let looking = isLookingAt(id)
        updateRuntime(id) { runtime in
            runtime.status = status
            runtime.message = message ?? (status == previous ? runtime.message : nil)
            if status == .needsInput || status == .done {
                if !looking { runtime.unseen = true }
            } else if status == .working {
                runtime.unseen = false
            }
        }
        if status == .done, looking { updateRuntime(id) { $0.status = .idle } }
        updateDockBadge()
        guard notify, status == .needsInput || status == .done, status != previous, !looking,
              settings.notificationsEnabled, let item = anyItem(id), let workspace = workspace(containing: id) else { return }
        let title = title(for: item)
        let body = message ?? (status == .needsInput ? "Needs your input" : "Finished")
        notifier.post(title: title, body: body, subtitle: workspace.name, workspace: workspace.id, item: id)
        if NSApp.isActive {
            showToast(title: title, detail: body,
                      symbol: status == .needsInput ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                      tint: status == .needsInput ? .orange : .green, actionTitle: "Show") { [weak self] in
                self?.focusFromNotification(workspace: workspace.id, item: id)
            }
        }
    }

    func focusFromNotification(workspace: WorkspaceID, item: ItemID) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusItem(item)
    }

    @discardableResult
    func focusItem(_ id: ItemID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.item(id) != nil }) else { return false }
        if workspace.id != activeID { switchWorkspace(workspace.id) }
        // Asking for a tab means the keyboard goes there, even with a Peek floating.
        peekHasKeyboard = false
        updateActive { $0.activate(id) }
        requestFocus()
        return true
    }

    func nextAttention() {
        var candidates: [ItemID] = []
        for workspace in workspaces {
            for item in workspace.items where runtimes[item.id]?.unseen == true {
                candidates.append(item.id)
            }
        }
        // needs-input comes before done: someone is waiting.
        candidates.sort { lhs, rhs in
            (runtimes[lhs]?.status == .needsInput ? 0 : 1) < (runtimes[rhs]?.status == .needsInput ? 0 : 1)
        }
        guard let first = candidates.first else {
            showToast(title: "Nothing needs attention", detail: nil, symbol: "checkmark.circle", tint: .secondary)
            return
        }
        focusItem(first)
    }

    func unseenCount(in workspace: Workspace) -> (needsInput: Int, done: Int) {
        var needs = 0
        var done = 0
        for item in workspace.items {
            guard let runtime = runtimes[item.id], runtime.unseen else { continue }
            if runtime.status == .needsInput { needs += 1 } else { done += 1 }
        }
        return (needs, done)
    }

    private func updateDockBadge() {
        let count = runtimes.values.filter(\.unseen).count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func handleHookReport(item id: ItemID, tool: String?, state: String?, message: String?, session: String?,
                          turn: String? = nil, prompt: String? = nil) {
        if let tool, case .terminal(let spec)? = anyItem(id)?.content, !spec.acceptsHook(from: tool) { return }
        if turn == AgentHookEvent.Turn.start.rawValue { turnStarted(item: id, prompt: prompt) }
        if turn == AgentHookEvent.Turn.end.rawValue { turnEnded(item: id) }
        if let session, !session.isEmpty {
            if let index = workspaces.firstIndex(where: { $0.item(id) != nil }) {
                workspaces[index].updateItem(id) { item in
                    if case .terminal(var spec) = item.content, spec.sessionID != session {
                        spec.sessionID = session
                        item.content = .terminal(spec)
                    }
                }
                scheduleSave()
            }
        }
        guard let state, let status = TerminalStatus(rawValue: state) else { return }
        (existingController(for: id) as? TerminalController)?.noteHookReport(status: status)
        setStatus(id, status, message: message)
    }

    func terminalHoverEvent(_ event: NSEvent) {
        for terminal in terminalControllers {
            terminal.terminalView.hoverEvent(event)
        }
    }

    func title(for item: Item) -> String {
        switch item.content {
        case .terminal(let spec):
            if let title = runtimes[item.id]?.title, !title.isEmpty { return title }
            return spec.isShell ? item.defaultTitle : (spec.command ?? item.defaultTitle)
        case .web:
            if let title = (existingController(for: item.id) as? WebController)?.title, !title.isEmpty { return title }
            return item.defaultTitle
        case .file, .settings, .diff:
            return item.defaultTitle
        }
    }

    // MARK: Closing

    func requestClose(_ id: ItemID, confirm: Bool = true) {
        if active.peek?.id == id {
            dismissPeek()
            return
        }
        if confirm, let controller = existingController(for: id), controller.isDirty, let window, let item = anyItem(id) {
            let alert = NSAlert()
            alert.messageText = "Save your changes to \(title(for: item))?"
            alert.informativeText = "They're lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if response == .alertFirstButtonReturn {
                        self.save(controller) { self.closeNow(id) }
                    } else if response == .alertSecondButtonReturn {
                        self.closeNow(id)
                    }
                }
            }
            return
        }
        if confirm, let terminal = existingController(for: id) as? TerminalController,
           let name = terminal.foregroundProcessName, let window {
            let alert = NSAlert()
            alert.messageText = "Terminate \(name)?"
            alert.informativeText = "This terminal is still running \(name). Closing it stops the process."
            alert.addButton(withTitle: "Terminate")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.closeNow(id) }
                }
            }
            return
        }
        closeNow(id)
    }

    func closeNow(_ id: ItemID) {
        updateWorkspace(containing: id) { $0.close(id) }
        if find?.targetItem == id { find = nil }
        requestFocus()
    }

    func closeActive() {
        if active.peek != nil, peekHasKeyboard {
            dismissPeek()
            return
        }
        guard let id = active.focused.active else { return }
        requestClose(id)
    }

    func reopenClosed() {
        updateActive { workspace in
            guard let item = workspace.popClosed() else { return }
            // A reopened terminal is a new process with the old cwd and command.
            workspace.addItem(Item(content: item.content, isPreview: false))
        }
        requestFocus()
    }

    // MARK: Splits

    func splitActive(_ direction: SplitDirection) {
        guard let item = active.activeItem else {
            startTerminal(split: direction)
            return
        }
        switch item.content {
        case .file(let spec):
            updateActive { $0.addItem(Item(content: .file(spec)), split: direction) }
        case .web(let spec):
            updateActive { $0.addItem(Item(content: .web(spec)), split: direction) }
        case .terminal(let spec):
            // A process can't be in two places, so splitting a terminal starts a new one beside it.
            let cwd = (existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd
            newTerminal(cwd: cwd, split: direction)
            return
        case .settings:
            // One Settings tab per workspace. Beside it, a new terminal is what's useful.
            startTerminal(split: direction)
            return
        case .diff(let spec):
            updateActive { $0.addItem(Item(content: .diff(spec)), split: direction) }
        }
        requestFocus()
    }

    // MARK: Tab dragging

    func updateTabDrag(item: ItemID, title: String, location: CGPoint) {
        // SwiftUI delivers drag updates asynchronously. One that arrives after the drop carries an
        // old position and would move the tab straight back, so it's ignored.
        if tabDragCommitted { return }
        let released = NSEvent.pressedMouseButtons & 1 == 0
        var point = location
        if released, let window, let height = window.contentView?.bounds.height {
            // The mouse is already up: a quick flick drops where it ended, not where this update was.
            let current = window.mouseLocationOutsideOfEventStream
            point = CGPoint(x: current.x, y: height - current.y)
        }
        let target = layoutRegistry.dropTarget(at: point, validGroups: Set(active.groups.map(\.id))) { [self] group in
            active.group(id: group)?.tabs ?? []
        }
        tabDrag = TabDragState(item: item, title: title, location: point, target: target)
        if released { endTabDrag() }
    }

    func endTabDrag() {
        guard let drag = tabDrag else { return }
        tabDrag = nil
        tabDragCommitted = true
        guard let target = drag.target else { return }
        switch target {
        case .tabBar(let group, let index):
            updateActive { $0.moveTab(drag.item, toGroup: group, index: index) }
        case .center(let group):
            if active.group(containing: drag.item)?.id != group {
                updateActive { $0.moveTab(drag.item, toGroup: group) }
            }
        case .edge(let group, let direction):
            updateActive { $0.moveTab(drag.item, splitting: group, direction: direction) }
        }
        requestFocus()
    }

    // MARK: Workspaces

    func switchWorkspace(_ id: WorkspaceID) {
        guard id != activeID, workspaces.contains(where: { $0.id == id }) else { return }
        // A Peek is a glance at what's in front of you. It doesn't follow you elsewhere.
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        if let index = workspaces.firstIndex(where: { $0.id == activeID }) {
            workspaces[index].dismissPeek()
        }
        find = nil
        activeID = id
        collectGarbage()
        syncWatchRoots()
        enterActiveWorkspace()
        scheduleSave()
        markActiveItemSeen()
    }

    func switchWorkspace(index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        switchWorkspace(workspaces[index].id)
    }

    @discardableResult
    func createWorkspace(name: String, folders: [String]) -> Workspace {
        var workspace = Workspace(name: uniqueName(name), folders: folders)
        if !folders.isEmpty { workspace.addInitialTerminal(fallbackCwd: NSHomeDirectory()) }
        workspaces.append(workspace)
        switchWorkspace(workspace.id)
        editorBridge.writeLock()
        return workspace
    }

    private func uniqueName(_ name: String) -> String {
        guard workspaces.contains(where: { $0.name == name }) else { return name }
        var number = 2
        while workspaces.contains(where: { $0.name == "\(name) \(number)" }) { number += 1 }
        return "\(name) \(number)"
    }

    func newWorkspaceInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose the folders for the new workspace"
        panel.prompt = "Create Workspace"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let name = panel.urls[0].lastPathComponent
        createWorkspace(name: name, folders: panel.urls.map(\.path))
    }

    func renameWorkspace(_ id: WorkspaceID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = trimmed
        scheduleSave()
    }

    func promptRenameWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        openPrompt(title: "Rename workspace", initial: workspace.name) { [weak self] name in
            self?.renameWorkspace(id, to: name)
        }
    }

    func deleteWorkspace(_ id: WorkspaceID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if workspaces.count == 1 {
            // There's always a workspace to be in.
            workspaces.append(Workspace(name: Workspace.placeholderName))
        }
        let wasActive = id == activeID
        workspaces.remove(at: index)
        if wasActive {
            peekHasKeyboard = false
            layoutRegistry.peekFrame = nil
            find = nil
            activeID = workspaces[min(index, workspaces.count - 1)].id
            syncWatchRoots()
            enterActiveWorkspace()
        }
        collectGarbage()
        scheduleSave()
    }

    func confirmDeleteWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the workspace \u{201C}\(workspace.name)\u{201D}?"
        alert.informativeText = "Its terminals stop. Your files and folders aren't touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.deleteWorkspace(id) }
            }
        }
    }

    func addFolder(_ path: String, in workspaceID: WorkspaceID? = nil) {
        let target = workspaceID ?? activeID
        // Worked out first: looking through `workspaces` during the update below would crash.
        let name = uniqueName((path as NSString).lastPathComponent)
        update(workspace: target) { $0.adoptFolder(path, named: name) }
        if target == activeID { foldersChanged() }
    }

    func removeFolder(_ path: String, in workspaceID: WorkspaceID? = nil) {
        let target = workspaceID ?? activeID
        update(workspace: target) { $0.removeFolder(path) }
        if target == activeID { foldersChanged() }
    }

    private func foldersChanged() {
        editorBridge.writeLock()
        syncWatchRoots()
        enterActiveWorkspace()
    }

    func addFolderInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url.path) }
    }

    func importWorkspaceInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "code-workspace") {
            panel.allowedContentTypes = [type]
        }
        panel.message = "Choose a Cursor or VS Code .code-workspace file"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importWorkspace(url: url)
    }

    @discardableResult
    func importWorkspace(url: URL) -> Workspace? {
        do {
            let imported = try CodeWorkspaceImporter.read(fileAt: url)
            let existing = imported.folders.filter { FileManager.default.fileExists(atPath: $0) }
            if existing.count < imported.folders.count {
                let missing = imported.folders.count - existing.count
                showToast(title: "\(missing) folder\(missing == 1 ? "" : "s") not found",
                          detail: "Imported the rest of \(imported.name)", symbol: "exclamationmark.triangle", tint: .orange)
            }
            return createWorkspace(name: imported.name, folders: existing)
        } catch {
            showBanner("\(url.lastPathComponent): \(error)", isError: true)
            return nil
        }
    }

    func handleExternalOpen(_ url: URL) {
        if url.pathExtension == "code-workspace" {
            importWorkspace(url: url)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            openFolderAsWorkspace(url.path)
        } else {
            open(path: url.path, intent: .pinned)
            requestFocus()
        }
    }

    /// `tiri open <dir>` and dropping a folder on the dock icon. Reveal it if it's already here;
    /// fill an empty workspace; otherwise it gets a workspace of its own.
    func openFolderAsWorkspace(_ path: String) {
        if let existing = workspaces.first(where: { $0.folders.contains(path) }) {
            switchWorkspace(existing.id)
            return
        }
        if active.folder(containing: path) != nil {
            revealInTree(path)
            return
        }
        if active.folders.isEmpty {
            addFolder(path)
            return
        }
        createWorkspace(name: (path as NSString).lastPathComponent, folders: [path])
    }

    private func syncWatchRoots() {
        FileWatchHub.shared.setWorkspaceRoots(active.folders)
    }

    private func filesChanged(_ paths: [String]) {
        languageServers.filesChanged(paths)
        fileTree.filesChanged(paths)
        fileIndex.invalidate()
    }

    // MARK: Files

    func openExternally(path: String, line: Int? = nil, col: Int? = nil) {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"]
        for editor in settings.externalEditors {
            guard let executable = ExternalEditor.locate(editor, pathEnv: pathEnv) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ExternalEditor.arguments(editor: editor, path: path, line: line, col: col)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                return
            } catch {
                continue
            }
        }
        // None installed: the system's default app is better than nothing.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var activeFilePath: String? { active.activeItem?.filePath }

    func toggleMarkdownSource(_ id: ItemID? = nil) {
        guard let target = id ?? active.peek?.id ?? active.focused.active,
              let markdown = existingController(for: target) as? MarkdownController else { return }
        markdown.toggleSource()
        updateWorkspace(containing: target) { workspace in
            workspace.updateItem(target) { item in
                if case .file(var spec) = item.content {
                    spec.showSource = markdown.showingSource
                    item.content = .file(spec)
                }
            }
        }
        controllerRevision += 1
    }

    // MARK: Find

    func openFind() {
        guard let target = (peekHasKeyboard ? active.peek?.id : nil) ?? active.focused.active else { return }
        guard existingController(for: target)?.supportsFind == true else { return }
        var state = find ?? FindState(targetItem: target)
        state.targetItem = target
        state.focusNonce += 1
        if state.query.isEmpty, let selection = existingController(for: target)?.selectedTextForFind {
            state.query = selection
        }
        find = state
    }

    func closeFind() {
        if let target = find?.targetItem { existingController(for: target)?.clearFind() }
        find = nil
        requestFocus()
    }

    func runFind(backwards: Bool = false) {
        guard var state = find, let controller = existingController(for: state.targetItem) else { return }
        if state.query.isEmpty {
            controller.clearFind()
            state.notFound = false
        } else {
            state.notFound = !controller.find(state.query, backwards: backwards)
        }
        find = state
    }

    // MARK: Settings

    /// One Settings tab per workspace. Asking again goes back to it.
    func openSettings() {
        if let existing = active.items.first(where: { $0.content == .settings }) {
            focusItem(existing.id)
            return
        }
        updateActive { $0.addItem(Item(content: .settings), split: nil) }
        requestFocus()
    }

    /// Saves a change from the settings screen or `tiri settings set`, and applies it at once.
    /// Returns what went wrong, if anything.
    @discardableResult
    func setSetting(_ key: String, to value: JSONValue) -> String? {
        do {
            try settingsStore.write(key, value: value)
        } catch {
            showToast(title: "Couldn't change that setting", detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
            return "\(error)"
        }
        return nil
    }

    func resetSetting(_ key: String) {
        guard let definition = SettingsSchema.definition(for: key) else { return }
        setSetting(key, to: definition.value(TiriSettings()))
    }

    /// Sends the settings prompt to that agent if it's already running in this workspace, for you
    /// to read before pressing Return. Otherwise starts the agent with the prompt.
    func askAgentAboutSettings(preset: TerminalPreset) {
        askAgent(preset: preset, prompt: SettingsSchema.agentPrompt)
    }

    /// Into a running session of that agent, or a new one.
    func askAgent(preset: TerminalPreset, prompt: String) {
        let tool = preset.command.split(separator: " ").first.map(String.init) ?? preset.command
        let running = active.items.first { item in
            guard case .terminal(let spec) = item.content else { return false }
            let controller = existingController(for: item.id) as? TerminalController
            let running = AgentReference.agent(commandLine: controller?.foregroundCommandLine ?? [], command: spec.command)
            let wanted = AgentReference.agent(commandLine: [], command: tool)
            return running != nil && running == wanted
        }
        if let running, let terminal = existingController(for: running.id) as? TerminalController {
            focusItem(running.id)
            terminal.send(text: prompt)
            return
        }
        startTerminal(command: preset.command + " " + ShellQuote.quote(prompt), named: preset.name)
    }

    func openKeyboardShortcuts() {
        openSettings()
        settingsAnchor = SettingsView.shortcutsAnchor
    }

    /// The web page you're looking at: in the Peek if there is one, or else the focused tab.
    var frontWebController: WebController? {
        if let peek = active.peek { return existingController(for: peek.id) as? WebController }
        return active.focused.active.flatMap { existingController(for: $0) as? WebController }
    }

    // MARK: Separate windows

    /// Puts a tab in its own window, for another display. Its tab stays, saying where it went.
    func moveToNewWindow(_ id: ItemID) {
        guard detachedWindows[id] == nil, let item = anyItem(id), active.peek?.id != id else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title(for: item)
        window.tabbingMode = .disallowed
        let delegate = DetachedWindowDelegate(item: id, model: self)
        detachedDelegates[id] = delegate
        window.delegate = delegate
        detachedItems.insert(id)
        detachedWindows[id] = window
        window.contentView = NSHostingView(rootView: DetachedItemView(itemID: id).environment(self))
        if let main = self.window {
            window.setFrameOrigin(NSPoint(x: main.frame.minX + 60, y: main.frame.maxY - window.frame.height - 60))
        }
        window.makeKeyAndOrderFront(nil)
        controller(for: id)?.focus()
    }

    /// Back to its tab, in the main window.
    func bringBack(_ id: ItemID) {
        guard let window = detachedWindows.removeValue(forKey: id) else { return }
        detachedItems.remove(id)
        window.delegate = nil
        detachedDelegates[id] = nil
        window.close()
        window.contentView = nil
        if active.item(id) != nil {
            self.window?.makeKeyAndOrderFront(nil)
            focusItem(id)
        }
    }

    func showDetachedWindow(_ id: ItemID) {
        detachedWindows[id]?.makeKeyAndOrderFront(nil)
    }

    func detachedItem(of window: NSWindow) -> ItemID? {
        detachedWindows.first { $0.value === window }?.key
    }

    // MARK: Editing

    /// An edit in a Peek or a preview tab is something you mean to keep.
    func fileWasEdited(_ id: ItemID) {
        if active.peek?.id == id {
            promotePeek()
        } else {
            updateWorkspace(containing: id) { $0.pin(id) }
        }
    }

    var firstUnsavedFileName: String? {
        for (id, controller) in controllers where controller.isDirty {
            if let item = anyItem(id) { return title(for: item) }
        }
        return nil
    }

    func saveItem(_ id: ItemID) {
        if let controller = existingController(for: id) { save(controller) {} }
    }

    func saveFront() {
        guard let item = active.peek ?? active.activeItem, let controller = existingController(for: item.id) else { return }
        save(controller) {}
    }

    private func save(_ controller: ItemController, then done: @escaping () -> Void) {
        switch controller.save(overwriting: false) {
        case .saved:
            done()
        case .failed(let why):
            showToast(title: "Couldn't save", detail: why, symbol: "exclamationmark.triangle", tint: .orange)
        case .changedOnDisk:
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "This file changed on disk"
            alert.informativeText = "Something else, perhaps an agent, changed it after you started editing. Saving replaces that with what you have here."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn, case .saved = controller.save(overwriting: true) { done() }
                }
            }
        }
    }

    func saveAllEdits() -> Bool {
        for controller in controllers.values where controller.isDirty {
            guard case .saved = controller.save(overwriting: true) else { return false }
        }
        return true
    }

    // MARK: Search

    /// The files worth searching: what git counts as the project, which leaves out what
    /// .gitignore does, or else everything the explorer shows.
    func searchablePaths() async -> [String] {
        let folders = active.folders
        let excludes = ExcludeMatcher(patterns: settings.filesExclude)
        let openFiles = active.items.compactMap(\.filePath)
        return await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var result: [String] = []
            for folder in folders {
                let files = Git.projectFiles(in: folder)?.filter { path in
                    !path.dropFirst(folder.count + 1).split(separator: "/").contains { excludes.excludes(name: String($0)) }
                } ?? FileIndexer.walk(roots: [folder], excludes: excludes).map(\.path)
                for path in files where seen.insert(path).inserted { result.append(path) }
            }
            for path in openFiles where seen.insert(path).inserted { result.append(path) }
            return result
        }.value
    }

    /// Picks up what's selected, or where the last search left off.
    func openSearch() {
        let selected = (active.peek ?? active.activeItem).flatMap { existingController(for: $0.id)?.selectedTextForFind }
        palette = PaletteModel(mode: .search, model: self, initialQuery: selected ?? lastSearchQuery)
    }

    // MARK: Changes

    /// Anything changing under a folder can change the list, including a commit, so it's
    /// looked at again shortly after. One look at a time, and one more if more happened meanwhile.
    private func watchForChanges() {
        // Another workspace's changes shouldn't show here, even for a moment.
        if changesWorkspace != activeID {
            changesWorkspace = activeID
            changes = []
            turnChanges = []
            changesScope = .sinceCommit
            repositories = []
            repositoryTokens = [:]
        }
        changesTokens = active.folders.map { folder in
            FileWatchHub.shared.watch(path: folder, recursive: true) { [weak self] in self?.scheduleChangesRefresh() }
        }
        refreshChanges()
    }

    private func scheduleChangesRefresh() {
        changesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshChanges() }
        changesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refreshChanges() {
        guard !changesInFlight else {
            changesAgain = true
            return
        }
        changesInFlight = true
        let folders = active.folders
        let workspace = activeID
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Git.changesAcross(folders)
            let repositories = Git.repositoriesAcross(folders)
            await MainActor.run {
                guard let self else { return }
                self.changesInFlight = false
                self.refreshReviewLines()
                self.refreshTurnChanges()
                if self.activeID == workspace, self.changes != found { self.changes = found }
                if self.activeID == workspace { self.barHasRepositories = !repositories.isEmpty }
                if self.activeID == workspace, self.repositories != repositories {
                    self.repositories = repositories
                    self.watchGitDirectories(of: repositories, folders: folders)
                }
                // Whatever's on screen compares against the same new state.
                for item in self.active.items + (self.active.peek.map { [$0] } ?? []) {
                    if case .diff = item.content { (self.existingController(for: item.id) as? DiffController)?.load() }
                }
                if self.changesAgain || self.activeID != workspace {
                    self.changesAgain = false
                    self.refreshChanges()
                }
            }
        }
    }

    // MARK: Fetch, pull and push

    /// A commit or a push from a terminal moves the counts. When git's folder is outside the
    /// workspace, as for a subfolder of a repository or a worktree, nothing else would hear it.
    private func watchGitDirectories(of repositories: [RepositoryStatus], folders: [String]) {
        var tokens: [String: FileWatchHub.Token] = [:]
        for directory in repositories.flatMap(\.gitDirectories)
        where !folders.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) {
            tokens[directory] = repositoryTokens[directory]
                ?? FileWatchHub.shared.watch(path: directory, recursive: true) { [weak self] in self?.scheduleChangesRefresh() }
        }
        repositoryTokens = tokens
    }

    /// The repository of what you're looking at, for the palette. The status bar names its own.
    var frontRepository: RepositoryStatus? {
        let directory = defaultTerminalDirectory()
        return repositories.first { directory == $0.root || directory.hasPrefix($0.root + "/") } ?? repositories.first
    }

    func fetch(_ repository: RepositoryStatus) {
        guard let remote = repository.remote else {
            showToast(title: "Nothing to fetch from", detail: "\(repository.name) has no remote.", symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        transfer(.fetching, repository: repository, arguments: ["fetch", remote], failure: "Couldn't fetch") { [weak self] updated in
            guard let self else { return }
            let new = (updated?.behind ?? 0) - repository.behind
            let target = updated?.upstream ?? remote
            self.showToast(title: new > 0 ? "\(Self.commits(new)) to pull from \(target)" : "\(target) has nothing new", detail: nil,
                           symbol: "checkmark.circle.fill", tint: .green)
        }
    }

    /// Doesn't ask: it only moves the branch forward to commits the remote already has, and the
    /// way back is one `git reset`. Anything that would need a decision fails and says so.
    func pull(_ repository: RepositoryStatus) {
        guard repository.canPull, let target = repository.upstream else {
            showToast(title: "Nothing to pull from", detail: "\(repository.title) doesn't track a remote branch yet.", symbol: "checkmark.circle", tint: .secondary)
            return
        }
        transfer(.pulling, repository: repository, arguments: Git.pullArguments, failure: "Couldn't pull") { [weak self] updated in
            self?.showToast(title: updated?.shortOID == repository.shortOID ? "\(target) has nothing new" : "Pulled from \(target)", detail: nil,
                            symbol: "checkmark.circle.fill", tint: .green)
        }
    }

    /// Asks first, every time: it's the one thing here that can't be taken back, and some remotes deploy what they receive.
    func confirmPush(_ repository: RepositoryStatus) {
        guard let window else { return }
        guard repository.canPush || repository.canPublish, let branch = repository.branch else {
            showToast(title: "Nothing to push", detail: repository.remote == nil ? "\(repository.name) has no remote." : "\(repository.title) has no commits to send.",
                      symbol: "checkmark.circle", tint: .secondary)
            return
        }
        let target = repository.upstream ?? "\(repository.remote ?? "origin")/\(branch)"
        let alert = NSAlert()
        alert.messageText = repository.upstream == nil ? "Publish \(branch) to \(repository.remote ?? "origin")?" : "Push \(Self.commits(repository.ahead)) to \(target)?"
        var details = ["From \(repository.name)."]
        if repository.isDirty { details.append("Uncommitted changes stay here.") }
        if repository.behind > 0 { details.append("\(target) also has \(Self.commits(repository.behind)) you don't have, so it will probably refuse.") }
        alert.informativeText = details.joined(separator: " ")
        alert.addButton(withTitle: repository.upstream == nil ? "Publish" : "Push")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.transfer(.pushing, repository: repository, arguments: repository.pushArguments, failure: "Couldn't push") { [weak self] _ in
                    self?.showToast(title: repository.upstream == nil ? "Published to \(target)" : "Pushed \(Self.commits(repository.ahead)) to \(target)",
                                    detail: nil, symbol: "checkmark.circle.fill", tint: .green)
                }
            }
        }
    }

    private static func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }

    private func transfer(_ kind: RepositoryTransfer, repository: RepositoryStatus, arguments: [String], failure: String,
                          succeeded: @escaping @MainActor @Sendable (RepositoryStatus?) -> Void) {
        let root = repository.root
        guard repositoryTransfers[root] == nil else { return }
        repositoryTransfers[root] = kind
        let shell = settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : settings.terminalShell
        let known = userPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let path: String?
            if let known { path = known } else { path = await ShellLookup.path(shell: shell) }
            let result = Git.transfer(arguments, in: root, path: path)
            let updated = Git.repositoryStatus(of: root)
            await MainActor.run {
                guard let self else { return }
                self.userPath = path ?? self.userPath
                self.repositoryTransfers[root] = nil
                if let updated, let index = self.repositories.firstIndex(where: { $0.root == root }) { self.repositories[index] = updated }
                switch result {
                case .success:
                    succeeded(updated)
                case .failure(let problem):
                    // A remote that wants a password can get one in a terminal, which this can't do.
                    self.showToast(title: failure, detail: problem.message, symbol: "exclamationmark.triangle", tint: .orange,
                                   actionTitle: "Open Terminal") { [weak self] in self?.newTerminal(cwd: root) }
                }
            }
        }
    }

    func openDiff(path: String, preview: Bool, turn: String? = nil) {
        updateActive { $0.dismissPeek(); $0.openDiff(path: path, preview: preview, turn: turn) }
        requestFocus()
    }

    /// Takes the Peek's place. With `takeFocus`, a person asked. Without it, an agent is showing something.
    func peekDiff(path: String, takeFocus: Bool, turn: String? = nil) {
        updateActive { $0.peekDiff(path: path, turn: turn) }
        peekHasKeyboard = takeFocus
        requestFocus()
    }

    /// Switch between a file and what changed in it, wherever it's showing.
    func toggleChangesForFront() {
        guard let item = active.peek ?? active.activeItem else { return }
        let isPeek = active.peek?.id == item.id
        switch item.content {
        case .file(let spec):
            if isPeek { peekDiff(path: spec.path, takeFocus: true) } else { openDiff(path: spec.path, preview: false) }
        case .diff(let spec):
            if isPeek {
                updateActive { $0.peekFile(path: spec.path, revealExisting: false) }
                peekHasKeyboard = true
                requestFocus()
            } else {
                open(path: spec.path, intent: .pinned)
                requestFocus()
            }
        default:
            break
        }
    }

    func hasChanges(_ path: String) -> Bool {
        changes.contains { $0.path == path }
    }

    // MARK: Agent hooks

    func hooksInstalled(_ tool: AgentHooks.Tool) -> Bool {
        _ = hooksRevision
        let text = (try? String(contentsOf: AgentHooks.configURL(for: tool), encoding: .utf8)) ?? ""
        return AgentHooks.isInstalled(tool, in: text)
    }

    /// These are the agent's own files, so nothing changes until you say yes here.
    func confirmHooks(_ tool: AgentHooks.Tool, install: Bool) {
        guard let window else { return }
        let url = AgentHooks.configURL(for: tool)
        let alert = NSAlert()
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        if install {
            alert.messageText = "Tell Tiri exactly what \(tool.title) is doing?"
            alert.informativeText = "Tiri adds a small hook to \(path), and keeps a copy of the file next to it. The hook does nothing outside Tiri.\n\n" + AgentHooks.summary(of: tool)
            alert.addButton(withTitle: "Install")
        } else {
            alert.messageText = "Remove Tiri's hooks from \(tool.title)?"
            alert.informativeText = "Tiri takes its entries out of \(path) and leaves the rest. Status goes back to an estimate."
            alert.addButton(withTitle: "Remove")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.applyHooks(tool, install: install) }
            }
        }
    }

    private func applyHooks(_ tool: AgentHooks.Tool, install: Bool) {
        let url = AgentHooks.configURL(for: tool)
        let manager = FileManager.default
        do {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = install ? try AgentHooks.installing(tool, in: text) : try AgentHooks.removing(tool, from: text)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("tiri-backup")
                try? manager.removeItem(at: backup)
                try manager.copyItem(at: url, to: backup)
            }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            hooksRevision += 1
            showToast(title: install ? "\(tool.title) hooks are on" : "\(tool.title) hooks are off",
                      detail: install ? "New \(tool.title) sessions report their status exactly." : nil,
                      symbol: "checkmark.circle.fill", tint: .green)
        } catch {
            showToast(title: "Couldn't change \(tool.title)'s config", detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    /// Once, the first time an agent runs without hooks. Dismissing it is an answer.
    func offerHooksIfNeeded(_ tool: AgentHooks.Tool) {
        let key = "offeredHooks.\(tool.rawValue)"
        guard !UserDefaults.standard.bool(forKey: key), !hooksInstalled(tool) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showToast(title: "Get exact status from \(tool.title)?", detail: "Right now Tiri is estimating when it's working or done.",
                  symbol: "waveform.path.ecg", tint: .accentColor, actionTitle: "Set Up") { [weak self] in
            self?.confirmHooks(tool, install: true)
        }
    }

    // MARK: What's installed

    /// The first word of each New Terminal preset that the user's shell can run. Nil until the
    /// shell has answered, or if it didn't, so nothing is hidden on a guess.
    private(set) var availableCommands: Set<String>?
    private var isLookingUpCommands = false

    func agentPresets() -> [TerminalPreset] {
        settings.terminalPresets.filter { !$0.command.isEmpty }
    }

    static func tool(of preset: TerminalPreset) -> String {
        preset.command.split(separator: " ").first.map(String.init) ?? preset.command
    }

    /// Agents that can start, as far as anyone knows. Commands that aren't plain names can't be asked about.
    func runnableAgentPresets() -> [TerminalPreset] {
        guard let availableCommands else { return agentPresets() }
        return agentPresets().filter {
            let tool = Self.tool(of: $0)
            return availableCommands.contains(tool) || !ShellLookup.isPlainName(tool)
        }
    }

    /// Called while the screen that needs it is up, including on coming back from installing one.
    func refreshAvailableCommands() {
        guard !isLookingUpCommands else { return }
        let names = agentPresets().map(Self.tool(of:)) + ["tiri"]
        if let availableCommands, availableCommands.isSuperset(of: names) { return }
        isLookingUpCommands = true
        let shell = settings.terminalShell.isEmpty
            ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            : settings.terminalShell
        Task {
            let found = await ShellLookup.run(names: names, shell: shell)
            isLookingUpCommands = false
            availableCommands = found
        }
    }

    // MARK: The tiri command

    var commandLineLink: URL { CommandLineTool.link() }

    var bundledCommandLineTool: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/tiri")
    }

    func commandLineState() -> CommandLineTool.State {
        _ = hooksRevision
        guard let bundled = bundledCommandLineTool else { return .notInstalled }
        return CommandLineTool.state(link: commandLineLink, bundled: bundled)
    }

    /// Your home folder, so nothing changes until you say yes here.
    func confirmCommandLineTool(install: Bool) {
        guard let window, let bundled = bundledCommandLineTool else { return }
        if install, let problem = CommandLineTool.problem(appPath: Bundle.main.bundlePath) {
            showToast(title: "Can't install the tiri command yet", detail: problem, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        let link = commandLineLink
        let path = (link.path as NSString).abbreviatingWithTildeInPath
        let replacing = commandLineState() == .otherFile
        let alert = NSAlert()
        if install {
            alert.messageText = "Use tiri in your other terminals?"
            alert.informativeText = "Tiri adds a link at \(path). It follows the app when you update, and Settings can remove it."
                + (replacing ? "\n\nThis replaces the file already at that path." : "")
            alert.addButton(withTitle: replacing ? "Replace" : "Install")
        } else {
            alert.messageText = "Remove the tiri command?"
            alert.informativeText = "Tiri removes the link at \(path). Terminals inside Tiri keep their own."
            alert.addButton(withTitle: "Remove")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                do {
                    if install {
                        try CommandLineTool.install(link: link, bundled: bundled)
                    } else {
                        try CommandLineTool.remove(link: link)
                    }
                    self.hooksRevision += 1
                    if install { self.reportCommandLineInstalled(link: link) }
                } catch {
                    self.showToast(title: "Couldn't change the tiri command", detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
                }
            }
        }
    }

    /// Tiri doesn't edit shell setup files, so if the folder isn't on the PATH, it says what to add.
    private func reportCommandLineInstalled(link: URL) {
        let shell = settings.terminalShell.isEmpty
            ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            : settings.terminalShell
        Task {
            let found = await ShellLookup.run(names: ["tiri"], shell: shell)
            if found?.contains("tiri") == false {
                let line = "export PATH=\"$HOME/.local/bin:$PATH\""
                showToast(title: "One more step for the tiri command",
                          detail: "Your shell doesn't look in ~/.local/bin yet. Copy this line into its setup file.",
                          symbol: "terminal", tint: .accentColor, actionTitle: "Copy Line") { Clipboard.copy(line) }
            } else {
                showToast(title: "tiri works in your other terminals", detail: "New terminals will have it.",
                          symbol: "checkmark.circle.fill", tint: .green)
            }
        }
    }

    // MARK: Keyboard shortcuts

    /// Saves a shortcut, or removes it if the key is nil. Returns why it couldn't, if it couldn't.
    @discardableResult
    func setShortcut(_ command: String, key: String?) -> String? {
        if let key, let problem = Keymap.problem(with: key, command: command, bindings: keybindings) {
            showToast(title: "That shortcut won't work", detail: problem, symbol: "keyboard", tint: .orange)
            return problem
        }
        let strokes = key.flatMap(Keymap.parseStrokes)
        let previous = keybindings.first { $0.strokes == strokes && $0.command != command }
        do {
            try settingsStore.writeKeybindings(Keymap.rebound(user: settingsStore.userKeybindings, command: command, key: key))
        } catch {
            return "\(error)"
        }
        if let previous {
            let title = allCommands.first { $0.id == previous.command }?.title ?? previous.command
            showToast(title: "\(previous.symbol) was \(title)", detail: "That command has no shortcut on this key now.", symbol: "keyboard", tint: .secondary)
        }
        return nil
    }

    @discardableResult
    func resetShortcut(_ command: String) -> String? {
        do {
            try settingsStore.writeKeybindings(Keymap.reset(user: settingsStore.userKeybindings, command: command))
            return nil
        } catch {
            return "\(error)"
        }
    }

    func shortcutIsCustom(_ command: String) -> Bool {
        settingsStore.userKeybindings.contains { $0.command == command || $0.command == "-" + command }
    }

    func beginRecordingShortcut(for command: String) {
        recordingWork?.cancel()
        recordedStrokes = []
        keyResolver.reset()
        recordingShortcutFor = command
    }

    func cancelRecordingShortcut() {
        recordingWork?.cancel()
        recordedStrokes = []
        recordingShortcutFor = nil
    }

    /// One press makes a shortcut. A second within a moment makes it a chord like ⌘K ⌘S.
    func recordKey(_ stroke: KeyStroke) {
        guard let command = recordingShortcutFor else { return }
        recordingWork?.cancel()
        if stroke.modifiers.isEmpty, stroke.key == "escape" {
            cancelRecordingShortcut()
            return
        }
        if stroke.modifiers.isEmpty, stroke.key == "backspace" || stroke.key == "delete", recordedStrokes.isEmpty {
            cancelRecordingShortcut()
            setShortcut(command, key: nil)
            return
        }
        recordedStrokes.append(stroke)
        if recordedStrokes.count == 2 {
            finishRecording()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.finishRecording() }
        recordingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func finishRecording() {
        guard let command = recordingShortcutFor else { return }
        let key = recordedStrokes.map(\.description).joined(separator: " ")
        cancelRecordingShortcut()
        if !key.isEmpty { setShortcut(command, key: key) }
    }

    private func applySettings() {
        let previous = settings
        settings = settingsStore.settings
        if previous.languageServers, !settings.languageServers { languageServers.stopAll() }
        rebuildKeybindings()
        if let error = settingsStore.currentError {
            banner = AppBanner(message: error, isError: true)
        } else if banner?.isError == true {
            banner = nil
        }
        guard previous != settings else { return }
        applyTheme()
        for controller in controllers.values { controller.applySettings() }
        if previous.filesExclude != settings.filesExclude {
            FileWatchHub.shared.excludedNames = Set(settings.filesExclude)
            fileTree.bind(active)
            fileIndex.invalidate()
        }
    }

    private func rebuildKeybindings() {
        keybindings = Keymap.build(user: settingsStore.userKeybindings)
        keyResolver = KeyResolver(bindings: keybindings)
    }

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setTheme(_ mode: ThemeMode) {
        settingsStore.writeTheme(mode)
        settings.theme = mode
        applyTheme()
        // Writing the file won't reach them: by the time it reloads, nothing looks changed.
        for controller in controllers.values { controller.applySettings() }
    }

    /// An explicit theme is known immediately. Following the system asks the system, which is
    /// why `systemAppearanceRevision` exists: reading it makes views update when the system flips.
    var effectiveDark: Bool {
        switch settings.theme {
        case .light: return false
        case .dark: return true
        case .system:
            _ = systemAppearanceRevision
            let name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            return name == "Dark"
        }
    }

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemAppearanceRevision += 1
                for controller in self.controllers.values { controller.applySettings() }
            }
        }
    }

    /// What can be forced dark: web pages, PDFs and Office files. Everything else already follows the theme.
    func forceDarkController(for id: ItemID) -> ForceDarkCapable? {
        guard let controller = existingController(for: id) as? ForceDarkCapable, controller.supportsForceDark else { return nil }
        return controller
    }

    func setForceDark(_ on: Bool, item: ItemID?) {
        if let item {
            forceDarkController(for: item)?.setForceDark(on)
            updateWorkspace(containing: item) { workspace in
                workspace.updateItem(item) { item in
                    switch item.content {
                    case .web(var spec):
                        spec.forceDark = on
                        item.content = .web(spec)
                    case .file(var spec):
                        spec.forceDark = on
                        item.content = .file(spec)
                    case .terminal, .settings, .diff:
                        break
                    }
                }
            }
        } else {
            for id in controllers.keys { forceDarkController(for: id)?.setForceDark(on) }
        }
        controllerRevision += 1
    }

    // MARK: Banners and toasts

    func showBanner(_ message: String, isError: Bool) {
        banner = AppBanner(message: message, isError: isError)
    }

    func showToast(title: String, detail: String?, symbol: String, tint: Color,
                   actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = AppToast(title: title, detail: detail, symbol: symbol, tint: tint, actionTitle: actionTitle, action: action)
        withAnimation(.smooth(duration: 0.25)) {
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, id = toast.id] in
            self?.dismissToast(id)
        }
    }

    func dismissToast(_ id: UUID) {
        withAnimation(.smooth(duration: 0.2)) {
            toasts.removeAll { $0.id == id }
        }
    }

    func showAgentGuide() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tiri Agent Guide.md")
        try? AgentGuide.markdown.write(to: url, atomically: true, encoding: .utf8)
        open(path: url.path, intent: .pinned)
    }

    // MARK: Palette

    func openPalette(_ mode: PaletteModel.Mode) {
        palette = PaletteModel(mode: mode, model: self)
    }

    func closePalette(restoreFocus: Bool = true) {
        palette = nil
        if restoreFocus { requestFocus() }
    }

    func openPrompt(title: String, initial: String, commit: @escaping (String) -> Void) {
        palette = PaletteModel(mode: .prompt(title: title, commit: commit), model: self, initialQuery: initial)
    }

    // MARK: Commands

    func firstSingleStrokeBinding(for id: String) -> KeyStroke? {
        keybindings.first { $0.command == id && $0.strokes.count == 1 }?.strokes.first
    }

    func shortcutSymbol(for id: String) -> String? {
        keybindings.first { $0.command == id }?.symbol
    }
}

enum ProcessClock {
    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// Wall-clock time since the kernel started this process.
    static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// The same number Activity Monitor calls Memory.
    static func footprintMegabytes(pid: pid_t = getpid()) -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(info.ri_phys_footprint) / 1_048_576
    }
}

/// Native notifications, which focus the right terminal when clicked.
final class Notifier: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private var onClick: ((WorkspaceID, ItemID) -> Void)?

    func configure(onClick: @escaping (WorkspaceID, ItemID) -> Void) {
        self.onClick = onClick
        // UNUserNotificationCenter needs a real bundle. It throws when run as a bare binary.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, subtitle: String, workspace: WorkspaceID, item: ItemID) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["workspace": workspace, "item": item]
        let request = UNNotificationRequest(identifier: "\(item)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let workspace = info["workspace"] as? String, let item = info["item"] as? String {
            onClick?(workspace, item)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // While Tiri is in front, its in-app toast does this job.
        completionHandler([])
    }
}

/// Settings and keybindings files, watched and reloaded live.
final class SettingsStore {
    private(set) var settings = TiriSettings()
    private(set) var userKeybindings: [(key: String, command: String)] = []
    private(set) var currentError: String?
    var onChange: (() -> Void)?

    let settingsURL = TiriPaths.configDirectory.appendingPathComponent("settings.json")
    let keybindingsURL = TiriPaths.configDirectory.appendingPathComponent("keybindings.json")
    private var tokens: [FileWatchHub.Token] = []
    private var settingsError: String?
    private var keybindingsError: String?

    func start() {
        ensureFilesExist()
        reload()
        tokens = [
            FileWatchHub.shared.watch(path: settingsURL.path) { [weak self] in self?.fileChanged() },
            FileWatchHub.shared.watch(path: keybindingsURL.path) { [weak self] in self?.fileChanged() },
        ]
    }

    func ensureFilesExist() {
        let manager = FileManager.default
        try? manager.createDirectory(at: TiriPaths.configDirectory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: settingsURL.path) {
            try? TiriSettings.defaultFileContents.write(to: settingsURL, atomically: true, encoding: .utf8)
        }
        if !manager.fileExists(atPath: keybindingsURL.path) {
            try? Keymap.defaultFileContents.write(to: keybindingsURL, atomically: true, encoding: .utf8)
        }
    }

    private func fileChanged() {
        reload()
        onChange?()
    }

    private func reload() {
        // Any failure keeps the last good values, and the app says so without getting in the way.
        if let text = try? String(contentsOf: settingsURL, encoding: .utf8) {
            do {
                settings = try TiriSettings.parse(text)
                settingsError = nil
            } catch {
                settingsError = "settings.json: \(error). Using the last good settings."
            }
        }
        if let text = try? String(contentsOf: keybindingsURL, encoding: .utf8) {
            do {
                userKeybindings = try Keymap.parseUserFile(text)
                keybindingsError = nil
            } catch {
                keybindingsError = "keybindings.json: \(error). Using the last good keybindings."
            }
        }
        currentError = settingsError ?? keybindingsError
    }

    /// Checks the result parses before saving, so a change can't break the file, then applies it.
    func write(_ key: String, value: JSONValue) throws {
        ensureFilesExist()
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? TiriSettings.defaultFileContents
        let updated = SettingsFile.setting(key, toJSON: SettingsSchema.json(value), in: text)
        _ = try TiriSettings.parse(updated)
        try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        fileChanged()
    }

    func writeKeybindings(_ list: [(key: String, command: String)]) throws {
        ensureFilesExist()
        try Keymap.fileContents(user: list).write(to: keybindingsURL, atomically: true, encoding: .utf8)
        fileChanged()
    }

    func writeTheme(_ mode: ThemeMode) {
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? TiriSettings.defaultFileContents
        try? SettingsFile.setting("theme", to: mode.rawValue, in: text).write(to: settingsURL, atomically: true, encoding: .utf8)
    }
}

/// The background file list behind quick open.
final class FileIndexStore {
    private(set) var files: [IndexedFile] = [] {
        didSet { byName = nil }
    }
    private var byName: [String: [String]]?
    private var dirty = true
    private var building = false
    private var generation = 0
    private var latest: (roots: [String], excludes: ExcludeMatcher)?
    private var indexedRoots: [String]?
    private var waiting: [() -> Void] = []
    var onUpdate: (() -> Void)?

    func invalidate() {
        dirty = true
        generation += 1
    }

    func paths(named name: String) -> [String] {
        if byName == nil {
            byName = Dictionary(grouping: files, by: \.name).mapValues { $0.map(\.path) }
        }
        return byName?[name] ?? []
    }

    /// Runs now if the index is up to date, or else when the walk underway finishes.
    func whenReady(_ block: @escaping () -> Void) {
        if building { waiting.append(block) } else { block() }
    }

    /// For roots that change on their own, with no file watcher to say so.
    func ensure(roots: [String], excludes: ExcludeMatcher) {
        if roots != indexedRoots {
            indexedRoots = roots
            invalidate()
        }
        refreshIfNeeded(roots: roots, excludes: excludes)
    }

    func refreshIfNeeded(roots: [String], excludes: ExcludeMatcher) {
        // Whatever is asked for last wins, even if a walk of some other folder is still going.
        latest = (roots, excludes)
        guard dirty, !building else { return }
        dirty = false
        building = true
        let currentGeneration = generation
        Task.detached(priority: .userInitiated) {
            let files = FileIndexer.walk(roots: roots, excludes: excludes)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.building = false
                if self.generation == currentGeneration {
                    self.files = files
                    self.onUpdate?()
                    let ready = self.waiting
                    self.waiting = []
                    ready.forEach { $0() }
                } else if let latest = self.latest {
                    // Things changed during the walk. Its result may be for another workspace.
                    self.refreshIfNeeded(roots: latest.roots, excludes: latest.excludes)
                }
            }
        }
    }
}
