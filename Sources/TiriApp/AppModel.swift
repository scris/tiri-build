import AppKit
import Observation
import SwiftUI
import TiriCore
import TiriHighlight
import UniformTypeIdentifiers
import UserNotifications

enum TerminalStatus: String {
    case idle, working, needsInput = "needs-input", done, exited

    /// What VoiceOver says for it, where the screen shows only an icon or a color.
    var spoken: String? {
        switch self {
        case .idle: nil
        case .working: String(localized: "Working")
        case .needsInput: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .exited: String(localized: "Exited")
        }
    }
}

struct TerminalRuntime: Equatable {
    var status: TerminalStatus = .idle
    var message: String?
    /// Something happened here that the user hasn't looked at yet.
    var unseen = false
    var title: String?
    var exitCode: Int32?
    /// What it was last asked, what it just did, and what it's changed this turn.
    var prompt: String?
    var activity: String?
    var touched: [String] = []
    /// When it last started working; nil whenever it isn't.
    var workingSince: Date?
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
                // macOS refusing is EPERM. EACCES is the file's own permissions, which Privacy & Security can't help with.
                return errno == EPERM
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
    /// A quieter second choice, shown before the main one.
    var otherTitle: String?
    var otherAction: (() -> Void)?
    /// Closing it with its ✕, for a question where that's an answer too.
    var closed: (() -> Void)?
}

struct FindState: Equatable {
    var query = ""
    var targetItem: ItemID
    var notFound = false
    var focusNonce = 0
    var showReplace = false
    var replacement = ""
    var caseSensitive = false
    var current = 0
    var total: Int?
    var replacedCount: Int?
    var replaceFocusNonce = 0
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

    /// Workspaces on servers.
    @ObservationIgnored lazy var remote = RemoteManager(model: self)

    var workspaces: [Workspace] = [] {
        didSet { plugins.editorEvents.workspaceMaybeChanged(plugins) }
    }
    var activeID: WorkspaceID = "" {
        didSet { plugins.editorEvents.workspaceMaybeChanged(plugins) }
    }
    var settings = TiriSettings()
    var keybindings: [Keybinding] = Keymap.build(user: [])
    var agentRows: [AgentOverviewRow] = []
    @ObservationIgnored private var agentRowsPending = false
    var runtimes: [ItemID: TerminalRuntime] = [:] { didSet { scheduleAgentRows() } }
    var banner: AppBanner? {
        didSet {
            // It appears where the keyboard isn't, so VoiceOver is told.
            if let banner, banner.message != oldValue?.message { AccessibilityDisplay.shared.announce(banner.message) }
        }
    }
    var toasts: [AppToast] = []
    /// What a test copy would have opened in a browser, instead of opening it.
    @ObservationIgnored var sentToBrowser: [String] = []
    /// Sites whose sign-in page already brought an offer of the browser, so it's made once. See `offerBrowser`.
    @ObservationIgnored var offeredBrowserFor: Set<String> = []
    /// Themes someone brought in or made, from the themes folder. The built-in ones are `Theme.builtIns`.
    var userThemes: [Theme] = []
    /// The theme showing now, for the look it's for.
    var activeTheme: Theme = .tiriDark
    var activeThemeSlot: ThemeSlot = .dark
    /// Increase Contrast, from Accessibility settings.
    var increaseContrast: Bool { AccessibilityDisplay.shared.increaseContrast }
    var find: FindState?
    var tabDrag: TabDragState?
    var palette: PaletteModel?
    var sidebarVisibility: NavigationSplitViewVisibility = .all {
        didSet { if oldValue != sidebarVisibility { holdItemSizes() } }
    }
    @ObservationIgnored var lastSwitchMilliseconds: Double?
    @ObservationIgnored private var itemSizesHeld = 0
    var peekHasKeyboard = false
    /// Files something is waiting on, like `git commit` or Claude Code's Ctrl-G through `tiri open --wait`.
    /// Closing one hands it back, so it offers Done instead of Open as Tab.
    var waitingFor: Set<ItemID> = []
    /// Files a `tiri://` link opened outside every workspace. See `openLink`.
    @ObservationIgnored var linkOnlyFiles: Set<String> = []
    @ObservationIgnored lazy var notebookKernels = NotebookKernels(model: self)
    var systemAppearanceRevision = 0
    /// Bumped when something outside SwiftUI's view (a controller) changed what headers show.
    var controllerRevision = 0

    @ObservationIgnored var keyResolver = KeyResolver(bindings: Keymap.build(user: []))
    @ObservationIgnored let layoutRegistry = LayoutRegistry()
    @ObservationIgnored let settingsStore = SettingsStore()
    /// The offer to restart in another language, while it shows.
    @ObservationIgnored var languageToastID: UUID?
    @ObservationIgnored let fileIndex = FileIndexStore()
    @ObservationIgnored let terminalFolderIndex = FileIndexStore()
    @ObservationIgnored lazy var editorBridge = EditorBridge(model: self)
    @ObservationIgnored var lastAgentTerminal: ItemID?
    var turns: [AgentTurn] = []
    /// Each terminal's files when an agent was first seen in it, for an agent whose hooks only say when it stops.
    @ObservationIgnored var turnBaselines: [ItemID: (started: Date, trees: [String: String])] = [:]
    @ObservationIgnored var conversationsLoaded: [ConversationSummary]?
    @ObservationIgnored var conversationsLoading = false
    @ObservationIgnored var conversationIndex: ConversationIndex?
    @ObservationIgnored var conversationsIndexing = false
    @ObservationIgnored var conversationIndexing: Task<Void, Never>?
    /// Titles the Mac's model has written, by file.
    @ObservationIgnored var conversationLabels: [String: (label: String, seconds: Int)]?
    @ObservationIgnored var agentTitles: [ItemID: String] = [:]
    /// What a person typed to start it, which says it better than a summary of those words, until it's moved on.
    @ObservationIgnored var agentAsked: [ItemID: String] = [:]
    @ObservationIgnored var agentTitlesAsked: [ItemID: Int] = [:]
    @ObservationIgnored var agentTitlesWanted: [ItemID] = []
    @ObservationIgnored var agentTitler: Task<Void, Never>?
    @ObservationIgnored var lastAgentConversationLook = 0.0
    @ObservationIgnored var conversationsWantingLabels: [ConversationSummary] = []
    @ObservationIgnored var conversationLabeler: Task<Void, Never>?
    @ObservationIgnored var conversationSummarizing: Task<Void, Never>?
    /// How far summarizing everything has got, for Settings.
    var conversationsSummarized: (done: Int, total: Int)?
    /// A look that's under way, and where, so that asking again joins it rather than starting another.
    @ObservationIgnored var conversationLook: (place: String?, task: Task<[ConversationSummary], Never>)?
    @ObservationIgnored private var watchTicks = 0
    @ObservationIgnored let snapshots = TurnSnapshots()
    @ObservationIgnored let turnStore = TurnStore()
    var navigationStops: [NavigationStop] = []
    @ObservationIgnored var symbolHover: (view: NSTextView?, range: NSRange)?
    var languageRevision = 0
    @ObservationIgnored lazy var languageServers = LanguageServerHub(model: self)
    @ObservationIgnored lazy var runner = FileRunner(model: self)
    @ObservationIgnored lazy var starter = FolderStarter(model: self)
    @ObservationIgnored lazy var plugins = PluginHost(model: self)
    @ObservationIgnored lazy var yourTiri = YourTiriModel(model: self)
    /// The app is about to come straight back, so no terminal ends, whatever the setting says.
    @ObservationIgnored var keepTerminalsThroughQuit = false
    /// Your Tiri has no place in Settings until someone has used it.
    var settingsPanes: [SettingsPane] { SettingsPane.allCases.filter { $0 != .yourTiri || yourTiri.isUsed || yourTiri.entriesAreOn } }
    @ObservationIgnored let commands = CommandRegistry(builtIn: AppModel.staticCommands)
    @ObservationIgnored let languageTrust = LanguageServerTrust()
    @ObservationIgnored var hoverPopover: NSPopover?
    @ObservationIgnored var hoverWork: DispatchWorkItem?
    @ObservationIgnored var reviewPopover: NSPopover?
    @ObservationIgnored var reviewPopoverCloser: NSObjectProtocol?
    /// Fetches and pushes under way, by repository.
    var repositoryTransfers: [String: RepositoryTransfer] = [:]
    @ObservationIgnored var userPath: String? {
        didSet {
            DeveloperTools.shellPath = userPath
            // A git that only the shell knows about.
            if needsGit, userPath != oldValue { refreshChanges() }
        }
    }
    var detachedItems: Set<ItemID> = []
    @ObservationIgnored private var detachedWindows: [ItemID: NSWindow] = [:]
    @ObservationIgnored private var detachedDelegates: [ItemID: DetachedWindowDelegate] = [:]
    /// Which workspace each window shows. `WindowPlan.main` is the first window; see WorkspaceWindows.swift.
    var windowWorkspaces: [String: WorkspaceID] = [:]
    /// The window in front, whose workspace is `activeID`.
    var currentWindow = WindowPlan.main
    /// What's been worked out about each workspace in a window. Views read it while drawing, and `live(_:)` adds to
    /// it then, so the storage isn't observed: changing observed state mid-draw makes SwiftUI abort. What's added is
    /// told to views a moment later, through `livesRevision`.
    var lives: [WorkspaceID: WorkspaceLive] {
        get {
            _ = livesRevision
            return livesStorage
        }
        set { livesStorage = newValue }
    }
    @ObservationIgnored var livesStorage: [WorkspaceID: WorkspaceLive] = [:]
    /// Workspaces whose status bar has shown. It stays, for as long as Tiri's open: a bar that comes and goes as the
    /// keyboard moves between a file and a terminal makes the window jump. Kept apart from `lives`, which a workspace
    /// switch lets go of. Added to while the bar draws, when it's already showing, so it isn't observed.
    @ObservationIgnored var workspacesWithBar: Set<WorkspaceID> = []
    var livesRevision = 0
    @ObservationIgnored var windowOrder: [String] = []
    @ObservationIgnored var workspaceWindows: [String: NSWindow] = [:]
    @ObservationIgnored var windowObservers: [String: [NSObjectProtocol]] = [:]
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored var windowsToRestore: [SavedWindow] = []
    @ObservationIgnored var pendingFrames: [String: [Double]] = [:]
    @ObservationIgnored var sidebarVisibilities: [String: NavigationSplitViewVisibility] = [:]
    @ObservationIgnored var lastSearchQuery = ""
    var recordingShortcutFor: String?
    var hooksRevision = 0
    /// Offers of hooks already up, or pushed out by newer toasts, so one isn't made twice in a launch.
    @ObservationIgnored var hooksOfferedThisLaunch: Set<String> = []
    let settingsUI = SettingsNavigation()
    /// What's been pressed so far, for the row to show.
    private(set) var recordedStrokes: [KeyStroke] = []
    /// What came of a recording that didn't simply work, shown on the command's own row.
    var shortcutNotice: ShortcutNotice?
    /// The next key press is what to look for in the list of shortcuts.
    private(set) var isFindingShortcutKey = false
    @ObservationIgnored private var recordingWork: DispatchWorkItem?
    @ObservationIgnored var skipQuitConfirmation = false
    @ObservationIgnored var launchMilliseconds: Double?
    @ObservationIgnored var lastOpenMilliseconds: Double?
    @ObservationIgnored private var openInFlight: (item: ItemID, started: Double)?
    @ObservationIgnored var groupHosts: [GroupID: WeakView] = [:]
    @ObservationIgnored private var controllers: [ItemID: ItemController] = [:]
    @ObservationIgnored var restoredItems: Set<ItemID> = []
    /// Tabs of a closed workspace: their unsaved edits wait for it to be reopened.
    @ObservationIgnored var keptEdits: Set<ItemID> = []
    /// Workspaces closed, and folders used lately elsewhere: File → Open Recent.
    let recents = RecentWorkspaces()
    /// Terminals whose agent's status came back from disk, until their controller is made.
    @ObservationIgnored var restoredAgentStatus: Set<ItemID> = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored let router = EventRouter()
    @ObservationIgnored private let store = WorkspaceStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var didFinishLaunching = false
    /// Nothing saved from before: the very first launch, which is the one that says hello.
    @ObservationIgnored private var isNewInstall = false
    /// Some saved state couldn't be read, so what came back is the last good copy of it.
    @ObservationIgnored private var stateWasDamaged = false
    @ObservationIgnored private var toldNewerFormat = false
    @ObservationIgnored private var checkedPaths: Set<String> = []
    @ObservationIgnored private var tabDragCommitted = false

    struct WeakView { weak var view: NSView? }

    // MARK: Lifecycle

