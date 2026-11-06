import AppKit
import CryptoKit
import Network
import Observation
import SwiftUI
import TiriCore

/// A port on the server, reachable from this Mac.
struct RemoteForward: Identifiable, Hashable {
    var destination: String
    var remotePort: Int
    var localPort: Int
    var id: String { "\(destination):\(remotePort)" }
}

/// Everything about working on a server that isn't about one connection. The connection itself is
/// `RemoteConnection`, and the model of a remote folder is in `RemotePaths.swift`.
@MainActor
@Observable
final class RemoteManager {
    @ObservationIgnored unowned let model: AppModel
    private(set) var states: [String: RemoteState] = [:]
    /// Bumped when something held back for the connection can go ahead, like a file being fetched.
    private(set) var revision = 0
    private(set) var forwards: [RemoteForward] = []
    private(set) var pendingSaves: [String: Int] = [:]
    /// Which of the user's agents the server's own shell can find.
    private(set) var commandsOnServer: [String: Set<String>] = [:]

    @ObservationIgnored private var connections: [String: RemoteConnection] = [:]
    @ObservationIgnored private var bridgePorts: [String: Int] = [:]
    @ObservationIgnored private var pendingEnds: [String: [ItemID]] = [:]
    @ObservationIgnored private var waitingForReady: [String: [(Result<RemoteConnection, RemoteFailure>) -> Void]] = [:]
    @ObservationIgnored private var fetchFailures: [String: String] = [:]
    @ObservationIgnored private let openFiles = OpenFilesBox()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var folderCache: [String: [String]] = [:]

    private nonisolated final class OpenFilesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Set<String> = []
        var value: Set<String> {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    init(model: AppModel) {
        self.model = model
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryAllNow() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tryAllNow() } }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func tryAllNow() {
        for connection in connections.values { connection.tryNow() }
    }

