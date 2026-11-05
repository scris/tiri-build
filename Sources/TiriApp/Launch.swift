import AppKit
import CoreGraphics
import TiriCore

/// The first thing a launch does. Everyone who has never changed Tiri pays for one failed file open here.
@main
enum TiriEntry {
    static func main() {
        // Before any look at state: this is the new release putting itself in place of the old one.
        if let flag = CommandLine.arguments.firstIndex(of: UpdateInstall.flag), CommandLine.arguments.count > flag + 1 {
            UpdateInstall.run(target: CommandLine.arguments[flag + 1])
        }
        let state = CopyState.load()
        // No state and not a personal copy is everyone else, and nothing further gets looked at.
        let isPersonal = Bundle.main.object(forInfoDictionaryKey: YourTiri.copyKey) as? String == "personal"
        guard state != nil || isPersonal else {
            TiriApplication.main()
            return
        }
        // Before anything can go looking for it: the app may have moved, or been updated, while another copy ran.
        if !isPersonal, var known = state {
            let (path, identifier, version) = (Bundle.main.bundlePath, Bundle.main.bundleIdentifier, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            if known.plainPath != path || known.plainBundleID != identifier || known.plainVersion != version {
                known.plainPath = path
                known.plainBundleID = identifier
                known.plainVersion = version
                try? known.save()
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let input = LaunchGate.Input(state: state, isPersonalCopy: isPersonal, optionHeld: optionHeld(environment),
                                     plainOnce: environment["TIRI_PLAIN_ONCE"] == "1",
                                     personalExists: FileManager.default.isExecutableFile(atPath: YourTiri.current.appendingPathComponent("Contents/MacOS/Tiri").path))
        switch LaunchGate.choose(input) {
        case .runHere:
            if input.optionHeld || input.plainOnce, !isPersonal { PlainForNow.isOn = true }
            TiriApplication.main()
        case .openPersonal:
            HandOff.run(to: .personal)
        case .openPlain:
            HandOff.run(to: .plain)
        case .fallBack:
            var changed = state ?? CopyState()
            changed.fallBack()
            try? changed.save()
            if changed.active == .personal { HandOff.run(to: .personal) } else { TiriApplication.main() }
        case .personalMissing:
            var changed = state ?? CopyState()
            changed.active = .plain
            changed.trial = nil
            changed.notice = "Your copy of Tiri wasn't there, so this is Plain Tiri. Your changes are kept."
            try? changed.save()
            TiriApplication.main()
        }
    }

    private static func optionHeld(_ environment: [String: String]) -> Bool {
        // A test copy can't be pressed, and shouldn't read a key someone is holding for something else.
        if AppModel.isTestCopy { return environment["TIRI_DEV_OPTION"] == "1" }
        return CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }
}

/// Pressing Update, once the app that was running has gone. It's the new release that does this, signed by
/// whoever made the old one, because macOS only lets an app be replaced by something from the same maker.
enum UpdateInstall {
    static let flag = "--tiri-install-into"

    static func run(target: String) -> Never {
        let targetURL = URL(fileURLWithPath: target)
        let own = Bundle.main.bundleURL
        let previous = YourTiri.updates.appendingPathComponent("previous/Tiri.app")
        // Only ever what state says is installed, and only from where a waiting update sits.
        var allowed = CopyState.load()?.plainPath == target && own.standardizedFileURL.path == YourTiri.updates.appendingPathComponent("waiting/Tiri.app").standardizedFileURL.path
        // Checked here too, since this can be run by hand: only forward, and only from whoever made what's there.
        if allowed, (try? UpdateTools.checkRelease(own, replacing: targetURL)) == nil { allowed = false }
        if allowed, (try? CopyFiles.swap(own, targetURL)) != nil {
            // Now `own` is the old release, under the waiting name.
            try? CopyFiles.move(own, to: previous)
            // Only now the source and the copy move, so that one that couldn't go in place changes nothing.
            do {
                try UpdateTools.commitToUpdate()
            } catch {
                if var state = CopyState.load() {
                    state.notice = "\(error)"
                    try? state.save()
                }
            }
            try? FileManager.default.removeItem(at: UpdateStatus.file)
            if var state = CopyState.load(), let installed = Bundle(url: targetURL) {
                state.plainVersion = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                state.plainBundleID = installed.bundleIdentifier
                try? state.save()
            }
        } else if var state = CopyState.load() {
            state.notice = "Tiri couldn't put the update in place, so nothing changed."
            try? state.save()
        }
        // -n, or macOS would call this process, which has the same bundle ID, that app already running.
        var arguments = ["-n"]
        if AppModel.isTestCopy {
            arguments.append("-g")
            for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("TIRI_") {
                arguments += ["--env", "\(key)=\(value)"]
            }
        }
        arguments.append(target)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        try? open.run()
        open.waitUntilExit()
        exit(0)
    }
}

/// Held ⌥ at launch: Plain Tiri for this one run, with the choice of what runs next time left alone.
enum PlainForNow {
    nonisolated(unsafe) static var isOn = false
}

/// Starts the copy that should be running and stays, unseen, until it has shown it can stay up.
/// It's this copy that can do that, because a broken personal copy can't be relied on to look after itself.
final class HandOff: NSObject, NSApplicationDelegate {
    private let destination: CopyState.Active
    private var opened: [URL] = []
    private var watchTimer: Timer?
    private var launches = 0
    private static var current: HandOff?

    init(destination: CopyState.Active) {
        self.destination = destination
    }

    /// Never returns: it ends when its work is done.
    static func run(to destination: CopyState.Active) {
        let app = NSApplication.shared
        // Nothing of this one in the Dock or the app switcher.
        app.setActivationPolicy(.prohibited)
        // An app holds its delegate weakly.
        current = HandOff(destination: destination)
        app.delegate = current
        app.run()
    }

    /// Documents arrive between these two, and must reach whichever copy runs.
    func application(_ application: NSApplication, open urls: [URL]) {
        opened += urls
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launch()
    }

    private static var isTestCopy: Bool { AppModel.isTestCopy }

    private func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !Self.isTestCopy
        if Self.isTestCopy {
            // A test copy's state is named in its environment, and a copy with none would use real state.
            configuration.environment = ProcessInfo.processInfo.environment.filter {
                $0.key.hasPrefix("TIRI_") || $0.key == "CODEX_HOME" || $0.key == "GROK_HOME"
            }
        }
        return configuration
    }

    private func launch() {
        switch destination {
        case .plain: openPlain()
        case .personal: openPersonal()
        }
    }

    private func openPlain() {
        guard let path = CopyState.load()?.plainPath, FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/Tiri") else {
            // There's nowhere to hand over to, and being something is better than being nothing.
            let alert = NSAlert()
            alert.messageText = "Tiri can't find the app it came from."
            alert.informativeText = "Open Tiri from where you installed it."
            alert.runModal()
            exit(1)
        }
        let configuration = configuration()
        // Told by what's in the environment for the sake of this one launch, whatever state says.
        configuration.environment = configuration.environment.merging(["TIRI_PLAIN_ONCE": "1"]) { _, new in new }
        configuration.createsNewApplicationInstance = true
        finish(opening: URL(fileURLWithPath: path), configuration: configuration) { _ in exit(0) }
    }

    private func openPersonal() {
        let current = YourTiri.current
        let identifier = Bundle(url: current)?.bundleIdentifier
        // Already up, as with a click on the other Dock tile. Only bring it forward.
        if let identifier, !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            finish(opening: current, configuration: configuration()) { _ in exit(0) }
            return
        }
        var state = CopyState.load() ?? CopyState()
        state.attempts += 1
        state.lastAttempt = Date()
        try? state.save()
        launches += 1
        let thisLaunch = launches
        finish(opening: current, configuration: configuration()) { [weak self] process in
            // macOS can refuse to start it, and that's the same as it dying straight away.
            guard let self, process == nil, self.launches == thisLaunch else { return }
            self.died()
        }
        watch(identifier)
    }

