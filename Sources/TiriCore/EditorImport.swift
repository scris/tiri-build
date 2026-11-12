import Foundation

/// Bringing someone's Cursor or VS Code setup into Tiri in one step: the settings that mean the same thing
/// here, their theme, and their shortcuts for commands Tiri has. Folders come by Open Recent, not from here.
public enum EditorImport {
    public struct Editor: Equatable, Sendable {
        public var name: String
        public var userFolder: String

        public var settingsPath: String { userFolder + "/settings.json" }
        public var keybindingsPath: String { userFolder + "/keybindings.json" }
    }

    /// What would change, and what couldn't come over.
    public struct Plan: Equatable, Sendable {
        public var editor: String
        public var settings: [(key: String, value: JSONValue)] = []
        /// The theme's name as the editor knows it.
        public var theme: String?
        public var shortcuts: [(key: String, command: String)] = []
        /// Shortcuts left out: a command Tiri doesn't have, or one that only applies somewhere specific.
        public var shortcutsLeftOut = 0

        public var isEmpty: Bool { settings.isEmpty && theme == nil && shortcuts.isEmpty }

        public init(editor: String) { self.editor = editor }

        public static func == (a: Plan, b: Plan) -> Bool {
            a.editor == b.editor && a.theme == b.theme && a.shortcutsLeftOut == b.shortcutsLeftOut
                && a.settings.map(\.key) == b.settings.map(\.key) && a.settings.map(\.value) == b.settings.map(\.value)
                && a.shortcuts.map(\.key) == b.shortcuts.map(\.key) && a.shortcuts.map(\.command) == b.shortcuts.map(\.command)
        }
    }

    public static let editorNames = ["Cursor", "Code", "Windsurf", "VSCodium", "Code - Insiders"]

    /// Editors on this Mac with settings of their own, in the order people most likely use them.
    public static func editors(home: String = NSHomeDirectory()) -> [Editor] {
        editorNames.compactMap { name in
            let user = home + "/Library/Application Support/" + name + "/User"
            let editor = Editor(name: name == "Code" ? "VS Code" : name, userFolder: user)
            let manager = FileManager.default
            guard manager.fileExists(atPath: editor.settingsPath) || manager.fileExists(atPath: editor.keybindingsPath) else { return nil }
            return editor
        }
    }

    public static func plan(for editor: Editor, current: TiriSettings, commands: Set<String>) -> Plan {
        let settings = read(editor.settingsPath) as? [String: Any] ?? [:]
        let keybindings = read(editor.keybindingsPath) as? [[String: Any]] ?? []
        return plan(editor: editor.name, settings: settings, keybindings: keybindings, current: current, commands: commands)
    }

