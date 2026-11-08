import AppKit
import SwiftUI
import TiriCore
import UserNotifications

struct TiriApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Tiri", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { TiriMenus(model: model) }
        // Files and links from outside are Tiri's to place. Left to SwiftUI, it shows this window for them by closing
        // and reopening it, and a window that closed forgets its workspace and comes back on the first one.
        .handlesExternalEvents(matching: [])
        // Each further window, with a workspace of its own. Tiri says what opens and what comes back.
        WindowGroup("Tiri", id: AppModel.workspaceWindowScene, for: String.self) { $windowID in
            WorkspaceWindowRoot(windowID: windowID)
                .environment(model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs are Tiri's own. A second layer of native window tabs would only confuse things.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Tiri draws its own find bars.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.finishLaunching()
        AppModel.shared.offerCrashReport()
        CopyHealth.startWatching()
        SafeStart.startWatching()
        SafeStart.announce(model: AppModel.shared)
        Self.saveOnTerminateSignal()
        // After a crash or a force quit, SwiftUI can start without opening its window. Terminals have
        // reattached by then, but nothing shows until the Dock icon is clicked, so do that for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                guard AppModel.shared.window == nil else { return }
                let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                                    targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                                    transactionID: AETransactionID(kAnyTransactionID))
                _ = try? reopen.sendEvent(options: [.noReply], timeout: 5)
            }
        }
    }

    private static var terminateSignal: DispatchSourceSignal?

    /// `kill`, `launchctl`, a shutdown that runs out of patience: a terminate signal would otherwise end Tiri
    /// on the spot, without saving the last moment's tabs or keeping unsaved edits.
    private static func saveOnTerminateSignal() {
        // A handler that does nothing, rather than ignoring it: what's ignored stays ignored in every program
        // Tiri starts, and a server in a terminal would shrug off `kill`. A handler goes back to normal there.
        var quiet = sigaction()
        quiet.__sigaction_u.__sa_handler = { _ in }
        sigaction(SIGTERM, &quiet, nil)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        // Sendable, so it isn't taken to belong to the main thread: run here, that would be a crash.
        source.setEventHandler { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CopyHealth.quitOnPurpose()
                    SafeStart.quitOnPurpose()
                    AppModel.shared.prepareForTermination()
                    exit(0)
                }
            }
            // A Tiri that's stuck still ends when asked to, as it did before.
            Thread.sleep(forTimeInterval: 3)
            _exit(0)
        }
        source.resume()
        terminateSignal = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppModel.shared.handleExternalOpen(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// False if someone chose to stay. Also asked before a switch, since nothing should have moved by then.
    static func settleUnsavedFiles() -> Bool {
        // Kept, they come back with their tabs, so there's nothing to ask, as in VS Code or Zed.
        if AppModel.shared.keepAllUnsavedEdits() { return true }
        guard let name = AppModel.shared.firstUnsavedFileName else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save your changes before quitting?")
        alert.informativeText = String(localized: "\(name) has unsaved changes.")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return AppModel.shared.saveAllEdits()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A switch has asked already, and has moved things since.
        if !AppModel.shared.keepTerminalsThroughQuit, !Self.settleUnsavedFiles() { return .terminateCancel }
        let working = AppModel.shared.workingTerminalCount
        guard working > 0, !AppModel.shared.skipQuitConfirmation else { return .terminateNow }
        // They'll still be running when Tiri comes back.
        if AppModel.shared.settings.terminalKeepRunning, TerminalSessions.helper != nil { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = working == 1 ? String(localized: "1 terminal is still working") : String(localized: "\(working) terminals are still working")
        alert.informativeText = String(localized: "Quitting stops them. Agent terminals resume where they left off when you reopen Tiri.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CopyHealth.quitOnPurpose()
        SafeStart.quitOnPurpose()
        AppModel.shared.prepareForTermination()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.applicationDidBecomeActive()
    }
}

/// The native menu bar. Key handling goes through `EventRouter`, so keybindings.json applies
/// everywhere; the shortcuts shown here are for discovery.
struct TiriMenus: Commands {
    let model: AppModel

    private func item(_ id: String) -> some View {
        let command = model.command(id)
        return Button(command?.shownTitle ?? id) { model.runFromMenu(id) }
            .modifier(MenuShortcut(binding: model.firstSingleStrokeBinding(for: id)))
    }

    var body: some Commands {
        // App menu: About with credits (who made it, the website, the source).
        CommandGroup(replacing: .appInfo) {
            Button("About \(AboutPanel.appName)") { AboutPanel.show() }
            item("checkForUpdates")
        }
        CommandGroup(replacing: .appSettings) {
            item("openSettings")
            if model.yourTiri.entriesAreOn { item("changeTiri") }
        }
        CommandGroup(replacing: .newItem) {
            item("newTerminal")
            Menu("New Terminal Preset") {
                ForEach(model.settings.activePresets) { preset in
                    Button(preset.name) { model.startTerminal(command: preset.command) }
                }
                Divider()
                Button("Manage Agents…") { model.openAgentSettings() }
            }
            Divider()
            item("newWindow")
            item("newWorkspace")
            item("addFolder")
            item("connectToServer")
            item("importWorkspace")
        }
        CommandGroup(replacing: .saveItem) {
            item("closeItem")
            item("reopenClosed")
        }
        CommandGroup(after: .textEditing) {
            item("find")
            item("findReplace")
        }
        CommandMenu("Go") {
            item("quickOpen")
            item("commandPalette")
            Divider()
            item("nextTab")
            item("previousTab")
            item("nextAttention")
            item("conversations")
            Divider()
            item("nextChange")
            item("previousChange")
            Divider()
            item("focusExplorer")
            item("revealActive")
        }
        CommandGroup(before: .sidebar) {
            item("toggleSidebar")
            Divider()
            item("splitRight")
            item("splitDown")
            Divider()
            // Source or rendered is the file's own business, a button above it, not the window's.
            item("openInExternalEditor")
            Divider()
        }
        CommandMenu("Plugins") {
            let _ = model.plugins.revision
            ForEach(model.commands.fromPlugins) { command in
                Button(command.shownTitle) { model.runFromMenu(command.id) }
                    .modifier(MenuShortcut(binding: model.firstSingleStrokeBinding(for: command.id)))
            }
            if !model.commands.fromPlugins.isEmpty { Divider() }
            item("newPlugin")
            item("managePlugins")
            item("reloadPlugins")
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Tiri") { Welcome.show(model: model) }
            Button("Tiri Agent Guide") { model.showAgentGuide() }
            Button("Tiri Website") { NSWorkspace.shared.open(AboutPanel.websiteURL) }
            Button("Release Notes") { NSWorkspace.shared.open(AboutPanel.releaseNotesURL) }
            Divider()
            Button("Report a Problem…") { model.reportProblem() }
        }
    }
}

private struct MenuShortcut: ViewModifier {
    let binding: KeyStroke?

    func body(content: Content) -> some View {
        if let binding, let shortcut = binding.swiftUIShortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

extension KeyStroke {
    var swiftUIShortcut: KeyboardShortcut? {
        var flags: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        let equivalent: KeyEquivalent
        switch key {
        case "tab": equivalent = .tab
        case "enter": equivalent = .return
        case "escape": equivalent = .escape
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "space": equivalent = .space
        case "backspace": equivalent = .delete
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }
}
