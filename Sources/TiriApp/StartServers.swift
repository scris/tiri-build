import SwiftUI
import TiriCore

/// ▶ Start: each workspace's own list of things to start, its dev servers and the project's own start scripts, each in a
/// terminal of its own. Tiri finds the ports they listen on and opens the page beside the code. People fill the list by
/// hand, from Tiri's suggestions, or by asking their agent, and agents start the same ones through `tiri start`, so
/// there's never a second copy fighting for a port, or one left running where nobody can see it.
@MainActor
@Observable
final class FolderStarter {
    enum Phase: String { case starting, running, stopping }

    struct Key: Hashable {
        var workspace: WorkspaceID
        var entry: String
    }

    struct Server: Equatable {
        var terminal: ItemID
        var command: String
        var phase: Phase
        /// The page's port: the one it printed, or the lowest it listens on. On the server, for a workspace there.
        var port: Int?
        /// Every port it listens on, for one start that brings up several servers.
        var ports: [Int] = []
        /// Where this Mac reaches the page: a forwarded port, for a workspace on a server.
        var localPort: Int?
        /// Pressed by someone, so the page opens when it's up. An agent's start leaves that to the agent.
        var opensPage: Bool
        /// Seen running. A terminal picked up after a relaunch may have nothing running in it.
        var confirmed: Bool
        /// Picked up after a relaunch and not yet seen running: not shown as anything until it is.
        var checking = false
    }

    @ObservationIgnored private weak var model: AppModel?
    private(set) var servers: [Key: Server] = [:]
    /// The workspace whose list is open for editing.
    var editing: WorkspaceID?
    /// What each workspace's folders suggest. Observed, so suggestions appear once they're found.
    private(set) var suggested: [WorkspaceID: [StartGuess]] = [:]
    @ObservationIgnored private var suggestedAt: [WorkspaceID: Date] = [:]
    @ObservationIgnored private var suggesting: Set<WorkspaceID> = []
    @ObservationIgnored private var watchers: [Key: Task<Void, Never>] = [:]
    /// Between a press and its command being typed, which can take a few seconds. Another start then would type it twice.
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var adopted: Set<Key> = []

    init(model: AppModel) { self.model = model }

    // MARK: The list

    /// A workspace's starts. Before there was a list, a start was kept per folder in `start.commands`: those come in once.
    func entries(in workspace: WorkspaceID) -> [StartEntry] {
        guard let model, let space = model.workspaces.first(where: { $0.id == workspace }) else { return [] }
        if let starts = space.starts { return starts }
        let carried = space.folders.compactMap { folder in
            model.settings.startCommands[folder].map { StartEntry(id: "folder:" + folder, name: (folder as NSString).lastPathComponent, command: $0, folder: folder) }
        }
        // Not while a view is drawing: the change goes in a moment later.
        DispatchQueue.main.async { [weak model] in
            model?.update(workspace: workspace) { if $0.starts == nil { $0.starts = carried } }
        }
        return carried
    }

    func entry(_ id: String, in workspace: WorkspaceID) -> StartEntry? { entries(in: workspace).first { $0.id == id } }

