import AppKit
import SwiftUI
import TiriCore

/// The browser macOS opens web addresses with, by its own name and icon: "Open in Chrome" says more than "Open Externally".
enum DefaultBrowser {
    static var app: URL? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static var name: String {
        guard let app else { return "Browser" }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static var icon: NSImage? { app.map { NSWorkspace.shared.icon(forFile: $0.path) } }
}

extension AppModel {
    /// Hands an address to the person's own browser. A test copy only writes it down: it must never bring a browser
    /// to the front of someone's screen.
    func openInBrowser(_ url: URL) {
        if Self.isTestCopy {
            sentToBrowser.append(url.absoluteString)
            return
        }
        // A local page could open in an editor by default. Asked for the browser, it goes to the browser.
        if url.isFileURL, let browser = DefaultBrowser.app {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sites someone keeps in their browser go straight there. Says whether this one did, and offers it here, this once.
    func sendsToBrowser(_ url: URL, openHere: @escaping () -> Void) -> Bool {
        guard let rule = BrowserRules.matching(url, in: settings.webOpenInBrowser) else { return false }
        openInBrowser(url)
        showToast(title: "Opened in \(DefaultBrowser.name)", detail: "\(rule) always opens there", symbol: "arrow.up.forward.app",
                  tint: .secondary, actionTitle: "Open Here", duration: 8, action: openHere)
        return true
    }

    /// From the browser button's menu: the site goes to the browser from now on, or stops.
    func setOpensInBrowser(_ rule: String, _ on: Bool) {
        var rules = settings.webOpenInBrowser
        if on {
            guard !rules.contains(rule) else { return }
            rules.append(rule)
        } else {
            rules.removeAll { $0 == rule }
        }
        guard setSetting("web.openInBrowser", to: .array(rules.map(JSONValue.string))) == nil else { return }
        if on {
            showToast(title: "\(rule) opens in \(DefaultBrowser.name) now", detail: nil, symbol: "arrow.up.forward.app", tint: .secondary,
                      actionTitle: "Undo") { [weak self] in self?.setOpensInBrowser(rule, false) }
        }
    }

    /// Moves a page to the browser. A Peek was only a glance, so it goes; a tab stays where it was put.
    func movePageToBrowser(_ item: ItemID) {
        guard let web = existingController(for: item) as? WebController, let url = web.addressForBrowser else { return }
        openInBrowser(url)
        if active.peek?.id == item { dismissPeek() }
    }
}

extension WebController {
    /// What the browser gets: the page itself, never a plugin's panel or the stand-in for a page that didn't load.
    var addressForBrowser: URL? {
        guard panel == nil, let url = URL(string: currentURLString) else { return nil }
        return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    }
}

/// The one way out of Tiri above a page or a file: a quiet arrow, never another app's colored icon. A click takes a page
/// to the browser and a file to the editor; holding it (or a right-click) offers the rest, by name.
struct OpenElsewhereButton: View {
    var page: WebController?
    var path: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let url = page?.addressForBrowser
        if url != nil || path != nil {
            let browser = DefaultBrowser.name
            let editor = ExternalEditor.displayName(of: model.settings.externalEditors, pathEnv: ProcessInfo.processInfo.environment["PATH"])
            Menu {
                choices(url: url, browser: browser, editor: editor)
            } label: {
                Label(url != nil ? "Open in \(browser)" : "Open in \(editor)", systemImage: "arrow.up.forward.square")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                if let page, url != nil { model.movePageToBrowser(page.itemID) } else if let path { model.openExternally(path: path) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .contextMenu { choices(url: url, browser: browser, editor: editor) }
            .help(url != nil ? "Open in \(browser). Hold for more" : "Open in \(editor). Hold for more")
        }
    }

    @ViewBuilder
    private func choices(url: URL?, browser: String, editor: String) -> some View {
        if let page, let url {
            Button("Open in \(browser)") { model.movePageToBrowser(page.itemID) }
            if let path { Button("Open in \(editor)") { model.openExternally(path: path) } }
            if let path { Button("Show in Finder") { model.showInFinder(path) } }
            Divider()
            if let rule = BrowserRules.matching(url, in: model.settings.webOpenInBrowser) {
                Button("Stop Opening \(rule) in \(browser)") { model.setOpensInBrowser(rule, false) }
            } else if let site = BrowserRules.site(of: url) {
                Button("Always Open \(site) in \(browser)") {
                    model.setOpensInBrowser(site, true)
                    model.movePageToBrowser(page.itemID)
                }
            }
        } else if let path {
            Button("Open in \(editor)") { model.openExternally(path: path) }
            Button("Show in Finder") { model.showInFinder(path) }
        }
    }
}
