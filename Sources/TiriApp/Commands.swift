import AppKit
import SwiftUI
import TiriCore

/// Every app action, in one place. Keybindings, the command palette, the menu bar and
/// `tiri run` all call through this, so they can't drift apart.
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    let action: (AppModel) -> Void
}

extension AppModel {
    static let staticCommands: [AppCommand] = {
        var list: [AppCommand] = [
            AppCommand(id: "quickOpen", title: "Go to File…", category: "Go") { $0.openPalette(.files) },
            AppCommand(id: "commandPalette", title: "Show All Commands", category: "Go") { $0.openPalette(.commands) },
            AppCommand(id: "nextTab", title: "Next Tab", category: "Go") { model in
                model.updateActive { $0.cycleTab(by: 1) }
                model.requestFocus()
            },
            AppCommand(id: "previousTab", title: "Previous Tab", category: "Go") { model in
                model.updateActive { $0.cycleTab(by: -1) }
                model.requestFocus()
            },
            AppCommand(id: "nextAttention", title: "Go to Next Terminal Needing Attention", category: "Go") { $0.nextAttention() },
            AppCommand(id: "toggleSidebar", title: "Toggle Sidebar", category: "View") { model in
                model.sidebarVisibility = model.sidebarVisibility == .detailOnly ? .all : .detailOnly
            },
            AppCommand(id: "focusExplorer", title: "Focus on Explorer", category: "View") { model in
                if model.sidebarVisibility == .detailOnly { model.sidebarVisibility = .all }
                SidebarSection.explorer.open()
                model.fileTree.focus()
            },
            AppCommand(id: "revealActive", title: "Reveal Active Item in Explorer", category: "View") { model in
                if let path = model.activeFilePath { model.revealInTree(path) }
            },
            AppCommand(id: "newTerminal", title: "New Terminal", category: "Terminal") { $0.startTerminal() },
            AppCommand(id: "restartTerminal", title: "Restart Exited Terminal", category: "Terminal") { model in
                if let id = model.active.focused.active {
                    (model.existingController(for: id) as? TerminalController)?.restart()
                }
            },
            AppCommand(id: "splitRight", title: "Split Right", category: "View") { $0.splitActive(.right) },
            AppCommand(id: "splitDown", title: "Split Down", category: "View") { $0.splitActive(.down) },
            AppCommand(id: "closeItem", title: "Close Item", category: "File") { $0.closeActive() },
            AppCommand(id: "reopenClosed", title: "Reopen Closed Item", category: "File") { $0.reopenClosed() },
            AppCommand(id: "pinTab", title: "Keep Open (Pin Preview Tab)", category: "View") { model in
                if let id = model.active.focused.active { model.updateActive { $0.pin(id) } }
            },
            AppCommand(id: "find", title: "Find", category: "Edit") { $0.openFind() },
            AppCommand(id: "openSettings", title: "Open Settings…", category: "Preferences") { $0.openSettings() },
            AppCommand(id: "openKeybindings", title: "Open Keyboard Shortcuts", category: "Preferences") { $0.openKeyboardShortcuts() },
            AppCommand(id: "themeSystem", title: "Theme: Follow System", category: "Preferences") { $0.setTheme(.system) },
            AppCommand(id: "themeLight", title: "Theme: Light", category: "Preferences") { $0.setTheme(.light) },
            AppCommand(id: "themeDark", title: "Theme: Dark", category: "Preferences") { $0.setTheme(.dark) },
            AppCommand(id: "installCommandLine", title: "Install tiri Command for Other Terminals…", category: "Preferences") {
                $0.confirmCommandLineTool(install: true)
            },
            AppCommand(id: "newWorkspace", title: "New Workspace…", category: "Workspace") { $0.newWorkspaceInteractive() },
            AppCommand(id: "addFolder", title: "Add Folder to Workspace…", category: "Workspace") { $0.addFolderInteractive() },
            AppCommand(id: "importWorkspace", title: "Import .code-workspace…", category: "Workspace") { $0.importWorkspaceInteractive() },
            AppCommand(id: "renameWorkspace", title: "Rename Workspace…", category: "Workspace") { $0.promptRenameWorkspace($0.activeID) },
            AppCommand(id: "deleteWorkspace", title: "Delete Workspace…", category: "Workspace") { $0.confirmDeleteWorkspace($0.activeID) },
            AppCommand(id: "toggleMarkdownSource", title: "Markdown: Toggle Source", category: "View") { $0.toggleMarkdownSource() },
            AppCommand(id: "openInExternalEditor", title: "Open in External Editor", category: "File") { model in
                let item = model.active.peek ?? model.active.activeItem
                if let path = item?.filePath { model.openExternally(path: path) }
            },
            AppCommand(id: "promotePeek", title: "Peek: Open as Tab", category: "View") { $0.promotePeek() },
            AppCommand(id: "promotePeekToSide", title: "Peek: Open to the Side", category: "View") { $0.promotePeek(split: .right) },
            AppCommand(id: "dismissPeek", title: "Peek: Close", category: "View") { $0.dismissPeek() },
            AppCommand(id: "webDarkOn", title: "View: Force Dark On", category: "View") { model in
                model.setForceDark(true, item: model.active.focused.active)
            },
            AppCommand(id: "webDarkOff", title: "View: Force Dark Off", category: "View") { model in
                model.setForceDark(false, item: model.active.focused.active)
            },
            AppCommand(id: "moveToNewWindow", title: "Move to New Window", category: "View") { model in
                if let id = model.active.focused.active { model.moveToNewWindow(id) }
            },
            AppCommand(id: "bringBackFromWindow", title: "Bring Back from Its Window", category: "View") { model in
                if let id = model.active.focused.active { model.bringBack(id) }
            },
            AppCommand(id: "saveFile", title: "Save", category: "File") { $0.saveFront() },
            AppCommand(id: "addToAgent", title: "Add to Agent", category: "Agent") { $0.addFrontToAgent() },
            AppCommand(id: "attachToAgent", title: "Add Files or Images to Agent…", category: "Agent") { $0.chooseFilesForAgent() },
            AppCommand(id: "foldExplorer", title: "Fold or Unfold Explorer", category: "View") { _ in SidebarSection.explorer.toggle() },
            AppCommand(id: "foldChanges", title: "Fold or Unfold Changes", category: "View") { _ in SidebarSection.changes.toggle() },
            AppCommand(id: "foldOpenItems", title: "Fold or Unfold Open Items", category: "View") { _ in SidebarSection.items.toggle() },
            AppCommand(id: "searchInFiles", title: "Search in Files", category: "Go") { $0.openSearch() },
            AppCommand(id: "showChanges", title: "Show Changes in This File", category: "View") { $0.toggleChangesForFront() },
            AppCommand(id: "webReload", title: "Web: Reload", category: "Web") { model in
                model.frontWebController?.reload()
            },
        ]
        for number in 1...9 {
            list.append(AppCommand(id: "focusGroup\(number)", title: "Focus Group \(number)", category: "View") { model in
                model.updateActive { $0.focusGroup(index: number - 1) }
                model.requestFocus()
            })
            list.append(AppCommand(id: "switchWorkspace\(number)", title: "Switch to Workspace \(number)", category: "Workspace") {
                $0.switchWorkspace(index: number - 1)
            })
        }
        return list
    }()

