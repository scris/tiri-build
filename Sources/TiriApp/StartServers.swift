import SwiftUI
import TiriCore

/// ▶ Start: one long-running program per folder, usually its dev server, in a terminal of its own. Tiri finds the
/// port it listens on and opens the page beside the code. Agents use the same one through `tiri start`, so there's
/// never a second copy fighting for the port, and nothing left running where nobody can see it.
/// A folder can be in two workspaces, and each has its own: everything here is by workspace and folder.
@MainActor
@Observable
final class FolderStarter {
    enum Phase: String { case starting, running, stopping }

    struct Key: Hashable {
        var workspace: WorkspaceID
        var folder: String
    }

    struct Server: Equatable {
        var terminal: ItemID
        var command: String
        var phase: Phase
        /// On the server, for a workspace there; the same as `localPort` here.
        var port: Int?
        /// Where this Mac reaches it: a forwarded port, for a workspace on a server.
        var localPort: Int?
        /// Pressed by someone, so the page opens when it's up. An agent's start leaves that to the agent.
        var opensPage: Bool
        /// Seen running at least once. A terminal picked up after a relaunch may have nothing running in it.
        var confirmed: Bool
    }

    @ObservationIgnored private weak var model: AppModel?
    private(set) var servers: [Key: Server] = [:]
    /// The folder whose chooser is open, and for which workspace.
    var choosing: Key?
    /// What each folder's files suggest. Observed, so ▶ Start appears once a project's files do.
    private(set) var guessed: [String: [StartGuess]] = [:]
    @ObservationIgnored private var guessedAt: [String: Date] = [:]
    @ObservationIgnored private var guessing: Set<String> = []
    @ObservationIgnored private var watchers: [Key: Task<Void, Never>] = [:]
    /// Between a press and its command being typed, which can take a few seconds. Another start then would type it twice.
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var adopted: Set<Key> = []

    init(model: AppModel) { self.model = model }

    func command(for folder: String) -> String? { model?.settings.startCommands[folder] }
    func server(_ folder: String, in workspace: WorkspaceID) -> Server? { servers[Key(workspace: workspace, folder: folder)] }