    func entry(named name: String, in workspace: WorkspaceID) -> StartEntry? {
        entries(in: workspace).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func setEntries(_ starts: [StartEntry], in workspace: WorkspaceID) {
        model?.update(workspace: workspace) { $0.starts = starts }
    }

    @discardableResult
    func add(_ entry: StartEntry, to workspace: WorkspaceID) -> StartEntry {
        var starts = entries(in: workspace)
        var entry = entry
        // Names are how agents ask for one, so two can't share one.
        let base = entry.name.trimmingCharacters(in: .whitespaces).isEmpty ? (entry.folder as NSString).lastPathComponent : entry.name
        entry.name = base
        var number = 2
        while starts.contains(where: { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame && $0.id != entry.id }) {
            entry.name = "\(base) \(number)"
            number += 1
        }
        starts.append(entry)
        setEntries(starts, in: workspace)
        return entry
    }

    func update(_ entry: StartEntry, in workspace: WorkspaceID) {
        var starts = entries(in: workspace)
        guard let index = starts.firstIndex(where: { $0.id == entry.id }) else { return }
        starts[index] = entry
        setEntries(starts, in: workspace)
    }

    func remove(_ id: String, from workspace: WorkspaceID) {
        stop(id, in: workspace)
        setEntries(entries(in: workspace).filter { $0.id != id }, in: workspace)
    }

    /// The workspace's folders' suggestions that aren't in its list yet. Looked for off the main thread, again now and then,
    /// since an agent may only just have made the project.
    func suggestions(for workspace: WorkspaceID) -> [StartGuess] {
        guard let model, let space = model.workspaces.first(where: { $0.id == workspace }) else { return [] }
        if suggestedAt[workspace].map({ Date().timeIntervalSince($0) > 20 }) ?? true, suggesting.insert(workspace).inserted {
            let folders = space.remote == nil ? space.folders : []
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) { StartFolders.suggestions(for: folders) }.value
                guard let self else { return }
                self.suggesting.remove(workspace)
                self.suggestedAt[workspace] = Date()
                if self.suggested[workspace] != found { self.suggested[workspace] = found }
            }
        }
        let taken = Set(entries(in: workspace).map { $0.folder + "\u{1}" + $0.command })
        return (suggested[workspace] ?? []).filter { !taken.contains($0.id) }
    }

    func isRunning(in workspace: WorkspaceID) -> Bool { servers.contains { $0.key.workspace == workspace && !$0.value.checking } }
    /// What's known to be running. One still being checked after a relaunch isn't, yet.
    func server(_ entry: String, in workspace: WorkspaceID) -> Server? {
        servers[Key(workspace: workspace, entry: entry)].flatMap { $0.checking ? nil : $0 }
    }

    // MARK: Pressed

    /// A start in the list, pressed: running, it opens the page; otherwise it starts. Only from someone at this Mac.
    func press(_ id: String, in workspace: WorkspaceID) {
        guard let entry = entry(id, in: workspace) else { return }
        if let server = server(id, in: workspace), server.phase != .stopping {
            if server.port != nil { openPage(id, in: workspace, focus: true) } else { showOutput(id, in: workspace) }
            return
        }
        Task { _ = await start(entry, in: workspace, opensPage: true) }
    }

    /// ⌃⌥S: with one start it's that one; otherwise the list, to choose from or fill.
    func pressInFront() {
        guard let model else { return }
        let workspace = model.activeID
        let starts = entries(in: workspace)
        if starts.count == 1 { press(starts[0].id, in: workspace) } else { editing = workspace }
    }

    /// Added from a suggestion, and started: what picking one means.
    func addAndStart(_ guess: StartGuess, in workspace: WorkspaceID) {
        let entry = add(guess.entry, to: workspace)
        Task { _ = await start(entry, in: workspace, opensPage: true) }
    }

    func askAgentToSetUp(_ workspace: WorkspaceID) {
        guard let model, let space = model.workspaces.first(where: { $0.id == workspace }) else { return }
        editing = nil
        guard let agent = model.runnableAgentPresets().first else {
            model.showToast(title: String(localized: "No agent to ask"), detail: String(localized: "Turn one on in Settings."), symbol: "sparkles", tint: .secondary)
            return
        }
        model.askAgent(preset: agent, prompt: Self.setUpPrompt(folders: space.folders, existing: entries(in: workspace)))
    }

    static func setUpPrompt(folders: [String], existing: [StartEntry]) -> String {
        var prompt = "Set up Tiri's Start list for this workspace: the things I'd want to start while working on it, like dev servers, "
            + "the project's own start scripts, and the parts of a monorepo. The folders: \(folders.joined(separator: ", ")). "
            + "Read their files (package.json, README, scripts/, Procfile, docker compose, .claude/launch.json and so on), and don't start anything. "
            + "Add each with `tiri start add <short name> \"<command>\" --folder <the folder it runs in>`; `tiri start guesses` shows what Tiri found, "
            + "and `tiri start list` what's there."
        if !existing.isEmpty { prompt += " Already in the list: " + existing.map { "\($0.name) (`\($0.command)`)" }.joined(separator: ", ") + "." }
        return prompt + " Then tell me what you added and why."
    }

    // MARK: Running

    /// Starts one in its own terminal in that workspace, or finds it already going. Waits for the shell's prompt, not for the server.
    func start(_ entry: StartEntry, in workspace: WorkspaceID, opensPage: Bool) async -> Server? {
        guard let model, model.workspaces.contains(where: { $0.id == workspace }) else { return nil }
        let key = Key(workspace: workspace, entry: entry.id)
        adopt(entry, in: workspace)
        // Picked up after a relaunch, and not yet known to be a server rather than the shell's own setup: a moment tells.
        let began = Date()
        while let server = servers[key], !server.confirmed, server.phase == .starting, !inFlight.contains(key), Date().timeIntervalSince(began) < 3 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let server = servers[key], server.phase != .stopping {
            if server.confirmed || inFlight.contains(key) { return server }
            let terminal = model.existingController(for: server.terminal) as? TerminalController
            if terminal?.isRunningProgram == true { return server }
            end(key)
        }
        // Already starting, or a restart is under way: that one, not a second.
        guard servers[key] == nil, inFlight.insert(key).inserted else {
            return servers[key] ?? Server(terminal: "", command: entry.command, phase: .starting, opensPage: false, confirmed: false)
        }
        defer { inFlight.remove(key) }
        let line = entry.command + "\r"
        if let existing = startTerminal(for: entry, in: workspace),
           let controller = model.controller(for: existing) as? TerminalController, !controller.hasExited {
            controller.startIfNeeded(fallbackSize: true)
            servers[key] = Server(terminal: existing, command: entry.command, phase: .starting, opensPage: opensPage, confirmed: false)
            if controller.isRunningProgram {
                // Started by hand in its terminal: it's that one.
                servers[key]?.confirmed = true
            } else {
                let here = controller.currentDirectory
                await controller.typeWhenReady((FileRunner.sameFolder(here, entry.folder) ? "" : "cd \(ShellQuote.quote(entry.folder)) && ") + line)
            }
        } else {
            var spec = TerminalSpec(cwd: entry.folder, title: entry.name)
            spec.startsEntry = entry.id
            let item = Item(content: .terminal(spec))
            // A tab behind what you're looking at: the page is what you want to see, and the output is a click away.
            model.update(workspace: workspace) { space in
                let behind = space.focused.active
                space.addItem(item)
                if let behind { space.activate(behind) }
            }
            guard let controller = model.controller(for: item.id) as? TerminalController else { return nil }
            controller.startIfNeeded(fallbackSize: true)
            servers[key] = Server(terminal: item.id, command: entry.command, phase: .starting, opensPage: opensPage, confirmed: false)
            await controller.typeWhenReady(line)
        }
        guard servers[key] != nil else { return nil }
        watch(key)
        return servers[key]
    }

    /// After a relaunch a start is still running in its terminal. Picked up once, when its terminal is found.
    func adopt(_ entry: StartEntry, in workspace: WorkspaceID) {
        let key = Key(workspace: workspace, entry: entry.id)
        guard let model, servers[key] == nil, !adopted.contains(key), let terminal = startTerminal(for: entry, in: workspace),
              let controller = model.controller(for: terminal) as? TerminalController else { return }
        adopted.insert(key)
        controller.startIfNeeded(fallbackSize: true)
        servers[key] = Server(terminal: terminal, command: entry.command, phase: .starting, opensPage: false, confirmed: false, checking: true)
        watch(key, adopting: true)
    }

    func adoptAll(in workspace: WorkspaceID) {
        for entry in entries(in: workspace) { adopt(entry, in: workspace) }
    }

    /// Its terminal: the one it made, or one a folder's start made before starts were a list.
    private func startTerminal(for entry: StartEntry, in workspace: WorkspaceID) -> ItemID? {
        let items = model?.workspaces.first { $0.id == workspace }?.items ?? []
        return items.first { item in
            guard case .terminal(let spec) = item.content else { return false }
            return spec.startsEntry == entry.id || spec.startsEntry == nil && spec.startsFolder != nil && spec.startsFolder == entry.folder
        }?.id
    }

    private func end(_ key: Key) {
        watchers.removeValue(forKey: key)?.cancel()
        servers[key] = nil
    }

    /// Follows a start: when it's listening, on which ports, and when it ends.
    private func watch(_ key: Key, adopting: Bool = false) {
        watchers[key]?.cancel()
        watchers[key] = Task { [weak self] in
            let began = Date()
            var seenRunning = false
            var runningSince: Date?
            var idleSince: Date?
            var lastLook = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let model = self.model, let server = self.servers[key] else { return }
                guard model.anyItem(server.terminal) != nil, let controller = model.existingController(for: server.terminal) as? TerminalController,
                      !controller.hasExited else {
                    self.end(key)
                    return
                }
                if controller.isRunningProgram {
                    let since = runningSince ?? Date()
                    runningSince = since
                    // A shell that's just started runs its own setup first, conda and the like, for a moment. In a terminal
                    // picked up after a relaunch, only something that keeps running is the server.
                    if !seenRunning, !adopting || Date().timeIntervalSince(since) > 2 {
                        seenRunning = true
                        self.servers[key]?.confirmed = true
                        self.servers[key]?.checking = false
                    }
                    idleSince = nil
                    // Often until there's a port, for 20 seconds. Then now and then: some never print one or hold it
                    // themselves, like docker compose, and a start script can bring up more as it goes.
                    let every: TimeInterval = server.port == nil && Date().timeIntervalSince(began) < 20 ? 0.4 : 5
                    if Date().timeIntervalSince(lastLook) >= every {
                        lastLook = Date()
                        self.lookForPorts(key, controller: controller)
                    }
                    continue
                }
                runningSince = nil
                let idle = idleSince ?? Date()
                idleSince = idle
                if adopting, !seenRunning, Date().timeIntervalSince(began) > 1.5, Date().timeIntervalSince(idle) > 1 {
                    self.end(key)
                    return
                }
                // `a && b` hands the terminal back to the shell between the two, so it's over only after a moment of that.
                let over = seenRunning ? Date().timeIntervalSince(idle) > 1 : Date().timeIntervalSince(began) > 6
                guard over else { continue }
                self.end(key)
                if server.phase != .stopping, !adopting || seenRunning { self.ended(key, server: server, controller: controller) }
                return
            }
        }
    }

    private func lookForPorts(_ key: Key, controller: TerminalController) {
        guard var server = servers[key] else { return }
        // Only what this run printed: the terminal may hold an earlier run's address.
        var output = controller.readText(lines: 300)
        if !server.command.isEmpty, let typed = output.range(of: server.command, options: .backwards) { output = String(output[typed.upperBound...]) }
        let printed = StartFolders.printedPorts(in: output)
        let listening = controller.isOnServer ? [] : controller.localShell.map(ListeningPorts.under) ?? []
        // On a server only what it printed can be known.
        let port = controller.isOnServer ? printed.min() : StartFolders.pagePort(listening: listening, printed: printed)
        let ports = listening.isEmpty ? [port].compactMap { $0 } : listening
        guard port != server.port || ports != server.ports else { return }
        let first = server.port == nil && port != nil
        server.port = port
        server.ports = ports
        if !controller.isOnServer { server.localPort = port }
        // Stopping stays stopping: its second ⌃C depends on it.
        if port != nil, server.phase == .starting { server.phase = .running }
        // Listening on a port: whatever it was picked up from, it's a server.
        if port != nil { server.checking = false }
        let opens = server.opensPage && first
        if opens { server.opensPage = false }
        servers[key] = server
        if opens { openPage(key.entry, in: key.workspace, focus: false) }
    }

    /// It stopped by itself: says so, with what it last printed, and offers the agent.
    private func ended(_ key: Key, server: Server, controller: TerminalController) {
        guard let model else { return }
        let entry = entry(key.entry, in: key.workspace)
        let name = entry?.name ?? StartFolders.title(of: server.command)
        let last = controller.readText(lines: 40).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasSuffix("%") && !$0.hasSuffix("$") && !$0.hasSuffix(">") }
        let agent = model.runnableAgentPresets().first
        model.showToast(title: String(localized: "\(name) stopped"), detail: last, symbol: "stop.circle", tint: .orange,
                        actionTitle: agent.map { String(localized: "Ask \($0.name)") }, duration: 12,
                        other: (String(localized: "Show Output"), { [weak model] in _ = model?.focusItem(server.terminal) })) {
            guard let agent else { return }
            model.askAgent(preset: agent, prompt: "My \(name) stopped by itself. It runs `\(server.command)` in a Tiri terminal. "
                + "Read what it printed with `tiri start logs \(ShellQuote.quote(name))`, find out why and fix it, "
                + "then start it again with `tiri start \(ShellQuote.quote(name))`.")
        }
    }

    func stop(_ id: String, in workspace: WorkspaceID) {
        let key = Key(workspace: workspace, entry: id)
        guard let model, var server = servers[key],
              let controller = model.existingController(for: server.terminal) as? TerminalController else { return }
        server.phase = .stopping
        servers[key] = server
        controller.send(text: "\u{03}")
        // Some servers want a second ⌃C, or a moment to close what they hold.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.servers[key]?.phase == .stopping, self?.servers[key]?.terminal == server.terminal, controller.isRunningProgram else { return }
            controller.send(text: "\u{03}")
        }
    }

    func stopAll(in workspace: WorkspaceID) {
        for key in servers.keys where key.workspace == workspace { stop(key.entry, in: workspace) }
    }

    /// Only what's running, in its own workspace. Never a press: a restart asked for from a server's terminal must not
    /// start anything on this Mac, or ask anything of the person here.
    func restart(_ id: String, in workspace: WorkspaceID) {
        let key = Key(workspace: workspace, entry: id)
        guard servers[key] != nil, !inFlight.contains(key), let entry = entry(id, in: workspace) else { return }
        inFlight.insert(key)
        stop(id, in: workspace)
        Task { [weak self] in
            let began = Date()
            while self?.servers[key] != nil, Date().timeIntervalSince(began) < 10 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.inFlight.remove(key)
            _ = await self?.start(entry, in: workspace, opensPage: false)
        }
    }

    func showOutput(_ id: String, in workspace: WorkspaceID) {
        guard let model else { return }
        let terminal = server(id, in: workspace)?.terminal ?? entry(id, in: workspace).flatMap { startTerminal(for: $0, in: workspace) }
        if let terminal { _ = model.focusItem(terminal) }
    }

    func address(_ id: String, in workspace: WorkspaceID) -> String? {
        server(id, in: workspace)?.port.map { "http://localhost:\($0)" }
    }

    /// Beside the code, without taking the keyboard unless asked. An open page for it is reused.
    func openPage(_ id: String, in workspaceID: WorkspaceID, port wanted: Int? = nil, focus: Bool) {
        let key = Key(workspace: workspaceID, entry: id)
        guard let model, let server = servers[key], let port = wanted ?? server.port,
              let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let ports = Set([port] + (wanted == nil ? [server.localPort].compactMap { $0 } : []))
        if let open = workspace.items.first(where: { item in
            if case .web(let spec) = item.content, let url = URL(string: spec.url), let shown = url.port {
                return ports.contains(shown) && ["localhost", "127.0.0.1"].contains(url.host ?? "")
            }
            return false
        }) {
            if focus { _ = model.focusItem(open.id) }
            return
        }
        let show: (URL) -> Void = { [weak model] url in
            guard let model else { return }
            if model.sendsToBrowser(url, openHere: { [weak model] in _ = model?.openWeb(url: url.absoluteString, split: .right, in: workspaceID) }) { return }
            if focus {
                model.openWeb(url: url.absoluteString, split: .right, in: workspaceID)
            } else {
                // Opening a split moves the keyboard's place to it. It stays where it was.
                let before = model.workspaces.first { $0.id == workspaceID }?.focusedGroup
                model.openWeb(url: url.absoluteString, split: .right, in: workspaceID, takeFocus: false)
                if let before { model.update(workspace: workspaceID) { $0.focusGroup(id: before) } }
            }
        }
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        if let destination = workspace.remote {
            Task { [weak self] in
                guard let local = await model.remote.localURL(for: url, on: destination) else { return }
                // Remembered, so the page open for it is found next time.
                if wanted == nil { self?.servers[key]?.localPort = local.port }
                show(local)
            }
        } else {
            show(url)
        }
    }

    // MARK: tiri start

    func control(_ request: ControlRequest) async -> ControlResponse {
        guard let model else { return .failure(id: request.id, "Tiri isn't ready.") }
        var workspace = request.args["source"]?.stringValue.flatMap { model.workspace(containing: $0)?.id } ?? model.activeID
        let asked = request.args["folder"]?.stringValue ?? ""
        // From a server's terminal it's only ever that server's own workspace: nothing it asks may run on this Mac.
        if request.args["fromServer"]?.boolValue == true {
            guard let theirs = model.workspaces.first(where: { $0.id == workspace && $0.remote != nil && $0.folder(containing: asked) != nil })
                    ?? model.workspaces.first(where: { $0.remote != nil && $0.folder(containing: asked) != nil }) else {
                return .failure(id: request.id, "That folder isn't in a workspace on this server.")
            }
            workspace = theirs.id
        }
        guard let space = model.workspaces.first(where: { $0.id == workspace }) else { return .failure(id: request.id, "No workspace.") }
        adoptAll(in: workspace)
        let starts = entries(in: workspace)
        let name = request.args["name"]?.stringValue

        func describe(_ entry: StartEntry) -> JSONValue {
            let server = self.server(entry.id, in: workspace)
            var result: [String: JSONValue] = ["name": .string(entry.name), "command": .string(entry.command), "folder": .string(entry.folder),
                                               "state": .string(server?.phase.rawValue ?? "stopped")]
            if let address = address(entry.id, in: workspace) { result["url"] = .string(address) }
            if let ports = server?.ports, ports.count > 1 { result["ports"] = .array(ports.map(JSONValue.int)) }
            if let server { result["item"] = .string(server.terminal) }
            return .object(result)
        }
        /// The one asked for by name, or the only one there is.
        func chosen() -> Result<StartEntry, StartProblem> {
            if let name {
                if let found = entry(named: name, in: workspace) { return .success(found) }
                return .failure(StartProblem("No start called \(name). " + (starts.isEmpty ? "There are none yet." : "There are: \(starts.map(\.name).joined(separator: ", ")).")
                    + " Add one with: tiri start add <name> \"<command>\""))
            }
            if starts.count == 1 { return .success(starts[0]) }
            if starts.isEmpty {
                let found = suggestionsNow(space)
                var message = "This workspace has no starts yet."
                if !found.isEmpty { message += " Tiri's suggestions: " + found.prefix(8).map { "\($0.name): `\($0.command)` in \($0.folder)" }.joined(separator: "; ") + "." }
                return .failure(StartProblem(message + " Add one with: tiri start add <name> \"<command>\" --folder DIR"))
            }
            return .failure(StartProblem("Which one? This workspace's starts: \(starts.map(\.name).joined(separator: ", ")). Run tiri start <name>."))
        }

        switch request.args["action"]?.stringValue ?? "start" {
        case "list", "status" where name == nil:
            return .success(id: request.id, .array(starts.map(describe)))
        case "guesses":
            let taken = Set(starts.map { $0.folder + "\u{1}" + $0.command })
            return .success(id: request.id, .array(suggestionsNow(space).filter { !taken.contains($0.id) }.map { guess in
                var entry: [String: JSONValue] = ["name": .string(guess.name), "command": .string(guess.command),
                                                  "folder": .string(guess.folder), "source": .string(guess.source)]
                if let detail = guess.detail { entry["detail"] = .string(detail) }
                return .object(entry)
            }))
        case "add":
            guard let name, let command = request.args["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return .failure(id: request.id, "usage: tiri start add <name> \"<command>\" [--folder DIR]")
            }
            guard space.folder(containing: asked) != nil else {
                return .failure(id: request.id, "\(asked) isn't in this workspace's folders: \(space.folders.joined(separator: ", ")).")
            }
            if var existing = entry(named: name, in: workspace) {
                existing.command = command
                existing.folder = asked
                update(existing, in: workspace)
                return .success(id: request.id, describe(existing))
            }
            return .success(id: request.id, describe(add(StartEntry(name: name, command: command, folder: asked), to: workspace)))
        case "remove":
            guard let name, let found = entry(named: name, in: workspace) else { return .failure(id: request.id, "No start called \(name ?? "that").") }
            remove(found.id, from: workspace)
            return .success(id: request.id, .object(["removed": .string(found.name)]))
        default:
            break
        }

        let found: StartEntry
        switch chosen() {
        case .success(let entry): found = entry
        case .failure(let problem): return .failure(id: request.id, problem.message)
        }
        let key = Key(workspace: workspace, entry: found.id)
        switch request.args["action"]?.stringValue ?? "start" {
        case "status":
            return .success(id: request.id, describe(found))
        case "stop":
            stop(found.id, in: workspace)
            return .success(id: request.id, describe(found))
        case "restart":
            guard servers[key] != nil else { return .failure(id: request.id, "\(found.name) isn't running. Start it with tiri start \(found.name).") }
            restart(found.id, in: workspace)
            return .success(id: request.id, describe(found))
        case "logs":
            guard let terminal = servers[key]?.terminal ?? startTerminal(for: found, in: workspace),
                  let controller = model.controller(for: terminal) as? TerminalController else {
                return .failure(id: request.id, "\(found.name) hasn't been started.")
            }
            controller.startIfNeeded(fallbackSize: true)
            return .success(id: request.id, .object(["text": .string(controller.readText(lines: request.args["lines"]?.intValue ?? 80))]))
        default:
            guard await start(found, in: workspace, opensPage: false) != nil else {
                if inFlight.contains(key) || servers[key] != nil { return await waitForAddress(key, found, request: request, describe: describe) }
                return .failure(id: request.id, "Couldn't start it.")
            }
            return await waitForAddress(key, found, request: request, describe: describe)
        }
    }

    private func suggestionsNow(_ space: Workspace) -> [StartGuess] {
        space.remote == nil ? StartFolders.suggestions(for: space.folders) : []
    }

    /// So whoever asked can use the address straight away. Under a minute: a server's `tiri` waits only that long.
    private func waitForAddress(_ key: Key, _ entry: StartEntry, request: ControlRequest, describe: (StartEntry) -> JSONValue) async -> ControlResponse {
        let began = Date()
        while Date().timeIntervalSince(began) < 50 {
            // Through a restart too: the old run's address isn't the answer, and between the two there's no server at all.
            if let server = servers[key], server.phase == .running, server.port != nil { break }
            if servers[key] == nil, !inFlight.contains(key) { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if servers[key] == nil, !inFlight.contains(key) {
            return .failure(id: request.id, "It stopped. What it printed: tiri start logs \(ShellQuote.quote(entry.name))")
        }
        return .success(id: request.id, describe(entry))
    }
}

/// Why `tiri start` can't tell which start was meant.
struct StartProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension TerminalController {
    /// Typed ahead of a shell's first prompt, a command shows twice: the terminal echoes it, then the shell draws it again.
    /// So this waits for the prompt, a moment of quiet after the shell's first output, for up to a few seconds.
    func typeWhenReady(_ text: String) async {
        let began = Date()
        while Date().timeIntervalSince(began) < 4 {
            if let quiet = quietFor, quiet > 200, !isRunningProgram { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        send(text: text)
    }
}
