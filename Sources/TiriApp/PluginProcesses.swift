import AppKit
import Foundation
import TiriCore

/// A plugin's background programs. Each starts when something asks it, one per place it can run,
/// and stops after a while with nothing to do, as language servers do.
final class PluginProcesses {
    struct Failure: Error, Sendable {
        var message: String
    }

    struct Key: Hashable {
        var plugin: String
        var process: String
        /// Nil is this Mac.
        var destination: String?
    }

    private final class Running {
        let key: Key
        let process: Process
        let input: FileHandle
        var pending: [Int: CheckedContinuation<Result<JSONValue, Failure>, Never>] = [:]
        var nextID = 1
        var lastUsed = Date()
        var idleMinutes: Double
        let writes = DispatchQueue(label: "tiri.plugins.process-input")
        /// The plugin as it was when this started.
        var hash = ""
        /// When it last ended a line on stdout, of any kind.
        var lastHeard = Date.distantPast
        /// Tiri stopped it, so its end isn't a crash.
        var stopping = false
        var reader: PluginOutputReader?

        init(key: Key, process: Process, input: FileHandle, idleMinutes: Double) {
            self.key = key
            self.process = process
            self.input = input
            self.idleMinutes = idleMinutes
        }
    }

    unowned let host: PluginHost
    private var running: [Key: Running] = [:]
    private var idleTimer: Timer?
    /// Ends nobody asked for, for each place it runs.
    var crashes: [Key: PluginCrashRecord] = [:]

    init(host: PluginHost) {
        self.host = host
    }

    var runningCount: Int { running.count }

    // MARK: Asking

