import Foundation

// MARK: - State

public enum RemoteState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    /// It was up, and it went away. Programs on the server carry on.
    case reconnecting(attempt: Int)
    /// Nobody can fix this by waiting: wrong host, refused key, cancelled.
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .ready: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Couldn't connect"
        }
    }
}

public struct RemoteResult: Sendable {
    public var status: Int32
    public var output: Data
    public var errors: Data
    public var text: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errors, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public struct RemoteFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - The connection

/// One server: a multiplexed OpenSSH connection everything shares, the helper on the far side, and
/// the local copy of its folders. OpenSSH does the connecting, so keys, agents, jump hosts and
/// anything else in the user's config just work, and Tiri never sees a credential.
public final class RemoteConnection: @unchecked Sendable {
    public let destination: String
    public let map: RemotePathMap
    /// Where the connection's control socket goes. Unix sockets have short paths.
    private let controlPath: String
    private let helperDirectory: String
    private let askpass: String?
    private let controlSocket: String?
    private let machineTag: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tiri.remote.connection")
    private let mirrorQueue = DispatchQueue(label: "tiri.remote.mirror")

    private var _state: RemoteState = .idle
    private var _home: String?
    private var _shell = "/bin/sh"
    private var _binDirectory: String?
    private var _runDirectory: String?
    private var _hasHelper = false
    private var master: Process?
    private var masterErrors = Data()
    private var wanted = false
    private var attempt = 0
    private var generation = 0
    private var retryWork: DispatchWorkItem?

    /// Told about every change of state, on the main thread.
    public var onState: (@Sendable (RemoteState) -> Void)?
    /// A signal that the repository moved or that something changed that doesn't show in the tree.
    public var onRepositoryMoved: (@Sendable () -> Void)?
    /// What's open right now, whose contents should stay current. Asked from the mirror's queue.
    public var openFiles: (@Sendable () -> Set<String>)?
    /// Saves that couldn't reach the server yet, or just got there.
    public var onPendingSaves: (@Sendable (Int) -> Void)?

    public init(destination: String, controlPath: String, helperDirectory: String, askpass: String? = nil,
                controlSocket: String? = nil, machineTag: String = "local") {
        self.machineTag = machineTag
        self.destination = destination
        self.map = RemotePathMap(destination: destination)
        self.controlPath = controlPath
        self.helperDirectory = helperDirectory
        self.askpass = askpass
        self.controlSocket = controlSocket
        // Before anything can compare what's here with what's there: an edit that never got to the
        // server has to be known about by then.
        loadPendingSaves()
    }

    public var state: RemoteState { lock.withLock { _state } }
    public var home: String? { lock.withLock { _home } }
    public var shell: String { lock.withLock { _shell } }
    public var binDirectory: String? { lock.withLock { _binDirectory } }
    public var runDirectory: String? { lock.withLock { _runDirectory } }
    public var hasHelper: Bool { lock.withLock { _hasHelper } }
    /// csh and tcsh take neither `-l` with anything else nor `command -v`.
    public var isCShell: Bool { ["csh", "tcsh"].contains((shell as NSString).lastPathComponent) }

    private func setState(_ state: RemoteState) {
        let changed: Bool = lock.withLock {
            let different = _state != state
            _state = state
            return different
        }
        guard changed, let onState else { return }
        DispatchQueue.main.async { onState(state) }
    }

    // MARK: Commands

    private static let ssh = "/usr/bin/ssh"

    /// Options every use shares. The user's config applies, except what would stop this working.
    private var configArguments: [String] {
        if let config = ProcessInfo.processInfo.environment["TIRI_SSH_CONFIG"], !config.isEmpty { return ["-F", config] }
        return []
    }

