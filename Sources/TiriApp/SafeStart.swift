import AppKit
import SwiftUI
import TiriCore

/// After two launches in a row that didn't finish, Tiri starts without what most often stops it: plugins, language
/// servers and the rest of what it starts by itself. Workspaces, tabs and terminals all come back. Quitting, or staying
/// up a little while, ends it. Personal copies have their own watch, in `HandOff`, so this is the app people installed.
enum SafeStart {
    nonisolated(unsafe) static var isOn = false
    /// The record from before this launch, which says whether an update came just before.
    nonisolated(unsafe) private static var before = LaunchRecord()
    nonisolated(unsafe) private static var counted = false

    /// Becomes the app: the only one for this state folder, and counted until it has shown it stays up.
    static func runApp(isPersonal: Bool) {
        claimOrLeave()
        if !isPersonal {
            let begun = LaunchRecord.begin()
            counted = true
            before = begun.before
            isOn = begun.safe
        }
        TiriApplication.main()
    }

    /// Another Tiri has this state folder: it's brought forward, and this one goes before touching anything.
    private static func claimOrLeave() {
        guard !InstanceLock.claim() else { return }
        // Not through its socket: that would wait on its main thread, which may be what's busy. A test copy is never brought forward.
        if !AppModel.isTestCopy, let pid = InstanceLock.holder(), let other = NSRunningApplication(processIdentifier: pid) {
            other.activate()
        }
        exit(0)
    }

    static func startWatching() {
        guard counted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + YourTiri.healthyAfter) { LaunchRecord.finish() }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            DispatchQueue.global(qos: .utility).async { UpdateRollback.tidy(running: version) }
        }
    }

    static func quitOnPurpose() {
        if counted { LaunchRecord.finish() }
    }

    /// One toast, and with it the way back if an update came just before.
    @MainActor static func announce(model: AppModel) {
        guard isOn else { return }
        let back = before.updatedFrom.flatMap { UpdateRollback.available(installed: Bundle.main.bundleURL, expected: $0) }
        let restart = (title: String(localized: "Restart"), action: { _ = model.relaunch(app: Bundle.main.bundlePath) })
        if let back {
            model.showToast(title: String(localized: "Tiri started without plugins"),
                            detail: String(localized: "It stopped twice after updating. Plugins are off for now."),
                            symbol: "exclamationmark.shield", tint: .orange, actionTitle: String(localized: "Go Back to Tiri \(back)"), duration: nil,
                            other: restart) { goBack(model: model) }
        } else {
            model.showToast(title: String(localized: "Tiri started without plugins"),
                            detail: String(localized: "It stopped twice while starting. Plugins and language servers are off for now."),
                            symbol: "exclamationmark.shield", tint: .orange, actionTitle: String(localized: "Restart"), duration: 30) {
                _ = model.relaunch(app: Bundle.main.bundlePath)
            }
        }
    }

    @MainActor private static func goBack(model: AppModel) {
        let installed = Bundle.main.bundleURL
        do {
            try UpdateRollback.run(installed: installed)
        } catch {
            model.showToast(title: String(localized: "Couldn't go back"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        // The earlier release is where this one was, and opening that path opens it.
        if !model.relaunch(app: installed.path) {
            model.showToast(title: String(localized: "Couldn't restart Tiri"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }
}