    private static let commandsByID: [String: AppCommand] = Dictionary(uniqueKeysWithValues: staticCommands.map { ($0.id, $0) })

    func command(_ id: String) -> AppCommand? { Self.commandsByID[id] }

    /// Static commands plus the ones that depend on what's in the app right now.
    var allCommands: [AppCommand] {
        var list = Self.staticCommands
        for preset in settings.terminalPresets where !preset.command.isEmpty {
            list.append(AppCommand(id: "newTerminal:\(preset.name)", title: "New Terminal: \(preset.name)", category: "Terminal") {
                $0.startTerminal(command: preset.command)
            })
        }
        for workspace in workspaces where workspace.id != activeID {
            list.append(AppCommand(id: "workspace:\(workspace.name)", title: "Switch to Workspace: \(workspace.name)", category: "Workspace") {
                $0.switchWorkspace(workspace.id)
            })
        }
        return list
    }

    /// Menu items show the same shortcuts the router handles, and macOS can still fire a menu's
    /// key equivalent for a key the router already ran, later and under a different current
    /// event (WebKit re-dispatches keys asynchronously). Only a deliberate menu choice acts here.
    func runFromMenu(_ id: String) {
        if NSApp.currentEvent?.type == .keyDown { return }
        if router.ranRecently(id) { return }
        run(id)
    }