    func call(plugin: InstalledPlugin, process id: String, method: String, params: JSONValue, context: PluginContext, timeout: Double = 60, workspace: WorkspaceID? = nil) async -> Result<JSONValue, Failure> {
        let holder: Running
        switch await running(plugin: plugin, process: id, context: context, workspace: workspace) {
        case .success(let found): holder = found
        case .failure(let failure): return .failure(failure)
        }
        holder.lastUsed = Date()
        let sent = Date()
        let requestID = holder.nextID
        holder.nextID += 1
        let line = SettingsSchema.json(.object(["id": .int(requestID), "method": .string(method), "params": params])) + "\n"
        return await withCheckedContinuation { continuation in
            holder.pending[requestID] = continuation
            // On a queue of its own: a program that stops reading fills the pipe, and this would wait forever.
            let input = holder.input
            holder.writes.async {
                do {
                    try input.write(contentsOf: Data(line.utf8))
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let waiting = holder.pending.removeValue(forKey: requestID) else { return }
                            waiting.resume(returning: .failure(Failure(message: "It isn't listening.")))
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let waiting = holder.pending.removeValue(forKey: requestID) else { return }
                waiting.resume(returning: .failure(Failure(message: "\(method) took longer than \(Int(timeout)) seconds.")))
                // Not a word since it was asked: it's stuck, not slow, and the next one would wait as long.
                holder.reader?.flush()
                if holder.lastHeard < sent, !holder.stopping { self?.replaceStuck(holder, method: method, timeout: timeout) }
            }
        }
    }

    private func replaceStuck(_ holder: Running, method: String, timeout: Double) {
        countEnd(of: holder.key, hash: holder.hash, saying: "said nothing for \(Int(timeout)) seconds after being asked \(method), so it was stopped.")
        let waiting = holder.pending
        holder.pending = [:]
        for (_, continuation) in waiting { continuation.resume(returning: .failure(Failure(message: "It stopped answering, so it was stopped. tiri plugin logs \(holder.key.plugin) may say why."))) }
        stop(holder)
    }

    /// The one running for this place, started if it isn't.
    private func running(plugin: InstalledPlugin, process id: String, context: PluginContext, workspace: WorkspaceID?) async -> Result<Running, Failure> {
        guard let declared = plugin.manifest?.processes?.first(where: { $0.id == id }) else {
            return .failure(Failure(message: "\(plugin.name) has no process \(id)."))
        }
        let place = declared.where ?? .workspace
        let destination = place == .workspace ? host.runner.destination(of: workspace) : nil
        let key = Key(plugin: plugin.name, process: id, destination: destination)
        // One that's running was approved when it started, and stops when the plugin changes, so the
        // folder isn't walked again for each call.
        if let existing = running[key], existing.process.isRunning, existing.hash == plugin.hash, host.enabledPlugin(named: plugin.name)?.hash == plugin.hash {
            return .success(existing)
        }
        if let refusal = refusal(key, plugin: plugin) { return .failure(refusal) }
        guard await host.stillApproved(plugin) else { return .failure(Failure(message: "It changed, so it's off until you approve it again.")) }
        if let existing = running[key], existing.process.isRunning { return .success(existing) }
        guard let target = await host.runner.target(plugin: plugin, context: context, place: place, workspace: workspace) else {
            return .failure(Failure(message: "Couldn't reach the server this workspace is on."))
        }
        await host.runner.ensureUserPath()
        // That took a while, and it may have been turned off in the meantime.
        guard host.enabledPlugin(named: plugin.name)?.hash == plugin.hash else {
            return .failure(Failure(message: "\(plugin.title) is off."))
        }
        // Someone else may have started it during that wait.
        if let existing = running[key], existing.process.isRunning { return .success(existing) }
        do {
            return .success(try start(key: key, declared: declared, plugin: plugin, target: target))
        } catch {
            return .failure(Failure(message: "Couldn't start \(declared.exec.first ?? id): \(error.localizedDescription)"))
        }
    }

    /// Something it asked to hear about. No answer is wanted, and it doesn't count as being used, so a
    /// process that's only listening still stops when it's idle, and starts again with the next one.
    func notify(plugin: InstalledPlugin, process id: String, event: String, data: JSONValue, workspace: WorkspaceID? = nil) async {
        let place = plugin.manifest?.processes?.first(where: { $0.id == id })?.where ?? .workspace
        let key = Key(plugin: plugin.name, process: id, destination: place == .workspace ? host.runner.destination(of: workspace) : nil)
        let holder: Running
        // One that's running was approved when it started, and stops when the plugin changes.
        if let existing = running[key], existing.process.isRunning {
            holder = existing
        } else {
            let context = host.runner.context(plugin: plugin, args: [:], workspace: workspace)
            guard case .success(let started) = await running(plugin: plugin, process: id, context: context, workspace: workspace) else { return }
            holder = started
        }
        let line = SettingsSchema.json(.object(["method": .string("event"), "params": .object(["name": .string(event), "data": data])])) + "\n"
        let input = holder.input
        holder.writes.async { try? input.write(contentsOf: Data(line.utf8)) }
    }

    /// Whether it's running for this place right now.
    func isRunning(plugin: String, process id: String, destination: String?) -> Bool {
        running[Key(plugin: plugin, process: id, destination: destination)]?.process.isRunning == true
    }

    private func start(key: Key, declared: PluginManifest.BackgroundProcess, plugin: InstalledPlugin, target: PluginRunner.Target) throws -> Running {
        let process = Process()
        let argv = host.runner.resolve(declared.exec, target: target)
        let environment = host.runner.environment(plugin: plugin, target: target)
        if let connection = target.connection {
            let script = RemoteProgram.script(argv: argv, environment: environment, folder: target.context.folder, connection: connection)
            process.executableURL = URL(fileURLWithPath: connection.sshExecutable)
            process.arguments = connection.commandArguments(script: script)
        } else {
            guard let first = argv.first else { throw Failure(message: "Nothing to run.") }
            process.executableURL = URL(fileURLWithPath: first.hasPrefix("/") ? first : "/usr/bin/env")
            process.arguments = first.hasPrefix("/") ? Array(argv.dropFirst()) : argv
            let folder = target.context.folder ?? plugin.folder.path
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory())
            var values = ProcessInfo.processInfo.environment
            for variable in values.keys where variable.hasPrefix("CLAUDE_CODE") || variable == "TIRI_ITEM_ID" || variable == "TIRI_WORKSPACE" { values[variable] = nil }
            if let path = host.model.userPath { values["PATH"] = path }
            values.merge(environment) { _, new in new }
            process.environment = values
        }
        let input = Pipe.notInherited()
        let output = Pipe.notInherited()
        let errors = Pipe.notInherited()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A program that closes its input shouldn't take the app with it when something's written there.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let holder = Running(key: key, process: process, input: input.fileHandleForWriting, idleMinutes: min(declared.idleMinutes ?? 10, 1440))
        let name = key.plugin
        holder.hash = plugin.hash
        let reader = PluginOutputReader(logName: name) { [weak self, weak holder] batch in
            guard let self, let holder else { return }
            self.received(batch, from: holder)
        }
        holder.reader = reader
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Right here, whatever's become of the rest: at the end of a pipe this fires over and over.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            reader.received(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                PluginProcesses.log(name, String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { [weak self, weak holder] _ in
            // After what it said before it went has been read, so its last answer still counts.
            reader.queue.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let holder else { return }
                        self.ended(holder)
                    }
                }
            }
        }
        try process.run()
        running[key] = holder
        startIdleTimer()
        return holder
    }

    // MARK: Hearing back

    /// Already split and decoded, off this thread.
    private func received(_ batch: PluginOutputReader.Batch, from holder: Running) {
        if let heard = batch.heard { holder.lastHeard = max(holder.lastHeard, heard) }
        for message in batch.answers {
            guard let id = message["id"]?.intValue, let waiting = holder.pending.removeValue(forKey: id) else { continue }
            holder.lastUsed = Date()
            if let failure = message["error"], failure != .null {
                waiting.resume(returning: .failure(Failure(message: failure["message"]?.stringValue ?? failure.stringValue ?? "It failed.")))
            } else {
                waiting.resume(returning: .success(message["result"] ?? .null))
            }
        }
        if batch.askedToRefresh { host.processAskedToRefresh(holder.key.plugin) }
        for event in batch.events {
            _ = host.post(plugin: holder.key.plugin, panel: nil, event: event.name, data: event.data, from: holder.key.destination)
        }
        if batch.lineTooLong, !holder.stopping {
            countEnd(of: holder.key, hash: holder.hash, saying: "printed a line over 8 MB on stdout, so it was stopped.")
            stop(holder)
        }
    }

    private func ended(_ holder: Running) {
        holder.reader?.flush()
        let unasked = !holder.stopping && running[holder.key] === holder
        if running[holder.key] === holder { running[holder.key] = nil }
        for (_, waiting) in holder.pending {
            waiting.resume(returning: .failure(Failure(message: "It stopped before it answered. tiri plugin logs \(holder.key.plugin) may say why.")))
        }
        holder.pending = [:]
        if unasked { countEnd(of: holder.key, hash: holder.hash, saying: Self.ending(of: holder.process) + ".") }
    }

    // MARK: Stopping

    private func stop(_ holder: Running) {
        holder.stopping = true
        if running[holder.key] === holder { running[holder.key] = nil }
        let input = holder.input
        holder.writes.async { try? input.close() }
        // One that ignores being asked goes anyway, and so does what it started, so nothing's left
        // behind on your battery. On a server, its input closing is the signal.
        PluginSignal.stop(holder.process.processIdentifier)
    }

    func stop(plugin name: String) {
        for holder in running.values where holder.key.plugin == name { stop(holder) }
        // Changed, or turned off: either way, a new start when it's next wanted.
        forgetEnds(of: name)
    }

    func stopAll() {
        idleTimer?.invalidate()
        idleTimer = nil
        // Quitting, so there's no later to come back and insist.
        for holder in running.values { holder.stopping = true }
        let ending = running.values.map(\.process) + PluginProgramTable.all()
        for process in ending { PluginSignal.send(SIGTERM, to: process.processIdentifier) }
        running = [:]
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline, ending.contains(where: \.isRunning) { usleep(10_000) }
        for process in ending { PluginSignal.send(SIGKILL, to: process.processIdentifier) }
    }

    private func startIdleTimer() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIdle() }
        }
    }

    private func stopIdle() {
        let now = Date()
        for holder in running.values where holder.pending.isEmpty && now.timeIntervalSince(holder.lastUsed) >= holder.idleMinutes * 60 {
            stop(holder)
        }
        if running.isEmpty {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    // MARK: Logs

    nonisolated static func logFile(_ name: String) -> URL {
        TiriPaths.supportDirectory.appendingPathComponent("plugin-logs/\(name).log")
    }

    /// What it wrote to stderr, for `tiri plugin logs`. Kept short: the newest half when it gets long.
    nonisolated static func log(_ name: String, _ text: String) {
        PluginLogFiles.append(text, to: logFile(name))
    }
}
