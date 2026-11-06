import AppKit
import Observation
import SwiftUI
import TiriCore
import TiriHighlight
import UniformTypeIdentifiers

/// Every action, built-in or from a plugin, in one table. Palette, shortcuts, menus and `tiri run`
/// all read this, so a plugin's command takes the same road Tiri's own do.
final class CommandRegistry {
    private let builtIn: [AppCommand]
    private(set) var byID: [String: AppCommand]
    private(set) var fromPlugins: [AppCommand] = []

    init(builtIn: [AppCommand]) {
        self.builtIn = builtIn
        byID = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })
    }

    var list: [AppCommand] { builtIn + fromPlugins }

    func setPluginCommands(_ commands: [AppCommand]) {
        fromPlugins = commands
        var table = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })
        for command in commands where table[command.id] == nil { table[command.id] = command }
        byID = table
    }
}

/// What's loaded right now. Everything here comes from plugins you turned on, and all of it
/// goes when they go.
struct PluginBuild: Identifiable, Equatable {
    let item: ItemID
    var request: String?
    var plugin: String?
    let started: Date
    var sawWork = false
    var id: ItemID { item }
}

@Observable
final class PluginHost {
    @ObservationIgnored unowned let model: AppModel
    private(set) var plugins: [InstalledPlugin] = []
    private(set) var isLoaded = false
    /// Read by anything drawing what plugins add.
    private(set) var revision = 0
    private(set) var sidebarStates: [String: SidebarState] = [:]
    private(set) var statusStates: [String: PluginStatusContent] = [:]

    struct SidebarState: Equatable {
        var items: [PluginTreeItem] = []
        var problem: String?
        var isLoading = false
        var hasLoaded = false
    }

    @ObservationIgnored var scanMilliseconds: Double?
    @ObservationIgnored private var pendingAlert: (alert: NSAlert, name: String)?
    /// What an agent is writing right now. It isn't ready to be turned on, whatever's in its folder so far.
    var builds: [PluginBuild] = []
    /// Being imported, so not something an agent is building.
    @ObservationIgnored private var arriving: String?
    /// How the last import or export ended, for a test copy to read.
    @ObservationIgnored var lastShare = ""
    @ObservationIgnored private var folderToken: FileWatchHub.Token?
    @ObservationIgnored private var rescanWork: DispatchWorkItem?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored var lastRefresh: [String: Date] = [:]
    @ObservationIgnored var inFlight: Set<String> = []
    /// Asked for again while it was running: what it's working from may already be out of date.
    @ObservationIgnored var askedAgain: Set<String> = []
    @ObservationIgnored private var announcedChanges: [String: String] = [:]
    @ObservationIgnored lazy var processes = PluginProcesses(host: self)
    @ObservationIgnored lazy var runner = PluginRunner(host: self)
    @ObservationIgnored private var fileButtonIndex: [(plugin: InstalledPlugin, button: PluginManifest.FileButton)] = []
    @ObservationIgnored private var viewerIndex: [(plugin: InstalledPlugin, viewer: PluginManifest.Viewer, panel: PluginManifest.Panel)] = []
    @ObservationIgnored private var saveWatchers: Set<String> = []
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var waitingForScan: [() -> Void] = []
    @ObservationIgnored private var declinedAt: [String: Date] = [:]
    @ObservationIgnored private var lastProcessRefresh: [String: Double] = [:]
    /// What each plugin's file marks say, by plugin/id, then by path.
    var fileMarkStates: [String: [String: PluginFileMark]] = [:]
    /// Text in the editor that plugins color, ready to match.
    @ObservationIgnored var highlightRules: [EditorHighlightRule] = []
    @ObservationIgnored var editorEvents = PluginEditorEvents()
    /// The last thing a person did, for a panel asking to reach beyond itself.
    @ObservationIgnored private var lastPersonEvent: NSEvent?
    @ObservationIgnored private var personMonitor: Any?
    /// Plugins whose folder was walked and found to be what was approved, by hash. Forgotten the moment
    /// anything in the plugins folder changes, so only a folder nobody's touched since skips the walk.
    @ObservationIgnored private var checkedHashes: [String: String] = [:]
    @ObservationIgnored private var folderChanges = 0

    init(model: AppModel) {
        self.model = model
    }

    var enabled: [InstalledPlugin] { plugins.filter(\.isOn) }

    func plugin(named name: String) -> InstalledPlugin? { plugins.first { $0.name == name } }
    func enabledPlugin(named name: String) -> InstalledPlugin? { enabled.first { $0.name == name } }

    // MARK: Loading

    /// Off the main thread: launch doesn't wait for this, and neither does anything else.
    func load() {
        listenForDamagedFiles()
        try? FileManager.default.createDirectory(at: PluginLibrary.folder, withIntermediateDirectories: true)
        folderToken = FileWatchHub.shared.watch(path: PluginLibrary.folder.path, recursive: true) { [weak self] in self?.scheduleRescan() }
        try? FileManager.default.createDirectory(at: ClaudeParts.folder, withIntermediateDirectories: true)
        rescan()
    }

