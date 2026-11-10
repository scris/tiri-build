import AppKit
import SwiftUI
import TiriCore

/// The browser macOS opens web addresses with, by its own name and icon: "Open in Chrome" says more than "Open Externally".
enum DefaultBrowser {
    static var app: URL? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static var name: String {
        guard let app else { return String(localized: "Browser") }
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
        showToast(title: String(localized: "Opened in \(DefaultBrowser.name)"), detail: String(localized: "\(rule) always opens there"), symbol: "arrow.up.forward.app",
                  tint: .secondary, actionTitle: String(localized: "Open Here"), duration: 8, action: openHere)
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
            showToast(title: String(localized: "\(rule) opens in \(DefaultBrowser.name) now"), detail: nil, symbol: "arrow.up.forward.app", tint: .secondary,
                      actionTitle: String(localized: "Undo")) { [weak self] in self?.setOpensInBrowser(rule, false) }
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
/// to the browser, a document to its own app and code to the editor; holding it (or a right-click) offers the rest, by name.
struct OpenElsewhereButton: View {
    var page: WebController?
    var path: String?
    @Environment(AppModel.self) private var model

    /// Where a file goes when it leaves: its own app for a picture or a document, the editor for anything to type in.
    private struct FileWays {
        var editor: String
        /// The app macOS opens it with, when that's the better place for it.
        var app: String?
        var kind: String?
        var rule: String?
    }

    private func ways(for path: String) -> FileWays {
        let editor = ExternalEditor.displayName(of: model.settings.externalEditors, pathEnv: ProcessInfo.processInfo.environment["PATH"])
        guard !RemoteRegistry.shared.isRemote(path) else { return FileWays(editor: editor) }
        let rule = AppRules.matching(path: path, in: model.settings.filesOpenInDefaultApp)
        let place = DefaultApp.place(for: path)
        // Something to type in belongs to the editor, unless they've said this kind has an app.
        let app = rule != nil || !place.typed ? place.app : nil
        return FileWays(editor: editor, app: app, kind: app == nil ? nil : AppRules.kind(of: path), rule: app == nil ? nil : rule)
    }

    var body: some View {
        let url = page?.addressForBrowser
        if url != nil || path != nil {
            let browser = DefaultBrowser.name
            let file = path.map(ways)
            let target = url != nil ? browser : (file?.app ?? file?.editor ?? browser)
            let title = String(localized: "Open in \(target)")
            Menu {
                choices(url: url, browser: browser, file: file)
            } label: {
                Label(title, systemImage: "arrow.up.forward.square")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } primaryAction: {
                leave(url: url, file: file)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .contextMenu { choices(url: url, browser: browser, file: file) }
            .help(String(localized: "Open in \(target). Hold for more"))
            // One button to VoiceOver, with the menu's choices as its actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { leave(url: url, file: file) }
            .accessibilityActions { choices(url: url, browser: browser, file: file) }
        }
    }

    private func leave(url: URL?, file: FileWays?) {
        if let page, url != nil {
            model.movePageToBrowser(page.itemID)
        } else if let path {
            if file?.app != nil { model.moveFileToApp(path) } else { model.openExternally(path: path) }
        }
    }

    @ViewBuilder
    private func choices(url: URL?, browser: String, file: FileWays?) -> some View {
        if let page, let url {
            Button("Open in \(browser)") { model.movePageToBrowser(page.itemID) }
            if let path, let file { Button("Open in \(file.editor)") { model.openExternally(path: path) } }
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
        } else if let path, let file {
            if let app = file.app { Button("Open in \(app)") { model.moveFileToApp(path) } }
            Button("Open in \(file.editor)") { model.openExternally(path: path) }
            Button("Show in Finder") { model.showInFinder(path) }
            if let app = file.app {
                if let rule = file.rule {
                    Divider()
                    Button("Stop Opening \(rule) in \(app)") { model.setOpensInApp(rule, false, app: app) }
                } else if let kind = file.kind {
                    Divider()
                    Button("Always Open \(kind) in \(app)") {
                        model.setOpensInApp(kind, true, app: app)
                        model.moveFileToApp(path)
                    }
                }
            }
        }
    }
}
