import Foundation
import Testing
@testable import TiriCore

struct EditorImportTests {
    let commands: Set<String> = ["quickOpen", "commandPalette", "toggleSidebar", "splitRight", "toggleLineComment", "openRecent"]

    func plan(_ settings: [String: Any], _ keybindings: [[String: Any]] = [], current: TiriSettings = TiriSettings()) -> EditorImport.Plan {
        EditorImport.plan(editor: "Cursor", settings: settings, keybindings: keybindings, current: current, commands: commands)
    }

    @Test func settingsThatMeanTheSameComeOver() {
        let result = plan([
            "editor.fontFamily": "'Fira Code', Menlo, monospace",
            "editor.fontSize": 14,
            "terminal.integrated.fontSize": 40,
            "editor.wordWrap": "wordWrapColumn",
            "editor.wordWrapColumn": 100,
            "diffEditor.renderSideBySide": true,
            "files.exclude": ["**/.venv": true, "**/dist": false],
            "window.autoDetectColorScheme": true,
            "workbench.colorTheme": "Cursor Dark Midnight",
            "editor.minimap.enabled": false,
        ])
        let settings = Dictionary(uniqueKeysWithValues: result.settings.map { ($0.key, $0.value) })
        #expect(settings["code.fontFamily"] == .string("Fira Code"))
        #expect(settings["code.fontSize"] == .double(14))
        #expect(settings["terminal.fontSize"] == .double(32), "kept within what Tiri allows")
        #expect(settings["editor.wordWrap"] == .string("bounded"))
        #expect(settings["editor.wordWrapColumn"] == .int(100))
        #expect(settings["diff.sideBySide"] == .bool(true))
        #expect(settings["files.exclude"] == .array((TiriSettings().filesExclude + ["**/.venv"]).map(JSONValue.string)))
        #expect(settings["theme"] == nil, "already follows the Mac")
        #expect(result.theme == "Cursor Dark Midnight")
        #expect(settings.count == 7)
    }

    @Test func whatsTheSameHereAlreadyIsLeftAlone() {
        var current = TiriSettings()
        current.codeFontSize = 14
        current.editorWordWrap = .on
        let result = plan(["editor.fontSize": 14, "editor.wordWrap": "on", "explorer.compactFolders": true], current: current)
        #expect(result.isEmpty)
    }

    @Test func shortcutsForCommandsTiriHas() {
        let result = plan([:], [
            ["key": "cmd+e", "command": "workbench.action.quickOpen"],
            ["key": "cmd+k cmd+s", "command": "workbench.action.showCommands"],
            ["key": "meta+/", "command": "editor.action.commentLine", "when": "editorTextFocus && !editorReadonly"],
            ["key": "cmd+b", "command": "-workbench.action.toggleSidebarVisibility"],
            ["key": "cmd+j", "command": "workbench.action.togglePanel"],
            ["key": "cmd+[Slash]", "command": "workbench.action.quickOpen"],
            ["key": "ctrl+r", "command": "workbench.action.openRecent", "when": "inQuickOpen"],
        ])
        #expect(result.shortcuts.map(\.key) == ["cmd+e", "cmd+k cmd+s", "cmd+/", "cmd+b"])
        #expect(result.shortcuts.map(\.command) == ["quickOpen", "commandPalette", "toggleLineComment", "-toggleSidebar"])
        #expect(result.shortcutsLeftOut == 3)
    }

    @Test func fontListsSkipGenericNames() {
        #expect(EditorImport.firstFont("monospace, 'JetBrains Mono'") == "JetBrains Mono")
        #expect(EditorImport.firstFont("monospace") == nil)
    }

    @Test func readsTheirFilesWithComments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "{\n  // mine\n  \"editor.fontSize\": 15,\n}\n".write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "[ { \"key\": \"cmd+e\", \"command\": \"workbench.action.quickOpen\" }, ]".write(to: folder.appendingPathComponent("keybindings.json"), atomically: true, encoding: .utf8)
        let result = EditorImport.plan(for: .init(name: "Cursor", userFolder: folder.path), current: TiriSettings(), commands: commands)
        #expect(result.settings.map(\.key) == ["code.fontSize"])
        #expect(result.shortcuts.map(\.command) == ["quickOpen"])
    }

    @Test func everyMappedCommandExists() {
        // The table only names commands Tiri has; the app checks again against its own list.
        let ids = Set(Keymap.defaults.map(\.1))
        let unbound: Set<String> = ["closeWorkspace", "newWorkspace", "addFolder", "openRecent"]
        for command in Set(EditorImport.commandIDs.values) where !unbound.contains(command) {
            #expect(ids.contains(command), "\(command)")
        }
    }
}
