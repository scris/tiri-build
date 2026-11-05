import AppKit
import SwiftUI
import TiriCore

/// Starts language servers when they're of use, keeps them told about files, and stops them when
/// they've been left alone. They can be large, and there's no reason to run one nobody's asking.
final class LanguageServerHub {
    private unowned let model: AppModel

    private struct Key: Hashable {
        var server: String
        var root: String
    }

    /// A file as a server knows it. Edits are held here until a question needs them answered or
    /// typing pauses, then go in one message.
    private final class OpenDocument {
        var version = 1
        let mirror: TextMirror
        var pending: [JSONValue] = []
        var sendWhole = false

        init(text: String) {
            mirror = TextMirror(text)
        }
    }

    private final class Session {
        let key: Key
        let definition: LanguageServerDefinition
        let client: LSPClient
        let executable: String
        var isReady = false
        var canPullDiagnostics = false
        var canSearchWorkspace = false
        var hasFailed = false
        var abilities = LSP.ServerAbilities()
        /// What the server has been told, by path.
        var documents: [String: OpenDocument] = [:]
        var lastUsed = Date()
        var waiting: [CheckedContinuation<Bool, Never>] = []

        init(key: Key, definition: LanguageServerDefinition, client: LSPClient, executable: String) {
            self.key = key
            self.definition = definition
            self.client = client
            self.executable = executable
        }
    }

    enum Availability: Equatable {
        case looking
        case found(String)
        /// Only inside this project, and nobody has said yes to running it.
        case needsTrust(String)
        /// There, but it stopped before it could answer. A rustup shim for a component that isn't
        /// installed looks exactly like the real thing until it's run.
        case wontStart(String)
        case installing
        case missing
    }

    private var sessions: [Key: Session] = [:]
    /// How many viewers are showing each path, by its real path.
    private var viewers: [String: Int] = [:]
    /// For each open viewer of a path, its text if that has unsaved changes. Asked only when a
    /// server needs the whole file, so typing doesn't copy it.
    private var liveText: [String: [ObjectIdentifier: () -> String?]] = [:]
    private var editWork: [String: DispatchWorkItem] = [:]
    private var offerToasts: [String: UUID] = [:]
    private var completionToken: (client: LSPClient, token: LSPClient.RequestToken)?
    let installer = LanguageServerInstaller()
    /// Each language is offered a server once, ever.
    private let offers = LanguageServerOffers()
    private var diagnostics: [String: [LSPDiagnostic]] = [:]
    private var diagnosticsWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var located: [String: String] = [:]
    private var lookedUp = false
    private var lookup: Task<Void, Never>?
    private var failedStarts: [Key: Int] = [:]
    /// Programs that stopped before they were ready.
    private var wontStart = Set<String>()
    private var dwell: [String: DispatchWorkItem] = [:]
    private var pendingChanges = Set<String>()
    private var changesWork: DispatchWorkItem?
    private var idleTimer: Timer?

    /// Unused for this long, a server stops. Coming back to its files starts it again.
    /// `TIRI_LANGUAGE_IDLE_SECONDS` is for testing that this happens without waiting for it.
    private static let idleLimit: TimeInterval = ProcessInfo.processInfo.environment["TIRI_LANGUAGE_IDLE_SECONDS"].flatMap(TimeInterval.init) ?? 600
    /// Long enough that going through a list of files in a Peek doesn't start one for each.
    private static let dwellTime: TimeInterval = 1.5

    init(model: AppModel) {
        self.model = model
    }

    private var isEnabled: Bool { model.settings.languageServers }

    // MARK: Finding servers

    /// What the user's shell can find. A Mac app opened from Finder doesn't have their PATH.
    private struct RemoteServers: Sendable {
        var located: [String: String] = [:]
        var path: String?
    }

    /// Whether the server was actually asked and said it has none. Not knowing doesn't count.
    fileprivate func serverKnownMissing(_ definition: LanguageServerDefinition, on connection: RemoteConnection) -> Bool {
        guard connection.state.isReady, let servers = remoteLocated[connection.destination] else { return false }
        return !definition.commands.contains { $0.first.map { servers.located[$0] != nil } ?? false }
    }
    private var remoteLocated: [String: RemoteServers] = [:]

    private func locateServers() async {
        if lookedUp { return }
        if let lookup {
            await lookup.value
            return
        }
        let names = Array(Set(LanguageServerCatalog.all.flatMap { $0.commands.compactMap(\.first) } + LanguageServerInstaller.toolNames))
        let shell = model.settings.terminalShell.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : model.settings.terminalShell
        let task = Task {
            let found = await ShellLookup.locations(names: names, shell: shell)
            let path: String?
            if let known = model.userPath { path = known } else { path = await ShellLookup.path(shell: shell) }
            model.userPath = path ?? model.userPath
            located = found ?? [:]
            lookedUp = found != nil
            lookup = nil
            model.languageRevision += 1
        }
        lookup = task
        await task.value
    }