    /// Separate for each Tiri on each Mac, and for each name a server goes by, so none of them
    /// ever takes for its own, or ends, what belongs to another on the same machine.
    private func tag(for destination: String) -> String {
        let identity = TiriPaths.supportDirectory.path + "@" + (Host.current().localizedName ?? "") + "@" + destination
        return SHA256.hash(data: Data(identity.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Connections

    func connection(_ destination: String) -> RemoteConnection {
        if let existing = connections[destination] { return existing }
        TerminalSessions.prepareDirectory()
        let resources = Bundle.main.resourceURL?.appendingPathComponent("remote").path ?? ""
        let connection = RemoteConnection(destination: destination, controlPath: controlPath(for: destination),
                                          helperDirectory: resources, askpass: resources + "/tiri-askpass", controlSocket: TiriPaths.socket, machineTag: tag(for: destination))
        connection.onRelayRequest = { body in
            guard let request = try? JSONDecoder().decode(RemoteRelayMessage.Request.self, from: body) else {
                return RemoteRelayMessage.Reply(code: 2, errors: "tiri: that wasn't understood.\n").encoded
            }
            return await RemoteRelay.handle(request, from: destination).encoded
        }
        connection.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(destination, state) }
        }
        connection.onRepositoryMoved = { [weak self] in
            MainActor.assumeIsolated { self?.model.remoteRepositoryMoved(destination) }
        }
        connection.onPendingSaves = { [weak self] count in
            MainActor.assumeIsolated { self?.pendingSaves[destination] = count }
        }
        connection.onSaveConflict = { [weak self] local in
            MainActor.assumeIsolated { self?.askAboutConflict(local, on: connection) }
        }
        connection.onCaseCollision = { [weak self] name, holder in
            MainActor.assumeIsolated { self?.noteCaseCollision(name, holder: holder, on: destination) }
        }
        let box = openFiles
        connection.openFiles = { box.value }
        connection.onReady = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setUpAfterConnecting(destination) } }
        }
        connections[destination] = connection
        RemoteRegistry.shared.register(connection)
        return connection
    }

    func existingConnection(_ destination: String) -> RemoteConnection? { connections[destination] }

    private func controlPath(for destination: String) -> String {
        let hash = SHA256.hash(data: Data(destination.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        return TerminalSessions.directory + "/s-" + hash
    }

    func state(of destination: String) -> RemoteState { states[destination] ?? .idle }

    func connect(_ destination: String, quiet: Bool = false) {
        let connection = connection(destination)
        syncRoots(destination)
        connection.connect(quiet: quiet)
    }

    /// At launch: each server is known, so its paths are, and the ones not in front try quietly.
    /// An agent on one of them may have something to say, but it's no reason to ask for a password.
    func startUp() {
        let hosts = Set(model.workspaces.compactMap(\.remote))
        for destination in hosts { _ = connection(destination) }
        let directory = TerminalSessions.directory
        let keeping = Set(hosts.map { (controlPath(for: $0) as NSString).lastPathComponent })
        DispatchQueue.global(qos: .utility).async { RemoteConnection.endLeftovers(in: directory, keeping: keeping) }
        for destination in hosts where destination != model.active.remote { connect(destination, quiet: true) }
    }

    // MARK: Sharing out connections

    @ObservationIgnored private var terminalSlots: [String: [ItemID: Int]] = [:]
    /// Connected, with the tunnels a terminal's `tiri` and editor protocol rely on already in place.
    @ObservationIgnored private var setUpHosts: Set<String> = []

    func isSetUp(_ destination: String) -> Bool { setUpHosts.contains(destination) }

    /// Which connection a terminal goes over. See RemoteConnection.ensureTerminalConnection.
    func terminalSlot(_ item: ItemID, on destination: String) -> Int {
        if let known = terminalSlots[destination]?[item] { return known }
        let used = terminalSlots[destination] ?? [:]
        var slot = 0
        while used.values.filter({ $0 == slot }).count >= (slot == 0 ? RemoteConnection.terminalsOnMainConnection : RemoteConnection.terminalsPerExtraConnection) { slot += 1 }
        terminalSlots[destination, default: [:]][item] = slot
        return slot
    }

    /// The server wouldn't open another session on that connection, whatever its limit is.
    func moveToNextSlot(_ item: ItemID, on destination: String) {
        let current = terminalSlots[destination]?[item] ?? 0
        terminalSlots[destination, default: [:]][item] = min(current + 1, 8)
    }

    func releaseTerminalSlot(_ item: ItemID, on destination: String) {
        terminalSlots[destination]?[item] = nil
    }

    /// Everything the workspaces hold on this server, and nothing else.
    func syncRoots(_ destination: String) {
        guard let connection = connections[destination] else { return }
        let folders = model.workspaces.filter { $0.remote == destination }.flatMap(\.folders).compactMap { connection.map.remote($0) }
        connection.setRoots(folders, excludes: model.settings.filesExclude)
    }

    func syncAllRoots() {
        for destination in connections.keys { syncRoots(destination) }
    }

    /// Open files stay current. Everything else can wait until someone opens it.
    func syncOpenFiles() {
        var open = Set<String>()
        for workspace in model.workspaces where workspace.remote != nil {
            open.formUnion(workspace.items.compactMap(\.filePath))
            if let path = workspace.peek?.filePath { open.insert(path) }
        }
        openFiles.value = open
    }

    private func stateChanged(_ destination: String, _ state: RemoteState) {
        states[destination] = state
        // Up isn't the same as ready for a terminal. See setUpAfterConnecting.
        if state != .ready {
            setUpHosts.remove(destination)
            for terminal in model.terminalControllers where terminal.remoteDestination == destination {
                terminal.remoteStateChanged(state)
            }
        }
        switch state {
        case .ready:
            let waiting = waitingForReady.removeValue(forKey: destination) ?? []
            if let connection = connections[destination] { waiting.forEach { $0(.success(connection)) } }
            revision += 1
            model.refreshChangesIfOn(destination)
            for live in model.lives.values { live.fileTree.reload() }
            fetchFailures = [:]
            // Anything left waiting to be fetched can go now.
            for controller in model.allControllers where controller is RemoteFileController {
                (controller as? RemoteFileController)?.connectionChanged()
            }
        case .failed(let message):
            let waiting = waitingForReady.removeValue(forKey: destination) ?? []
            waiting.forEach { $0(.failure(RemoteFailure(message))) }
        default:
            break
        }
    }

    /// Runs when it's up, connecting first if need be.
    func whenReady(_ destination: String, _ then: @escaping (Result<RemoteConnection, RemoteFailure>) -> Void) {
        let connection = connection(destination)
        if connection.state.isReady {
            then(.success(connection))
            return
        }
        waitingForReady[destination, default: []].append(then)
        connect(destination)
    }

    /// Forwards don't survive a reconnection, and neither does anything that leans on them.
    private func setUpAfterConnecting(_ destination: String) {
        guard let connection = connections[destination] else { return }
        syncRoots(destination)
        let wanted = forwards.filter { $0.destination == destination }
        let ends = pendingEnds.removeValue(forKey: destination) ?? []
        let tag = tag(for: destination)
        let bridge = model.editorBridge.listener(for: destination)
        let previousPort = bridgePorts[destination]
        let lock = bridgeLock(for: connection, token: bridge?.token)
        let names = model.settings.terminalPresets.compactMap { $0.command.split(separator: " ").first.map(String.init) }.filter(ShellLookup.isPlainName)
        Task.detached(priority: .userInitiated) { [weak self] in
            for forward in wanted { _ = connection.forwardToServer(remotePort: forward.remotePort, preferredLocalPort: forward.localPort) }
            var remoteBridge: Int?
            if let bridge {
                remoteBridge = connection.forwardToMac(localPort: Int(bridge.port), preferredRemotePort: previousPort)
                if let remoteBridge, let lock { RemoteManager.writeBridgeLock(lock, port: remoteBridge, tag: tag, connection: connection) }
            }
            if let run = connection.runDirectory, let bin = connection.binDirectory {
                for item in ends {
                    _ = connection.run("\(ShellQuote.quote(bin + "/tiri-remote")) session kill \(ShellQuote.quote(run + "/" + tag + "-" + item + ".sock"))", timeout: 10)
                }
                // A tab closed while this Mac wasn't here. Other Macs' terminals have another tag.
                if let listing = connection.run("cd \(ShellQuote.quote(run)) && for f in \(tag)-i-*.sock; do printf '%s\\n' \"$f\"; done", timeout: 10) {
                    // Asked now, not earlier: a workspace may have appeared since connecting.
                    let keep = await MainActor.run { () -> Set<ItemID> in
                        guard let self else { return [] }
                        return Set(self.model.workspaces.filter { $0.remote == destination }.flatMap { $0.items.map(\.id) })
                    }
                    for line in listing.text.split(whereSeparator: \.isNewline)
                    where line.hasPrefix(tag + "-i-") && line.hasSuffix(".sock") {
                        let item = String(line.dropFirst(tag.count + 1).dropLast(5))
                        if self != nil, !keep.contains(item) {
                            _ = connection.run("\(ShellQuote.quote(bin + "/tiri-remote")) session kill \(ShellQuote.quote(run + "/" + line))", timeout: 10)
                        }
                    }
                }
            }
            await MainActor.run {
                guard let self, connection.state.isReady else { return }
                self.bridgePorts[destination] = remoteBridge
                self.setUpHosts.insert(destination)
                for terminal in self.model.terminalControllers where terminal.remoteDestination == destination {
                    terminal.remoteStateChanged(.ready)
                }
            }
            let found = await RemoteManager.lookUp(names: names, on: connection)
            await MainActor.run {
                if let found { self?.commandsOnServer[destination] = found }
            }
        }
    }

    private nonisolated static func lookUp(names: [String], on connection: RemoteConnection) async -> Set<String>? {
        guard !names.isEmpty, !connection.isCShell else { return nil }
        let script = "\(ShellQuote.quote(connection.shell)) -l -i -c \(ShellQuote.quote(ShellLookup.script(for: names))) 2>/dev/null"
        guard let result = connection.run(script, timeout: 15) else { return nil }
        return ShellLookup.found(in: result.text)
    }

    /// What Claude Code needs to find Tiri from the server: the same lock file VS Code's server writes there.
    private struct BridgeLock: Sendable {
        var folders: [String]
        var token: String
    }

    private func bridgeLock(for connection: RemoteConnection, token: String?) -> BridgeLock? {
        guard let token else { return nil }
        let folders = model.workspaces.filter { $0.remote == connection.destination }.flatMap(\.folders).compactMap { connection.map.remote($0) }
        return BridgeLock(folders: Array(Set(folders)).sorted(), token: token)
    }

    /// The process it names has to exist there, or Claude Code treats the lock as left over. So it
    /// names one that lives as long as this connection. Last time's lock goes, so they don't pile up.
    private nonisolated static func writeBridgeLock(_ lock: BridgeLock, port: Int, tag: String, connection: RemoteConnection) {
        guard let pid = connection.waitForRelay().flatMap(Int32.init(exactly:)), let run = connection.runDirectory else { return }
        let data = EditorProtocol.lockFile(pid: pid, folders: lock.folders, token: lock.token)
        let note = ShellQuote.quote(run + "/bridge-" + tag)
        let script = """
        [ -r \(note) ] && rm -f "$HOME/.claude/ide/$(cat \(note)).lock"
        printf %s \(port) > \(note)
        mkdir -p "$HOME/.claude/ide" && chmod 700 "$HOME/.claude/ide"
        cat > "$HOME/.claude/ide/\(port).lock" && chmod 600 "$HOME/.claude/ide/\(port).lock"
        """
        _ = connection.run(script, stdin: data, timeout: 15)
    }

    /// The server keeps running what it's running. This Mac lets go of everything else.
    func prepareForQuit() {
        let group = DispatchGroup()
        for (destination, connection) in connections {
            let port = bridgePorts[destination]
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let port, connection.state.isReady { _ = connection.run("rm -f \"$HOME/.claude/ide/\(port).lock\"", timeout: 2) }
                connection.endForQuit()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
    }

    func bridgePort(for destination: String) -> Int? { bridgePorts[destination] }

    // MARK: Terminals

    func sessionSocket(_ item: ItemID, on connection: RemoteConnection) -> String? {
        connection.runDirectory.map { $0 + "/" + tag(for: connection.destination) + "-" + item + ".sock" }
    }

    /// What runs on the server for a terminal. `attachOnly` comes back to what's there and starts
    /// nothing new, so a program that ended while the connection was down is reported as ended.
    func terminalScript(connection: RemoteConnection, itemID: ItemID, workspaceID: WorkspaceID, command: String?, cwd: String, attachOnly: Bool) -> String {
        let remoteCwd = connection.map.remote(cwd) ?? connection.home ?? "/"
        let shell = connection.shell
        let name = (shell as NSString).lastPathComponent
        var lines = [#"[ -n "$LANG$LC_ALL$LC_CTYPE" ] || export LC_CTYPE=C.UTF-8"#]
        var environment: [(String, String)] = [
            ("COLORTERM", "truecolor"), ("TERM_PROGRAM", "Tiri"), ("TERM_PROGRAM_VERSION", TiriCoreVersion.string),
            ("TIRI_WORKSPACE", workspaceID), ("TIRI_ITEM_ID", itemID),
        ]
        if let socket = connection.relaySocket { environment.append(("TIRI_SOCKET", socket)) }
        if let port = bridgePorts[connection.destination] {
            environment.append(("CLAUDE_CODE_SSE_PORT", String(port)))
            environment.append(("ENABLE_IDE_INTEGRATION", "true"))
        }
        for (key, value) in environment { lines.append("export \(key)=\(ShellQuote.quote(value))") }
        if let bin = connection.binDirectory {
            lines.append("export PATH=\(ShellQuote.quote(bin)):\"$PATH\"")
            // A Mac can be a server too, and its own shell setup may put its own `tiri` first.
            lines.append("export TIRI_SERVER_HELPER=\(ShellQuote.quote(bin + "/tiri"))")
        }
        // A program outlives the connection that brought your SSH agent, so `git push` would find it
        // gone. So it's given a link that never moves, pointed at the live one on each connection.
        if let run = connection.runDirectory {
            let link = ShellQuote.quote(run + "/" + tag(for: connection.destination) + "-agent.sock")
            lines.append("if [ -n \"$SSH_AUTH_SOCK\" ]; then ln -sf \"$SSH_AUTH_SOCK\" \(link) && export SSH_AUTH_SOCK=\(link); fi")
        }
        var program: [String]
        var execName: String
        let trimmed = command?.trimmingCharacters(in: .whitespaces) ?? ""
        // A login shell's setup can set PATH from scratch, as Alpine's does, and `tiri` has to survive
        // it. So it goes on once that setup has run. Shells that don't speak this start plainly.
        let speaksExport = ["bash", "zsh", "sh", "ash", "dash", "ksh", "fish"].contains(name)
        let addPath = connection.binDirectory.flatMap { speaksExport ? "export PATH=\(ShellQuote.quote($0)):\"$PATH\"" : nil }
        if trimmed.isEmpty {
            if let addPath {
                program = [shell, "-l", "-c", "\(addPath); exec \(ShellQuote.quote(shell)) -i"]
                execName = name
            } else {
                // The leading dash is what says login shell, which every shell understands.
                program = [shell]
                execName = "-" + name
            }
        } else if connection.isCShell {
            program = [shell, "-c", trimmed]
            execName = name
        } else {
            program = [shell, "-l", "-i", "-c", (addPath.map { $0 + "; " } ?? "") + trimmed]
            execName = name
        }
        if let bin = connection.binDirectory, let socket = sessionSocket(itemID, on: connection) {
            let helper = ShellQuote.quote(bin + "/tiri-remote")
            if attachOnly {
                lines.append("exec \(helper) session attach \(ShellQuote.quote(socket)) --report \(reportTag(for: itemID))")
            } else {
                lines.append("exec \(helper) session attach \(ShellQuote.quote(socket)) --report \(reportTag(for: itemID)) --cwd \(ShellQuote.quote(remoteCwd)) --argv0 \(ShellQuote.quote(execName)) -- \(RemoteShell.arguments(program))")
            }
        } else {
            // A kind of machine the helper doesn't run on: a plain session, which ends with its connection.
            lines.append("cd \(ShellQuote.quote(remoteCwd)) 2>/dev/null")
            lines.append("exec \(RemoteShell.arguments(program))")
        }
        return lines.joined(separator: "\n")
    }

    /// What says a report on a terminal's state really is from its session, not something printed by
    /// a program or a file being read. Fixed for each terminal, since it's given when the session starts.
    func reportTag(for item: ItemID) -> String {
        SHA256.hash(data: Data((model.editorBridge.token + item).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func terminalLaunch(connection: RemoteConnection, script: String, slot: Int) -> TerminalLaunch {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        for key in ["TIRI_ITEM_ID", "TIRI_WORKSPACE"] { environment[key] = nil }
        return TerminalLaunch(executable: connection.sshExecutable, args: connection.terminalArguments(script: script, slot: slot), execName: "ssh",
                              environment: environment.map { "\($0.key)=\($0.value)" }, cwd: NSHomeDirectory())
    }

    /// A tab was closed on purpose. If the server can't be told now, it's told when it's back.
    func endSession(_ item: ItemID, on destination: String) {
        releaseTerminalSlot(item, on: destination)
        guard let connection = connections[destination], connection.state.isReady,
              let bin = connection.binDirectory, let socket = sessionSocket(item, on: connection) else {
            pendingEnds[destination, default: []].append(item)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            _ = connection.run("\(ShellQuote.quote(bin + "/tiri-remote")) session kill \(ShellQuote.quote(socket))", timeout: 15)
        }
    }

    func sessionIsAlive(_ item: ItemID, on connection: RemoteConnection) async -> Bool {
        guard let bin = connection.binDirectory, let socket = sessionSocket(item, on: connection) else { return false }
        return await Task.detached {
            connection.run("\(ShellQuote.quote(bin + "/tiri-remote")) session alive \(ShellQuote.quote(socket))", timeout: 15)?.status == 0
        }.value
    }

    /// Files for a terminal on a server: what's on that server is named as it is there, and what's
    /// only on this Mac, like a pasted picture, is sent over first.
    func serverPaths(for paths: [String], on destination: String, then done: @escaping ([String]) -> Void) {
        guard let connection = connections[destination] else {
            done(paths)
            return
        }
        let locals = paths.filter { connection.map.remote($0) == nil }
        guard !locals.isEmpty, let bin = connection.binDirectory else {
            done(paths.map { connection.map.remote($0) ?? $0 })
            return
        }
        let host = SSHConfigFile.displayName(of: destination)
        let sending = locals.count == 1 ? String(localized: "Sending \((locals[0] as NSString).lastPathComponent) to \(host)") : String(localized: "Sending \(locals.count) files to \(host)")
        model.showToast(title: sending, detail: nil, symbol: "arrow.up.circle", tint: .secondary)
        Task { [weak self] in
            let (mapped, failed) = await Task.detached(priority: .userInitiated) { () -> ([String], String?) in
                let base = (bin as NSString).deletingLastPathComponent + "/tmp"
                // A week is plenty for anything an agent was shown.
                _ = connection.run("find \(ShellQuote.quote(base)) -mindepth 1 -mtime +7 -delete 2>/dev/null; true", timeout: 15)
                var mapped: [String] = []
                var failed: String?
                for path in paths {
                    if let remote = connection.map.remote(path) {
                        mapped.append(remote)
                        continue
                    }
                    let folder = base + "/" + UUID().uuidString.prefix(8)
                    let target = folder + "/" + (path as NSString).lastPathComponent
                    guard let data = FileManager.default.contents(atPath: path),
                          connection.run("mkdir -p \(ShellQuote.quote(folder)) && cat > \(ShellQuote.quote(target))", stdin: data, timeout: 600)?.succeeded == true else {
                        failed = (path as NSString).lastPathComponent
                        continue
                    }
                    mapped.append(target)
                }
                return (mapped, failed)
            }.value
            if let failed {
                self?.model.showToast(title: String(localized: "Couldn't send \(failed) to the server"), detail: String(localized: "A folder or something unreadable, or the connection dropped."),
                                      symbol: "exclamationmark.triangle", tint: .orange)
            }
            done(mapped)
        }
    }

    // MARK: Ports

    /// A page served on the server opens here through a forwarded port. Same number when it's free.
    func forward(remotePort: Int, on destination: String) async -> Int? {
        if let known = forwards.first(where: { $0.destination == destination && $0.remotePort == remotePort }) { return known.localPort }
        guard let connection = connections[destination], connection.state.isReady else { return nil }
        let local = await Task.detached { connection.forwardToServer(remotePort: remotePort) }.value
        if let local { forwards.append(RemoteForward(destination: destination, remotePort: remotePort, localPort: local)) }
        return local
    }

    func cancelForward(_ forward: RemoteForward) {
        forwards.removeAll { $0 == forward }
        guard let connection = connections[forward.destination] else { return }
        DispatchQueue.global(qos: .utility).async { connection.cancelForward(localPort: forward.localPort, remotePort: forward.remotePort) }
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" || host == "[::1]"
    }

    /// The address to open here for one printed on a server.
    func localURL(for url: URL, on destination: String) async -> URL? {
        guard Self.isLoopback(url) else { return url }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let local = await forward(remotePort: port, on: destination), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // A forward can always be asked for. Only connecting says whether anything's at the other end.
        let answers = await Task.detached(priority: .userInitiated) { RemoteConnection.portAnswers(local) }.value
        if !answers {
            model.showToast(title: String(localized: "Nothing answered on port \(port)"), detail: String(localized: "It may not be running yet, or \(SSHConfigFile.displayName(of: destination)) may not allow forwarding."),
                            symbol: "exclamationmark.triangle", tint: .orange)
        }
        parts.host = "localhost"
        parts.port = local
        if local != port {
            model.showToast(title: String(localized: "Port \(port) on the server is localhost:\(local) here"), detail: nil, symbol: "arrow.left.arrow.right", tint: .secondary)
        }
        return parts.url
    }

    // MARK: Files

    /// A file was saved here. Now it has to reach the server, and if it can't yet, it says so.
    func didSave(_ path: String) {
        guard let connection = RemoteRegistry.shared.connection(forLocal: path) else { return }
        if (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int == 0 { connection.didSaveEmpty(path) }
        let name = (path as NSString).lastPathComponent
        connection.push(path) { [weak self] result in
            MainActor.assumeIsolated {
                guard case .failure(let failure) = result else { return }
                let destination = SSHConfigFile.displayName(of: connection.destination)
                if connection.state.isReady {
                    self?.model.showToast(title: String(localized: "Couldn't save \(name) on \(destination)"), detail: String(localized: "\(failure.description) Your edit is safe here."),
                                          symbol: "exclamationmark.triangle", tint: .orange)
                } else {
                    self?.model.showToast(title: String(localized: "\(name) will save when \(destination) is back"), detail: String(localized: "Your edit is safe here."),
                                          symbol: "clock.arrow.circlepath", tint: .secondary)
                }
            }
        }
    }

    /// While a save waited for the connection, an agent changed the same file. Neither is lost
    /// until someone chooses: yours stays here, and theirs stays there.
    private func askAboutConflict(_ local: String, on connection: RemoteConnection) {
        let name = (local as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "\(name) changed on \(SSHConfigFile.displayName(of: connection.destination)) while your save was waiting")
        alert.informativeText = String(localized: "Keep yours, which replaces what's there now, or keep theirs, which throws away your edit.")
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: String(localized: "Keep Theirs"))
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { connection.keepMine(local) } else { connection.keepTheirs(local) }
        }
        if let window = model.window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { decide(response) } }
        } else {
            decide(alert.runModal())
        }
    }

    /// This Mac's disk can't hold names that differ only by case, and a server's can. Said once.
    private func noteCaseCollision(_ name: String, holder: String, on destination: String) {
        let key = "saidCaseCollision.\(destination)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        model.showToast(title: String(localized: "Some files on \(SSHConfigFile.displayName(of: destination)) differ only by case"), detail: String(localized: "This Mac can only show one of each, like \((holder as NSString).lastPathComponent). The terminal sees them all."),
                        symbol: "textformat.size", tint: .secondary)
    }

    func needsFetch(_ path: String) -> Bool {
        RemoteRegistry.shared.connection(forLocal: path)?.needsFetch(path) ?? false
    }

    /// An HTML page wants what's beside it: its styles, scripts and pictures.
    func fetchAround(_ path: String) {
        guard let connection = RemoteRegistry.shared.connection(forLocal: path) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        Task.detached(priority: .utility) {
            var count = 0
            guard let walker = FileManager.default.enumerator(atPath: directory) else { return }
            while let name = walker.nextObject() as? String, count < 300 {
                let local = directory + "/" + name
                if let record = connection.record(forLocal: local), record.size > 0, record.size < 8_000_000, connection.needsFetch(local) {
                    count += 1
                    connection.fetch(local) { _ in }
                }
            }
        }
    }

    func fetchFailure(_ path: String) -> String? { fetchFailures[path] }

    func fetch(_ path: String) {
        guard let connection = RemoteRegistry.shared.connection(forLocal: path) else { return }
        fetchFailures[path] = nil
        connection.fetch(path) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failure(let failure) = result { self.fetchFailures[path] = failure.description }
                self.fileArrived(path)
            }
        }
    }

    /// The real viewer can be made now. Anything showing "loading" for this file gets replaced.
    private func fileArrived(_ path: String) {
        for workspace in model.workspaces {
            for item in workspace.items + (workspace.peek.map { [$0] } ?? []) where item.filePath == path {
                if let loading = model.existingController(for: item.id) as? RemoteFileController {
                    if fetchFailures[path] != nil {
                        loading.showFailure(fetchFailures[path] ?? "")
                    } else {
                        model.discardController(item.id)
                    }
                }
            }
        }
        revision += 1
    }

    /// Runs off the main thread: it's over the network. The tree refreshes from what the server says.
    func perform(_ script: String, affecting remotes: [String], on connection: RemoteConnection, failure: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = connection.perform(script, affecting: remotes)
            await MainActor.run {
                guard let self else { return }
                if case .failure(let problem) = result {
                    self.model.showToast(title: failure, detail: problem.description, symbol: "exclamationmark.triangle", tint: .orange)
                }
                for live in self.model.lives.values { live.fileTree.reload() }
            }
        }
    }

    // MARK: Remembering where you've been

    fileprivate func cachedFolders(_ directory: String) -> [String]? { folderCache[directory] }
    fileprivate func cacheFolders(_ directory: String, _ list: [String]) { folderCache[directory] = list }

    private var recentsFile: URL { TiriPaths.supportDirectory.appendingPathComponent("remote-hosts.json") }

    struct Recents: Codable {
        var hosts: [String] = []
        var folders: [String: [String]] = [:]
        /// Remembered so a path reads the same before the server has answered.
        var homes: [String: String] = [:]
    }

    func recents() -> Recents {
        guard let data = try? Data(contentsOf: recentsFile), let decoded = try? JSONDecoder().decode(Recents.self, from: data) else { return Recents() }
        return decoded
    }

    func remember(destination: String, folder: String?) {
        var stored = recents()
        stored.hosts.removeAll { $0 == destination }
        stored.hosts.insert(destination, at: 0)
        if let folder {
            var list = stored.folders[destination] ?? []
            list.removeAll { $0 == folder }
            list.insert(folder, at: 0)
            stored.folders[destination] = Array(list.prefix(8))
        }
        stored.hosts = Array(stored.hosts.prefix(20))
        if let home = connections[destination]?.home { stored.homes[destination] = home }
        if let data = try? JSONEncoder().encode(stored) {
            try? FileManager.default.createDirectory(at: recentsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: recentsFile, options: .atomic)
        }
    }

    // MARK: Agents' hooks on the server

    /// Same offer as on this Mac, about the agent's config on the server, once per server.
    func offerHooksIfNeeded(_ tool: AgentHooks.Tool, on destination: String) {
        let key = "offeredHooks.\(tool.rawValue).\(destination)"
        guard tool.profile?.hookInstall != nil, model.isAgentEnabled(tool), !UserDefaults.standard.bool(forKey: key),
              !model.hooksOfferedThisLaunch.contains(key),
              let connection = connections[destination], connection.state.isReady, let path = hookConfigPath(tool) else { return }
        model.hooksOfferedThisLaunch.insert(key)
        let answered = { UserDefaults.standard.set(true, forKey: key) }
        Task { [weak self] in
            // Couldn't ask isn't the same as isn't there. Nothing's offered on a guess.
            let text = await Task.detached(priority: .utility) { RemoteManager.readConfig(path, on: connection) }.value
            guard let self, let text, !AgentHooks.isInstalled(tool, in: text) else { return }
            let name = SSHConfigFile.displayName(of: destination)
            self.model.showToast(title: String(localized: "Get exact status from \(tool.title)?"), detail: String(localized: "On \(name), Tiri is estimating when it's working or done."),
                                 symbol: "waveform.path.ecg", tint: .accentColor, actionTitle: String(localized: "Set Up"), duration: nil,
                                 other: (String(localized: "Not Now"), answered), closed: answered) { [weak self] in
                answered()
                self?.confirmHooks(tool, on: destination)
            }
        }
    }

    /// The file's text, empty if it isn't there, or nil if it couldn't be read.
    private nonisolated static func readConfig(_ path: String, on connection: RemoteConnection) -> String? {
        let quoted = "\"$HOME\"/" + ShellQuote.quote(path)
        guard let result = connection.run("[ -e \(quoted) ] || exit 0; cat \(quoted)", timeout: 15), result.succeeded else { return nil }
        return result.text
    }

    private func hookConfigPath(_ tool: AgentHooks.Tool) -> String? {
        guard let profile = tool.profile, let install = profile.hookInstall else { return nil }
        switch install {
        case .jsonSettings(let file), .tomlSection(let file), .ownFile(let file):
            return profile.configDirectory + "/" + file
        }
    }

    func confirmHooks(_ tool: AgentHooks.Tool, on destination: String) {
        guard let window = model.window, let path = hookConfigPath(tool), let connection = connections[destination] else { return }
        let name = SSHConfigFile.displayName(of: destination)
        let alert = NSAlert()
        alert.messageText = String(localized: "Tell Tiri exactly what \(tool.title) is doing on \(name)?")
        alert.informativeText = String(localized: "Tiri adds a small hook to ~/\(path) on \(name), and keeps a copy of the file next to it. The hook does nothing outside Tiri.") + "\n\n" + AgentHooks.summary(of: tool)
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.installHooks(tool, path: path, on: connection)
            }
        }
    }

    private func installHooks(_ tool: AgentHooks.Tool, path: String, on connection: RemoteConnection) {
        Task { [weak self] in
            let problem: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                // A failed read must never look like an empty file, or their settings would be replaced.
                guard let existing = RemoteManager.readConfig(path, on: connection) else { return String(localized: "Couldn't read \(path) on the server.") }
                do {
                    let updated = try AgentHooks.installing(tool, in: existing)
                    // Through a link to its file, with that file's mode, and never readable by others.
                    let script = SafeFile.remoteReplaceScript(homeRelativePath: path)
                    guard connection.run(script, stdin: Data(updated.utf8), timeout: 15)?.succeeded == true else { return String(localized: "The server wouldn't take the change.") }
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            if let problem {
                self?.model.showToast(title: String(localized: "Couldn't change \(tool.title)'s config"), detail: problem, symbol: "exclamationmark.triangle", tint: .orange)
            } else {
                self?.model.showToast(title: String(localized: "\(tool.title) hooks are on"), detail: String(localized: "New \(tool.title) sessions on this server report their status exactly."),
                                      symbol: "checkmark.circle.fill", tint: .green)
            }
        }
    }

    // MARK: Ending

    /// No workspace needs this server any more.
    func forget(_ destination: String) {
        guard !model.workspaces.contains(where: { $0.remote == destination }) else { return }
        let connection = connections.removeValue(forKey: destination)
        connection?.disconnect()
        RemoteRegistry.shared.unregister(destination)
        forwards.removeAll { $0.destination == destination }
        states[destination] = nil
        bridgePorts[destination] = nil
        // What was fetched goes with it, unless it holds an edit that hasn't got there yet.
        if connection?.hasPendingSaves != true {
            let root = RemoteMirror.localRoot(of: destination)
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(atPath: root) }
        }
    }
}

