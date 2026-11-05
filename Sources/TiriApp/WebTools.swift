import AppKit
import Foundation
import SwiftUI
import TiriCore
import WebKit

/// What a page has been saying and fetching, for whoever's debugging it: an agent, mostly.
struct WebLogEntry: Equatable {
    enum Level: String { case log, info, warn, error, debug }
    var time: Date
    var level: Level
    var text: String
}

struct WebRequestEntry: Equatable {
    var url: String
    var kind: String
    var status: Int
    var milliseconds: Int
}

enum WebScripts {
    static let logHandler = "tiriWebLog"
    static let pickHandler = "tiriWebPick"

    /// In the page's own world, because that's the only place its console and errors can be heard. It
    /// only passes things along, and a page writing to it can only add to its own log.
    static let listening = #"""
    (() => {
      if (window.__tiriListening) return;
      Object.defineProperty(window, '__tiriListening', {value: true});
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.tiriWebLog;
      if (!handler) return;
      const post = handler.postMessage.bind(handler);
      let sent = 0, windowStart = Date.now();
      const send = (message) => {
        const now = Date.now();
        if (now - windowStart > 1000) { windowStart = now; sent = 0; }
        if (++sent > 200) return;
        try { post(message); } catch (e) {}
      };
      const show = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.name + ': ' + value.message + (value.stack ? '\n' + value.stack : '');
        try { return JSON.stringify(value); } catch (e) { return String(value); }
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) {
          send({kind: 'log', level, text: args.map(show).join(' ').slice(0, 4000)});
          return original.apply(this, args);
        };
      }
      addEventListener('error', (event) => {
        if (event.target && event.target !== window && event.target.tagName) {
          const address = event.target.src || event.target.href || '';
          send({kind: 'log', level: 'error', text: `Couldn't load ${event.target.tagName.toLowerCase()}: ${address}`});
          send({kind: 'request', url: address, type: event.target.tagName.toLowerCase(), status: -1, ms: 0});
        } else {
          const place = event.filename ? ` (${event.filename}:${event.lineno}:${event.colno})` : '';
          send({kind: 'log', level: 'error', text: (event.message || 'Error') + place});
        }
      }, true);
      addEventListener('unhandledrejection', (event) => send({kind: 'log', level: 'error', text: 'Unhandled rejection: ' + show(event.reason)}));
      // Timing says nothing about how a request ended, so the two ways of asking are heard directly.
      const pageFetch = window.fetch;
      if (pageFetch) window.fetch = function (input, init) {
        const started = performance.now();
        const address = (input && input.url) || String(input);
        const done = (status, url) => send({kind: 'request', url: url || address, type: 'fetch', status, ms: Math.round(performance.now() - started)});
        return pageFetch.apply(this, arguments).then((response) => { done(response.status, response.url); return response; },
                                                     (error) => { done(-1); throw error; });
      };
      const pageOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        const started = performance.now();
        this.addEventListener('loadend', () => send({kind: 'request', url: this.responseURL || String(url), type: 'xhr', status: this.status || -1,
                                                     ms: Math.round(performance.now() - started)}));
        return pageOpen.apply(this, arguments);
      };
      const report = (entry) => {
        if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') return;
        send({kind: 'request', url: entry.name, type: entry.initiatorType || entry.entryType, status: entry.responseStatus || 0, ms: Math.round(entry.duration || 0)});
      };
      try {
        new PerformanceObserver((list) => list.getEntries().forEach(report)).observe({type: 'resource', buffered: true});
      } catch (e) {}
    })();
    """#

    /// In a world of its own, so a page can't see it or fake what's picked.
    static let pick = #"""
    (() => {
      if (window.__tiriPicking) return false;
      window.__tiriPicking = true;
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;background:rgba(80,140,255,.25);outline:2px solid rgb(80,140,255);border-radius:2px;display:none';
      document.documentElement.appendChild(box);
      let current = null;
      const part = (element) => {
        if (element.id) return '#' + CSS.escape(element.id);
        let text = element.tagName.toLowerCase();
        const parent = element.parentElement;
        if (parent) {
          const same = Array.from(parent.children).filter((child) => child.tagName === element.tagName);
          if (same.length > 1) text += `:nth-of-type(${same.indexOf(element) + 1})`;
        }
        return text;
      };
      const selector = (element) => {
        const parts = [];
        for (let node = element; node && node.nodeType === 1 && parts.length < 6; node = node.parentElement) {
          parts.unshift(part(node));
          if (node.id) break;
        }
        return parts.join(' > ');
      };
      const move = (event) => {
        current = event.target;
        const rect = current.getBoundingClientRect();
        box.style.cssText += `;display:block;left:${rect.left}px;top:${rect.top}px;width:${rect.width}px;height:${rect.height}px`;
      };
      const finish = () => {
        removeEventListener('mousemove', move, true);
        removeEventListener('click', click, true);
        removeEventListener('keydown', key, true);
        box.remove();
        window.__tiriPicking = false;
      };
      const send = (message) => webkit.messageHandlers.tiriWebPick.postMessage(message);
      const click = (event) => {
        event.preventDefault();
        event.stopPropagation();
        const element = current || event.target;
        finish();
        send({selector: selector(element), html: element.outerHTML.slice(0, 2000), text: (element.innerText || '').slice(0, 500)});
      };
      const key = (event) => {
        if (event.key !== 'Escape') return;
        event.preventDefault();
        finish();
        send({});
      };
      addEventListener('mousemove', move, true);
      addEventListener('click', click, true);
      addEventListener('keydown', key, true);
      return true;
    })();
    """#

    static func string(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

extension WebController: WKScriptMessageHandler {
    func installTools() {
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: WebScripts.listening, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(WeakMessageHandler(self), contentWorld: .page, name: WebScripts.logHandler)
        controller.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: WebScripts.pickHandler)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == WebScripts.pickHandler {
            picked(body)
            return
        }
        // The script in the page limits this too, and a page can talk past that script.
        let now = ProcessClock.now()
        if now - logWindowStart > 1000 {
            logWindowStart = now
            logWindowCount = 0
        }
        logWindowCount += 1
        guard logWindowCount <= 400 else { return }
        switch body["kind"] as? String {
        case "log":
            let level = WebLogEntry.Level(rawValue: body["level"] as? String ?? "log") ?? .log
            log.append(WebLogEntry(time: Date(), level: level, text: body["text"] as? String ?? ""))
            if log.count > 2000 { log.removeFirst(log.count - 2000) }
            if level == .error { errorCount += 1 }
        case "request":
            requests.append(WebRequestEntry(url: body["url"] as? String ?? "", kind: body["type"] as? String ?? "",
                                            status: (body["status"] as? NSNumber)?.intValue ?? 0, milliseconds: (body["ms"] as? NSNumber)?.intValue ?? 0))
            if requests.count > 1000 { requests.removeFirst(requests.count - 1000) }
        default:
            break
        }
    }

    /// A new page starts a new story.
    func pageStarted() {
        log = []
        requests = []
        errorCount = 0
    }

    func startPicking() {
        focus()
        picking = true
        webView.evaluateJavaScript(WebScripts.pick, in: nil, in: .defaultClient) { _ in }
    }

    private func picked(_ body: [String: Any]) {
        picking = false
        guard let selector = body["selector"] as? String else { return }
        var text = "From \(currentURLString), the element `\(selector)`:\n```html\n\(body["html"] as? String ?? "")\n```"
        if let shown = body["text"] as? String, !shown.isEmpty { text += "\nIt shows: \(shown)" }
        model.addReference(AgentSelection(path: currentURLString, quote: text + "\n"))
    }

    /// The page's errors, for handing to an agent as they are.
    func quoteErrors() {
        let errors = log.filter { $0.level == .error }.suffix(30).map(\.text).joined(separator: "\n")
        guard !errors.isEmpty else { return }
        model.addReference(AgentSelection(path: currentURLString, quote: "Errors from \(currentURLString):\n```\n\(errors)\n```\n"))
    }

    func consoleLines(limit: Int, errorsOnly: Bool) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return log.filter { !errorsOnly || $0.level == .error }.suffix(limit).map { "\(formatter.string(from: $0.time)) \($0.level.rawValue)\t\($0.text)" }
    }

    func requestLines(limit: Int, failedOnly: Bool) -> [String] {
        // A file the page loaded by itself loaded, or it would have said otherwise. How isn't known.
        let failedFiles = Set(requests.filter { $0.status == -1 }.map(\.url))
        return requests.filter { $0.status != 0 || !failedFiles.contains($0.url) }.filter { !failedOnly || $0.status >= 400 || $0.status == -1 }.suffix(limit).map { entry in
            let status = entry.status == -1 ? "failed" : entry.status == 0 ? "-" : String(entry.status)
            return "\(status)\t\(entry.milliseconds) ms\t\(entry.kind)\t\(entry.url)"
        }
    }

    /// What the page looks like right now, whatever's in front of it.
    func snapshot(to path: String) async -> Bool {
        let configuration = WKSnapshotConfiguration()
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                nonisolated(unsafe) let shot = image
                continuation.resume(returning: shot)
            }
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    func run(script: String) async -> (value: String?, problem: String?) {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .failure(let error):
                        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                        continuation.resume(returning: (nil, detail))
                    case .success(let value):
                        continuation.resume(returning: (Self.describe(value), nil))
                    }
                }
            }
        }
    }

    private nonisolated static func describe(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) { return String(decoding: data, as: UTF8.self) }
        return String(describing: value)
    }
}

extension AppModel {
    /// The page meant: the one named, the one in front, or else this workspace's only one.
    fileprivate func webController(named item: String?) throws -> WebController {
        if let item {
            guard let web = controller(for: item) as? WebController else { throw ControlHandler.ControlFailure("\(item) isn't a web page") }
            return web
        }
        if let web = frontWebController { return web }
        let pages = active.items.compactMap { existingController(for: $0.id) as? WebController }
        if pages.count == 1 { return pages[0] }
        throw ControlHandler.ControlFailure(pages.isEmpty ? "No web page is open. Open one with tiri preview <url>." : "Several web pages are open. Say which with --item.")
    }

    func webCommand(_ request: ControlRequest) async -> ControlResponse {
        do {
            let web = try webController(named: request.args["item"]?.stringValue)
            // A panel can run things on this Mac. A server's terminal doesn't get to press its buttons.
            if request.args["fromServer"]?.boolValue == true, web.panel != nil { throw ControlHandler.ControlFailure("A plugin's panel can only be driven from the Mac, not from a server.") }
            let lines = request.args["lines"]?.intValue ?? 100
            switch request.cmd {
            case "web.console":
                return .success(id: request.id, .array(web.consoleLines(limit: lines, errorsOnly: request.args["errors"]?.boolValue == true).map(JSONValue.string)))
            case "web.network":
                return .success(id: request.id, .array(web.requestLines(limit: lines, failedOnly: request.args["failed"]?.boolValue == true).map(JSONValue.string)))
            case "web.shot":
                return try await webShot(web, request)
            case "web.text":
                let result = await web.run(script: "document.body ? document.body.innerText : ''")
                if let problem = result.problem { throw ControlHandler.ControlFailure(problem) }
                return .success(id: request.id, .string(result.value ?? ""))
            case "web.click", "web.type":
                let selector = WebScripts.string(request.args["selector"]?.stringValue ?? "")
                let value = WebScripts.string(request.args["text"]?.stringValue ?? "")
                let action = request.cmd == "web.click" ? "element.scrollIntoView({block:'center'}); element.click();" : """
                element.focus();
                const proto = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value');
                if (setter && setter.set && (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement)) setter.set.call(element, \(value)); else element.textContent = \(value);
                element.dispatchEvent(new Event('input', {bubbles: true}));
                element.dispatchEvent(new Event('change', {bubbles: true}));
                """
                let result = await web.run(script: "(() => { const element = document.querySelector(\(selector)); if (!element) return false; \(action) return true; })()")
                if let problem = result.problem { throw ControlHandler.ControlFailure(problem) }
                guard result.value == "1" || result.value == "true" else { throw ControlHandler.ControlFailure("Nothing on the page matches \(request.args["selector"]?.stringValue ?? "that").") }
                return .success(id: request.id, .object([:]))
            case "web.eval":
                let result = await web.run(script: request.args["script"]?.stringValue ?? "")
                if let problem = result.problem { throw ControlHandler.ControlFailure(problem) }
                return .success(id: request.id, .string(result.value ?? ""))
            default:
                throw ControlHandler.ControlFailure("Unknown command")
            }
        } catch let failure as ControlHandler.ControlFailure {
            return .failure(id: request.id, failure.message)
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// A picture an agent can open. On a server, that means putting it on the server.
    private func webShot(_ web: WebController, _ request: ControlRequest) async throws -> ControlResponse {
        let folder = (RemoteMirror.root as NSString).deletingLastPathComponent + "/Screenshots"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = "page-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let path = folder + "/" + name
        guard await web.snapshot(to: path) else { throw ControlHandler.ControlFailure("Couldn't capture that page.") }
        guard let destination = workspace(containing: web.itemID)?.remote, let connection = remote.existingConnection(destination) else {
            return .success(id: request.id, .object(["path": .string(path)]))
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = await Task.detached(priority: .userInitiated) {
            connection.run("mkdir -p \"$HOME\"/.tiri/shots && cat > \"$HOME\"/.tiri/shots/\(name) && printf %s \"$HOME\"/.tiri/shots/\(name)", stdin: data, timeout: 60)
        }.value
        guard let result, result.succeeded else { throw ControlHandler.ControlFailure("Couldn't send the picture to the server.") }
        return .success(id: request.id, .object(["path": .string(result.text)]))
    }
}
