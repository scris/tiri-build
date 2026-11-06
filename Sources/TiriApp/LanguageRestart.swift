import AppKit
import SwiftUI
import TiriCore

extension AppModel {
    /// Quits and opens `app` once this process is gone, keeping terminals running through it.
    /// False if the helper that waits couldn't start, and nothing has quit.
    func relaunch(app: String, arguments: [String] = []) -> Bool {
        keepTerminalsThroughQuit = true
        skipQuitConfirmation = true
        // -n, because the app it opens may still be there, waiting to see that this copy stayed up, and
        // being asked to open by something already running only brings it forward.
        var script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.02; done; exec /usr/bin/open -n"
        if AppModel.isTestCopy {
            script += " -g"
            for (key, value) in ProcessInfo.processInfo.environment where (key.hasPrefix("TIRI_") && key != "TIRI_PLAIN_ONCE" && key != "TIRI_DEV_OPTION") || key == "CODEX_HOME" || key == "GROK_HOME" {
                script += " --env " + ShellQuote.quote("\(key)=\(value)")
            }
        }
        script += " " + ShellQuote.quote(app)
        if !arguments.isEmpty { script += " --args " + arguments.map(ShellQuote.quote).joined(separator: " ") }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        guard (try? helper.run()) != nil else {
            keepTerminalsThroughQuit = false
            skipQuitConfirmation = false
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// After the language setting changes, from Settings or an agent. Said in the language chosen, since
    /// whoever chose it may not read the one Tiri is in now.
    func offerLanguageRestart() {
        let chosen = settings.language
        if let previous = languageToastID { dismissToast(previous) }
        guard chosen != AppLanguage.launched else { return }
        // System is whatever the Mac says, which this launch may already be in.
        let say = { (key: String) in
            chosen == .system ? Bundle.main.localizedString(forKey: key, value: key, table: nil) : chosen.localized(key)
        }
        languageToastID = showToast(title: say("Restart Tiri to switch language"), detail: say("Terminals keep running."),
                                    symbol: "globe", tint: .accentColor, actionTitle: say("Restart"), duration: 30) { [weak self] in
            self?.restartForLanguage()
        }
    }

    func restartForLanguage() {
        // A personal copy restarts through the app people installed, which hands over to it again.
        let plain = CopyState.load()?.plainPath
        let app = plain.flatMap { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/Tiri") ? $0 : nil } ?? Bundle.main.bundlePath
        if !relaunch(app: app) {
            showToast(title: String(localized: "Couldn't restart Tiri"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }
}
