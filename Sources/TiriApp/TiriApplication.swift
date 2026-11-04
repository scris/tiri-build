import AppKit
import SwiftUI
import TiriCore
import UserNotifications

@main
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
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppModel.shared.handleExternalOpen(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let name = AppModel.shared.firstUnsavedFileName {
            let alert = NSAlert()
            alert.messageText = "Save your changes before quitting?"
            alert.informativeText = "\(name) has unsaved changes."
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !AppModel.shared.saveAllEdits() { return .terminateCancel }
            case .alertSecondButtonReturn:
                break
            default:
                return .terminateCancel
            }
        }
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
        CommandGroup(replacing: .appSettings) { item("openSettings") }
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
        }
        CommandMenu("Go") {
            item("quickOpen")
            item("commandPalette")
            Divider()
            item("nextTab")
            item("previousTab")
            item("nextAttention")
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
