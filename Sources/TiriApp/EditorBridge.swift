import AppKit
import Foundation
import Network
import TiriCore
import UniformTypeIdentifiers

/// Claude Code connects to Tiri the way it connects to an editor, on this Mac only and with a
/// token only it's told, so it can see your selection and take mentions into its input.
final class EditorBridge {
    private unowned let model: AppModel
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Client] = [:]
    private var pendingSelection: DispatchWorkItem?
    private(set) var port: UInt16 = 0
    private(set) var token = ""
    private var lockURL: URL?
    var latestSelection: EditorSelection?

    private final class Client {
        let connection: NWConnection
        var pid: Int32?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(model: AppModel) {
        self.model = model
    }

    private var lockDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("ide", isDirectory: true)
    }

    /// The same port and token after a relaunch, so an agent left running can come back.
    private func restoredAddress() -> (UInt16, String) {
        let file = TiriPaths.supportDirectory.appendingPathComponent("editor-bridge")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let parts = text.split(separator: " ")
            if parts.count == 2, let port = UInt16(parts[0]), parts[1].count == 32 { return (port, String(parts[1])) }
        }
        let fresh = (UInt16.random(in: 10_000...65_000), EditorProtocol.newToken())
        try? FileManager.default.createDirectory(at: TiriPaths.supportDirectory, withIntermediateDirectories: true)
        try? "\(fresh.0) \(fresh.1)".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return fresh
    }

    func start() {
        let (savedPort, savedToken) = restoredAddress()
        token = savedToken
        for attempt in 0..<5 {
            let candidate = attempt == 0 ? savedPort : UInt16.random(in: 10_000...65_000)
            if listen(on: candidate) {
                port = candidate
                break
            }
        }
        writeLock()
    }

    private func listen(on port: UInt16) -> Bool {
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let expected = token
        // Anything else on this Mac can reach a local port. Only a holder of the token gets in.
        socket.setClientRequestHandler(.main) { subprotocols, headers in
            let authorized = headers.contains { $0.name.lowercased() == "x-claude-code-ide-authorization" && $0.value == expected }
            // A client that asks for "mcp" hangs up if it isn't given it.
            return NWProtocolWebSocket.Response(status: authorized ? .accept : .reject, subprotocol: subprotocols.first)
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        return true
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let key = ObjectIdentifier(connection)
        connections[key] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(from: client)
    }

    private func receive(from client: Client) {
        client.connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.handle(data, from: client) }
                if error == nil { self.receive(from: client) }
            }
        }
    }

    private func handle(_ data: Data, from client: Client) {
        if let pid = EditorProtocol.connectedProcess(in: data) {
            client.pid = pid
            // It should know what's selected right away, like an editor it has just met.
            if let latestSelection { send(EditorProtocol.selectionChanged(latestSelection), to: client) }
        }
        if let response = EditorProtocol.respond(to: data, host: host) {
            send(response, to: client)
        }
    }

    private var host: EditorProtocol.Host {
        EditorProtocol.Host(
            selection: { [weak self] in self?.latestSelection },
            openFiles: { [weak self] in
                guard let model = self?.model else { return [] }
                let front = model.active.activeItem?.filePath
                return model.active.items.compactMap(\.filePath).map { ($0, $0 == front) }
            },
            folders: { [weak self] in self?.model.active.folders ?? [] },
            isDirty: { [weak self] path in self?.model.fileIsDirty(path) ?? false },
            openFile: { [weak self] path in _ = self?.model.open(path: path, intent: .peek(takeFocus: false)) })
    }

    private func send(_ data: Data, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: Telling Claude

    /// Selections arrive fast while dragging. Claude only needs where they settled.
    func selectionChanged(_ selection: EditorSelection) {
        latestSelection = selection
        pendingSelection?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var shown = selection
            shown.path = Self.realPath(selection.path)
            let data = EditorProtocol.selectionChanged(shown)
            for client in self.connections.values { self.send(data, to: client) }
        }
        pendingSelection = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Sends a mention to the Claude running in this terminal. False if it isn't connected.
    func mention(path: String, firstLine: Int?, lastLine: Int?, in terminal: TerminalController) -> Bool {
        let candidates = connections.values.filter { client in
            client.pid.map(terminal.ownsProcess) ?? false
        }
        guard let client = candidates.first else { return false }
        // Claude works out how to show a path from the real one, not from a link to it.
        send(EditorProtocol.atMentioned(path: Self.realPath(path), firstLine: firstLine, lastLine: lastLine), to: client)
        return true
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: The lock file

    /// How Claude finds Tiri. It lists every workspace's folders, because any of them may have a session.
    func writeLock() {
        guard port != 0 else { return }
        let folders = Array(Set(model.workspaces.flatMap(\.folders))).sorted()
        let directory = lockDirectory
        let url = directory.appendingPathComponent("\(port).lock")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try EditorProtocol.lockFile(pid: ProcessInfo.processInfo.processIdentifier, folders: folders, token: token)
                .write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lockURL = url
        } catch {
            lockURL = nil
        }
    }

    func stop() {
        listener?.cancel()
        if let lockURL { try? FileManager.default.removeItem(at: lockURL) }
    }
}