// MARK: - What a server may ask of this Mac

/// A server is less trusted than this Mac: someone else may run it, or be on it. So a `tiri` in a
/// server's terminal only reaches that server's own workspaces. It can't see or type into terminals
/// on this Mac or another server, change settings or hooks here, or quit the app.
enum RemoteRelay {
    private static let allowed: Set<String> = [
        "ping", "items", "open", "reveal", "preview", "term", "focus", "close", "notify", "send", "read", "follow", "select",
        "layout", "tree", "changes", "changes.branch", "changes.commit", "log", "diff", "turns", "git", "search", "diagnostics", "languages",
        "review.list", "review.add", "review.remove", "review.clear", "review.send", "remote.forward", "remote.ports", "worktree.add",
        "work", "conversations", "web.console", "web.network", "web.shot", "web.text", "web.click", "web.type", "web.eval", "notebook.status", "notebook.run", "notebook.interrupt", "notebook.restart", "notebook.stop", "notebook.input",
    ]
    /// These answer about the workspace in front, so that has to be this server's.
    private static let aboutFront: Set<String> = ["work", "conversations", "web.console", "web.network", "web.shot", "web.text", "web.click", "web.type", "web.eval", "layout", "tree", "changes", "changes.branch", "changes.commit", "log", "diff", "turns", "git", "search", "diagnostics", "languages",
                                                  "review.list", "review.add", "review.remove", "review.clear", "review.send", "reveal"]

