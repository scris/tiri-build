import SwiftUI
import TiriCore

/// ▶ and ⌃⌥N: save the file, then type its command into the workspace's Run terminal, in the file's folder.
/// A real shell, so input, ↑ to run again, ⌘-clicking an error's path and ⌘L all work as in any terminal.
/// While the program runs the keyboard is with it, and it comes back to the file when the program ends.
@MainActor
@Observable
final class FileRunner {
    @ObservationIgnored private weak var model: AppModel?
    /// Files whose program is running now, and the terminal it's in. One terminal runs one file at a time.
    private(set) var running: [String: ItemID] = [:]
    /// What the shell found for each tool, on this Mac. Missing ones are asked again on each run, so installing one counts.
    private(set) var located: [String: Bool] = [:]
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var lookedForAll = false
    @ObservationIgnored private var watchers: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Between a press and its command being typed. Another press then would type it twice.
    @ObservationIgnored private var starting = false
    /// What each workspace ran last, so ⌃⌥N in the Run terminal itself runs it again.
    @ObservationIgnored private var lastRun: [WorkspaceID: (item: ItemID, path: String)] = [:]
    /// A kind of file someone tried to run, for Settings → Run to open its Add row with.
    var adding: String?

    init(model: AppModel) { self.model = model }

    static var terminalTitle: String { String(localized: "Run") }

    func plan(for path: String) -> RunPlan? {
        guard let settings = model?.settings else { return nil }
        return RunCommands.plan(for: path, commands: settings.runCommands, off: settings.runOff)
    }

    func isRunning(_ path: String) -> Bool { running[path] != nil }

    // MARK: Looking for tools

    /// Looks for every language's program once, for Settings to say which are on this Mac.
    func lookForTools() {
        guard let model, lookup == nil, !lookedForAll else { return }
        let names = RunCommands.tools(commands: model.settings.runCommands)
        let shell = Self.shell(model)
        lookup = Task { [weak self] in
            let found = await ShellLookup.locations(names: names, shell: shell)
            guard let self else { return }
            if let found {
                for name in names { self.located[name] = found[name] != nil }
                self.lookedForAll = true
            }
            self.lookup = nil
        }
    }

    private func isInstalled(_ tool: String) async -> Bool? {
        guard let model else { return nil }
        if located[tool] == true { return true }
        guard let found = await ShellLookup.locations(names: [tool], shell: Self.shell(model)) else { return nil }
        located[tool] = found[tool] != nil
        return found[tool] != nil
    }

    private static func shell(_ model: AppModel) -> String {
        model.settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : model.settings.terminalShell
    }

    // MARK: Running

    /// The file in front: the Peek's, or the focused tab's. From the Run terminal itself, what it ran last.
    func runFront() {
        guard let model else { return }
        let front = model.active.peek ?? model.active.activeItem
        if let front, case .file(let spec) = front.content {
            run(item: front.id, path: spec.path)
            return
        }
        if let front, case .terminal(let spec) = front.content, spec.runsFiles == true,
           let last = lastRun[model.activeID], isOpen(last.item) {
            run(item: last.item, path: last.path)
            return
        }
        model.showToast(title: String(localized: "Nothing to run"), detail: String(localized: "Run works on a file, like a .py or .cpp."),
                        symbol: "play", tint: .secondary)
    }

    /// In the workspace in front, as a tab or as its Peek.
    private func isOpen(_ file: ItemID) -> Bool {
        guard let model else { return false }
        return model.active.item(file) != nil || model.active.peek?.id == file
    }

    func run(item: ItemID, path: String) {
        guard let model, !starting else { return }
        guard let plan = plan(for: path) else {
            let ext = RunCommands.extensionKey(path)
            model.showToast(title: String(localized: "Tiri doesn't run this kind of file yet"),
                            detail: ext.map { String(localized: "Tell Tiri what runs \($0) files, and ▶ appears above them.") },
                            symbol: "play", tint: .secondary, actionTitle: ext == nil ? nil : String(localized: "Add a Command…")) { [weak self] in
                self?.adding = ext
                model.openSettings(pane: .run)
            }
            return
        }
        let workspace = model.activeID
        let go = { [weak self] in
            guard let self, !self.starting else { return }
            self.starting = true
            Task {
                await self.start(plan, file: item, path: path, workspace: workspace)
                self.starting = false
            }
        }
        if let controller = model.existingController(for: item) {
            model.save(controller, then: go)
        } else {
            go()
        }
    }