    static func read(_ path: String) -> Any? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8))
    }

    // MARK: Settings

    /// Only what was set on purpose there (that's all their settings.json holds), and only where it differs here.
    public static func plan(editor: String, settings: [String: Any], keybindings: [[String: Any]],
                            current: TiriSettings, commands: Set<String>) -> Plan {
        var plan = Plan(editor: editor)
        func add(_ key: String, _ value: JSONValue?, unless now: JSONValue) {
            guard let value, value != now else { return }
            plan.settings.append((key, value))
        }
        func raw(_ key: String, in range: ClosedRange<Double>) -> Double? {
            guard let value = settings[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return min(max(value.doubleValue, range.lowerBound), range.upperBound)
        }
        func number(_ key: String, in range: ClosedRange<Double>) -> JSONValue? { raw(key, in: range).map(JSONValue.double) }
        func bool(_ key: String) -> JSONValue? {
            guard let value = settings[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return .bool(value.boolValue)
        }

        add("code.fontFamily", (settings["editor.fontFamily"] as? String).flatMap(firstFont).map(JSONValue.string), unless: .string(current.codeFontFamily))
        add("code.fontSize", number("editor.fontSize", in: 8...32), unless: .double(current.codeFontSize))
        add("terminal.fontFamily", (settings["terminal.integrated.fontFamily"] as? String).flatMap(firstFont).map(JSONValue.string),
            unless: .string(current.terminalFontFamily))
        add("terminal.fontSize", number("terminal.integrated.fontSize", in: 8...32), unless: .double(current.terminalFontSize))
        if let lines = raw("terminal.integrated.scrollback", in: 1_000...200_000) {
            add("terminal.scrollback", .int(Int(lines)), unless: .int(current.terminalScrollback))
        }
        if let wrap = settings["editor.wordWrap"] as? String {
            // VS Code's "wordWrapColumn" wraps at the column alone; Tiri's "bounded" is the nearest.
            let mapped = ["off": "off", "on": "on", "bounded": "bounded", "wordWrapColumn": "bounded"][wrap]
            add("editor.wordWrap", mapped.map(JSONValue.string), unless: .string(current.editorWordWrap.rawValue))
        }
        if let column = raw("editor.wordWrapColumn", in: 20...1_000) {
            add("editor.wordWrapColumn", .int(Int(column)), unless: .int(current.editorWordWrapColumn))
        }
        add("diff.sideBySide", bool("diffEditor.renderSideBySide"), unless: .bool(current.diffSideBySide))
        add("explorer.compactFolders", bool("explorer.compactFolders"), unless: .bool(current.explorerCompactFolders))
        if let reveal = settings["explorer.autoReveal"] {
            // `true`, `false` or "focusNoScroll", which still follows.
            let follows = (reveal as? NSNumber)?.boolValue ?? (reveal as? String).map { _ in true }
            add("explorer.autoReveal", follows.map(JSONValue.bool), unless: .bool(current.explorerAutoReveal))
        }
        if let excluded = settings["files.exclude"] as? [String: Any] {
            let patterns = excluded.compactMap { pattern, on in (on as? NSNumber)?.boolValue == true ? pattern : nil }
            let merged = current.filesExclude + patterns.sorted().filter { !current.filesExclude.contains($0) }
            if merged != current.filesExclude { plan.settings.append(("files.exclude", .array(merged.map(JSONValue.string)))) }
        }
        if (settings["window.autoDetectColorScheme"] as? NSNumber)?.boolValue == true {
            add("theme", .string("system"), unless: .string(current.theme.rawValue))
        }
        plan.theme = settings["workbench.colorTheme"] as? String

        // MARK: Shortcuts
        for entry in keybindings {
            guard let key = entry["key"] as? String, let raw = entry["command"] as? String else { continue }
            let removing = raw.hasPrefix("-")
            let name = removing ? String(raw.dropFirst()) : raw
            guard let command = commandIDs[name], commands.contains(command), isGeneral(entry["when"] as? String),
                  let normalized = normalizedKey(key) else {
                plan.shortcutsLeftOut += 1
                continue
            }
            plan.shortcuts.append((normalized, (removing ? "-" : "") + command))
        }
        return plan
    }

    /// The first family in a CSS-style list that isn't a generic one: `"'Fira Code', Menlo, monospace"` is Fira Code.
    static func firstFont(_ list: String) -> String? {
        let generic: Set<String> = ["monospace", "serif", "sans-serif", "ui-monospace", "system-ui", "-apple-system", "blinkmacsystemfont"]
        return list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .first { !$0.isEmpty && !generic.contains($0.lowercased()) }
    }

    /// A shortcut that applies wherever you type is the same here. One tied to a panel Tiri doesn't have isn't.
    static func isGeneral(_ when: String?) -> Bool {
        guard let when = when?.trimmingCharacters(in: .whitespaces), !when.isEmpty else { return true }
        let general: Set<String> = ["editorTextFocus", "editorFocus", "textInputFocus", "editorTextFocus && !editorReadonly",
                                    "terminalFocus", "!terminalFocus", "editorTextFocus && !editorHasSelection"]
        return general.contains(when)
    }

    /// VS Code's spelling of a key, as Tiri reads it: `cmd+k cmd+s`. Keys VS Code names by their place on the
    /// keyboard (`[Slash]`) are left out, as is anything longer than two presses.
    static func normalizedKey(_ key: String) -> String? {
        let presses = key.lowercased().split(separator: " ").map { press in
            press.split(separator: "+").map { part -> String in
                switch part {
                case "meta", "command": return "cmd"
                case "option": return "alt"
                case "control": return "ctrl"
                default: return String(part)
                }
            }.joined(separator: "+")
        }
        guard (1...2).contains(presses.count), !presses.contains(where: { $0.contains("[") }) else { return nil }
        return presses.joined(separator: " ")
    }

    /// VS Code's command names for the commands Tiri has.
    public static let commandIDs: [String: String] = [
        "workbench.action.quickOpen": "quickOpen",
        "workbench.action.showCommands": "commandPalette",
        "workbench.action.toggleSidebarVisibility": "toggleSidebar",
        "workbench.view.explorer": "focusExplorer",
        "workbench.action.terminal.new": "newTerminal",
        "workbench.action.terminal.toggleTerminal": "newTerminal",
        "workbench.action.splitEditor": "splitRight",
        "workbench.action.splitEditorRight": "splitRight",
        "workbench.action.splitEditorDown": "splitDown",
        "workbench.action.closeActiveEditor": "closeItem",
        "workbench.action.reopenClosedEditor": "reopenClosed",
        "workbench.action.nextEditor": "nextTab",
        "workbench.action.previousEditor": "previousTab",
        "actions.find": "find",
        "editor.action.startFindReplaceAction": "findReplace",
        "workbench.action.files.save": "saveFile",
        "editor.action.revealDefinition": "goToDefinition",
        "editor.action.goToDeclaration": "goToDefinition",
        "editor.action.goToReferences": "findReferences",
        "references-view.findReferences": "findReferences",
        "editor.action.showHover": "showHover",
        "workbench.action.navigateBack": "goBack",
        "workbench.action.findInFiles": "searchInFiles",
        "workbench.view.search": "searchInFiles",
        "workbench.action.openSettings": "openSettings",
        "editor.action.commentLine": "toggleLineComment",
        "editor.action.indentLines": "indentLines",
        "editor.action.outdentLines": "outdentLines",
        "editor.action.moveLinesUpAction": "moveLinesUp",
        "editor.action.moveLinesDownAction": "moveLinesDown",
        "editor.action.copyLinesUpAction": "copyLinesUp",
        "editor.action.copyLinesDownAction": "copyLinesDown",
        "editor.action.deleteLines": "deleteLine",
        "editor.action.addSelectionToNextFindMatch": "addNextOccurrence",
        "editor.action.triggerSuggest": "triggerCompletion",
        "workbench.action.gotoLine": "goToLine",
        "editor.action.toggleWordWrap": "toggleWordWrap",
        "workbench.action.gotoSymbol": "symbolsInFile",
        "workbench.action.showAllSymbols": "symbolsInWorkspace",
        "workbench.action.zoomIn": "zoomIn",
        "workbench.action.zoomOut": "zoomOut",
        "workbench.action.zoomReset": "zoomReset",
        "workbench.action.terminal.clear": "clearTerminal",
        "workbench.action.newWindow": "newWindow",
        "editor.action.insertLineAfter": "insertLineBelow",
        "editor.action.insertLineBefore": "insertLineAbove",
        "workbench.action.openRecent": "openRecent",
        "workbench.action.closeFolder": "closeWorkspace",
        "workbench.action.files.openFolder": "newWorkspace",
        "workbench.action.addRootFolder": "addFolder",
    ]
}