    private static func refuse(_ why: String) -> RemoteRelayMessage.Reply {
        .init(code: 1, errors: "tiri: \(why)\n")
    }

    static func handle(_ request: RemoteRelayMessage.Request, from destination: String) async -> RemoteRelayMessage.Reply {
        guard let connection = await MainActor.run(body: { AppModel.shared.remote.existingConnection(destination) }) else {
            return refuse("this server isn't connected.")
        }
        let map = connection.map
        let stdin = request.stdin
        var environment = CLIParser.Environment(
            cwd: map.local(request.cwd ?? connection.home ?? "/"), itemID: request.item, workspace: request.workspace, claudeEntrypoint: request.entrypoint,
            ancestors: { [ancestors = request.ancestors ?? []] in ancestors.map { $0.split(separator: " ").map(String.init) } },
            fileExists: { path in
                if FileManager.default.fileExists(atPath: path) { return true }
                // Not in the copy yet: outside the workspace's folders, or only just made.
                return map.remote(path).flatMap { connection.learn(remote: $0) } != nil
            },
            readStdin: { Data((stdin ?? "").utf8) })
        environment.translate = { map.local($0) }
        environment.home = connection.home
        let parsed: CLIParser.Parsed
        do {
            parsed = try CLIParser.parse(request.argv, environment: environment)
        } catch {
            return .init(code: 2, errors: "\(error)\n")
        }
        switch parsed {
        case .printText(let text):
            return .init(output: text + "\n")
        case .quietSuccess:
            return .init()
        case .local:
            // What's installed on this Mac doesn't get decided from a server.
            return refuse("plugins can only be managed on the Mac, not from a server.")
        case .change, .update:
            return refuse("Tiri itself can only be changed from a terminal on the Mac, not from a server.")
        case .request(var control, let json):
            guard allowed.contains(control.cmd) else {
                return refuse("\(control.cmd) can only be run on the Mac, not from a server.")
            }
            control.args["fromServer"] = true
            // Everything a path could mean has to be on this server. Nothing here is a path on the Mac.
            for key in ["path", "cwd", "folder", "file"] {
                guard let path = control.args[key]?.stringValue else { continue }
                let standard = RemotePathMap.lexical(path)
                guard map.contains(standard) else { return refuse("\(path) isn't on this server.") }
                control.args[key] = .string(standard)
            }
            if let paths = control.args["paths"]?.arrayValue {
                let standard = paths.compactMap(\.stringValue).map(RemotePathMap.lexical)
                guard standard.allSatisfy(map.contains) else { return refuse("those paths aren't all on this server.") }
                control.args["paths"] = .array(standard.map(JSONValue.string))
            }
            if control.cmd == "preview", let target = control.args["target"]?.stringValue {
                guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else { return refuse("that isn't an address.") }
                if scheme == "file" {
                    guard map.contains(RemotePathMap.lexical(url.path)) else { return refuse("that file isn't on this server.") }
                } else if scheme == "http" || scheme == "https" {
                    guard let local = await MainActor.run(body: { AppModel.shared.remote }).localURL(for: url, on: destination) else {
                        return refuse("couldn't forward that port. This server may not allow it.")
                    }
                    control.args["target"] = .string(local.absoluteString)
                } else {
                    return refuse("Tiri only opens web and file addresses.")
                }
            }
            // Every item named has to be on this server, and with none named the command
            // has to land on this server, never on whatever the Mac happens to have in front.
            let scoped: String? = await MainActor.run { () -> String? in
                let model = AppModel.shared
                var named: [String] = []
                for key in ["item", "source", "to"] {
                    if let id = control.args[key]?.stringValue { named.append(id) }
                }
                // Review comments have ids of their own.
                if !control.cmd.hasPrefix("review."), let id = control.args["id"]?.stringValue { named.append(id) }
                for id in named where model.workspace(containing: id)?.remote != destination {
                    return "\(id) isn't on this server."
                }
                if let item = request.item {
                    guard model.workspace(containing: item)?.remote == destination else { return "this terminal isn't one of this server's." }
                    if control.args["source"] == nil { control.args["source"] = .string(item) }
                } else if model.active.remote != destination {
                    return "the workspace in front isn't on this server, and this isn't a terminal of Tiri's."
                }
                if aboutFront.contains(control.cmd), model.active.remote != destination {
                    return "the workspace in front isn't on this server. Switch to it first."
                }
                if control.cmd == "review.send", control.args["item"] == nil, control.args["to"] == nil {
                    return "say which terminal should get it, with --to."
                }
                // A folder here would become a workspace on the Mac. Workspaces are the person's call.
                if control.cmd == "open", let path = control.args["path"]?.stringValue {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                        return "that's a folder. Try tiri reveal."
                    }
                }
                return nil
            }
            if let scoped { return refuse(scoped) }
            if control.cmd == "remote.forward" { control.args["host"] = .string(destination) }
            // Somewhere the copy doesn't hold yet: outside the folders, or only just made.
            for key in ["path", "cwd"] {
                guard let path = control.args[key]?.stringValue, !FileManager.default.fileExists(atPath: path),
                      let remote = map.remote(path) else { continue }
                _ = connection.learn(remote: remote)
            }
            var response = await ControlHandler.handle(control)
            if control.cmd == "items", let list = response.result?.arrayValue {
                let allowedItems = await MainActor.run {
                    Set(AppModel.shared.workspaces.filter { $0.remote == destination }.flatMap { ($0.items + ($0.peek.map { [$0] } ?? [])).map(\.id) })
                }
                response.result = .array(list.filter { allowedItems.contains($0["id"]?.stringValue ?? "") })
            }
            if control.cmd == "remote.ports", let list = response.result?.arrayValue {
                response.result = .array(list.filter { $0["host"]?.stringValue == destination })
            }
            guard response.ok else {
                return refuse(map.remoteText(response.error ?? "Unknown error"))
            }
            if json {
                return .init(output: map.remoteText(String(decoding: (try? ControlCoding.encodeLine(response)) ?? Data(), as: UTF8.self)))
            }
            return .init(output: map.remoteText(CLIOutput.text(request: control, response: response)))
        }
    }
}

