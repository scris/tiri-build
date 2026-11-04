import AppKit
import Foundation
import Network
import TiriCore
import UniformTypeIdentifiers
import WebKit

/// Claude Code connects to Tiri the way it connects to an editor, on this Mac only and with a
/// token only it's told, so it can see your selection and take mentions into its input.
final class EditorBridge {
    private unowned let model: AppModel
    private var listener: NWListener?
    private var portAttempts = 0
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
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard case .failed(let error) = state, let self, self.listener === listener else { return }
                NSLog("Tiri's editor bridge couldn't use port \(port): \(error)")
                self.listenOnAnotherPort(after: port)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        return true
    }

    /// The port the last run used can be taken by now, and only trying it can tell. That's found
    /// out after starting, and Claude can't find Tiri until the lock file names one that works.
    private func listenOnAnotherPort(after failed: UInt16) {
        listener?.cancel()
        listener = nil
        if let lockURL { try? FileManager.default.removeItem(at: lockURL) }
        lockURL = nil
        portAttempts += 1
        guard portAttempts < 8 else { return }
        let candidate = UInt16.random(in: 10_000...65_000)
        guard listen(on: candidate) else { return }
        port = candidate
        writeLock()
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
            diagnostics: { [weak self] uri in self?.diagnostics(uri: uri) ?? [] },
            openFiles: { [weak self] in
                guard let model = self?.model else { return [] }
                let front = model.active.activeItem?.filePath
                return model.active.items.compactMap(\.filePath).map { (RemoteRegistry.shared.displayPath($0), $0 == front) }
            },
            folders: { [weak self] in (self?.model.active.folders ?? []).map { RemoteRegistry.shared.displayPath($0) } },
            isDirty: { [weak self] path in
                guard let self else { return false }
                return self.model.fileIsDirty(self.localPath(path))
            },
            openFile: { [weak self] path in
                guard let self else { return }
                _ = self.model.open(path: self.localPath(path), intent: .peek(takeFocus: false))
            })
    }

    /// A path from an agent on a server, as this Mac knows it. An agent here says what it means.
    private func localPath(_ path: String) -> String {
        guard !RemoteRegistry.shared.isRemote(path), !FileManager.default.fileExists(atPath: path), let connection = model.activeConnection else { return path }
        return connection.map.local(path)
    }

    /// Claude can ask around each edit, and an edit shouldn't wait for a server to start. It gets
    /// what's known, and asking gets the server going for next time.
    private func diagnostics(uri: String?) -> [(path: String, diagnostics: [LSPDiagnostic])] {
        let hub = model.languageServers
        guard let uri, var path = LSP.path(from: uri) else {
            return hub.allKnownDiagnostics.map { (RemoteRegistry.shared.displayPath($0.path), $0.diagnostics) }
        }
        path = localPath(path)
        hub.requestDiagnosticsSoon(for: path)
        return [(path, hub.knownDiagnostics(for: path))]
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
        // A path on a server is the one that means something to an agent there.
        if let connection = RemoteRegistry.shared.connection(forLocal: path), let remote = connection.map.remote(path) { return remote }
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: The lock file

    /// How Claude finds Tiri. It lists every workspace's folders, because any of them may have a session.
    func writeLock() {
        guard port != 0 else { return }
        // Folders on servers go in a lock file on that server.
        let folders = Array(Set(model.workspaces.filter { $0.remote == nil }.flatMap(\.folders))).sorted()
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
    /// Every agent running in a terminal right now, in any workspace: the one you last used, then
    /// this workspace's, then the rest.
    func activeAgentSessions() -> [AgentSession] {
        var sessions: [AgentSession] = []
        for workspace in workspaces {
            for item in workspace.items {
                guard case .terminal(let spec) = item.content else { continue }
                // An agent in a workspace not visited since Tiri relaunched is still running.
                if existingController(for: item.id) == nil, TerminalSessions.isAlive(item.id) {
                    (controller(for: item.id) as? TerminalController)?.startIfNeeded(fallbackSize: true)
                }
                guard let terminal = existingController(for: item.id) as? TerminalController,
                      terminal.isRunning, let agent = AgentReference.agent(commandLine: terminal.foregroundCommandLine, command: spec.command, custom: customAgentNames) else { continue }
                sessions.append(AgentSession(terminal: terminal, agent: agent, item: item, workspace: workspace))
            }
        }
        func rank(_ session: AgentSession) -> Int {
            if session.item.id == lastAgentTerminal { return 0 }
            return session.workspace.id == activeID ? 1 : 2
        }
        return sessions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Whatever else is in the New Terminal menu counts as an agent you can hand things to.
    var customAgentNames: Set<String> {
        Set(settings.terminalPresets.compactMap { preset -> String? in
            guard let name = preset.command.split(separator: " ").first.map(String.init),
                  AgentCatalog.profile(executable: name) == nil else { return nil }
            return (name as NSString).lastPathComponent.lowercased()
        })
    }

    /// With one agent running there's nothing to ask. With several, you choose.
    func withAgent(asking question: String, _ deliver: @escaping (TerminalController, AgentReference.Agent) -> Void) {
        let sessions = activeAgentSessions()
        guard let first = sessions.first else {
            showToast(title: "No agent is running", detail: "Start one from the + button, then try again.",
                      symbol: "sparkles", tint: .secondary)
            return
        }
        guard sessions.count > 1 else {
            deliver(first.terminal, first.agent)
            return
        }
        let rows = sessions.map { session in
            let name = session.agent.title
            let status = runtimes[session.item.id]?.status.rawValue ?? "idle"
            return PaletteModel.Row(id: session.item.id, title: name + " · " + title(for: session.item),
                                    detail: session.workspace.name + " · " + status,
                                    symbol: session.agent.profile?.symbol ?? "terminal") { [weak self] _ in
                self?.closePalette(restoreFocus: false)
                deliver(session.terminal, session.agent)
            }
        }
        openPalette(.choices(title: question, rows: rows))
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

    func addReference(_ reference: AgentSelection) {
        withAgent(asking: "Which session should get \(reference.shortDescription)?") { [weak self] terminal, agent in
            self?.deliver(reference, to: terminal, agent: agent)
        }
    }

    private func deliver(_ reference: AgentSelection, to terminal: TerminalController, agent: AgentReference.Agent) {
        focusAgent(terminal)
        if let quote = reference.quote {
            terminal.send(text: AgentReference.bracketedPaste(quote))
            return
        }
        if agent.profile?.speaksEditorProtocol == true,
           editorBridge.mention(path: reference.path, firstLine: reference.firstLine, lastLine: reference.lastLine, in: terminal) {
            return
        }
        terminal.send(text: AgentReference.text(path: EditorBridge.realPath(reference.path), cwd: EditorBridge.realPath(terminal.currentDirectory),
                                                firstLine: reference.firstLine, lastLine: reference.lastLine, agent: agent))
    }

    func addFilesToAgent(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        withAgent(asking: "Which session should get \(what)?") { [weak self] terminal, agent in
            self?.focusAgent(terminal)
            self?.insert(paths, into: terminal, agent: agent)
        }
    }

    /// Images go in as a paste, which agents take as the image. Other files become mentions.
    func insert(_ paths: [String], into terminal: TerminalController, agent: AgentReference.Agent) {
        if let destination = terminal.remoteDestination, paths.contains(where: { remote.existingConnection(destination)?.map.contains($0) != true || !$0.hasPrefix("/") }) {
            remote.serverPaths(for: paths, on: destination) { [weak self] mapped in self?.insertOnServer(mapped, into: terminal, agent: agent) }
            return
        }
        for path in paths {
            if AgentReference.isImage(path: path) {
                terminal.send(text: AgentReference.bracketedPaste(path) + " ")
            } else if agent.profile?.speaksEditorProtocol == true, editorBridge.mention(path: path, firstLine: nil, lastLine: nil, in: terminal) {
                continue
            } else {
                terminal.send(text: AgentReference.text(path: EditorBridge.realPath(path), cwd: EditorBridge.realPath(terminal.currentDirectory),
                                                        firstLine: nil, lastLine: nil, agent: agent))
            }
        }
    }

    func focusAgent(_ terminal: TerminalController) {
        lastAgentTerminal = terminal.itemID
        if active.peek != nil { dismissPeek(restoreFocus: false) }
        focusItem(terminal.itemID)
    }

    /// The paperclip: pick files or images to add.
    /// Named as they are on the server now, so they go in as they are.
    private func insertOnServer(_ paths: [String], into terminal: TerminalController, agent: AgentReference.Agent) {
        for path in paths {
            if AgentReference.isImage(path: path) {
                terminal.send(text: AgentReference.bracketedPaste(path) + " ")
            } else if agent.profile?.speaksEditorProtocol == true, editorBridge.mention(path: path, firstLine: nil, lastLine: nil, in: terminal) {
                continue
            } else {
                terminal.send(text: AgentReference.text(path: path, cwd: EditorBridge.realPath(terminal.currentDirectory), firstLine: nil, lastLine: nil, agent: agent))
            }
        }
    }

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
    /// Text that isn't simply lines of the file as it stands, like a PDF's or a diff's, goes in as a quotation.
    var quote: String?

    var shortDescription: String {
        let name = (path as NSString).lastPathComponent
        guard let firstLine else { return quote == nil ? name : "this from \(name)" }
        let count = (lastLine ?? firstLine) - firstLine + 1
        return count == 1 ? "line \(firstLine + 1) of \(name)" : "\(count) lines of \(name)"
    }
}

struct AgentSession {
    var terminal: TerminalController
    var agent: AgentReference.Agent
    var item: Item
    var workspace: Workspace
}

/// The small button that appears by what you've selected, in a file or a diff.
final class QuoteButton: NSButton {
    private weak var textView: NSTextView?
    private weak var host: NSView?
    private var observers: [NSObjectProtocol] = []
    /// Beside it, for keeping a remark for later rather than sending this now.
    private let commentButton = NSButton(title: "", target: nil, action: nil)
    var onQuote: (() -> Void)?

    override var isHidden: Bool {
        didSet { commentButton.isHidden = isHidden }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        commentButton.setFrameOrigin(NSPoint(x: newOrigin.x - commentButton.frame.width - 6, y: newOrigin.y))
    }

    convenience init(textView: NSTextView, scrollView: NSScrollView, host: NSView) {
        self.init(host: host)
        self.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: reposition))
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main, using: reposition))
    }

    /// For a web view, which reports where its selection is rather than being asked.
    convenience init(host: NSView) {
        self.init(title: "", target: nil, action: nil)
        self.host = host
        target = self
        action = #selector(pressed)
        // Solid, because it sits over code and has to stay readable.
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        attributedTitle = NSAttributedString(string: "Quote in Agent  ⌘L", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white,
        ])
        isHidden = true
        sizeToFit()
        setFrameSize(NSSize(width: frame.width + 18, height: 22))
        toolTip = "Add this selection to your agent's input"
        host.addSubview(self)
        commentButton.isBordered = false
        commentButton.wantsLayer = true
        commentButton.layer?.cornerRadius = 6
        commentButton.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        commentButton.layer?.borderWidth = 1
        commentButton.layer?.borderColor = NSColor.separatorColor.cgColor
        commentButton.attributedTitle = NSAttributedString(string: "Comment  ⌥⌘L", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        commentButton.sizeToFit()
        commentButton.setFrameSize(NSSize(width: commentButton.frame.width + 18, height: 22))
        commentButton.toolTip = "Keep a comment on this for your next batch to the agent"
        commentButton.target = self
        commentButton.action = #selector(commentPressed)
        commentButton.isHidden = true
        host.addSubview(commentButton)
    }

    @objc private func commentPressed() { AppModel.shared.beginReviewComment() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Layer colors are fixed when they're set, and outside a window they resolve against the
    /// Mac's appearance, not the app's. Set again whenever it's shown.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            commentButton.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            commentButton.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// A distance from the top of the host, in a view whose own coordinates are ignored.
    func show(fromTop top: CGFloat) {
        guard let host else { return }
        let y = host.isFlipped ? top : host.bounds.height - top - frame.height
        setFrameOrigin(NSPoint(x: max(host.bounds.width - frame.width - 18, 8),
                               y: min(max(y, 4), max(host.bounds.height - frame.height - 4, 4))))
        applyColors()
        isHidden = false
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    @objc private func pressed() { onQuote?() }

    /// Just above the selection, inside the pane. Off screen with its selection, it hides.
    func update() {
        guard let textView, let host, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            isHidden = true
            return
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerInset.height
        rect.origin.x += textView.textContainerInset.width
        let visible = textView.visibleRect
        guard rect.intersects(visible) else {
            isHidden = true
            return
        }
        // At the pane's right edge, level with the start of the selection, where it covers the least.
        let top = max(rect.minY, visible.minY)
        let anchor = textView.convert(NSPoint(x: 0, y: top), to: host)
        let size = frame.size
        var y = host.isFlipped ? anchor.y : anchor.y - size.height
        y = min(max(y, 4), max(host.bounds.height - size.height - 4, 4))
        // At the right of its own column, when there are two, and not over the other one.
        let right = textView.enclosingScrollView.map { $0.convert($0.bounds, to: host).maxX } ?? host.bounds.width
        setFrameOrigin(NSPoint(x: max(right - size.width - 18, 8), y: y))
        applyColors()
        isHidden = false
    }
}

// MARK: - Selections in web views

/// Tells Tiri what's selected in a web view, and where. It runs apart from the page's own
/// scripts, which can't see it or pretend to be it, and it works with page scripts turned off.
enum WebSelectionScript {
    static let handlerName = "tiriSelection"

    static let source = """
    (function () {
      let pending = null;
      // A selection inside a shadow root is invisible to the plain API, and one reaching into it
      // has no ranges at all. Notebook HTML outputs are in shadow roots, so ends are found the
      // composed way.
      function ends(selection) {
        const hosts = document.querySelectorAll('.nb-html');
        if (hosts.length && selection.getComposedRanges) {
          const shadowRoots = Array.from(hosts, host => host.shadowRoot).filter(Boolean);
          const composed = selection.getComposedRanges({ shadowRoots })[0];
          if (composed && !composed.collapsed) return composed;
        }
        return selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
      }
      function acrossRoots(found) {
        let text = '';
        let on = false;
        let done = false;
        let preformatted = 0;
        const blocks = /^(P|DIV|LI|PRE|TR|H[1-6]|BLOCKQUOTE|SECTION|TABLE|FIGURE)$/;
        const noText = /^(DIV|SECTION|MAIN|BODY|TABLE|THEAD|TBODY|TR|UL|OL|BLOCKQUOTE|#document-fragment)$/;
        function visit(node) {
          if (done) return;
          if (node === found.startContainer) on = true;
          if (node.nodeType === 3) {
            if (on) {
              let piece = node.data.slice(node === found.startContainer ? found.startOffset : 0, node === found.endContainer ? found.endOffset : undefined);
              if (!preformatted) {
                piece = piece.replace(/\\s+/g, ' ');
                if (piece === ' ' && noText.test(node.parentNode.nodeName)) piece = '';
              }
              text += piece;
            }
            if (node === found.endContainer) done = true;
            return;
          }
          if (node.nodeType !== 1 || node.tagName === 'STYLE' || node.tagName === 'SCRIPT') return;
          if (node.dataset && node.dataset.tex !== undefined) {
            // All of it or none of it, wherever in its glyphs the selection starts or ends.
            if (node.contains(found.startContainer)) on = true;
            if (on) text += node.dataset.tex;
            if (node.contains(found.endContainer)) done = true;
          } else {
            if (node.tagName === 'PRE') preformatted += 1;
            for (const child of (node.shadowRoot || node).childNodes) visit(child);
            if (node.tagName === 'PRE') preformatted -= 1;
          }
          if (on && !done) {
            if (blocks.test(node.tagName)) text += '\\n';
            if (node.tagName === 'TD' || node.tagName === 'TH') text += '\\t';
          }
          if (node === found.endContainer) done = true;
        }
        visit(document.body);
        return text.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
      }
      // Rendered math is a pile of positioned glyphs. As text it's what was written.
      function selectedText(selection) {
        const found = selection && ends(selection);
        if (!found) return '';
        if (document.querySelector('.nb-html')) return acrossRoots(found);
        const around = found.commonAncestorContainer;
        const element = around.nodeType === 1 ? around : around.parentElement;
        const inside = element && element.closest('[data-tex]');
        if (inside) return inside.dataset.tex;
        return document.querySelector('[data-tex]') ? acrossRoots(found) : selection.toString();
      }
      document.addEventListener('copy', function (event) {
        if (!document.querySelector('[data-tex],.nb-html')) return;
        const text = selectedText(window.getSelection());
        if (!text) return;
        event.clipboardData.setData('text/plain', text);
        event.preventDefault();
      });
      function elementOf(node) { return node.nodeType === 1 ? node : node.parentElement; }
      function report() {
        pending = null;
        const selection = window.getSelection();
        const text = selectedText(selection);
        if (!text.trim()) {
          window.webkit.messageHandlers.tiriSelection.postMessage({ empty: true });
          return;
        }
        const found = ends(selection);
        let box;
        if (found.startContainer.getRootNode() === found.endContainer.getRootNode()) {
          const range = document.createRange();
          range.setStart(found.startContainer, found.startOffset);
          range.setEnd(found.endContainer, found.endOffset);
          box = range.getBoundingClientRect();
        } else {
          box = { top: elementOf(found.startContainer).getBoundingClientRect().top, bottom: elementOf(found.endContainer).getBoundingClientRect().bottom };
        }
        function block(node) {
          let element = elementOf(node);
          while (element && !(element.dataset && element.dataset.line !== undefined)) {
            element = element.parentElement || element.getRootNode().host;
          }
          return element;
        }
        const first = block(found.startContainer);
        const last = block(found.endContainer);
        window.webkit.messageHandlers.tiriSelection.postMessage({
          text: text.slice(0, 20000), top: box.top, bottom: box.bottom, height: window.innerHeight,
          line: first ? Number(first.dataset.line) : -1,
          lineEnd: last ? Number(last.dataset.lineEnd) : -1
        });
      }
      function soon() { if (pending === null) pending = setTimeout(report, 60); }
      document.addEventListener('selectionchange', soon);
      window.addEventListener('scroll', soon, { passive: true, capture: true });
      window.addEventListener('resize', soon);
    })();
    """

    /// Selects from one piece of text to the end of another, from the top of the page.
    static func selecting(_ start: String, to end: String?) -> String {
        func quoted(_ text: String) -> String {
            let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return """
        (function () {
          const selection = window.getSelection();
          selection.removeAllRanges();
          if (!window.find(\(quoted(start)), false, false, true)) return false;
          const endText = \(end.map(quoted) ?? "null");
          if (endText === null) return true;
          const first = selection.getRangeAt(0).cloneRange();
          if (!window.find(endText, false, false, true)) return false;
          const last = selection.getRangeAt(0);
          const whole = document.createRange();
          whole.setStart(first.startContainer, first.startOffset);
          whole.setEnd(last.endContainer, last.endOffset);
          selection.removeAllRanges();
          selection.addRange(whole);
          return true;
        })();
        """
    }
}

struct WebSelection {
    var text: String
    var line: Int
    var lineEnd: Int
}

/// A web view that tells its owner about selections, and offers to quote them on right-click.
final class TiriWebView: WKWebView, WKScriptMessageHandler {
    var selection: WebSelection?
    var onSelectionChange: ((WebSelection?, _ top: CGFloat?) -> Void)?
    var onQuote: (() -> Void)?

    static func makeConfigured(_ configuration: WKWebViewConfiguration) -> TiriWebView {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: WebSelectionScript.source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        let view = TiriWebView(frame: .zero, configuration: configuration)
        controller.add(WeakMessageHandler(view), contentWorld: .defaultClient, name: WebSelectionScript.handlerName)
        return view
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard let text = body["text"] as? String, !text.isEmpty else {
            selection = nil
            onSelectionChange?(nil, nil)
            return
        }
        selection = WebSelection(text: text, line: (body["line"] as? NSNumber)?.intValue ?? -1,
                                 lineEnd: (body["lineEnd"] as? NSNumber)?.intValue ?? -1)
        let top = (body["top"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let bottom = (body["bottom"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? top
        // Scrolled away with its selection, the button goes too.
        let onScreen = bottom > 0 && top < bounds.height
        onSelectionChange?(selection, onScreen ? max(top, 4) : nil)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard selection != nil else { return }
        let item = NSMenuItem(title: "Quote in Agent", action: #selector(quoteFromMenu), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func quoteFromMenu() { onQuote?() }
}

/// The content controller keeps its handlers alive, so this keeps it from keeping the view alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