    private func clientArguments(tty: Bool) -> [String] {
        configArguments + ["-S", controlPath, "-o", "ControlMaster=no", "-o", "RemoteCommand=none",
                           "-o", tty ? "RequestTTY=force" : "RequestTTY=no", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes"]
    }

    private var masterArguments: [String] {
        configArguments + ["-M", "-N", "-S", controlPath, "-o", "ControlPersist=no", "-o", "RemoteCommand=none",
                           "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=20",
                           "-o", "TCPKeepAlive=yes", "-o", "ExitOnForwardFailure=no", "-o", "LogLevel=ERROR",
                           "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", destination]
    }

    /// The program for a terminal: `ssh` running `script` on a real terminal over the connection.
    /// Slot 0 shares the main connection. Past what that can hold, each slot is a connection of its own.
    public func terminalArguments(script: String, slot: Int = 0) -> [String] {
        var arguments = clientArguments(tty: true)
        if slot > 0, let index = arguments.firstIndex(of: "-S") { arguments[index + 1] = controlPath + "-t\(slot)" }
        return arguments + [destination, RemoteShell.wrap(script)]
    }

    public static let terminalsOnMainConnection = 3
    public static let terminalsPerExtraConnection = 8

    /// Brings up the extra connection for a slot, if it isn't up. It goes away by itself once idle.
    public func ensureTerminalConnection(slot: Int) -> Bool {
        guard slot > 0 else { return true }
        let path = controlPath + "-t\(slot)"
        if Self.runProcess(executable: Self.ssh, arguments: configArguments + ["-S", path, "-O", "check", destination], timeout: 5)?.status == 0 { return true }
        unlink(path)
        var environment = ProcessInfo.processInfo.environment
        if let askpass {
            environment["SSH_ASKPASS"] = askpass
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["TIRI_ASKPASS_HOST"] = SSHConfigFile.displayName(of: destination)
            if let controlSocket { environment["TIRI_SOCKET"] = controlSocket }
        }
        let arguments = configArguments + ["-M", "-N", "-f", "-S", path, "-o", "ControlPersist=60", "-o", "RemoteCommand=none", "-o", "ServerAliveInterval=10",
                                           "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=20", "-o", "LogLevel=ERROR", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", destination]
        return Self.runProcess(executable: Self.ssh, arguments: arguments, timeout: 180, environment: environment)?.status == 0
    }

    private func endTerminalConnections() {
        for slot in 1...8 {
            let path = controlPath + "-t\(slot)"
            guard access(path, F_OK) == 0 else { continue }
            _ = Self.runProcess(executable: Self.ssh, arguments: configArguments + ["-S", path, "-O", "exit", destination], timeout: 5)
        }
    }

    /// The program for something with pipes rather than a terminal, like a language server.
    public func commandArguments(script: String) -> [String] {
        clientArguments(tty: false) + [destination, RemoteShell.wrap(script)]
    }

    public var sshExecutable: String { Self.ssh }

    /// Runs `sh` over the connection. Nil if there's no connection to run it on.
    public func run(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 30, outputFile: URL? = nil) -> RemoteResult? {
        guard state.isReady || runningDuringPreparation.value else { return nil }
        return exec(script, stdin: stdin, timeout: timeout, outputFile: outputFile)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
    private let runningDuringPreparation = Flag()

    /// `sshd` allows ten sessions per connection unless told otherwise, and refuses the rest. The
    /// watcher, the holder, a language server and a few terminals share them, so commands take turns.
    private let commandSlots = DispatchSemaphore(value: 2)
    /// Reading a big file can take a long time, and nothing else should have to wait for it.
    private let transferSlots = DispatchSemaphore(value: 2)

    private func exec(_ script: String, stdin: Data?, timeout: TimeInterval, outputFile: URL? = nil) -> RemoteResult? {
        let slots = timeout > 120 || outputFile != nil ? transferSlots : commandSlots
        guard slots.wait(timeout: .now() + max(timeout, 30)) == .success else { return nil }
        defer { slots.signal() }
        // A server can set its session limit lower than usual. It's only busy, so wait a moment.
        for attempt in 0..<6 {
            let result = Self.runProcess(executable: Self.ssh, arguments: clientArguments(tty: false) + [destination, RemoteShell.wrap(script)],
                                         stdin: stdin, timeout: timeout, outputFile: outputFile)
            guard let result, result.status == 255, Self.isSessionRefusal(result.errorText), attempt < 5 else { return result }
            Thread.sleep(forTimeInterval: 0.4 * Double(attempt + 1))
        }
        return nil
    }

    static func isSessionRefusal(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("session open refused") || lower.contains("session request failed") || lower.contains("too many sessions")
    }

    /// Reads both pipes on threads of their own: either can fill while the other waits.
    static func runProcess(executable: String, arguments: [String], stdin: Data? = nil, timeout: TimeInterval,
                           outputFile: URL? = nil, environment: [String: String]? = nil) -> RemoteResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let outputPipe = Pipe()
        var outputHandle: FileHandle?
        if let outputFile {
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            outputHandle = try? FileHandle(forWritingTo: outputFile)
            process.standardOutput = outputHandle ?? FileHandle.nullDevice
        } else {
            process.standardOutput = outputPipe
        }
        let inputPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inputPipe
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if outputFile == nil {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            // Or the threads above would wait for ever on pipes nobody will close.
            try? errorPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            return nil
        }
        if let stdin {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? errorPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            try? outputHandle?.close()
            return RemoteResult(status: 124, output: box.output, errors: Data("Timed out.".utf8))
        }
        // A daemon started over the connection can hold a pipe open forever. Don't wait for it.
        _ = group.wait(timeout: .now() + 2)
        try? outputHandle?.close()
        return RemoteResult(status: process.terminationStatus, output: box.output, errors: box.errors)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _output = Data()
        private var _errors = Data()
        var output: Data {
            get { lock.withLock { _output } }
            set { lock.withLock { _output = newValue } }
        }
        var errors: Data {
            get { lock.withLock { _errors } }
            set { lock.withLock { _errors = newValue } }
        }
    }

    // MARK: Connecting

    /// Starts, or does nothing if it's already up or trying. `quiet` won't ask anyone anything: for
    /// a server nobody's looking at, whose agents may want to report in.
    public func connect(quiet: Bool = false) {
        queue.async { [self] in
            wanted = true
            retryWork?.cancel()
            // Someone's looking now, so it's fine to ask them things. Quietly trying won't get there.
            let wasQuiet = isQuiet
            isQuiet = quiet
            switch state {
            case .ready:
                return
            case .connecting:
                if wasQuiet, !quiet { startMaster(reconnecting: false) }
            case .reconnecting:
                // An attempt under way may be waiting on a person, or just on a slow network.
                if master?.isRunning != true { startMaster(reconnecting: true) }
            case .idle, .failed:
                attempt = 0
                setState(.connecting)
                startMaster(reconnecting: false)
            }
        }
    }

    private var isQuiet = false

    /// Something suggests it's worth trying right now: the Mac woke, the network came back.
    public func tryNow() {
        queue.async { [self] in
            guard wanted else { return }
            switch state {
            case .reconnecting:
                guard master?.isRunning != true else { return }
                retryWork?.cancel()
                attempt = 0
                startMaster(reconnecting: true)
            case .failed:
                retryWork?.cancel()
                attempt = 0
                setState(.connecting)
                startMaster(reconnecting: false)
            case .ready:
                // The connection may be dead and not know yet, and waiting for keepalives takes 30
                // seconds. Only asking the far side tells: the local process is fine either way.
                let current = generation
                DispatchQueue.global(qos: .utility).async { [self] in
                    let alive = exec("true", stdin: nil, timeout: 6)?.succeeded == true
                    queue.async { [self] in
                        guard !alive, current == generation, let master, master.isRunning else { return }
                        master.terminate()
                    }
                }
            case .idle, .connecting:
                break
            }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            wanted = false
            retryWork?.cancel()
            generation += 1
            // First, so it's done even if the app is on its way out.
            if let master, master.isRunning { master.terminate() }
            master = nil
            stopWatcher()
            stopRelay()
            endTerminalConnections()
            setState(.idle)
        }
    }

    /// Tiri is quitting. What's running on the server carries on, but nothing here should linger.
    public func endForQuit() {
        queue.sync {
            wanted = false
            retryWork?.cancel()
            generation += 1
            stopWatcher()
            stopRelay()
            endTerminalConnections()
            _ = Self.runProcess(executable: Self.ssh, arguments: configArguments + ["-S", controlPath, "-O", "exit", destination], timeout: 2)
            if let master, master.isRunning { master.terminate() }
        }
    }

    /// Connections left by a run that crashed, which would otherwise linger for as long as the Mac's up.
    public static func endLeftovers(in directory: String, keeping: Set<String>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix("s-") && !keeping.contains(name) {
            _ = runProcess(executable: ssh, arguments: ["-S", directory + "/" + name, "-O", "exit", "leftover"], timeout: 3)
            unlink(directory + "/" + name)
        }
    }

    /// Whether the local end of the connection is up. It can be, with the far end long gone.
    public func isMasterRunning() -> Bool { isMasterHealthy() }

    private func isMasterHealthy() -> Bool {
        guard let result = Self.runProcess(executable: Self.ssh, arguments: configArguments + ["-S", controlPath, "-O", "check", destination], timeout: 5) else { return false }
        return result.status == 0
    }

    private func startMaster(reconnecting: Bool) {
        generation += 1
        let current = generation
        if let master, master.isRunning { master.terminate() }
        // One left over from a run that didn't end cleanly, which would hold its forwarded ports.
        if master == nil, access(controlPath, F_OK) == 0 {
            _ = Self.runProcess(executable: Self.ssh, arguments: configArguments + ["-S", controlPath, "-O", "exit", destination], timeout: 3)
        }
        unlink(controlPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = (isQuiet ? ["-o", "BatchMode=yes"] : []) + masterArguments
        var environment = ProcessInfo.processInfo.environment
        if let askpass, !isQuiet {
            // A passphrase, a password, a one-time code or an unknown host: ssh asks, Tiri shows
            // the question and hands back the answer, and holds onto none of it.
            environment["SSH_ASKPASS"] = askpass
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["TIRI_ASKPASS_HOST"] = SSHConfigFile.displayName(of: destination)
            if let controlSocket { environment["TIRI_SOCKET"] = controlSocket }
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        masterErrors = Data()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async { self.masterErrors.append(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            // What it said on its way out is still in the pipe, and it's what the person needs to know.
            self.queue.asyncAfter(deadline: .now() + 0.25) { self.masterEnded(generation: current) }
        }
        do {
            try process.run()
        } catch {
            setState(.failed("Couldn't run ssh: \(error.localizedDescription)"))
            return
        }
        master = process
        waitForMaster(generation: current, reconnecting: reconnecting, deadline: Date().addingTimeInterval(180))
    }

    /// The control socket appears once it has really logged in, however long a person took.
    private func waitForMaster(generation current: Int, reconnecting: Bool, deadline: Date) {
        guard current == generation, master?.isRunning == true else { return }
        if access(controlPath, F_OK) == 0, isMasterHealthy() {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let problem = prepare()
                queue.async { [self] in
                    guard current == generation else { return }
                    if problem == Self.connectionGone {
                        // It dropped while getting ready. That's the usual case, handled the usual way.
                        if let master, master.isRunning { master.terminate() }
                        return
                    }
                    if let problem {
                        // A connection that's up but can't be used doesn't get better by retrying.
                        if let master, master.isRunning { master.terminate() }
                        wanted = false
                        generation += 1
                        setState(.failed(problem))
                        return
                    }
                    attempt = 0
                    setState(.ready)
                    afterReady()
                }
            }
            return
        }
        if Date() > deadline {
            master?.terminate()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            waitForMaster(generation: current, reconnecting: reconnecting, deadline: deadline)
        }
    }

    private func masterEnded(generation ended: Int) {
        guard ended == generation, wanted else { return }
        let message = String(decoding: masterErrors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        stopWatcher()
        stopRelay()
        let wasUp: Bool
        switch state {
        case .ready, .reconnecting: wasUp = true
        default: wasUp = false
        }
        // Refused, as opposed to unreachable. Trying again would only ask someone again and again.
        let lower = message.lowercased()
        let refused = lower.contains("permission denied") || lower.contains("host key verification failed") || lower.contains("too many authentication")
        if !wasUp || refused {
            // It never got anywhere. Asking again wouldn't change the answer.
            if refused { wanted = false }
            setState(.failed(Self.explain(message, destination: destination)))
            return
        }
        attempt += 1
        setState(.reconnecting(attempt: attempt))
        let delay = min(pow(2, Double(attempt - 1)), 15)
        let work = DispatchWorkItem { [weak self] in self?.startMaster(reconnecting: true) }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// OpenSSH's words, where they mean something. Otherwise its last line.
    static func explain(_ message: String, destination: String) -> String {
        let lower = message.lowercased()
        let name = SSHConfigFile.displayName(of: destination)
        if lower.contains("could not resolve hostname") { return "\(name) isn't a host this Mac can find." }
        if lower.contains("permission denied") { return "\(name) didn't accept your key or password." }
        if lower.contains("connection refused") { return "\(name) refused the connection. SSH may not be running there." }
        if lower.contains("timed out") { return "\(name) didn't answer." }
        if lower.contains("host key verification failed") { return "\(name)'s identity couldn't be confirmed, so Tiri didn't connect." }
        if lower.contains("no route to host") || lower.contains("network is unreachable") { return "This Mac can't reach \(name) from this network." }
        let last = message.split(whereSeparator: \.isNewline).last.map(String.init)
        return last ?? "\(name) closed the connection."
    }

    // MARK: Getting the server ready

    /// What's needed before anything else: what kind of server it is, and the helper on it.
    /// Returns what's wrong, if anything is.
    private static let connectionGone = "connection gone"

    private func prepare() -> String? {
        runningDuringPreparation.value = true
        defer { runningDuringPreparation.value = false }
        let probe = """
        printf 'kind=%s %s\\n' "$(uname -s)" "$(uname -m)"
        printf 'home=%s\\n' "$HOME"
        shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
        [ -n "$shell" ] || shell="$SHELL"
        printf 'shell=%s\\n' "$shell"
        printf 'uid=%s\\n' "$(id -u)"
        """
        guard let answer = exec(probe, stdin: nil, timeout: 30), answer.status != 255, answer.status != 124 else { return Self.connectionGone }
        guard answer.succeeded else {
            return "\(SSHConfigFile.displayName(of: destination)) connected, but wouldn't run a command."
        }
        var values: [String: String] = [:]
        for line in answer.text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let home = values["home"], home.hasPrefix("/") else {
            return "\(SSHConfigFile.displayName(of: destination)) connected, but didn't say where its home folder is."
        }
        lock.withLock {
            _home = home
            if let shell = values["shell"], shell.hasPrefix("/") { _shell = shell }
        }
        installHelper(kind: values["kind"] ?? "", home: home, uid: values["uid"] ?? "0")
        return nil
    }

    static func helperName(kind: String) -> String? {
        switch kind.lowercased() {
        case "linux x86_64", "linux amd64": "tiri-remote-linux-x86_64"
        case "linux aarch64", "linux arm64": "tiri-remote-linux-aarch64"
        case "darwin arm64": "tiri-remote-darwin-arm64"
        case "darwin x86_64": "tiri-remote-darwin-x86_64"
        default: nil
        }
    }

    /// Named by version, so an update doesn't pull it out from under a running session, and a
    /// server with it already needs nothing sent.
    private func installHelper(kind: String, home: String, uid: String) {
        let version = (try? String(contentsOfFile: helperDirectory + "/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
        // The usual place, then a place for a home folder that won't run programs.
        for base in [home + "/.tiri", "/tmp/.tiri-" + uid] {
            let bin = base + "/bin"
            // Sockets have short paths, and a deep home folder can go past them.
            let run = (base + "/run").utf8.count < 70 ? base + "/run" : "/tmp/.tiri-" + uid + "/run"
            let quoted = ShellQuote.quote(bin + "/tiri-remote-" + version)
            // Only a folder that's really this user's. Under /tmp, someone else could have made it first.
            let quotedBase = ShellQuote.quote(base)
            let ours = "mkdir -p \(quotedBase) && [ -O \(quotedBase) ] && [ ! -L \(quotedBase) ] && chmod 700 \(quotedBase)"
            let check = "\(ours) && mkdir -p \(ShellQuote.quote(bin)) \(ShellQuote.quote(run)) \(ShellQuote.quote(base + "/tmp")) && chmod 700 \(ShellQuote.quote(run)) && \(quoted) version"
            var works = exec(check, stdin: nil, timeout: 20)?.text.trimmingCharacters(in: .whitespacesAndNewlines) == version
            if !works, let name = Self.helperName(kind: kind),
               let binary = try? Data(contentsOf: URL(fileURLWithPath: helperDirectory + "/" + name)) {
                let temporary = ShellQuote.quote(bin + "/.upload-" + UUID().uuidString.prefix(8))
                let upload = "\(ours) && cat > \(temporary) && chmod 755 \(temporary) && mv \(temporary) \(quoted) && \(quoted) version"
                works = exec(upload, stdin: binary, timeout: 120)?.text.trimmingCharacters(in: .whitespacesAndNewlines) == version
            }
            if works {
                let links = """
                cd \(ShellQuote.quote(bin)) && ln -sf tiri-remote-\(version) tiri-remote && ln -sf tiri-remote-\(version) tiri
                for old in tiri-remote-*; do [ "$old" = tiri-remote-\(version) ] || rm -f "$old"; done
                """
                _ = exec(links, stdin: nil, timeout: 20)
                lock.withLock {
                    _binDirectory = bin
                    _runDirectory = run
                    _hasHelper = true
                }
                return
            }
        }
        // Some other kind of machine. Terminals and files still work, just without what needs it.
        lock.withLock {
            _binDirectory = nil
            _runDirectory = nil
            _hasHelper = false
        }
    }

    // MARK: After connecting

    /// What to do each time it comes up. Forwards don't survive a reconnection.
    public var onReady: (@Sendable () -> Void)?

    private func afterReady() {
        isQuiet = false
        startRelay()
        rescan()
        startWatcher()
        retryPendingSaves()
        if let onReady { DispatchQueue.global(qos: .userInitiated).async(execute: onReady) }
    }

    // MARK: `tiri` on the server

    private var relayProcess: Process?
    private var relayInput: Pipe?
    private var relayPID: Int?
    private let relayWrites = NSLock()

    /// A `tiri` command from a terminal on the server: its JSON, and what to send back.
    public var onRelayRequest: (@Sendable (Data) async -> Data)?

    /// Unique to this Mac's Tiri, so two of them on one server don't take each other's commands.
    public var relaySocket: String? { runDirectory.map { $0 + "/" + machineTag + "-control.sock" } }

    /// A process that lives exactly as long as this connection. Commands from `tiri` arrive through
    /// it, and a lock file can name it. Over an ordinary session, because plenty of servers forbid forwarding.
    private func startRelay() {
        stopRelay()
        let script: String
        if let bin = binDirectory, let socket = relaySocket, let run = runDirectory {
            script = """
            ln -sf \(ShellQuote.quote((socket as NSString).lastPathComponent)) \(ShellQuote.quote(run + "/control.sock"))
            exec \(ShellQuote.quote(bin + "/tiri-remote")) relay \(ShellQuote.quote(socket))
            """
        } else {
            script = "echo P $$ 0; exec tail -f /dev/null"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = clientArguments(tty: false) + [destination, RemoteShell.wrap(script)]
        let output = Pipe()
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = RelayFrames()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for frame in reader.read(data) { self?.relayFrame(frame, input: input) }
        }
        process.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) {
                guard self.relayProcess === ended, self.state.isReady else { return }
                self.startRelay()
            }
        }
        guard (try? process.run()) != nil else { return }
        relayProcess = process
        relayInput = input
    }

    private func stopRelay() {
        try? relayInput?.fileHandleForWriting.close()
        relayInput = nil
        if let relayProcess, relayProcess.isRunning { relayProcess.terminate() }
        relayProcess = nil
        lock.withLock { relayPID = nil }
    }

    private func relayFrame(_ frame: RelayFrames.Frame, input: Pipe) {
        switch frame.kind {
        case "P":
            lock.withLock { relayPID = frame.id }
        case "R":
            guard let onRelayRequest else { return }
            let id = frame.id
            let body = frame.body
            let writes = relayWrites
            Task.detached {
                let answer = await onRelayRequest(body)
                var message = Data("A \(id) \(answer.count)\n".utf8)
                message.append(answer)
                writes.withLock { try? input.fileHandleForWriting.write(contentsOf: message) }
            }
        default:
            break
        }
    }

    /// Reads `<letter> <id> <length>\n` then that many bytes.
    final class RelayFrames: @unchecked Sendable {
        struct Frame {
            var kind: Character
            var id: Int
            var body: Data
        }
        private let lock = NSLock()
        private var pending = Data()

        func read(_ chunk: Data) -> [Frame] {
            lock.withLock {
                pending.append(chunk)
                var frames: [Frame] = []
                while let newline = pending.firstIndex(of: 10) {
                    let words = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self).split(separator: " ")
                    guard words.count == 3, let kind = words[0].first, let id = Int(words[1]), let length = Int(words[2]),
                          length >= 0, length <= 16 * 1024 * 1024 else {
                        pending = Data(pending[pending.index(after: newline)...])
                        continue
                    }
                    let start = pending.index(after: newline)
                    guard pending.distance(from: start, to: pending.endIndex) >= length else { break }
                    let end = pending.index(start, offsetBy: length)
                    frames.append(Frame(kind: kind, id: id, body: Data(pending[start..<end])))
                    pending = Data(pending[end...])
                }
                if pending.count > 32 * 1024 * 1024 { pending = Data() }
                return frames
            }
        }
    }

    /// Waits a moment to hear who it is.
    public func waitForRelay(timeout: TimeInterval = 5) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = lock.withLock({ relayPID }) { return pid }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    // MARK: Forwarding

    /// Reaches a port on the server from this Mac. Returns the local port.
    public func forwardToServer(remotePort: Int, preferredLocalPort: Int? = nil) -> Int? {
        for local in Self.candidatePorts(preferred: preferredLocalPort ?? remotePort) {
            let arguments = configArguments + ["-S", controlPath, "-O", "forward", "-L", "127.0.0.1:\(local):127.0.0.1:\(remotePort)", destination]
            guard let result = Self.runProcess(executable: Self.ssh, arguments: arguments, timeout: 10) else { return nil }
            if result.status == 0 { return local }
            // Only a port already taken here is worth another try with another number.
            let reason = result.errorText.lowercased()
            guard reason.contains("bind") || reason.contains("already in use") else { return nil }
        }
        return nil
    }

    /// Connects to a forwarded port. When nothing's listening at the far end, or the server forbids
    /// forwarding, ssh accepts and then hangs up straight away. A real server waits for a request.
    public static func portAnswers(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        var wait = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&wait, 1, 700) > 0 else { return true }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) > 0
    }

    public func cancelForward(localPort: Int, remotePort: Int) {
        let arguments = configArguments + ["-S", controlPath, "-O", "cancel", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", destination]
        _ = Self.runProcess(executable: Self.ssh, arguments: arguments, timeout: 10)
    }

    private static func candidatePorts(preferred: Int) -> [Int] {
        // The same number when it's free, because pages often link to their own port.
        [preferred] + (1...8).map { _ in Int.random(in: 49152...65000) }
    }

    /// Reaches a port on this Mac from the server. The server picks the port unless one's asked for.
    public func forwardToMac(localPort: Int, preferredRemotePort: Int? = nil) -> Int? {
        var attempts: [Int] = []
        if let preferredRemotePort { attempts.append(preferredRemotePort) }
        attempts.append(0)
        for remote in attempts {
            let arguments = configArguments + ["-S", controlPath, "-O", "forward", "-R", "127.0.0.1:\(remote):127.0.0.1:\(localPort)", destination]
            guard let result = Self.runProcess(executable: Self.ssh, arguments: arguments, timeout: 10), result.status == 0 else { continue }
            if remote != 0 { return remote }
            if let port = Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) { return port }
        }
        return nil
    }

    // MARK: The local copy

    private var roots: [String] = []
    private var excludes: [String] = [".git", ".DS_Store"]
    private var records: [String: RemoteRecord] = [:]
    private var inFlight: [String: [@Sendable (Result<Void, RemoteFailure>) -> Void]] = [:]
    /// Remote path to the server's modified time when the edit was made, to spot a conflict.
    private var pendingSaves: [String: Int64] = [:]
    private var uploading: Set<String> = []
    private var savedAgain: Set<String> = []
    /// Asked about by name, so a rescan of everything else shouldn't take them away.
    private var onDemand: Set<String> = []
    /// Case-folded path on this Mac to the one name on the server that gets to live there.
    private var foldedNames: [String: String] = [:]
    public var onCaseCollision: (@Sendable (String, String) -> Void)?
    public var onSaveConflict: (@Sendable (String) -> Void)?
    private var watcher: Process?
    private var watcherInput: Pipe?
    private var limited = false
    private var rescanTimer: DispatchSourceTimer?

    /// The folders this connection keeps a copy of, as paths on the server.
    public func setRoots(_ remoteRoots: [String], excludes names: [String]) {
        mirrorQueue.async { [self] in
            let fresh = Array(Set(remoteRoots)).sorted()
            let names = Array(Set(names + [".git", ".DS_Store"])).sorted()
            guard fresh != roots || names != excludes else { return }
            roots = fresh
            lock.withLock { excludes = names }
            guard state.isReady else { return }
            rescan()
            startWatcher()
        }
    }

    private var excludeArgument: String {
        // A name with a comma can't be passed along. No such exclude is worth a whole failed scan.
        lock.withLock { excludes }.filter { !$0.contains(",") }.joined(separator: ",")
    }

    /// Something still to reach the server is at this path, or somewhere under it.
    private func holdsPendingSave(_ remote: String) -> Bool {
        if pendingSaves[remote] != nil { return true }
        let prefix = remote == "/" ? "/" : remote + "/"
        return pendingSaves.keys.contains { $0.hasPrefix(prefix) }
    }

    /// On this Mac's disk, names that differ only by case or normalization are one file, and on
    /// Linux they're two. Only the first gets a place here, or each would read and overwrite the other.
    /// Returns false if this name's place is taken. Runs on mirrorQueue.
    private func claimName(_ record: RemoteRecord) -> Bool {
        let folded = record.path.precomposedStringWithCanonicalMapping.lowercased()
        if let holder = foldedNames[folded], holder != record.path {
            if let onCaseCollision { DispatchQueue.main.async { onCaseCollision(record.path, holder) } }
            return false
        }
        foldedNames[folded] = record.path
        return true
    }

    private func helper(_ bin: String) -> String { ShellQuote.quote(bin + "/tiri-remote") }

    /// Looks at everything again. After connecting, and whenever the watcher lost track.
    public func rescan(then done: (@Sendable () -> Void)? = nil) {
        mirrorQueue.async { [self] in
            defer { done?() }
            for root in roots { scan(root: root, depth: 0, removing: true) }
        }
    }

    /// Runs on mirrorQueue.
    private func scan(root: String, depth: Int, removing: Bool) {
        let script: String
        if let bin = binDirectory {
            script = "\(helper(bin)) scan \(ShellQuote.quote(root)) --exclude \(ShellQuote.quote(excludeArgument))" + (depth > 0 ? " --depth \(depth)" : "")
        } else {
            // With no helper here: what plain `find` can tell, in the same form.
            let prune = excludes.filter { !$0.contains("/") }.map { "-name \(ShellQuote.quote($0))" }.joined(separator: " -o ")
            let limit = depth > 0 ? "-maxdepth \(depth) " : ""
            let quotedRoot = ShellQuote.quote(root)
            script = """
            find \(quotedRoot) \(limit)\\( \(prune) \\) -prune -o -type d -exec sh -c 'for p; do printf "d\\t0\\t0\\t%s\\0" "$p"; done' _ {} +
            find \(quotedRoot) \(limit)\\( \(prune) \\) -prune -o ! -type d -exec sh -c 'for p; do printf "f\\t0\\t-1\\t%s\\0" "$p"; done' _ {} +
            """
        }
        guard let result = run(script, timeout: 120), result.succeeded || !result.output.isEmpty else { return }
        var reader = RemoteRecordReader()
        var found: [RemoteRecord] = []
        var partial = !result.succeeded
        for event in reader.read(result.output) {
            switch event {
            case .record(let record): found.append(record)
            case .signal(let signal): if signal == "truncated" || signal == "partial" { partial = true }
            }
        }
        // The folder itself seems to be gone, which is more often a blip than the truth.
        if let first = found.first, first.path == root, first.kind == .gone { return }
        // Only a complete answer says what isn't there. A timeout or an unreadable folder doesn't.
        apply(found, root: root, removing: removing && !partial)
    }

    /// Makes the copy of `root` match a listing. Runs on mirrorQueue.
    private func apply(_ listing: [RemoteRecord], root: String, removing: Bool) {
        let manager = FileManager.default
        let open = openFiles?() ?? []
        let localRoot = map.local(root)
        var seen = Set<String>()
        seen.reserveCapacity(listing.count)
        var existing = Set<String>()
        if removing, let walker = manager.enumerator(atPath: localRoot) {
            while let name = walker.nextObject() as? String { existing.insert(localRoot + "/" + name) }
        }
        if removing { foldedNames = foldedNames.filter { !$0.value.hasPrefix(root == "/" ? "/" : root + "/") } }
        var usable: [RemoteRecord] = []
        usable.reserveCapacity(listing.count)
        for record in listing {
            if record.kind == .gone {
                applyEvent(record, open: open)
            } else if claimName(record) {
                usable.append(record)
            }
        }
        lock.withLock {
            for record in usable { records[record.path] = record }
        }
        for record in usable {
            let local = map.local(record.path)
            seen.insert(local)
            place(record, at: local, open: open)
        }
        guard removing else { return }
        // Longest first, so a folder is empty by the time it's removed.
        for local in existing.subtracting(seen).sorted(by: { $0.count > $1.count }) {
            guard let remote = map.remote(local), !holdsPendingSave(remote), !onDemand.contains(remote), !open.contains(local) else { continue }
            lock.withLock { records[remote] = nil }
            try? manager.removeItem(atPath: local)
        }
    }

    /// One thing the server says exists, put in place here. Runs on mirrorQueue.
    private func place(_ record: RemoteRecord, at local: String, open: Set<String>) {
        var info = stat()
        let exists = lstat(local, &info) == 0
        let isFolderHere = exists && (info.st_mode & S_IFMT) == S_IFDIR
        if record.isFolder {
            if exists, !isFolderHere {
                guard pendingSaves[record.path] == nil else { return }
                unlink(local)
            }
            if !isFolderHere { mkdirs(local) }
            return
        }
        if exists, isFolderHere {
            guard !holdsPendingSave(record.path) else { return }
            try? FileManager.default.removeItem(atPath: local)
        }
        guard exists, !isFolderHere else {
            createPlaceholder(local, modified: record.modified)
            if open.contains(local), record.size != 0 { fetchQueued(local) }
            return
        }
        guard pendingSaves[record.path] == nil else { return }
        let localSize = Int64(info.st_size)
        let localModified = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
        if localSize == 0 {
            // A placeholder, unless the file really is empty, which is the same thing.
            if open.contains(local), record.size != 0 { fetchQueued(local) }
            if localModified != record.modified { setModified(local, record.modified) }
            return
        }
        if localSize == record.size, localModified == record.modified { return }
        // A plain `find` couldn't say, so there's nothing to compare.
        if record.size < 0 { return }
        if open.contains(local) {
            fetchQueued(local)
        } else {
            // Changed there, and nobody's reading it here. It comes back when someone opens it.
            _ = truncate(local, 0)
            setModified(local, record.modified)
        }
    }

    private func mkdirs(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func createPlaceholder(_ path: String, modified: Int64) {
        var fd = Darwin.open(path, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0, errno == ENOENT {
            mkdirs((path as NSString).deletingLastPathComponent)
            fd = Darwin.open(path, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { return }
        close(fd)
        setModified(path, modified)
    }

    private func setModified(_ path: String, _ modified: Int64) {
        guard modified > 0 else { return }
        var times = [timespec(tv_sec: Int(modified / 1000), tv_nsec: Int(modified % 1000) * 1_000_000),
                     timespec(tv_sec: Int(modified / 1000), tv_nsec: Int(modified % 1000) * 1_000_000)]
        utimensat(AT_FDCWD, path, &times, 0)
    }

    private func applyEvent(_ record: RemoteRecord, open: Set<String>) {
        let local = map.local(record.path)
        guard !holdsPendingSave(record.path) else { return }
        if record.kind == .gone {
            lock.withLock { records[record.path] = nil }
            foldedNames[record.path.precomposedStringWithCanonicalMapping.lowercased()] = nil
            try? FileManager.default.removeItem(atPath: local)
            return
        }
        guard claimName(record) else { return }
        lock.withLock { records[record.path] = record }
        place(record, at: local, open: open)
    }

    // MARK: Watching

    private func startWatcher() {
        queue.async { [self] in
            stopWatcher()
            guard state.isReady else { return }
            let folders: [String] = mirrorQueue.sync { roots }
            guard !folders.isEmpty else { return }
            guard let bin = binDirectory else {
                setLimited(true)
                return
            }
            let script = "exec \(helper(bin)) watch \(RemoteShell.arguments(folders)) --exclude \(ShellQuote.quote(excludeArgument))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.ssh)
            process.arguments = clientArguments(tty: false) + [destination, RemoteShell.wrap(script)]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let reader = RecordStream()
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                let events = reader.read(data)
                guard let self else { return }
                self.mirrorQueue.async { self.handleWatch(events) }
            }
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.watcherEnded(process) }
            }
            do {
                try process.run()
            } catch {
                setLimited(true)
                return
            }
            watcher = process
            watcherInput = input
        }
    }

    private final class RecordStream: @unchecked Sendable {
        private let lock = NSLock()
        private var reader = RemoteRecordReader()
        func read(_ data: Data) -> [RemoteRecordReader.Event] { lock.withLock { reader.read(data) } }
    }

    private func stopWatcher() {
        // Closing its stdin is how it knows to go.
        try? watcherInput?.fileHandleForWriting.close()
        watcherInput = nil
        if let watcher, watcher.isRunning { watcher.terminate() }
        watcher = nil
    }

    private func watcherEnded(_ process: Process) {
        guard watcher === process, state.isReady else { return }
        // Something killed it but the connection is fine. Look again, then watch again.
        watcher = nil
        rescan()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startWatcher() }
    }

    private func handleWatch(_ events: [RemoteRecordReader.Event]) {
        let open = openFiles?() ?? []
        for event in events {
            switch event {
            case .record(let record):
                applyEvent(record, open: open)
            case .signal("ready"):
                setLimited(false)
            case .signal("rescan"):
                rescan()
            case .signal("limited"):
                setLimited(true)
            case .signal("git"):
                if let onRepositoryMoved { DispatchQueue.main.async(execute: onRepositoryMoved) }
            case .signal:
                break
            }
        }
    }

    /// Without kernel watches it can't hear about changes, so it looks every so often instead.
    private func setLimited(_ value: Bool) {
        mirrorQueue.async { [self] in
            limited = value
            rescanTimer?.cancel()
            rescanTimer = nil
            guard value else { return }
            let timer = DispatchSource.makeTimerSource(queue: mirrorQueue)
            timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in
                guard let self, self.state.isReady else { return }
                for root in self.roots { self.scan(root: root, depth: 0, removing: true) }
                if let moved = self.onRepositoryMoved { DispatchQueue.main.async(execute: moved) }
            }
            rescanTimer = timer
            timer.resume()
        }
    }

    // MARK: Files

    public func record(forLocal local: String) -> RemoteRecord? {
        guard let remote = map.remote(local) else { return nil }
        return lock.withLock { records[remote] }
    }

    /// A placeholder: the file has contents on the server, and none here yet.
    public func needsFetch(_ local: String) -> Bool {
        var info = stat()
        guard lstat(local, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR, info.st_size == 0 else { return false }
        // Not listed yet, as right after a relaunch: it's worth asking.
        guard let record = record(forLocal: local) else { return true }
        return record.size != 0
    }

    /// Says what's at a path that isn't in any listing, like `/etc/hosts`, and makes room for it.
    public func learn(remote: String) -> RemoteRecord? {
        guard let bin = binDirectory else { return nil }
        let script = "\(helper(bin)) scan \(ShellQuote.quote(remote)) --depth 1 --max 0"
        guard let result = run(script, timeout: 10) else { return nil }
        var reader = RemoteRecordReader()
        var found: RemoteRecord?
        for case .record(let record) in reader.read(result.output) where record.path == remote && record.kind != .gone {
            found = record
        }
        guard let found else { return nil }
        lock.withLock { records[remote] = found }
        mirrorQueue.sync {
            onDemand.insert(remote)
            place(found, at: map.local(remote), open: [])
        }
        return found
    }

    /// Lists a folder the first scan left out, such as a linked folder, when someone opens it.
    public func list(remote: String) {
        mirrorQueue.async { [self] in scan(root: remote, depth: 1, removing: false) }
    }

    /// The folders in a folder on the server, for choosing one to open.
    public func folders(in remote: String) -> [String]? {
        let quoted = ShellQuote.quote(remote)
        let script = "cd \(quoted) 2>/dev/null || exit 3; for entry in .* *; do [ -d \"$entry\" ] && [ \"$entry\" != . ] && [ \"$entry\" != .. ] && printf '%s\\0' \"$entry\"; done; exit 0"
        guard let result = run(script, timeout: 15), result.succeeded else { return nil }
        return result.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// The real location of a folder, or nil if it isn't one.
    public func resolveFolder(_ path: String) -> String? {
        let expanded: String
        if path == "~" { expanded = home ?? path }
        else if path.hasPrefix("~/") { expanded = (home ?? "") + path.dropFirst(1) }
        else { expanded = path }
        guard let result = run("cd \(ShellQuote.quote(expanded)) 2>/dev/null && pwd -P", timeout: 15), result.succeeded else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("/") ? text : nil
    }

    /// Brings a file's contents here. Asking again while it's on its way just waits for that one.
    public func fetch(_ local: String, completion: @escaping @Sendable (Result<Void, RemoteFailure>) -> Void) {
        mirrorQueue.async { [self] in
            if inFlight[local] != nil {
                inFlight[local]!.append(completion)
                return
            }
            inFlight[local] = [completion]
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = download(local)
                mirrorQueue.async { [self] in
                    let waiting = inFlight.removeValue(forKey: local) ?? []
                    DispatchQueue.main.async { waiting.forEach { $0(result) } }
                }
            }
        }
    }

    /// For a background thread that needs these read before it can go on.
    public func fetchAndWait(_ locals: [String], timeout: TimeInterval) {
        let group = DispatchGroup()
        for local in locals {
            group.enter()
            fetch(local) { _ in group.leave() }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    private func fetchQueued(_ local: String) {
        fetch(local) { _ in }
    }

    private func download(_ local: String) -> Result<Void, RemoteFailure> {
        guard let remote = map.remote(local) else { return .failure(RemoteFailure("Not a file on this server.")) }
        guard state.isReady else { return .failure(RemoteFailure("Not connected to \(SSHConfigFile.displayName(of: destination)).")) }
        let parent = (local as NSString).deletingLastPathComponent
        mkdirs(parent)
        // Beside the copy, not in it: on the same disk so it can be renamed into place, but where the
        // tree and the watchers won't see a file that was never on the server.
        let downloads = map.localRoot + ".downloads"
        mkdirs(downloads)
        let temporary = URL(fileURLWithPath: downloads + "/" + UUID().uuidString)
        defer { unlink(temporary.path) }
        // Taken before reading, so a change while it's on its way looks like a change afterwards.
        var modified = record(forLocal: local)?.modified ?? 0
        if let bin = binDirectory,
           let listed = run("\(helper(bin)) scan \(ShellQuote.quote(remote)) --depth 1 --max 0", timeout: 15) {
            var reader = RemoteRecordReader()
            for case .record(let record) in reader.read(listed.output) where record.path == remote {
                modified = record.modified
                lock.withLock { records[remote] = record }
            }
        }
        // Well past anything worth reading here, and a server shouldn't be able to fill this disk.
        let limit: Int64 = 8 * 1024 * 1024 * 1024
        if let size = record(forLocal: local)?.size, size > limit { return .failure(RemoteFailure("That file is too big to open here.")) }
        guard let result = run("head -c \(limit) -- \(ShellQuote.quote(remote))", timeout: 3600, outputFile: temporary) else {
            return .failure(RemoteFailure("The connection went away."))
        }
        guard result.succeeded else {
            // `head: cannot open 'x' for reading: Permission denied`: only the end says anything.
            let reason = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ": ").last ?? ""
            return .failure(RemoteFailure(reason.isEmpty ? "Couldn't read it." : "Couldn't read \((local as NSString).lastPathComponent). \(reason)."))
        }
        setModified(temporary.path, modified)
        if rename(temporary.path, local) != 0 { return .failure(RemoteFailure(String(cString: strerror(errno)))) }
        return .success(())
    }

    /// Sends what's here now to the server. A save that can't get through right now stays here,
    /// and goes when the connection's back. Saves of one file go one at a time, last one last.
    public func push(_ local: String, completion: @escaping @Sendable (Result<Void, RemoteFailure>) -> Void) {
        guard let remote = map.remote(local) else {
            completion(.failure(RemoteFailure("Not a file on this server.")))
            return
        }
        mirrorQueue.async { [self] in
            if pendingSaves[remote] == nil { pendingSaves[remote] = self.record(forLocal: local)?.modified ?? 0 }
            savePending()
            if uploading.contains(remote) {
                savedAgain.insert(remote)
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            startUpload(local, remote: remote, overwriting: false, completion: completion)
        }
    }

    /// Runs on mirrorQueue.
    private func startUpload(_ local: String, remote: String, overwriting: Bool, completion: @escaping @Sendable (Result<Void, RemoteFailure>) -> Void) {
        uploading.insert(remote)
        let expected = overwriting ? nil : pendingSaves[remote]
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = upload(local, remote: remote, ifModified: expected)
            mirrorQueue.async { [self] in
                uploading.remove(remote)
                if savedAgain.remove(remote) != nil {
                    // Newer than what just went: that's the one that has to get there. The newer edit was
                    // made over this upload's result, so it isn't a conflict with it.
                    startUpload(local, remote: remote, overwriting: true, completion: completion)
                    return
                }
                var outcome = result
                switch result {
                case .success:
                    pendingSaves[remote] = nil
                case .failure(let failure):
                    if failure.description == Self.conflictMessage {
                        // Left pending and untouched here until someone decides. Nothing's been lost.
                        if let onSaveConflict { DispatchQueue.main.async { onSaveConflict(local) } }
                        outcome = .success(())
                    }
                }
                savePending()
                let count = pendingSaves.count
                if let onPendingSaves { DispatchQueue.main.async { onPendingSaves(count) } }
                let final = outcome
                DispatchQueue.main.async { completion(final) }
            }
        }
    }

    private static let conflictMessage = "changed on the server"

    private func upload(_ local: String, remote: String, ifModified expected: Int64?) -> Result<Void, RemoteFailure> {
        guard let data = FileManager.default.contents(atPath: local) else { return .failure(RemoteFailure("Couldn't read the file here.")) }
        guard state.isReady else { return .failure(RemoteFailure("Waiting for the connection.")) }
        // An empty copy of a file with contents is a placeholder, not an edit. Never send one.
        if data.isEmpty, let record = record(forLocal: local), record.size > 0, expected != nil, !savedByEditor(remote) {
            mirrorQueue.async { [self] in
                pendingSaves[remote] = nil
                savePending()
            }
            return .success(())
        }
        let script: String
        if let bin = binDirectory {
            let condition = expected.flatMap { $0 > 0 ? " --if-modified \($0)" : nil } ?? ""
            script = "\(helper(bin)) write \(ShellQuote.quote(remote)) \(data.count)\(condition)"
        } else {
            // Into a file beside it, so a dropped connection can't leave half of it in place.
            let target = ShellQuote.quote(remote)
            let temporary = ShellQuote.quote(remote + ".tiri-upload")
            script = "cat > \(temporary) && [ \"$(wc -c < \(temporary) | tr -d ' ')\" = \(data.count) ] && mv \(temporary) \(target) && printf '0 %s\\n' \(data.count)"
        }
        guard let result = run(script, stdin: data, timeout: 600) else { return .failure(RemoteFailure("The connection went away.")) }
        guard result.succeeded else {
            if result.status == 9 { return .failure(RemoteFailure(Self.conflictMessage)) }
            let reason = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 255 || result.status == 124 { return .failure(RemoteFailure("The connection went away.")) }
            return .failure(RemoteFailure(reason.isEmpty ? "The server wouldn't take it." : reason))
        }
        let words = result.text.split(separator: " ")
        if words.count == 2, let modified = Int64(words[0]), let size = Int64(words[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            if modified > 0 { setModified(local, modified) }
            lock.withLock { records[remote] = RemoteRecord(kind: .file, modified: modified, size: size, path: remote) }
        }
        return .success(())
    }

    /// A file an editor just saved empty really is empty. See `didSaveEmpty`.
    private let emptiedByEditor = EmptiedFiles()

    private final class EmptiedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func insert(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        func remove(_ path: String) -> Bool { lock.withLock { paths.remove(path) != nil } }
    }

    private func savedByEditor(_ remote: String) -> Bool { emptiedByEditor.remove(remote) }

    /// Someone emptied a file on purpose and saved it, which looks exactly like a placeholder.
    public func didSaveEmpty(_ local: String) {
        if let remote = map.remote(local) { emptiedByEditor.insert(remote) }
    }

    /// Yours replaces theirs, after someone was asked.
    public func keepMine(_ local: String) {
        guard let remote = map.remote(local) else { return }
        mirrorQueue.async { [self] in
            startUpload(local, remote: remote, overwriting: true) { _ in }
        }
    }

    /// Theirs replaces yours, after someone was asked.
    public func keepTheirs(_ local: String) {
        guard let remote = map.remote(local) else { return }
        mirrorQueue.async { [self] in
            pendingSaves[remote] = nil
            savePending()
            fetchQueued(local)
        }
    }

    /// Stored beside the copy, so a quit while it's offline doesn't lose the edit.
    private var pendingFile: String { map.localRoot + ".pending-saves.json" }

    /// Whether anything is waiting that's only here, even if it's from before this launch.
    public var hasPendingSaves: Bool {
        access(pendingFile, F_OK) == 0
    }

    private func loadPendingSaves() {
        guard let data = FileManager.default.contents(atPath: pendingFile),
              let stored = try? JSONDecoder().decode([String: Int64].self, from: data) else { return }
        pendingSaves = stored
    }

    private func savePending() {
        if pendingSaves.isEmpty {
            unlink(pendingFile)
        } else if let data = try? JSONEncoder().encode(pendingSaves) {
            try? data.write(to: URL(fileURLWithPath: pendingFile), options: .atomic)
        }
    }

    private func retryPendingSaves() {
        mirrorQueue.async { [self] in
            for remote in pendingSaves.keys where !uploading.contains(remote) {
                startUpload(map.local(remote), remote: remote, overwriting: false) { _ in }
            }
        }
    }

    // MARK: Changing things on the server

    /// Creates, renames or removes something there. The copy follows from what the server says,
    /// so it can never claim something happened that didn't.
    public func perform(_ script: String, affecting remotes: [String]) -> Result<Void, RemoteFailure> {
        guard let result = run(script, timeout: 60) else {
            return .failure(RemoteFailure("Not connected to \(SSHConfigFile.displayName(of: destination))."))
        }
        guard result.succeeded else {
            let reason = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RemoteFailure(reason.isEmpty ? "The server said no." : reason))
        }
        refresh(remotes)
        return .success(())
    }

    /// What's true of these paths right now, in full. For when the watcher can't be waited for.
    public func refresh(_ remotes: [String]) {
        guard let bin = binDirectory else {
            rescan()
            return
        }
        let group = DispatchGroup()
        group.enter()
        mirrorQueue.async { [self] in
            defer { group.leave() }
            for remote in remotes {
                let script = "\(helper(bin)) scan \(ShellQuote.quote(remote)) --exclude \(ShellQuote.quote(excludeArgument))"
                guard let result = run(script, timeout: 30) else { continue }
                var reader = RemoteRecordReader()
                var found: [RemoteRecord] = []
                var partial = !result.succeeded
                for event in reader.read(result.output) {
                    switch event {
                    case .record(let record): found.append(record)
                    case .signal(let signal): if signal == "truncated" || signal == "partial" { partial = true }
                    }
                }
                if found.isEmpty || found.first?.kind == .gone {
                    applyEvent(RemoteRecord(kind: .gone, modified: 0, size: 0, path: remote), open: [])
                } else {
                    apply(found, root: remote, removing: !partial)
                }
            }
        }
        _ = group.wait(timeout: .now() + 30)
    }
}

// MARK: - Finding the connection for a path, from anywhere

/// Paths are how everything in Tiri names a file, so a path is enough to find its server.
public final class RemoteRegistry: @unchecked Sendable {
    public static let shared = RemoteRegistry()
    private let lock = NSLock()
    private var connections: [String: RemoteConnection] = [:]
    private let mirrorRoot = RemoteMirror.root

    public func register(_ connection: RemoteConnection) {
        lock.withLock { connections[connection.destination] = connection }
    }

    public func unregister(_ destination: String) {
        lock.withLock { connections[destination] = nil }
    }

    public func connection(destination: String) -> RemoteConnection? {
        lock.withLock { connections[destination] }
    }

    public func connection(forLocal path: String) -> RemoteConnection? {
        // Almost every path is a local one, and this runs a lot.
        guard path.hasPrefix(mirrorRoot) else { return nil }
        return lock.withLock { connections.values.first { $0.map.contains(path) } }
    }

    public func isRemote(_ path: String) -> Bool { path.hasPrefix(mirrorRoot + "/") }

    /// What the path is on its server, for showing it or handing it to an agent there.
    public func displayPath(_ path: String) -> String {
        connection(forLocal: path)?.map.remote(path) ?? path
    }
}