    private func finish(opening app: URL, configuration: NSWorkspace.OpenConfiguration, then done: @escaping @Sendable @MainActor (pid_t?) -> Void) {
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { launched, _ in
            let process = launched?.processIdentifier
            DispatchQueue.main.async { MainActor.assumeIsolated { done(process) } }
        }
        if opened.isEmpty {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(opened, withApplicationAt: app, configuration: configuration, completionHandler: completion)
        }
    }

    /// Ends when it's clear which way it went. An early death is tried once more, and then Tiri goes back.
    /// This keeps its own clock, because a program that dies before it has told macOS it's an app can leave
    /// the request to open it unanswered for a long time.
    private func watch(_ identifier: String?) {
        let started = Date()
        var seen: pid_t?
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // It says so when it's been up long enough, or when it quit on purpose.
                if CopyState.load()?.attempts == 0 { exit(0) }
                let waited = Date().timeIntervalSince(started)
                if waited > YourTiri.healthyAfter + 5 { exit(0) }
                if seen == nil, let identifier { seen = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.processIdentifier }
                if let seen {
                    if kill(seen, 0) != 0 { self?.died() }
                } else if waited > 8 {
                    self?.died()
                }
            }
        }
    }

    private func died() {
        watchTimer?.invalidate()
        watchTimer = nil
        var state = CopyState.load() ?? CopyState()
        // Quit on purpose, in the moment before the timer looked.
        if state.attempts == 0 { exit(0) }
        if state.isCrashLooping {
            state.fallBack()
            try? state.save()
            let configuration = configuration()
            configuration.createsNewApplicationInstance = true
            // This one has no window and can't become the app any more, so a new one looks at state again.
            finish(opening: Bundle.main.bundleURL, configuration: configuration) { _ in exit(0) }
            return
        }
        openPersonal()
    }
}

/// A personal copy says when it has stayed up, or quit on purpose, which is what ends `HandOff`'s watch.
enum CopyHealth {
    private static var isPersonal: Bool { Bundle.main.object(forInfoDictionaryKey: YourTiri.copyKey) as? String == "personal" }

    static func startWatching() {
        guard isPersonal else { return }
        importSettingsOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + YourTiri.healthyAfter) { settle() }
    }

    static func quitOnPurpose() {
        if isPersonal { settle() }
    }

    private static func settle() {
        guard var state = CopyState.load(), state.attempts != 0 else { return }
        state.attempts = 0
        state.lastAttempt = nil
        try? state.save()
    }

    /// A personal copy has its own bundle ID, and so its own small preferences: what's folded, which notebook
    /// kernel was chosen. It starts from the installed app's.
    private static func importSettingsOnce() {
        let key = "TiriImportedPlainPreferences"
        guard !UserDefaults.standard.bool(forKey: key), let plain = CopyState.load()?.plainBundleID else { return }
        for (name, value) in UserDefaults.standard.persistentDomain(forName: plain) ?? [:] where UserDefaults.standard.object(forKey: name) == nil {
            UserDefaults.standard.set(value, forKey: name)
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