    /// Soon after launch, so that it's done before anyone asks.
    func prepare() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { await self?.locateServers() }
        }
    }

    /// For an agent asking which there are: an answer rather than "still looking".
    func waitForLocations() async {
        await locateServers()
    }

    /// Looks again, for after installing one.
    func refreshLocations() {
        lookedUp = false
        located = [:]
        remoteLocated = [:]
        wontStart = []
        failedStarts = [:]
        Task { await locateServers() }
    }

    private func command(for definition: LanguageServerDefinition, root: String) -> (executable: String, arguments: [String], isLocal: Bool)? {
        let managed = managedCommand(for: definition)
        for command in definition.commands {
            if let name = command.first, let found = located[name] {
                // One that's there but can't start, like a rustup shim, gives way to one that was added.
                if wontStart.contains(found), let managed { return managed }
                return (found, Array(command.dropFirst()), false)
            }
        }
        for folder in definition.localBins {
            for command in definition.commands {
                guard let name = command.first else { continue }
                let candidate = root + "/" + folder + "/" + name
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return (candidate, Array(command.dropFirst()), true)
                }
            }
        }
        // The last place to look: what you've found on your own always comes first.
        return managed
    }

    private func managedCommand(for definition: LanguageServerDefinition) -> (executable: String, arguments: [String], isLocal: Bool)? {
        guard let managed = definition.managed, let folder = installer.installedFolder(managed) else { return nil }
        for command in definition.commands {
            guard let name = command.first else { continue }
            let candidate = folder + "/" + managed.binaryFolder + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return (candidate, Array(command.dropFirst()), false)
            }
        }
        return nil
    }

    /// What can install things here: `uv`, `npm` or `go`, wherever your shell finds them.
    func toolPath(_ tool: ManagedServer.Tool) -> String? { located[tool.rawValue] }

    /// `roots` are the folders it might be inside. Any one of them having it will do.
    func availability(of definition: LanguageServerDefinition, roots: [String]) -> Availability {
        guard lookedUp else {
            Task { await locateServers() }
            return .looking
        }
        for root in roots.isEmpty ? ["/nonexistent"] : roots {
            guard let found = command(for: definition, root: root) else { continue }
            if wontStart.contains(found.executable) { return .wontStart(found.executable) }
            if found.isLocal, !model.languageTrust.isTrusted(found.executable) { return .needsTrust(found.executable) }
            return .found(found.executable)
        }
        if let managed = definition.managed, installer.isInstalling(managed) { return .installing }
        return .missing
    }

    private func folders() -> [String] {
        model.workspaces.flatMap(\.folders).map(Git.real)
    }

    func root(for path: String, definition: LanguageServerDefinition) -> String {
        LanguageServerCatalog.root(for: Git.real(path), definition: definition, folders: folders())
    }

    // MARK: Sessions

    /// A session for this file, if there is or can be one. `asked` means a person has just
    /// asked for something. Nothing else gets to put a question on screen.
    private func session(for path: String, asked: Bool) async -> Session? {
        guard isEnabled, let definition = LanguageServerCatalog.definition(for: path) else { return nil }
        await locateServers()
        let real = Git.real(path)
        let root = LanguageServerCatalog.root(for: real, definition: definition, folders: folders())
        let key = Key(server: definition.id, root: root)
        if let existing = sessions[key] {
            existing.lastUsed = Date()
            return existing
        }
        if let connection = RemoteRegistry.shared.connection(forLocal: path) {
            return await remoteSession(key: key, definition: definition, root: root, connection: connection)
        }
        guard (failedStarts[key] ?? 0) < 3, let found = command(for: definition, root: root) else { return nil }
        if found.isLocal, !model.languageTrust.isTrusted(found.executable) {
            guard asked, await model.confirmRunningLocalServer(found.executable, language: definition.language) else { return nil }
            guard sessions[key] == nil else { return sessions[key] }
        }
        let client = LSPClient(launch: .init(executable: found.executable, arguments: found.arguments, directory: root, path: model.userPath))
        let session = Session(key: key, definition: definition, client: client, executable: found.executable)
        client.onNotification = { [weak self] method, params in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(method, params) }
            }
        }
        client.onExit = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionExited(key) }
            }
        }
        do {
            try client.start()
        } catch {
            failedStarts[key, default: 0] += 1
            return nil
        }
        begin(session, key: key, root: root)
        return session
    }

    /// Everything after a server's process has started, wherever it's running.
    private func begin(_ session: Session, key: Key, root: String) {
        let client = session.client
        sessions[key] = session
        startIdleTimer()
        model.languageRevision += 1
        let params = LSP.initializeParams(root: root, processID: RemoteRegistry.shared.isRemote(root) ? nil : ProcessInfo.processInfo.processIdentifier)
        Task {
            // A large project can take a while to say hello.
            let answer = await client.request("initialize", params, timeout: 60)
            finishStarting(session, answer: answer)
        }
    }

    /// Servers on a server: found with its shell, and run there, with its files. A server inside
    /// the repository would be running the repository's code, so only ones on its PATH count.
    private func remoteSession(key: Key, definition: LanguageServerDefinition, root: String, connection: RemoteConnection) async -> Session? {
        guard (failedStarts[key] ?? 0) < 3, connection.state.isReady, let remoteRoot = connection.map.remote(root) else { return nil }
        let names = Array(Set(LanguageServerCatalog.all.flatMap { $0.commands.compactMap(\.first) }))
        if remoteLocated[connection.destination] == nil {
            // Nil if it didn't answer, so that next time it's asked again.
            remoteLocated[connection.destination] = await Task.detached(priority: .utility) { () -> RemoteServers? in
                guard !connection.isCShell else { return RemoteServers() }
                let script = names.filter(ShellLookup.isPlainName)
                    .map { "command -v \($0) 2>/dev/null | sed 's|^|tiri-found:\($0)=|'" }.joined(separator: "; ") + "; echo tiri-path:$PATH"
                let shell = connection.shell
                guard let result = connection.run("\(ShellQuote.quote(shell)) -l -i -c \(ShellQuote.quote(script)) 2>/dev/null", timeout: 20) else { return nil }
                var servers = RemoteServers()
                for line in result.text.split(whereSeparator: \.isNewline) {
                    if line.hasPrefix("tiri-path:") { servers.path = String(line.dropFirst(10)) }
                    guard line.hasPrefix("tiri-found:") else { continue }
                    let parts = line.dropFirst(11).split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[1].hasPrefix("/") { servers.located[String(parts[0])] = String(parts[1]) }
                }
                return servers
            }.value
            model.languageRevision += 1
        }
        guard let servers = remoteLocated[connection.destination], sessions[key] == nil else { return sessions[key] }
        guard let command = definition.commands.first(where: { $0.first.map { servers.located[$0] != nil } ?? false }),
              let name = command.first, let executable = servers.located[name] else { return nil }
        let assignment = servers.path.map { "PATH=\(ShellQuote.quote($0)) " } ?? ""
        let script = "cd \(ShellQuote.quote(remoteRoot)) && \(assignment)exec \(RemoteShell.arguments([executable] + command.dropFirst()))"
        let client = LSPClient(launch: .init(executable: connection.sshExecutable, arguments: connection.commandArguments(script: script),
                                             directory: root, path: nil, remoteMap: connection.map))
        let session = Session(key: key, definition: definition, client: client, executable: executable)
        client.onNotification = { [weak self] method, params in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(method, params) }
            }
        }
        client.onExit = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionExited(key) }
            }
        }
        do {
            try client.start()
        } catch {
            failedStarts[key, default: 0] += 1
            return nil
        }
        begin(session, key: key, root: root)
        return session
    }

    private func finishStarting(_ session: Session, answer: JSONValue?) {
        guard sessions[session.key] === session else { return }
        guard answer != nil else {
            session.hasFailed = true
            session.client.stop()
            resume(session, ready: false)
            return
        }
        session.abilities = LSP.ServerAbilities(capabilities: answer?["capabilities"])
        session.canPullDiagnostics = answer?["capabilities"]?["diagnosticProvider"] != nil
        let workspaceSymbols = answer?["capabilities"]?["workspaceSymbolProvider"]
        session.canSearchWorkspace = workspaceSymbols != nil && workspaceSymbols?.boolValue != false
        session.client.notify("initialized", .object([:]))
        session.isReady = true
        failedStarts[session.key] = nil
        model.languageRevision += 1
        for path in viewers.keys where belongs(path, to: session) {
            openDocument(path, in: session)
        }
        resume(session, ready: true)
    }

    private func resume(_ session: Session, ready: Bool) {
        let waiting = session.waiting
        session.waiting = []
        for waiter in waiting { waiter.resume(returning: ready) }
    }

    private func sessionExited(_ key: Key) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        // Crashing again and again shouldn't turn into starting again and again.
        if !session.isReady || session.hasFailed {
            failedStarts[key, default: 0] += 1
            wontStart.insert(session.executable)
        }
        resume(session, ready: false)
        model.languageRevision += 1
    }

    /// Whether it's ready, waiting no longer than this.
    private func ready(_ session: Session, within seconds: TimeInterval) async -> Bool {
        if session.isReady { return true }
        return await withCheckedContinuation { continuation in
            session.waiting.append(continuation)
            let deadline = DispatchWorkItem { [weak session] in
                guard let session, !session.isReady else { return }
                let waiting = session.waiting
                session.waiting = []
                for waiter in waiting { waiter.resume(returning: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
        }
    }

    private func startIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: min(60, Self.idleLimit / 2), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIdleServers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdleServers() {
        for (key, session) in sessions where Date().timeIntervalSince(session.lastUsed) > Self.idleLimit {
            sessions[key] = nil
            session.client.stop()
        }
        model.languageRevision += 1
        if sessions.isEmpty {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    func stopAll() {
        for session in sessions.values { session.client.stop() }
        sessions = [:]
        idleTimer?.invalidate()
        idleTimer = nil
        model.languageRevision += 1
    }

    func runningCount() -> Int { sessions.count }

    fileprivate var modelForOffers: AppModel { model }
    fileprivate func offers(claim key: String) -> Bool { offers.claim(key) }
    fileprivate var openOffers: [String: UUID] {
        get { offerToasts }
        set { offerToasts = newValue }
    }

    fileprivate func forgetFailures() {
        wontStart = []
        failedStarts = [:]
    }

    fileprivate func startForOpenFiles() {
        for path in viewers.keys {
            Task { _ = await session(for: path, asked: false) }
        }
    }

    func isRunning(_ definition: LanguageServerDefinition) -> Bool {
        sessions.values.contains { $0.definition.id == definition.id && $0.isReady }
    }

    func isStarting(_ definition: LanguageServerDefinition) -> Bool {
        sessions.values.contains { $0.definition.id == definition.id && !$0.isReady }
    }

    private func belongs(_ path: String, to session: Session) -> Bool {
        guard LanguageServerCatalog.definition(for: path)?.id == session.definition.id else { return false }
        return path.hasPrefix(session.key.root + "/")
    }

    // MARK: Documents

    /// A viewer has this file open. Servers don't start for it until it's been looked at a moment.
    /// `text` gives what it's showing, if that's not what's on disk.
    func viewerOpened(_ path: String, viewer: AnyObject, text: @escaping () -> String?) {
        let real = Git.real(path)
        viewers[real, default: 0] += 1
        liveText[real, default: [:]][ObjectIdentifier(viewer)] = text
        for session in sessions.values where session.isReady && belongs(real, to: session) {
            openDocument(real, in: session)
        }
    }

    func viewerClosed(_ path: String, viewer: AnyObject) {
        let real = Git.real(path)
        liveText[real]?[ObjectIdentifier(viewer)] = nil
        guard let count = viewers[real] else { return }
        if count > 1 {
            viewers[real] = count - 1
            return
        }
        viewers[real] = nil
        liveText[real] = nil
        dwell[real]?.cancel()
        dwell[real] = nil
        for session in sessions.values where session.documents[real] != nil {
            closeDocument(real, in: session)
        }
    }

    private func closeDocument(_ path: String, in session: Session) {
        flush(path, in: session)
        session.documents[path] = nil
        session.client.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(LSP.uri(for: path))])]))
    }

    /// In front of someone. A little later, if it's still there, a server is worth having.
    func viewerShown(_ path: String) {
        guard isEnabled, LanguageServerCatalog.definition(for: path) != nil else { return }
        let real = Git.real(path)
        for session in sessions.values where belongs(real, to: session) { session.lastUsed = Date() }
        dwell[real]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewers[real] != nil else { return }
            Task {
                let started = await self.session(for: real, asked: false)
                if started == nil { self.offerServer(for: real) }
            }
        }
        dwell[real] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellTime, execute: work)
    }

    private func text(of path: String) -> String? {
        for provider in (liveText[path] ?? [:]).values {
            if let text = provider() { return text }
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func openDocument(_ path: String, in session: Session) {
        guard session.documents[path] == nil, let text = text(of: path) else { return }
        session.documents[path] = OpenDocument(text: text)
        session.client.notify("textDocument/didOpen", .object(["textDocument": .object([
            "uri": .string(LSP.uri(for: path)), "languageId": .string(session.definition.languageID(for: path)),
            "version": 1, "text": .string(text),
        ])]))
        pullDiagnostics(path, from: session)
    }

    /// Someone typed. `range` is where in the text before, and `length` how long the text is now.
    /// Nothing is sent yet: it goes just before the next question, or when typing pauses.
    func textEdited(realPath path: String, range: NSRange, replacement: String, length: Int) {
        var anyone = false
        for session in sessions.values {
            guard let document = session.documents[path] else { continue }
            anyone = true
            let mirror = document.mirror
            // Another viewer of this file, or something missed. The whole file puts that right.
            guard NSMaxRange(range) <= mirror.length, mirror.length - range.length + (replacement as NSString).length == length else {
                document.sendWhole = true
                continue
            }
            if session.abilities.syncKind == 2, !document.sendWhole {
                document.pending.append(LSP.contentChange(range: range, text: replacement, in: mirror))
            } else {
                document.sendWhole = true
            }
            mirror.apply(range: range, replacement: replacement)
        }
        guard anyone else { return }
        editWork[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.editWork[path] = nil
            self?.flushAll(path)
        }
        editWork[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func flushAll(_ path: String) {
        for session in sessions.values { flush(path, in: session) }
    }

    /// Tells the server everything since it last heard.
    private func flush(_ path: String, in session: Session) {
        guard let document = session.documents[path], session.abilities.syncKind != 0, !document.pending.isEmpty || document.sendWhole else { return }
        document.version += 1
        var changes = document.pending
        if document.sendWhole {
            // The viewer's own text if there's any question about what the copy here says.
            if let current = text(of: path), current != document.mirror.text as String { document.mirror.replaceAll(current) }
            changes = [.object(["text": .string(document.mirror.text as String)])]
        }
        document.pending = []
        document.sendWhole = false
        session.client.notify("textDocument/didChange", .object([
            "textDocument": .object(["uri": .string(LSP.uri(for: path)), "version": .int(document.version)]),
            "contentChanges": .array(changes),
        ]))
        pullDiagnostics(path, from: session)
    }

    /// Saved, which some servers wait for before they check anything.
    func didSave(_ path: String) {
        let real = Git.real(path)
        for session in sessions.values where session.documents[real] != nil {
            flush(real, in: session)
            session.client.notify("textDocument/didSave", .object(["textDocument": .object(["uri": .string(LSP.uri(for: real))])]))
        }
    }

    /// What's on disk may have changed. Called whenever anything looks at the file again.
    func fileMayHaveChanged(_ path: String) {
        sendCurrentText(of: Git.real(path))
    }

    private func sendCurrentText(of path: String) {
        guard let text = text(of: path) else { return }
        for session in sessions.values {
            guard let document = session.documents[path], document.pending.isEmpty, document.mirror.text as String != text else { continue }
            document.mirror.replaceAll(text)
            document.sendWhole = true
            flush(path, in: session)
        }
    }

    /// Agents change a lot of files at once. Servers hear about them in one go.
    func filesChanged(_ paths: [String]) {
        guard !sessions.isEmpty else { return }
        pendingChanges.formUnion(paths.map(Git.real))
        changesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendPendingChanges() }
        changesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func sendPendingChanges() {
        let paths = pendingChanges
        pendingChanges = []
        for session in sessions.values where session.isReady {
            let mine = paths.filter { $0.hasPrefix(session.key.root + "/") && !$0.contains("/.git/") }
            guard !mine.isEmpty else { continue }
            // 2 is "changed", which is the most any server needs in order to look again.
            session.client.notify("workspace/didChangeWatchedFiles", .object(["changes": .array(mine.prefix(2000).map { path in
                .object(["uri": .string(LSP.uri(for: path)), "type": 2])
            })]))
        }
        for path in paths where viewers[path] != nil { sendCurrentText(of: path) }
    }

    // MARK: Diagnostics

    private func received(_ method: String, _ params: JSONValue?) {
        guard method == "textDocument/publishDiagnostics", let uri = params?["uri"]?.stringValue, let path = LSP.path(from: uri) else { return }
        setDiagnostics(LSP.diagnostics(from: params?["diagnostics"]), for: Git.real(path))
    }

    private func setDiagnostics(_ found: [LSPDiagnostic], for path: String) {
        let changed = diagnostics[path] != found
        diagnostics[path] = found
        for waiter in diagnosticsWaiters.removeValue(forKey: path) ?? [] { waiter.resume() }
        if changed {
            model.languageRevision += 1
            model.diagnosticsChanged(path: path)
        }
    }

    /// Servers that only answer when asked.
    private func pullDiagnostics(_ path: String, from session: Session) {
        guard session.canPullDiagnostics else { return }
        let client = session.client
        let params: JSONValue = .object(["textDocument": .object(["uri": .string(LSP.uri(for: path))])])
        client.request("textDocument/diagnostic", params, timeout: 30) { [weak self] answer in
            guard let answer, answer["kind"]?.stringValue == "full" else { return }
            let found = LSP.diagnostics(from: answer["items"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.setDiagnostics(found, for: path) }
            }
        }
    }

    /// What's known right now, for anyone who can't wait.
    func knownDiagnostics(for path: String) -> [LSPDiagnostic] {
        diagnostics[Git.real(path)] ?? []
    }

    var allKnownDiagnostics: [(path: String, diagnostics: [LSPDiagnostic])] {
        diagnostics.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// For the path, or nil and false if no server covers it. Gets it started either way, so
    /// that asking again soon has an answer. This never waits: an agent is waiting on it.
    func requestDiagnosticsSoon(for path: String) {
        let real = Git.real(path)
        Task {
            guard let session = await session(for: real, asked: false), await ready(session, within: 30) else { return }
            openDocument(real, in: session)
        }
    }

    /// For someone willing to wait: opens the file if it has to, and gives the server a little
    /// time. Nil if no server covers this file.
    func diagnostics(for path: String, waiting seconds: TimeInterval) async -> [LSPDiagnostic]? {
        let real = Git.real(path)
        guard let session = await session(for: real, asked: false), await ready(session, within: seconds) else { return nil }
        let opened = session.documents[real] == nil
        if opened {
            diagnostics[real] = nil
            openDocument(real, in: session)
        } else {
            sendCurrentText(of: real)
        }
        if diagnostics[real] == nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                diagnosticsWaiters[real, default: []].append(continuation)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, let waiting = self.diagnosticsWaiters.removeValue(forKey: real) else { return }
                    for waiter in waiting { waiter.resume() }
                }
            }
        }
        // More can follow straight after the first report, as a server finishes looking.
        try? await Task.sleep(for: .milliseconds(400))
        let found = diagnostics[real]
        // Opened only to be asked about, and no viewer wants it.
        if opened, viewers[real] == nil, session.documents[real] != nil {
            closeDocument(real, in: session)
        }
        return found ?? []
    }

    // MARK: Questions

    private func asking(_ path: String, within seconds: TimeInterval) async -> Session? {
        // Someone's waiting, and a slow shell can take seconds to say what it has. The search can
        // answer now, and by the next question this will be done.
        guard lookedUp else {
            Task { await locateServers() }
            return nil
        }
        let real = Git.real(path)
        guard let session = await session(for: real, asked: true), await ready(session, within: seconds) else { return nil }
        session.lastUsed = Date()
        openDocument(real, in: session)
        flush(real, in: session)
        return session
    }

    private func supportsNavigation(_ answer: JSONValue?) -> [SymbolLocation]? {
        let found = LSP.locations(from: answer)
        guard !found.isEmpty else { return nil }
        return found.map { place in
            let line = (try? String(contentsOfFile: place.path, encoding: .utf8))?
                .components(separatedBy: "\n").dropFirst(place.line).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SymbolLocation(path: place.path, line: place.line + 1, column: place.character + 1, text: line)
        }
    }

    /// Nil if there's nothing to ask or no answer in time, and the search can have a go.
    func definition(path: String, line: Int, character: Int) async -> [SymbolLocation]? {
        guard let session = await asking(path, within: 4) else { return nil }
        let answer = await session.client.request("textDocument/definition", LSP.textPosition(path: Git.real(path), line: line, character: character), timeout: 4)
        return supportsNavigation(answer)
    }

    func references(path: String, line: Int, character: Int) async -> [SymbolLocation]? {
        guard let session = await asking(path, within: 4) else { return nil }
        var params = LSP.textPosition(path: Git.real(path), line: line, character: character).objectValue
        params["context"] = .object(["includeDeclaration": true])
        let answer = await session.client.request("textDocument/references", .object(params), timeout: 6)
        return supportsNavigation(answer)
    }

    /// What's defined in a file. Nil if no server can say in time, and a simple reading of the text can have a go.
    func documentSymbols(path: String) async -> [DocumentSymbol]? {
        guard let session = await asking(path, within: 4) else { return nil }
        let params: JSONValue = .object(["textDocument": .object(["uri": .string(LSP.uri(for: Git.real(path)))])])
        guard let answer = await session.client.request("textDocument/documentSymbol", params, timeout: 6), answer.arrayValue != nil else { return nil }
        let found = LSP.documentSymbols(from: answer)
        // A server that hasn't finished reading the file says nothing at all.
        return found.isEmpty ? nil : found
    }

    /// Names across every server running for these folders. Nil if none of them can answer.
    func workspaceSymbols(query: String, near path: String?, folders: [String]) async -> [DocumentSymbol]? {
        if let path, LanguageServerCatalog.definition(for: path) != nil { _ = await asking(path, within: 4) }
        let roots = folders.map(Git.real)
        let asked = sessions.values.filter { session in
            session.isReady && session.canSearchWorkspace && roots.contains { session.key.root == $0 || session.key.root.hasPrefix($0 + "/") }
        }
        guard !asked.isEmpty else { return nil }
        var found: [DocumentSymbol] = []
        for session in asked {
            session.lastUsed = Date()
            let answer = await session.client.request("workspace/symbol", .object(["query": .string(query)]), timeout: 6)
            found += LSP.workspaceSymbols(from: answer)
        }
        return found
    }

    // MARK: Completion

    /// What a server is ready to do for this file right now. Never waits and never asks anyone:
    /// a server still starting just means words from the file, for now.
    func completionAbilities(for path: String) -> LSP.ServerAbilities? {
        guard isEnabled, lookedUp, let definition = LanguageServerCatalog.definition(for: path) else { return nil }
        let real = Git.real(path)
        let root = LanguageServerCatalog.root(for: real, definition: definition, folders: folders())
        guard let session = sessions[Key(server: definition.id, root: root)], session.isReady, session.abilities.completes else { return nil }
        openDocument(real, in: session)
        return session.abilities
    }

    private func readySession(for path: String) -> Session? {
        guard let definition = LanguageServerCatalog.definition(for: path) else { return nil }
        let root = LanguageServerCatalog.root(for: path, definition: definition, folders: folders())
        guard let session = sessions[Key(server: definition.id, root: root)], session.isReady else { return nil }
        return session
    }

    /// Only the newest question counts. An older one still on its way gets taken back.
    func complete(path: String, line: Int, character: Int, triggerCharacter: String?) async -> CompletionList? {
        let real = Git.real(path)
        guard let session = readySession(for: real) else { return nil }
        session.lastUsed = Date()
        openDocument(real, in: session)
        flush(real, in: session)
        if let previous = completionToken { previous.client.cancel(previous.token) }
        let token = LSPClient.RequestToken()
        completionToken = (session.client, token)
        let params = LSP.completionParams(path: real, line: line, character: character, triggerCharacter: triggerCharacter)
        guard let answer = await session.client.request("textDocument/completion", params, timeout: 5, token: token) else { return nil }
        return LSP.completions(from: answer)
    }

    /// The details a server keeps back until something's highlighted.
    func resolve(_ item: CompletionItem, path: String) async -> CompletionItem? {
        guard let session = readySession(for: Git.real(path)), session.abilities.canResolve, let raw = item.raw,
              let answer = await session.client.request("completionItem/resolve", raw, timeout: 3),
              var resolved = LSP.completionItem(answer) else { return nil }
        // Where it goes was decided when the list was made, and a server may leave that out now.
        resolved.replaceRange = resolved.replaceRange ?? item.replaceRange
        resolved.insertText = resolved.insertText ?? item.insertText
        resolved.filterText = item.filterText
        resolved.sortText = item.sortText
        return resolved
    }

    func hover(path: String, line: Int, character: Int) async -> [LSPHoverBlock] {
        guard let session = await asking(path, within: 4) else { return [] }
        let answer = await session.client.request("textDocument/hover", LSP.textPosition(path: Git.real(path), line: line, character: character), timeout: 4)
        return LSP.hover(from: answer)
    }
}

/// Which programs inside a project someone has said can run. A server in `node_modules/.bin` is
/// that project's code, and opening a folder isn't the same as agreeing to run what's in it.
// MARK: - Adding a server

/// Which languages have been offered a server. Asked once, and left alone after that.
final class LanguageServerOffers {
    private let file = TiriPaths.supportDirectory.appendingPathComponent("language-server-offers.json")
    private lazy var offered: Set<String> = {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }()

    /// True the first time only.
    func claim(_ key: String) -> Bool {
        guard offered.insert(key).inserted else { return false }
        guard let data = try? JSONEncoder().encode(offered.sorted()) else { return true }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return true
    }
}

/// Installs a server into Tiri's own folder, at the exact version and hashes that came with the
/// app. Only when someone presses the button, and never into anything of theirs.
final class LanguageServerInstaller {
    /// What it looks for along with the servers.
    static let toolNames = ["uv", "npm", "go"]

    private var running: [String: Task<String?, Never>] = [:]
    private var root: URL { TiriPaths.supportDirectory.appendingPathComponent("language-servers") }

    private func key(_ managed: ManagedServer) -> String {
        "\(managed.lock.isEmpty ? managed.title : managed.lock)-\(managed.version)"
    }

    private func folder(_ managed: ManagedServer) -> URL { root.appendingPathComponent(key(managed)) }

    /// Only once it has finished: a half-done install is the same as none.
    func installedFolder(_ managed: ManagedServer) -> String? {
        let folder = folder(managed)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path) ? folder.path : nil
    }

    func isInstalling(_ managed: ManagedServer) -> Bool { running[key(managed)] != nil }

    /// Nil if it worked, or what went wrong.
    func install(_ managed: ManagedServer, tool: String, path: String?) async -> String? {
        let key = key(managed)
        // JSON, HTML and CSS share one install. A second press waits for the same answer.
        if let underway = running[key] { return await underway.value }
        let folder = folder(managed)
        let locks = Bundle.main.resourceURL?.appendingPathComponent("language-servers/\(managed.lock)")
        let task = Task.detached(priority: .userInitiated) {
            Self.run(managed, tool: tool, path: path, folder: folder, locks: locks)
        }
        running[key] = task
        let failure = await task.value
        running[key] = nil
        return failure
    }

    nonisolated private static func run(_ managed: ManagedServer, tool: String, path: String?, folder: URL, locks: URL?) -> String? {
        let files = FileManager.default
        try? files.removeItem(at: folder)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        var environment: [String: String] = ["PATH": path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        var failure: String?
        switch managed.tool {
        case .uv:
            guard let requirements = locks?.appendingPathComponent("requirements.txt").path else { return "Its list of versions is missing." }
            failure = launch(tool, ["venv", "venv", "--python", ">=3.10", "--quiet"], in: folder, environment: environment)
                ?? launch(tool, ["pip", "install", "--python", "venv/bin/python", "--require-hashes", "--quiet", "-r", requirements], in: folder, environment: environment)
        case .npm:
            guard let locks else { return "Its list of versions is missing." }
            do {
                for name in ["package.json", "package-lock.json"] {
                    try files.copyItem(at: locks.appendingPathComponent(name), to: folder.appendingPathComponent(name))
                }
            } catch {
                return error.localizedDescription
            }
            failure = launch(tool, ["ci", "--ignore-scripts", "--no-audit", "--no-fund"], in: folder, environment: environment)
        case .go:
            guard let package = managed.package else { return "It doesn't say what to install." }
            environment["GOBIN"] = folder.appendingPathComponent("bin").path
            environment["HOME"] = NSHomeDirectory()
            failure = launch(tool, ["install", "\(package)@\(managed.version)"], in: folder, environment: environment)
        }
        if let failure {
            try? files.removeItem(at: folder)
            return failure
        }
        files.createFile(atPath: folder.appendingPathComponent(".complete").path, contents: Data())
        return nil
    }

    nonisolated private static func launch(_ tool: String, _ arguments: [String], in folder: URL, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { _, new in new }
        process.environment = merged
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        // A stalled download shouldn't look like adding it forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 900, execute: deadline)
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("hash mismatch") || lower.contains("integrity checksum failed") || lower.contains("checksum mismatch") {
            return "What was downloaded doesn't match the hash that came with Tiri, so nothing was installed."
        }
        return String(text.suffix(400)).isEmpty ? "\((tool as NSString).lastPathComponent) stopped with status \(process.terminationStatus)." : String(text.suffix(400))
    }
}

extension LanguageServerHub {
    /// The first time a language with a server to offer is opened without one.
    fileprivate func offerServer(for path: String) {
        guard let definition = LanguageServerCatalog.definition(for: path) else { return }
        let model = modelForOffers
        let remote = RemoteRegistry.shared.connection(forLocal: path)
        if let remote {
            guard serverKnownMissing(definition, on: remote) else { return }
        } else {
            guard case .missing = availability(of: definition, roots: [root(for: path, definition: definition)]) else { return }
        }
        let what = "Completion and Go to Definition."
        let title = "Add a language server for \(definition.language)?"
        // Only once there's something to say. Otherwise the one chance would go on nothing.
        if remote == nil, let managed = definition.managed, toolPath(managed.tool) != nil {
            guard offers(claim: definition.id) else { return }
            openOffers[definition.id] = model.showToast(title: title, detail: "\(what) Installs \(managed.title), \(managed.megabytes) MB.",
                                symbol: "sparkles", tint: .accentColor, actionTitle: "Add", duration: 20) { [weak self] in
                Task { await self?.add(definition) }
            }
        } else if let preset = model.runnableAgentPresets().first {
            guard offers(claim: remote.map { "\(definition.id)@\($0.destination)" } ?? definition.id) else { return }
            _ = model.showToast(title: title, detail: "\(what) \(preset.name) can install it for you.",
                                symbol: "sparkles", tint: .accentColor, actionTitle: "Ask \(preset.name)", duration: 20) {
                model.askAgentToInstall(definition, preset: preset)
            }
        }
    }

    /// Installs it, then starts it for anything already open. Says what went wrong, to whoever's
    /// waiting and on screen, or nil if it worked. `Add` and `tiri languages add` both come here.
    @discardableResult
    func add(_ definition: LanguageServerDefinition) async -> String? {
        guard let managed = definition.managed else { return "Tiri can't install this one itself." }
        let model = modelForOffers
        guard let tool = toolPath(managed.tool) else { return "It needs \(managed.tool.rawValue), which isn't on this Mac." }
        // It's been answered, whichever way it was asked.
        if let offer = openOffers.removeValue(forKey: definition.id) { model.dismissToast(offer) }
        model.languageRevision += 1
        let failure = await installer.install(managed, tool: tool, path: model.userPath)
        model.languageRevision += 1
        if let failure {
            let preset = model.runnableAgentPresets().first
            _ = model.showToast(title: "Couldn't add the \(definition.language) server", detail: failure, symbol: "exclamationmark.triangle", tint: .orange,
                                actionTitle: preset.map { "Ask \($0.name)" }) {
                if let preset { model.askAgentToInstall(definition, preset: preset) }
            }
        } else {
            _ = model.showToast(title: "\(definition.language) server added", detail: nil, symbol: "checkmark.circle", tint: .green)
            forgetFailures()
            startForOpenFiles()
        }
        return failure
    }
}

final class LanguageServerTrust {
    private let file = TiriPaths.supportDirectory.appendingPathComponent("language-server-trust.json")
    private lazy var trusted: Set<String> = {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }()

    func isTrusted(_ executable: String) -> Bool { trusted.contains(executable) }

    func trust(_ executable: String) {
        trusted.insert(executable)
        guard let data = try? JSONEncoder().encode(trusted.sorted()) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension AppModel {
    func openLanguageServerSettings() {
        openSettings()
        settingsAnchor = LanguageServersSection.anchor
    }

    /// Asked only when someone has just asked for something a server would answer.
    func confirmRunningLocalServer(_ executable: String, language: String) async -> Bool {
        guard let window else { return false }
        let project = ((executable as NSString).abbreviatingWithTildeInPath)
        let alert = NSAlert()
        alert.messageText = "Run this project's own \(language) server?"
        alert.informativeText = "\(project) came with this project, so it's the project's code. Run it only if you trust the project.\n\nWithout it, Tiri searches the files instead."
        alert.addButton(withTitle: "Run It")
        alert.addButton(withTitle: "Not Now")
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return false }
        languageTrust.trust(executable)
        languageRevision += 1
        return true
    }

    /// Every open viewer of the file redraws what's wrong with it.
    func diagnosticsChanged(path: String) {
        for workspace in workspaces {
            for item in workspace.items + (workspace.peek.map { [$0] } ?? []) {
                guard let viewer = existingController(for: item.id) as? SymbolViewing, Git.real(viewer.path) == path else { continue }
                viewer.diagnosticsChanged()
            }
        }
    }

    /// Into an agent's input, unsent: a list it can act on.
    func quoteDiagnostics(_ found: [LSPDiagnostic], path: String) {
        guard !found.isEmpty else { return }
        let lines = found.map { $0.printed(path: (path as NSString).lastPathComponent) }.joined(separator: "\n")
        let name = (path as NSString).lastPathComponent
        let text = "Problems in \(name):\n```\n\(lines)\n```\n"
        addReference(AgentSelection(path: path, quote: text))
    }

    /// Asks an agent to install what's missing. Nothing runs until you've read it and pressed Return.
    func askAgentToInstall(_ definition: LanguageServerDefinition, preset: TerminalPreset) {
        let prompt = "Please install the language server for \(definition.language), so Tiri can use it. The usual way is: \(definition.installHint). Tell me what you'll run before running it, and check that the command works afterwards."
        askAgent(preset: preset, prompt: prompt)
    }
}

extension LanguageServerHub.Availability {
    var canBeInstalled: Bool {
        switch self {
        case .missing, .wontStart: true
        default: false
        }
    }
}

// MARK: - The settings section

struct LanguageServersSection: View {
    static let anchor = "language-servers"

    @Environment(AppModel.self) private var model
    @State private var showsAll = false

    private func status(_ definition: LanguageServerDefinition, _ availability: LanguageServerHub.Availability) -> String {
        if model.languageServers.isRunning(definition) { return "Running." }
        if model.languageServers.isStarting(definition) { return "Starting…" }
        switch availability {
        case .looking: return "Looking…"
        case .found(let path): return "Found at \((path as NSString).abbreviatingWithTildeInPath). Starts when you open one of these files."
        case .needsTrust: return "Only inside this project. Tiri asks before running it."
        case .wontStart(let path): return "\((path as NSString).abbreviatingWithTildeInPath) is there, but stopped without answering. It may not be fully installed."
        case .installing: return "Adding it…"
        case .missing:
            // "Not installed" read as if the language itself were missing.
            if let managed = definition.managed, model.languageServers.toolPath(managed.tool) != nil {
                return "No language server yet. Add installs \(managed.title), \(managed.megabytes) MB."
            }
            return "No language server yet. Install: \(definition.installHint)"
        }
    }

    /// Whether there's something here worth seeing without asking for the whole list.
    private func isUsual(_ definition: LanguageServerDefinition, _ availability: LanguageServerHub.Availability) -> Bool {
        if case .missing = availability {
            return definition.managed != nil && model.languageServers.toolPath(definition.managed!.tool) != nil
        }
        return true
    }

    @ViewBuilder
    private func row(_ definition: LanguageServerDefinition, _ availability: LanguageServerHub.Availability) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(definition.language)
                Text(status(definition, availability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .installing = availability {
                ProgressView().controlSize(.small)
            } else if availability.canBeInstalled {
                if let managed = definition.managed, model.languageServers.toolPath(managed.tool) != nil {
                    Button("Add") { Task { await model.languageServers.add(definition) } }
                        .help("Installs \(managed.title) \(managed.version) into Tiri's own folder, about \(managed.megabytes) MB. Nothing outside it changes.")
                } else if let preset = model.runnableAgentPresets().first {
                    Button("Ask \(preset.name)") { model.askAgentToInstall(definition, preset: preset) }
                        .help("Prepares a request to install it: \(definition.installHint)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    var body: some View {
        let _ = model.languageRevision
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Language Servers").font(.headline)
                Spacer()
                Button("Look Again") { model.languageServers.refreshLocations() }
                    .controlSize(.small)
            }
            let roots = model.active.folders.map(Git.real)
            let rows = LanguageServerCatalog.all.map { ($0, model.languageServers.availability(of: $0, roots: roots)) }
            let usual = rows.filter { isUsual($0.0, $0.1) }
            let others = rows.filter { !isUsual($0.0, $0.1) }
            let shown = showsAll ? usual + others : usual
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.0.id) { index, entry in
                    row(entry.0, entry.1)
                    if index < shown.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            .disabled(!model.settings.languageServers)
            .opacity(model.settings.languageServers ? 1 : 0.5)
            if !others.isEmpty {
                Button(showsAll ? "Show Fewer" : "Show \(others.count) More Languages") { showsAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .id(Self.anchor)
    }
}

// MARK: - The bar along the bottom

extension AppModel {
    var frontCodePath: String? {
        guard let item = active.peek ?? active.activeItem else { return nil }
        switch item.content {
        case .file(let spec): return spec.path
        case .diff(let spec): return spec.path
        default: return nil
        }
    }

    /// A server at work, or something wrong. "No server" alone isn't worth a bar of its own.
    var languageHasNews: Bool {
        guard settings.languageServers, let path = frontCodePath, let definition = LanguageServerCatalog.definition(for: path) else { return false }
        return languageServers.isRunning(definition) || languageServers.isStarting(definition) || !languageServers.knownDiagnostics(for: path).isEmpty
    }

    var statusBarHasContent: Bool { barHasRepositories || languageHasNews || active.remote != nil }
}

struct LanguageStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.languageRevision
        if model.settings.languageServers, let path = model.frontCodePath, let definition = LanguageServerCatalog.definition(for: path) {
            let found = model.languageServers.knownDiagnostics(for: path)
            let errors = found.filter { $0.severity == .error }.count
            let warnings = found.filter { $0.severity == .warning }.count
            Button {
                model.openLanguageServerSettings()
            } label: {
                HStack(spacing: 8) {
                    if errors > 0 {
                        Label("\(errors)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    if warnings > 0 {
                        Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if model.languageServers.isStarting(definition) {
                        Text("\(definition.language): starting")
                            .foregroundStyle(.secondary)
                    } else if !model.languageServers.isRunning(definition) {
                        Text("\(definition.language): no language server")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(definition.language)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help(model.languageServers.isRunning(definition) ? "A language server is answering for this file" : "No language server is answering yet, so Go to Definition searches the files. Click to add one.")
        }
    }
}

// MARK: - Hover

/// What a name is, and anything wrong with it.
struct SymbolHoverView: View {
    let blocks: [LSPHoverBlock]
    let problems: [LSPDiagnostic]
    let onQuote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: problem.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(problem.severity == .error ? Color.red : .orange)
                    Text(problem.message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !problems.isEmpty {
                Button("Quote in Agent", action: onQuote)
                    .controlSize(.small)
                if !blocks.isEmpty { Divider() }
            }
            ForEach(Array(blocks.prefix(6).enumerated()), id: \.offset) { _, block in
                if block.isCode {
                    Text(block.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 480, alignment: .leading)
    }
}