    /// What the files suggest, looked at off the main thread and again now and then, since an agent may only just
    /// have made the project. Empty until the first look is done.
    func guesses(for folder: String) -> [StartGuess] {
        if guessedAt[folder].map({ Date().timeIntervalSince($0) > 20 }) ?? true, guessing.insert(folder).inserted {
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) { StartFolders.guesses(in: folder) }.value
                guard let self else { return }
                self.guessing.remove(folder)
                self.guessedAt[folder] = Date()
                if self.guessed[folder] != found { self.guessed[folder] = found }
            }
        }
        return guessed[folder] ?? []
    }

    /// For the chooser, which needs them now.
    func guessesNow(for folder: String) -> [StartGuess] {
        let found = StartFolders.guesses(in: folder)
        guessed[folder] = found
        guessedAt[folder] = Date()
        return found
    }

    /// Only where there's something to start: a command, a guess, or a server already going.
    func shows(_ folder: String, in workspace: WorkspaceID) -> Bool {
        server(folder, in: workspace) != nil || command(for: folder) != nil || !guesses(for: folder).isEmpty
    }

    /// The folder of what you're looking at, or the workspace's first.
    func folderInFront() -> String? {
        guard let model else { return nil }
        let workspace = model.active
        if let item = workspace.peek ?? workspace.activeItem {
            switch item.content {
            case .file(let spec): if let folder = workspace.folder(containing: spec.path) { return folder }
            case .terminal(let spec):
                if let folder = spec.startsFolder, workspace.folders.contains(folder) { return folder }
                let here = (model.existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd
                if let folder = workspace.folder(containing: here) { return folder }
            default: break
            }
        }
        return workspace.folders.first
    }

    // MARK: Pressed

    /// ▶ Start, or ⌃⌥S: running, it opens the page; with a command it starts; without one it asks which.
    /// Only ever from someone at this Mac.
    func press(_ folder: String, in workspace: WorkspaceID) {
        if let server = server(folder, in: workspace), server.phase != .stopping {
            if server.port != nil { openPage(folder, in: workspace, focus: true) } else { showOutput(folder, in: workspace) }
            return
        }
        guard let command = command(for: folder) else {
            openChooser(folder, in: workspace)
            return
        }
        Task { _ = await start(folder, command: command, in: workspace, opensPage: true) }
    }

    func pressInFront() {
        guard let model, let folder = folderInFront() else {
            model?.showToast(title: String(localized: "Nothing to start"), detail: String(localized: "Add a folder to this workspace first."),
                             symbol: "play", tint: .secondary)
            return
        }
        press(folder, in: model.activeID)
    }

    func openChooser(_ folder: String, in workspace: WorkspaceID) {
        _ = guessesNow(for: folder)
        choosing = Key(workspace: workspace, folder: folder)
    }

    /// From the chooser: keeps the command for the folder, then starts it, or restarts it with the new one.
    func choose(_ command: String, for key: Key) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, choosing == key else { return }
        choosing = nil
        save(trimmed, for: key.folder)
        if let server = servers[key], server.phase != .stopping {
            if server.command != trimmed { restart(key.folder, in: key.workspace) }
            return
        }
        Task { _ = await start(key.folder, command: trimmed, in: key.workspace, opensPage: true) }
    }

    func save(_ command: String?, for folder: String) {
        guard let model else { return }
        var commands = model.settings.startCommands
        commands[folder] = command
        _ = model.setSetting("start.commands", to: .object(commands.mapValues(JSONValue.string)))
    }

    func askAgentToFind(_ key: Key) {
        guard let model else { return }
        choosing = nil
        guard let agent = model.runnableAgentPresets().first else {
            model.showToast(title: String(localized: "No agent to ask"), detail: String(localized: "Turn one on in Settings."), symbol: "sparkles", tint: .secondary)
            return
        }
        model.askAgent(preset: agent, prompt: Self.findPrompt(key.folder))
    }

    static func findPrompt(_ folder: String) -> String {
        "Find out how to start the project in \(folder): its dev server, or its main program if it has no server. "
            + "Read its files (package.json, README, Procfile, docker compose, .claude/launch.json and so on), and don't start anything yourself. "
            + "When you know, save it with `tiri start set \"<command>\" --folder \(ShellQuote.quote(folder))`, "
            + "then start it with `tiri start --folder \(ShellQuote.quote(folder))`, and tell me the address it prints."
    }

    // MARK: Running

    /// Starts the folder's command in its own terminal in that workspace, or finds it already going.
    /// Waits for the shell's prompt, not for the server.
    func start(_ folder: String, command: String, in workspace: WorkspaceID, opensPage: Bool) async -> Server? {
        guard let model, model.workspaces.contains(where: { $0.id == workspace }) else { return nil }
        let key = Key(workspace: workspace, folder: folder)
        adopt(key)
        // Picked up after a relaunch, and not yet known to be a server rather than the shell's own setup: a moment tells.
        let began = Date()
        while let server = servers[key], !server.confirmed, server.phase == .starting, !inFlight.contains(key), Date().timeIntervalSince(began) < 3 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let server = servers[key], server.phase != .stopping {
            if server.confirmed || inFlight.contains(key) { return server }
            // Still unknown, with nothing running in it: that's no server, so it starts.
            let terminal = model.existingController(for: server.terminal) as? TerminalController
            if terminal?.isRunningProgram == true { return server }
            end(key)
        }
        // Already starting, or a restart is under way: that one, not a second.
        guard servers[key] == nil, inFlight.insert(key).inserted else { return servers[key] ?? Server(terminal: "", command: command, phase: .starting, port: nil, localPort: nil, opensPage: false, confirmed: false) }
        defer { inFlight.remove(key) }
        let line = command + "\r"
        if let existing = startTerminal(for: key),
           let controller = model.controller(for: existing) as? TerminalController, !controller.hasExited {
            controller.startIfNeeded(fallbackSize: true)
            servers[key] = Server(terminal: existing, command: command, phase: .starting, port: nil, localPort: nil, opensPage: opensPage, confirmed: false)
            if controller.isRunningProgram {
                // Started by hand in its terminal: it's that one.
                servers[key]?.confirmed = true
            } else {
                let here = controller.currentDirectory
                await controller.typeWhenReady((FileRunner.sameFolder(here, folder) ? "" : "cd \(ShellQuote.quote(folder)) && ") + line)
            }
        } else {
            // Named for its folder too: two folders' `npm run dev` are otherwise one name twice.
            var spec = TerminalSpec(cwd: folder, title: "\((folder as NSString).lastPathComponent): \(StartFolders.title(of: command))")
            spec.startsFolder = folder
            let item = Item(content: .terminal(spec))
            // A tab behind what you're looking at: the page is what you want to see, and the output is a click away.
            model.update(workspace: workspace) { space in
                let behind = space.focused.active
                space.addItem(item)
                if let behind { space.activate(behind) }
            }
            guard let controller = model.controller(for: item.id) as? TerminalController else { return nil }
            controller.startIfNeeded(fallbackSize: true)
            servers[key] = Server(terminal: item.id, command: command, phase: .starting, port: nil, localPort: nil, opensPage: opensPage, confirmed: false)
            await controller.typeWhenReady(line)
        }
        guard servers[key] != nil else { return nil }
        watch(key)
        return servers[key]
    }

    /// After a relaunch the server is still running in its terminal. Picked up once per workspace and folder,
    /// when its terminal is found.
    func adopt(_ key: Key) {
        guard let model, servers[key] == nil, !adopted.contains(key), let terminal = startTerminal(for: key),
              let controller = model.controller(for: terminal) as? TerminalController else { return }
        adopted.insert(key)
        controller.startIfNeeded(fallbackSize: true)
        servers[key] = Server(terminal: terminal, command: command(for: key.folder) ?? "", phase: .starting, port: nil, localPort: nil,
                              opensPage: false, confirmed: false)
        watch(key, adopting: true)
    }

    private func startTerminal(for key: Key) -> ItemID? {
        model?.workspaces.first { $0.id == key.workspace }?.items.first { item in
            if case .terminal(let spec) = item.content { return spec.startsFolder == key.folder }
            return false
        }?.id
    }

    private func end(_ key: Key) {
        watchers.removeValue(forKey: key)?.cancel()
        servers[key] = nil
    }

    /// Follows the server: when it's listening, on which port, and when it ends.
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
                    }
                    idleSince = nil
                    // Often until there's a port, for 20 seconds. Then now and then: some never print one or hold it
                    // themselves, like docker compose, and a restart by hand can move it.
                    let every: TimeInterval = server.port == nil && Date().timeIntervalSince(began) < 20 ? 0.4 : 5
                    if Date().timeIntervalSince(lastLook) >= every {
                        lastLook = Date()
                        self.lookForPort(key, controller: controller)
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

    private func lookForPort(_ key: Key, controller: TerminalController) {
        guard var server = servers[key] else { return }
        // Only what this run printed: the terminal may hold an earlier run's address.
        var output = controller.readText(lines: 300)
        if !server.command.isEmpty, let typed = output.range(of: server.command, options: .backwards) { output = String(output[typed.upperBound...]) }
        let printed = StartFolders.printedPort(in: output)
        let port: Int?
        if controller.isOnServer {
            // On a server only what it printed can be known.
            port = printed
        } else {
            port = StartFolders.pagePort(listening: controller.localShell.map(ListeningPorts.under) ?? [], printed: printed)
        }
        guard let port, port != server.port else { return }
        let first = server.port == nil
        server.port = port
        server.localPort = controller.isOnServer ? nil : port
        // Stopping stays stopping: its second ⌃C depends on it.
        if server.phase == .starting { server.phase = .running }
        let opens = server.opensPage && first
        server.opensPage = false
        servers[key] = server
        if opens { openPage(key.folder, in: key.workspace, focus: false) }
    }

    /// It stopped by itself: says so, with what it last printed, and offers the agent.
    private func ended(_ key: Key, server: Server, controller: TerminalController) {
        guard let model else { return }
        let folder = key.folder
        let last = controller.readText(lines: 40).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasSuffix("%") && !$0.hasSuffix("$") && !$0.hasSuffix(">") }
        let name = (folder as NSString).lastPathComponent
        let agent = model.runnableAgentPresets().first
        model.showToast(title: String(localized: "\(name) stopped"), detail: last, symbol: "stop.circle", tint: .orange,
                        actionTitle: agent.map { String(localized: "Ask \($0.name)") }, duration: 12,
                        other: (String(localized: "Show Output"), { [weak self] in self?.showOutput(folder, in: key.workspace, terminal: server.terminal) })) {
            guard let agent else { return }
            model.askAgent(preset: agent, prompt: "The dev server for \(folder) stopped by itself. It runs `\(server.command)` in a Tiri terminal. "
                + "Read what it printed with `tiri start logs --folder \(ShellQuote.quote(folder))`, find out why and fix it, "
                + "then start it again with `tiri start --folder \(ShellQuote.quote(folder))`.")
        }
    }

    func stop(_ folder: String, in workspace: WorkspaceID) {
        let key = Key(workspace: workspace, folder: folder)
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

    /// Only what's running, in the workspace it's running in. Never a press: a restart asked for from a server's
    /// terminal must not start anything on this Mac, or ask anything of the person here.
    func restart(_ folder: String, in workspace: WorkspaceID) {
        let key = Key(workspace: workspace, folder: folder)
        guard let server = servers[key], !inFlight.contains(key) else { return }
        let command = command(for: folder) ?? server.command
        guard !command.isEmpty else { return }
        inFlight.insert(key)
        stop(folder, in: workspace)
        Task { [weak self] in
            let began = Date()
            while self?.servers[key] != nil, Date().timeIntervalSince(began) < 10 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.inFlight.remove(key)
            _ = await self?.start(folder, command: command, in: workspace, opensPage: false)
        }
    }

    func showOutput(_ folder: String, in workspace: WorkspaceID, terminal: ItemID? = nil) {
        guard let model, let item = terminal ?? servers[Key(workspace: workspace, folder: folder)]?.terminal ?? startTerminal(for: Key(workspace: workspace, folder: folder)) else { return }
        _ = model.focusItem(item)
    }

    func address(_ folder: String, in workspace: WorkspaceID) -> String? {
        server(folder, in: workspace)?.port.map { "http://localhost:\($0)" }
    }

    /// Beside the code, without taking the keyboard unless asked. An open page for it is reused.
    func openPage(_ folder: String, in workspaceID: WorkspaceID, focus: Bool) {
        let key = Key(workspace: workspaceID, folder: folder)
        guard let model, let server = servers[key], let port = server.port,
              let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let ports = Set([port, server.localPort].compactMap { $0 })
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
                self?.servers[key]?.localPort = local.port
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
        // From a server's terminal it's only ever that server's own workspace: nothing it asks may run on this Mac.
        if request.args["fromServer"]?.boolValue == true {
            let asked = request.args["folder"]?.stringValue ?? ""
            guard let theirs = model.workspaces.first(where: { $0.id == workspace && $0.remote != nil && $0.folder(containing: asked) != nil })
                    ?? model.workspaces.first(where: { $0.remote != nil && $0.folder(containing: asked) != nil }) else {
                return .failure(id: request.id, "That folder isn't in a workspace on this server.")
            }
            workspace = theirs.id
        }
        guard let space = model.workspaces.first(where: { $0.id == workspace }) else { return .failure(id: request.id, "No workspace.") }
        let asked = request.args["folder"]?.stringValue ?? space.folders.first ?? ""
        guard let folder = space.folder(containing: asked) ?? space.folders.first(where: { $0 == asked }) else {
            return .failure(id: request.id, "\(asked) isn't in this workspace's folders: \(space.folders.joined(separator: ", ")).")
        }
        let key = Key(workspace: workspace, folder: folder)
        adopt(key)
        func status() -> ControlResponse {
            var result: [String: JSONValue] = ["folder": .string(folder), "state": .string(servers[key]?.phase.rawValue ?? "stopped")]
            if let command = command(for: folder) ?? servers[key]?.command, !command.isEmpty { result["command"] = .string(command) }
            if let address = address(folder, in: workspace) { result["url"] = .string(address) }
            if let server = servers[key] { result["item"] = .string(server.terminal) }
            return .success(id: request.id, .object(result))
        }
        switch request.args["action"]?.stringValue ?? "start" {
        case "status":
            return status()
        case "guesses":
            return .success(id: request.id, .array(guessesNow(for: folder).map { guess in
                var entry: [String: JSONValue] = ["command": .string(guess.command), "source": .string(guess.source)]
                if let detail = guess.detail { entry["detail"] = .string(detail) }
                return .object(entry)
            }))
        case "set":
            guard let command = request.args["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return .failure(id: request.id, "usage: tiri start set \"<command>\"")
            }
            save(command, for: folder)
            return status()
        case "stop":
            stop(folder, in: workspace)
            return status()
        case "restart":
            guard servers[key] != nil else { return .failure(id: request.id, "It isn't running. Start it with tiri start.") }
            restart(folder, in: workspace)
            return status()
        case "logs":
            guard let terminal = servers[key]?.terminal ?? startTerminal(for: key),
                  let controller = model.controller(for: terminal) as? TerminalController else {
                return .failure(id: request.id, "\((folder as NSString).lastPathComponent) hasn't been started.")
            }
            controller.startIfNeeded(fallbackSize: true)
            return .success(id: request.id, .object(["text": .string(controller.readText(lines: request.args["lines"]?.intValue ?? 80))]))
        default:
            guard let command = command(for: folder) else {
                let found = guessesNow(for: folder)
                var message = "\((folder as NSString).lastPathComponent) has no start command yet."
                if !found.isEmpty { message += " Tiri's guesses: " + found.map { "`\($0.command)` (\($0.source))" }.joined(separator: ", ") + "." }
                message += " Save one with: tiri start set \"<command>\" --folder \(ShellQuote.quote(folder))"
                return .failure(id: request.id, message)
            }
            guard await start(folder, command: command, in: workspace, opensPage: false) != nil else {
                // Another start of it is under way: wait for that one.
                if inFlight.contains(key) || servers[key] != nil { return await waitForAddress(key, request: request, status: status) }
                return .failure(id: request.id, "Couldn't start it.")
            }
            return await waitForAddress(key, request: request, status: status)
        }
    }

    /// So whoever asked can use the address straight away. Under a minute: a server's `tiri` waits only that long.
    private func waitForAddress(_ key: Key, request: ControlRequest, status: () -> ControlResponse) async -> ControlResponse {
        let began = Date()
        while Date().timeIntervalSince(began) < 50 {
            // Through a restart too: the old run's address isn't the answer, and between the two there's no server at all.
            if let server = servers[key], server.phase == .running, server.port != nil { break }
            if servers[key] == nil, !inFlight.contains(key) { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if servers[key] == nil, !inFlight.contains(key) {
            return .failure(id: request.id, "It stopped. What it printed: tiri start logs --folder \(ShellQuote.quote(key.folder))")
        }
        return status()
    }
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

// MARK: - In the bar along the bottom

/// One folder's Start: ▶ Start, then Starting…, then its address. Next to its branch, since both are about the folder.
struct StartStatusItem: View {
    let folder: String
    let showsName: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope

    private var starter: FolderStarter { model.starter }
    /// This window's workspace, which may not be the one in front.
    private var workspace: WorkspaceID { WindowModel(app: model, scope: scope).activeID }
    private var name: String { (folder as NSString).lastPathComponent }

    var body: some View {
        let server = starter.server(folder, in: workspace)
        HStack(spacing: 7) {
            switch server?.phase {
            case nil:
                Button { starter.press(folder, in: workspace) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Start").font(.system(size: 12))
                        if showsName { folderName }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(starter.command(for: folder).map { String(localized: "Start \($0)") } ?? String(localized: "Choose what starts \(name)"))
            case .starting?, .stopping?:
                Button { starter.showOutput(folder, in: workspace) } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(server?.phase == .stopping ? String(localized: "Stopping") : String(localized: "Starting")).font(.system(size: 12))
                        if showsName { folderName }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show its output")
                if server?.phase == .starting { stopButton }
            case .running?:
                Button { starter.openPage(folder, in: workspace, focus: true) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(verbatim: "localhost:\(server?.port ?? 0)").font(.system(size: 12).monospacedDigit())
                        if showsName { folderName }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open the page. \(server?.command ?? "") is running"))
                iconButton("arrow.clockwise", help: String(localized: "Restart")) { starter.restart(folder, in: workspace) }
                stopButton
            }
        }
        .fixedSize()
        .contextMenu { menu(server) }
        .onAppear { starter.adopt(FolderStarter.Key(workspace: workspace, folder: folder)) }
    }

    private var folderName: some View {
        Text(verbatim: name).font(.system(size: 11)).foregroundStyle(.faint).lineLimit(1)
    }

    private var stopButton: some View {
        iconButton("stop.fill", help: String(localized: "Stop")) { starter.stop(folder, in: workspace) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private func menu(_ server: FolderStarter.Server?) -> some View {
        if server != nil {
            if server?.port != nil { Button("Open Page") { starter.openPage(folder, in: workspace, focus: true) } }
            Button("Show Output") { starter.showOutput(folder, in: workspace) }
            Button("Restart") { starter.restart(folder, in: workspace) }
            Button("Stop") { starter.stop(folder, in: workspace) }
            Divider()
        }
        Button("Change Start Command…") { starter.openChooser(folder, in: workspace) }
    }
}

/// What starts a folder: Tiri's guesses to pick from, your own, or your agent to find it.
struct StartChooser: View {
    let key: FolderStarter.Key
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var own = ""
    /// Your own command is the choice: set by typing in it or clicking it, and only a guess unsets it.
    @State private var usesOwn = false
    @FocusState private var typing: Bool

    private var starter: FolderStarter { model.starter }
    private var guesses: [StartGuess] { starter.guessed[key.folder] ?? [] }
    private var current: String? { starter.command(for: key.folder) }
    /// The guesses, with what's set now first if it isn't one of them.
    private var choices: [StartGuess] {
        guard let current, !guesses.contains(where: { $0.command == current }) else { return guesses }
        return [StartGuess(command: current, source: String(localized: "Yours"))] + guesses
    }
    private var chosen: String {
        (usesOwn ? own : selected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start \((key.folder as NSString).lastPathComponent)").font(.headline)
            VStack(spacing: 2) {
                ForEach(choices) { guess in row(guess) }
                ownRow
            }
            HStack {
                if let agent = model.runnableAgentPresets().first {
                    Button("Ask \(agent.name) to Find It") { starter.askAgentToFind(key) }
                }
                Spacer()
                Button("Cancel") { starter.choosing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { starter.choose(chosen, for: key) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear {
            selected = current ?? choices.first?.command
            if choices.isEmpty {
                usesOwn = true
                typing = true
            }
        }
    }

    private func row(_ guess: StartGuess) -> some View {
        let isOn = !usesOwn && selected == guess.command
        return Button {
            selected = guess.command
            usesOwn = false
            typing = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: guess.command).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(verbatim: guess.source).font(.caption).foregroundStyle(.secondary)
                        if let detail = guess.detail {
                            Text(verbatim: detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isOn ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ownRow: some View {
        HStack(spacing: 8) {
            Image(systemName: usesOwn ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(usesOwn ? Color.accentColor : .secondary)
                .font(.system(size: 12))
            // Return is the Start button's, so the field has no submit of its own: one press, one start.
            TextField("Your own command", text: $own)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .focused($typing)
                .onChange(of: typing) { _, now in if now { usesOwn = true } }
                .onChange(of: own) { _, _ in usesOwn = true }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(usesOwn ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            usesOwn = true
            typing = true
        }
    }
}

// MARK: - Settings → Run

/// Each folder's Start command, to change or forget. The bar is where they're made, so with none yet it says where that is.
struct StartCommandsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let commands = model.settings.startCommands.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        SettingsGroup(String(localized: "Start a Folder")) {
            if commands.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("Start, in the bar along the bottom, runs a folder's dev server. What each folder runs shows here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsCard {
                    ForEach(Array(commands.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { SettingsRowDivider() }
                        StartCommandRow(folder: entry.key, command: entry.value)
                    }
                }
            }
        }
    }
}

private struct StartCommandRow: View {
    let folder: String
    let command: String
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        // The folder's name. Where it is shows on pointing at it: a clipped path says nothing.
        let words = HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(verbatim: (folder as NSString).lastPathComponent).lineLimit(1)
        }
        Group {
            if rowsStack {
                VStack(alignment: .leading, spacing: 6) { words; HStack { field; remove } }
            } else {
                HStack(spacing: 12) { words.frame(width: 118, alignment: .leading); field; remove }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(folder)
    }

    private var field: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(editing ? 0.09 : hovering ? 0.05 : 0))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(editing ? 0.7 : 0), lineWidth: 1) }
            }
            .onHover { hovering = $0 }
            .focused($editing)
            .onAppear { draft = command }
            .onChange(of: command) { _, value in if !editing { draft = value } }
            .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
            .onSubmit { commit() }
            .accessibilityLabel(String(localized: "Start command for \((folder as NSString).lastPathComponent)"))
    }

    private var remove: some View {
        Button {
            model.starter.save(nil, for: folder)
        } label: {
            Image(systemName: "minus.circle").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Forget it. Start asks again next time")
        .accessibilityLabel(String(localized: "Forget the start command for \((folder as NSString).lastPathComponent)"))
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { draft = command; return }
        if text != command { model.starter.save(text, for: folder) }
    }
}