// MARK: - Adding things to an agent

extension AppModel {
    /// The agent you've most recently been working with in this workspace.
    func agentTerminal() -> (TerminalController, AgentReference.Agent)? {
        var ordered: [Item] = []
        if let last = lastAgentTerminal, let item = active.item(last) { ordered.append(item) }
        ordered += active.items
        for item in ordered {
            guard case .terminal(let spec) = item.content, let terminal = existingController(for: item.id) as? TerminalController,
                  let agent = AgentReference.agent(commandLine: terminal.foregroundCommandLine, command: spec.command) else { continue }
            return (terminal, agent)
        }
        return nil
    }

    private func requireAgent() -> (TerminalController, AgentReference.Agent)? {
        if let found = agentTerminal() { return found }
        showToast(title: "No agent is running in this workspace", detail: "Start Claude Code or Codex from the + button, then add this again.",
                  symbol: "sparkles", tint: .secondary)
        return nil
    }

    /// ⌘L: the lines you've selected, or the whole file in front.
    func addFrontToAgent() {
        guard let item = active.peek ?? active.activeItem else { return }
        let controller = existingController(for: item.id)
        if let reference = controller?.agentReference {
            addReference(reference)
            return
        }
        guard case .file(let spec) = item.content else {
            showToast(title: "There's nothing to add from here", detail: "Open a file, then press ⌘L.", symbol: "sparkles", tint: .secondary)
            return
        }
        addFilesToAgent([spec.path])
    }

    private func addReference(_ reference: AgentSelection) {
        guard let (terminal, agent) = requireAgent() else { return }
        focusAgent(terminal)
        if let quote = reference.quote {
            terminal.send(text: AgentReference.bracketedPaste(quote))
            return
        }
        if agent == .claude,
           editorBridge.mention(path: reference.path, firstLine: reference.firstLine, lastLine: reference.lastLine, in: terminal) {
            return
        }
        terminal.send(text: AgentReference.text(path: EditorBridge.realPath(reference.path), cwd: EditorBridge.realPath(terminal.currentDirectory),
                                                firstLine: reference.firstLine, lastLine: reference.lastLine, agent: agent))
    }

    func addFilesToAgent(_ paths: [String]) {
        guard !paths.isEmpty, let (terminal, agent) = requireAgent() else { return }
        focusAgent(terminal)
        insert(paths, into: terminal, agent: agent)
    }

    /// Images go in as a paste, which agents take as the image. Other files become mentions.
    func insert(_ paths: [String], into terminal: TerminalController, agent: AgentReference.Agent) {
        for path in paths {
            if AgentReference.isImage(path: path) {
                terminal.send(text: AgentReference.bracketedPaste(path) + " ")
            } else if agent == .claude, editorBridge.mention(path: path, firstLine: nil, lastLine: nil, in: terminal) {
                continue
            } else {
                terminal.send(text: AgentReference.text(path: EditorBridge.realPath(path), cwd: EditorBridge.realPath(terminal.currentDirectory),
                                                        firstLine: nil, lastLine: nil, agent: agent))
            }
        }
    }

    private func focusAgent(_ terminal: TerminalController) {
        if active.peek != nil { dismissPeek(restoreFocus: false) }
        focusItem(terminal.itemID)
    }

    /// The paperclip: pick files or images to add.
    func chooseFilesForAgent() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or images to add to your agent"
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.addFilesToAgent(panel.urls.map(\.path))
            }
        }
    }

    /// A picture on the clipboard has no path of its own, so it gets one.
    func savePastedImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("Tiri/Pasted Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A week is plenty for an agent to have read it.
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < week { try? FileManager.default.removeItem(at: old) }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = directory.appendingPathComponent("pasted-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    func fileIsDirty(_ path: String) -> Bool {
        guard let item = (active.items + (active.peek.map { [$0] } ?? [])).first(where: { $0.filePath == path }) else { return false }
        return existingController(for: item.id)?.isDirty ?? false
    }
}

/// What an item has selected, for ⌘L.
struct AgentSelection {
    var path: String
    var firstLine: Int?
    var lastLine: Int?
    /// Text from something without lines, like a PDF, goes in as a quotation.
    var quote: String?
}