    private func start(_ plan: RunPlan, file: ItemID, path: String, workspace: WorkspaceID) async {
        guard let model else { return }
        if model.active.remote != nil {
            // The save goes up in the background. Running before it's there would run the old file.
            if let connection = RemoteRegistry.shared.connection(forLocal: path) {
                let began = Date()
                while connection.isSaving(path), Date().timeIntervalSince(began) < 10 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else if let tool = plan.tool {
            // A server has its own programs, and its shell says so if one's missing. Asking this Mac's shell takes
            // a second or two with a heavy shell setup, so Run only waits for it when the program was missing before.
            switch located[tool] {
            case true?:
                break
            case false?:
                if await isInstalled(tool) == false {
                    missing(tool, plan: plan, path: path)
                    return
                }
            case nil:
                Task { [weak self] in
                    if await self?.isInstalled(tool) == false { self?.missing(tool, plan: plan, path: path) }
                }
            }
        }
        // Someone moved to another workspace meanwhile: running it there would be a surprise.
        guard model.activeID == workspace, isOpen(file) else { return }
        lastRun[workspace] = (file, path)
        let line = plan.command + "\r"
        let terminal: ItemID
        if let existing = runTerminal() {
            terminal = existing
            _ = model.focusItem(existing)
            // After a relaunch it may not have started yet.
            let started = model.existingController(for: existing) != nil
            guard let controller = model.controller(for: existing) as? TerminalController else { return }
            let typed = (started && Self.sameFolder(controller.currentDirectory, plan.directory) ? "" : "cd \(ShellQuote.quote(plan.directory)) && ") + line
            if controller.isRunningProgram {
                // Run means this file, fresh: what's still going stops first.
                controller.send(text: "\u{03}")
                try? await Task.sleep(for: .milliseconds(150))
            }
            if started { controller.send(text: typed) } else { await controller.typeWhenReady(typed) }
        } else {
            terminal = makeRunTerminal(in: plan.directory)
            guard let controller = model.controller(for: terminal) as? TerminalController else { return }
            await controller.typeWhenReady(line)
        }
        watch(path: path, terminal: terminal, file: file, workspace: workspace)
    }

    /// The workspace's Run terminal, if it's still there and its shell hasn't ended. The one in view, if there are several.
    private func runTerminal() -> ItemID? {
        guard let model else { return nil }
        let candidates = model.active.items.filter { item in
            guard case .terminal(let spec) = item.content, spec.runsFiles == true else { return false }
            return (model.existingController(for: item.id) as? TerminalController)?.hasExited != true
        }.map(\.id)
        let shown = Set(model.active.groups.compactMap(\.active))
        return candidates.first(where: shown.contains) ?? candidates.first
    }

    /// /tmp and /private/tmp are one folder, and a shell reports the second.
    static func sameFolder(_ one: String, _ other: String) -> Bool {
        one == other || URL(fileURLWithPath: one).resolvingSymlinksInPath().path == URL(fileURLWithPath: other).resolvingSymlinksInPath().path
    }

    private func makeRunTerminal(in directory: String) -> ItemID {
        guard let model else { return ItemID() }
        let split: SplitDirection? = switch model.settings.runOpensIn {
        case .below: .down
        case .right: .right
        case .tab: nil
        }
        var spec = TerminalSpec(cwd: directory, title: Self.terminalTitle)
        spec.runsFiles = true
        let item = Item(content: .terminal(spec))
        model.updateActive { $0.addItem(item, split: split) }
        _ = model.focusItem(item.id)
        return item.id
    }

    /// Marks the file as running until the program ends, then gives the keyboard back to the file,
    /// unless it's gone somewhere else meanwhile or the terminal is a tab covering the file.
    private func watch(path: String, terminal: ItemID, file: ItemID, workspace: WorkspaceID) {
        // What ran there before has been stopped: one terminal, one file at a time.
        for (other, place) in running where place == terminal || other == path { end(other) }
        let token = UUID()
        running[path] = terminal
        let task = Task { [weak self] in
            let began = Date()
            var seenRunning = false
            // `clang++ a.cpp -o /tmp/a && /tmp/a` is two programs, with the shell in between for a moment.
            // So it's over once the shell has had the terminal for a while, not at the first sight of it.
            var idleSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let model = self.model else { return }
                guard model.anyItem(terminal) != nil, let controller = model.existingController(for: terminal) as? TerminalController,
                      !controller.hasExited else { break }
                if controller.isRunningProgram {
                    seenRunning = true
                    idleSince = nil
                    continue
                }
                let idle = idleSince ?? Date()
                idleSince = idle
                // A program over before it was ever seen running still has to start first.
                if (seenRunning && Date().timeIntervalSince(idle) > 0.4) || (!seenRunning && Date().timeIntervalSince(began) > 0.8) {
                    self.finished(path: path, terminal: terminal, file: file, workspace: workspace, token: token)
                    return
                }
            }
            // Only this watch's own, since a newer one may have taken over the file.
            if let self, self.watchers[path]?.token == token { self.end(path) }
        }
        watchers[path] = (token, task)
    }

    private func end(_ path: String) {
        watchers.removeValue(forKey: path)?.task.cancel()
        running[path] = nil
    }

    private func finished(path: String, terminal: ItemID, file: ItemID, workspace: WorkspaceID, token: UUID) {
        guard watchers[path]?.token == token else { return }
        end(path)
        guard let model, model.activeID == workspace, model.active.focused.active == terminal, isOpen(file) else { return }
        if model.active.peek?.id == file {
            model.peekHasKeyboard = true
            model.requestFocus()
            return
        }
        // A tab would hide what it printed.
        if model.active.group(containing: file)?.id == model.active.group(containing: terminal)?.id { return }
        _ = model.focusItem(file)
    }

    func stop(_ path: String) {
        guard let model, let terminal = running[path],
              let controller = model.existingController(for: terminal) as? TerminalController else { return }
        controller.send(text: "\u{03}")
    }

    private func missing(_ tool: String, plan: RunPlan, path: String) {
        guard let model else { return }
        let file = (path as NSString).lastPathComponent
        let agent = model.runnableAgentPresets().first
        model.showToast(title: String(localized: "\(tool) isn't on this Mac"),
                        detail: String(localized: "\(file) runs with \(plan.command)"),
                        symbol: "play.slash", tint: .orange,
                        actionTitle: agent.map { String(localized: "Ask \($0.name) to Install It") },
                        other: (String(localized: "Change Command"), { model.openSettings(pane: .run, reveal: "run.\(plan.key)") })) {
            guard let agent else { return }
            model.askAgent(preset: agent, prompt: "Install \(tool) on this Mac so I can run \(file) with `\(plan.command)` from a terminal. "
                + "Use what's already here, like Homebrew, if it is, and check it works with `command -v \(tool)` in a new login shell. "
                + "If another program would suit better, say so, and I can change the command in Tiri's Settings → Run.")
        }
    }
}

// MARK: - Above a file

struct RunFileButton: View {
    let path: String
    let item: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.runButton, let plan = model.runner.plan(for: path) {
            let isRunning = model.runner.isRunning(path)
            Button {
                if isRunning { model.runner.stop(path) } else { model.runner.run(item: item, path: path) }
            } label: {
                Label(isRunning ? String(localized: "Stop") : String(localized: "Run"),
                      systemImage: isRunning ? "stop.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help(isRunning ? String(localized: "Stop what's running (⌃C in the Run terminal)") : String(localized: "Run \(plan.command)"))
            // So the first press doesn't wait for the shell to say what's installed.
            .onAppear { model.runner.lookForTools() }
        }
    }
}