    private func scheduleRescan() {
        checkedHashes = [:]
        folderChanges += 1
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func rescan(then done: (() -> Void)? = nil) {
        let started = ProcessClock.now()
        // Only the newest look counts. An older one could have read what's approved before a change to it.
        scanGeneration += 1
        let generation = scanGeneration
        if let done { waitingForScan.append(done) }
        Task {
            let found = await Task.detached(priority: .userInitiated) { PluginLibrary.scan() }.value
            guard generation == scanGeneration else { return }
            scanMilliseconds = ProcessClock.now() - started
            apply(found)
            let waiting = waitingForScan
            waitingForScan = []
            for done in waiting { done() }
        }
    }

    /// Everything plugins add is replaced in one go, so nothing's left behind when one goes.
    private func apply(_ found: [InstalledPlugin]) {
        let before = plugins
        // A folder turning up while one build has nothing to its name yet is that build's, however it
        // got there: an agent can make one without `tiri plugin new`, or with a `tiri` from elsewhere.
        let newcomers = Set(found.map(\.name)).subtracting(before.map(\.name))
        let unnamed = builds.indices.filter { builds[$0].plugin == nil }
        if isLoaded, newcomers.count == 1, let name = newcomers.first, name != arriving, unnamed.count == 1 {
            builds[unnamed[0]].plugin = name
        }
        let beforeOn = Dictionary(uniqueKeysWithValues: enabled.map { ($0.name, $0.hash) })
        let oldScopes = Dictionary(uniqueKeysWithValues: enabled.map { ($0.name, Set(($0.manifest?.grammars ?? []).flatMap { [$0.scope] + ($0.injectTo ?? []) })) })
        let oldServers = Set(enabled.flatMap { PluginLibrary.servers(of: $0).map(\.id) })
        plugins = found
        isLoaded = true
        let on = enabled
        let afterOn = Dictionary(uniqueKeysWithValues: on.map { ($0.name, $0.hash) })
        let changedPlugins = beforeOn.keys.filter { afterOn[$0] != beforeOn[$0] }

        // What other threads read.
        LanguageCatalog.setPluginLanguages(on.flatMap(PluginLibrary.languages(of:)))
        LanguageServerCatalog.setPluginServers(on.flatMap(PluginLibrary.servers(of:)))
        PluginGrammars.set(on.flatMap(PluginLibrary.grammars(of:)))
        SettingsSchema.setPluginDefinitions(on.compactMap(\.manifest).flatMap(SettingsSchema.definitions(for:)))

        model.commands.setPluginCommands(on.flatMap(pluginCommands(of:)))
        model.rebuildKeybindings()
        fileButtonIndex = on.flatMap { plugin in (plugin.manifest?.fileButtons ?? []).map { (plugin, $0) } }
        viewerIndex = on.flatMap { plugin -> [(InstalledPlugin, PluginManifest.Viewer, PluginManifest.Panel)] in
            (plugin.manifest?.viewers ?? []).compactMap { viewer in
                plugin.manifest?.panels?.first { $0.id == viewer.panel }.map { (plugin, viewer, $0) }
            }
        }
        saveWatchers = Set(on.filter { plugin in
            (plugin.manifest?.sidebar ?? []).contains { $0.refresh?.onSave == true } || (plugin.manifest?.statusBar ?? []).contains { $0.refresh?.onSave == true }
                || (plugin.manifest?.fileMarks ?? []).contains { $0.refresh?.onSave == true }
        }.map(\.name))

        rebuildHighlightRules()
        editorEvents.listenersChanged(self)

        // Whatever belonged to a plugin that's gone or different stops here.
        for name in changedPlugins {
            processes.stop(plugin: name)
            PluginProgramTable.stop(owner: name)
            forgetProviders(of: name)
        }
        let arriving = on.filter { beforeOn[$0.name] == nil || beforeOn[$0.name] != $0.hash }
        let carriesLanguages = { (plugin: InstalledPlugin) in plugin.manifest?.languages != nil || plugin.manifest?.grammars != nil }
        ClaudeParts.sync(on)
        if !changedPlugins.isEmpty || arriving.contains(where: carriesLanguages) {
            // A grammar injected into another language changes that language's colors too.
            var scopes = Set(changedPlugins.flatMap { oldScopes[$0] ?? [] })
            for plugin in arriving { scopes.formUnion((plugin.manifest?.grammars ?? []).flatMap { [$0.scope] + ($0.injectTo ?? []) }) }
            HighlightEngine.shared.pluginsChanged()
            model.languagesChanged(restarting: scopes)
            let servers = Set(on.flatMap { PluginLibrary.servers(of: $0).map(\.id) })
            let affected = Set(changedPlugins.flatMap { name in oldServers.filter { $0.hasPrefix(name + ".") } })
            if servers != oldServers || !affected.isEmpty { model.languageServers.catalogChanged(stopping: affected) }
        }
        model.pluginPanelsChanged(changed: Set(changedPlugins).union(afterOn.keys.filter { beforeOn[$0] == nil }))
        updateRefreshTimer()
        revision += 1
        for plugin in on where beforeOn[plugin.name] == nil { refreshProviders(of: plugin.name, onlyIfUnloaded: true) }
        announce(before: before)
    }

    /// A plugin that stopped because its files changed says so, once for each change.
    private func announce(before: [InstalledPlugin]) {
        for plugin in plugins {
            guard case .changed = plugin.state, announcedChanges[plugin.name] != plugin.hash else { continue }
            announcedChanges[plugin.name] = plugin.hash
            model.showToast(title: String(localized: "\(plugin.title) changed, so it's off"), detail: String(localized: "Its files aren't the ones you approved."), symbol: "exclamationmark.shield",
                            tint: .orange, actionTitle: String(localized: "Review"), duration: 12) { [weak self] in self?.askToEnable(plugin.name) }
        }
    }

    // MARK: Commands

    static func fullID(plugin: String, command: String) -> String {
        command.hasPrefix(plugin + ".") ? command : plugin + "." + command
    }

    private func pluginCommands(of plugin: InstalledPlugin) -> [AppCommand] {
        guard let manifest = plugin.manifest else { return [] }
        let name = plugin.name
        var list = (manifest.commands ?? []).map { command in
            AppCommand(id: Self.fullID(plugin: name, command: command.id), title: command.title, category: command.category ?? manifest.displayName) { model in
                let id = Self.fullID(plugin: name, command: command.id)
                Task { await model.plugins.run(id, args: [:]) }
            }
        }
        // Every panel can be shown, whether or not a command mentions it.
        for panel in manifest.panels ?? [] where !(manifest.commands ?? []).contains(where: { $0.panel == panel.id }) {
            list.append(AppCommand(id: "\(name).panel.\(panel.id)", title: "Show \(panel.title)", category: manifest.displayName,
                                   shown: String(localized: "Show \(panel.title)")) { model in
                model.plugins.openPanel(plugin: name, panel: panel.id, args: [:], opening: .tab)
            })
        }
        return list
    }

    /// Whether this id is one of the commands plugins have added.
    func owns(_ fullID: String) -> Bool {
        model.commands.fromPlugins.contains { $0.id == fullID }
    }

    func command(_ fullID: String) -> (plugin: InstalledPlugin, command: PluginManifest.Command)? {
        for plugin in enabled where fullID.hasPrefix(plugin.name + ".") {
            let short = String(fullID.dropFirst(plugin.name.count + 1))
            if let command = plugin.manifest?.commands?.first(where: { $0.id == short }) { return (plugin, command) }
        }
        return nil
    }

    var defaultKeys: [(key: String, command: String)] {
        enabled.flatMap { plugin in
            (plugin.manifest?.commands ?? []).compactMap { command in
                command.key.map { ($0, Self.fullID(plugin: plugin.name, command: command.id)) }
            }
        }
    }

    struct RunResult {
        var ok: Bool
        var output: String
        var problem: String?
    }

    /// Runs a plugin's command. `withArgs` comes from a click, a panel or `tiri run`.
    @discardableResult
    func run(_ fullID: String, args: [String: JSONValue], quietly: Bool = false, workspace: WorkspaceID? = nil) async -> RunResult {
        guard let (plugin, command) = command(fullID) else {
            if fullID.contains(".panel."), let found = enabled.first(where: { fullID.hasPrefix($0.name + ".panel.") }) {
                openPanel(plugin: found.name, panel: String(fullID.dropFirst(found.name.count + 7)), args: args, opening: .tab)
                return RunResult(ok: true, output: "")
            }
            return RunResult(ok: false, output: "", problem: "No plugin command \(fullID). Is it turned on? Run tiri plugin.")
        }
        guard await stillApproved(plugin) else {
            return RunResult(ok: false, output: "", problem: "\(plugin.title) changed, so it's off until you approve it again.")
        }
        var args = args
        if let inputs = command.input, inputs.contains(where: { args[$0.name] == nil }) {
            guard let answered = await askForInputs(inputs, plugin: plugin, command: command, args: args, workspace: workspace) else {
                return RunResult(ok: false, output: "", problem: "Cancelled.")
            }
            args = answered
        }
        if let saving = command.save, let failure = saveBeforeRunning(saving, workspace: workspace) {
            return RunResult(ok: false, output: "", problem: failure)
        }
        let context = runner.context(plugin: plugin, args: args, workspace: workspace, using: (command.exec ?? []) + [command.terminal ?? "", command.ask ?? ""])
        let result: RunResult
        if let exec = command.exec {
            let done = await runner.exec(exec, plugin: plugin, context: context, place: command.where ?? .workspace, timeout: command.timeout ?? 60, workspace: workspace)
            result = RunResult(ok: done.code == 0, output: done.output, problem: done.code == 0 ? nil : done.failure)
            if !quietly {
                let trimmed = done.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if done.code != 0 {
                    model.showToast(title: String(localized: "\(command.title) failed"), detail: String((done.failure ?? trimmed).suffix(300)), symbol: "exclamationmark.triangle", tint: .orange,
                                    actionTitle: String(localized: "Logs"), duration: 10) { [weak self] in self?.showLog(plugin.name) }
                } else if command.show != PluginManifest.Display.none, !trimmed.isEmpty {
                    model.showToast(title: command.title, detail: String(trimmed.suffix(300)), symbol: "puzzlepiece.extension", tint: .accentColor)
                }
            }
        } else if let line = command.terminal {
            let started = await runner.terminal(line, plugin: plugin, context: context, title: command.title, workspace: workspace)
            result = RunResult(ok: started != nil, output: started ?? "", problem: started == nil ? "Couldn't reach where this workspace is." : nil)
        } else if let panel = command.panel {
            openPanel(plugin: plugin.name, panel: panel, args: args, opening: command.open ?? .tab)
            result = RunResult(ok: true, output: "")
        } else if let words = command.ask {
            deliverToAgent(PluginTemplate.fill(words, context))
            result = RunResult(ok: true, output: "")
        } else if let process = command.process, let method = command.method {
            let answer = await processes.call(plugin: plugin, process: process, method: method, params: .object(args), context: context, workspace: workspace)
            switch answer {
            case .success(let value):
                result = RunResult(ok: true, output: value == .null ? "" : PluginTemplate.text(value))
            case .failure(let failure):
                result = RunResult(ok: false, output: "", problem: failure.message)
                if !quietly {
                    model.showToast(title: String(localized: "\(command.title) failed"), detail: failure.message, symbol: "exclamationmark.triangle", tint: .orange,
                                    actionTitle: String(localized: "Logs"), duration: 10) { [weak self] in self?.showLog(plugin.name) }
                }
            }
        } else {
            result = RunResult(ok: false, output: "", problem: "\(command.title) doesn't do anything.")
        }
        if command.exec != nil || command.process != nil { refreshProviders(of: plugin.name, onlyIfUnloaded: false) }
        return result
    }

    /// Words wait in the agent's input until you send them. A plugin can't press Return: what's in a
    /// panel is sandboxed, what's in an agent isn't, and that keystroke is what stands between them. So
    /// they only go somewhere that will hold them as a paste, and not to an agent in the middle of asking
    /// you something, where your next Return would answer it.
    func deliverToAgent(_ text: String) {
        let words = PluginTemplate.plain(text)
        model.withAgent(asking: String(localized: "Which session should get this?")) { [weak model] terminal, agent in
            guard let model else { return }
            guard terminal.terminalView.holdsPastes else {
                model.showToast(title: String(localized: "Didn't send that to \(agent.title)"), detail: String(localized: "It can't hold words as a paste, so they could run by themselves."), symbol: "exclamationmark.shield", tint: .orange)
                return
            }
            if model.runtimes[terminal.itemID]?.status == .needsInput {
                model.showToast(title: String(localized: "\(agent.title) is waiting for your answer"), detail: String(localized: "Answer it first, then try again."), symbol: "exclamationmark.circle", tint: .orange)
                return
            }
            model.focusAgent(terminal)
            terminal.send(text: AgentReference.bracketedPaste(words))
        }
    }

    // MARK: Who's asking

    /// Notes what a person does, from the first panel on. It only keeps the latest event.
    func watchForPerson() {
        guard personMonitor == nil else { return }
        personMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            self?.lastPersonEvent = event
            return event
        }
    }

