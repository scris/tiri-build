import AppKit
import Foundation
import TiriCore
import UniformTypeIdentifiers
import WebKit

/// What a viewer shows when its page has crashed twice running, so it doesn't loop.
enum CrashPage {
    static func html(path: String) -> String {
        let words = [String(localized: "Can't show this file"), String(localized: "This page stopped working."),
                     String(localized: "It tries again when the file changes.")].map(MarkdownRenderer.escapeText)
        return """
        <!DOCTYPE html><meta charset="utf-8"><title>\(words[0])</title>
        <style>:root{color-scheme:light dark}body{font:14px -apple-system;margin:0;height:100vh;display:flex;align-items:center;justify-content:center;color:GrayText}
        div{max-width:460px;text-align:center}h1{font-size:17px;font-weight:600;color:CanvasText;margin:0 0 8px}code{word-break:break-all}</style>
        <div><h1>\(words[0])</h1><p>\(words[1])</p><p><code>\(MarkdownRenderer.escapeText(path))</code></p><p>\(words[2])</p></div>
        """
    }
}

/// The Markdown a rendered page was made from, split into lines once, with its headings once they're needed.
nonisolated struct RenderedMarkdownSource: Sendable {
    let id = UUID()
    let text: String
    let lines: [String]
    var headings: [MarkdownRenderer.HeadingAnchor]?

    init(text: String, headings: [MarkdownRenderer.HeadingAnchor]?) {
        self.text = text
        self.lines = text.components(separatedBy: "\n")
        self.headings = headings
    }
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

extension WebController {
    /// The item that has the keyboard, so a page that isn't it can't take the keyboard away.
    var isFocusedItem: Bool {
        let active = model.active
        if let peek = active.peek, model.peekHasKeyboard { return peek.id == itemID }
        return active.focused.active == itemID
    }

    /// Something in a local page's folder changed. Only the page, or what it loaded, reloads it.
    func localFilesChanged(_ paths: [String], page url: URL) {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        let realFolder = realPath(folder)
        func real(_ path: String) -> String {
            path == folder ? realFolder : path.hasPrefix(folder + "/") ? realFolder + path.dropFirst(folder.count) : realPath(path)
        }
        let samePage = localLoaded.page.split(separator: "#").first == url.absoluteString.split(separator: "#").first
        let addresses = requests.map(\.url) + (samePage ? Array(localLoaded.files) : [])
        let loaded = Set(addresses.compactMap { URL(string: $0) }.filter(\.isFileURL).map { real($0.standardizedFileURL.path) })
        guard LocalPageChanges.affect(page: real(url.standardizedFileURL.path), folder: realFolder, loaded: loaded, changed: paths,
                                      excluded: FileWatchHub.shared.excludedNames) else { return }
        reloadLocalPage()
    }

    /// WebKit keeps no timings for files, so a local page's own files are read from its document.
    func listenForLocalFiles() {
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: LocalFilesScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(LocalFilesListener(self), contentWorld: .defaultClient, name: LocalFilesScript.handler)
    }

    fileprivate func localFilesReported(_ body: Any) {
        guard let body = body as? [String: Any], let page = body["page"] as? String, let files = body["files"] as? [String] else { return }
        if localLoaded.page != page { localLoaded = (page, []) }
        // A page can name a great many. Enough for any real one.
        guard localLoaded.files.count < 5000 else { return }
        localLoaded.files.formUnion(files.prefix(5000))
    }

    /// No more than one reload each 300 ms, however fast things are written. The last change always gets one.
    private func reloadLocalPage() {
        guard !localReloadWaiting, webView.navigationDelegate != nil else { return }
        let wait = localReloadAt + 300 - ProcessClock.now()
        if wait > 0 {
            localReloadWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) { [weak self] in
                guard let self else { return }
                self.localReloadWaiting = false
                self.reloadLocalPage()
            }
            return
        }
        localReloadAt = ProcessClock.now()
        reload()
    }
}

/// The content controller keeps its handlers alive, so this keeps it from keeping the page alive.
private final class LocalFilesListener: NSObject, WKScriptMessageHandler {
    private weak var controller: WebController?
    init(_ controller: WebController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        controller?.localFilesReported(message.body)
    }
}

enum LocalFilesScript {
    static let handler = "tiriLocalFiles"

    /// In a world of its own. What a local page's document refers to, as it is now and as it changes:
    /// stylesheets and what they import, scripts, images, media, frames.
    static let source = #"""
    (() => {
      if (location.protocol !== 'file:') return;
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.tiriLocalFiles;
      if (!handler) return;
      const page = location.href.split('#')[0];
      const seen = new Set();
      let found = [];
      const add = (address, base) => {
        if (!address || seen.size > 5000) return;
        try {
          const url = new URL(address, base || document.baseURI);
          if (url.protocol !== 'file:') return;
          url.hash = ''; url.search = '';
          if (seen.has(url.href)) return;
          seen.add(url.href);
          found.push(url.href);
        } catch (error) {}
      };
      const sheet = (style, depth) => {
        if (!style || depth > 8) return;
        let rules;
        try { rules = style.cssRules; } catch (error) { return; }
        const base = style.href || document.baseURI;
        for (const rule of rules || []) {
          if (rule.href) add(rule.href, base);
          if (rule.styleSheet) sheet(rule.styleSheet, depth + 1);
          for (const match of (rule.cssText || '').matchAll(/url\(\s*['"]?([^'")]+)['"]?\s*\)/g)) add(match[1], base);
        }
      };
      const look = () => {
        timer = null;
        for (const element of document.querySelectorAll('link[href]')) add(element.getAttribute('href'));
        for (const element of document.querySelectorAll('[src]')) add(element.getAttribute('src'));
        for (const element of document.querySelectorAll('object[data]')) add(element.getAttribute('data'));
        for (const element of document.querySelectorAll('[srcset]')) {
          for (const part of element.getAttribute('srcset').split(',')) add(part.trim().split(/\s+/)[0]);
        }
        for (const style of document.styleSheets) sheet(style, 0);
        if (!found.length) return;
        const files = found;
        found = [];
        try { handler.postMessage({page, files}); } catch (error) {}
      };
      let timer = null;
      const soon = () => { if (timer === null) timer = setTimeout(look, 200); };
      look();
      addEventListener('load', soon);
      new MutationObserver(soon).observe(document.documentElement, {subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'href', 'srcset', 'data']});
    })();
    """#
}

/// Reading for `tiri-file:`, away from the main thread, in pieces, and from a byte range when one is asked
/// for, so a long video seeks without reading all of it.
nonisolated enum LocalFileServing {
    struct Opened: @unchecked Sendable {
        let handle: FileHandle
        let length: Int
        let request: ByteRangeRequest
    }

    /// Only a regular file: reading a pipe or a device would never end.
    static func open(_ path: String, range: String?) -> Opened? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        let length = Int(info.st_size)
        return Opened(handle: handle, length: length, request: ByteRangeRequest.parse(range, length: length))
    }

    static func read(_ opened: Opened, at offset: Int, count: Int) -> Data? {
        do {
            try opened.handle.seek(toOffset: UInt64(offset))
            return try opened.handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    static let pieceSize = 1 << 20
}