// MARK: - A file that's still on its way

/// Shows for the moment between opening a file on a server and having it here. Most never get seen.
@MainActor
final class RemoteFileController: ItemController {
    let itemID: ItemID
    let view: NSView
    private let path: String
    private unowned let model: AppModel
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let retry = NSButton(title: String(localized: "Try Again"), target: nil, action: nil)

    init(itemID: ItemID, path: String, model: AppModel) {
        self.itemID = itemID
        self.path = path
        self.model = model
        let holder = NSView()
        view = holder
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        retry.isHidden = true
        retry.target = self
        retry.action = #selector(tryAgain)
        let stack = NSStackView(views: [spinner, label, retry])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        label.stringValue = Self.waitingText(path: path)
        // Almost always quicker than this, so no flash of a spinner.
        spinner.isHidden = true
        label.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.spinner.isHidden = self?.retry.isHidden == false
            self?.label.isHidden = false
        }
    }

    func focus() {}

    private static func waitingText(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let size = RemoteRegistry.shared.connection(forLocal: path)?.record(forLocal: path)?.size, size > 5_000_000 else { return String(localized: "Getting \(name)…") }
        return String(localized: "Getting \(name), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))…")
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = false
        label.stringValue = message
        retry.isHidden = false
    }

    func connectionChanged() {
        model.notebookKernels.connectionChanged()
        if !retry.isHidden { tryAgain() }
    }

    @objc private func tryAgain() {
        retry.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.stringValue = Self.waitingText(path: path)
        model.remote.fetch(path)
    }
}

