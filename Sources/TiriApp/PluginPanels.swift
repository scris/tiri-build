import AppKit
import CryptoKit
import SwiftUI
import TiriCore
import UniformTypeIdentifiers
import WebKit

/// Each plugin's panels have storage of their own, out of reach of web pages and other plugins.
enum PluginPanelStorage {
    private static func identifier(_ plugin: String) -> UUID {
        // Stays the same from one launch to the next, and differs in test copies with their own folder.
        let digest = SHA256.hash(data: Data((TiriPaths.supportDirectory.path + "/" + plugin).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { $0.baseAddress!.withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) } }
    }

    static func store(for plugin: String) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: identifier(plugin))
    }

    static func remove(plugin: String) {
        WKWebsiteDataStore.remove(forIdentifier: identifier(plugin)) { _ in }
    }
}

/// Files for a panel, from its plugin's folder and nowhere else, each with the policy that keeps it in.
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tiri-plugin"

    private let plugin: String
    private let folder: URL
    private let policy: String

    init(plugin: String, folder: URL, policy: String) {
        self.plugin = plugin
        self.folder = folder
        self.policy = policy
    }

    /// Tasks still wanted. WebKit can stop one while its file is being read.
    private var active: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == plugin,
              let file = PluginValidator.resolve(String(url.path(percentEncoded: false).drop(while: { $0 == "/" })), in: folder) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let identity = ObjectIdentifier(task)
        active.insert(identity)
        let policy = policy
        // Off the main thread, however big it is, and only a real file: reading a pipe would never end.
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
                return try? Data(contentsOf: file, options: .mappedIfSafe)
            }.value
            guard active.remove(identity) != nil else { return }
            guard let data else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let headers = ["Content-Type": type, "Content-Security-Policy": policy, "Content-Length": String(data.count),
                           "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                task.didFailWithError(URLError(.badServerResponse))
                return
            }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}