    @discardableResult
    func run(_ id: String) -> Bool {
        if let command = allCommands.first(where: { $0.id == id }) {
            command.action(self)
            return true
        }
        return false
    }
}

// MARK: - Control API

enum ControlHandler {
    /// Paths a request is about to touch. Their privacy check happens first, off the main
    /// thread, so an agent's `tiri open` can't freeze the app behind a macOS prompt.
    nonisolated private static func paths(in request: ControlRequest) -> [String] {
        var paths = ["path", "file", "folder", "cwd"].compactMap { request.args[$0]?.stringValue }
        paths += request.args["folders"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return paths
    }

    static func handle(_ request: ControlRequest) async -> ControlResponse {
        let touched = paths(in: request)
        if !touched.isEmpty { _ = await FolderAccess.deniedPaths(touched) }
        // These read a lot of files. The app keeps responding while they do.
        if request.cmd == "search", let query = request.args["query"]?.stringValue {
            let paths = await AppModel.shared.searchablePaths()
            let collector = SearchCollector()
            await Task.detached(priority: .userInitiated) {
                ContentSearch.run(paths: paths, query: query, cancellation: ContentSearch.Cancellation()) { collector.add($0) }
            }.value
            return ControlResponse.success(id: request.id, .array(collector.sorted().map { match in
                .object(["path": .string(match.path), "line": .int(match.line), "text": .string(match.text)])
            }))
        }
        return await MainActor.run {
            do {
                let result = try perform(request, model: AppModel.shared)
                return ControlResponse.success(id: request.id, result)
            } catch let error as ControlFailure {
                return ControlResponse.failure(id: request.id, error.message)
            } catch {
                return ControlResponse.failure(id: request.id, "\(error)")
            }
        }
    }

    struct ControlFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func string(_ request: ControlRequest, _ key: String) throws -> String {
        guard let value = request.args[key]?.stringValue, !value.isEmpty else {
            throw ControlFailure("Missing argument \"\(key)\"")
        }
        return value
    }

    private static func split(_ request: ControlRequest) -> SplitDirection? {
        request.args["split"]?.stringValue.flatMap(SplitDirection.init(rawValue:))
    }

    private static func requireItem(_ request: ControlRequest, model: AppModel) throws -> ItemID {
        let id = try string(request, "item")
        guard model.anyItem(id) != nil else { throw ControlFailure("No item with id \(id). Run tiri items.") }
        return id
    }

    private static func describe(_ item: Item, model: AppModel, workspace: Workspace) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id),
            "kind": .string(item.content.kindName),
            "title": .string(model.title(for: item)),
            "workspace": .string(workspace.name),
            "active": .bool(workspace.id == model.activeID && workspace.focused.active == item.id),
            "preview": .bool(item.isPreview),
            "peek": .bool(workspace.peek?.id == item.id),
        ]
        switch item.content {
        case .terminal(let spec):
            let runtime = model.runtimes[item.id] ?? TerminalRuntime()
            object["status"] = .string(runtime.status.rawValue)
            object["unseen"] = .bool(runtime.unseen)
            object["cwd"] = .string((model.existingController(for: item.id) as? TerminalController)?.currentDirectory ?? spec.cwd)
            if let command = spec.command { object["command"] = .string(command) }
            if let session = spec.sessionID { object["session"] = .string(session) }
            if let message = runtime.message { object["message"] = .string(message) }
        case .file(let spec):
            object["path"] = .string(spec.path)
        case .web(let spec):
            object["url"] = .string((model.existingController(for: item.id) as? WebController)?.currentURLString ?? spec.url)
        case .diff(let spec):
            object["path"] = .string(spec.path)
        case .settings:
            break
        }
        return .object(object)
    }

    private static func describe(layout node: PaneNode) -> JSONValue {
        switch node {
        case .group(let group):
            return .object(["group": .string(group.id), "tabs": .array(group.tabs.map(JSONValue.string)),
                            "active": group.active.map(JSONValue.string) ?? .null])
        case .split(let split):
            return .object(["split": .string(split.axis.rawValue), "ratios": .array(split.ratios.map(JSONValue.double)),
                            "children": .array(split.children.map(describe(layout:)))])
        }
    }

    private static func findWorkspace(_ name: String, model: AppModel) throws -> Workspace {
        if let match = model.workspaces.first(where: { $0.name == name || $0.id == name }) { return match }
        if let number = Int(name), number >= 1, number <= model.workspaces.count { return model.workspaces[number - 1] }
        throw ControlFailure("No workspace named \"\(name)\". Run tiri workspace list.")
    }

    @MainActor
    private static func perform(_ request: ControlRequest, model: AppModel) throws -> JSONValue {
        // Commands from a Tiri terminal apply to that terminal's workspace, which may be
        // behind the one the user is looking at.
        let sourceWorkspace = request.args["source"]?.stringValue.flatMap { model.workspace(containing: $0)?.id }
        switch request.cmd {
        case "ping":
            return .object(["pong": true, "version": .string(TiriCoreVersion.string), "workspace": .string(model.active.name)])

        case "open":
            let path = try string(request, "path")
            guard FileManager.default.fileExists(atPath: path) else { throw ControlFailure("No such file: \(path)") }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                // Changing workspace is the user's call, not a background agent's.
                if sourceWorkspace == nil || sourceWorkspace == model.activeID { model.openFolderAsWorkspace(path) }
                return .object(["workspace": .string(model.active.name)])
            }
            let line = request.args["line"]?.intValue
            let col = request.args["col"]?.intValue
            let intent: OpenIntent
            if let direction = split(request) {
                intent = .split(direction)
            } else if request.args["mode"]?.stringValue == "tab" || request.args["pin"]?.boolValue == true {
                intent = .pinned
            } else if request.args["mode"]?.stringValue == "peek" || request.args["source"] != nil {
                // From a terminal: float it over the session and leave the keyboard there.
                intent = .peek(takeFocus: false)
            } else {
                intent = .pinned
            }
            guard let id = model.open(path: path, line: line, col: col, intent: intent, in: sourceWorkspace) else {
                throw ControlFailure("Could not open \(path)")
            }
            let inFront = sourceWorkspace == nil || sourceWorkspace == model.activeID
            // Asked to keep something: fine to bring it up, but from a terminal, leave the keyboard there.
            if inFront, request.args["source"] == nil {
                if case .peek = intent {} else { model.requestFocus() }
            }
            return .object(["item": .string(id), "peek": .bool(model.active.peek?.id == id)])

        case "reveal":
            let path = try string(request, "path")
            guard FileManager.default.fileExists(atPath: path) else { throw ControlFailure("No such path: \(path)") }
            let aliased = model.aliasedPath(path)
            guard model.active.folder(containing: aliased) != nil else {
                throw ControlFailure("\(path) isn't in this workspace. Add it with tiri workspace add-folder.")
            }
            model.revealInTree(aliased)
            return .object(["path": .string(aliased)])

        case "preview":
            let target = try string(request, "target")
            let url = URL(string: target)
            if url?.isFileURL == true, let path = url?.path, !FileManager.default.fileExists(atPath: path) {
                throw ControlFailure("No such file: \(path)")
            }
            guard url?.scheme != nil else { throw ControlFailure("Not a URL or path: \(target)") }
            return .object(["item": .string(model.openWeb(url: target, split: split(request), in: sourceWorkspace))])

        case "term":
            let cwd = request.args["cwd"]?.stringValue
            if let cwd {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ControlFailure("No such directory: \(cwd)")
                }
            }
            let id = model.newTerminal(command: request.args["cmd"]?.stringValue, cwd: cwd, split: split(request), in: sourceWorkspace)
            return .object(["item": .string(id)])

        case "workspace.list":
            let list = model.workspaces.enumerated().map { index, workspace -> JSONValue in
                let counts = model.unseenCount(in: workspace)
                return .object([
                    "id": .string(workspace.id), "name": .string(workspace.name), "index": .int(index + 1),
                    "active": .bool(workspace.id == model.activeID),
                    "folders": .array(workspace.folders.map(JSONValue.string)),
                    "items": .int(workspace.items.count),
                    "needsInput": .int(counts.needsInput), "done": .int(counts.done),
                ])
            }
            return .array(list)

        case "workspace.switch":
            let workspace = try findWorkspace(try string(request, "name"), model: model)
            model.switchWorkspace(workspace.id)
            return .object(["workspace": .string(workspace.name)])

        case "workspace.new":
            let name = try string(request, "name")
            let folders = request.args["folders"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for folder in folders where !FileManager.default.fileExists(atPath: folder) {
                throw ControlFailure("No such folder: \(folder)")
            }
            let workspace = model.createWorkspace(name: name, folders: folders)
            return .object(["id": .string(workspace.id), "name": .string(workspace.name)])

        case "workspace.add-folder":
            let folder = try string(request, "folder")
            guard FileManager.default.fileExists(atPath: folder) else { throw ControlFailure("No such folder: \(folder)") }
            model.addFolder(folder, in: sourceWorkspace)
            let current = model.workspaces.first { $0.id == sourceWorkspace ?? model.activeID }
            return .object(["folders": .array((current?.folders ?? []).map(JSONValue.string))])

        case "workspace.remove-folder":
            let folder = try string(request, "folder")
            let holder = model.workspaces.first { $0.id == sourceWorkspace ?? model.activeID }
            guard holder?.folders.contains(folder) == true else { throw ControlFailure("\(folder) isn't in this workspace") }
            model.removeFolder(folder, in: sourceWorkspace)
            let current = model.workspaces.first { $0.id == sourceWorkspace ?? model.activeID }
            return .object(["folders": .array((current?.folders ?? []).map(JSONValue.string))])

        case "workspace.import":
            let file = try string(request, "file")
            guard let workspace = model.importWorkspace(url: URL(fileURLWithPath: file)) else {
                throw ControlFailure("Could not import \(file)")
            }
            return .object(["name": .string(workspace.name), "folders": .array(workspace.folders.map(JSONValue.string))])

        case "workspace.rename":
            let target = try request.args["workspace"]?.stringValue.map { try findWorkspace($0, model: model) } ?? model.active
            model.renameWorkspace(target.id, to: try string(request, "name"))
            return .object(["name": .string(try string(request, "name"))])

        case "workspace.delete":
            let target = try findWorkspace(try string(request, "name"), model: model)
            model.deleteWorkspace(target.id)
            return .object(["deleted": .string(target.name)])

        case "items":
            var list: [JSONValue] = []
            for workspace in model.workspaces {
                for item in workspace.items { list.append(describe(item, model: model, workspace: workspace)) }
                if let peek = workspace.peek { list.append(describe(peek, model: model, workspace: workspace)) }
            }
            return .array(list)

        case "focus":
            let id = try requireItem(request, model: model)
            if model.active.peek?.id == id {
                model.setPeekKeyboard(true)
                model.requestFocus()
            } else if !model.focusItem(id), let holder = model.workspace(containing: id) {
                model.switchWorkspace(holder.id)
            }
            return .object(["item": .string(id)])

        case "close":
            let id = try requireItem(request, model: model)
            if model.active.peek?.id == id {
                model.dismissPeek()
            } else if let holder = model.workspace(containing: id), holder.peek?.id == id {
                // A Peek floating in a workspace that's in the background.
                model.update(workspace: holder.id) { $0.dismissPeek() }
            } else {
                model.closeNow(id)
            }
            return .object(["closed": .string(id)])

        case "notify":
            let id = try requireItem(request, model: model)
            guard case .terminal = model.anyItem(id)?.content else { throw ControlFailure("\(id) isn't a terminal") }
            model.handleHookReport(item: id, tool: request.args["tool"]?.stringValue,
                                   state: request.args["state"]?.stringValue,
                                   message: request.args["message"]?.stringValue,
                                   session: request.args["session"]?.stringValue)
            return .object(["item": .string(id), "status": .string(model.runtimes[id]?.status.rawValue ?? "idle")])

        case "settings.list", "settings.explain":
            let settings = model.settings
            func entry(_ definition: SettingDefinition) -> JSONValue {
                .object(["key": .string(definition.key), "section": .string(definition.section), "title": .string(definition.title),
                         "explanation": .string(definition.explanation), "accepts": .string(SettingsSchema.allowedValues(definition.kind)),
                         "value": definition.value(settings), "display": .string(SettingsSchema.display(definition.value(settings))),
                         "defaultDisplay": .string(SettingsSchema.display(definition.value(TiriSettings())))])
            }
            if let key = request.args["key"]?.stringValue {
                guard let definition = SettingsSchema.definition(for: key) else {
                    throw ControlFailure("No setting called \"\(key)\". Run tiri settings to see them all.")
                }
                return .array([entry(definition)])
            }
            return .array(SettingsSchema.all.map(entry))

        case "settings.get":
            let key = try string(request, "key")
            guard let definition = SettingsSchema.definition(for: key) else {
                throw ControlFailure("No setting called \"\(key)\". Run tiri settings to see them all.")
            }
            let value = definition.value(model.settings)
            return .object(["key": .string(key), "value": value, "display": .string(SettingsSchema.display(value))])

        case "settings.set":
            let key = try string(request, "key")
            let value: JSONValue
            do {
                value = try SettingsSchema.value(from: try string(request, "value"), for: key)
            } catch let invalid as SettingsSchema.InvalidValue {
                throw ControlFailure(invalid.description)
            }
            if let problem = model.setSetting(key, to: value) { throw ControlFailure(problem) }
            let now = SettingsSchema.definition(for: key)?.value(model.settings) ?? value
            return .object(["key": .string(key), "value": now, "display": .string(SettingsSchema.display(now))])

        case "settings.reset":
            let key = try string(request, "key")
            guard let definition = SettingsSchema.definition(for: key) else {
                throw ControlFailure("No setting called \"\(key)\". Run tiri settings to see them all.")
            }
            model.resetSetting(key)
            let now = definition.value(model.settings)
            return .object(["key": .string(key), "value": now, "display": .string(SettingsSchema.display(now))])

        case "settings.open":
            model.openSettings()
            return .object([:])

        case "hooks.install", "hooks.remove":
            guard let tool = AgentHooks.Tool(rawValue: try string(request, "tool")) else { throw ControlFailure("Unknown tool") }
            model.confirmHooks(tool, install: request.cmd == "hooks.install")
            return .object([:])

        case "keys.set", "keys.unset", "keys.reset":
            let command = try string(request, "command")
            guard model.allCommands.contains(where: { $0.id == command }) else {
                throw ControlFailure("No command called \"\(command)\". Run tiri keys to see them all.")
            }
            let problem: String?
            switch request.cmd {
            case "keys.set": problem = model.setShortcut(command, key: try string(request, "key"))
            case "keys.unset": problem = model.setShortcut(command, key: nil)
            default: problem = model.resetShortcut(command)
            }
            if let problem { throw ControlFailure(problem) }
            return .object(["command": .string(command), "key": .string(model.shortcutSymbol(for: command) ?? "")])

        case "theme":
            guard let mode = request.args["mode"]?.stringValue.flatMap(ThemeMode.init(rawValue:)) else {
                throw ControlFailure("Theme must be light, dark or system")
            }
            model.setTheme(mode)
            return .object(["theme": .string(mode.rawValue)])

        case "web-dark":
            guard let on = request.args["on"]?.boolValue else { throw ControlFailure("Missing argument \"on\"") }
            var target = request.args["item"]?.stringValue
            if let target, model.forceDarkController(for: target) == nil {
                throw ControlFailure("\(target) isn't an open web page or document")
            }
            if target == nil, let active = model.active.focused.active, model.forceDarkController(for: active) != nil {
                target = active
            }
            model.setForceDark(on, item: target)
            return .object(["on": .bool(on)])

        case "commands":
            return .array(model.allCommands.map { command in
                var object: [String: JSONValue] = ["id": .string(command.id), "title": .string(command.title)]
                if let symbol = model.shortcutSymbol(for: command.id) { object["key"] = .string(symbol) }
                return .object(object)
            })

        case "run":
            let id = try string(request, "command")
            guard model.run(id) else { throw ControlFailure("No command \(id). Run tiri commands.") }
            return .object(["ran": .string(id)])

        case "layout":
            let workspace = model.active
            return .object(["workspace": .string(workspace.name), "focusedGroup": .string(workspace.focusedGroup),
                            "peek": workspace.peek.map { .string($0.id) } ?? .null,
                            "layout": describe(layout: workspace.layout),
                            "tabFrames": .object(model.layoutRegistry.tabFrames.mapValues { frame in
                                .array([.int(Int(frame.midX)), .int(Int(frame.midY))])
                            }),
                            "contentFrames": .object(model.layoutRegistry.contentFrames.mapValues { frame in
                                .array([.int(Int(frame.minX)), .int(Int(frame.minY)), .int(Int(frame.width)), .int(Int(frame.height))])
                            })])

        case "send":
            let id = try requireItem(request, model: model)
            guard let terminal = model.controller(for: id) as? TerminalController else { throw ControlFailure("\(id) isn't a terminal") }
            terminal.startIfNeeded(fallbackSize: true)
            terminal.send(text: try string(request, "text"))
            return .object(["item": .string(id)])

        case "changes":
            return .array(Git.changesAcross(model.active.folders).map { change in
                .object(["status": .string(change.status.letter), "path": .string(change.path)])
            })

        case "diff":
            let path = try string(request, "path")
            if request.args["mode"]?.stringValue == "tab" {
                model.openDiff(path: path, preview: false)
            } else {
                model.peekDiff(path: path, takeFocus: false)
            }
            return .object([:])

        case "select":
            let id = try requireItem(request, model: model)
            guard let controller = model.controller(for: id), controller.select(text: try string(request, "text"), to: request.args["to"]?.stringValue) else {
                throw ControlFailure("That isn't in \(id)")
            }
            return .object([:])

        case "follow":
            let id = try requireItem(request, model: model)
            guard let terminal = model.controller(for: id) as? TerminalController else { throw ControlFailure("\(id) isn't a terminal") }
            guard let row = request.args["row"]?.intValue, let col = request.args["col"]?.intValue else {
                throw ControlFailure("Missing row or column")
            }
            guard terminal.terminalView.followLink(row: row, column: col, forceTab: false) else {
                throw ControlFailure("There's no link or path there")
            }
            return .object(["item": .string(id)])

        case "read":
            let id = try requireItem(request, model: model)
            guard let terminal = model.controller(for: id) as? TerminalController else { throw ControlFailure("\(id) isn't a terminal") }
            return .object(["text": .string(terminal.readText(lines: request.args["lines"]?.intValue))])

        case "perf":
            var object: [String: JSONValue] = ["footprintMB": .double(ProcessClock.footprintMegabytes())]
            if let launch = model.launchMilliseconds { object["launchMs"] = .double(launch) }
            if let open = model.lastOpenMilliseconds { object["lastOpenMs"] = .double(open) }
            object["indexedFiles"] = .int(model.fileIndex.files.count)
            object["firstResponder"] = .string(model.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
            return .object(object)

        case "tree":
            return .array(model.fileTree.visibleRows().map(JSONValue.string))

        case "quit":
            // Asked for from outside, nobody's there to answer "save your changes?".
            if let name = model.firstUnsavedFileName { throw ControlFailure("\(name) has unsaved changes") }
            model.skipQuitConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return .object([:])

        default:
            throw ControlFailure("Unknown command \"\(request.cmd)\"")
        }
    }
}