// MARK: - Connecting, as a person does it

extension AppModel {
    /// Connect to Server…: the hosts in `~/.ssh/config`, the ones used before, or anything typed.
    func connectToServerInteractive() {
        let manager = remote
        openPalette(.dynamic(title: String(localized: "Connect to a server. Type a host from your SSH config, or user@host."), provider: { query, deliver in
            MainActor.assumeIsolated {
                deliver(manager.hostRows(query: query))
            }
        }))
    }

    /// Connects, then asks which folder.
    func connect(to destination: String) {
        let name = SSHConfigFile.displayName(of: destination)
        // Already up: straight on, with nothing to say about it.
        let toast = remote.existingConnection(destination)?.state.isReady == true ? nil
            : showToast(title: String(localized: "Connecting to \(name)…"), detail: nil, symbol: "server.rack", tint: .secondary)
        remote.whenReady(destination) { [weak self] result in
            guard let self else { return }
            if let toast { self.dismissToast(toast) }
            switch result {
            case .success:
                self.remote.remember(destination: destination, folder: nil)
                self.chooseRemoteFolder(on: destination)
            case .failure(let failure):
                self.showToast(title: String(localized: "Couldn't connect"), detail: failure.description, symbol: "exclamationmark.triangle", tint: .orange,
                               actionTitle: String(localized: "Try Again")) { [weak self] in self?.connect(to: destination) }
            }
        }
    }