    /// Whether someone has just clicked or typed in this view. A page can't fake this: it's the
    /// app's own events, not the page's.
    func personJustActed(in view: NSView) -> Bool {
        guard let event = lastPersonEvent, let window = view.window, event.window === window,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 1.5 else { return false }
        if event.type == .leftMouseUp { return view.bounds.contains(view.convert(event.locationInWindow, from: nil)) }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    func showLog(_ name: String) {
        let file = PluginProcesses.logFile(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            model.showToast(title: String(localized: "\(name) hasn't logged anything"), detail: nil, symbol: "doc.text", tint: .secondary)
            return
        }
        model.open(path: file.path, intent: .peek(takeFocus: false))
    }

    // MARK: What's been approved

    /// Whether what's on disk is still what you said yes to. Looked at right before anything runs. A walk
    /// that found it unchanged is trusted until the folder watcher next hears of a change in any plugin,
    /// a tenth of a second or so after it happens: walking node_modules can take seconds, each time.
    func stillApproved(_ plugin: InstalledPlugin) async -> Bool {
        guard enabledPlugin(named: plugin.name)?.hash == plugin.hash else { return false }
        if checkedHashes[plugin.name] == plugin.hash { return true }
        let folder = plugin.folder
        let fingerprint = plugin.fingerprint
        let changesBefore = folderChanges
        let same = await Task.detached(priority: .userInitiated) { PluginTree.fullFingerprint(folder) == fingerprint }.value
        guard enabledPlugin(named: plugin.name)?.hash == plugin.hash else { return false }
        if !same { rescan() }
        // Only if nothing changed while it was being walked.
        if same, folderChanges == changesBefore { checkedHashes[plugin.name] = plugin.hash }
        return same
    }

    /// Nothing turns on without a person pressing this button, and Return doesn't press it: an
    /// agent's question can land while you're typing to it.
    func askToEnable(_ name: String) {
        guard let plugin = plugin(named: name), let manifest = plugin.manifest else { return }
        builds.removeAll { $0.plugin == name }
        if case .broken(let why) = plugin.state {
            model.showToast(title: String(localized: "\(plugin.title) can't run"), detail: why, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        guard let window = model.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        var words: [String] = []
        if case .changed(let changes) = plugin.state {
            alert.messageText = String(localized: "\(plugin.title) has changed. Turn it on again?")
            if !changes.summary.isEmpty { words.append(changes.shownSummary) }
        } else {
            alert.messageText = String(localized: "Turn on \(plugin.title)?")
            if let approval = PluginLibrary.approvals()[name], approval.hash != plugin.hash {
                let changes = PluginChanges(from: approval.files, to: plugin.files)
                if !changes.summary.isEmpty { words.append(String(localized: "Since you last approved it:\n\(changes.shownSummary)")) }
            }
        }
        if let description = manifest.description { words.insert(description, at: 0) }
        let additions = manifest.shownAdditions
        words.append(additions.isEmpty ? String(localized: "Adds nothing.") : String(localized: "Adds \(additions.formatted(.list(type: .and, width: .narrow)))."))
        if !manifest.programs.isEmpty {
            var programs = manifest.programs.prefix(8).map { "• " + $0 }
            if manifest.programs.count > 8 { programs.append(String(localized: "• and \(manifest.programs.count - 8) more")) }
            words.append(String(localized: "Runs these with your full access, including all your files:\n\(programs.joined(separator: "\n"))"))
        }
        if !manifest.networkAddresses.isEmpty { words.append(String(localized: "Its panels can reach \(manifest.networkAddresses.joined(separator: ", ")).")) }
        words += manifest.shownPanelPowers
        if let part = ClaudeParts.summary(of: plugin) { words.append(part) }
        words.append(String(localized: "From \((plugin.folder.path as NSString).abbreviatingWithTildeInPath)"))
        alert.informativeText = words.joined(separator: "\n\n")
        let turnOn = alert.addButton(withTitle: String(localized: "Turn On"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        turnOn.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        pendingAlert = (alert, name)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pendingAlert = nil
                if response == .alertFirstButtonReturn {
                    self?.approve(name, shown: plugin.hash)
                } else {
                    self?.declinedAt[name] = Date()
                }
            }
        }
    }

    func secondsUntilAskingAgain(_ name: String) -> Int? {
        guard !AppModel.isTestCopy, let when = declinedAt[name] else { return nil }
        let left = 60 - Date().timeIntervalSince(when)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// What was on screen has to still be what's on disk.
    private func approve(_ name: String, shown: String) {
        Task {
            // Every file read again, whatever the cache says: this is the record of what you approved.
            let found = await Task.detached(priority: .userInitiated) { PluginLibrary.scan(trustingCache: false) }.value
            guard let plugin = found.first(where: { $0.name == name }), plugin.hash == shown else {
                model.showToast(title: String(localized: "It changed while you were reading"), detail: String(localized: "Nothing was turned on. Have another look."), symbol: "exclamationmark.shield", tint: .orange)
                rescan()
                return
            }
            await runner.ensureUserPath()
            if let failure = await PluginDependencies.install(plugin, path: model.userPath) {
                model.showToast(title: String(localized: "\(plugin.title) couldn't set up"), detail: failure, symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
                return
            }
            PluginLibrary.approve(plugin)
            rescan { [weak self] in
                self?.model.showToast(title: String(localized: "\(plugin.title) is on"), detail: plugin.manifest?.shownAdditions.formatted(.list(type: .and, width: .narrow)), symbol: "puzzlepiece.extension", tint: .green)
            }
        }
    }

    func disable(_ name: String) {
        PluginLibrary.turnOff(name)
        rescan()
    }

    func askToRemove(_ name: String) {
        guard let plugin = plugin(named: name), let window = model.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove \(plugin.title)?")
        alert.informativeText = String(localized: "Its folder goes to the Trash, with its settings and its panels' storage.")
        let remove = alert.addButton(withTitle: String(localized: "Remove"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        pendingAlert = (alert, name)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pendingAlert = nil
                if response == .alertFirstButtonReturn { self?.remove(plugin) }
            }
        }
    }

    private func remove(_ plugin: InstalledPlugin) {
        PluginLibrary.forget(plugin.name)
        PluginSettingsStore.remove(plugin.name)
        if AppModel.isTestCopy {
            try? FileManager.default.removeItem(at: plugin.folder)
        } else {
            try? FileManager.default.trashItem(at: plugin.folder, resultingItemURL: nil)
        }
        // Once its panels have closed: storage that's in use can't be deleted.
        rescan { PluginPanelStorage.remove(plugin: plugin.name) }
    }

    // MARK: Being built

    func building(item: ItemID, request: String?, plugin name: String? = nil) {
        if let index = builds.firstIndex(where: { $0.item == item && ($0.plugin == nil || $0.plugin == name) }) {
            if let name { builds[index].plugin = name }
            if let request { builds[index].request = request }
        } else {
            builds.append(PluginBuild(item: item, request: request, plugin: name, started: Date()))
        }
    }

    /// An agent can pause and carry on, so a build only ends with its terminal, or after a good long while.
    func agentsChanged(_ rows: [AppModel.AgentOverviewRow]) {
        guard !builds.isEmpty else { return }
        var next = builds
        for index in next.indices.reversed() {
            let age = Date().timeIntervalSince(next[index].started)
            guard let row = rows.first(where: { $0.item == next[index].item }), age < 7200 else {
                // Starting takes a moment.
                if age > 20 { next.remove(at: index) }
                continue
            }
            if row.status == .working || row.status == .needsInput { next[index].sawWork = true }
        }
        if next != builds { builds = next }
    }

    /// What's being written right now, as opposed to waiting on somebody or finished.
    var liveBuilds: [PluginBuild] {
        builds.filter { build in
            guard let row = model.agentRows.first(where: { $0.item == build.item }) else { return true }
            return row.status == .working || row.status == .needsInput || !build.sawWork
        }
    }

    func build(of plugin: String) -> PluginBuild? { liveBuilds.first { $0.plugin == plugin } }

    // MARK: Sharing

    static let importableTypes: [UTType] = [UTType(filenameExtension: PluginPackage.fileExtension), UTType(filenameExtension: "vsix"), .zip, .folder].compactMap { $0 }

    func chooseFileToImport() {
        guard let window = model.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.importableTypes
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "A .tiriplugin file, a plugin's folder, a .zip of one, or a VS Code .vsix")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { self?.importPlugin(at: url) }
            }
        }
    }

    /// It always arrives off, and then the usual question says what it adds and runs.
    func importPlugin(at url: URL) {
        Task {
            let couldNot = String(localized: "Couldn't import \(url.lastPathComponent)")
            if url.pathExtension.lowercased() == "vsix" {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                    Result { try VSIXImporter.importFile(url.path, into: PluginLibrary.folder).name }
                }.value
                switch result {
                case .success(let name):
                    arriving = name
                    arrived(name)
                case .failure(let error): shareFailed(couldNot, error)
                }
                return
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PluginPackage.Opened, Error> in
                Result { try PluginPackage.open(url) }
            }.value
            switch result {
            case .failure(let error):
                shareFailed(couldNot, error)
            case .success(let opened):
                if let existing = plugin(named: opened.name) {
                    if existing.hash == opened.hash {
                        opened.discard()
                        lastShare = "same \(opened.name)"
                        model.showToast(title: String(localized: "You already have this"), detail: String(localized: "\(existing.title) \(opened.version) is the same, file for file."), symbol: "checkmark.circle", tint: .secondary)
                        return
                    }
                    askToReplace(existing, with: opened)
                } else {
                    install(opened)
                }
            }
        }
    }

    private func askToReplace(_ existing: InstalledPlugin, with opened: PluginPackage.Opened) {
        guard let window = model.window, window.attachedSheet == nil else {
            opened.discard()
            return
        }
        let alert = NSAlert()
        let from = existing.manifest?.version ?? ""
        alert.messageText = String(localized: "Replace \(existing.title) \(from) with \(opened.version)?")
        alert.informativeText = String(localized: "The one you have goes to the Trash. The new one stays off until you've seen what it adds and runs.")
        let replace = alert.addButton(withTitle: String(localized: "Replace"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        replace.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        pendingAlert = (alert, opened.name)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pendingAlert = nil
                if response == .alertFirstButtonReturn { self?.install(opened) } else { opened.discard() }
            }
        }
    }

    private func install(_ opened: PluginPackage.Opened) {
        arriving = opened.name
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                defer { opened.discard() }
                return Result { try PluginTools.install(opened) }
            }.value
            switch result {
            case .success: arrived(opened.name)
            case .failure(let error): shareFailed(String(localized: "Couldn't import \(opened.title)"), error)
            }
        }
    }

    private func arrived(_ name: String) {
        lastShare = "imported \(name)"
        rescan { [weak self] in self?.askToEnable(name) }
    }

    private func shareFailed(_ title: String, _ error: Error) {
        lastShare = "failed: \(error)"
        model.showToast(title: title, detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
    }

    func chooseWhereToExport(_ name: String) {
        guard let plugin = plugin(named: name), let window = model.window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PluginPackage.defaultFileName(name: plugin.name, version: plugin.manifest?.version ?? "0.0.0")
        panel.allowedContentTypes = [UTType(filenameExtension: PluginPackage.fileExtension) ?? .data]
        panel.prompt = String(localized: "Export")
        panel.message = String(localized: "One file to hand to someone. Its settings stay here.")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { self?.exportPlugin(name, to: url) }
            }
        }
    }

    func exportPlugin(_ name: String, to file: URL) {
        guard let plugin = plugin(named: name) else { return }
        let folder = plugin.folder
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PluginPackage.Exported, Error> in
                Result { try PluginPackage.export(folder, to: file) }
            }.value
            switch result {
            case .failure(let error):
                shareFailed(String(localized: "Couldn't export \(plugin.title)"), error)
            case .success(let exported):
                lastShare = "exported \(name)"
                let detail = exported.leftOut.isEmpty ? file.lastPathComponent
                    : String(localized: "\(file.lastPathComponent). Left out, in case they hold secrets: \(exported.leftOut.joined(separator: ", ")).")
                model.showToast(title: String(localized: "Exported \(plugin.title)"), detail: detail, symbol: "square.and.arrow.up", tint: .green,
                                actionTitle: String(localized: "Show in Finder"), duration: 10) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
    }

    /// What the buttons do, for a test copy. A real answer takes a real press.
    func answerForTest(yes: Bool) -> Bool {
        guard let pendingAlert else { return false }
        pendingAlert.alert.buttons[yes ? 0 : 1].performClick(nil)
        return true
    }

    var pendingQuestion: String? { pendingAlert?.alert.messageText }

    // MARK: Sidebar sections and status items

    func key(_ plugin: String, _ id: String) -> String { plugin + "/" + id }

    struct Section: Identifiable {
        var plugin: InstalledPlugin
        var section: PluginManifest.SidebarSection
        var id: String { plugin.name + "/" + section.id }
        var state: SidebarState
    }

    var sections: [Section] {
        enabled.flatMap { plugin in
            (plugin.manifest?.sidebar ?? []).map { section in
                Section(plugin: plugin, section: section, state: sidebarStates[key(plugin.name, section.id)] ?? SidebarState())
            }
        }
    }

    struct Status: Identifiable {
        var plugin: InstalledPlugin
        var item: PluginManifest.StatusItem
        var content: PluginStatusContent
        var id: String { plugin.name + "/" + item.id }
    }

    var statusItems: [Status] {
        enabled.flatMap { plugin in
            (plugin.manifest?.statusBar ?? []).compactMap { item -> Status? in
                let pushed = statusStates[key(plugin.name, item.id)]
                let fixed = item.text.map { PluginStatusContent(text: $0, symbol: item.symbol, tooltip: item.tooltip, command: item.command) }
                guard var content = pushed ?? fixed, !content.text.isEmpty else { return nil }
                content.symbol = content.symbol ?? item.symbol
                content.tooltip = content.tooltip ?? item.tooltip
                content.command = content.command ?? item.command
                return Status(plugin: plugin, item: item, content: content)
            }
        }
    }

    private func forgetProviders(of name: String) {
        for id in sidebarStates.keys where id.hasPrefix(name + "/") { sidebarStates[id] = nil }
        for id in statusStates.keys where id.hasPrefix(name + "/") { statusStates[id] = nil }
        for id in lastRefresh.keys where id.hasPrefix(name + "/") { lastRefresh[id] = nil }
        if fileMarkStates.keys.contains(where: { $0.hasPrefix(name + "/") }) {
            for id in fileMarkStates.keys where id.hasPrefix(name + "/") { fileMarkStates[id] = nil }
            model.pluginFileMarksChanged()
        }
    }

    /// When a section is drawn. A section nobody has unfolded runs nothing.
    func sectionAppeared(plugin: String, section: String) {
        guard sidebarStates[key(plugin, section)]?.hasLoaded != true else { return }
        refreshSection(plugin: plugin, section: section)
    }

    func refreshProviders(of name: String, onlyIfUnloaded: Bool) {
        guard let manifest = enabledPlugin(named: name)?.manifest else { return }
        for section in manifest.sidebar ?? [] where section.provider != nil {
            // Sections load when they're first seen. After that, they follow what happens.
            let state = sidebarStates[key(name, section.id)]
            if onlyIfUnloaded || state?.hasLoaded != true { continue }
            refreshSection(plugin: name, section: section.id)
        }
        for item in manifest.statusBar ?? [] where item.provider != nil {
            if onlyIfUnloaded, statusStates[key(name, item.id)] != nil { continue }
            refreshStatus(plugin: name, item: item.id)
        }
        for marks in manifest.fileMarks ?? [] where marks.provider != nil {
            if onlyIfUnloaded, fileMarkStates[key(name, marks.id)] != nil { continue }
            refreshFileMarks(plugin: name, marks: marks.id)
        }
    }

    func refreshSection(plugin name: String, section id: String) {
        guard let plugin = enabledPlugin(named: name), let section = plugin.manifest?.sidebar?.first(where: { $0.id == id }), let provider = section.provider else { return }
        let identity = key(name, id)
        guard inFlight.insert(identity).inserted else {
            askedAgain.insert(identity)
            return
        }
        lastRefresh[identity] = Date()
        var state = sidebarStates[identity] ?? SidebarState()
        state.isLoading = true
        sidebarStates[identity] = state
        Task {
            let answer = await ask(provider, plugin: plugin)
            inFlight.remove(identity)
            // Asked of a version that's since changed: the new one asks for itself.
            guard enabledPlugin(named: name)?.hash == plugin.hash else {
                if askedAgain.remove(identity) != nil { refreshSection(plugin: name, section: id) }
                return
            }
            var state = sidebarStates[identity] ?? SidebarState()
            state.isLoading = false
            state.hasLoaded = true
            switch answer {
            case .success(let value):
                state.items = Self.ownOnly(PluginTreeItem.list(from: value), plugin: name)
                state.problem = nil
            case .failure(let failure):
                state.problem = failure.message
            }
            sidebarStates[identity] = state
            if askedAgain.remove(identity) != nil { refreshSection(plugin: name, section: id) }
        }
    }

    /// What's clicked in a list can only ever run the plugin's own commands. What a list says comes
    /// from a program's output, which could be repeating anything.
    private static func ownOnly(_ items: [PluginTreeItem], plugin: String) -> [PluginTreeItem] {
        items.map { item in
            var copy = item
            if let command = item.command { copy.command = fullID(plugin: plugin, command: command) }
            copy.menu = item.menu.map { PluginManifest.MenuItem(title: $0.title, command: fullID(plugin: plugin, command: $0.command), symbol: $0.symbol) }
            copy.children = ownOnly(item.children, plugin: plugin)
            return copy
        }
    }

    func refreshStatus(plugin name: String, item id: String) {
        guard let plugin = enabledPlugin(named: name), let item = plugin.manifest?.statusBar?.first(where: { $0.id == id }), let provider = item.provider else { return }
        let identity = key(name, id)
        guard inFlight.insert(identity).inserted else {
            askedAgain.insert(identity)
            return
        }
        lastRefresh[identity] = Date()
        Task {
            let answer = await ask(provider, plugin: plugin)
            inFlight.remove(identity)
            guard enabledPlugin(named: name)?.hash == plugin.hash else {
                if askedAgain.remove(identity) != nil { refreshStatus(plugin: name, item: id) }
                return
            }
            if case .success(let value) = answer {
                statusStates[identity] = PluginStatusContent(value) ?? PluginStatusContent(text: "")
            }
            if askedAgain.remove(identity) != nil { refreshStatus(plugin: name, item: id) }
        }
    }

    func ask(_ provider: PluginManifest.Provider, plugin: InstalledPlugin) async -> Result<JSONValue, PluginProcesses.Failure> {
        guard await stillApproved(plugin) else { return .failure(.init(message: String(localized: "It changed, so it's off until you approve it again."))) }
        let context = runner.context(plugin: plugin, args: [:], using: provider.exec ?? [])
        if let process = provider.process, let method = provider.method {
            return await processes.call(plugin: plugin, process: process, method: method, params: .object([:]), context: context)
        }
        guard let exec = provider.exec else { return .failure(.init(message: String(localized: "It has no provider."))) }
        let done = await runner.exec(exec, plugin: plugin, context: context, place: provider.where ?? .workspace, timeout: provider.timeout ?? 30)
        guard done.code == 0 else { return .failure(.init(message: done.failure ?? String(localized: "It failed."))) }
        // Up to 8 MB of it, so not on the main thread.
        let output = done.output
        guard let value = await Task.detached(priority: .userInitiated, operation: { try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) }).value else {
            return .failure(.init(message: String(localized: "It didn't print JSON.")))
        }
        return .success(value)
    }

    /// A process saying its lists are out of date. Answering costs a program each time, so not too often.
    func processAskedToRefresh(_ name: String) {
        let now = ProcessClock.now()
        guard now - (lastProcessRefresh[name] ?? 0) > 1000 else { return }
        lastProcessRefresh[name] = now
        refreshProviders(of: name, onlyIfUnloaded: false)
    }

    /// `tiri plugin update`, or a process that knows something changed.
    func push(plugin name: String, surface: String, id: String, value: JSONValue) -> String? {
        guard let manifest = enabledPlugin(named: name)?.manifest else { return "\(name) isn't on." }
        let identity = key(name, id)
        if surface == "marks" {
            guard manifest.fileMarks?.contains(where: { $0.id == id }) == true else { return "\(name) has no file marks \(id)." }
            setFileMarks(PluginFileMark.list(from: value, folder: model.active.folders.first), plugin: name, id: id)
            return nil
        }
        if surface == "sidebar" {
            guard manifest.sidebar?.contains(where: { $0.id == id }) == true else { return "\(name) has no sidebar section \(id)." }
            sidebarStates[identity] = SidebarState(items: Self.ownOnly(PluginTreeItem.list(from: value), plugin: name), hasLoaded: true)
        } else {
            guard manifest.statusBar?.contains(where: { $0.id == id }) == true else { return "\(name) has no status bar item \(id)." }
            statusStates[identity] = PluginStatusContent(value) ?? PluginStatusContent(text: "")
        }
        return nil
    }

    private func updateRefreshTimer() {
        let wanted = enabled.contains { plugin in
            (plugin.manifest?.sidebar ?? []).contains { $0.refresh?.every != nil } || (plugin.manifest?.statusBar ?? []).contains { $0.refresh?.every != nil }
                || (plugin.manifest?.fileMarks ?? []).contains { $0.refresh?.every != nil }
        }
        if !wanted {
            refreshTimer?.invalidate()
            refreshTimer = nil
        } else if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDue() }
            }
        }
    }

    /// Only while you're using Tiri. A timer behind another app has nobody to show anything to.
    private func refreshDue() {
        guard NSApp.isActive else { return }
        let now = Date()
        for plugin in enabled {
            for section in plugin.manifest?.sidebar ?? [] {
                guard let every = section.refresh?.every else { continue }
                let identity = key(plugin.name, section.id)
                guard sidebarStates[identity]?.hasLoaded == true, now.timeIntervalSince(lastRefresh[identity] ?? .distantPast) >= every else { continue }
                refreshSection(plugin: plugin.name, section: section.id)
            }
            for item in plugin.manifest?.statusBar ?? [] {
                guard let every = item.refresh?.every else { continue }
                if now.timeIntervalSince(lastRefresh[key(plugin.name, item.id)] ?? .distantPast) >= every { refreshStatus(plugin: plugin.name, item: item.id) }
            }
            for marks in plugin.manifest?.fileMarks ?? [] {
                guard let every = marks.refresh?.every else { continue }
                if now.timeIntervalSince(lastRefresh[key(plugin.name, marks.id)] ?? .distantPast) >= every { refreshFileMarks(plugin: plugin.name, marks: marks.id) }
            }
        }
    }

    func fileSaved(_ path: String) {
        editorEvents.saved(path, host: self)
        guard !saveWatchers.isEmpty else { return }
        for name in saveWatchers {
            guard let manifest = enabledPlugin(named: name)?.manifest else { continue }
            for section in manifest.sidebar ?? [] where section.refresh?.onSave == true && sidebarStates[key(name, section.id)]?.hasLoaded == true {
                refreshSection(plugin: name, section: section.id)
            }
            for item in manifest.statusBar ?? [] where item.refresh?.onSave == true { refreshStatus(plugin: name, item: item.id) }
            for marks in manifest.fileMarks ?? [] where marks.refresh?.onSave == true { refreshFileMarks(plugin: name, marks: marks.id) }
        }
    }

    /// What's listed may be about this workspace, so another one needs its own answer.
    func workspaceChanged() {
        guard !enabled.isEmpty else { return }
        for plugin in enabled { refreshProviders(of: plugin.name, onlyIfUnloaded: false) }
    }

    /// A click on a row.
    func activate(_ item: PluginTreeItem, plugin: String) {
        if let command = item.command {
            Task { await run(command, args: item.args) }
        } else if let path = item.path {
            let full = path.hasPrefix("/") ? path : model.active.folders.first.map { $0 + "/" + path } ?? path
            model.open(path: full, intent: .preview)
        }
    }

    // MARK: Buttons above files

    func buttons(for path: String) -> [(plugin: InstalledPlugin, button: PluginManifest.FileButton)] {
        guard !fileButtonIndex.isEmpty else { return [] }
        return fileButtonIndex.filter { entry in entry.button.patterns.contains { PluginPattern.matches($0, path: path) } }
    }

    // MARK: Viewers

    /// What should show this file, given what the item already chose.
    func viewer(for spec: FileSpec) -> (plugin: InstalledPlugin, viewer: PluginManifest.Viewer, panel: PluginManifest.Panel)? {
        guard !viewerIndex.isEmpty, spec.viewer != "text" else { return nil }
        let matching = viewerIndex.filter { entry in entry.viewer.patterns.contains { PluginPattern.matches($0, path: spec.path) } }
        if let chosen = spec.viewer { return matching.first { "\($0.plugin.name).\($0.panel.id)" == chosen } }
        return matching.first { ($0.viewer.priority ?? .default) == .default }
    }

    func viewerChoices(for path: String) -> [(plugin: InstalledPlugin, panel: PluginManifest.Panel)] {
        guard !viewerIndex.isEmpty else { return [] }
        return viewerIndex.filter { entry in entry.viewer.patterns.contains { PluginPattern.matches($0, path: path) } }.map { ($0.plugin, $0.panel) }
    }

    // MARK: Panels

    func openPanel(plugin name: String, panel id: String, args: [String: JSONValue], opening: PluginManifest.Opening) {
        guard let plugin = enabledPlugin(named: name), let panel = plugin.manifest?.panels?.first(where: { $0.id == id }) else {
            model.showToast(title: String(localized: "\(name) isn't on"), detail: nil, symbol: "puzzlepiece.extension", tint: .secondary)
            return
        }
        let same = { (item: Item) -> Bool in
            if case .plugin(let spec) = item.content { return spec.plugin == name && spec.panel == id }
            return false
        }
        // One of each, as with a file. Asked for again, it's told what's new.
        if let peek = model.active.peek, same(peek) {
            (model.existingController(for: peek.id) as? WebController)?.panel?.update(args: args)
            return
        }
        if let open = model.active.items.first(where: same) {
            model.updateActive { workspace in
                workspace.updateItem(open.id) { item in
                    if case .plugin(var spec) = item.content {
                        spec.args = args.isEmpty ? spec.args : args
                        item.content = .plugin(spec)
                    }
                }
            }
            (model.existingController(for: open.id) as? WebController)?.panel?.update(args: args)
            model.focusItem(open.id)
            return
        }
        let spec = PluginPanelSpec(plugin: name, panel: id, title: panel.title, args: args.isEmpty ? nil : args)
        let item = Item(content: .plugin(spec))
        model.measureOpen(item.id)
        switch opening {
        case .peek:
            model.updateActive { _ = $0.peekPanel(item) }
            model.peekHasKeyboard = true
        case .tab:
            model.updateActive { $0.addItem(item, split: nil) }
        case .right:
            model.updateActive { $0.addItem(item, split: .right) }
        case .down:
            model.updateActive { $0.addItem(item, split: .down) }
        }
        model.requestFocus()
    }

    /// A tab for one of a plugin's panels, or a note saying why there isn't one.
    func makeController(itemID: ItemID, spec: PluginPanelSpec) -> ItemController {
        guard let plugin = enabledPlugin(named: spec.plugin), let panel = plugin.manifest?.panels?.first(where: { $0.id == spec.panel }) else {
            return PluginOffController(itemID: itemID, spec: spec, model: model)
        }
        watchForPerson()
        let context = PluginPanelContext(plugin: plugin, panel: panel, itemID: itemID, args: spec.args ?? [:], file: nil, writes: false, model: model)
        return WebController(itemID: itemID, url: context.url, forceDark: nil, isFile: false, model: model, panel: context)
    }

    /// A file shown by a plugin's panel, if one should show it.
    func makeViewer(itemID: ItemID, spec: FileSpec) -> ItemController? {
        guard let found = viewer(for: spec) else { return nil }
        watchForPerson()
        let context = PluginPanelContext(plugin: found.plugin, panel: found.panel, itemID: itemID, args: [:], file: spec.path, writes: found.viewer.writes == true, model: model)
        return WebController(itemID: itemID, url: context.url, forceDark: nil, isFile: false, model: model, panel: context)
    }

    /// `from` is a server a process is on. It only reaches panels in that server's workspaces, since
    /// nothing on a server gets to talk to what's on the Mac.
    func post(plugin name: String, panel: String?, event: String, data: JSONValue, from destination: String? = nil) -> Int {
        var reached = 0
        for controller in model.allPanelControllers() where controller.panel?.plugin.name == name && (panel == nil || controller.panel?.panel.id == panel) {
            if let destination, model.workspace(containing: controller.itemID)?.remote != destination { continue }
            controller.panel?.send(event: event, data: data)
            reached += 1
        }
        return reached
    }

    // MARK: Settings

    func settingsChanged(plugin name: String) {
        revision += 1
        if enabledPlugin(named: name)?.manifest?.highlights?.isEmpty == false { rebuildHighlightRules() }
        for controller in model.allPanelControllers() where controller.panel?.plugin.name == name {
            controller.panel?.settingsChanged()
        }
    }

    // MARK: Verifying against this build

    func verify(name: String?) async -> JSONValue {
        var results: [String: JSONValue] = [:]
        let known = Set(model.allCommands.map(\.id))
        for plugin in plugins where name == nil || plugin.name == name {
            guard let manifest = plugin.manifest else { continue }
            var problems: [String] = []
            for panel in manifest.panels ?? [] {
                for command in panel.allow?.commands ?? [] {
                    let own = manifest.commands?.contains { $0.id == command || Self.fullID(plugin: plugin.name, command: $0.id) == command } == true
                    if !own, !known.contains(command) { problems.append("panel \(panel.id) can run \(command), which this Tiri doesn't have") }
                }
            }
            // Only one that's on has its grammars where the engine can see them.
            if plugin.isOn {
                let scopes = (manifest.grammars ?? []).map(\.scope)
                let failing = await Task.detached(priority: .userInitiated) { scopes.filter { !HighlightEngine.shared.canLoad(scope: $0) } }.value
                problems += failing.map { "grammar \($0) doesn't compile in this Tiri's engine" }
            }
            results[plugin.name] = .array(problems.map(JSONValue.string))
        }
        return .object(results)
    }
}

