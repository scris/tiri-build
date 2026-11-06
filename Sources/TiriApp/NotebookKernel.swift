import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import TiriCore

private func shellQuoted(_ word: String) -> String { RemoteShell.arguments([word]) }

private nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func reset() { lock.withLock { pending = Data() } }

    func add(_ data: Data) -> [Data] {
        lock.withLock {
            pending.append(data)
            guard pending.contains(10) else { return [] }
            var result: [Data] = []
            while let end = pending.firstIndex(of: 10) {
                result.append(Data(pending[pending.startIndex..<end]))
                pending.removeSubrange(pending.startIndex...end)
            }
            pending = Data(pending)
            return result
        }
    }
}

/// One notebook's kernel. The work happens in `tiri-kernel.py`, on this Mac or on the server the
/// notebook is on, which keeps going whether or not anything's attached. This is only the view of it:
/// what it's doing, and a way to ask it for more.
@MainActor @Observable
final class NotebookKernel {
    enum State: Equatable { case off, finding, starting, idle, busy, stopped, reconnecting }

    /// Where the notebook is on this Mac. On a server, that's its place in the sparse copy.
    let path: String
    private(set) var state: State = .off
    private(set) var running: Int?
    private(set) var queued: [Int] = []
    struct Question: Equatable {
        var prompt: String
        var password: Bool
    }
    /// What the running cell is waiting to be told.
    private(set) var question: Question?
    /// "Python 3.12.1", once one has been chosen.
    private(set) var title: String?
    private(set) var pythonPath: String?

    @ObservationIgnored private unowned let kernels: NotebookKernels
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var waiting: [JSONValue] = []
    @ObservationIgnored private var wantsAttachment = false
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private let lines = LineBuffer()

    init(path: String, kernels: NotebookKernels) {
        self.path = path
        self.kernels = kernels
    }

    var isAttached: Bool { process?.isRunning == true }
    var isActive: Bool { state == .busy || !queued.isEmpty || running != nil }
    var hasKernel: Bool { ![.off, .finding].contains(state) }

    private var connection: RemoteConnection? { RemoteRegistry.shared.connection(forLocal: path) }