/// What one open panel is allowed, and the only way it reaches anything outside itself. The page
/// talks to a script in a world of its own, which is the only thing that can talk to this. Everything
/// asked for is checked here, against what was declared when you turned the plugin on.
final class PluginPanelContext: NSObject, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "tiri-plugin-bridge")
    private static let handlerName = "tiriPlugin"

    let plugin: InstalledPlugin
    let panel: PluginManifest.Panel
    let itemID: ItemID
    private(set) var args: [String: JSONValue]
    let file: String?
    let writes: Bool
    private unowned let model: AppModel
    private weak var controller: WebController?
    private var fileToken: FileWatchHub.Token?
    private var lastAsk = 0.0
    private var lastLink = 0.0
    /// What it last read, so a save can tell if someone else has changed the file since.
    private var lastRead: Data?

    init(plugin: InstalledPlugin, panel: PluginManifest.Panel, itemID: ItemID, args: [String: JSONValue], file: String?, writes: Bool, model: AppModel) {
        self.plugin = plugin
        self.panel = panel
        self.itemID = itemID
        self.args = args
        self.file = file
        self.writes = writes
        self.model = model
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = PluginSchemeHandler.scheme
        parts.host = plugin.name
        parts.path = "/" + panel.entry.split(separator: "/").joined(separator: "/")
        return parts.url ?? URL(string: "\(PluginSchemeHandler.scheme)://\(plugin.name)/")!
    }

    var source: String { file.map { ($0 as NSString).lastPathComponent } ?? panel.title }
    var quotePath: String { file ?? plugin.folder.appendingPathComponent(panel.entry).path }

    func configure(_ configuration: WKWebViewConfiguration) {
        let policy = PluginNetwork.contentPolicy(allowing: panel.allow?.network ?? [], scheme: PluginSchemeHandler.scheme)
        configuration.websiteDataStore = PluginPanelStorage.store(for: plugin.name)
        configuration.setURLSchemeHandler(PluginSchemeHandler(plugin: plugin.name, folder: plugin.folder, policy: policy), forURLScheme: PluginSchemeHandler.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: PluginPanelScripts.closing, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: PluginPanelScripts.page, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: PluginPanelScripts.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        controller.addScriptMessageHandler(WeakReplyHandler(self), contentWorld: Self.world, name: Self.handlerName)
    }

    func attach(_ controller: WebController) {
        self.controller = controller
        if let file {
            fileToken = FileWatchHub.shared.watch(path: file) { [weak self] in self?.send(event: "file", data: .null) }
        }
    }

    func teardown() {
        fileToken = nil
        controller?.webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
    }

    // MARK: Where it can go

    /// Its own files, and only those. A link someone clicks opens as a web page of its own.
    func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        if target.scheme == PluginSchemeHandler.scheme, target.host == plugin.name { return .allow }
        if target.scheme == "about" { return .allow }
        // Only with a real click. A page can click its own links, and that would carry whatever it
        // likes in the address, to anywhere, past everything else here.
        if action.navigationType == .linkActivated, ["http", "https"].contains(target.scheme?.lowercased()),
           let view = controller?.webView, model.plugins.personJustActed(in: view) {
            let now = ProcessClock.now()
            guard now - lastLink > 1000 else { return .cancel }
            lastLink = now
            let workspace = model.workspace(containing: itemID)?.id
            let openHere = { [weak model] in _ = model?.openWeb(url: target.absoluteString, split: nil, in: workspace) }
            if !model.sendsToBrowser(target, openHere: openHere) { openHere() }
        }
        return .cancel
    }

    // MARK: Telling it things

    func update(args new: [String: JSONValue]) {
        guard !new.isEmpty else { return }
        args = new
        send(event: "args", data: .object(new))
    }

    func settingsChanged() {
        send(event: "settings", data: plugin.manifest.map { .object(PluginSettingsStore.resolved($0)) } ?? .null)
    }

    func themeChanged() {
        send(event: "theme", data: .string(model.effectiveDark ? "dark" : "light"))
    }

    func send(event: String, data: JSONValue) {
        let payload = SettingsSchema.json(.object(["event": .string(event), "data": data]))
        let script = "document.dispatchEvent(new CustomEvent('tiri-plugin-event', {detail: \(WebScripts.string(payload))}));"
        controller?.webView.evaluateJavaScript(script, in: nil, in: Self.world) { _ in }
    }

    // MARK: What it can ask

    private struct Refused: Error {
        var message: String
    }

    private var personActed = false

    /// Reaching the agent takes the person's own click or key in this panel, so that it only ever
    /// happens when they're looking at it, and it's the thing they meant to do.
    private func requireAgentAccess(_ what: String) throws {
        guard panel.allow?.agent == true else { throw Refused(message: "\(what) needs \"agent\": true in this panel's allow") }
        guard personActed else { throw Refused(message: "\(what) needs the person to have just clicked or typed in this panel") }
        // A page can't keep taking the keyboard away from you.
        let now = ProcessClock.now()
        guard now - lastAsk > 1000 else { throw Refused(message: "Only one of those a second.") }
        lastAsk = now
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        // Only the panel's own top page. Nothing it might have embedded.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == PluginSchemeHandler.scheme,
              message.frameInfo.securityOrigin.host == plugin.name,
              let body = message.body as? [String: Any], let method = body["method"] as? String else {
            replyHandler(nil, "That can't come from here.")
            return
        }
        let params = (body["params"] as? String).flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .object([:])
        // Looked at as it arrives, not after anything else has had a turn.
        personActed = controller.map { model.plugins.personJustActed(in: $0.webView) } ?? false
        Task {
            do {
                let result = try await perform(method, params)
                replyHandler(SettingsSchema.json(result), nil)
            } catch let refused as Refused {
                replyHandler(nil, refused.message)
            } catch {
                replyHandler(nil, "\(error)")
            }
        }
    }

    private func perform(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let allow = panel.allow
        switch method {
        case "context":
            return .object([
                "plugin": .string(plugin.name), "panel": .string(panel.id), "version": .string(TiriCoreVersion.string), "apiVersion": .int(PluginManifest.currentAPI),
                "theme": .string(model.effectiveDark ? "dark" : "light"), "args": .object(args), "file": file.map(JSONValue.string) ?? .null,
                "folder": model.workspace(containing: itemID)?.folders.first.map(JSONValue.string) ?? .null,
                "settings": plugin.manifest.map { .object(PluginSettingsStore.resolved($0)) } ?? .object([:]),
            ])
        case "ask", "quote":
            guard let text = params["text"]?.stringValue, !text.isEmpty else { throw Refused(message: "\(method) needs some text") }
            try requireAgentAccess(method)
            let words = method == "quote" ? AgentReference.quotation(from: params["source"]?.stringValue ?? source, text: text) : text
            model.plugins.deliverToAgent(words)
            return .null
        case "run":
            guard let wanted = params["command"]?.stringValue else { throw Refused(message: "run needs a command") }
            let allowed = allow?.commands ?? []
            let full = PluginHost.fullID(plugin: plugin.name, command: wanted)
            let isOwn = plugin.manifest?.commands?.contains { $0.id == wanted || PluginHost.fullID(plugin: plugin.name, command: $0.id) == wanted } == true
            guard allowed.contains(wanted) || allowed.contains(full) || (isOwn && allowed.contains { PluginHost.fullID(plugin: plugin.name, command: $0) == full }) else {
                throw Refused(message: "\(wanted) isn't in this panel's allow.commands")
            }
            if isOwn {
                // A command that speaks to the agent is held to the same rules as asking directly.
                if model.plugins.command(full)?.command.ask != nil { try requireAgentAccess("A command that asks the agent") }
                let done = await model.plugins.run(full, args: params["args"]?.objectValue ?? [:], workspace: model.workspace(containing: itemID)?.id)
                if let problem = done.problem { throw Refused(message: problem) }
                return .string(done.output)
            }
            guard model.run(wanted) else { throw Refused(message: "No command \(wanted)") }
            return .null
        case "call":
            guard let process = params["process"]?.stringValue, let name = params["method"]?.stringValue else { throw Refused(message: "call needs a process and a method") }
            guard allow?.processes?.contains(process) == true else { throw Refused(message: "\(process) isn't in this panel's allow.processes") }
            let workspace = model.workspace(containing: itemID)?.id
            let context = model.plugins.runner.context(plugin: plugin, args: args, workspace: workspace)
            switch await model.plugins.processes.call(plugin: plugin, process: process, method: name, params: params["params"] ?? .null, context: context, workspace: workspace) {
            case .success(let value): return value
            case .failure(let failure): throw Refused(message: failure.message)
            }
        case "open":
            guard allow?.openFiles == true else { throw Refused(message: "open needs \"openFiles\": true in this panel's allow") }
            guard let path = params["path"]?.stringValue else { throw Refused(message: "open needs a path") }
            // Its own workspace's, whichever one's in front.
            guard let place = model.workspace(containing: itemID) else { throw Refused(message: "This panel has closed") }
            let full = path.hasPrefix("/") ? path : (place.folders.first.map { $0 + "/" + path } ?? path)
            let standard = (full as NSString).standardizingPath
            guard place.folder(containing: standard) != nil else { throw Refused(message: "\(path) isn't in this workspace") }
            model.open(path: standard, line: params["line"]?.intValue, intent: .peek(takeFocus: false), in: place.id)
            return .null
        case "read":
            guard let file else { throw Refused(message: "Only a viewer has a file to read") }
            let encoding = params["encoding"]?.stringValue
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: URL(fileURLWithPath: file)) }.value
            lastRead = data
            return .string(encoding == "base64" ? data.base64EncodedString() : String(decoding: data, as: UTF8.self))
        case "write":
            guard let file else { throw Refused(message: "Only a viewer has a file to write") }
            guard writes else { throw Refused(message: "write needs \"writes\": true on this viewer") }
            guard let text = params["text"]?.stringValue else { throw Refused(message: "write needs text") }
            guard let lastRead else { throw Refused(message: "Read the file before writing it, so nothing newer gets overwritten") }
            let new = Data(text.utf8)
            let wrote = try await Task.detached(priority: .userInitiated) { () -> Bool in
                let url = URL(fileURLWithPath: file)
                guard (try? Data(contentsOf: url)) == lastRead else { return false }
                try new.write(to: url, options: .atomic)
                return true
            }.value
            guard wrote else { throw Refused(message: "The file has changed since you read it. Read it again first") }
            self.lastRead = new
            model.remote.didSave(file)
            return .null
        case "comment":
            guard allow?.agent == true else { throw Refused(message: "comment needs \"agent\": true in this panel's allow") }
            guard let text = params["text"]?.stringValue, !text.isEmpty else { throw Refused(message: "comment needs text") }
            let line = params["line"]?.intValue
            let comment = ReviewComment(path: quotePath, firstLine: line, lastLine: line, excerpt: line.flatMap { ReviewQuote.lines($0, $0, of: quotePath) }, text: text)
            model.addReviewComment(comment, in: model.workspace(containing: itemID)?.id)
            return .null
        case "setSetting":
            guard let key = params["key"]?.stringValue, plugin.manifest?.settings?.contains(where: { $0.key == key }) == true else {
                throw Refused(message: "That isn't one of this plugin's settings")
            }
            _ = model.setSetting(SettingsSchema.pluginKey(plugin.name, key), to: params["value"] ?? .null)
            return .null
        case "setTitle":
            guard let title = params["title"]?.stringValue else { throw Refused(message: "setTitle needs a title") }
            model.setPanelTitle(itemID, to: String(title.prefix(120)))
            return .null
        default:
            throw Refused(message: "There's no \(method)")
        }
    }
}

