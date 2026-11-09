import AppKit
import SwiftUI
import TiriCore

/// The app macOS opens a file with, by its own name: "Open in Keynote" says more than "Open Externally".
@MainActor
enum DefaultApp {
    /// Nothing when no app claims the file, or when the one that does is Tiri: sending it there would only bring it back.
    static func app(for path: String) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { return nil }
        return isTiri(Bundle(url: app)?.bundleIdentifier) ? nil : app
    }

    /// Its name, and whether the file is one to type in. Asked for on every draw of a file's header, so an answer
    /// is kept a while: which app opens a kind of file changes about never.
    static func place(for path: String) -> (app: String?, typed: Bool) {
        let now = ProcessClock.now()
        if let kept = places[path], now - kept.at < 30_000 { return (kept.app, kept.typed) }
        let kind = FileClassifier.classify(path: path) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
        let typed = [FileKind.text, .markdown, .notebook, .csv, .svg, .html].contains(kind)
        if places.count > 200 { places.removeAll() }
        places[path] = (name(for: path), typed, now)
        return (places[path]?.app, typed)
    }

    @MainActor private static var places: [String: (app: String?, typed: Bool, at: Double)] = [:]

    static func name(for path: String) -> String? {
        guard let app = app(for: path) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Tiri, a personal copy of it or a test copy: all one app as far as "its own app" goes.
    static func isTiri(_ identifier: String?) -> Bool {
        guard let identifier, let own = Bundle.main.bundleIdentifier else { return false }
        func plain(_ id: String) -> String { id.hasSuffix(".personal") ? String(id.dropLast(9)) : id }
        return plain(identifier) == plain(own)
    }
}

extension AppModel {
    /// Hands a file to its own app. `quietly` is for an agent showing something: the app opens behind Tiri.
    /// A test copy only writes it down: it must never start an app on someone's screen.
    func openInDefaultApp(_ path: String, quietly: Bool = false) {
        if Self.isTestCopy {
            sentToBrowser.append("app:" + path)
            return
        }
        guard let app = DefaultApp.app(for: path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !quietly
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: configuration)
    }

    /// The rule a file on this Mac falls under, and the app it would go to. Nothing for a file on a server.
    func appRule(for path: String) -> (rule: String, app: String)? {
        guard !settings.filesOpenInDefaultApp.isEmpty, !RemoteRegistry.shared.isRemote(path),
              let rule = AppRules.matching(path: path, in: settings.filesOpenInDefaultApp),
              let app = DefaultApp.name(for: path) else { return nil }
        return (rule, app)
    }

    /// Kinds of file someone keeps in their own app go straight there. Says whether this one did, and offers it here, this once.
    func sendsToApp(_ path: String, quietly: Bool = false, openHere: @escaping () -> Void) -> Bool {
        guard let (rule, app) = appRule(for: path) else { return false }
        openInDefaultApp(path, quietly: quietly)
        showToast(title: String(localized: "Opened in \(app)"), detail: String(localized: "\(rule) always opens there"), symbol: "arrow.up.forward.app",
                  tint: .secondary, actionTitle: String(localized: "Open Here"), duration: 8, action: openHere)
        return true
    }

    /// From the ↗ button's menu: the kind goes to its own app from now on, or stops.
    func setOpensInApp(_ rule: String, _ on: Bool, app: String) {
        var rules = settings.filesOpenInDefaultApp
        if on {
            guard !rules.contains(rule) else { return }
            rules.append(rule)
        } else {
            rules.removeAll { $0 == rule }
        }
        guard setSetting("files.openInDefaultApp", to: .array(rules.map(JSONValue.string))) == nil else { return }
        if on {
            showToast(title: String(localized: "\(rule) opens in \(app) now"), detail: nil, symbol: "arrow.up.forward.app", tint: .secondary,
                      actionTitle: String(localized: "Undo")) { [weak self] in self?.setOpensInApp(rule, false, app: app) }
        }
    }

    /// Moves a file to its own app. A Peek was only a glance, so it goes; a tab stays where it was put.
    func moveFileToApp(_ path: String) {
        openInDefaultApp(path)
        if active.peek?.filePath == path { dismissPeek() }
    }

    // MARK: Pages that want a sign-in

    /// A page came back asking who's there. Someone is far more likely signed in to that site in their own browser,
    /// so it's offered, once per site, ever: this page there, or the whole site from now on.
    func offerBrowser(for url: URL, item: ItemID) {
        guard let site = BrowserRules.site(of: url), !offeredBrowserFor.contains(site),
              BrowserRules.matching(url, in: settings.webOpenInBrowser) == nil else { return }
        // Once per site, ever: a tab that comes back with every launch would otherwise ask every launch.
        // A test copy forgets, so each run of a check starts clean.
        let kept = "browserOfferedSites"
        var asked = Self.isTestCopy ? [] : UserDefaults.standard.stringArray(forKey: kept) ?? []
        guard !asked.contains(site) else { return }
        offeredBrowserFor.insert(site)
        if !Self.isTestCopy {
            asked.append(site)
            UserDefaults.standard.set(Array(asked.suffix(500)), forKey: kept)
        }
        let browser = DefaultBrowser.name
        let send = { [weak self] in
            guard let self else { return }
            self.openInBrowser(url)
            if self.active.peek?.id == item { self.dismissPeek() }
        }
        // Says what's wrong and what each button does: a bare question left people guessing what "Always" meant.
        showToast(title: String(localized: "Open in \(browser)?"), detail: String(localized: "You're not signed in to \(site) here"),
                  symbol: "person.crop.circle.badge.questionmark", tint: .secondary, actionTitle: String(localized: "Just This Page"), duration: 12,
                  other: (String(localized: "Always for \(site)"), { [weak self] in
                      self?.setOpensInBrowser(site, true)
                      send()
                  }), action: send)
    }
}