// MARK: - Dependencies

enum PluginDependencies {
    /// Exactly the lockfile, with no install scripts, each time it's approved. Nil means it's ready.
    static func install(_ plugin: InstalledPlugin, path: String?) async -> String? {
        guard FileManager.default.fileExists(atPath: plugin.folder.appendingPathComponent("package-lock.json").path) else { return nil }
        let done = await LocalProgram.run(argv: ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], environment: [:], directory: plugin.folder.path,
                                          path: path, timeout: 300, logName: plugin.name)
        return done.code == 0 ? nil : String((done.failure ?? String(localized: "npm ci failed")).suffix(300))
    }
}

// MARK: - A plugin's part for Claude Code

/// One folder, holding a copy of each part you approved. Claude Code reads it each time it starts, so
/// a shell already open follows plugins coming and going, and an edit to a plugin can't reach an agent.
enum ClaudeParts {
    nonisolated static var folder: URL { TiriPaths.supportDirectory.appendingPathComponent("agent-plugins/claude", isDirectory: true) }

    private nonisolated static let queue = DispatchQueue(label: "tiri.plugins.claude")

    /// What's in here is what's on, and nothing else.
    nonisolated static func sync(_ plugins: [InstalledPlugin]) {
        let wanted = plugins.compactMap { plugin -> (name: String, source: URL, hash: String, version: String)? in
            guard let claude = plugin.manifest?.agent?.claude, let source = PluginValidator.resolve(claude, in: plugin.folder) else { return nil }
            return (plugin.name, source, plugin.hash, plugin.manifest?.version ?? "0.0.0")
        }
        let root = folder
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            let names = Set(wanted.map(\.name))
            for existing in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] where !names.contains(existing) {
                try? manager.removeItem(at: root.appendingPathComponent(existing))
            }
            for part in wanted {
                let target = root.appendingPathComponent(part.name, isDirectory: true)
                let marker = target.appendingPathComponent(".tiri-approved")
                if (try? String(contentsOf: marker, encoding: .utf8)) == part.hash { continue }
                try? manager.removeItem(at: target)
                guard (try? manager.copyItem(at: part.source, to: target)) != nil else { continue }
                try? manager.removeItem(at: target.appendingPathComponent(".git"))
                // Claude Code needs this to see a folder of plugins as plugins.
                let declared = target.appendingPathComponent(".claude-plugin/plugin.json")
                if !manager.fileExists(atPath: declared.path) {
                    try? manager.createDirectory(at: declared.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? SettingsSchema.json(.object(["name": .string(part.name), "version": .string(part.version)])).write(to: declared, atomically: true, encoding: .utf8)
                }
                try? part.hash.write(to: marker, atomically: true, encoding: .utf8)
            }
        }
    }

    /// In words, for the question before turning it on.
    static func summary(of plugin: InstalledPlugin) -> String? {
        guard let claude = plugin.manifest?.agent?.claude, let root = PluginValidator.resolve(claude, in: plugin.folder) else { return nil }
        let manager = FileManager.default
        var parts: [String] = []
        let skills = ((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("skills").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        if !skills.isEmpty { parts.append(String(localized: "skills: \(skills.joined(separator: ", "))")) }
        let agents = ((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("agents").path)) ?? []).filter { !$0.hasPrefix(".") }
        if agents.count == 1 { parts.append(String(localized: "1 subagent")) } else if agents.count > 1 { parts.append(String(localized: "\(agents.count) subagents")) }
        if manager.fileExists(atPath: root.appendingPathComponent("hooks").path) { parts.append(String(localized: "hooks, which run by themselves")) }
        if manager.fileExists(atPath: root.appendingPathComponent(".mcp.json").path) { parts.append(String(localized: "MCP servers")) }
        return parts.isEmpty ? String(localized: "Adds to Claude Code, in Tiri's terminals only: a plugin.")
            : String(localized: "Adds to Claude Code, in Tiri's terminals only: \(parts.joined(separator: "; ")).")
    }
}

