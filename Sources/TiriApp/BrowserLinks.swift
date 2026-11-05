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

/// The browser's own icon above a page. A click moves the page there; its menu keeps the site there from now on, or stops.
struct BrowserButton: View {
    let controller: WebController
    var glass = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if let url = controller.addressForBrowser {
            let item = controller.itemID
            let name = DefaultBrowser.name
            let rule = BrowserRules.matching(url, in: model.settings.webOpenInBrowser)
            let menu = Menu {
                Button("Open in \(name)") { model.movePageToBrowser(item) }
                if let rule {
                    Button("Stop Opening \(rule) in \(name)") { model.setOpensInBrowser(rule, false) }
                } else if let site = BrowserRules.site(of: url) {
                    Button("Always Open \(site) in \(name)") {
                        model.setOpensInBrowser(site, true)
                        model.movePageToBrowser(item)
                    }
                }
            } label: {
                if let icon = DefaultBrowser.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "safari")
                }
            } primaryAction: {
                model.movePageToBrowser(item)
            }
            .help("Open in \(name)")
            .fixedSize()
            if glass {
                menu.menuStyle(.button).buttonStyle(.glass)
            } else {
                menu.menuStyle(.borderlessButton).frame(height: 24)
            }
        }
    }
}
