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

    private final class Session {
        let key: Key
        let definition: LanguageServerDefinition
        let client: LSPClient
        let executable: String
        var isReady = false
        var canPullDiagnostics = false
        var hasFailed = false
        /// Path to what the server was last told it says.
        var documents: [String: (version: Int, text: String)] = [:]
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
        case missing
    }

    private var sessions: [Key: Session] = [:]
    /// How many viewers are showing each path, by its real path.
    private var viewers: [String: Int] = [:]
    /// Text that hasn't been saved, which is what the server should be looking at.
    private var unsaved: [String: String] = [:]
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
    private var remoteLocated: [String: RemoteServers] = [:]

    private func locateServers() async {
        if lookedUp { return }
        if let lookup {
            await lookup.value
            return
        }
        let names = Array(Set(LanguageServerCatalog.all.flatMap { $0.commands.compactMap(\.first) }))
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
        wontStart = []
        failedStarts = [:]
        Task { await locateServers() }
    }

    private func command(for definition: LanguageServerDefinition, root: String) -> (executable: String, arguments: [String], isLocal: Bool)? {
        for command in definition.commands {
            if let name = command.first, let found = located[name] {
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
        return nil
    }

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
            remoteLocated[connection.destination] = await Task.detached(priority: .utility) { () -> RemoteServers in
                let script = names.filter(ShellLookup.isPlainName)
                    .map { "command -v \($0) 2>/dev/null | sed 's|^|tiri-found:\($0)=|'" }.joined(separator: "; ") + "; echo tiri-path:$PATH"
                let shell = connection.shell
                guard let result = connection.run("\(ShellQuote.quote(shell)) -l -i -c \(ShellQuote.quote(script)) 2>/dev/null", timeout: 20) else { return RemoteServers() }
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
        session.canPullDiagnostics = answer?["capabilities"]?["diagnosticProvider"] != nil
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

    func isRunning(_ definition: LanguageServerDefinition) -> Bool {
        sessions.values.contains { $0.definition.id == definition.id && $0.isReady }
    }

    func isStarting(_ definition: LanguageServerDefinition) -> Bool {
        sessions.values.contains { $0.definition.id == definition.id && !$0.isReady }
    }

    private func belongs(_ path: String, to session: Session) -> Bool {
        guard session.definition.extensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        return path.hasPrefix(session.key.root + "/")
    }

    // MARK: Documents

    /// A viewer has this file open. Servers don't start for it until it's been looked at a moment.
    func viewerOpened(_ path: String) {
        let real = Git.real(path)
        viewers[real, default: 0] += 1
        for session in sessions.values where session.isReady && belongs(real, to: session) {
            openDocument(real, in: session)
        }
    }

    func viewerClosed(_ path: String) {
        let real = Git.real(path)
        guard let count = viewers[real] else { return }
        if count > 1 {
            viewers[real] = count - 1
            return
        }
        viewers[real] = nil
        unsaved[real] = nil
        dwell[real]?.cancel()
        dwell[real] = nil
        for session in sessions.values where session.documents[real] != nil {
            session.documents[real] = nil
            session.client.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(LSP.uri(for: real))])]))
        }
    }

    /// In front of someone. A little later, if it's still there, a server is worth having.
    func viewerShown(_ path: String) {
        guard isEnabled, LanguageServerCatalog.definition(for: path) != nil else { return }
        let real = Git.real(path)
        for session in sessions.values where belongs(real, to: session) { session.lastUsed = Date() }
        dwell[real]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewers[real] != nil else { return }
            Task { _ = await self.session(for: real, asked: false) }
        }
        dwell[real] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellTime, execute: work)
    }

    private func text(of path: String) -> String? {
        unsaved[path] ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    private func openDocument(_ path: String, in session: Session) {
        guard session.documents[path] == nil, let text = text(of: path) else { return }
        session.documents[path] = (1, text)
        session.client.notify("textDocument/didOpen", .object(["textDocument": .object([
            "uri": .string(LSP.uri(for: path)), "languageId": .string(session.definition.languageID(for: path)),
            "version": 1, "text": .string(text),
        ])]))
        pullDiagnostics(path, from: session)
    }

    /// The text in a viewer changed, by someone typing. Nil means it's back to what's on disk.
    func unsavedText(_ text: String?, for path: String) {
        let real = Git.real(path)
        unsaved[real] = text
        sendCurrentText(of: real)
    }

    /// What's on disk may have changed. Called whenever anything looks at the file again.
    func fileMayHaveChanged(_ path: String) {
        sendCurrentText(of: Git.real(path))
    }

    private func sendCurrentText(of path: String) {
        guard let text = text(of: path) else { return }
        for session in sessions.values {
            guard let document = session.documents[path], document.text != text else { continue }
            let version = document.version + 1
            session.documents[path] = (version, text)
            session.client.notify("textDocument/didChange", .object([
                "textDocument": .object(["uri": .string(LSP.uri(for: path)), "version": .int(version)]),
                "contentChanges": .array([.object(["text": .string(text)])]),
            ]))
            pullDiagnostics(path, from: session)
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
        for path in paths where viewers[path] != nil && unsaved[path] == nil { sendCurrentText(of: path) }
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
            session.documents[real] = nil
            session.client.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(LSP.uri(for: real))])]))
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

    func hover(path: String, line: Int, character: Int) async -> [LSPHoverBlock] {
        guard let session = await asking(path, within: 4) else { return [] }
        let answer = await session.client.request("textDocument/hover", LSP.textPosition(path: Git.real(path), line: line, character: character), timeout: 4)
        return LSP.hover(from: answer)
    }
}

/// Which programs inside a project someone has said can run. A server in `node_modules/.bin` is
/// that project's code, and opening a folder isn't the same as agreeing to run what's in it.
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
    @Environment(AppModel.self) private var model

    private func status(_ definition: LanguageServerDefinition, _ availability: LanguageServerHub.Availability) -> String {
        if model.languageServers.isRunning(definition) { return "Running." }
        if model.languageServers.isStarting(definition) { return "Starting…" }
        switch availability {
        case .looking: return "Looking…"
        case .found(let path): return "Found at \((path as NSString).abbreviatingWithTildeInPath). Starts when you open one of these files."
        case .needsTrust: return "Only inside this project. Tiri asks before running it."
        case .wontStart(let path): return "\((path as NSString).abbreviatingWithTildeInPath) is there, but stopped without answering. It may not be fully installed."
        case .missing: return "Not installed. Go to Definition searches the files instead."
        }
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
            VStack(spacing: 0) {
                let roots = model.active.folders.map(Git.real)
                ForEach(LanguageServerCatalog.all) { definition in
                    let availability = model.languageServers.availability(of: definition, roots: roots)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(definition.language)
                            Text(status(definition, availability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if availability.canBeInstalled, let preset = model.runnableAgentPresets().first {
                            Button("Ask \(preset.name)") { model.askAgentToInstall(definition, preset: preset) }
                                .help("Prepares a request to install it: \(definition.installHint)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    if definition.id != LanguageServerCatalog.all.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            .disabled(!model.settings.languageServers)
            .opacity(model.settings.languageServers ? 1 : 0.5)
        }
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
                model.openSettings()
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
                        Text("\(definition.language): searching files")
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
            .help(model.languageServers.isRunning(definition) ? "A language server is answering for this file" : "No language server is answering yet, so Go to Definition searches the files. Open Settings to see more.")
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