    func chooseRemoteFolder(on destination: String, adding: Bool = false) {
        let manager = remote
        let host = SSHConfigFile.displayName(of: destination)
        let title = adding ? String(localized: "Folder on \(host). Type a path, ↩ adds it.") : String(localized: "Folder on \(host). Type a path, ↩ opens it.")
        openPalette(.dynamic(title: title, provider: { query, deliver in
            MainActor.assumeIsolated { manager.folderRows(query: query, destination: destination, adding: adding, deliver: deliver) }
        }))
    }

    /// A workspace for a folder on a server. Starts with a terminal there, like any other.
    @discardableResult
    func openRemoteFolder(_ remoteFolder: String, on destination: String, name: String? = nil, activating: Bool = true) -> Workspace {
        let connection = remote.connection(destination)
        let local = connection.map.local(remoteFolder)
        if let existing = workspaces.first(where: { $0.remote == destination && $0.folders.contains(local) }) {
            if activating { switchWorkspace(existing.id) }
            return existing
        }
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        remote.remember(destination: destination, folder: remoteFolder)
        let workspace = createWorkspace(name: name ?? (remoteFolder as NSString).lastPathComponent, folders: [local], remote: destination, activating: activating)
        remote.syncRoots(destination)
        return workspace
    }

    /// A Remote-SSH workspace from Cursor or VS Code: connects, then opens its folders together.
    func importRemoteWorkspace(_ imported: CodeWorkspaceImporter.Imported, host: String) {
        let name = SSHConfigFile.displayName(of: host)
        let toast = showToast(title: String(localized: "Connecting to \(name)…"), detail: nil, symbol: "server.rack", tint: .secondary)
        remote.whenReady(host) { [weak self] result in
            guard let self else { return }
            self.dismissToast(toast)
            switch result {
            case .failure(let failure):
                self.showToast(title: String(localized: "Couldn't connect"), detail: failure.description, symbol: "exclamationmark.triangle", tint: .orange,
                               actionTitle: String(localized: "Try Again")) { [weak self] in self?.importRemoteWorkspace(imported, host: host) }
            case .success(let connection):
                Task {
                    let folders = await Task.detached(priority: .userInitiated) { imported.folders.compactMap { connection.resolveFolder($0) } }.value
                    if folders.count < imported.folders.count {
                        let missing = imported.folders.count - folders.count
                        let title = missing == 1 ? String(localized: "1 folder not found on \(name)") : String(localized: "\(missing) folders not found on \(name)")
                        self.showToast(title: title, detail: String(localized: "Imported the rest of \(imported.name)"),
                                       symbol: "exclamationmark.triangle", tint: .orange)
                    }
                    guard let first = folders.first else { return }
                    self.openRemoteFolder(first, on: host, name: imported.name)
                    for folder in folders.dropFirst() {
                        let local = connection.map.local(folder)
                        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
                        self.addFolder(local)
                    }
                }
            }
        }
    }

    /// How a path reads to a person: as it is on its server, and with `~` when it's in the home folder.
    func prettyPath(_ path: String) -> String {
        guard RemoteRegistry.shared.isRemote(path) else { return (path as NSString).abbreviatingWithTildeInPath }
        // Before launch has finished, and again once the home folder is known.
        let host = workspaces.first { $0.remote != nil && $0.folder(containing: path) != nil }?.remote
        if let host { _ = remote.state(of: host) }
        guard let connection = RemoteRegistry.shared.connection(forLocal: path) ?? host.map({ remote.connection($0) }),
              let remote = connection.map.remote(path) else { return path }
        if let home = connection.home ?? self.remote.recents().homes[connection.destination], remote == home || remote.hasPrefix(home + "/") {
            return "~" + remote.dropFirst(home.count)
        }
        return remote
    }

    func remoteRepositoryMoved(_ destination: String) {
        for workspace in workspaces where workspace.remote == destination && lives[workspace.id] != nil { refreshChanges(workspace.id) }
    }

    func refreshChangesIfOn(_ destination: String) {
        if active.remote == destination { refreshChanges() }
    }
}

