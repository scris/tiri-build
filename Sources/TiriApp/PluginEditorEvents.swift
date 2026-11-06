import AppKit
import TiriCore

// What plugins add around the editor: colors on text, questions before a command, saving first,
// marks in the explorer, menus on sidebar rows, and hearing about files.

/// One of a plugin's colors for text, ready to match.
struct EditorHighlightRule {
    let plugin: String
    let expression: NSRegularExpression
    let group: Int?
    let files: [String]?
    let color: NSColor?
    let background: NSColor?
    let underline: Bool
    let strikethrough: Bool
    let onlyInComments: Bool
    /// As the manifest has it, for its log.
    var pattern = ""

    func applies(to path: String) -> Bool {
        files.map { patterns in patterns.contains { PluginPattern.matches($0, path: path) } } ?? true
    }
}

extension PluginColor {
    var nsColor: NSColor {
        switch self {
        case .named(let name):
            switch name {
            case "red": .systemRed
            case "orange": .systemOrange
            case "yellow": .systemYellow
            case "green": .systemGreen
            case "mint": .systemMint
            case "teal": .systemTeal
            case "cyan": .systemCyan
            case "blue": .systemBlue
            case "indigo": .systemIndigo
            case "purple": .systemPurple
            case "pink": .systemPink
            case "brown": .systemBrown
            case "gray": .systemGray
            default: .controlAccentColor
            }
        case .rgba(let red, let green, let blue, let alpha):
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    static func ns(_ text: String?) -> NSColor? { text.flatMap(parse)?.nsColor }
}

extension PluginHost {
    // MARK: Colors on text

    func rebuildHighlightRules() {
        var rules: [EditorHighlightRule] = []
        for plugin in enabled {
            guard let manifest = plugin.manifest, let highlights = manifest.highlights, !highlights.isEmpty else { continue }
            let settings = PluginSettingsStore.resolved(manifest)
            for highlight in highlights {
                let pattern = PluginHighlightPattern.fill(highlight.pattern, settings: settings)
                guard let expression = try? NSRegularExpression(pattern: pattern, options: highlight.caseInsensitive == true ? [.caseInsensitive] : []) else {
                    PluginProcesses.log(plugin.name, "highlight \(highlight.pattern) isn't a regular expression once its settings are in: \(pattern)\n")
                    continue
                }
                rules.append(EditorHighlightRule(plugin: plugin.name, expression: expression, group: highlight.group, files: highlight.files,
                                                 color: PluginColor.ns(highlight.color), background: PluginColor.ns(highlight.background),
                                                 underline: highlight.underline == true, strikethrough: highlight.strikethrough == true,
                                                 onlyInComments: highlight.onlyInComments == true, pattern: highlight.pattern))
            }
        }
        // Nothing to tell anyone when there was nothing before and there's nothing now.
        if rules.isEmpty, highlightRules.isEmpty { return }
        highlightRules = rules
        model.pluginHighlightsChanged()
    }

    func highlightRules(for path: String) -> [EditorHighlightRule] {
        highlightRules.isEmpty ? [] : highlightRules.filter { $0.applies(to: path) }
    }

    // MARK: Asking before it runs

    /// Each answer that isn't in `args` already, in the palette. Nil if the person backed out.
    func askForInputs(_ inputs: [PluginManifest.Input], plugin: InstalledPlugin, command: PluginManifest.Command, args: [String: JSONValue],
                      workspace: WorkspaceID?) async -> [String: JSONValue]? {
        var values = args
        for input in inputs where values[input.name] == nil {
            let answer: String?
            switch input.kind {
            case .text:
                let heading = input.default?.isEmpty == false ? "\(command.title) · \(input.prompt)" : command.title
                answer = await model.askForText(heading: heading, prompt: input.placeholder ?? input.prompt, initial: input.default ?? "")
            case .choice:
                answer = await model.askForChoice(heading: command.title, prompt: input.prompt) { [weak self] in
                    if let fixed = input.options { return .success(fixed) }
                    guard let self, let provider = input.optionsFrom else { return .success([]) }
                    return await self.ask(provider, plugin: plugin).map { PluginManifest.Choice.list(from: $0) }
                }
            }
            guard let answer else { return nil }
            values[input.name] = .string(answer)
        }
        return values
    }

    /// Nil when it's saved, or there was nothing to save. A file changed on disk under your edits
    /// isn't overwritten for a plugin: that's yours to decide.
    func saveBeforeRunning(_ saving: PluginManifest.Saving, workspace: WorkspaceID?) -> String? {
        let place = workspace.flatMap { id in model.workspaces.first { $0.id == id } } ?? model.active
        let items: [Item]
        switch saving {
        case .front: items = [place.peek ?? place.activeItem].compactMap { $0 }
        case .all: items = place.items + [place.peek].compactMap { $0 }
        }
        for item in items {
            guard let controller = model.existingController(for: item.id), controller.isDirty else { continue }
            let name = item.filePath.map { ($0 as NSString).lastPathComponent } ?? model.englishTitle(for: item)
            switch controller.save(overwriting: false) {
            case .saved: continue
            case .failed(let why):
                model.showToast(title: String(localized: "Couldn't save \(name)"), detail: why, symbol: "exclamationmark.triangle", tint: .orange)
                return "Couldn't save \(name): \(why)"
            case .changedOnDisk:
                model.showToast(title: String(localized: "\(name) changed on disk"), detail: String(localized: "Save it yourself first, so you choose what's kept."),
                                symbol: "exclamationmark.triangle", tint: .orange)
                return "\(name) changed on disk since it was edited here. Save it first."
            }
        }
        return nil
    }

    // MARK: Marks in the explorer

    func refreshFileMarks(plugin name: String, marks id: String) {
        guard let plugin = enabledPlugin(named: name), let provider = plugin.manifest?.fileMarks?.first(where: { $0.id == id })?.provider else { return }
        let identity = key(name, id)
        guard inFlight.insert(identity).inserted else {
            askedAgain.insert(identity)
            return
        }
        lastRefresh[identity] = Date()
        let workspace = model.active
        Task {
            let answer = await ask(provider, plugin: plugin)
            inFlight.remove(identity)
            // Asked of a version that's since changed: the new one asks for itself.
            guard enabledPlugin(named: name)?.hash == plugin.hash else {
                if askedAgain.remove(identity) != nil { refreshFileMarks(plugin: name, marks: id) }
                return
            }
            switch answer {
            case .success(let value):
                var marks = PluginFileMark.list(from: value, folder: workspace.folders.first)
                // A program on a server speaks of the server's paths.
                if let destination = workspace.remote, let connection = model.remote.existingConnection(destination) {
                    marks = Dictionary(marks.map { (connection.map.contains($0.key) ? $0.key : connection.map.local($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
                }
                setFileMarks(marks, plugin: name, id: id)
            case .failure(let failure):
                PluginProcesses.log(name, "file marks \(id): \(failure.message)\n")
            }
            if askedAgain.remove(identity) != nil { refreshFileMarks(plugin: name, marks: id) }
        }
    }

    func setFileMarks(_ marks: [String: PluginFileMark], plugin name: String, id: String) {
        let identity = key(name, id)
        guard fileMarkStates[identity] != marks else { return }
        fileMarkStates[identity] = marks
        model.pluginFileMarksChanged()
    }

    /// What plugins say about this file: the first badge and color, and every tooltip.
    func fileMark(for path: String) -> PluginFileMark? {
        guard !fileMarkStates.isEmpty else { return nil }
        var merged: PluginFileMark?
        for identity in fileMarkStates.keys.sorted() {
            guard let mark = fileMarkStates[identity]?[path] else { continue }
            guard var found = merged else {
                merged = mark
                continue
            }
            found.badge = found.badge ?? mark.badge
            found.color = found.color ?? mark.color
            if let tip = mark.tooltip { found.tooltip = found.tooltip.map { $0 + "\n" + tip } ?? tip }
            merged = found
        }
        return merged
    }

    // MARK: A row's menu

    /// The section's entries, then the row's own. Every one is the plugin's own command.
    func menu(for item: PluginTreeItem, in section: Section) -> [PluginManifest.MenuItem] {
        let name = section.plugin.name
        let shared = (section.section.menu ?? []).map { PluginManifest.MenuItem(title: $0.title, command: Self.fullID(plugin: name, command: $0.command), symbol: $0.symbol) }
        return shared + item.menu
    }

    /// What a menu entry runs with: the row's args, and its path and title when they don't say.
    func runMenu(_ entry: PluginManifest.MenuItem, on item: PluginTreeItem) {
        var args = item.args
        if args["path"] == nil, let path = item.path {
            args["path"] = .string(path.hasPrefix("/") ? path : model.active.folders.first.map { $0 + "/" + path } ?? path)
        }
        if args["title"] == nil { args["title"] = .string(item.title) }
        Task { await run(entry.command, args: args) }
    }
}

// MARK: - Questions in the palette

extension AppModel {
    /// A line of text. Nil if the palette closed without one.
    func askForText(heading: String?, prompt: String, initial: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once(continuation)
            openPrompt(title: prompt, initial: initial) { value in once.resume(value) }
            palette?.heading = heading
            palette?.onCancel = { once.resume(nil) }
        }
    }

    /// One of a list, which may take a moment to arrive. Nil if the palette closed without one.
    func askForChoice(heading: String?, prompt: String, load: @escaping () async -> Result<[PluginManifest.Choice], PluginProcesses.Failure>) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once(continuation)
            openPalette(.choices(title: prompt, rows: []))
            guard let asking = palette else {
                once.resume(nil)
                return
            }
            asking.heading = heading
            asking.isIndexing = true
            asking.onCancel = { once.resume(nil) }
            Task { [weak self] in
                let loaded = await load()
                guard let self, self.palette === asking else { return }
                asking.isIndexing = false
                switch loaded {
                case .failure(let failure):
                    asking.note = failure.message
                case .success(let choices):
                    let rows = choices.enumerated().map { index, choice in
                        PaletteModel.Row(id: "choice-\(index)", title: choice.label ?? choice.value, detail: choice.detail, symbol: choice.symbol) { [weak self] _ in
                            self?.closePalette()
                            once.resume(choice.value)
                        }
                    }
                    asking.mode = .choices(title: prompt, rows: rows)
                    asking.refresh()
                    if rows.isEmpty { asking.note = String(localized: "Nothing to choose from.") }
                }
            }
        }
    }

    func pluginHighlightsChanged() {
        for controller in allTextControllers() { controller.pluginHighlightsChanged() }
    }

    func pluginFileMarksChanged() {
        for live in lives.values { live.fileTree.pluginMarksChanged() }
    }
}

/// A continuation that can be resumed from more than one place, of which only the first counts.
private final class Once {
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

// MARK: - Hearing about files

/// Tells plugins which files are open, which is in front, and what's saved or changed on disk. It
/// costs nothing until a plugin that's on asks for one of these.
final class PluginEditorEvents {
    private struct Listener {
        var plugin: InstalledPlugin
        var process: String
        var events: Set<PluginManifest.Event>
        var place: PluginManifest.Place
    }

    private enum Surface { case sidebar, status, marks }

    private var listeners: [Listener] = []
    private var panelsListen = false
    private var onFront: [(plugin: String, surface: Surface, id: String)] = []
    private var onChange: [(plugin: String, surface: Surface, id: String)] = []
    private var lastFront: String??
    private var lastOpen: [String]?
    private var frontWork: DispatchWorkItem?
    private var changed: Set<String> = []
    private var changeWork: DispatchWorkItem?
    private var lastChangeRefresh: [String: Double] = [:]
    private var waitingChangeRefresh: Set<String> = []
    /// The most paths one event carries. Past it, `more` says how many weren't listed.
    static let mostPaths = 1_000

    var isListening: Bool { !listeners.isEmpty || panelsListen || !onFront.isEmpty || !onChange.isEmpty }

    func listenersChanged(_ host: PluginHost) {
        listeners = host.enabled.flatMap { plugin in
            (plugin.manifest?.processes ?? []).compactMap { process -> Listener? in
                guard let events = process.events, !events.isEmpty else { return nil }
                return Listener(plugin: plugin, process: process.id, events: Set(events), place: process.where ?? .workspace)
            }
        }
        panelsListen = host.enabled.contains { ($0.manifest?.panels ?? []).contains { $0.allow?.editor == true } }
        onFront = []
        onChange = []
        for plugin in host.enabled {
            guard let manifest = plugin.manifest else { continue }
            let all: [(Surface, String, PluginManifest.Refresh?)] = (manifest.sidebar ?? []).map { (.sidebar, $0.id, $0.refresh) }
                + (manifest.statusBar ?? []).map { (.status, $0.id, $0.refresh) } + (manifest.fileMarks ?? []).map { (.marks, $0.id, $0.refresh) }
            for (surface, id, refresh) in all {
                if refresh?.onFrontFile == true { onFront.append((plugin.name, surface, id)) }
                if refresh?.onFileChange == true { onChange.append((plugin.name, surface, id)) }
            }
        }
        // Whoever's new hears where things stand.
        lastFront = nil
        lastOpen = nil
        if isListening { workspaceMaybeChanged(host) }
    }

    /// From any change to the workspaces. Cheap until there's someone to tell, and then it waits for
    /// things to settle, so ⌃Tab through ten tabs is one event.
    func workspaceMaybeChanged(_ host: PluginHost) {
        guard isListening else { return }
        frontWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak host] in
            guard let self, let host else { return }
            self.check(host)
        }
        frontWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func state(_ host: PluginHost) -> (front: String?, open: [String]) {
        let place = host.model.active
        let front = (place.peek ?? place.activeItem)?.filePath
        var seen = Set<String>()
        let open = (place.items + [place.peek].compactMap { $0 }).compactMap(\.filePath).filter { seen.insert($0).inserted }
        return (front, open)
    }

    private func check(_ host: PluginHost) {
        let now = state(host)
        if lastFront != .some(now.front) {
            let first = lastFront == nil
            lastFront = .some(now.front)
            deliver(.frontFile, ["path": now.front.map(JSONValue.string) ?? .null], host: host)
            if !first { for entry in onFront { refresh(entry, host: host) } }
        }
        if lastOpen != now.open {
            lastOpen = now.open
            deliver(.openFiles, ["paths": .array(now.open.map(JSONValue.string)), "front": now.front.map(JSONValue.string) ?? .null], host: host)
        }
    }

    func saved(_ path: String, host: PluginHost) {
        guard isListening else { return }
        deliver(.saved, ["path": .string(path)], host: host)
    }

    /// From the file watcher, in the front workspace's folders only. Git's own bookkeeping isn't a change to anyone's files.
    func filesChanged(_ paths: [String], host: PluginHost) {
        guard isListening, !listeners.isEmpty || panelsListen || !onChange.isEmpty else { return }
        let folders = host.model.active.folders
        let mine = paths.filter { path in
            !path.contains("/.git/") && !path.hasSuffix("/.git") && folders.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard !mine.isEmpty else { return }
        changed.formUnion(mine)
        guard changeWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak host] in
            guard let self, let host else { return }
            self.changeWork = nil
            let paths = self.changed.sorted()
            self.changed = []
            var data: [String: JSONValue] = ["paths": .array(paths.prefix(Self.mostPaths).map(JSONValue.string))]
            if paths.count > Self.mostPaths { data["more"] = .int(paths.count - Self.mostPaths) }
            self.deliver(.filesChanged, data, host: host)
            for entry in self.onChange { self.refreshAfterChange(entry, host: host) }
        }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// A provider is a program, so a burst of changes from an agent runs it every few seconds at most,
    /// and once more after the burst.
    private func refreshAfterChange(_ entry: (plugin: String, surface: Surface, id: String), host: PluginHost) {
        let identity = entry.plugin + "/" + entry.id
        let gap = 3000.0
        let since = ProcessClock.now() - (lastChangeRefresh[identity] ?? 0)
        if since >= gap {
            lastChangeRefresh[identity] = ProcessClock.now()
            refresh(entry, host: host)
        } else if waitingChangeRefresh.insert(identity).inserted {
            DispatchQueue.main.asyncAfter(deadline: .now() + (gap - since) / 1000) { [weak self, weak host] in
                guard let self, let host else { return }
                self.waitingChangeRefresh.remove(identity)
                self.lastChangeRefresh[identity] = ProcessClock.now()
                self.refresh(entry, host: host)
            }
        }
    }

    private func refresh(_ entry: (plugin: String, surface: Surface, id: String), host: PluginHost) {
        switch entry.surface {
        case .sidebar:
            // A section nobody has unfolded runs nothing.
            guard host.sidebarStates[host.key(entry.plugin, entry.id)]?.hasLoaded == true else { return }
            host.refreshSection(plugin: entry.plugin, section: entry.id)
        case .status: host.refreshStatus(plugin: entry.plugin, item: entry.id)
        case .marks: host.refreshFileMarks(plugin: entry.plugin, marks: entry.id)
        }
    }

    /// The paths as the process will see them: a server's own, for one running there.
    private func mapped(_ data: [String: JSONValue], for listener: Listener, host: PluginHost) -> JSONValue {
        guard listener.place == .workspace, let destination = host.model.active.remote,
              let connection = host.model.remote.existingConnection(destination) else { return .object(data) }
        func map(_ value: JSONValue) -> JSONValue {
            if let path = value.stringValue { return connection.map.remote(path).map(JSONValue.string) ?? .null }
            if let list = value.arrayValue { return .array(list.map(map).filter { $0 != .null }) }
            return value
        }
        var result = data
        for key in ["path", "front", "paths"] { if let value = data[key] { result[key] = map(value) } }
        return .object(result)
    }

    private func deliver(_ event: PluginManifest.Event, _ data: [String: JSONValue], host: PluginHost) {
        for listener in listeners where listener.events.contains(event) {
            let destination = listener.place == .workspace ? host.runner.destination(of: nil) : nil
            let wasRunning = host.processes.isRunning(plugin: listener.plugin.name, process: listener.process, destination: destination)
            // Starting it to say this, so it also hears where things stand.
            var first: [(PluginManifest.Event, JSONValue)] = []
            if !wasRunning {
                let now = state(host)
                if event != .frontFile, listener.events.contains(.frontFile) { first.append((.frontFile, mapped(["path": now.front.map(JSONValue.string) ?? .null], for: listener, host: host))) }
                if event != .openFiles, listener.events.contains(.openFiles) {
                    first.append((.openFiles, mapped(["paths": .array(now.open.map(JSONValue.string)), "front": now.front.map(JSONValue.string) ?? .null], for: listener, host: host)))
                }
            }
            let message = mapped(data, for: listener, host: host)
            let plugin = listener.plugin
            let process = listener.process
            Task { [weak host] in
                for (name, value) in first { await host?.processes.notify(plugin: plugin, process: process, event: name.rawValue, data: value) }
                await host?.processes.notify(plugin: plugin, process: process, event: event.rawValue, data: message)
            }
        }
        guard panelsListen else { return }
        for controller in host.model.allPanelControllers() where controller.panel?.panel.allow?.editor == true {
            guard host.model.workspace(containing: controller.itemID)?.id == host.model.active.id else { continue }
            controller.panel?.send(event: event.rawValue, data: .object(data))
        }
    }

    /// For a panel's `tiri.files()`.
    func current(_ host: PluginHost) -> JSONValue {
        let now = state(host)
        return .object(["front": now.front.map(JSONValue.string) ?? .null, "paths": .array(now.open.map(JSONValue.string))])
    }
}
