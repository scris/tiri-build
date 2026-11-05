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
        CopyHealth.startWatching()
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppModel.shared.handleExternalOpen(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// False if someone chose to stay. Also asked before a switch, since nothing should have moved by then.
    static func settleUnsavedFiles() -> Bool {
        guard let name = AppModel.shared.firstUnsavedFileName else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes before quitting?"
        alert.informativeText = "\(name) has unsaved changes."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
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
        alert.messageText = working == 1 ? "1 terminal is still working" : "\(working) terminals are still working"
        alert.informativeText = "Quitting stops them. Agent terminals resume where they left off when you reopen Tiri."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CopyHealth.quitOnPurpose()
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
        return Button(command?.title ?? id) { model.runFromMenu(id) }
            .modifier(MenuShortcut(binding: model.firstSingleStrokeBinding(for: id)))
    }

    var body: some Commands {
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
            item("newWorkspace")
            item("addFolder")
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
            item("toggleMarkdownSource")
            item("openInExternalEditor")
            Divider()
        }
        CommandMenu("Plugins") {
            let _ = model.plugins.revision
            ForEach(model.commands.fromPlugins) { command in
                Button(command.title) { model.runFromMenu(command.id) }
                    .modifier(MenuShortcut(binding: model.firstSingleStrokeBinding(for: command.id)))
            }
            if !model.commands.fromPlugins.isEmpty { Divider() }
            item("newPlugin")
            item("managePlugins")
            item("reloadPlugins")
        }
        CommandGroup(replacing: .help) {
            Button("Tiri Agent Guide") { model.showAgentGuide() }
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
