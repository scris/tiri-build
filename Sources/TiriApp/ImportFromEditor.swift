import AppKit
import SwiftUI
import TiriCore

/// Cursor or VS Code's setup in one step: what means the same here, their theme and their shortcuts. Then a
/// toast says what came over, with Undo. Their folders are in Open Recent already.
extension AppModel {
    /// Editors on this Mac that have something Tiri would take, best first.
    func editorsToImport() -> [(editor: EditorImport.Editor, plan: EditorImport.Plan)] {
        EditorImport.editors(home: RecentWorkspaces.home).compactMap { editor in
            var plan = importPlan(for: editor)
            if let theme = plan.theme, themeToImport(named: theme, from: editor) == nil { plan.theme = nil }
            return plan.isEmpty ? nil : (editor, plan)
        }
    }

    /// Their plan, less a font this Mac doesn't have: it would show as some other font.
    func importPlan(for editor: EditorImport.Editor) -> EditorImport.Plan {
        var plan = EditorImport.plan(for: editor, current: settings, commands: Set(allCommands.map(\.id)))
        let families = Set(NSFontManager.shared.availableFontFamilies)
        plan.settings.removeAll { setting in
            guard setting.key.hasSuffix("fontFamily"), let family = setting.value.stringValue else { return false }
            return !families.contains(family)
        }
        return plan
    }

    /// The theme the editor uses, if Tiri can read it and doesn't have it on already.
    private func themeToImport(named name: String, from editor: EditorImport.Editor) -> ThemeDiscovery.Found? {
        if activeTheme.name.caseInsensitiveCompare(name) == .orderedSame { return nil }
        let available = ThemeDiscovery.available(home: RecentWorkspaces.home)
        return available.first { $0.name == name && editor.name.contains($0.from) } ?? available.first { $0.name == name }
    }

    /// From the palette: the editor with the most to bring, or a choice when there's more than one.
    func importFromEditorInteractive() {
        let found = editorsToImport()
        switch found.count {
        case 0:
            showToast(title: String(localized: "Nothing to bring in"), detail: String(localized: "No Cursor or VS Code settings on this Mac differ from Tiri's."),
                      symbol: "checkmark", tint: .secondary)
        case 1:
            importFromEditor(found[0].editor)
        default:
            openPalette(.choices(title: String(localized: "Bring in settings from"), rows: found.map { entry in
                PaletteModel.Row(id: entry.editor.name, title: entry.editor.name, detail: Self.importSummary(entry.plan), symbol: "square.and.arrow.down",
                                 action: { [weak self] _ in
                                     self?.closePalette()
                                     self?.importFromEditor(entry.editor)
                                 })
            }))
        }
    }

    @discardableResult
    func importFromEditor(_ editor: EditorImport.Editor) -> EditorImport.Plan? {
        var plan = importPlan(for: editor)
        // As they were, for Undo.
        let settingsBefore = try? Data(contentsOf: settingsStore.settingsURL)
        let keybindingsBefore = try? Data(contentsOf: settingsStore.keybindingsURL)

        var settingsDone = 0
        for (key, value) in plan.settings where setSetting(key, to: value) == nil { settingsDone += 1 }
        plan.settings = Array(plan.settings.prefix(settingsDone))

        if let name = plan.theme, let found = themeToImport(named: name, from: editor) {
            if (try? importTheme(from: URL(fileURLWithPath: found.path), named: found.name, use: true)) == nil { plan.theme = nil }
        } else {
            plan.theme = nil
        }

        // Each one replaces whatever had its key, as theirs did there. One Tiri can't take is left out, never the file.
        var list = settingsStore.userKeybindings
        var taken: [(key: String, command: String)] = []
        for shortcut in plan.shortcuts {
            let removing = shortcut.command.hasPrefix("-")
            let command = removing ? String(shortcut.command.dropFirst()) : shortcut.command
            if !removing, Keymap.problem(with: shortcut.key, command: command, bindings: keybindings) != nil { continue }
            guard let strokes = Keymap.parseStrokes(shortcut.key) else { continue }
            if !removing { list.removeAll { !$0.command.hasPrefix("-") && Keymap.parseStrokes($0.key) == strokes } }
            list.removeAll { $0.key == shortcut.key && $0.command == shortcut.command }
            list.append(shortcut)
            taken.append(shortcut)
        }
        plan.shortcutsLeftOut += plan.shortcuts.count - taken.count
        plan.shortcuts = taken
        if !taken.isEmpty, (try? settingsStore.writeKeybindings(list)) == nil {
            plan.shortcuts = []
        }

        guard !plan.isEmpty else {
            showToast(title: String(localized: "Nothing to bring in"), detail: String(localized: "No Cursor or VS Code settings on this Mac differ from Tiri's."),
                      symbol: "checkmark", tint: .secondary)
            return plan
        }
        let settingsURL = settingsStore.settingsURL, keybindingsURL = settingsStore.keybindingsURL
        showToast(title: String(localized: "Brought in your \(editor.name) setup"), detail: Self.importSummary(plan),
                  symbol: "square.and.arrow.down", tint: .accentColor, actionTitle: String(localized: "Undo"), duration: 12) {
            if let settingsBefore { try? DurableFile.write(settingsBefore, to: settingsURL) }
            if let keybindingsBefore { try? DurableFile.write(keybindingsBefore, to: keybindingsURL) }
        }
        return plan
    }

    /// "Theme, 5 settings and 3 shortcuts", the way people would say it.
    static func importSummary(_ plan: EditorImport.Plan) -> String {
        var parts: [String] = []
        if let theme = plan.theme { parts.append(String(localized: "the theme \(theme)")) }
        let settings = plan.settings.count, shortcuts = plan.shortcuts.count
        if settings > 0 { parts.append(settings == 1 ? String(localized: "1 setting") : String(localized: "\(settings) settings")) }
        if shortcuts > 0 { parts.append(shortcuts == 1 ? String(localized: "1 shortcut") : String(localized: "\(shortcuts) shortcuts")) }
        return ListFormatter.localizedString(byJoining: parts)
    }
}