// MARK: - Running programs

/// Starts a plugin's programs, on this Mac or on the server its workspace is on.
final class PluginRunner {
    @ObservationIgnored unowned let host: PluginHost
    private var model: AppModel { host.model }

    init(host: PluginHost) {
        self.host = host
    }

    private func holder(_ workspace: WorkspaceID?) -> Workspace {
        workspace.flatMap { id in model.workspaces.first { $0.id == id } } ?? model.active
    }

    func destination(of workspace: WorkspaceID?) -> String? { holder(workspace).remote }

    /// `using` is the templates about to be filled in. What they don't ask for doesn't get worked out,
    /// so a list refreshing while you type doesn't go and count your lines.
    func context(plugin: InstalledPlugin, args: [String: JSONValue], workspace: WorkspaceID? = nil, using templates: [String] = []) -> PluginContext {
        let place = holder(workspace)
        let item = place.peek ?? place.activeItem
        var file: String?
        if case .file(let spec)? = item?.content { file = spec.path }
        if case .diff(let spec)? = item?.content { file = spec.path }
        let text = item.flatMap { model.existingController(for: $0.id) as? TextController }
        let wants = { (name: String) in templates.contains { $0.contains("${" + name + "}") } }
        return PluginContext(plugin: plugin.folder.path, file: file, folder: place.folders.first,
                             line: wants("line") ? text?.currentLineForPlugins : nil, selection: wants("selection") ? text?.selectedTextForFind : nil, args: args)
    }