    private var key: String {
        let name = connection?.map.remote(path) ?? path
        return SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static let script: Data = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("remote/tiri-kernel.py"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    private static var localRoot: String {
        (RemoteMirror.root as NSString).deletingLastPathComponent + "/Kernels"
    }

    /// Shell words for this kernel's folder, and for the program.
    private var directory: String {
        connection == nil ? shellQuoted(Self.localRoot + "/" + key) : "\"$HOME\"/.tiri/kernels/" + key
    }

    private var scriptPath: String {
        if connection == nil { return shellQuoted(Bundle.main.resourceURL?.appendingPathComponent("remote/tiri-kernel.py").path ?? "") }
        let version = SHA256.hash(data: Self.script).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\"$HOME\"/.tiri/bin/tiri-kernel-\(version).py"
    }

    // MARK: Asking it for things

    func run(cells: [Int]) {
        guard !cells.isEmpty else { return }
        send(["op": "run", "cells": .array(cells.map(JSONValue.int))])
    }

    func runAll() { send(["op": "run", "all": true]) }

    func interrupt() { sendIfAttached(["op": "interrupt"]) }

    func restart() { send(["op": "restart"]) }

    func stop() {
        wantsAttachment = false
        waiting = []
        if isAttached {
            sendIfAttached(["op": "stop"])
        } else {
            stopUnattached()
        }
        state = .off
        running = nil
        queued = []
    }

    /// It may be running with nothing attached, after a dropped connection or a relaunch.
    private func stopUnattached() {
        let command = "[ -f \(directory)/python ] && printf '{\"op\":\"stop\"}\\n' | \(python(in: directory)) \(scriptPath) attach \(directory) >/dev/null 2>&1"
        if let connection {
            Task.detached { _ = connection.run(command, timeout: 15) }
        } else {
            Task { _ = await kernels.runDirectly(command) }
        }
    }

    func answer(_ value: String) {
        question = nil
        sendIfAttached(["op": "input", "value": .string(value)])
        kernels.statusChanged(self)
    }

    /// True if it went to the kernel, which then does the writing.
    func edit(_ fields: [String: JSONValue]) -> Bool {
        guard isAttached else { return false }
        var message = fields
        message["op"] = "edit"
        sendIfAttached(message)
        return true
    }

    func usePython(_ path: String) {
        kernels.rememberPython(path, for: self.path)
        guard hasKernel else { return }
        stop()
        // It takes a moment to let go of the folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.send(["op": "status"]) }
    }

    private func sendIfAttached(_ message: [String: JSONValue]) {
        guard let input, let data = try? JSONEncoder().encode(JSONValue.object(message)) else { return }
        try? input.write(contentsOf: data + Data([10]))
    }

    private func send(_ message: [String: JSONValue]) {
        if isAttached {
            sendIfAttached(message)
            return
        }
        waiting.append(.object(message))
        guard state == .off || state == .stopped else { return }
        Task { await bringUp() }
    }

    // MARK: Finding Python, and starting

    private func bringUp() async {
        state = .finding
        wantsAttachment = true
        if await isRunningAlready() {
            attach()
            return
        }
        let found = await kernels.pythons(for: path)
        guard state == .finding else { return }
        let remembered = kernels.rememberedPython(for: path)
        guard let python = found.usable.first(where: { $0.path == remembered }) ?? found.usable.first else {
            state = .off
            waiting = []
            wantsAttachment = false
            kernels.offerInstall(for: path, found: found.without)
            return
        }
        pythonPath = python.path
        title = "Python \(Self.shortVersion(python.version))"
        state = .starting
        let notebook = connection?.map.remote(path) ?? path
        let kernelName = Self.kernelName(for: path, offeredBy: python)
        let start = "\(shellQuoted(python.path)) \(scriptPath) start \(directory) \(shellQuoted(notebook))"
            + (kernelName.map { " " + shellQuoted($0) } ?? "")
        let started = await kernels.runInLoginShell(start, for: path, needsScript: connection != nil)
        guard state == .starting else { return }
        guard started?.succeeded == true else {
            state = .off
            waiting = []
            wantsAttachment = false
            kernels.tell(path: path, String(localized: "The kernel couldn't start"), detail: started?.errorText.isEmpty == false ? started?.errorText : nil)
            return
        }
        attach()
    }

    /// A notebook that isn't Python says which kernel it wants.
    private static func kernelName(for path: String, offeredBy python: NotebookKernels.Python) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let spec = metadata["kernelspec"] as? [String: Any],
              let name = spec["name"] as? String else { return nil }
        let language = (spec["language"] as? String)?.lowercased() ?? (metadata["language_info"] as? [String: Any])?["name"] as? String
        if language?.lowercased() == "python" || name.hasPrefix("python") { return nil }
        return python.kernels[name] != nil ? name : nil
    }

    /// 3.12, not 3.12.13. The whole path is in the tooltip.
    private static func shortVersion(_ version: String) -> String { version.split(separator: ".").prefix(2).joined(separator: ".") }

    private func python(in directory: String) -> String { "\"$(cat \(directory)/python)\"" }

    private func isRunningAlready() async -> Bool {
        if connection == nil {
            guard FileManager.default.fileExists(atPath: Self.localRoot + "/" + key + "/python") else { return false }
            return await kernels.runDirectly("\(python(in: directory)) \(scriptPath) alive \(directory)")
        }
        guard let connection, connection.state.isReady else { return false }
        let command = "[ -f \(directory)/python ] && \(python(in: directory)) \(scriptPath) alive \(directory)"
        let result = await Task.detached { connection.run(command, timeout: 15) }.value
        return result?.succeeded == true
    }

    /// Someone may have left one running: a quit, a crash, a dropped connection.
    func adoptIfRunning() {
        guard !isAttached, state == .off || state == .reconnecting else { return }
        Task {
            guard await isRunningAlready() else {
                if state == .reconnecting { state = .off }
                return
            }
            wantsAttachment = true
            attach()
        }
    }

    // MARK: Attached

    private func attach() {
        guard !isAttached else {
            flushWaiting()
            return
        }
        let process = Process()
        let command = "exec \(python(in: directory)) \(scriptPath) attach \(directory)"
        if let connection {
            process.executableURL = URL(fileURLWithPath: connection.sshExecutable)
            process.arguments = connection.commandArguments(script: command)
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        let toProcess = Pipe.notInherited()
        let fromProcess = Pipe.notInherited()
        process.standardInput = toProcess
        process.standardOutput = fromProcess
        process.standardError = FileHandle.nullDevice
        let lines = self.lines
        lines.reset()
        fromProcess.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            for line in lines.add(data) {
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                nonisolated(unsafe) let sent = message
                DispatchQueue.main.async { self?.received(sent) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            fromProcess.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.attachmentEnded(ended) }
        }
        do {
            try process.run()
        } catch {
            state = .off
            return
        }
        self.process = process
        input = toProcess.fileHandleForWriting
        retries = 0
        flushWaiting()
    }

    private func flushWaiting() {
        let messages = waiting
        waiting = []
        for case .object(let message) in messages { sendIfAttached(message) }
    }

    private func attachmentEnded(_ ended: Process) {
        guard process === ended else { return }
        process = nil
        input = nil
        guard wantsAttachment else {
            state = .off
            running = nil
            queued = []
            return
        }
        // Over SSH, this is usually only the connection. The kernel's still working.
        state = .reconnecting
        retries += 1
        tryAgainAfterDrop(in: min(Double(retries) * 2, 15))
    }

    private func tryAgainAfterDrop(in delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsAttachment else { return }
            // However long the connection stays down, there's no giving up on what's still running.
            if self.connection?.state.isReady == false {
                self.tryAgainAfterDrop(in: 5)
            } else {
                self.adoptAfterDrop()
            }
        }
    }

    private func adoptAfterDrop() {
        Task {
            if await isRunningAlready() {
                attach()
            } else {
                wantsAttachment = false
                state = .off
                running = nil
                queued = []
            }
        }
    }

    private func received(_ message: [String: Any]) {
        switch message["ev"] as? String {
        case "status":
            switch message["state"] as? String {
            case "busy": state = .busy
            case "idle": state = .idle
            case "starting": state = .starting
            case "dead", "stopped": state = .stopped
            default: break
            }
            running = (message["running"] as? NSNumber)?.intValue
            queued = (message["queued"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            if let version = message["version"] as? String {
                title = "Python \(Self.shortVersion(version))"
                pythonPath = message["python"] as? String
            }
            kernels.statusChanged(self)
            asked(message["input"] as? [String: Any])
        case "output":
            kernels.output(self, index: (message["index"] as? NSNumber)?.intValue ?? -1,
                           count: (message["count"] as? NSNumber)?.intValue, running: message["running"] as? Bool ?? false,
                           outputs: (message["outputs"] as? [[String: Any]] ?? []).compactMap(Notebook.output))
        case "input":
            asked(message)
        case "problem":
            kernels.tell(path: path, message["message"] as? String ?? String(localized: "The kernel had a problem"), detail: nil)
        default:
            break
        }
    }

    private func asked(_ fields: [String: Any]?) {
        let new = fields.map { Question(prompt: $0["prompt"] as? String ?? "", password: $0["password"] as? Bool ?? false) }
        guard new != question else { return }
        question = new
        kernels.statusChanged(self)
        if new != nil { kernels.questionArrived(self) }
    }
}

/// Every notebook's kernel, whichever tab is showing it, or none.
@MainActor @Observable
final class NotebookKernels {
    struct Python: Sendable, Hashable {
        var path: String
        var version: String
        var kernels: [String: String]
    }

    struct Found: Sendable {
        var usable: [Python] = []
        /// Pythons that could run a kernel once they have what it needs.
        var without: [String] = []
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var all: [String: NotebookKernel] = [:]
    @ObservationIgnored private let viewers = NSHashTable<MarkdownController>.weakObjects()

    init(model: AppModel) { self.model = model }

    func kernel(for path: String) -> NotebookKernel {
        if let existing = all[path] { return existing }
        let kernel = NotebookKernel(path: path, kernels: self)
        all[path] = kernel
        return kernel
    }

    func existing(for path: String) -> NotebookKernel? { all[path] }

    func register(_ viewer: MarkdownController) { viewers.add(viewer) }

    func statusChanged(_ kernel: NotebookKernel) {
        for viewer in viewers.allObjects where viewer.path == kernel.path { viewer.kernelStatusChanged(kernel) }
    }

    func output(_ kernel: NotebookKernel, index: Int, count: Int?, running: Bool, outputs: [Notebook.Output]) {
        for viewer in viewers.allObjects where viewer.path == kernel.path {
            viewer.kernelOutput(index: index, count: count, running: running, outputs: outputs)
        }
    }

    /// A connection's back, so kernels on that server can be picked up again.
    func connectionChanged() {
        for viewer in viewers.allObjects { kernel(for: viewer.path).adoptIfRunning() }
    }

    func stopIfUnused(path: String) {
        guard let kernel = all[path], kernel.hasKernel else { return }
        kernel.stop()
    }

    // MARK: Which Python

    private static let chosenKey = "notebookPythons"

    func rememberedPython(for path: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.chosenKey) as? [String: String])?[path]
    }

    func rememberPython(_ python: String, for path: String) {
        var chosen = UserDefaults.standard.dictionary(forKey: Self.chosenKey) as? [String: String] ?? [:]
        chosen[path] = python
        UserDefaults.standard.set(chosen, forKey: Self.chosenKey)
    }

    /// Closest first: a project's own environment, then what its terminals would get, then the rest.
    private func discovery(folders: [String], script: String) -> String {
        let local = folders.map(shellQuoted).joined(separator: " ")
        return """
        try_python() {
          case "$1" in */*) [ -x "$1" ] || return 0 ;; *) command -v "$1" >/dev/null 2>&1 || return 0 ;; esac
          if out=$("$1" \(script) probe 2>/dev/null); then printf 'TIRI-PYTHON %s\\n' "$out"; else printf 'TIRI-WITHOUT %s\\n' "$(command -v "$1")"; fi
        }
        for d in \(local); do
          try_python "$d/.venv/bin/python"; try_python "$d/venv/bin/python"; try_python "$d/env/bin/python"
        done
        [ -n "$VIRTUAL_ENV" ] && try_python "$VIRTUAL_ENV/bin/python"
        [ -n "$CONDA_PREFIX" ] && try_python "$CONDA_PREFIX/bin/python"
        try_python python3
        try_python python
        for p in "$HOME"/.pyenv/versions/*/bin/python "$HOME"/miniconda3/bin/python "$HOME"/miniconda3/envs/*/bin/python \\
                 "$HOME"/anaconda3/bin/python "$HOME"/anaconda3/envs/*/bin/python \\
                 "$HOME"/miniforge3/bin/python "$HOME"/miniforge3/envs/*/bin/python \\
                 /opt/homebrew/Caskroom/miniconda/base/bin/python /opt/homebrew/Caskroom/miniconda/base/envs/*/bin/python; do
          try_python "$p"
        done
        exit 0
        """
    }

    func pythons(for path: String) async -> Found {
        // From the notebook's folder up to the workspace's.
        let connection = RemoteRegistry.shared.connection(forLocal: path)
        var folders: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        let top = model.active.folders.first { current == $0 || current.hasPrefix($0 + "/") }
        for _ in 0..<8 {
            folders.append(connection?.map.remote(current) ?? current)
            if current == top || current == "/" || current.isEmpty { break }
            current = (current as NSString).deletingLastPathComponent
        }
        let kernel = kernel(for: path)
        let script = kernel.scriptPathForDiscovery
        let result = await runInLoginShell(discovery(folders: folders, script: script), for: path, needsScript: connection != nil)
        var found = Found()
        for line in (result?.outputText ?? "").split(whereSeparator: \.isNewline) {
            if line.hasPrefix("TIRI-WITHOUT ") {
                let name = String(line.dropFirst("TIRI-WITHOUT ".count))
                if !name.isEmpty, !found.without.contains(name) { found.without.append(name) }
            } else if line.hasPrefix("TIRI-PYTHON "),
                      let data = line.dropFirst("TIRI-PYTHON ".count).data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let python = info["python"] as? String, let version = info["version"] as? String {
                guard !found.usable.contains(where: { $0.path == python }) else { continue }
                found.usable.append(Python(path: python, version: version, kernels: info["kernels"] as? [String: String] ?? [:]))
            }
        }
        return found
    }

    func offerInstall(for path: String, found without: [String]) {
        let name = (path as NSString).lastPathComponent
        let preset = model.firstAgentPreset
        let prompt = "Install ipykernel so that Tiri can run \(name). Use this project's virtual environment if it has one, and create one if it doesn't."
        _ = model.showToast(title: String(localized: "No Python here can run this notebook"), detail: String(localized: "It needs a Python with ipykernel installed."),
                            symbol: "exclamationmark.triangle", tint: .orange,
                            actionTitle: preset.map { String(localized: "Ask \($0.name)") }) { [weak model] in
            if let preset { model?.askAgent(preset: preset, prompt: prompt) }
        }
    }

    func chooseKernel(for path: String) {
        Task {
            let found = await pythons(for: path)
            let kernel = kernel(for: path)
            guard !found.usable.isEmpty else {
                offerInstall(for: path, found: found.without)
                return
            }
            let rows = found.usable.map { python in
                PaletteModel.Row(id: python.path, title: "Python \(python.version)", detail: python.path,
                                 symbol: kernel.pythonPath == python.path ? "checkmark" : "chevron.left.forwardslash.chevron.right") { [weak self] _ in
                    self?.model.closePalette()
                    kernel.usePython(python.path)
                }
            }
            model.openPalette(.choices(title: String(localized: "Which Python should run \((path as NSString).lastPathComponent)?"), rows: rows))
        }
    }

    // MARK: Running things

    struct ShellResult: Sendable {
        var succeeded: Bool
        var outputText: String
        var errorText: String
    }

    func runDirectly(_ command: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    /// With the person's own environment, as a terminal has it: their PATH, API keys and conda.
    func runInLoginShell(_ command: String, for path: String, needsScript: Bool) async -> ShellResult? {
        if let connection = RemoteRegistry.shared.connection(forLocal: path) {
            guard connection.state.isReady else { return nil }
            let data = NotebookKernel.scriptData
            let target = kernel(for: path).scriptPathForDiscovery
            let script = "mkdir -p \"$HOME\"/.tiri/bin && if [ ! -f \(target) ]; then cat > \(target).tmp && mv \(target).tmp \(target); else cat >/dev/null; fi; \(command)"
            let result = await Task.detached { connection.run(script, stdin: data, timeout: 120) }.value
            return result.map { ShellResult(succeeded: $0.succeeded, outputText: $0.text, errorText: $0.errorText) }
        }
        let shell = model.settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : model.settings.terminalShell
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { environment[key] = nil }
        environment["TIRI_SCRIPT"] = command
        // Run by sh whatever the login shell is, fish and tcsh included. As long as a server gets, and
        // no longer: shell setup that waits on something, or a kernel left holding its output, can't hang this.
        guard let result = await BoundedRun.run(shell, ["-l", "-i", "-c", "exec /bin/sh -c \"$TIRI_SCRIPT\""], environment: environment, timeout: 120) else {
            return nil
        }
        return ShellResult(succeeded: result.succeeded, outputText: String(decoding: result.output, as: UTF8.self),
                           errorText: result.timedOut ? String(localized: "It took longer than 2 minutes.")
                               : String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Talking to the person

    func tell(path: String, _ message: String, detail: String?) {
        _ = model.showToast(title: message, detail: detail, symbol: "exclamationmark.triangle", tint: .orange)
    }

    /// A cell's waiting for an answer. Its own page asks. If that's not in front, this says so and
    /// leaves you to it: nothing here should get in the way of what you're doing.
    func questionArrived(_ kernel: NotebookKernel) {
        guard model.frontNotebook?.path != kernel.path else { return }
        let name = (kernel.path as NSString).lastPathComponent
        _ = model.showToast(title: String(localized: "\(name) is waiting for input"), detail: kernel.question?.prompt, symbol: "keyboard", tint: .orange,
                            actionTitle: String(localized: "Show")) { [weak model] in
            model?.open(path: kernel.path, intent: .pinned)
            model?.requestFocus()
        }
    }
}

extension NotebookKernel {
    nonisolated static var scriptData: Data {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("remote/tiri-kernel.py") else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    var scriptPathForDiscovery: String { scriptPath }
}

/// What the page gets, to make its cells do things. Scripts in the notebook itself never run: this is
/// in a world of its own, with the page's own scripts off.
enum NotebookPage {
    static let handler = "tiriNotebook"

    /// Tiri's own words in the page, as script strings.
    private static let askingWords = scriptString(String(localized: "This cell is asking for input"))
    private static let sendWord = scriptString(String(localized: "Send"))

    private static func scriptString(_ text: String) -> String {
        String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    }

    static let script = #"""
    (() => {
      if (window.tiriNB) return;
      const post = (message) => webkit.messageHandlers.tiriNotebook.postMessage(message);
      const cellAt = (index) => document.querySelector(`.nb-cell[data-line="${index}"]`);
      const indexOf = (element) => { const cell = element.closest('.nb-cell'); return cell ? parseInt(cell.dataset.line, 10) : null; };
      let current = null;
      let editing = null;
      let saveTimer = null;

      const select = (index) => {
        document.querySelectorAll('.nb-current').forEach((cell) => cell.classList.remove('nb-current'));
        current = cellAt(index) ? index : null;
        if (current !== null) cellAt(current).classList.add('nb-current');
        post({op: 'select', cell: current});
      };

      const nextCode = (index) => {
        let cell = cellAt(index)?.nextElementSibling;
        while (cell && !cell.matches('.nb-cell')) cell = cell.nextElementSibling;
        return cell ? parseInt(cell.dataset.line, 10) : null;
      };

      const fit = (area) => { area.style.height = 'auto'; area.style.height = (area.scrollHeight + 2) + 'px'; };

      const save = () => {
        clearTimeout(saveTimer);
        saveTimer = null;
        if (editing && editing.area.value !== editing.saved) {
          editing.saved = editing.area.value;
          post({op: 'save', cell: editing.index, source: editing.area.value});
        }
      };

      const finish = (then) => {
        if (!editing) return;
        const index = editing.index;
        const cancelled = then === 'cancel';
        if (cancelled) {
          clearTimeout(saveTimer);
          post({op: 'cancelEdit', cell: index, source: editing.original});
        } else {
          save();
          post({op: 'endEdit', cell: index, run: then === 'run'});
        }
        editing = null;
      };

      document.addEventListener('click', (event) => {
        const target = event.target;
        if (target.closest('.nb-ask')) {
          if (target.closest('button')) sendAnswer();
          return;
        }
        if (target.closest('.nb-run')) { post({op: 'run', cell: indexOf(target)}); return; }
        if (target.closest('.nb-add-code')) { post({op: 'add', kind: 'code'}); return; }
        if (target.closest('.nb-add-markdown')) { post({op: 'add', kind: 'markdown'}); return; }
        if (editing && !target.closest('.nb-edit')) finish('end');
        const index = indexOf(target);
        if (index !== null) select(index);
      }, true);

      document.addEventListener('dblclick', (event) => {
        const target = event.target;
        if (target.closest('.nb-edit, .nb-outputs, .nb-run')) return;
        const index = indexOf(target);
        if (index !== null && (target.closest('.nb-input') || target.closest('.nb-markdown'))) post({op: 'edit', cell: index});
      }, true);

      const askBox = () => document.querySelector('.nb-ask');
      const sendAnswer = () => {
        const box = askBox();
        if (!box) return;
        const value = box.querySelector('input').value;
        box.remove();
        post({op: 'answer', value});
      };

      document.addEventListener('keydown', (event) => {
        if (event.target.closest && event.target.closest('.nb-ask')) {
          if (event.key === 'Enter') { event.preventDefault(); sendAnswer(); }
          return;
        }
        if (editing) {
          if (event.key === 'Enter' && event.shiftKey) { event.preventDefault(); finish('run'); }
          else if (event.key === 'Escape') { event.preventDefault(); finish('cancel'); }
          else if (event.key === 'Tab' && !event.metaKey && !event.ctrlKey) {
            event.preventDefault();
            document.execCommand('insertText', false, '    ');
          }
          return;
        }
        if (current === null || event.metaKey || event.ctrlKey || event.altKey) return;
        if (window.getSelection && !window.getSelection().isCollapsed && event.key === 'Enter' && !event.shiftKey) return;
        if (event.key === 'Enter' && event.shiftKey) {
          event.preventDefault();
          const index = current;
          post({op: 'run', cell: index, advance: true});
          const next = nextCode(index);
          if (next !== null) select(next);
        } else if (event.key === 'Enter') {
          event.preventDefault();
          post({op: 'edit', cell: current});
        }
      }, true);

      window.tiriNB = {
        select,
        ask(index, prompt, password) {
          let box = askBox();
          if (box && (box.dataset.cell !== String(index) || box.dataset.prompt !== prompt)) { box.remove(); box = null; }
          if (box) return;
          const cell = cellAt(index);
          if (!cell) return;
          box = document.createElement('div');
          box.className = 'nb-ask';
          box.dataset.cell = String(index);
          box.dataset.prompt = prompt;
          const label = document.createElement('label');
          label.textContent = prompt || \#(NotebookPage.askingWords);
          const field = document.createElement('input');
          field.type = password ? 'password' : 'text';
          field.autocomplete = 'off';
          field.spellcheck = false;
          const send = document.createElement('button');
          send.textContent = \#(NotebookPage.sendWord);
          box.append(label, field, send);
          cell.querySelector('.nb-body').appendChild(box);
          // Only if you're already reading this page. It's never worth taking the keyboard for.
          if (document.hasFocus() && !editing) field.focus();
        },
        answered() { const box = askBox(); if (box) box.remove(); },
        beginEdit(index, source) {
          const cell = cellAt(index);
          if (!cell) return;
          select(index);
          const body = cell.querySelector('.nb-body');
          const shown = cell.dataset.kind === 'code' ? [body.querySelector('.nb-input')] : Array.from(body.children);
          shown.forEach((element) => { if (element) element.style.display = 'none'; });
          const area = document.createElement('textarea');
          area.className = 'nb-edit';
          area.spellcheck = false;
          area.value = source;
          body.insertBefore(area, body.firstChild);
          fit(area);
          area.focus();
          area.addEventListener('input', () => {
            fit(area);
            clearTimeout(saveTimer);
            saveTimer = setTimeout(save, 500);
          });
          editing = {index, area, saved: source, original: source};
        },
        status(running, queued) {
          document.querySelectorAll('.nb-cell.nb-running').forEach((cell) => cell.classList.remove('nb-running'));
          document.querySelectorAll('.nb-count[data-shown]').forEach((count) => {
            count.textContent = count.dataset.shown;
            delete count.dataset.shown;
          });
          const mark = (index, text) => {
            const cell = cellAt(index);
            const count = cell && cell.querySelector('.nb-count');
            if (!count) return;
            count.dataset.shown = count.textContent;
            count.textContent = text;
            cell.classList.add('nb-running');
          };
          queued.forEach((index) => mark(index, '[-]'));
          if (running !== null) mark(running, '[*]');
        },
        outputs(index, html, count) {
          const cell = cellAt(index);
          if (!cell) return;
          const body = cell.querySelector('.nb-body');
          let place = body.querySelector(':scope > .nb-outputs');
          if (html) {
            if (!place) {
              place = document.createElement('div');
              place.className = 'nb-outputs';
              body.appendChild(place);
            }
            place.setHTMLUnsafe(html);
          } else if (place) {
            place.remove();
          }
          if (count !== null) {
            const label = cell.querySelector('.nb-count');
            if (label) {
              label.textContent = `[${count}]`;
              delete label.dataset.shown;
            }
          }
        },
      };
    })();
    0
    """#
}