    private init() {
        var savedWindows: [SavedWindow] = []
        let loaded = store.loadRecovering()
        stateWasDamaged = loaded.damaged
        if let snapshot = loaded.snapshot, !snapshot.workspaces.isEmpty {
            workspaces = snapshot.workspaces
            activeID = snapshot.activeID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil } ?? workspaces[0].id
            savedWindows = snapshot.windows
            // Everything that was running comes back as a fresh process.
            for workspace in workspaces {
                for item in workspace.items {
                    if case .terminal = item.content { restoredItems.insert(item.id) }
                }
            }
        } else {
            // Saved state that couldn't be read isn't a new install: nobody needs welcoming.
            isNewInstall = !loaded.damaged
            // Nothing runs until you've said where: see `startTerminal`.
            let first = Workspace(name: Workspace.placeholderName)
            workspaces = [first]
            activeID = first.id
        }
        prepareWindows(saved: savedWindows)
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
        // Before the first frame, so an agent still working never shows as idle.
        restoreAgentStatus(finished: false)
    }

    func finishLaunching() {
        startWatchingAgents()
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        BlockedLinks.install()
        if !SafeStart.isOn { updateSummarizingAll() }
        // Another Tiri has these workspaces. Attaching to a terminal takes it from whoever has it, so
        // this one touches nothing, and brings that one forward.
        // With the instance lock this is settled already; this is for an older Tiri, from before there was one.
        if !InstanceLock.isHeld, ControlClient.isAlive(path: TiriPaths.socket) {
            if let other = try? ControlClient(path: TiriPaths.socket, timeout: 2) {
                _ = try? other.send(ControlRequest(cmd: "activate"))
            }
            SafeStart.quitOnPurpose()
            exit(0)
        }
        editorBridge.start()
        loadTurns()
        adoptNewAgents()
        // After two launches that didn't finish, without what most often stops one: see `SafeStart`.
        if !SafeStart.isOn {
            languageServers.prepare()
            plugins.load()
        }
        yourTiri.finishLaunching()
        // So the first file's colors aren't late, without making launch any longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { HighlightEngine.shared.prepare() }
        // A program still running with no tab lost it in a crash, or in damaged state. It comes back as one:
        // closing a tab is what ends its program, and that never happened.
        adoptOrphanedSessions()
        refreshRecents()
        restoreAgentStatus(finished: true)
        bringBackUnsavedEdits()
        router.install(model: self)
        applyTheme()
        observeSystemAppearance()
        startServer()
        notifier.configure { [weak self] workspace, item in
            self?.focusFromNotification(workspace: workspace, item: item)
        }
        FileWatchHub.shared.excludedNames = Set(settings.filesExclude)
        FileWatchHub.shared.onChanges = { [weak self] paths in self?.filesChanged(paths) }
        FileWatchHub.shared.onRescan = { [weak self] folders in self?.foldersNeedRescan(folders) }
        syncWatchRoots()
        remote.startUp()
        enterActiveWorkspace()
        refreshDeletedFiles()
        // After launch, so the warm web view doesn't count against the launch budget.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MarkdownWebViews.warmUp() }
        Welcome.showIfNew(model: self, isNewInstall: isNewInstall)
    }

    /// Everything that reads the active workspace's files waits here until macOS has said yes.
    private func enterActiveWorkspace() { enterWorkspace(activeID) }

    /// The same for any workspace a window shows. `focus` is false when a window came forward by itself, which
    /// keeps whatever it had the keyboard on.
    func enterWorkspace(_ id: WorkspaceID, focus: Bool = true) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let live = live(id)
        var paths = workspace.folders
        for item in workspace.items {
            switch item.content {
            case .terminal(let spec): paths.append(spec.cwd)
            case .file(let spec): paths.append(spec.path)
            case .diff(let spec): paths.append((spec.path as NSString).deletingLastPathComponent)
            case .web, .settings, .plugin, .unknown: break
            }
        }
        let unchecked = Array(Set(paths).subtracting(checkedPaths))
        if unchecked.isEmpty {
            live.accessReady = true
            workspaceReady(id, focus: focus)
            return
        }
        live.accessReady = false
        live.fileTree.clear()
        live.treeFolders = nil
        Task { [weak self] in
            let denied = await FolderAccess.deniedPaths(unchecked)
            // Only while a window still shows it.
            guard let self, self.lives[id] === live else { return }
            self.checkedPaths.formUnion(unchecked)
            live.accessReady = true
            if let first = denied.first {
                let name = (first as NSString).abbreviatingWithTildeInPath
                self.banner = AppBanner(message: String(localized: "macOS is blocking Tiri from reading \(name). Allow it under Privacy & Security > Files and Folders."),
                                        isError: true, opensPrivacySettings: true)
            }
            self.workspaceReady(id, focus: focus)
        }
    }

    private func workspaceReady(_ id: WorkspaceID, focus: Bool) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let inFront = id == activeID
        if let destination = workspace.remote { remote.connect(destination) }
        remote.syncOpenFiles()
        live(id).bindTree(workspace)
        if inFront { refreshFileIndex() }
        watchForChanges(id)
        if inFront { plugins.workspaceChanged() }
        startWorkspaceTerminals(id)
        // Back to a Peek that's waiting for typing: the keyboard goes back into it.
        if inFront, focus, let peek = workspace.peek, waitingFor.contains(peek.id) { peekHasKeyboard = true }
        if inFront, focus { requestFocus() }
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

    private func adoptOrphanedSessions() {
        guard settings.terminalKeepRunning else { return }
        var adopted = 0
        for orphan in TerminalSessions.orphans(except: Set(workspaces.flatMap { $0.items.map(\.id) })) {
            let cwd = orphan.cwd ?? active.folders.first ?? NSHomeDirectory()
            // Where it ran says which workspace it belongs to, best as it can be told.
            let index = workspaces.firstIndex { $0.remote == nil && $0.folder(containing: cwd) != nil }
                ?? workspaces.firstIndex { $0.id == activeID } ?? 0
            workspaces[index].addItem(Item(id: orphan.id, content: .terminal(TerminalSpec(command: orphan.command, cwd: cwd))))
            adopted += 1
        }
        if adopted > 0 { scheduleSave() }
        if stateWasDamaged {
            showBanner(String(localized: "Some of what Tiri saved couldn't be read, so its last good copy came back."), isError: true)
        }
    }

    /// Edits that weren't saved come back with their tabs. Those whose tab is gone, after a crash or damaged
    /// state, come back in a tab of their own: nobody chose not to keep them.
    private func bringBackUnsavedEdits() {
        for id in UnsavedEdits.all() {
            guard let edit = UnsavedEdits.read(id) else {
                UnsavedEdits.remove(id)
                continue
            }
            if anyItem(id) == nil {
                // A closed workspace's: it waits for that to be reopened.
                if recents.store.closed.contains(where: { $0.workspace.item(id) != nil }) {
                    keptEdits.insert(id)
                    continue
                }
                let index = workspaces.firstIndex { $0.remote == nil && $0.folder(containing: edit.path) != nil }
                    ?? workspaces.firstIndex { $0.id == activeID } ?? 0
                workspaces[index].addItem(Item(id: id, content: .file(FileSpec(path: edit.path))))
                scheduleSave()
            }
            // Made now, so its tab shows it has changes.
            _ = controller(for: id)
        }
    }

    /// Unsaved edits, kept so a quit doesn't need to ask about them. False if some couldn't be.
    func keepAllUnsavedEdits() -> Bool {
        var kept = true
        for controller in controllers.values where controller.isDirty {
            if !controller.keepUnsavedEdits() { kept = false }
        }
        return kept
    }

    func prepareForTermination() {
        saveWork?.cancel()
        // A Peek isn't kept through a quit, but what's typed in one a program waits on is: as a tab.
        for index in workspaces.indices where workspaces[index].heldPeek != nil { workspaces[index].keepHeldPeek() }
        _ = keepAllUnsavedEdits()
        saveNow()
        editorBridge.stop()
        remote.prepareForQuit()
        for controller in controllers.values { controller.teardown() }
        languageServers.stopAll(quitting: true)
        plugins.processes.stopAll()
        server?.stop()
    }

    func applicationDidBecomeActive() {
        markActiveItemSeen()
    }

    /// Stage Manager brings any window back onto the screen, however far away it's put, and there it
    /// could be seen and pressed by whoever's using this Mac. So a test copy hides itself as an app,
    /// and stays hidden, and no click reaches its window even if something shows it for a moment.
    private static var keepingOutOfSight = false

    private func keepOutOfSight(_ window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        // On a screen nobody's working on, to measure drawing: shown there, and never clicked.
        if let name = environment["TIRI_DEV_SCREEN"], !name.isEmpty {
            window.ignoresMouseEvents = true
            if let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
                let area = screen.visibleFrame
                // TIRI_DEV_WINDOW_SIZE=1600x900 sizes it, as for a recording.
                let asked = environment["TIRI_DEV_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
                let wanted = asked?.count == 2 ? NSSize(width: asked![0], height: asked![1]) : window.frame.size
                let size = NSSize(width: min(wanted.width, area.width - 40), height: min(wanted.height, area.height - 40))
                window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
                window.orderFrontRegardless()
                return
            }
        }
        // scripts/dev-app.sh focus, for when nobody's using this Mac and a real click is the point.
        if environment["TIRI_DEV_VISIBLE"] == "1" { return }
        window.ignoresMouseEvents = true
        NSApp.hide(nil)
        // One watch for the app, however many windows it has.
        guard !Self.keepingOutOfSight else { return }
        Self.keepingOutOfSight = true
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !NSApp.isHidden { NSApp.hide(nil) }
            }
        }
    }

    func windowDidAppear(_ window: NSWindow, id: String = WindowPlan.main) {
        // A window that was closed stays closed.
        guard id == WindowPlan.main || windowWorkspaces[id] != nil else { return }
        registerWindow(window, id: id)
        // A test copy, out of sight, where it can't get in anyone's way and can still be captured.
        if ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1", !window.collectionBehavior.contains(.stationary) {
            window.collectionBehavior.insert(.stationary)
            keepOutOfSight(window)
        }
        window.acceptsMouseMovedEvents = true
        window.isRestorable = false
        if launchMilliseconds == nil {
            launchMilliseconds = ProcessClock.millisecondsSinceProcessStart()
        }
        requestFocus()
    }

    private func startServer() {
        let path = TiriPaths.socket
        // Holding the instance lock, no other Tiri has this state. Something still listening there is a terminal that
        // outlived a crash with the socket an older build passed on, and the path is this one's to take.
        if InstanceLock.isHeld, ControlClient.socketState(path: path) == .listening { unlink(path) }
        let server = ControlServer(path: path) { request in
            await ControlHandler.handleFromMac(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            showBanner(String(localized: "Tiri's control socket isn't available: \(String(describing: error))"), isError: true)
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

    func updateWorkspace(containing item: ItemID, _ change: (inout Workspace) -> Void) {
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
        remote.syncOpenFiles()
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
            // Its tab is gone, and with it any edits it was keeping, unless its workspace was only closed.
            if !keptEdits.contains(id) { UnsavedEdits.remove(id) }
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
            try store.save(.init(workspaces: workspaces, activeID: activeID, windows: windowPlacements))
        } catch let newer as WorkspaceStore.NewerFormat {
            // Said once a launch: every change would say it again.
            guard !toldNewerFormat else { return }
            toldNewerFormat = true
            showToast(title: String(localized: "Changes to tabs aren't saved"), detail: newer.description, symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
        } catch {
            showBanner(String(localized: "Couldn't save the workspace: \(error.localizedDescription)"), isError: true)
        }
    }

    // MARK: Controllers

    /// The terminals that have been opened, in no particular order.
    var openTerminals: [(id: ItemID, controller: TerminalController)] {
        controllers.compactMap { id, controller in (controller as? TerminalController).map { (id, $0) } }
    }

    func controller(for id: ItemID) -> ItemController? {
        if let existing = controllers[id] { return existing }
        guard let item = anyItem(id) else { return nil }
        let controller: ItemController
        switch item.content {
        case .terminal(let spec):
            let restored = restoredItems.remove(id) != nil
            var launch = spec.command
            var prefill: String?
            var attachedTo: String?
            // Still running from before: what's there now is what counts, so nothing is replayed.
            if settings.terminalKeepRunning || keepTerminalsThroughQuit, TerminalSessions.isAlive(id) {
                launch = nil
                // Started with a command, it's still that command running: an agent stays an agent.
                attachedTo = spec.isShell ? nil : spec.command
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
                    // What a plugin started goes through its command again, if it's still on, or not at all.
                    prefill = spec.plugin == nil ? command : nil
                }
            }
            let workspaceID = workspace(containing: id)?.id ?? activeID
            let terminal = TerminalController(itemID: id, spec: spec, launchCommand: launch, attachedTo: attachedTo, prefill: prefill,
                                              workspaceID: workspaceID, model: self)
            adoptRestoredStatus(terminal, id: id)
            controller = terminal
        case .file(let spec):
            // On a server and not here yet. The viewer depends on what's in it, so it waits.
            if remote.needsFetch(spec.path) {
                let loading = RemoteFileController(itemID: id, path: spec.path, model: self)
                controllers[id] = loading
                remote.fetch(spec.path)
                return loading
            }
            controller = ViewerFactory.make(itemID: id, spec: spec, model: self)
        case .settings:
            controller = SettingsController(itemID: id, model: self)
        case .diff(let spec):
            controller = DiffController(itemID: id, spec: spec, model: self)
        case .web(let spec):
            guard let url = URL(string: spec.url) else { return nil }
            controller = WebController(itemID: id, url: url, forceDark: spec.forceDark, isFile: false, model: self)
        case .plugin(let spec):
            controller = plugins.makeController(itemID: id, spec: spec)
        case .unknown:
            // Kept out of tabs by the store, so nothing asks for one.
            return nil
        }
        controllers[id] = controller
        return controller
    }

    func existingController(for id: ItemID) -> ItemController? { controllers[id] }

    /// Everything showing a plugin's page, in any workspace.
    func allTextControllers() -> [TextController] { controllers.values.compactMap { $0 as? TextController } }

    func allPanelControllers() -> [WebController] {
        controllers.values.compactMap { $0 as? WebController }.filter { $0.panel != nil }
    }

    /// Languages came or went, so files open now may be something else. `restarting` are grammars
    /// that may have new contents under the same name.
    func languagesChanged(restarting scopes: Set<String>) {
        for controller in controllers.values {
            (controller as? TextController)?.languagesChanged(restarting: scopes)
            (controller as? DiffController)?.languagesChanged()
        }
        languageRevision += 1
    }

    func measureOpen(_ id: ItemID) {
        openInFlight = (id, ProcessClock.now())
    }

    /// Whatever shows these plugins' panels starts over, as what they are now. A file that had a plugin's
    /// viewer goes back to Tiri's own, and one that could have one gets it.
    func pluginPanelsChanged(changed names: Set<String>) {
        for workspace in workspaces {
            for item in workspace.items + (workspace.peek.map { [$0] } ?? []) {
                guard let controller = controllers[item.id] else { continue }
                switch item.content {
                case .plugin(let spec) where names.contains(spec.plugin):
                    discardController(item.id)
                case .file(let spec):
                    let showing = (controller as? WebController)?.panel?.plugin.name
                    let wanted = plugins.viewer(for: spec)?.plugin.name
                    guard !controller.isDirty else { continue }
                    if showing != wanted || (showing.map(names.contains) ?? false) { discardController(item.id) }
                default:
                    break
                }
            }
        }
        controllerRevision += 1
    }

    func setViewer(_ id: ItemID, to viewer: String) {
        if existingController(for: id)?.isDirty == true {
            showToast(title: String(localized: "Save this file first"), detail: String(localized: "It has changes that aren't saved."), symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        updateWorkspace(containing: id) { workspace in
            workspace.updateItem(id) { item in
                if case .file(var spec) = item.content {
                    spec.viewer = viewer
                    item.content = .file(spec)
                }
            }
        }
        discardController(id)
        controllerRevision += 1
        scheduleSave()
    }

    func setPanelTitle(_ id: ItemID, to title: String) {
        updateWorkspace(containing: id) { workspace in
            workspace.updateItem(id) { item in
                if case .plugin(var spec) = item.content {
                    spec.title = title
                    item.content = .plugin(spec)
                }
            }
        }
        scheduleSave()
    }

    /// A copy made by scripts/dev-app.sh, with its own identity and folders. Nothing with the real
    /// app's identity, or using its folders, ever counts, whatever its environment says.
    static var isTestCopy: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier?.contains(".test.") == true, environment["TIRI_DEV_OFFSCREEN"] == "1", let home = environment["TIRI_HOME"], !home.isEmpty else { return false }
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tiri").standardizedFileURL.path
        return URL(fileURLWithPath: home).standardizedFileURL.path != real
    }

    func openPluginSettings() { openSettings(pane: .plugins) }

    func discardController(_ id: ItemID) {
        controllers[id]?.teardown()
        controllers[id] = nil
    }

    var allControllers: [ItemController] { Array(controllers.values) }

    var terminalControllers: [TerminalController] {
        controllers.values.compactMap { $0 as? TerminalController }
    }

    var workingTerminalCount: Int {
        runtimes.values.filter { $0.status == .working }.count
    }

    /// Terminals in the active workspace start with it. The visible one starts as soon as it has
    /// a size; the rest follow just after launch so they don't count against the launch budget.
    func startActiveWorkspaceTerminals() { startWorkspaceTerminals(activeID) }

    func startWorkspaceTerminals(_ workspaceID: WorkspaceID) {
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
        let before = runtimes[id]
        runtimes[id] = runtime
        keepStatusRecord(id, was: before)
        updateDockBadge()
    }

    func handleLeftMouseDown(_ event: NSEvent) {
        tabDrag = nil
        tabDragCommitted = false
        let point = globalPoint(event)
        // A click outside the palette closes it, and still does what it was for.
        if palette != nil, let frame = layoutRegistry.paletteFrame, !frame.contains(point) {
            closePalette(restoreFocus: false)
            DispatchQueue.main.async { [weak self] in
                // Chrome doesn't take the keyboard, and nothing else was left holding it.
                if let window = self?.window, window.firstResponder === window { self?.requestFocus() }
            }
        }
        // A click outside the Peek dismisses it, except a ⌘-click, which may be
        // the next link being opened. Going through a list of files should stay fluid.
        if active.peek != nil, let frame = layoutRegistry.peekFrame {
            if frame.contains(point) {
                setPeekKeyboard(true)
                return
            }
            // One a program is waiting on stays: a click to scroll or copy from the terminal isn't being done with it.
            if !event.modifierFlags.contains(.command), active.peek?.id != active.heldPeek {
                let peekView = active.peek.flatMap { existingController(for: $0.id)?.view }
                dismissPeek(restoreFocus: false)
                DispatchQueue.main.async { [weak self] in
                    // The click was meant to give the keyboard to what's under it. If it landed on
                    // something that won't take it, the keyboard is still in the Peek that's going
                    // (SwiftUI takes its view out later), and then nobody would be left holding it.
                    guard let self, let window = self.window else { return }
                    let holder = window.firstResponder as? NSView
                    if window.firstResponder === window || holder?.window == nil
                        || (peekView.map { holder?.isDescendant(of: $0) == true } ?? false) {
                        self.requestFocus()
                    }
                }
            }
        }
        // Clicking a pane makes its group the focused one.
        for (id, weak) in groupHosts {
            guard let view = weak.view, view.window != nil, view.window === event.window else { continue }
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
        // Whatever has the keyboard underneath, marking is what's in front.
        if yourTiri.isMarking {
            yourTiri.cancelMarking()
            return true
        }
        if shortcutNotice != nil {
            shortcutNotice = nil
            return true
        }
        if palette != nil {
            closePalette()
            return true
        }
        if find != nil, firstResponderIsFindField {
            closeFind()
            return true
        }
        // Before anything else about the editor: the list is the thing floating nearest you.
        if let editor = focusedEditor, editor.completion.isOpen {
            editor.completion.close()
            return true
        }
        if let editor = focusedEditor, editor.codeView.hasMultipleCursors {
            editor.codeView.dropExtraCursors()
            return true
        }
        // Whoever opened it, and whatever has the keyboard. Esc is for what's floating in front of
        // you, and the agent underneath only gets the next one.
        if active.peek != nil {
            dismissPeek()
            return true
        }
        return false
    }

    private var firstResponderIsFindField: Bool {
        guard let responder = window?.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor
    }

    /// `promotePeek` on ⌘↩ should only eat the key when there's a Peek to promote.
    func isCommandEnabledForKey(_ command: String) -> Bool {
        if EditorCommand(rawValue: command) != nil {
            guard let editor = focusedEditor else { return false }
            return editor.codeView.isEditable
        }
        switch command {
        case "goToLine", "toggleWordWrap": return focusedEditor != nil
        case "symbolsInFile": return frontOutlineTarget != nil
        case "clearTerminal", "terminalLineStart", "terminalLineEnd", "terminalDeleteToLineStart":
            return (NSApp.keyWindow ?? window)?.firstResponder is TiriTerminalView
        // A Peek floating over a file you're typing in doesn't take that file's ⌘↩.
        case "promotePeek": return active.peek != nil && (peekHasKeyboard || focusedEditor == nil)
        case "promotePeekToSide", "promotePeekBelow", "promotePeekToWindow": return active.peek != nil
        case "webReload": return frontWebController != nil
        case "goBack": return canGoBack
        case "goToDefinition", "findReferences", "showHover": return canAskAboutSymbols()
        case "nextChange", "previousChange": return canGoToChange
        default: return true
        }
    }

    // MARK: Opening

    @discardableResult
    func open(path rawPath: String, line: Int? = nil, col: Int? = nil, intent: OpenIntent,
              in workspaceID: WorkspaceID? = nil, here: Bool = false) -> ItemID? {
        let started = ProcessClock.now()
        let target = workspaceID ?? activeID
        let inFront = target == activeID
        let path = aliasedPath(rawPath, in: target)
        var intent = intent
        // A Peek something is waiting on stays put: anything else shown meanwhile goes in a tab beneath it.
        if case .peek = intent, let peek = workspaces.first(where: { $0.id == target })?.peek, waitingFor.contains(peek.id), peek.filePath != path {
            intent = .preview
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            if inFront { showToast(title: String(localized: "No such file"), detail: rawPath, symbol: "questionmark.folder", tint: .orange) }
            return nil
        }
        if isDirectory.boolValue {
            if inFront { revealOrOffer(path: path) }
            return nil
        }
        // A kind someone keeps in its own app goes there, unless they asked for it here. An agent showing it
        // doesn't get to bring that app in front.
        if !here {
            var quietly = !inFront
            if case .peek(takeFocus: false) = intent { quietly = true }
            let openHere = { [weak self] in _ = self?.open(path: rawPath, line: line, col: col, intent: intent, in: workspaceID, here: true) }
            if sendsToApp(path, quietly: quietly, openHere: openHere) { return nil }
        }
        if inFront { rememberRecent(path) }
        if RemoteRegistry.shared.isRemote(path), ["html", "htm", "svg"].contains((path as NSString).pathExtension.lowercased()) {
            remote.fetchAround(path)
        }
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
        // `readme.md` opens `README.md` on a Mac, and is the same tab, watched under the name events use.
        if let folder = workspace.folder(containing: path) { return workspace.remote == nil ? PathCase.onDisk(path, below: folder) : path }
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
        openPalette(.choices(title: String(localized: "\(matches.count) files match \(name). Type to narrow down."), rows: rows))
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

    func linkMatches(for path: String, from item: ItemID, also extra: [String] = []) -> [String] {
        guard let workspace = workspace(containing: item) else { return [] }
        let openFiles = workspace.items.compactMap(\.filePath)
        let cwd = (existingController(for: item) as? TerminalController)?.currentDirectory
        let found = PathSearch.matches(for: path) { name in
            fileIndex.paths(named: name) + terminalFolderIndex.paths(named: name)
                + (openFiles + extra).filter { ($0 as NSString).lastPathComponent == name }
        }
        // The same file reached by two names is one match. One deleted since the index was read is none.
        var seen = Set<String>()
        return PathSearch.ranked(found, open: Set(openFiles), near: cwd).filter {
            (workspace.remote != nil || FileManager.default.fileExists(atPath: $0)) && seen.insert(($0 as NSString).resolvingSymlinksInPath).inserted
        }
    }

    /// The index holds what git counts as the project, but agents print paths to what it ignores
    /// too: screenshots, build output, logs. Asked only once nothing else matched, so it walks
    /// for that one name, and gives up after a few seconds.
    func ignoredLinkFiles(named name: String, from item: ItemID) async -> [String] {
        guard let workspace = workspace(containing: item), workspace.remote == nil, !name.isEmpty else { return [] }
        let roots = workspace.folders + extraLinkRoots(for: workspace)
        let excludes = ExcludeMatcher(patterns: settings.filesExclude)
        return await Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(3)
            return FileIndexer.walk(roots: roots, excludes: excludes, limit: 500, named: name) { Date() > deadline }.map(\.path)
        }.value
    }

    func openWebFromTerminal(_ url: URL, forceTab: Bool, from destination: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let local = await self.remote.localURL(for: url, on: destination) else {
                self.showToast(title: String(localized: "Couldn't reach that port on the server"), detail: url.absoluteString, symbol: "exclamationmark.triangle", tint: .orange)
                return
            }
            self.openWebFromTerminal(local, forceTab: forceTab)
        }
    }

    func openWebFromTerminal(_ url: URL, forceTab: Bool, keepHere: Bool = false) {
        if !keepHere, sendsToBrowser(url, openHere: { [weak self] in self?.openWebFromTerminal(url, forceTab: forceTab, keepHere: true) }) {
            return
        }
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
    func openWeb(url: String, split: SplitDirection?, in workspaceID: WorkspaceID? = nil, takeFocus: Bool = true) -> ItemID {
        let target = workspaceID ?? activeID
        let item = Item(content: .web(WebSpec(url: url)))
        update(workspace: target) { $0.addItem(item, split: split) }
        if target == activeID, takeFocus { requestFocus() }
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
            showToast(title: String(localized: "\(name) isn't in this workspace"), detail: path, symbol: "folder.badge.plus", tint: .accentColor,
                      actionTitle: String(localized: "Add Folder"), duration: 10,
                      other: (String(localized: "Show in Finder"), { [weak self] in self?.showInFinder(path) })) { [weak self] in
                self?.addFolder(path)
                self?.revealInTree(path)
            }
        }
    }

    /// Finder, with the thing selected. A test copy only writes it down: Finder would come to the front.
    func showInFinder(_ path: String) {
        if Self.isTestCopy {
            sentToBrowser.append("finder:" + path)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealInTree(_ path: String) {
        setSidebar(visible: true)
        fileTree.reveal(path: path, expand: true)
    }

    private func autoRevealActive() {
        guard settings.explorerAutoReveal, let path = active.activeItem?.filePath else { return }
        fileTree.reveal(path: path, expand: false, quiet: true)
    }

    private func rememberRecent(_ path: String) {
        updateActive { workspace in
            workspace.recentFiles.removeAll { $0 == path }
            workspace.recentFiles.insert(path, at: 0)
            if workspace.recentFiles.count > 50 { workspace.recentFiles.removeLast() }
        }
    }

    var recentFilesInActive: [String] { active.recentFiles }

    // MARK: Peek

    func showNotebookNotice(_ text: String) {
        _ = showToast(title: text, detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
    }

    var frontNotebook: MarkdownController? {
        let target = active.peek?.id ?? active.focused.active
        guard let target, let viewer = existingController(for: target) as? MarkdownController, viewer.isNotebook else { return nil }
        return viewer
    }

    private func onFrontNotebook(_ act: (MarkdownController) -> Void) {
        if let viewer = frontNotebook { act(viewer) } else { showNotebookNotice(String(localized: "There's no notebook in front.")) }
    }

    func notebookCommand(_ id: String) {
        onFrontNotebook { viewer in
            let kernel = notebookKernels.kernel(for: viewer.path)
            switch id {
            case "notebookRunCell": viewer.runCurrentCell()
            case "notebookRunAll": viewer.runAllCells()
            case "notebookInterrupt": kernel.interrupt()
            case "notebookRestart": kernel.restart()
            case "notebookStop": kernel.stop()
            case "notebookClear": viewer.clearOutputs()
            case "notebookChoosePython": notebookKernels.chooseKernel(for: viewer.path)
            case "notebookAddCode": viewer.addCell(kind: .code)
            case "notebookAddMarkdown": viewer.addCell(kind: .markdown)
            case "notebookDeleteCell": viewer.deleteCurrentCell()
            default: break
            }
        }
    }

    func setPeekKeyboard(_ value: Bool) {
        if peekHasKeyboard != value { peekHasKeyboard = value }
    }

    func promotePeek(split: SplitDirection? = nil) {
        guard let peek = active.peek else { return }
        // Something's waiting for this file back: ⌘↩ is Done.
        if split == nil, waitingFor.contains(peek.id) {
            finishWaiting(peek.id)
            return
        }
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        updateActive { $0.promotePeek(split: split) }
        requestFocus()
    }

    func dismissPeek(restoreFocus: Bool = true, keepStops: Bool = false) {
        guard let peek = active.peek else { return }
        // Closing a file that's being waited on is finishing with it: what you typed goes back, not nothing.
        if waitingFor.contains(peek.id), let controller = existingController(for: peek.id), controller.isDirty {
            save(controller) { [weak self] in self?.dismissPeek(restoreFocus: restoreFocus, keepStops: keepStops) }
            return
        }
        // Places inside a Peek go with it. Nothing's left to go back through.
        if !keepStops { navigationStops.removeAll(where: \.inPeek) }
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        updateActive { $0.closePeek() }
        if restoreFocus { requestFocus() }
    }

    // MARK: Terminals

    @discardableResult
    func newTerminal(command: String? = nil, cwd: String? = nil, split: SplitDirection? = nil,
                     in workspaceID: WorkspaceID? = nil, title: String? = nil, plugin: String? = nil) -> ItemID {
        let target = workspaceID ?? activeID
        let directory = cwd ?? defaultTerminalDirectory()
        let trimmed = command?.trimmingCharacters(in: .whitespaces)
        var spec = TerminalSpec(command: trimmed?.isEmpty == true ? nil : trimmed, cwd: directory)
        spec.title = title
        spec.plugin = plugin
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
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = purpose.map { String(localized: "Choose the folder \($0) will work in") } ?? String(localized: "Choose the folder this terminal will work in")
        panel.prompt = String(localized: "Choose Folder")
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
        let directory = directoryOfFrontItem()
        // On a server, somewhere that isn't on it would mean starting in the home folder there.
        if let destination = active.remote, remote.existingConnection(destination)?.map.contains(directory) != true, let folder = active.folders.first { return folder }
        return directory
    }

    private func directoryOfFrontItem() -> String {
        if let item = active.activeItem {
            switch item.content {
            case .terminal(let spec):
                return (existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd
            case .file(let spec):
                // A file outside the workspace, such as an open history, starts new agents in the workspace's folder.
                return active.folder(containing: spec.path) ?? active.folders.first ?? (spec.path as NSString).deletingLastPathComponent
            case .diff(let spec):
                return active.folder(containing: spec.path) ?? active.folders.first ?? (spec.path as NSString).deletingLastPathComponent
            case .web, .settings, .plugin, .unknown:
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

    /// Not worked out while drawing: it looks at processes, and can start a terminal coming back.
    private func scheduleAgentRows() {
        guard !agentRowsPending else { return }
        agentRowsPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.agentRowsPending = false
            let rows = self.agentOverview
            if rows != self.agentRows { self.agentRows = rows }
            self.wantAgentTitles(rows)
            self.plugins.agentsChanged(rows)
        }
    }

    func agentRowsChanged() { scheduleAgentRows() }

    /// An agent can start or end with no report at all, like one typed at a shell without hooks.
    func startWatchingAgents() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleAgentRows()
                // An agent's worktree can be outside everything being watched. Less often over SSH.
                self.watchTicks += 1
                for (id, live) in self.lives {
                    let onServer = self.workspaces.first { $0.id == id }?.remote != nil
                    if self.watchTicks % (onServer ? 30 : 8) == 0 || !live.otherWorkLooked { self.refreshOtherWork(id) }
                }
            }
        }
    }

    func updateRuntime(_ id: ItemID, _ change: (inout TerminalRuntime) -> Void) {
        let before = runtimes[id]
        var runtime = before ?? TerminalRuntime()
        change(&runtime)
        runtime.keepWorkingSince(from: before)
        if runtimes[id] != runtime {
            runtimes[id] = runtime
            keepStatusRecord(id, was: before)
        }
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
        let body = message ?? (status == .needsInput ? String(localized: "Needs your input") : String(localized: "Finished"))
        notifier.post(title: title, body: body, subtitle: workspace.shownName, workspace: workspace.id, item: id)
        if NSApp.isActive {
            showToast(title: title, detail: body,
                      symbol: status == .needsInput ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                      tint: status == .needsInput ? .orange : .green, actionTitle: String(localized: "Show")) { [weak self] in
                self?.focusFromNotification(workspace: workspace.id, item: id)
            }
        }
    }

    /// A test copy never comes forward: someone may be using this Mac.
    static func bringAppForward() {
        guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] != "1" else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func focusFromNotification(workspace: WorkspaceID, item: ItemID) {
        Self.bringAppForward()
        // First, so it's the window that has it that comes forward.
        focusItem(item)
        window?.makeKeyAndOrderFront(nil)
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
            showToast(title: String(localized: "Nothing needs attention"), detail: nil, symbol: "checkmark.circle", tint: .secondary)
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

    func updateDockBadge() {
        let count = runtimes.values.filter(\.unseen).count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func handleHookReport(item id: ItemID, tool: String?, state: String?, message: String?, session: String?,
                          turn: String? = nil, prompt: String? = nil, activity: String? = nil, files: [String] = []) {
        if let tool, case .terminal(let spec)? = anyItem(id)?.content, !spec.acceptsHook(from: tool) { return }
        if turn == AgentHookEvent.Turn.start.rawValue { (existingController(for: id) as? TerminalController)?.heardTurnStart() }
        if turn != nil || activity != nil || !files.isEmpty {
            updateRuntime(id) { runtime in
                if turn == AgentHookEvent.Turn.start.rawValue {
                    runtime.prompt = AgentHookEvent.promptLine(prompt)
                    runtime.touched = []
                    runtime.activity = nil
                }
                if turn == AgentHookEvent.Turn.end.rawValue {
                    runtime.activity = nil
                    // An agent that only says when it's finished says here what it was asked.
                    if let prompt, let line = AgentHookEvent.promptLine(prompt) { runtime.prompt = line }
                }
                if let activity { runtime.activity = activity }
                for file in files where !runtime.touched.contains(file) { runtime.touched.append(file) }
            }
        }
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

    /// What a tab is called on screen.
    func title(for item: Item) -> String { title(for: item, shown: true) }

    /// The same, with the words Tiri makes up in English, for `tiri`.
    func englishTitle(for item: Item) -> String { title(for: item, shown: false) }

    private func title(for item: Item, shown: Bool) -> String {
        let made = shown ? item.shownDefaultTitle : item.defaultTitle
        switch item.content {
        case .terminal(let spec):
            // An agent has one name, wherever it's listed.
            if let row = agentRows.first(where: { $0.item == item.id }) { return row.name == Self.unnamedConversation ? row.agent : row.name }
            if let title = runtimes[item.id]?.title, !title.isEmpty { return title }
            return spec.isShell ? made : (spec.title ?? spec.command ?? made)
        case .web:
            if let title = (existingController(for: item.id) as? WebController)?.title, !title.isEmpty { return title }
            return made
        case .file, .settings, .diff, .plugin, .unknown:
            return made
        }
    }

    // MARK: Closing

    func requestClose(_ id: ItemID, confirm: Bool = true) {
        if active.peek?.id == id {
            dismissPeek()
            return
        }
        // A kernel doing work is the same as a terminal doing work, but only one of them says so.
        if confirm, let window, let path = notebookPath(of: id), notebookKernels.existing(for: path)?.isActive == true, otherTab(showing: path, than: id) == nil {
            let alert = NSAlert()
            alert.messageText = String(localized: "This notebook is still running")
            alert.informativeText = String(localized: "Closing it stops its kernel.")
            alert.addButton(withTitle: String(localized: "Close"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.closeNow(id) }
                }
            }
            return
        }
        if confirm, let controller = existingController(for: id), controller.isDirty, let window, let item = anyItem(id) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Save your changes to \(title(for: item))?")
            alert.informativeText = String(localized: "They're lost if you don't save them.")
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
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
            alert.messageText = String(localized: "Terminate \(name)?")
            alert.informativeText = String(localized: "This terminal is still running \(name). Closing it stops the process.")
            alert.addButton(withTitle: String(localized: "Terminate"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.closeNow(id) }
                }
            }
            return
        }
        closeNow(id)
    }

    private func notebookPath(of id: ItemID) -> String? {
        guard let item = anyItem(id), case .file(let spec) = item.content, spec.path.hasSuffix(".ipynb") else { return nil }
        return spec.path
    }

    private func otherTab(showing path: String, than id: ItemID) -> ItemID? {
        for workspace in workspaces {
            for item in workspace.items where item.id != id {
                if case .file(let spec) = item.content, spec.path == path { return item.id }
            }
        }
        return nil
    }

    func closeNow(_ id: ItemID) {
        if let path = notebookPath(of: id), otherTab(showing: path, than: id) == nil { notebookKernels.stopIfUnused(path: path) }
        updateWorkspace(containing: id) { $0.close(id) }
        AgentStatusRecords.remove(id)
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
        case .settings, .unknown:
            // One Settings tab per workspace. Beside it, a new terminal is what's useful.
            startTerminal(split: direction)
            return
        case .diff(let spec):
            updateActive { $0.addItem(Item(content: .diff(spec)), split: direction) }
        case .plugin(let spec):
            updateActive { $0.addItem(Item(content: .plugin(spec)), split: direction) }
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

    // MARK: Moving between things

    private static var motionIsWelcome: Bool { !AccessibilityDisplay.shared.reduceMotion }

    func setSidebar(visible: Bool) {
        let wanted: NavigationSplitViewVisibility = visible ? .all : .detailOnly
        guard wanted != sidebarVisibility else { return }
        withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.22))) { sidebarVisibility = wanted }
    }

    /// Terminals, editors and pages keep their size while the sidebar moves, and take the new one when
    /// it's stopped. Resizing a terminal on every frame reflows it and signals what's running each time.
    private func holdItemSizes() {
        itemSizesHeld += 1
        ItemHost.Host.holdsSizes = true
        let held = itemSizesHeld
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, self.itemSizesHeld == held else { return }
            ItemHost.Host.holdsSizes = false
            NotificationCenter.default.post(name: ItemHost.Host.sizesReleased, object: nil)
        }
    }

    /// What's on screen now fades into whatever's there after this turn of the run loop, however
    /// much of the window that changes, and whatever is rebuilt on the way there.
    func crossfade() {
        guard Self.motionIsWelcome, let layer = window?.contentView?.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "tiri.crossfade")
    }

    func switchWorkspace(_ id: WorkspaceID) {
        guard id != activeID, workspaces.contains(where: { $0.id == id }) else { return }
        // Its terminals can only be in one place: the window that has it comes forward instead.
        if let other = window(showing: id), other != currentWindow {
            focusWindow(other)
            return
        }
        let leaving = activeID
        let started = ProcessClock.now()
        crossfade()
        // Through to what's redrawn, which happens after this returns.
        defer {
            DispatchQueue.main.async {
                DispatchQueue.main.async { [weak self] in self?.lastSwitchMilliseconds = ProcessClock.now() - started }
            }
        }
        // A Peek is a glance at what's in front of you. It doesn't follow you elsewhere.
        peekHasKeyboard = false
        layoutRegistry.peekFrame = nil
        // Except one something is waiting on: closing it would hand back what's half typed, so it waits there.
        if let index = workspaces.firstIndex(where: { $0.id == activeID }), workspaces[index].peek?.id != workspaces[index].heldPeek {
            workspaces[index].dismissPeek()
        }
        find = nil
        activeID = id
        windowWorkspaces[currentWindow] = id
        pruneLives()
        dropIfUnused(leaving)
        collectGarbage()
        syncWatchRoots()
        enterActiveWorkspace()
        refreshDeletedFiles()
        scheduleSave()
        markActiveItemSeen()
    }

    func switchWorkspace(index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        switchWorkspace(workspaces[index].id)
    }

    @discardableResult
    func createWorkspace(name: String, folders: [String], remote destination: String? = nil, activating: Bool = true, initialTerminal: Bool = true) -> Workspace {
        var workspace = Workspace(name: uniqueName(name), folders: folders)
        workspace.remote = destination
        if !folders.isEmpty, initialTerminal { workspace.addInitialTerminal(fallbackCwd: NSHomeDirectory()) }
        workspaces.append(workspace)
        if activating { switchWorkspace(workspace.id) } else { scheduleSave() }
        editorBridge.writeLock()
        return workspace
    }

    func uniqueName(_ name: String) -> String {
        guard workspaces.contains(where: { $0.name == name }) else { return name }
        var number = 2
        while workspaces.contains(where: { $0.name == "\(name) \(number)" }) { number += 1 }
        return "\(name) \(number)"
    }

    /// Another agent, without their edits mixing with this one's: a worktree of this repository on a
    /// branch of its own, as a workspace beside this one.
    func newWorktreeInteractive() {
        guard let folder = active.activeItem.flatMap({ item -> String? in
            switch item.content {
            case .terminal: return (existingController(for: item.id) as? TerminalController)?.currentDirectory
            case .file(let spec): return active.folder(containing: spec.path)
            case .diff(let spec): return active.folder(containing: spec.path)
            default: return nil
            }
        }) ?? active.folders.first else {
            showToast(title: String(localized: "Open a folder in a git repository first"), detail: nil, symbol: "arrow.triangle.branch", tint: .secondary)
            return
        }
        openPrompt(title: String(localized: "Branch for the new worktree. A new one is made if it doesn't exist."), initial: "") { [weak self] text in
            self?.addWorktree(branch: text.trimmingCharacters(in: .whitespaces), from: folder)
        }
    }

    @discardableResult
    func addWorktree(branch: String, from folder: String, activating: Bool = true) -> Task<Result<Workspace, Git.TransferFailure>, Never> {
        let host = RemoteRegistry.shared.connection(forLocal: folder)?.destination
        return Task { [weak self] in
            let (result, root) = await Task.detached(priority: .userInitiated) { (Git.addWorktree(branch: branch, in: folder), Git.mainWorktree(of: folder)) }.value
            let repository = ((root ?? folder) as NSString).lastPathComponent
            guard let self else { return .failure(Git.TransferFailure(message: "Tiri is closing.")) }
            switch result {
            case .failure(let failure):
                self.showToast(title: String(localized: "Couldn't make a worktree for \(branch)"), detail: L10n.display(failure.message), symbol: "exclamationmark.triangle", tint: .orange)
                return .failure(failure)
            case .success(let path):
                let name = repository + ": " + branch
                if let host, let remotePath = self.remote.existingConnection(host)?.map.remote(path) {
                    return .success(self.openRemoteFolder(remotePath, on: host, name: name, activating: activating))
                }
                return .success(self.createWorkspace(name: name, folders: [path], activating: activating))
            }
        }
    }

    func newWorkspaceInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose the folders for the new workspace")
        panel.prompt = String(localized: "Create Workspace")
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
        openPrompt(title: String(localized: "Rename workspace"), initial: workspace.shownName) { [weak self] name in
            self?.renameWorkspace(id, to: name)
        }
    }

    func deleteWorkspace(_ id: WorkspaceID, keepingEdits: Bool = false) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        // A terminal not shown since launch has no view to end it, and would come back as an orphan.
        for item in workspaces[index].items where controllers[item.id] == nil {
            guard case .terminal = item.content else { continue }
            if let destination = workspaces[index].remote {
                remote.endSession(item.id, on: destination)
            } else if TerminalSessions.isAlive(item.id) {
                TerminalSessions.end(item.id)
            }
        }
        if keepingEdits { keptEdits.formUnion(workspaces[index].items.map(\.id)) }
        if workspaces.count == 1 {
            // There's always a workspace to be in.
            workspaces.append(Workspace(name: Workspace.placeholderName))
        }
        let wasActive = id == activeID
        let removedRemote = workspaces[index].remote
        for item in workspaces[index].items {
            if case .file(let spec) = item.content, spec.path.hasSuffix(".ipynb") { notebookKernels.stopIfUnused(path: spec.path) }
        }
        workspaces.remove(at: index)
        rehomeWindows(from: id)
        if wasActive {
            peekHasKeyboard = false
            layoutRegistry.peekFrame = nil
            find = nil
            let others = Set(windowWorkspaces.filter { $0.key != currentWindow }.values)
            activeID = WindowPlan.unshown(workspaces.map(\.id), shown: others, preferring: workspaces[min(index, workspaces.count - 1)].id)
                ?? createWorkspace(name: Workspace.placeholderName, folders: [], activating: false, initialTerminal: false).id
            windowWorkspaces[currentWindow] = activeID
            syncWatchRoots()
            enterActiveWorkspace()
        }
        pruneLives()
        collectGarbage()
        scheduleSave()
        if let destination = removedRemote { remote.forget(destination) }
    }

    func confirmDeleteWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the workspace “\(workspace.shownName)”?")
        alert.informativeText = String(localized: "Its terminals stop. Your files and folders aren't touched.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        if target == activeID { foldersChanged() } else if lives[target] != nil { foldersChanged(in: target) }
    }

    func removeFolder(_ path: String, in workspaceID: WorkspaceID? = nil) {
        let target = workspaceID ?? activeID
        update(workspace: target) { $0.removeFolder(path) }
        if target == activeID { foldersChanged() } else if lives[target] != nil { foldersChanged(in: target) }
    }

    private func foldersChanged(in id: WorkspaceID? = nil) {
        editorBridge.writeLock()
        remote.syncAllRoots()
        syncWatchRoots()
        enterWorkspace(id ?? activeID, focus: id == nil)
    }

    func addFolderInteractive() {
        if let destination = active.remote {
            chooseRemoteFolder(on: destination, adding: true)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
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
        panel.message = String(localized: "Choose a Cursor or VS Code .code-workspace file")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importWorkspace(url: url)
    }

    @discardableResult
    func importWorkspace(url: URL) -> Workspace? {
        do {
            let imported = try CodeWorkspaceImporter.read(fileAt: url)
            if imported.skipped > 0 {
                showToast(title: imported.skipped == 1 ? String(localized: "1 folder left out") : String(localized: "\(imported.skipped) folders left out"),
                          detail: String(localized: "A workspace is on this Mac or on one server."), symbol: "info.circle", tint: .secondary)
            }
            if let host = imported.remote {
                importRemoteWorkspace(imported, host: host)
                return nil
            }
            let existing = imported.folders.filter { FileManager.default.fileExists(atPath: $0) }
            if existing.count < imported.folders.count {
                let missing = imported.folders.count - existing.count
                showToast(title: missing == 1 ? String(localized: "1 folder not found") : String(localized: "\(missing) folders not found"),
                          detail: String(localized: "Imported the rest of \(imported.name)"), symbol: "exclamationmark.triangle", tint: .orange)
            }
            return createWorkspace(name: imported.name, folders: existing)
        } catch {
            showBanner("\(url.lastPathComponent): \(error)", isError: true)
            return nil
        }
    }

    func handleExternalOpen(_ url: URL) {
        if url.scheme?.lowercased() == FileLink.scheme {
            openLink(url)
            return
        }
        if url.pathExtension == "code-workspace" {
            importWorkspace(url: url)
            return
        }
        if url.pathExtension.lowercased() == PluginPackage.fileExtension {
            openPluginSettings()
            plugins.importPlugin(at: url)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            openFolderAsWorkspace(url.path)
        } else {
            openFromOutside(url.path)
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

    /// The folders of every workspace in a window, the one in front first.
    func syncWatchRoots() {
        var roots = active.folders
        for workspace in workspaces where workspace.id != activeID && lives[workspace.id] != nil {
            roots += workspace.folders.filter { !roots.contains($0) }
        }
        FileWatchHub.shared.setWorkspaceRoots(roots)
    }

    /// Open files that aren't there any more. Their tabs stay, showing what they last said, and say so.
    func refreshDeletedFiles() {
        for (id, live) in lives {
            guard let workspace = workspaces.first(where: { $0.id == id }) else { continue }
            guard workspace.remote == nil else {
                if !live.deletedFiles.isEmpty { live.deletedFiles = [] }
                continue
            }
            let gone = Set(workspace.items.compactMap(\.filePath).filter { !FileManager.default.fileExists(atPath: $0) })
            if gone != live.deletedFiles { live.deletedFiles = gone }
        }
    }

    private func filesChanged(_ paths: [String]) {
        refreshDeletedFiles()
        languageServers.filesChanged(paths)
        for live in lives.values { live.fileTree.filesChanged(paths) }
        // A deleted file mustn't be offered by quick open or ⌘-click while the index is walked again.
        // A batch too big to look at one by one is left to that walk.
        if paths.count <= 2_000 {
            let gone = paths.filter { !FileManager.default.fileExists(atPath: $0) }
            fileIndex.forget(gone)
            terminalFolderIndex.forget(gone)
        }
        fileIndex.invalidate()
        plugins.editorEvents.filesChanged(paths, host: plugins)
    }

    /// FSEvents lost track under these folders, so what's showing from them is read again.
    private func foldersNeedRescan(_ folders: [String]) {
        filesChanged(folders)
        for live in lives.values { live.fileTree.reload(under: folders) }
    }

    // MARK: Files

    func openExternally(path: String, line: Int? = nil, col: Int? = nil) {
        if openExternallyOnServer(path: path, line: line) { return }
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

    func openFind(replace: Bool = false) {
        guard let target = (peekHasKeyboard ? active.peek?.id : nil) ?? active.focused.active else { return }
        if existingController(for: target) is SettingsController {
            settingsUI.searchFocusRequests += 1
            return
        }
        guard let controller = existingController(for: target), controller.supportsFind else { return }
        var state = find ?? FindState(targetItem: target)
        state.targetItem = target
        let selection = controller.selectedTextForFind ?? ""
        if !selection.isEmpty { state.query = selection }
        if replace, controller.supportsReplace {
            state.showReplace = true
            // Started from a selection, what's left to say is what to replace it with.
            if !selection.isEmpty { state.replaceFocusNonce += 1 } else { state.focusNonce += 1 }
        } else {
            state.focusNonce += 1
        }
        find = state
        if !state.query.isEmpty { runFind(incremental: true) }
    }

    func closeFind() {
        if let target = find?.targetItem { existingController(for: target)?.clearFind() }
        find = nil
        requestFocus()
    }

    func runFind(backwards: Bool = false, incremental: Bool = false) {
        guard var state = find, let controller = existingController(for: state.targetItem) else { return }
        state.replacedCount = nil
        if state.query.isEmpty {
            controller.clearFind()
            state.notFound = false
        } else if incremental {
            state.notFound = !controller.findIncrementally(state.query, caseSensitive: state.caseSensitive)
        } else {
            state.notFound = !controller.find(state.query, backwards: backwards)
        }
        Self.note(controller.findCount, in: &state)
        find = state
    }

    func replaceCurrentMatch() {
        guard var state = find, let controller = existingController(for: state.targetItem), !state.query.isEmpty else { return }
        state.replacedCount = nil
        state.notFound = !controller.replaceCurrent(query: state.query, with: state.replacement, caseSensitive: state.caseSensitive)
        Self.note(controller.findCount, in: &state)
        find = state
    }

    func replaceAllMatches() {
        guard var state = find, let controller = existingController(for: state.targetItem), !state.query.isEmpty else { return }
        state.replacedCount = controller.replaceAll(query: state.query, with: state.replacement, caseSensitive: state.caseSensitive)
        Self.note(controller.findCount, in: &state)
        find = state
    }

    /// An edit moved the matches.
    func findCountChanged() {
        guard var state = find, let controller = existingController(for: state.targetItem) else { return }
        Self.note(controller.findCount, in: &state)
        if state != find { find = state }
    }

    private static func note(_ count: (current: Int, total: Int)?, in state: inout FindState) {
        state.current = count?.current ?? 0
        state.total = count?.total
    }

    // MARK: Settings

    /// One Settings tab per workspace. Asking again goes back to it.
    func openSettings(pane: SettingsPane? = nil, reveal: String? = nil, search: String? = nil) {
        cancelRecordingShortcut()
        if pane != nil || search != nil { settingsUI.query = search ?? "" }
        if let pane { settingsUI.pane = pane }
        settingsUI.reveal = reveal
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
        if let setting = SettingsSchema.splitPluginKey(key) {
            PluginSettingsStore.set(setting.plugin, key: setting.key, to: value)
            plugins.settingsChanged(plugin: setting.plugin)
            return nil
        }
        do {
            try settingsStore.write(key, value: value)
        } catch let needsFixing as SettingsStore.FileNeedsFixing {
            showFileNeedsFixing(needsFixing)
            return needsFixing.why
        } catch {
            showToast(title: String(localized: "Couldn't change that setting"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
            return "\(error)"
        }
        return nil
    }

    func resetSetting(_ key: String) {
        if let setting = SettingsSchema.splitPluginKey(key) {
            PluginSettingsStore.set(setting.plugin, key: setting.key, to: nil)
            plugins.settingsChanged(plugin: setting.plugin)
            return
        }
        guard let definition = SettingsSchema.definition(for: key) else { return }
        setSetting(key, to: definition.value(TiriSettings()))
    }

    /// Sends the settings prompt to that agent if it's already running in this workspace, for you
    /// to read before pressing Return. Otherwise starts the agent with the prompt.
    func askAgentAboutSettings(preset: TerminalPreset) {
        askAgent(preset: preset, prompt: SettingsSchema.agentPrompt)
    }

    /// Into a running session of that agent, or a new one.
    static let unnamedConversation = "New conversation"

    /// A conversation's name on screen. The unnamed one is compared, and goes to `tiri`, in English.
    static func shownConversationName(_ name: String) -> String {
        name == unnamedConversation ? String(localized: "New conversation") : name
    }

    /// Which terminal has it, if that's known already.
    @discardableResult
    func askAgent(preset: TerminalPreset, prompt: String, about: String? = nil) -> ItemID? {
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
            return running.id
        }
        let before = Set(active.items.map(\.id))
        startTerminal(command: preset.command + " " + ShellQuote.quote(prompt), named: preset.name)
        let started = active.items.first { !before.contains($0.id) }?.id
        if let about, let started { agentAsked[started] = about }
        return started
    }

    func openKeyboardShortcuts() { openSettings(pane: .keyboard) }

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
        giveKeyboard(to: id, in: window, tries: 20)
    }

    /// SwiftUI hosts the view a moment after the window appears, and until then there's nothing to focus.
    private func giveKeyboard(to id: ItemID, in window: NSWindow, tries: Int) {
        if let view = existingController(for: id)?.view, view.window === window {
            controller(for: id)?.focus()
            return
        }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let self, let window else { return }
            self.giveKeyboard(to: id, in: window, tries: tries - 1)
        }
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
        // Except one that's waiting to be handed back: typing in it is the point, and it stays where it is.
        if waitingFor.contains(id), active.peek?.id == id { return }
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

    func save(_ controller: ItemController, then done: @escaping () -> Void) {
        switch controller.save(overwriting: false) {
        case .saved:
            done()
        case .failed(let why):
            showToast(title: String(localized: "Couldn't save"), detail: why, symbol: "exclamationmark.triangle", tint: .orange)
        case .changedOnDisk:
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "This file changed on disk")
            alert.informativeText = String(localized: "Something else, perhaps an agent, changed it after you started editing. Saving replaces that with what you have here.")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Compare"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn, case .saved = controller.save(overwriting: true) { done() }
                    if response == .alertSecondButtonReturn { self?.compareWithDisk(controller.itemID) }
                }
            }
        }
    }

    /// What's on disk beside what you have here, in the diff viewer.
    func compareWithDisk(_ id: ItemID) {
        guard let path = anyItem(id)?.filePath else { return }
        var spec = DiffSpec(path: path)
        spec.unsaved = true
        openDiff(spec, preview: false)
    }

    /// The edits not saved yet in the editor open on this file, if it has any.
    func unsavedText(of path: String) -> String? {
        for (id, controller) in controllers where controller.isDirty && anyItem(id)?.filePath == path {
            if let text = controller.unsavedText { return text }
        }
        return nil
    }

    /// Save All, as quitting asks. A file something else changed since isn't overwritten: its edits are kept
    /// unsaved, and come back with it. False if one couldn't be saved or kept.
    func saveAllEdits() -> Bool {
        for controller in controllers.values where controller.isDirty {
            switch controller.save(overwriting: false) {
            case .saved:
                continue
            case .changedOnDisk:
                if controller.keepUnsavedEdits() { continue }
                save(controller) {}
                return false
            case .failed(let why):
                showToast(title: String(localized: "Couldn't save"), detail: why, symbol: "exclamationmark.triangle", tint: .orange)
                return false
            }
        }
        return true
    }

    // MARK: Search

    /// The files worth searching: what git counts as the project, which leaves out what
    /// .gitignore does, or else everything the explorer shows.
    /// The search behind ⌘⇧F and `tiri search`, wherever the files are.
    nonisolated static func runSearch(query: String, on connection: RemoteConnection?, folders: [String], paths: [String], excludes: [String],
                                      cancellation: ContentSearch.Cancellation, found: @escaping @Sendable ([ContentMatch]) -> Void) {
        if let connection {
            RemoteSearch.run(connection: connection, folders: folders, query: query, excludes: excludes, cancellation: cancellation, found: found)
        } else {
            ContentSearch.run(paths: paths, query: query, cancellation: cancellation, found: found)
        }
    }

    var activeConnection: RemoteConnection? { active.remote.flatMap { remote.existingConnection($0) } }

    /// On a server the contents aren't here to read, so the server says which files mention the
    /// name, and those are brought here to look through like any others.
    func symbolSearchPaths(for symbol: String) async -> [String] {
        guard let connection = activeConnection else { return await searchablePaths() }
        let folders = active.folders
        let excludes = settings.filesExclude
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let files = RemoteSearch.filesMentioning(symbol, connection: connection, folders: folders, excludes: excludes)
            connection.fetchAndWait(files.filter { connection.needsFetch($0) }, timeout: 20)
            return files
        }.value
    }

    func searchablePaths() async -> [String] {
        if active.remote != nil { return active.items.compactMap(\.filePath) }
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
    /// Each workspace in a window has its own: another workspace's changes can't show here, even for a moment.
    private func watchForChanges(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let live = live(id)
        if live.watchedFolders != workspace.folders {
            live.watchedFolders = workspace.folders
            live.changesTokens = workspace.folders.map { folder in
                FileWatchHub.shared.watch(path: folder, recursive: true) { [weak self] in self?.scheduleChangesRefresh(id) }
            }
        }
        refreshChanges(id)
    }

    func scheduleChangesRefresh(_ id: WorkspaceID? = nil) {
        let id = id ?? activeID
        guard let live = lives[id], !live.changesPaused else { return }
        live.changesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshChanges(id) }
        live.changesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Once: git may be somewhere only the person's shell setup puts on the PATH.
    private func learnUserPath() {
        guard !askedShellForPath else { return }
        askedShellForPath = true
        let shell = settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : settings.terminalShell
        Task { [weak self] in
            let path = await ShellLookup.path(shell: shell)
            if let path, self?.userPath == nil { self?.userPath = path }
        }
    }
    @ObservationIgnored private var askedShellForPath = false

    /// The workspace in front, or another in a window.
    func refreshChanges(_ id: WorkspaceID? = nil) {
        let workspaceID = id ?? activeID
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let live = live(workspaceID)
        guard !live.changesInFlight else {
            live.changesAgain = true
            return
        }
        // Nothing can be asked until it's back, and not knowing isn't the same as no changes.
        if let destination = workspace.remote, !remote.state(of: destination).isReady { return }
        // git took too long last time. Asking again at once, for every file saved, would keep it busy for nothing.
        if let until = live.changesQuietUntil, until > Date() {
            live.changesWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshChanges(workspaceID) }
            live.changesWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow, execute: work)
            return
        }
        live.changesInFlight = true
        let folders = workspace.folders
        Task.detached(priority: .userInitiated) { [weak self] in
            let scan = Git.scanChangesAcross(folders, timeout: ChangesNotice.timeout)
            let found = scan.files
            // It would be just as slow, and the status bar keeps what it had.
            let repositories = scan.timedOut ? nil : Git.repositoriesAcross(folders)
            let needsGit = DeveloperTools.git == nil && folders.contains(where: Git.looksLikeRepository)
            await MainActor.run {
                guard let self else { return }
                live.changesInFlight = false
                // No window shows it any more.
                guard self.lives[workspaceID] === live else { return }
                live.needsGit = needsGit
                if needsGit, self.userPath == nil { self.learnUserPath() }
                self.refreshReviewLines(in: workspaceID)
                self.refreshScopedChanges(workspaceID)
                self.refreshOtherWork(workspaceID)
                ChangesNotice.record(scan, in: live)
                guard let repositories else {
                    // There's a repository, or git wouldn't have been asked, and Changes is where that's said.
                    if !live.barHasRepositories { live.barHasRepositories = true }
                    if live.changesAgain {
                        live.changesAgain = false
                        self.refreshChanges(workspaceID)
                    }
                    return
                }
                live.barHasRepositories = !repositories.isEmpty
                if live.changes != found { live.changes = found }
                if live.repositories != repositories {
                    let headsMoved = live.repositories.map(\.head) != repositories.map(\.head)
                    live.repositories = repositories
                    self.watchGitDirectories(of: repositories, folders: folders, in: live)
                    if headsMoved { self.refreshChangeMarks(in: workspaceID) }
                }
                // Whatever's on screen compares against the same new state.
                if let shown = self.workspaces.first(where: { $0.id == workspaceID }) {
                    for item in shown.items + (shown.peek.map { [$0] } ?? []) {
                        if case .diff = item.content { (self.existingController(for: item.id) as? DiffController)?.load() }
                    }
                }
                if live.changesAgain {
                    live.changesAgain = false
                    self.refreshChanges(workspaceID)
                }
            }
        }
    }

    // MARK: Fetch, pull and push

    /// A commit or a push from a terminal moves the counts. When git's folder is outside the
    /// workspace, as for a subfolder of a repository or a worktree, nothing else would hear it.
    private func watchGitDirectories(of repositories: [RepositoryStatus], folders: [String], in live: WorkspaceLive) {
        var tokens: [String: FileWatchHub.Token] = [:]
        let id = live.id
        for directory in repositories.flatMap(\.gitDirectories)
        where !folders.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) {
            tokens[directory] = live.repositoryTokens[directory]
                ?? FileWatchHub.shared.watch(path: directory, recursive: true) { [weak self] in self?.scheduleChangesRefresh(id) }
        }
        live.repositoryTokens = tokens
    }

    /// The repository of what you're looking at, for the palette. The status bar names its own.
    var frontRepository: RepositoryStatus? {
        let directory = defaultTerminalDirectory()
        return repositories.first { directory == $0.root || directory.hasPrefix($0.root + "/") } ?? repositories.first
    }

    func fetch(_ repository: RepositoryStatus) {
        guard let remote = repository.remote else {
            showToast(title: String(localized: "Nothing to fetch from"), detail: String(localized: "\(repository.name) has no remote."), symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        transfer(.fetching, repository: repository, arguments: ["fetch", remote], failure: String(localized: "Couldn't fetch")) { [weak self] updated in
            guard let self else { return }
            let new = (updated?.behind ?? 0) - repository.behind
            let target = updated?.upstream ?? remote
            let title = new == 1 ? String(localized: "1 commit to pull from \(target)")
                : new > 1 ? String(localized: "\(new) commits to pull from \(target)")
                : String(localized: "\(target) has nothing new")
            self.showToast(title: title, detail: nil,
                           symbol: "checkmark.circle.fill", tint: .green)
        }
    }

    /// Doesn't ask: it only moves the branch forward to commits the remote already has, and the
    /// way back is one `git reset`. Anything that would need a decision fails and says so.
    func pull(_ repository: RepositoryStatus) {
        guard repository.canPull, let target = repository.upstream else {
            showToast(title: String(localized: "Nothing to pull from"), detail: String(localized: "\(repository.displayTitle) doesn't track a remote branch yet."), symbol: "checkmark.circle", tint: .secondary)
            return
        }
        transfer(.pulling, repository: repository, arguments: Git.pullArguments, failure: String(localized: "Couldn't pull")) { [weak self] updated in
            self?.showToast(title: updated?.shortOID == repository.shortOID ? String(localized: "\(target) has nothing new") : String(localized: "Pulled from \(target)"), detail: nil,
                            symbol: "checkmark.circle.fill", tint: .green)
        }
    }

    /// Asks first, every time: it's the one thing here that can't be taken back, and some remotes deploy what they receive.
    func confirmPush(_ repository: RepositoryStatus) {
        guard let window else { return }
        guard repository.canPush || repository.canPublish, let branch = repository.branch else {
            showToast(title: String(localized: "Nothing to push"), detail: repository.remote == nil ? String(localized: "\(repository.name) has no remote.") : String(localized: "\(repository.displayTitle) has no commits to send."),
                      symbol: "checkmark.circle", tint: .secondary)
            return
        }
        let target = repository.upstream ?? "\(repository.remote ?? "origin")/\(branch)"
        let alert = NSAlert()
        alert.messageText = repository.upstream == nil ? String(localized: "Publish \(branch) to \(repository.remote ?? "origin")?")
            : repository.ahead == 1 ? String(localized: "Push 1 commit to \(target)?") : String(localized: "Push \(repository.ahead) commits to \(target)?")
        var details = [String(localized: "From \(repository.name).")]
        if repository.isDirty { details.append(String(localized: "Uncommitted changes stay here.")) }
        if repository.behind == 1 { details.append(String(localized: "\(target) also has 1 commit you don't have, so it will probably refuse.")) }
        if repository.behind > 1 { details.append(String(localized: "\(target) also has \(repository.behind) commits you don't have, so it will probably refuse.")) }
        alert.informativeText = details.joined(separator: " ")
        alert.addButton(withTitle: repository.upstream == nil ? String(localized: "Publish") : String(localized: "Push"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.transfer(.pushing, repository: repository, arguments: repository.pushArguments, failure: String(localized: "Couldn't push")) { [weak self] _ in
                    let title = repository.upstream == nil ? String(localized: "Published to \(target)")
                        : repository.ahead == 1 ? String(localized: "Pushed 1 commit to \(target)") : String(localized: "Pushed \(repository.ahead) commits to \(target)")
                    self?.showToast(title: title,
                                    detail: nil, symbol: "checkmark.circle.fill", tint: .green)
                }
            }
        }
    }

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
                for live in self.lives.values {
                    if let updated, let index = live.repositories.firstIndex(where: { $0.root == root }) { live.repositories[index] = updated }
                }
                switch result {
                case .success:
                    succeeded(updated)
                case .failure(let problem):
                    self.gitButtonFailed(failure, problem: problem.message, shown: L10n.display(problem.message), command: arguments, root: root)
                }
            }
        }
    }

    /// The buttons only do the simple thing. Anything further is for an agent, except a remote that
    /// wants a password, which needs a person at a terminal.
    private func gitButtonFailed(_ failure: String, problem: String, shown: String, command: [String], root: String) {
        let lower = problem.lowercased()
        let wantsPerson = ["password", "passphrase", "could not read username", "terminal prompts disabled", "authentication failed"].contains(where: lower.contains)
        guard !wantsPerson, let preset = firstAgentPreset else {
            showToast(title: failure, detail: shown, symbol: "exclamationmark.triangle", tint: .orange,
                      actionTitle: String(localized: "Open Terminal")) { [weak self] in self?.newTerminal(cwd: root) }
            return
        }
        let prompt = "`git \(command.joined(separator: " "))` failed in \(root):\n\(problem)\nPlease sort this out, and tell me if there's anything you need me to decide."
        showToast(title: failure, detail: shown, symbol: "exclamationmark.triangle", tint: .orange,
                  actionTitle: String(localized: "Ask \(preset.name)")) { [weak self] in self?.askAgent(preset: preset, prompt: prompt) }
    }

    /// The first agent in the New Terminal menu.
    var firstAgentPreset: TerminalPreset? {
        settings.activePresets.first { AgentCatalog.profile(executable: $0.command.split(separator: " ").first.map(String.init) ?? "") != nil }
    }

    func openDiff(_ spec: DiffSpec, preview: Bool) {
        updateActive { $0.dismissPeek(); $0.openDiff(spec, preview: preview) }
        requestFocus()
    }

    /// Takes the Peek's place. With `takeFocus`, a person asked. Without it, an agent is showing something.
    func peekDiff(_ spec: DiffSpec, takeFocus: Bool) {
        // Already in a tab, like a file would be: go there rather than float a second copy over it.
        if takeFocus, let open = active.items.first(where: { if case .diff(let other) = $0.content { other == spec } else { false } }) {
            dismissPeek(restoreFocus: false)
            focusItem(open.id)
            return
        }
        updateActive { $0.peekDiff(spec) }
        peekHasKeyboard = takeFocus
        requestFocus()
    }

    /// Switch between a file and what changed in it, wherever it's showing.
    func toggleChangesForFront() {
        guard let item = active.peek ?? active.activeItem else { return }
        let isPeek = active.peek?.id == item.id
        switch item.content {
        case .file(let spec):
            if isPeek { peekDiff(DiffSpec(path: spec.path), takeFocus: true) } else { openDiff(DiffSpec(path: spec.path), preview: false) }
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
        guard let live = lives[activeID] else { return false }
        _ = live.changes
        return live.changedPaths.contains(path)
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
            alert.messageText = String(localized: "Tell Tiri exactly what \(tool.title) is doing?")
            alert.informativeText = String(localized: "Tiri adds a small hook to \(path), and keeps a copy of the file next to it. The hook does nothing outside Tiri.") + "\n\n" + AgentHooks.summary(of: tool)
            alert.addButton(withTitle: String(localized: "Install"))
        } else {
            alert.messageText = String(localized: "Remove Tiri's hooks from \(tool.title)?")
            alert.informativeText = String(localized: "Tiri takes its entries out of \(path) and leaves the rest. Status goes back to an estimate.")
            alert.addButton(withTitle: String(localized: "Remove"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.applyHooks(tool, install: install) }
            }
        }
    }

    /// Which agent's hooks already reach this one, if any do. Grok runs Claude Code's by default.
    func hooksCoverage(_ tool: AgentHooks.Tool) -> AgentHooks.Tool? {
        guard let other = tool.profile?.alsoRunsHooksOf.flatMap(AgentIdentity.init(rawValue:)), hooksInstalled(other) else { return nil }
        return other
    }

    /// A settings file can list the New Terminal menu in full, which would hide a new agent.
    private func adoptNewAgents() {
        let key = "knownAgents"
        let known = UserDefaults.standard.stringArray(forKey: key).map(Set.init) ?? AgentCatalog.alwaysKnown
        let adopted = AgentCatalog.adopting(into: settings.terminalPresets, resume: settings.terminalResume, known: known)
        UserDefaults.standard.set(adopted.known.sorted(), forKey: key)
        if adopted.presets != settings.terminalPresets {
            _ = setSetting("terminal.presets", to: TerminalPreset.json(adopted.presets))
        }
        if adopted.resume != settings.terminalResume {
            _ = setSetting("terminal.resume", to: .object(adopted.resume.mapValues(JSONValue.string)))
        }
    }

    private func applyHooks(_ tool: AgentHooks.Tool, install: Bool) {
        let url = AgentHooks.configURL(for: tool)
        let manager = FileManager.default
        do {
            // Only a file that isn't there is empty. One that can't be read stays as it is.
            let existing = try SafeFile.readText(url)
            let text = existing ?? ""
            let updated = install ? try AgentHooks.installing(tool, in: text) : try AgentHooks.removing(tool, from: text)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if existing != nil, case .ownFile? = tool.profile?.hookInstall {
                // Tiri's own file, with nothing of anyone else's to keep.
            } else if let existing {
                // The file as it was before Tiri ever touched it, so removing the hooks doesn't replace it.
                try SafeFile.keepFirstCopy(Data(existing.utf8), at: url.appendingPathExtension("tiri-backup"))
            }
            if updated.isEmpty, case .ownFile = tool.profile?.hookInstall {
                try? manager.removeItem(at: url)
            } else if updated != existing {
                // Through a link to the file it leads to, keeping that file's mode.
                try SafeFile.replace(url, with: Data(updated.utf8))
            }
            hooksRevision += 1
            showToast(title: install ? String(localized: "\(tool.title) hooks are on") : String(localized: "\(tool.title) hooks are off"),
                      detail: install ? String(localized: "New \(tool.title) sessions report their status exactly.") : nil,
                      symbol: "checkmark.circle.fill", tint: .green)
        } catch {
            showToast(title: String(localized: "Couldn't change \(tool.title)'s config"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    /// Asked when an agent without hooks finishes its first turn: that's when you look back to see
    /// whether it's done, and see an estimate. Not as it starts, when the agent's own first
    /// screens have you. It stays until it's answered, and closing it is an answer too; quitting
    /// first isn't, so it's asked again next time.
    func offerHooksIfNeeded(_ tool: AgentHooks.Tool) {
        let key = "offeredHooks.\(tool.rawValue)"
        guard tool.profile?.hookInstall != nil, isAgentEnabled(tool), !UserDefaults.standard.bool(forKey: key),
              !hooksOfferedThisLaunch.contains(key), !hooksInstalled(tool), hooksCoverage(tool) == nil else { return }
        hooksOfferedThisLaunch.insert(key)
        let answered = { UserDefaults.standard.set(true, forKey: key) }
        showToast(title: String(localized: "Get exact status from \(tool.title)?"), detail: String(localized: "Right now Tiri is estimating when it's working or done."),
                  symbol: "waveform.path.ecg", tint: .accentColor, actionTitle: String(localized: "Set Up"), duration: nil,
                  other: (String(localized: "Not Now"), answered), action: { [weak self] in
            answered()
            self?.confirmHooks(tool, install: true)
        }, closed: answered)
    }

    // MARK: What's installed

    /// The first word of each New Terminal preset that the user's shell can run. Nil until the
    /// shell has answered, or if it didn't, so nothing is hidden on a guess.
    private(set) var availableCommands: Set<String>?
    private var isLookingUpCommands = false

    func agentPresets() -> [TerminalPreset] {
        settings.activePresets.filter { !$0.command.isEmpty }
    }

    static func tool(of preset: TerminalPreset) -> String {
        preset.command.split(separator: " ").first.map(String.init) ?? preset.command
    }

    /// Agents that can start, as far as anyone knows. Commands that aren't plain names can't be asked about.
    func runnableAgentPresets() -> [TerminalPreset] {
        if let destination = active.remote {
            // What counts is what the server can run. Not known yet: don't hide anything on a guess.
            guard let found = remote.commandsOnServer[destination] else { return agentPresets() }
            return agentPresets().filter {
                let tool = Self.tool(of: $0)
                return found.contains(tool) || !ShellLookup.isPlainName(tool)
            }
        }
        guard let availableCommands else { return agentPresets() }
        return agentPresets().filter {
            let tool = Self.tool(of: $0)
            return availableCommands.contains(tool) || !ShellLookup.isPlainName(tool)
        }
    }

    /// Called while the screen that needs it is up, including on coming back from installing one.
    func refreshAvailableCommands() {
        guard !isLookingUpCommands else { return }
        // Those turned off too, so turning one on already knows whether it's there.
        let names = agentEntries.map(\.id) + ["tiri"]
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
            showToast(title: String(localized: "Can't install the tiri command yet"), detail: problem, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        let link = commandLineLink
        let path = (link.path as NSString).abbreviatingWithTildeInPath
        let replacing = commandLineState() == .otherFile
        let alert = NSAlert()
        if install {
            alert.messageText = String(localized: "Use tiri in your other terminals?")
            alert.informativeText = String(localized: "Tiri adds a link at \(path). It follows the app when you update, and Settings can remove it.")
                + (replacing ? "\n\n" + String(localized: "This replaces the file already at that path.") : "")
            alert.addButton(withTitle: replacing ? String(localized: "Replace") : String(localized: "Install"))
        } else {
            alert.messageText = String(localized: "Remove the tiri command?")
            alert.informativeText = String(localized: "Tiri removes the link at \(path). Terminals inside Tiri keep their own.")
            alert.addButton(withTitle: String(localized: "Remove"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
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
                    self.showToast(title: String(localized: "Couldn't change the tiri command"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
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
                showToast(title: String(localized: "One more step for the tiri command"),
                          detail: String(localized: "Your shell doesn't look in ~/.local/bin yet. Copy this line into its setup file."),
                          symbol: "terminal", tint: .accentColor, actionTitle: String(localized: "Copy Line")) { Clipboard.copy(line) }
            } else {
                showToast(title: String(localized: "tiri works in your other terminals"), detail: String(localized: "New terminals will have it."),
                          symbol: "checkmark.circle.fill", tint: .green)
            }
        }
    }

    // MARK: Keyboard shortcuts

    /// Saves a shortcut, or removes it if the key is nil. Returns why it couldn't, if it couldn't.
    @discardableResult
    func setShortcut(_ command: String, key: String?, announcing: Bool = true) -> String? {
        if let key, let problem = Keymap.problem(with: key, command: command, bindings: keybindings) {
            showToast(title: String(localized: "That shortcut won't work"), detail: Keymap.shownProblem(with: key, command: command, bindings: keybindings) ?? problem, symbol: "keyboard", tint: .orange)
            return problem
        }
        let strokes = key.flatMap(Keymap.parseStrokes)
        let previous = keybindings.first { $0.strokes == strokes && $0.command != command }
        do {
            try settingsStore.writeKeybindings(Keymap.rebound(user: settingsStore.userKeybindings, command: command, key: key))
        } catch {
            if let needsFixing = error as? SettingsStore.FileNeedsFixing { showFileNeedsFixing(needsFixing) }
            return "\(error)"
        }
        if announcing, let previous {
            let title = allCommands.first { $0.id == previous.command }?.shownTitle ?? previous.command
            showToast(title: String(localized: "\(previous.symbol) was \(title)"), detail: String(localized: "That command has no shortcut on this key now."), symbol: "keyboard", tint: .secondary)
        }
        return nil
    }

    @discardableResult
    func resetShortcut(_ command: String) -> String? {
        do {
            try settingsStore.writeKeybindings(Keymap.reset(user: settingsStore.userKeybindings, command: command))
            return nil
        } catch {
            if let needsFixing = error as? SettingsStore.FileNeedsFixing { showFileNeedsFixing(needsFixing) }
            return "\(error)"
        }
    }

    /// A change that would have written over a file someone has to fix first. What's wrong, and the file, one click away.
    func showFileNeedsFixing(_ needsFixing: SettingsStore.FileNeedsFixing) {
        let file = needsFixing.file
        showToast(title: String(localized: "Fix \(file.lastPathComponent) first"), detail: needsFixing.why, symbol: "exclamationmark.triangle", tint: .orange,
                  actionTitle: String(localized: "Open"), duration: 12) { [weak self] in
            self?.open(path: DurableFile.resolved(file).path, intent: .pinned)
        }
    }

    func shortcutIsCustom(_ command: String) -> Bool {
        settingsStore.userKeybindings.contains { $0.command == command || $0.command == "-" + command }
    }

    func beginRecordingShortcut(for command: String) {
        recordingWork?.cancel()
        recordedStrokes = []
        keyResolver.reset()
        shortcutNotice = nil
        isFindingShortcutKey = false
        recordingShortcutFor = command
    }

    /// Asks for one key press, then lists what that key does.
    func beginFindingShortcutKey() {
        cancelRecordingShortcut()
        shortcutNotice = nil
        settingsUI.shortcutKeys = []
        isFindingShortcutKey = true
    }

    func cancelFindingShortcutKey() { isFindingShortcutKey = false }

    func findShortcutKey(_ stroke: KeyStroke) {
        isFindingShortcutKey = false
        guard !(stroke.modifiers.isEmpty && stroke.key == "escape") else { return }
        settingsUI.shortcutKeys = [stroke]
    }

    func confirmShortcutConflict() {
        guard case .conflict(let command, let key, _) = shortcutNotice else { return }
        shortcutNotice = nil
        // You've seen who loses it, so there's nothing to announce.
        setShortcut(command, key: key, announcing: false)
    }

    private var shortcutTitles: [String: String] {
        Dictionary(shortcutCommands.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
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
        guard !key.isEmpty else { return }
        if let problem = Keymap.problem(with: key, command: command, bindings: keybindings) {
            shortcutNotice = .problem(command: command, message: Keymap.shownProblem(with: key, command: command, bindings: keybindings) ?? problem)
            return
        }
        let holders = ShortcutIndex.holders(of: key, except: command, in: keybindings)
        guard holders.isEmpty else {
            let titles = shortcutTitles
            shortcutNotice = .conflict(command: command, key: key, holders: holders.map { titles[$0] ?? $0 })
            return
        }
        setShortcut(command, key: key, announcing: false)
    }

    /// Every open item takes the settings again: after a theme or a look changes, which don't show in `settings`.
    func reapplyControllerSettings() {
        for controller in controllers.values { controller.applySettings() }
    }

    private func applySettings() {
        let previous = settings
        settings = settingsStore.settings
        if previous.languageServers, !settings.languageServers { languageServers.stopAll() }
        if previous.conversationsSummarizeAll != settings.conversationsSummarizeAll { updateSummarizingAll() }
        if previous.language != settings.language { offerLanguageRestart() }
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
            rebindTrees()
            fileIndex.invalidate()
        } else if previous.explorerCompactFolders != settings.explorerCompactFolders {
            rebindTrees()
        }
    }

    private func rebindTrees() {
        for workspace in workspaces { lives[workspace.id]?.bindTree(workspace, force: true) }
    }

    func rebuildKeybindings() {
        keybindings = Keymap.build(user: settingsStore.userKeybindings, plugins: plugins.defaultKeys)
        keyResolver = KeyResolver(bindings: keybindings)
    }

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
        resolveTheme()
        applyColorTheme()
    }

    /// AppKit looks for the accent in the app's own defaults before the Mac's, so one written
    /// there colors everything, native switches and selections included, and survives a relaunch
    /// without reading settings first. It's only reread on the notice System Settings sends when
    /// the accent changes, which every app hears and answers by redrawing, so it's sent only on a change.
    private func applyColorTheme() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let wanted = activeTheme.accent?.system ?? Self.testCopyMacAccent
        let stored = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        guard stored["AppleAccentColor"] as? Int != wanted?.number || stored["AppleHighlightColor"] as? String != wanted?.highlight else { return }
        if let wanted {
            UserDefaults.standard.set(wanted.number, forKey: "AppleAccentColor")
            UserDefaults.standard.set(wanted.highlight, forKey: "AppleHighlightColor")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleAccentColor")
            UserDefaults.standard.removeObject(forKey: "AppleHighlightColor")
        }
        DistributedNotificationCenter.default().postNotificationName(.init("AppleAquaColorVariantChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// A test copy can stand in for a Mac whose accent isn't pink, without changing this one's.
    private static var testCopyMacAccent: (number: Int, highlight: String)? {
        guard isTestCopy, ProcessInfo.processInfo.environment["TIRI_DEV_MAC_ACCENT"] == "blue" else { return nil }
        return (4, "0.698039 0.843137 1.000000 Blue")
    }

    func setTheme(_ mode: ThemeMode) {
        do {
            try settingsStore.writeTheme(mode)
        } catch {
            if let needsFixing = error as? SettingsStore.FileNeedsFixing { showFileNeedsFixing(needsFixing) }
            return
        }
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
                // Dark and light can each have their own theme, accent included.
                self.resolveTheme()
                self.applyColorTheme()
                for controller in self.controllers.values { controller.applySettings() }
            }
        }
        // Reduce Transparency and Increase Contrast: a translucent terminal goes solid, and back. Increase Contrast
        // also has its own themes.
        _ = AccessibilityDisplay.shared
        NotificationCenter.default.addObserver(forName: AccessibilityDisplay.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.activeThemeSlot != ThemeSlot.current(dark: self.effectiveDark, increaseContrast: self.increaseContrast) {
                    self.resolveTheme()
                    self.applyColorTheme()
                }
                for controller in self.controllers.values { controller.applySettings() }
            }
        }
        // A new accent, from the Mac or the color setting: terminals hold theirs as fixed colors.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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
                    case .terminal, .settings, .diff, .plugin, .unknown:
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

    @discardableResult
    func showToast(title: String, detail: String?, symbol: String, tint: Color,
                   actionTitle: String? = nil, duration: TimeInterval? = 6, other: (title: String, action: () -> Void)? = nil,
                   action: (() -> Void)? = nil, closed: (() -> Void)? = nil) -> UUID {
        // `action` comes before `closed`: a trailing closure goes to the first closure it can, and is the button's.
        let toast = AppToast(title: title, detail: detail, symbol: symbol, tint: tint, actionTitle: actionTitle, action: action,
                             otherTitle: other?.title, otherAction: other?.action, closed: closed)
        withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.25))) {
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst() }
        }
        AccessibilityDisplay.shared.announce([title, detail].compactMap { $0 }.joined(separator: ". "))
        // A question stays until it's answered: nil is for those.
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, id = toast.id] in
                self?.dismissToast(id)
            }
        }
        return toast.id
    }

    func dismissToast(_ id: UUID) {
        withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.2))) {
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
        palette?.finish()
        palette = PaletteModel(mode: mode, model: self)
    }

    func closePalette(restoreFocus: Bool = true) {
        palette?.finish()
        palette = nil
        if restoreFocus { requestFocus() }
    }

    /// The palette starting with something typed already: `:` for a line, `@` for a symbol.
    func openPalette(typing prefix: String) {
        palette?.finish()
        palette = PaletteModel(mode: .files, model: self, initialQuery: prefix)
    }

    func openPrompt(title: String, initial: String, commit: @escaping (String) -> Void) {
        palette?.finish()
        palette = PaletteModel(mode: .prompt(title: title, commit: commit), model: self, initialQuery: initial)
    }

    // MARK: Commands

    func firstSingleStrokeBinding(for id: String) -> KeyStroke? {
        keybindings.first { $0.command == id && $0.strokes.count == 1 }?.strokes.first
    }

    func shortcutSymbol(for id: String) -> String? {
        keybindings.first { $0.command == id }?.symbol
    }

    var changedShortcuts: Set<String> { ShortcutIndex.changedCommands(user: settingsStore.userKeybindings) }
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
        // Permission is asked for with the first thing worth saying, not at launch, before Tiri has
        // shown what its notifications are for.
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, subtitle: String, workspace: WorkspaceID, item: ItemID) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // The answers come back off the main thread. Delivering needs nothing from it.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted { Self.deliver(title: title, body: body, subtitle: subtitle, workspace: workspace, item: item) }
                }
            case .denied:
                break
            default:
                Self.deliver(title: title, body: body, subtitle: subtitle, workspace: workspace, item: item)
            }
        }
    }

    private nonisolated static func deliver(title: String, body: String, subtitle: String, workspace: WorkspaceID, item: ItemID) {
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
    /// Why the file can't be written right now: it can't be read, or isn't JSON. Writing from what's in memory
    /// would throw away whatever someone has in it, as VS Code also won't.
    private var settingsBlocked: String?
    private var keybindingsBlocked: String?

    /// A change that wasn't made because the file it goes in needs fixing first.
    struct FileNeedsFixing: Error, CustomStringConvertible {
        let file: URL
        let why: String
        var description: String { why }
    }

    func start() {
        ensureFilesExist()
        reload()
        // A link into a dotfiles folder changes where it points, so that file is watched too.
        let paths = Set([settingsURL, keybindingsURL].flatMap { [$0.path, DurableFile.resolved($0).path] })
        tokens = paths.sorted().map { path in FileWatchHub.shared.watch(path: path) { [weak self] in self?.fileChanged() } }
    }

    func ensureFilesExist() {
        let manager = FileManager.default
        try? manager.createDirectory(at: TiriPaths.configDirectory, withIntermediateDirectories: true)
        // Not `fileExists`, which says no for a link whose file has gone: that file is made, and the link kept.
        if !manager.fileExists(atPath: settingsURL.path) {
            try? DurableFile.write(TiriSettings.defaultFileContents, to: settingsURL)
        }
        if !manager.fileExists(atPath: keybindingsURL.path) {
            try? DurableFile.write(Keymap.defaultFileContents, to: keybindingsURL)
        }
    }

    private func fileChanged() {
        reload()
        onChange?()
    }

    /// The file's text, or why there isn't any. Missing is empty: there's nothing in it to lose.
    private static func read(_ url: URL) -> Result<String, FileNeedsFixing> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success("") }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(FileNeedsFixing(file: url, why: String(localized: "Tiri can't read \(url.lastPathComponent).")))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(FileNeedsFixing(file: url, why: String(localized: "\(url.lastPathComponent) isn't UTF-8 text.")))
        }
        return .success(text)
    }

    private func reload() {
        // Any failure keeps the last good values, and the app says so without getting in the way.
        switch Self.read(settingsURL) {
        case .success(let text):
            do {
                let parsed = try TiriSettings.parseReporting(text)
                settings = parsed.settings
                settingsBlocked = nil
                settingsError = parsed.problems.isEmpty ? nil
                    : String(localized: "settings.json: \(parsed.problems.map(\.description).joined(separator: "; ")). Using the default instead.")
            } catch {
                settingsBlocked = String(describing: error)
                settingsError = String(localized: "settings.json: \(String(describing: error)). Using the last good settings.")
            }
        case .failure(let failure):
            settingsBlocked = failure.why
            settingsError = failure.why
        }
        switch Self.read(keybindingsURL) {
        case .success(let text):
            do {
                userKeybindings = try Keymap.parseUserFile(text)
                keybindingsError = nil
                keybindingsBlocked = nil
            } catch {
                keybindingsBlocked = String(describing: error)
                keybindingsError = String(localized: "keybindings.json: \(String(describing: error)). Using the last good keybindings.")
            }
        case .failure(let failure):
            keybindingsBlocked = failure.why
            keybindingsError = failure.why
        }
        currentError = settingsError ?? keybindingsError
    }

    /// The settings file as it is now, if it can be changed at all.
    private func settingsText() throws -> String {
        ensureFilesExist()
        reload()
        if let settingsBlocked { throw FileNeedsFixing(file: settingsURL, why: settingsBlocked) }
        switch Self.read(settingsURL) {
        case .success(let text): return text.isEmpty ? TiriSettings.defaultFileContents : text
        case .failure(let failure): throw failure
        }
    }

    /// Checks the result parses before saving, so a change can't break the file, then applies it.
    func write(_ key: String, value: JSONValue) throws {
        let updated = SettingsFile.setting(key, toJSON: SettingsSchema.json(value), in: try settingsText())
        if let problem = try TiriSettings.parseReporting(updated).problems.first(where: { $0.key == key }) { throw problem }
        try DurableFile.write(updated, to: settingsURL)
        fileChanged()
    }

    func writeKeybindings(_ list: [(key: String, command: String)]) throws {
        ensureFilesExist()
        reload()
        if let keybindingsBlocked { throw FileNeedsFixing(file: keybindingsURL, why: keybindingsBlocked) }
        try DurableFile.write(Keymap.fileContents(user: list), to: keybindingsURL)
        fileChanged()
    }

    func writeTheme(_ mode: ThemeMode) throws {
        try DurableFile.write(SettingsFile.setting("theme", to: mode.rawValue, in: try settingsText()), to: settingsURL)
    }
}

/// The background file list behind quick open.
final class FileIndexStore {
    private(set) var files: [IndexedFile] = [] {
        didSet { byName = nil }
    }
    private var byName: [String: [String]]?
    /// The last list stopped at the cap, so some files aren't in it.
    private(set) var reachedLimit = false
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

    /// Files and folders that are gone leave at once, so nothing offers them while the next walk runs.
    func forget(_ gone: [String]) {
        guard !gone.isEmpty, !files.isEmpty else { return }
        let removed = Set(gone)
        func isGone(_ path: String) -> Bool {
            var path = Substring(path)
            while !path.isEmpty {
                if removed.contains(String(path)) { return true }
                guard let slash = path.lastIndex(of: "/"), slash > path.startIndex else { return false }
                path = path[..<slash]
            }
            return false
        }
        let kept = files.filter { !isGone($0.path) }
        if kept.count != files.count { files = kept }
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
            let (files, reachedLimit) = FileIndexer.index(roots: roots, excludes: excludes)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.building = false
                if self.generation == currentGeneration {
                    self.files = files
                    self.reachedLimit = reachedLimit
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