    /// A Mac app opened from Finder doesn't have your PATH. The first program anything runs waits for it.
    func ensureUserPath() async {
        guard model.userPath == nil else { return }
        let shell = model.settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : model.settings.terminalShell
        if let found = await ShellLookup.path(shell: shell) { model.userPath = found }
    }

    struct Done: Sendable {
        var code: Int32
        var output: String
        var failure: String?
    }

    /// Where a program goes, with its paths as they are there.
    struct Target {
        var connection: RemoteConnection?
        var pluginFolder: String
        var dataFolder: String
        var context: PluginContext
    }

    /// On a server, its files go there first, once for each version of them.
    func target(plugin: InstalledPlugin, context: PluginContext, place: PluginManifest.Place, workspace: WorkspaceID? = nil) async -> Target? {
        guard place == .workspace, let destination = destination(of: workspace) else {
            let data = TiriPaths.supportDirectory.appendingPathComponent("plugin-data/\(plugin.name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            return Target(connection: nil, pluginFolder: plugin.folder.path, dataFolder: data.path, context: context)
        }
        guard let connection = model.remote.existingConnection(destination), connection.state.isReady, let home = connection.home else { return nil }
        let folder = plugin.folder
        let hash = plugin.hash
        let name = plugin.name
        let data = home + "/.tiri/plugin-data/" + name
        let copied = await Task.detached(priority: .userInitiated) { () -> String? in
            let place = home + "/.tiri/plugins/" + name + "-" + hash.prefix(12)
            let quoted = ShellQuote.quote(place)
            if connection.run("mkdir -p \(ShellQuote.quote(data)) && test -f \(quoted)/.tiri-ready", timeout: 15)?.succeeded == true { return place }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-c", "--no-mac-metadata", "--exclude", "./node_modules", "--exclude", "./.git", "--exclude", ".DS_Store", "-C", folder.path, "."]
            let pipe = Pipe.notInherited()
            tar.standardOutput = pipe
            tar.standardError = FileHandle.nullDevice
            guard (try? tar.run()) != nil else { return nil }
            let archive = pipe.fileHandleForReading.readDataToEndOfFile()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { return nil }
            guard connection.run("mkdir -p \(quoted) && tar xf - -C \(quoted) && touch \(quoted)/.tiri-ready", stdin: archive, timeout: 120)?.succeeded == true else { return nil }
            return place
        }.value
        guard let copied else { return nil }
        var mapped = context
        mapped.plugin = copied
        mapped.file = context.file.flatMap { connection.map.remote($0) }
        mapped.folder = context.folder.flatMap { connection.map.remote($0) }
        return Target(connection: connection, pluginFolder: copied, dataFolder: data, context: mapped)
    }

    /// What's in the environment of everything a plugin runs.
    func environment(plugin: InstalledPlugin, target: Target, withSettings: Bool = true) -> [String: String] {
        var values: [String: String] = [
            "TIRI_PLUGIN_NAME": plugin.name,
            "TIRI_PLUGIN_DIR": target.pluginFolder,
            "TIRI_PLUGIN_DATA": target.dataFolder,
            "TIRI_PLUGIN_ARGS": SettingsSchema.json(.object(target.context.args)),
            // Caches written beside the code would change the plugin, and turn it off.
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
        if withSettings { values["TIRI_PLUGIN_SETTINGS"] = plugin.manifest.map { SettingsSchema.json(.object(PluginSettingsStore.resolved($0))) } ?? "{}" }
        if let folder = target.context.folder { values["TIRI_WORKSPACE_FOLDER"] = folder }
        if let file = target.context.file { values["TIRI_FILE"] = file }
        if let connection = target.connection {
            if let socket = connection.relaySocket { values["TIRI_SOCKET"] = socket }
        } else {
            values["TIRI_SOCKET"] = TiriPaths.socket
        }
        return values
    }

    /// The program's own path, wherever it's going.
    func resolve(_ words: [String], target: Target) -> [String] {
        guard let first = words.first else { return words }
        let filled = words.map { PluginTemplate.fill($0, target.context) }
        guard PluginCommandWord.isOwn(first) else { return filled }
        return [PluginCommandWord.path(first, in: target.pluginFolder)] + filled.dropFirst()
    }

    func exec(_ words: [String], plugin: InstalledPlugin, context: PluginContext, place: PluginManifest.Place, timeout: Double, workspace: WorkspaceID? = nil) async -> Done {
        guard let target = await target(plugin: plugin, context: context, place: place, workspace: workspace) else {
            return Done(code: -1, output: "", failure: "Couldn't reach the server this workspace is on.")
        }
        await ensureUserPath()
        // Copying to a server takes a while, and it may have been turned off since.
        guard host.enabledPlugin(named: plugin.name)?.hash == plugin.hash else {
            return Done(code: -1, output: "", failure: "\(plugin.title) is off.")
        }
        let argv = resolve(words, target: target)
        let environment = environment(plugin: plugin, target: target)
        let name = plugin.name
        if let connection = target.connection {
            let script = RemoteProgram.script(argv: argv, environment: environment, folder: target.context.folder, connection: connection, marksStart: true)
            let result = await Task.detached(priority: .userInitiated) { connection.run(script, timeout: timeout) }.value
            guard let result else { return Done(code: -1, output: "", failure: "The connection went away.") }
            PluginProcesses.log(name, result.errorText)
            return Done(code: result.status, output: RemoteProgram.afterStart(result.text), failure: result.succeeded ? nil : (result.errorText.isEmpty ? RemoteProgram.afterStart(result.text) : result.errorText))
        }
        return await LocalProgram.run(argv: argv, environment: environment, directory: target.context.folder ?? plugin.folder.path, path: model.userPath, timeout: timeout, logName: name, owner: name)
    }

    /// In a terminal of its own, where you can watch it and answer it. Returns the new item.
    func terminal(_ line: String, plugin: InstalledPlugin, context: PluginContext, title: String, workspace: WorkspaceID? = nil) async -> String? {
        guard let target = await target(plugin: plugin, context: context, place: .workspace, workspace: workspace) else { return nil }
        guard host.enabledPlugin(named: plugin.name)?.hash == plugin.hash else { return nil }
        // The filled-in values are quoted, so a name with spaces stays one word, and nothing in them
        // can be taken as keys by whatever's reading the terminal.
        let quoting = { (value: String) in ShellQuote.quote(PluginTemplate.plain(value).replacingOccurrences(of: "\n", with: " ")) }
        var filled = PluginTemplate.fill(line, target.context, quoting: quoting)
        if let first = line.split(separator: " ").first.map(String.init), PluginCommandWord.isOwn(first) {
            let rest = PluginTemplate.fill(String(line.dropFirst(first.count)), target.context, quoting: quoting)
            filled = ShellQuote.quote(PluginCommandWord.path(first, in: target.pluginFolder)) + rest
        }
        // Not its settings: a terminal's command line gets saved with the workspace.
        let exports = environment(plugin: plugin, target: target, withSettings: false).filter { $0.key != "TIRI_SOCKET" }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(ShellQuote.quote(PluginTemplate.plain($0.value)))" }.joined(separator: " ")
        return model.newTerminal(command: "env \(exports) \(filled)", cwd: context.folder, split: nil, in: workspace, title: title, plugin: plugin.name)
    }
}

enum PluginCommandWord {
    static func isOwn(_ word: String) -> Bool {
        word.hasPrefix("${plugin}/") || (word.contains("/") && !word.hasPrefix("/") && !word.hasPrefix("~") && !word.hasPrefix("$"))
    }

    static func path(_ word: String, in folder: String) -> String {
        folder + "/" + (word.hasPrefix("${plugin}/") ? String(word.dropFirst(10)) : word)
    }
}

enum RemoteProgram {
    private static let startMark = "\u{1E}tiri-start\u{1E}"

    /// A login shell, because that's where the server's PATH is. `marksStart` says where the program's
    /// own output begins, past whatever a chatty login profile prints.
    static func script(argv: [String], environment: [String: String], folder: String?, connection: RemoteConnection, marksStart: Bool = false) -> String {
        let exports = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(ShellQuote.quote($0.value))" }.joined(separator: " ")
        var path = ""
        if let bin = connection.binDirectory { path = "PATH=\(ShellQuote.quote(bin)):\"$PATH\" " }
        let mark = marksStart ? "printf '\\036tiri-start\\036'; " : ""
        let inner = (folder.map { "cd \(ShellQuote.quote($0)) && " } ?? "") + mark + "\(path)exec env \(exports) " + ShellQuote.join(argv)
        if connection.isCShell { return "sh -c \(ShellQuote.quote(inner))" }
        return "\(ShellQuote.quote(connection.shell)) -l -c \(ShellQuote.quote(inner))"
    }

    static func afterStart(_ text: String) -> String {
        guard let range = text.range(of: startMark) else { return text }
        return String(text[range.upperBound...])
    }
}

/// What's running for each plugin, so that turning it off can stop it, wherever it got to.
enum PluginProgramTable {
    private nonisolated static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: [ObjectIdentifier: Process]] = [:]

    nonisolated static func add(_ process: Process, owner: String) {
        lock.withLock { running[owner, default: [:]][ObjectIdentifier(process)] = process }
    }

    nonisolated static func remove(_ process: Process, owner: String) {
        lock.withLock { running[owner]?[ObjectIdentifier(process)] = nil }
    }

    nonisolated static func stop(owner: String) {
        let found = lock.withLock { running[owner].map { Array($0.values) } ?? [] }
        for process in found { PluginSignal.stop(process.processIdentifier) }
    }

    /// Process gives each child a process group of its own, so what it started goes with it.
    nonisolated static func all() -> [Process] {
        lock.withLock { running.values.flatMap(\.values) }
    }
}

enum PluginSignal {
    /// Everything in its group. Asked, then told.
    nonisolated static func stop(_ pid: Int32) {
        send(SIGTERM, to: pid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { send(SIGKILL, to: pid) }
    }

    nonisolated static func send(_ signal: Int32, to pid: Int32) {
        guard pid > 1 else { return }
        // Its group is its own pid, whether or not it has exited and left children behind.
        if killpg(pid, signal) != 0 { kill(pid, signal) }
    }
}

enum LocalProgram {
    nonisolated private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var printed = Data()
        private var said = Data()
        private var finished = false
        private var timedOut = false
        private let limit = 8 * 1024 * 1024