extension RemoteManager {
    func hostRows(query: String) -> [PaletteModel.Row] {
        let recents = recents().hosts
        let configured = SSHConfigFile.hosts()
        var names: [(alias: String, detail: String?)] = recents.map { recent in
            (recent, configured.first { $0.alias == recent }?.detail)
        }
        names += configured.filter { !recents.contains($0.alias) }.map { ($0.alias, $0.detail) }
        let text = SSHConfigFile.halfWidth(query.trimmingCharacters(in: .whitespaces))
        var rows: [PaletteModel.Row] = []
        for (alias, detail) in names where text.isEmpty || alias.localizedCaseInsensitiveContains(text) || (detail?.localizedCaseInsensitiveContains(text) ?? false) {
            rows.append(PaletteModel.Row(id: alias, title: SSHConfigFile.displayName(of: alias), detail: detail, symbol: "server.rack") { [weak self] _ in
                self?.model.closePalette(restoreFocus: false)
                self?.model.connect(to: alias)
            })
        }
        if !text.isEmpty, let destination = SSHConfigFile.destination(from: text), !rows.contains(where: { $0.id == destination }) {
            rows.append(PaletteModel.Row(id: "typed:" + destination, title: String(localized: "Connect to \(SSHConfigFile.displayName(of: destination))"), symbol: "arrow.right.circle") { [weak self] _ in
                self?.model.closePalette(restoreFocus: false)
                self?.model.connect(to: destination)
            })
        }
        return rows
    }

    /// Choosing a folder walks down into it. ⌘↩, or the first row, opens what's been typed.
    func folderRows(query: String, destination: String, adding: Bool, deliver: @escaping ([PaletteModel.Row]) -> Void) {
        guard let connection = existingConnection(destination), let home = connection.home else {
            deliver([])
            return
        }
        func expand(_ path: String) -> String {
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home + path.dropFirst(1) }
            return path.hasPrefix("/") ? path : home + "/" + path
        }
        func pretty(_ path: String) -> String {
            if path == home { return "~" }
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        let text = SSHConfigFile.halfWidth(query.trimmingCharacters(in: .whitespaces))
        let opensTyped = text.isEmpty || text.hasSuffix("/") || text == "~"
        let directory = text.isEmpty ? home : expand(opensTyped ? String(text.dropLast(text.hasSuffix("/") && text.count > 1 ? 1 : 0)) : (text as NSString).deletingLastPathComponent)
        let filter = opensTyped ? "" : (text as NSString).lastPathComponent
        let openRow: (String) -> PaletteModel.Row = { [weak self] path in
            PaletteModel.Row(id: "open:" + path, title: adding ? String(localized: "Add \(pretty(path))") : String(localized: "Open \(pretty(path))"), symbol: "folder.badge.plus") { _ in
                guard let self else { return }
                self.model.closePalette()
                self.resolveAndOpen(path, destination: destination, adding: adding)
            }
        }
        let build: ([String]) -> [PaletteModel.Row] = { [weak self] children in
            guard let self else { return [] }
            var rows: [PaletteModel.Row] = []
            // What's typed, as a place to open, before anything it might be the start of.
            if opensTyped { rows.append(openRow(directory)) } else if children.contains(filter) {
                rows.append(openRow((directory as NSString).appendingPathComponent(filter)))
            }
            if text.isEmpty {
                for recent in self.recents().folders[destination] ?? [] where recent != home {
                    rows.append(openRow(recent))
                }
            }
            let shown = children.filter { name in
                if name.hasPrefix("."), !filter.hasPrefix(".") { return false }
                return filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
            }
            for name in shown.prefix(200) {
                let path = (directory as NSString).appendingPathComponent(name)
                rows.append(PaletteModel.Row(id: "go:" + path, title: name, detail: pretty(directory), symbol: "folder") { [weak self] alternate in
                    guard let self else { return }
                    if alternate {
                        self.model.closePalette()
                        self.resolveAndOpen(path, destination: destination, adding: adding)
                    } else {
                        self.model.palette?.query = pretty(path) + "/"
                    }
                })
            }
            // Whatever's been typed can always be tried, so Return never does nothing.
            if !opensTyped, !children.contains(filter) {
                rows.append(openRow(expand(text)))
            }
            return rows
        }
        if let cached = cachedFolders(directory) {
            deliver(build(cached))
        } else {
            // Something right away, then the rest.
            deliver(opensTyped ? [openRow(directory)] : [])
        }
        Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) { connection.folders(in: directory) }.value
            guard let self else { return }
            self.cacheFolders(directory, children ?? [])
            deliver(build(children ?? []))
        }
    }

    private func resolveAndOpen(_ path: String, destination: String, adding: Bool) {
        guard let connection = existingConnection(destination) else { return }
        Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) { connection.resolveFolder(path) }.value
            guard let self else { return }
            guard let resolved else {
                self.model.showToast(title: String(localized: "\(path) isn't a folder on this server"), detail: nil, symbol: "questionmark.folder", tint: .orange)
                return
            }
            if adding {
                let local = connection.map.local(resolved)
                try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
                self.remember(destination: destination, folder: resolved)
                self.model.addFolder(local)
            } else {
                self.model.openRemoteFolder(resolved, on: destination)
            }
        }
    }
}

// MARK: - Opening a file on a server in another editor

extension AppModel {
    /// Editors that can reach a server themselves do it their way, on the real file, not the copy.
    func openExternallyOnServer(path: String, line: Int?) -> Bool {
        guard let connection = RemoteRegistry.shared.connection(forLocal: path), let remote = connection.map.remote(path) else { return false }
        let destination = connection.destination
        let pathEnv = ProcessInfo.processInfo.environment["PATH"]
        for editor in settings.externalEditors {
            guard let executable = ExternalEditor.locate(editor, pathEnv: pathEnv) else { continue }
            let name = (executable as NSString).lastPathComponent.lowercased()
            var arguments: [String]?
            let location = remote + (line.map { ":\($0)" } ?? "")
            if name == "zed" {
                arguments = ["ssh://" + SSHConfigFile.displayName(of: destination) + location]
            } else if name == "cursor" || name == "code" {
                arguments = ["--remote", "ssh-remote+" + SSHConfigFile.displayName(of: destination), "--goto", location]
            }
            guard let arguments else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return true }
        }
        showToast(title: String(localized: "None of your editors can open a file on a server"), detail: String(localized: "Zed, Cursor and VS Code can."), symbol: "exclamationmark.triangle", tint: .orange)
        return true
    }
}

// MARK: - When ssh has a question

extension AppModel {
    /// A password, a passphrase, a one-time code or an unknown host's fingerprint. Whatever's typed
    /// goes straight back to ssh and isn't kept.
    func answerSSHQuestion(_ prompt: String, host: String) async -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConfirmation = text.lowercased().contains("(yes/no")
        AppModel.bringAppForward()
        let alert = NSAlert()
        alert.alertStyle = isConfirmation ? .warning : .informational
        if host.isEmpty {
            alert.messageText = isConfirmation ? String(localized: "Trust this server?") : String(localized: "Connecting to this server")
        } else {
            alert.messageText = isConfirmation ? String(localized: "Trust \(host)?") : String(localized: "Connecting to \(host)")
        }
        alert.informativeText = text
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if isConfirmation {
            alert.addButton(withTitle: String(localized: "Trust and Connect"))
        } else {
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Continue"))
            alert.window.initialFirstResponder = field
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return isConfirmation ? "yes" : field.stringValue
    }
}