/// The content controller keeps its handlers alive, so this keeps it from keeping the panel alive.
final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: PluginPanelContext?
    init(_ target: PluginPanelContext) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let target else {
            replyHandler(nil, "This panel has closed.")
            return
        }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

enum PluginPanelScripts {
    /// A panel's content policy has no say over peer-to-peer connections. In every frame, so an empty
    /// embedded one can't hand them back.
    static let closing = #"""
    (() => {
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCIceTransport', 'RTCSctpTransport']) {
        try { Object.defineProperty(window, name, {value: undefined, writable: false, configurable: false}); } catch (error) {}
      }
    })();
    """#

    /// What a panel's page sees. It holds nothing worth stealing: it only passes requests on, and every
    /// one is checked on the far side.
    static let page = #"""
    (() => {
      // A page with no styling of its own still looks at home here, in light and dark. Anything of the
      // page's comes later, so it wins.
      const defaults = document.createElement('style');
      defaults.textContent = ':root{color-scheme:light dark;font:13px -apple-system,system-ui,sans-serif}';
      (document.head || document.documentElement).prepend(defaults);
      let next = 1;
      const waiting = new Map();
      const handlers = new Map();
      document.addEventListener('tiri-plugin-reply', (event) => {
        const reply = JSON.parse(event.detail);
        const found = waiting.get(reply.id);
        if (!found) return;
        waiting.delete(reply.id);
        if (reply.error !== undefined) found.reject(new Error(reply.error));
        else found.resolve(reply.result === undefined ? undefined : JSON.parse(reply.result));
      });
      document.addEventListener('tiri-plugin-event', (event) => {
        const message = JSON.parse(event.detail);
        for (const handler of handlers.get(message.event) || []) {
          try { handler(message.data); } catch (error) { console.error(error); }
        }
      });
      const request = (method, params) => new Promise((resolve, reject) => {
        const id = next++;
        waiting.set(id, {resolve, reject});
        document.dispatchEvent(new CustomEvent('tiri-plugin-request', {detail: JSON.stringify({id, method, params: JSON.stringify(params === undefined ? {} : params)})}));
      });
      const api = {
        context: () => request('context'),
        ask: (text) => request('ask', {text}),
        quote: (text, source) => request('quote', {text, source}),
        run: (command, args) => request('run', {command, args}),
        call: (process, method, params) => request('call', {process, method, params}),
        open: (path, line) => request('open', {path, line}),
        read: (encoding) => request('read', {encoding}),
        write: (text) => request('write', {text}),
        comment: (text, line) => request('comment', {text, line}),
        setSetting: (key, value) => request('setSetting', {key, value}),
        setTitle: (title) => request('setTitle', {title}),
        on: (event, handler) => {
          if (!handlers.has(event)) handlers.set(event, []);
          handlers.get(event).push(handler);
        },
      };
      Object.defineProperty(window, 'tiri', {value: Object.freeze(api), writable: false, configurable: false});
    })();
    """#

    /// In a world of its own, so a page can't see the handler or replace this.
    static let bridge = #"""
    (() => {
      const handler = webkit.messageHandlers.tiriPlugin;
      document.addEventListener('tiri-plugin-request', (event) => {
        let message;
        try { message = JSON.parse(event.detail); } catch (error) { return; }
        const answer = (reply) => document.dispatchEvent(new CustomEvent('tiri-plugin-reply', {detail: JSON.stringify(reply)}));
        handler.postMessage({method: message.method, params: message.params}).then(
          (result) => answer({id: message.id, result}),
          (error) => answer({id: message.id, error: String(error && error.message || error)}));
      });
    })();
    """#
}

// MARK: - A panel whose plugin is off

final class PluginOffController: ItemController {
    let itemID: ItemID
    private let host: NSView
    var view: NSView { host }

    init(itemID: ItemID, spec: PluginPanelSpec, model: AppModel) {
        self.itemID = itemID
        host = NSHostingView(rootView: PluginOffView(spec: spec).environment(model))
    }

    func focus() { host.window?.makeFirstResponder(host) }
    func didAttach() { AppModel.shared.viewerReady(itemID) }
}

struct PluginOffView: View {
    let spec: PluginPanelSpec
    @Environment(AppModel.self) private var model

    var body: some View {
        let found = model.plugins.plugin(named: spec.plugin)
        VStack(spacing: 12) {
            if model.plugins.isLoaded {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 30))
                    .foregroundStyle(.faint)
                Text(found == nil ? "\(spec.plugin) isn't installed any more" : "\(found?.title ?? spec.plugin) is off")
                    .foregroundStyle(.secondary)
                if found != nil {
                    Button("Turn On…") { model.plugins.askToEnable(spec.plugin) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Above a panel: where it's from, and starting it over.
struct PluginPanelHeader: View {
    let spec: PluginPanelSpec
    let controller: WebController
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.faint)
                .font(.caption)
            Text(model.plugins.plugin(named: spec.plugin)?.title ?? spec.plugin)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if controller.errorCount > 0 {
                Button { controller.quoteErrors() } label: {
                    Label("\(controller.errorCount)", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("This panel has errors. Click to quote them in your agent.")
            }
            Button { controller.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reload")
            .accessibilityLabel("Reload")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .tiriBar()
        .overlay(alignment: .bottom) { Divider() }
    }
}