        func add(output data: Data) { lock.withLock { if printed.count < limit { printed.append(data) } } }
        func add(errors data: Data) { lock.withLock { if said.count < 1024 * 1024 { said.append(data) } } }
        func markTimedOut() { lock.withLock { timedOut = true } }
        /// True the first time.
        func finish() -> (printed: Data, said: Data, timedOut: Bool)? {
            lock.withLock {
                guard !finished else { return nil }
                finished = true
                return (printed, said, timedOut)
            }
        }
    }

    /// Nothing here waits on a thread: a program that hangs, or leaves something holding its output
    /// open, can't use up what the rest of the app needs. Its output is bounded, and its time is too.
    nonisolated static func run(argv: [String], environment: [String: String], directory: String, path: String?, timeout: Double, logName: String, owner: String? = nil) async -> PluginRunner.Done {
        await withCheckedContinuation { (continuation: CheckedContinuation<PluginRunner.Done, Never>) in
            guard let first = argv.first else {
                continuation.resume(returning: .init(code: -1, output: "", failure: "Nothing to run."))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: first.hasPrefix("/") ? first : "/usr/bin/env")
            process.arguments = first.hasPrefix("/") ? Array(argv.dropFirst()) : argv
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory())
            var values = ProcessInfo.processInfo.environment
            for key in values.keys where key.hasPrefix("CLAUDE_CODE") || key == "TIRI_ITEM_ID" || key == "TIRI_WORKSPACE" { values[key] = nil }
            if let path { values["PATH"] = path }
            values.merge(environment) { _, new in new }
            process.environment = values
            process.standardInput = FileHandle.nullDevice
            let output = Pipe.notInherited()
            let errors = Pipe.notInherited()
            process.standardOutput = output
            process.standardError = errors
            let collector = Collector()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collector.add(output: data) }
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collector.add(errors: data) }
            }
            process.terminationHandler = { ended in
                // A moment for the last of its output, and no more: something it left running may hold the pipe.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    guard let result = collector.finish() else { return }
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    if let owner { PluginProgramTable.remove(ended, owner: owner) }
                    // Whatever it left running goes too. Something meant to stay up is a process.
                    PluginSignal.send(SIGTERM, to: ended.processIdentifier)
                    let errorText = String(decoding: result.said, as: UTF8.self)
                    PluginProcesses.log(logName, errorText)
                    let code = ended.terminationStatus
                    let printed = String(decoding: result.printed, as: UTF8.self)
                    let failure = code == 0 ? nil : result.timedOut ? "It took longer than \(Int(timeout)) seconds." : (errorText.isEmpty ? String(printed.suffix(500)) : errorText)
                    continuation.resume(returning: .init(code: code, output: printed, failure: failure))
                }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                _ = collector.finish()
                continuation.resume(returning: .init(code: -1, output: "", failure: "Couldn't start \(first): \(error.localizedDescription)"))
                return
            }
            if let owner { PluginProgramTable.add(process, owner: owner) }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                PluginSignal.stop(pid)
            }
        }
    }
}
