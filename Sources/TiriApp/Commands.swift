import AppKit
import SwiftUI
import TiriCore
import TiriHighlight

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
            AppCommand(id: "quickOpen", title: "Go to File…", category: "Navigation") { $0.openPalette(.files) },
            AppCommand(id: "commandPalette", title: "Show All Commands", category: "Navigation") { $0.openPalette(.commands) },
            AppCommand(id: "searchInFiles", title: "Search in Files", category: "Navigation") { $0.openSearch() },
            AppCommand(id: "goToLine", title: "Go to Line…", category: "Navigation") { $0.openPalette(typing: ":") },
            AppCommand(id: "symbolsInFile", title: "Go to Symbol in File…", category: "Navigation") { $0.openPalette(typing: "@") },
            AppCommand(id: "symbolsInWorkspace", title: "Go to Symbol in Workspace…", category: "Navigation") { $0.openPalette(typing: "#") },
            AppCommand(id: "goToDefinition", title: "Go to Definition", category: "Navigation") { $0.goToDefinition() },
            AppCommand(id: "findReferences", title: "Find References", category: "Navigation") { $0.findReferences() },
            AppCommand(id: "showHover", title: "Show What This Name Is", category: "Navigation") { $0.showHover() },
            AppCommand(id: "goBack", title: "Go Back", category: "Navigation") { $0.goBack() },
            AppCommand(id: "nextChange", title: "Go to Next Change", category: "Navigation") { $0.goToChange(forward: true) },
            AppCommand(id: "previousChange", title: "Go to Previous Change", category: "Navigation") { $0.goToChange(forward: false) },
            AppCommand(id: "nextAttention", title: "Go to Next Terminal Needing Attention", category: "Navigation") { $0.nextAttention() },
            AppCommand(id: "nextTab", title: "Next Tab", category: "Tabs and Splits") { model in
                model.updateActive { $0.cycleTab(by: 1) }
                model.requestFocus()
            },
            AppCommand(id: "previousTab", title: "Previous Tab", category: "Tabs and Splits") { model in
                model.updateActive { $0.cycleTab(by: -1) }
                model.requestFocus()
            },
            AppCommand(id: "closeItem", title: "Close Item", category: "Tabs and Splits") { $0.closeActive() },
            AppCommand(id: "reopenClosed", title: "Reopen Closed Item", category: "Tabs and Splits") { $0.reopenClosed() },
            AppCommand(id: "pinTab", title: "Keep Open (Pin Preview Tab)", category: "Tabs and Splits") { model in
                if let id = model.active.focused.active { model.updateActive { $0.pin(id) } }
            },
            AppCommand(id: "splitRight", title: "Split Right", category: "Tabs and Splits") { $0.splitActive(.right) },
            AppCommand(id: "splitDown", title: "Split Down", category: "Tabs and Splits") { $0.splitActive(.down) },
            AppCommand(id: "moveToNewWindow", title: "Move to New Window", category: "Tabs and Splits") { model in
                if let id = model.active.focused.active { model.moveToNewWindow(id) }
            },
            AppCommand(id: "bringBackFromWindow", title: "Bring Back from Its Window", category: "Tabs and Splits") { model in
                if let id = model.active.focused.active { model.bringBack(id) }
            },
            AppCommand(id: "promotePeek", title: "Peek: Open as Tab", category: "Tabs and Splits") { $0.promotePeek() },
            AppCommand(id: "promotePeekToSide", title: "Peek: Open to the Side", category: "Tabs and Splits") { $0.promotePeek(split: .right) },
            AppCommand(id: "dismissPeek", title: "Peek: Close", category: "Tabs and Splits") { $0.dismissPeek() },
            AppCommand(id: "toggleSidebar", title: "Toggle Sidebar", category: "Window") { model in
                model.setSidebar(visible: model.sidebarVisibility == .detailOnly)
            },
            AppCommand(id: "focusExplorer", title: "Focus on Explorer", category: "Window") { model in
                model.setSidebar(visible: true)
                SidebarSection.explorer.open()
                model.fileTree.focus()
            },
            AppCommand(id: "revealActive", title: "Reveal Active Item in Explorer", category: "Window") { model in
                if let path = model.activeFilePath { model.revealInTree(path) }
            },
            AppCommand(id: "foldExplorer", title: "Fold or Unfold Explorer", category: "Window") { _ in SidebarSection.explorer.toggle() },
            AppCommand(id: "foldChanges", title: "Fold or Unfold Changes", category: "Window") { _ in SidebarSection.changes.toggle() },
            AppCommand(id: "foldReview", title: "Fold or Unfold Review", category: "Window") { _ in SidebarSection.review.toggle() },
            AppCommand(id: "foldOpenItems", title: "Fold or Unfold Open Items", category: "Window") { _ in SidebarSection.items.toggle() },
            AppCommand(id: "zoomIn", title: "Zoom In", category: "Window") { $0.zoom(by: 1) },
            AppCommand(id: "zoomOut", title: "Zoom Out", category: "Window") { $0.zoom(by: -1) },
            AppCommand(id: "zoomReset", title: "Reset Zoom", category: "Window") { $0.zoomReset() },
            AppCommand(id: "saveFile", title: "Save", category: "Editing") { $0.saveFront() },
            AppCommand(id: "find", title: "Find", category: "Editing") { $0.openFind() },
            AppCommand(id: "findReplace", title: "Replace", category: "Editing") { $0.openFind(replace: true) },
            AppCommand(id: "toggleWordWrap", title: "Toggle Word Wrap", category: "Editing") { $0.frontEditor?.toggleWordWrap() },
            AppCommand(id: "toggleMarkdownSource", title: "Markdown or Notebook: Toggle Source", category: "Editing") { $0.toggleMarkdownSource() },
            AppCommand(id: "openInExternalEditor", title: "Open in External Editor", category: "Editing") { model in
                let item = model.active.peek ?? model.active.activeItem
                if let path = item?.filePath { model.openExternally(path: path) }
            },
            AppCommand(id: "newTerminal", title: "New Terminal", category: "Terminal") { $0.startTerminal() },
            AppCommand(id: "restartTerminal", title: "Restart Exited Terminal", category: "Terminal") { model in
                if let id = model.active.focused.active {
                    (model.existingController(for: id) as? TerminalController)?.restart()
                }
            },
            AppCommand(id: "clearTerminal", title: "Clear", category: "Terminal") { $0.frontTerminal?.clearScreen() },
            AppCommand(id: "terminalLineStart", title: "Go to Start of Line", category: "Terminal") { $0.frontTerminal?.sendLineStart() },
            AppCommand(id: "terminalLineEnd", title: "Go to End of Line", category: "Terminal") { $0.frontTerminal?.sendLineEnd() },
            AppCommand(id: "terminalDeleteToLineStart", title: "Delete to Start of Line", category: "Terminal") { $0.frontTerminal?.sendDeleteToLineStart() },
            AppCommand(id: "addToAgent", title: "Add to Agent", category: "Agents") { $0.addFrontToAgent() },
            AppCommand(id: "attachToAgent", title: "Add Files or Images to Agent…", category: "Agents") { $0.chooseFilesForAgent() },
            AppCommand(id: "addReviewComment", title: "Review: Add Comment", category: "Agents") { $0.beginReviewComment() },
            AppCommand(id: "sendReview", title: "Review: Send Comments to Agent", category: "Agents") { $0.sendReview() },
            AppCommand(id: "conversations", title: "Past Conversations…", category: "Agents") { $0.openConversationPicker() },
            AppCommand(id: "pickOnPage", title: "Web: Pick Something on the Page", category: "Agents") { $0.frontWebController?.startPicking() },
            AppCommand(id: "manageAgents", title: "Manage Agents…", category: "Agents") { $0.openAgentSettings() },
            AppCommand(id: "showChanges", title: "Show Changes in This File", category: "Changes and Git") { $0.toggleChangesForFront() },
            AppCommand(id: "toggleDiffSideBySide", title: "Diff: Side by Side", category: "Changes and Git") { model in
                _ = model.setSetting("diff.sideBySide", to: .bool(!model.settings.diffSideBySide))
            },
            AppCommand(id: "changesSinceCommit", title: "Changes: Since Last Commit", category: "Changes and Git") { $0.setChangesScope(.sinceCommit) },
            AppCommand(id: "changesLatestTurn", title: "Changes: Latest Turn", category: "Changes and Git") { $0.setChangesScope(.latestTurn) },
            AppCommand(id: "changesBranch", title: "Changes: This Branch", category: "Changes and Git") { $0.setChangesScope(.branch) },
            AppCommand(id: "changesRecentCommits", title: "Changes: Recent Commits", category: "Changes and Git") { $0.setChangesScope(.recentCommits) },
            AppCommand(id: "changesOtherWork", title: "Changes: Other Work", category: "Changes and Git") { $0.setChangesScope(.otherWork) },
            AppCommand(id: "gitFetch", title: "Git: Fetch", category: "Changes and Git") { model in
                if let repository = model.frontRepository { model.fetch(repository) }
            },
            AppCommand(id: "gitPull", title: "Git: Pull", category: "Changes and Git") { model in
                if let repository = model.frontRepository { model.pull(repository) }
            },
            AppCommand(id: "gitPush", title: "Git: Push…", category: "Changes and Git") { model in
                if let repository = model.frontRepository { model.confirmPush(repository) }
            },
            AppCommand(id: "newWorkspace", title: "New Workspace…", category: "Workspaces") { $0.newWorkspaceInteractive() },
            AppCommand(id: "addFolder", title: "Add Folder to Workspace…", category: "Workspaces") { $0.addFolderInteractive() },
            AppCommand(id: "connectToServer", title: "Connect to Server…", category: "Workspaces") { $0.connectToServerInteractive() },
            AppCommand(id: "importWorkspace", title: "Import .code-workspace…", category: "Workspaces") { $0.importWorkspaceInteractive() },
            AppCommand(id: "renameWorkspace", title: "Rename Workspace…", category: "Workspaces") { $0.promptRenameWorkspace($0.activeID) },
            AppCommand(id: "deleteWorkspace", title: "Delete Workspace…", category: "Workspaces") { $0.confirmDeleteWorkspace($0.activeID) },
            AppCommand(id: "notebookRunCell", title: "Notebook: Run Cell", category: "Notebook") { $0.notebookCommand("notebookRunCell") },
            AppCommand(id: "notebookRunAll", title: "Notebook: Run All", category: "Notebook") { $0.notebookCommand("notebookRunAll") },
            AppCommand(id: "notebookInterrupt", title: "Notebook: Interrupt", category: "Notebook") { $0.notebookCommand("notebookInterrupt") },
            AppCommand(id: "notebookRestart", title: "Notebook: Restart Kernel", category: "Notebook") { $0.notebookCommand("notebookRestart") },
            AppCommand(id: "notebookStop", title: "Notebook: Shut Down Kernel", category: "Notebook") { $0.notebookCommand("notebookStop") },
            AppCommand(id: "notebookClear", title: "Notebook: Clear All Outputs", category: "Notebook") { $0.notebookCommand("notebookClear") },
            AppCommand(id: "notebookChoosePython", title: "Notebook: Choose Python…", category: "Notebook") { $0.notebookCommand("notebookChoosePython") },
            AppCommand(id: "notebookAddCode", title: "Notebook: Add Code Cell", category: "Notebook") { $0.notebookCommand("notebookAddCode") },
            AppCommand(id: "notebookAddMarkdown", title: "Notebook: Add Markdown Cell", category: "Notebook") { $0.notebookCommand("notebookAddMarkdown") },
            AppCommand(id: "notebookDeleteCell", title: "Notebook: Delete Cell", category: "Notebook") { $0.notebookCommand("notebookDeleteCell") },
            AppCommand(id: "webReload", title: "Web: Reload", category: "Web") { model in
                model.frontWebController?.reload()
            },
            AppCommand(id: "webOpenInBrowser", title: "Web: Open in \(DefaultBrowser.name)", category: "Web") { model in
                if let page = model.frontWebController { model.movePageToBrowser(page.itemID) }
            },
            AppCommand(id: "webDarkOn", title: "Force Dark On", category: "Web") { model in
                model.setForceDark(true, item: model.active.focused.active)
            },
            AppCommand(id: "webDarkOff", title: "Force Dark Off", category: "Web") { model in
                model.setForceDark(false, item: model.active.focused.active)
            },
            AppCommand(id: "about", title: "About Tiri", category: "Help") { _ in AboutPanel.show() },
            AppCommand(id: "openSettings", title: "Open Settings…", category: "Settings") { $0.openSettings() },
            AppCommand(id: "openKeybindings", title: "Open Keyboard Shortcuts", category: "Settings") { $0.openKeyboardShortcuts() },
            AppCommand(id: "themeSystem", title: "Theme: Follow System", category: "Settings") { $0.setTheme(.system) },
            AppCommand(id: "themeLight", title: "Theme: Light", category: "Settings") { $0.setTheme(.light) },
            AppCommand(id: "themeDark", title: "Theme: Dark", category: "Settings") { $0.setTheme(.dark) },
            AppCommand(id: "manageLanguageServers", title: "Language Servers…", category: "Settings") { $0.openLanguageServerSettings() },
            AppCommand(id: "newPlugin", title: "New Plugin…", category: "Settings") { $0.promptForNewPlugin() },
            AppCommand(id: "changeTiri", title: "Change Tiri…", category: "Settings") { $0.yourTiri.beginChange(surface: nil) },
            AppCommand(id: "reportProblem", title: "Report a Problem…", category: "Help") { $0.reportProblem() },
            AppCommand(id: "reopenWithEncoding", title: "Reopen with Encoding…", category: "Editing") { $0.chooseEncoding() },
            AppCommand(id: "saveAsUTF8", title: "Save as UTF-8", category: "Editing") { $0.saveFrontAsUTF8() },
            AppCommand(id: "checkForUpdates", title: "Check for Updates…", category: "Help") { $0.yourTiri.checkForUpdatesNow() },
            AppCommand(id: "showYourTiri", title: "Your Tiri", category: "Settings") { $0.openSettings(pane: .yourTiri) },
            AppCommand(id: "managePlugins", title: "Plugins…", category: "Settings") { $0.openPluginSettings() },
            AppCommand(id: "importPlugin", title: "Import Plugin…", category: "Settings") {
                $0.openPluginSettings()
                $0.plugins.chooseFileToImport()
            },
            AppCommand(id: "reloadPlugins", title: "Reload Plugins", category: "Settings") { $0.plugins.rescan() },
            AppCommand(id: "installCommandLine", title: "Install tiri Command for Other Terminals…", category: "Settings") {
                $0.confirmCommandLineTool(install: true)
            },
        ]
        for command in EditorCommand.allCases {
            list.append(AppCommand(id: command.rawValue, title: command.title, category: "Editing") { $0.frontEditor?.run(command) })
        }
        for number in 1...9 {
            list.append(AppCommand(id: "focusGroup\(number)", title: "Focus Group \(number)", category: "Tabs and Splits") { model in
                model.updateActive { $0.focusGroup(index: number - 1) }
                model.requestFocus()
            })
            list.append(AppCommand(id: "switchWorkspace\(number)", title: "Switch to Workspace \(number)", category: "Workspaces") {
                $0.switchWorkspace(index: number - 1)
            })
        }
        return list
    }()

    func command(_ id: String) -> AppCommand? { commands.byID[id] }

    /// Everything that can have a shortcut, as Settings lists it: the same rows whatever's going
    /// on, with the words a heading already says left out.
    var shortcutCommands: [ShortcutCommand] {
        var seen = Set<String>()
        var list: [ShortcutCommand] = []
        for command in allCommands where seen.insert(command.id).inserted {
            var title = command.title
            if title.hasPrefix(command.category + ": ") { title.removeFirst(command.category.count + 2) }
            if let entry = agentEntries.first(where: { "agent:\($0.id)" == command.id }) { title = "Turn \(entry.name) On or Off" }
            list.append(ShortcutCommand(id: command.id, title: title, group: command.category))
        }
        // The one you're in isn't offered as somewhere to go, but it can still have a key.
        let own = "workspace:\(active.name)"
        if seen.insert(own).inserted {
            list.append(ShortcutCommand(id: own, title: "Switch to Workspace: \(active.name)", group: "Workspaces"))
        }
        return list
    }

    /// Static commands plus the ones that depend on what's in the app right now.
    var allCommands: [AppCommand] {
        var list = commands.list
        // Off means nowhere, and these are only for people with something to change them with.
        if !yourTiri.entriesAreOn { list.removeAll { $0.id == "changeTiri" } }
        if !yourTiri.isUsed && !yourTiri.entriesAreOn { list.removeAll { $0.id == "showYourTiri" } }
        for preset in settings.activePresets where !preset.command.isEmpty {
            list.append(AppCommand(id: "newTerminal:\(preset.name)", title: "New Terminal: \(preset.name)", category: "Terminal") {
                $0.startTerminal(command: preset.command)
            })
        }
        for entry in agentEntries {
            list.append(AppCommand(id: "agent:\(entry.id)", title: "Agents: Turn \(entry.isEnabled ? "Off" : "On") \(entry.name)", category: "Agents") {
                $0.setAgent(entry.id, enabled: !entry.isEnabled)
            })
        }
        for workspace in workspaces where workspace.id != activeID {
            list.append(AppCommand(id: "workspace:\(workspace.name)", title: "Switch to Workspace: \(workspace.name)", category: "Workspaces") {
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
        if let command = commands.byID[id] ?? allCommands.first(where: { $0.id == id }) {
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

    /// `tiri` on this Mac, about a workspace on a server: it speaks in the server's paths, both ways.
    static func handleFromMac(_ request: ControlRequest) async -> ControlResponse {
        let connection = await MainActor.run { AppModel.shared.activeConnection }
        guard let connection else { return await handle(request) }
        var localized = request
        for key in ["path", "cwd"] {
            guard let path = request.args[key]?.stringValue, path.hasPrefix("/"), !RemoteRegistry.shared.isRemote(path),
                  !FileManager.default.fileExists(atPath: path) else { continue }
            localized.args[key] = .string(connection.map.local(path))
        }
        var response = await handle(localized)
        response.result = response.result.map { translate($0, map: connection.map) }
        response.error = response.error.map { connection.map.remoteText($0) }
        return response
    }

    private static func translate(_ value: JSONValue, map: RemotePathMap) -> JSONValue {
        switch value {
        case .string(let text): .string(map.remoteText(text))
        case .array(let list): .array(list.map { translate($0, map: map) })
        case .object(let fields): .object(fields.mapValues { translate($0, map: map) })
        default: value
        }
    }

    static func handle(_ request: ControlRequest) async -> ControlResponse {
        // These wait: for a person to answer, or for a server to come up.
        if request.cmd == "askpass" {
            let answer = await AppModel.shared.answerSSHQuestion(request.args["prompt"]?.stringValue ?? "", host: request.args["host"]?.stringValue ?? "")
            guard let answer else { return ControlResponse.failure(id: request.id, "Cancelled.") }
            return .success(id: request.id, .object(["answer": .string(answer)]))
        }
        if request.cmd == "perf", request.args["measure"]?.stringValue == "highlight" {
            let measured = await Task.detached(priority: .userInitiated) { HighlightEngine.shared.measure() }.value
            return .success(id: request.id, .object(["highlight": measured]))
        }
        if request.cmd == "worktree.add" { return await worktreeAdd(request) }
        if request.cmd == "plugin.verify" {
            return .success(id: request.id, await AppModel.shared.plugins.verify(name: request.args["name"]?.stringValue))
        }
        if request.cmd == "plugin.reload" {
            await withCheckedContinuation { continuation in
                AppModel.shared.plugins.rescan { continuation.resume() }
            }
            return .success(id: request.id, .object([:]))
        }
        // A plugin's command answers with what it did, which can take a while.
        if request.cmd == "run", let id = request.args["command"]?.stringValue, AppModel.shared.plugins.owns(id) {
            let done = await AppModel.shared.plugins.run(id, args: request.args["args"]?.objectValue ?? [:], quietly: true)
            if let problem = done.problem { return .failure(id: request.id, problem) }
            return .success(id: request.id, .object(["ran": .string(id), "output": .string(done.output)]))
        }
        if request.cmd == "work" { return await work(request) }
        if request.cmd.hasPrefix("web.") { return await AppModel.shared.webCommand(request) }
        if request.cmd == "conversations" { return await conversations(request) }
        if request.cmd == "remote.connect" { return await remoteConnect(request) }
        if request.cmd == "remote.forward" { return await remoteForward(request) }
        let touched = paths(in: request)
        if !touched.isEmpty { _ = await FolderAccess.deniedPaths(touched) }
        // A language server may need a while to look.
        if request.cmd == "diagnostics" {
            return await diagnostics(request)
        }
        if request.cmd == "languages" || request.cmd == "languages.add" {
            await AppModel.shared.languageServers.waitForLocations()
        }
        if request.cmd == "languages.add" {
            let hub = AppModel.shared.languageServers
            guard let definition = LanguageServerCatalog.all.first(where: { $0.id == request.args["id"]?.stringValue }) else {
                return ControlResponse.failure(id: request.id, "No such language server. Run tiri languages.")
            }
            guard definition.managed != nil else { return ControlResponse.failure(id: request.id, "Tiri can't install this one itself. The usual way: \(definition.installHint)") }
            if let failure = await hub.add(definition) { return ControlResponse.failure(id: request.id, failure) }
            return .success(id: request.id, .object(["added": .string(definition.id)]))
        }
        if let response = await history(request) { return response }
        // Looking at a turn can mean snapshotting the files. The app keeps responding while it does.
        if request.cmd == "changes", let wanted = request.args["turn"]?.stringValue {
            let (turn, folders, snapshots) = await MainActor.run { () -> (AgentTurn?, [String], TurnSnapshots) in
                let model = AppModel.shared
                return (model.turns.resolving(wanted == "latest" ? .latestTurn : .turn(wanted), in: model.activeID), model.active.folders, model.snapshots)
            }
            guard let turn else { return ControlResponse.failure(id: request.id, "No such turn. Run tiri turns.") }
            let found = await Task.detached(priority: .userInitiated) { snapshots.changes(in: turn, folders: folders) }.value
            return ControlResponse.success(id: request.id, .array(found.map { change in
                .object(["status": .string(change.status.letter), "path": .string(change.path)])
            }))
        }
        // These can go over the network. The app keeps responding while they do.
        if request.cmd == "git" || request.cmd == "changes" {
            let folders = await MainActor.run { AppModel.shared.active.folders }
            if request.cmd == "changes" {
                let found = await Task.detached(priority: .userInitiated) { Git.changesAcross(folders) }.value
                return .success(id: request.id, .array(found.map { change in
                    .object(["status": .string(change.status.letter), "path": .string(change.path)])
                }))
            }
            let found = await Task.detached(priority: .userInitiated) { Git.repositoriesAcross(folders) }.value
            return .success(id: request.id, .array(found.map { repository in
                var object: [String: JSONValue] = ["root": .string(repository.root), "head": .string(repository.title),
                                                   "ahead": .int(repository.ahead), "behind": .int(repository.behind),
                                                   "dirty": .bool(repository.isDirty)]
                if let upstream = repository.upstream { object["upstream"] = .string(upstream) }
                return .object(object)
            }))
        }
        // These read a lot of files. The app keeps responding while they do.
        if request.cmd == "search", let query = request.args["query"]?.stringValue {
            let paths = await AppModel.shared.searchablePaths()
            let (connection, folders, excludes) = await MainActor.run { (AppModel.shared.activeConnection, AppModel.shared.active.folders, AppModel.shared.settings.filesExclude) }
            let collector = SearchCollector()
            await Task.detached(priority: .userInitiated) {
                AppModel.runSearch(query: query, on: connection, folders: folders, paths: paths, excludes: excludes, cancellation: ContentSearch.Cancellation()) { collector.add($0) }
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

    private static func diagnostics(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        var paths = request.args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if paths.isEmpty {
            let folders = model.active.folders
            let changes = await Task.detached(priority: .userInitiated) { Git.changesAcross(folders) }.value
            paths = changes.filter { $0.status != .deleted }.map(\.path)
        }
        var problems: [JSONValue] = []
        var uncovered: [String] = []
        var checked = 0
        for path in paths where LanguageServerCatalog.definition(for: path) != nil {
            guard let found = await model.languageServers.diagnostics(for: path, waiting: 20) else {
                uncovered.append(path)
                continue
            }
            checked += 1
            problems += found.sorted { ($0.severity, $0.line) < ($1.severity, $1.line) }.map { problem in
                .object(["path": .string(path), "line": .int(problem.line + 1), "column": .int(problem.character + 1),
                         "severity": .string(problem.severity.word), "message": .string(problem.message),
                         "text": .string(problem.printed(path: path))])
            }
        }
        return ControlResponse.success(id: request.id, .object(["problems": .array(problems), "checked": .int(checked),
                                                                "uncovered": .array(uncovered.map(JSONValue.string))]))
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
            if let commit = spec.commit { object["commit"] = .string(commit) }
            if spec.branch == true { object["branch"] = true }
        case .settings:
            break
        case .plugin(let spec):
            object["plugin"] = .string(spec.plugin)
            object["panel"] = .string(spec.panel)
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

    @MainActor
    private static func conversations(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        let all = await model.loadConversations()
        if let session = request.args["open"]?.stringValue {
            guard let conversation = all.first(where: { $0.session == session || $0.id == session }) else {
                return .failure(id: request.id, "No conversation \(session). Run tiri conversations to see them.")
            }
            guard let path = await model.showConversation(conversation) else { return .failure(id: request.id, "Couldn't read that conversation.") }
            return .success(id: request.id, .object(["path": .string(path)]))
        }
        if let session = request.args["read"]?.stringValue {
            guard let conversation = all.first(where: { $0.session == session || $0.id == session }) else {
                return .failure(id: request.id, "No conversation \(session). Run tiri conversations to see them.")
            }
            guard let path = await model.writeConversation(conversation) else { return .failure(id: request.id, "Couldn't read that conversation.") }
            return .success(id: request.id, .object(["path": .string(path)]))
        }
        if let session = request.args["reopen"]?.stringValue {
            guard let conversation = all.first(where: { $0.session == session || $0.id == session }) else {
                return .failure(id: request.id, "No conversation \(session). Run tiri conversations to see them.")
            }
            model.reopen(conversation)
            return .success(id: request.id, .object([:]))
        }
        if let session = request.args["hand"]?.stringValue {
            guard let conversation = all.first(where: { $0.session == session || $0.id == session }) else {
                return .failure(id: request.id, "No conversation \(session). Run tiri conversations to see them.")
            }
            let wanted = request.args["to"]?.stringValue?.lowercased()
            guard let preset = model.settings.activePresets.first(where: { $0.name.lowercased() == wanted || $0.command.lowercased().hasPrefix(wanted ?? "\u{0}") }) else {
                return .failure(id: request.id, "No agent called \(wanted ?? "that") in the New Terminal menu.")
            }
            guard let path = await model.showConversation(conversation) else { return .failure(id: request.id, "Couldn't read that conversation.") }
            model.hand(conversation, shownAt: path, to: preset)
            return .success(id: request.id, .object(["path": .string(path)]))
        }
        var shown = all
        var excerpts: [String: String] = [:]
        if let words = request.args["query"]?.stringValue, !words.isEmpty {
            let lower = words.lowercased()
            // An agent gets a whole answer, and the wait is only ever the first time.
            await model.conversationIndexing?.value
            let found = await model.conversationMatches(words, among: all)
            excerpts = found.excerpts
            let inTitle = all.filter { $0.title.lowercased().contains(lower) }
            shown = inTitle + found.conversations.filter { !inTitle.contains($0) }
        }
        return .success(id: request.id, .array(shown.prefix(100).map { conversation in
            var entry: [String: JSONValue] = ["session": .string(conversation.session), "agent": .string(conversation.agent), "title": .string(model.conversationTitle(conversation)),
                                              "cwd": .string(conversation.cwd ?? ""), "when": .string(RelativeTime.text(conversation.date))]
            if let excerpt = excerpts[conversation.file] { entry["match"] = .string(ConversationIndex.plain(excerpt)) }
            return .object(entry)
        }))
    }

    private static func work(_ request: ControlRequest) async -> ControlResponse {
        let folders = AppModel.shared.active.folders
        let lines = await Task.detached(priority: .userInitiated) { Git.otherWork(in: folders) }.value
        return .success(id: request.id, .array(lines.map { line in
            var entry: [String: JSONValue] = ["branch": .string(line.branch), "summary": .string(line.summary), "merged": .bool(line.merged),
                                              "base": .string(line.base), "subject": .string(line.subject)]
            if let worktree = line.worktree { entry["worktree"] = .string(worktree) }
            return .object(entry)
        }))
    }

    private static func worktreeAdd(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        guard let branch = request.args["branch"]?.stringValue else { return .failure(id: request.id, "Which branch?") }
        let terminal = request.args["source"]?.stringValue
        let source = terminal.flatMap { model.existingController(for: $0) as? TerminalController }?.currentDirectory
        // A terminal that hasn't been looked at yet has no controller, but its workspace still has folders.
        let holder = terminal.flatMap { model.workspace(containing: $0) } ?? model.active
        guard let folder = source ?? holder.folders.first else { return .failure(id: request.id, "This workspace has no folder.") }
        // From a terminal it's an agent asking. Where you're looking stays your call.
        switch await model.addWorktree(branch: branch, from: folder, activating: request.args["source"] == nil).value {
        case .success(let workspace):
            return .success(id: request.id, .object(["workspace": .string(workspace.name), "folder": .string(workspace.folders.first ?? "")]))
        case .failure(let failure):
            return .failure(id: request.id, failure.message)
        }
    }

    @MainActor
    private static func remoteConnect(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        guard let typed = request.args["host"]?.stringValue, let destination = SSHConfigFile.destination(from: typed) else {
            return .failure(id: request.id, "That isn't a host.")
        }
        let result: Result<RemoteConnection, RemoteFailure> = await withCheckedContinuation { continuation in
            model.remote.whenReady(destination) { continuation.resume(returning: $0) }
        }
        switch result {
        case .failure(let failure):
            return .failure(id: request.id, failure.description)
        case .success(let connection):
            let wanted = request.args["folder"]?.stringValue ?? "~"
            let resolved = await Task.detached { connection.resolveFolder(wanted) }.value
            guard let resolved else { return .failure(id: request.id, "\(wanted) isn't a folder on \(typed).") }
            let workspace = model.openRemoteFolder(resolved, on: destination)
            return .success(id: request.id, .object(["workspace": .string(workspace.name), "folder": .string(resolved)]))
        }
    }

    @MainActor
    private static func remoteForward(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        guard let port = request.args["port"]?.intValue else { return .failure(id: request.id, "Which port?") }
        guard let destination = request.args["host"]?.stringValue ?? model.active.remote else {
            return .failure(id: request.id, "This workspace isn't on a server.")
        }
        guard let local = await model.remote.forward(remotePort: port, on: destination) else {
            return .failure(id: request.id, "Couldn't forward port \(port).")
        }
        return .success(id: request.id, .object(["local": .int(local), "remote": .int(port)]))
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
            guard let url, url.scheme != nil else { throw ControlFailure("Not a URL or path: \(target)") }
            // The person keeps this site in their browser, so that's where it goes, and the agent is told.
            let direction = split(request)
            if model.sendsToBrowser(url, openHere: { _ = model.openWeb(url: target, split: direction, in: sourceWorkspace) }) {
                return .object(["browser": .string(url.absoluteString)])
            }
            return .object(["item": .string(model.openWeb(url: target, split: direction, in: sourceWorkspace))])

        case "term":
            var cwd = request.args["cwd"]?.stringValue
            // Run on the Mac with a server's workspace in front, where it was run from means nothing there.
            if let given = cwd, let destination = model.active.remote, model.remote.existingConnection(destination)?.map.contains(given) != true { cwd = nil }
            if let cwd {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ControlFailure("No such directory: \(cwd)")
                }
            }
            let id = model.newTerminal(command: request.args["cmd"]?.stringValue, cwd: cwd, split: split(request), in: sourceWorkspace)
            return .object(["item": .string(id)])

        case "activate":
            AppModel.bringAppForward()
            return .object([:])

        case "activity":
            return .array(model.agentOverview.map { row in
                var entry: [String: JSONValue] = ["item": .string(row.item), "agent": .string(row.agent), "name": .string(row.name), "status": .string(row.status.rawValue),
                                                  "workspace": .string(row.workspace), "files": .array(row.files.map(JSONValue.string))]
                if let prompt = row.prompt { entry["prompt"] = .string(prompt) }
                if let doing = row.doing { entry["doing"] = .string(doing) }
                return .object(entry)
            })

        case "dev.change":
            guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1", let row = request.args["row"]?.intValue,
                  let id = model.active.peek?.id ?? model.active.focused.active, let viewer = model.existingController(for: id) as? DiffController else {
                throw ControlFailure("Only for a test copy, with a diff in front.")
            }
            viewer.hoverForTest(row: row)
            switch request.args["action"]?.stringValue {
            case "undo": viewer.requestForTest(.undo)
            case "ask": viewer.requestForTest(.ask)
            default: break
            }
            return .object([:])

        case "dev.notification":
            // What a click on a notification does, past the part only the system can do.
            guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1", let item = request.args["item"]?.stringValue,
                  let workspace = model.workspace(containing: item) else { throw ControlFailure("Only for a test copy.") }
            model.focusFromNotification(workspace: workspace.id, item: item)
            return .object([:])

        case "dev.page":
            guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1", let script = request.args["script"]?.stringValue else { throw ControlFailure("Only for a test copy.") }
            if let web = model.frontWebController {
                web.webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
            } else if let viewer = model.frontNotebook {
                viewer.runInPage(script)
            } else {
                throw ControlFailure("Nothing to run that in.")
            }
            return .object([:])

        case "notebook.status", "notebook.run", "notebook.interrupt", "notebook.restart", "notebook.stop", "notebook.input":
            guard let path = request.args["path"]?.stringValue, path.hasSuffix(".ipynb"), FileManager.default.fileExists(atPath: path) else {
                throw ControlFailure("That isn't a notebook.")
            }
            let kernel = model.notebookKernels.kernel(for: path)
            switch request.cmd {
            case "notebook.run":
                if let cell = request.args["cell"]?.intValue { kernel.run(cells: [cell]) } else { kernel.runAll() }
            case "notebook.interrupt": kernel.interrupt()
            case "notebook.restart": kernel.restart()
            case "notebook.stop": kernel.stop()
            case "notebook.input":
                guard kernel.question != nil else { throw ControlFailure("That notebook isn't waiting for input.") }
                kernel.answer(request.args["text"]?.stringValue ?? "")
            default: kernel.adoptIfRunning()
            }
            var result: [String: JSONValue] = ["state": .string(String(describing: kernel.state))]
            if let running = kernel.running { result["running"] = .int(running) }
            result["queued"] = .array(kernel.queued.map(JSONValue.int))
            if let title = kernel.title { result["python"] = .string(title) }
            if let question = kernel.question { result["asking"] = .string(question.prompt.isEmpty ? "input" : question.prompt) }
            if let python = kernel.pythonPath { result["path"] = .string(python) }
            return .object(result)

        case "remote.list":
            let hosts = Set(model.workspaces.compactMap(\.remote))
            return .array(hosts.sorted().map { host in
                let state = model.remote.state(of: host)
                var detail = ""
                if case .failed(let message) = state { detail = message }
                if case .reconnecting(let attempt) = state { detail = "attempt \(attempt)" }
                return .object(["host": .string(host), "state": .string(state.label), "detail": .string(detail)])
            })

        case "remote.ports":
            return .array(model.remote.forwards.map {
                .object(["host": .string($0.destination), "remote": .int($0.remotePort), "local": .int($0.localPort)])
            })

        case "remote.disconnect":
            let host = try string(request, "host")
            let destination = SSHConfigFile.destination(from: host) ?? host
            guard let connection = model.remote.existingConnection(destination) else { throw ControlFailure("Not connected to \(host).") }
            connection.disconnect()
            return .object([:])

        case "workspace.list":
            let list = model.workspaces.enumerated().map { index, workspace -> JSONValue in
                let counts = model.unseenCount(in: workspace)
                return .object([
                    "id": .string(workspace.id), "name": .string(workspace.name), "index": .int(index + 1),
                    "active": .bool(workspace.id == model.activeID),
                    "folders": .array(workspace.folders.map { JSONValue.string(RemoteRegistry.shared.displayPath($0)) }),
                    "remote": workspace.remote.map(JSONValue.string) ?? .null,
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
                                   session: request.args["session"]?.stringValue,
                                   turn: request.args["turn"]?.stringValue,
                                   prompt: request.args["prompt"]?.stringValue,
                                   activity: request.args["activity"]?.stringValue,
                                   files: request.args["files"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return .object(["item": .string(id), "status": .string(model.runtimes[id]?.status.rawValue ?? "idle")])

        case "settings.list", "settings.explain":
            let settings = model.settings
            // An agent asked about these should say what's really going on, as the screen does.
            func explanation(of definition: SettingDefinition) -> String {
                guard definition.key.hasPrefix("conversations."), let why = ConversationAssistant.state.message else { return definition.fullExplanation }
                return why + " " + definition.fullExplanation
            }
            func entry(_ definition: SettingDefinition) -> JSONValue {
                .object(["key": .string(definition.key), "section": .string(definition.section), "title": .string(definition.title),
                         "explanation": .string(explanation(of: definition)), "accepts": .string(SettingsSchema.allowedValues(definition.kind)),
                         "value": definition.value(settings), "display": .string(SettingsSchema.display(definition.value(settings))),
                         "defaultDisplay": .string(SettingsSchema.display(definition.value(TiriSettings())))])
            }
            if let key = request.args["key"]?.stringValue {
                guard let definition = SettingsSchema.definition(for: key) else {
                    throw ControlFailure("No setting called \"\(key)\". Run tiri settings to see them all.")
                }
                return .array([entry(definition)])
            }
            return .array(SettingsSchema.everything.map(entry))

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
            guard let what = request.args["what"]?.stringValue, !what.isEmpty else {
                model.openSettings()
                return .object([:])
            }
            // A command, for someone looking at its shortcut.
            if model.shortcutCommands.contains(where: { $0.id == what }) {
                model.openSettings(pane: .keyboard, reveal: what)
                return .object([:])
            }
            switch SettingsSchema.openTarget(what) {
            case .pane(let pane): model.openSettings(pane: pane)
            case .setting(let key): model.openSettings(pane: SettingsSchema.definition(for: key)?.pane, reveal: key)
            case .search(let words): model.openSettings(search: words)
            }
            return .object([:])

        case "report":
            let facts = model.problemFacts(crash: ProblemReport.latestCrash(bundleID: AppModel.reportBundleID, since: Date().addingTimeInterval(-7 * 86400)))
            let body = ProblemReport.body(facts)
            let url = ProblemReport.issueURL(title: request.args["title"]?.stringValue ?? "", body: body)
            if request.args["open"]?.boolValue == true { NSWorkspace.shared.open(url) }
            return .object(["body": .string(body), "url": .string(url.absoluteString)])

        case "change.facts":
            model.yourTiri.recordFacts()
            return .object([:])

        case "change.refresh":
            model.yourTiri.refresh()
            return .object([:])

        case "dev.your-tiri":
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            let yours = model.yourTiri
            let value = request.args["value"]?.stringValue
            switch request.args["action"]?.stringValue {
            case "point": yours.beginChange(surface: value)
            case "ask":
                guard let preset = model.runnableAgentPresets().first else { throw ControlFailure("No agent can run here.") }
                _ = yours.startChange(sentence: value ?? "", surface: nil, preset: preset)
            case "try": DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { yours.tryReady() }
            case "keep": yours.keep()
            case "back": DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { yours.back() }
            case "plain": DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { yours.usePlain() }
            case "yours": DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { yours.useYours() }
            case "toggle":
                guard let change = yours.changes.first(where: { $0.id == value }) else { throw ControlFailure("No such change.") }
                yours.setChange(change, on: !change.isOn)
            case "update": DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { yours.applyUpdate() }
            case "repairs": yours.answerRepairs(value == "yes")
            case "later": yours.putOffWaiting()
            case "marking": yours.beginMarking(query: value ?? "")
            case "mark":
                let numbers = (value ?? "").split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 4 else { throw ControlFailure("x,y,width,height") }
                yours.finishMarking(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            case "unfold": UserDefaults.standard.set(true, forKey: "YourTiri.open.\(value ?? "")")
            case "where": break
            case "notice", "press-notice":
                guard let item = value ?? yours.draft?.item, let terminal = model.existingController(for: item) as? TerminalController else { throw ControlFailure("No change is being made.") }
                if request.args["action"]?.stringValue == "press-notice" { terminal.pressNotice() }
                return .object(["notice": .string(terminal.noticeText ?? ""), "item": .string(item)])
            default: throw ControlFailure("Unknown action.")
            }
            yours.refresh()
            return .object(["personal": .bool(yours.isPersonalCopy), "bundle": .string(Bundle.main.bundlePath),
                            "commit": .string(Bundle.main.object(forInfoDictionaryKey: YourTiri.commitKey) as? String ?? ""),
                            "swiftTools": .bool(SwiftTools.areHere()), "marking": .bool(yours.isMarking),
                            "ready": .string(yours.ready?.sentence ?? ""), "trial": .string(yours.state?.trial?.sentence ?? ""),
                            "plainForNow": .bool(PlainForNow.isOn), "panes": .array(model.settingsPanes.map { .string($0.rawValue) }),
                            "offers": .bool(yours.entriesAreOn), "update": .string(yours.update?.line ?? ""), "version": .string(YourTiriModel.version)])

        case "dev.settings":
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            switch request.args["action"]?.stringValue {
            case "record": model.beginRecordingShortcut(for: try string(request, "command"))
            case "key":
                guard let strokes = Keymap.parseStrokes(try string(request, "key")) else { throw ControlFailure("Can't read that key.") }
                for stroke in strokes { model.recordKey(stroke) }
            case "find-key": model.beginFindingShortcutKey()
            case "filter": model.settingsUI.shortcutFilter = ShortcutFilter(rawValue: try string(request, "value")) ?? .all
            case "confirm": model.confirmShortcutConflict()
            case "reveal": model.settingsUI.reveal = try string(request, "value")
            case "jump": model.settingsUI.jump(to: try string(request, "value"))
            case "where": break
            case "ai":
                ConversationAssistant.pretending = MacModelState(rawValue: try string(request, "value"))
                model.settingsUI.macModelChanges += 1
                model.updateSummarizingAll()
            case "expand": model.settingsUI.expandedAgent = try string(request, "value")
            case "plugin-request": model.settingsUI.newPluginRequest = try string(request, "value")
            case "plugin-ask":
                guard let preset = model.runnableAgentPresets().first else { throw ControlFailure("No agent can run here.") }
                model.askAgentToBuildPlugin(preset: preset, request: model.settingsUI.newPluginRequest)
                model.settingsUI.newPluginRequest = ""
            default: throw ControlFailure("Unknown action.")
            }
            return .object(["section": .string(model.settingsUI.currentSection ?? ""),
                            "recording": .string(model.recordingShortcutFor ?? ""),
                            "notice": .string(model.shortcutNotice.map(String.init(describing:)) ?? "")])

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

        case "git":
            return .array(Git.repositoriesAcross(model.active.folders).map { repository in
                var object: [String: JSONValue] = ["root": .string(repository.root), "head": .string(repository.title),
                                                   "ahead": .int(repository.ahead), "behind": .int(repository.behind),
                                                   "dirty": .bool(repository.isDirty)]
                if let upstream = repository.upstream { object["upstream"] = .string(upstream) }
                return .object(object)
            })

        case "agents.list":
            return .array(model.agentEntries.map { entry in
                .object(["id": .string(entry.id), "name": .string(entry.name), "command": .string(entry.command),
                         "state": .string(entry.isEnabled ? "on" : "off"), "custom": .bool(entry.isCustom)])
            })

        case "agents.set":
            guard let on = request.args["on"]?.boolValue else { throw ControlFailure("Missing argument \"on\"") }
            if let problem = model.setAgent(try string(request, "agent"), enabled: on) { throw ControlFailure(problem) }
            return .object([:])

        case "agents.add":
            if let problem = model.addAgent(name: try string(request, "name"), command: try string(request, "command")) { throw ControlFailure(problem) }
            return .object([:])

        case "agents.remove":
            if let problem = model.removeAgent(try string(request, "agent")) { throw ControlFailure(problem) }
            return .object([:])

        case "plugin.list":
            return .array(model.plugins.plugins.map { plugin in
                var object: [String: JSONValue] = ["name": .string(plugin.name), "title": .string(plugin.title), "version": .string(plugin.manifest?.version ?? ""),
                                                   "folder": .string(plugin.folder.path), "adds": .array((plugin.manifest?.additions ?? []).map(JSONValue.string))]
                switch plugin.state {
                case .on: object["state"] = "on"
                case .off: object["state"] = "off"
                case .changed(let changes):
                    object["state"] = "changed"
                    object["why"] = .string(changes.summary.replacingOccurrences(of: "\n", with: "; "))
                case .broken(let why):
                    object["state"] = "broken"
                    object["why"] = .string(why)
                }
                return .object(object)
            })

        case "plugin.enable":
            let name = try string(request, "name")
            guard model.plugins.plugin(named: name) != nil else { throw ControlFailure("No plugin called \(name). Run tiri plugin.") }
            guard model.window?.attachedSheet == nil else { throw ControlFailure("Tiri is already asking something on screen. Try again once it's answered.") }
            // A no is an answer. Asking again and again until someone gives in isn't asking.
            if let wait = model.plugins.secondsUntilAskingAgain(name) { throw ControlFailure("The person just said no. Talk to them about it, and don't ask again for \(wait) seconds.") }
            model.plugins.askToEnable(name)
            return .object([:])

        case "plugin.remove":
            let name = try string(request, "name")
            guard model.plugins.plugin(named: name) != nil else { throw ControlFailure("No plugin called \(name). Run tiri plugin.") }
            guard model.window?.attachedSheet == nil else { throw ControlFailure("Tiri is already asking something on screen. Try again once it's answered.") }
            model.plugins.askToRemove(name)
            return .object([:])

        case "plugin.disable":
            let name = try string(request, "name")
            guard model.plugins.plugin(named: name) != nil else { throw ControlFailure("No plugin called \(name). Run tiri plugin.") }
            model.plugins.disable(name)
            return .object([:])

        case "plugin.logs":
            let name = try string(request, "name")
            return .object(["text": .string((try? String(contentsOf: PluginProcesses.logFile(name), encoding: .utf8)) ?? "")])

        case "plugin.update":
            let name = try string(request, "name")
            if let problem = model.plugins.push(plugin: name, surface: try string(request, "surface"), id: try string(request, "id"), value: request.args["value"] ?? .null) {
                throw ControlFailure(problem)
            }
            return .object([:])

        case "plugin.post":
            let target = try string(request, "name").split(separator: ".", maxSplits: 1).map(String.init)
            guard let name = target.first else { throw ControlFailure("Which plugin?") }
            guard model.plugins.enabledPlugin(named: name) != nil else { throw ControlFailure("\(name) isn't on.") }
            let reached = model.plugins.post(plugin: name, panel: target.count > 1 ? target[1] : nil, event: try string(request, "event"), data: request.args["data"] ?? .null)
            return .object(["reached": .int(reached)])

        case "plugin.building":
            model.plugins.building(item: try string(request, "item"), request: nil, plugin: try string(request, "name"))
            return .object([:])

        case "dev.plugin-answer":
            // What the buttons do. In a test copy only: a real yes takes a real press.
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            guard model.plugins.answerForTest(yes: request.args["yes"]?.boolValue == true) else { throw ControlFailure("Nothing is being asked.") }
            return .object([:])

        case "dev.key":
            // A real key event through the app's own queue, which is as close as a hidden window gets.
            guard AppModel.isTestCopy, let code = request.args["code"]?.intValue, let window = model.window else { throw ControlFailure("Only for a test copy.") }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(code)) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            return .object([:])

        case "dev.browser":
            // What a test copy would have opened in a browser: it never opens one.
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            return .object(["sent": .array(model.sentToBrowser.map(JSONValue.string)), "rules": .array(model.settings.webOpenInBrowser.map(JSONValue.string)),
                            "peek": .string(model.active.peek.map { model.title(for: $0) } ?? "")])

        case "dev.drag":
            // The left button down, moved in steps, and up: what a real drag sends, for the monitors to see first.
            guard AppModel.isTestCopy, let window = model.window, let height = window.contentView?.bounds.height,
                  case .array(let from) = request.args["from"], case .array(let to) = request.args["to"],
                  let x1 = from.first?.numberValue, let y1 = from.last?.numberValue,
                  let x2 = to.first?.numberValue, let y2 = to.last?.numberValue else { throw ControlFailure("Only for a test copy.") }
            let steps = 6
            for step in 0...(steps + 1) {
                let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step <= steps ? .leftMouseDragged : .leftMouseUp
                let progress = Double(min(step, steps)) / Double(steps)
                let point = CGPoint(x: x1 + (x2 - x1) * progress, y: height - (y1 + (y2 - y1) * progress))
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            return .object([:])

        case "dev.plugin-question":
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            return .object(["question": .string(model.plugins.pendingQuestion ?? ""), "lastShare": .string(model.plugins.lastShare),
                            "building": .array(model.plugins.liveBuilds.compactMap(\.plugin).map(JSONValue.string))])

        case "dev.plugin-import":
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            model.plugins.lastShare = ""
            model.plugins.importPlugin(at: URL(fileURLWithPath: try string(request, "path")))
            return .object([:])

        case "dev.plugin-export":
            guard AppModel.isTestCopy else { throw ControlFailure("Only for a test copy.") }
            model.plugins.lastShare = ""
            model.plugins.exportPlugin(try string(request, "name"), to: URL(fileURLWithPath: try string(request, "path")))
            return .object([:])

        case "languages":
            let roots = model.active.folders.map(Git.real)
            return .array(LanguageServerCatalog.all.map { definition in
                let hub = model.languageServers
                var object: [String: JSONValue] = ["id": .string(definition.id), "language": .string(definition.language), "canAdd": .bool(definition.managed != nil), "install": .string(definition.installHint)]
                switch hub.availability(of: definition, roots: roots) {
                case .looking: object["state"] = "looking"
                case .missing: object["state"] = "not installed"
                case .installing: object["state"] = "installing"
                case .needsTrust(let path):
                    object["state"] = "only in this project"
                    object["path"] = .string(path)
                case .wontStart(let path):
                    object["state"] = "won't start"
                    object["path"] = .string(path)
                case .found(let path):
                    object["state"] = hub.isRunning(definition) ? "running" : (hub.isStarting(definition) ? "starting" : "found")
                    object["path"] = .string(path)
                }
                return .object(object)
            })

        case "turns":
            return .array(model.turns.filter { $0.workspace == model.activeID }.map { turn in
                var object: [String: JSONValue] = ["id": .string(turn.id), "item": .string(turn.item), "title": .string(turn.title),
                                                   "state": .string(turn.isOpen ? "working" : (turn.changedNothing ? "no changes" : "done"))]
                if let prompt = turn.prompt { object["prompt"] = .string(prompt) }
                return .object(object)
            })

        case "diff":
            let path = try string(request, "path")
            var turn: String?
            if let wanted = request.args["turn"]?.stringValue {
                guard let found = model.turns.resolving(wanted == "latest" ? .latestTurn : .turn(wanted), in: model.activeID) else {
                    throw ControlFailure("No such turn. Run tiri turns.")
                }
                turn = found.id
            }
            if request.args["mode"]?.stringValue == "tab" {
                model.openDiff(DiffSpec(path: path, turn: turn), preview: false)
            } else {
                model.peekDiff(DiffSpec(path: path, turn: turn), takeFocus: false)
            }
            return .object([:])

        case "review.list":
            return .array(model.active.review.map { comment in
                var object: [String: JSONValue] = ["id": .string(comment.id), "path": .string(comment.path), "text": .string(comment.text)]
                if let first = comment.firstLine { object["line"] = .int(first) }
                if let last = comment.lastLine { object["lastLine"] = .int(last) }
                return .object(object)
            })

        case "review.add":
            let path = try string(request, "path")
            guard FileManager.default.fileExists(atPath: path) else { throw ControlFailure("No such file: \(path)") }
            let first = request.args["line"]?.intValue
            let last = request.args["lastLine"]?.intValue ?? first
            let excerpt = first.flatMap { ReviewQuote.lines($0, last ?? $0, of: path) }
            let comment = ReviewComment(path: path, firstLine: first, lastLine: last, excerpt: excerpt, text: try string(request, "text"))
            model.addReviewComment(comment, in: sourceWorkspace)
            return .object(["id": .string(comment.id)])

        case "review.remove":
            let id = try string(request, "id")
            guard model.active.review.contains(where: { $0.id == id }) else { throw ControlFailure("No comment with id \(id). Run tiri review.") }
            model.removeReviewComment(id)
            return .object([:])

        case "review.clear":
            model.discardReview()
            return .object([:])

        case "review.send":
            guard !model.active.review.isEmpty else { throw ControlFailure("There are no review comments to send") }
            if let target = request.args["item"]?.stringValue {
                guard model.sendReview(to: target) else { throw ControlFailure("\(target) isn't a running agent. Run tiri items.") }
                return .object(["sent": true])
            }
            model.sendReview()
            return .object([:])

        case "select":
            let id = try requireItem(request, model: model)
            guard let controller = model.controller(for: id), controller.select(text: try string(request, "text"), to: request.args["to"]?.stringValue) else {
                throw ControlFailure("That isn't in \(id)")
            }
            return .object([:])

        case "follow":
            let id = try requireItem(request, model: model)
            guard let row = request.args["row"]?.intValue, let col = request.args["col"]?.intValue else {
                throw ControlFailure("Missing row or column")
            }
            if let viewer = model.controller(for: id) as? SymbolViewing {
                guard model.followSymbol(in: viewer, row: row, column: col) else { throw ControlFailure("There's no name there") }
                return .object(["item": .string(id)])
            }
            guard let terminal = model.controller(for: id) as? TerminalController else { throw ControlFailure("\(id) isn't a terminal or a code viewer") }
            guard terminal.terminalView.followLink(row: row, column: col, forceTab: false) else {
                throw ControlFailure("There's no link or path there")
            }
            return .object(["item": .string(id)])

        case "read":
            let id = try requireItem(request, model: model)
            guard let terminal = model.controller(for: id) as? TerminalController else { throw ControlFailure("\(id) isn't a terminal") }
            return .object(["text": .string(terminal.readText(lines: request.args["lines"]?.intValue))])

        case "dev-blocked-link":
            // SwiftTerm's own alert, as it builds it, as if a ⌘-click on this terminal had just set it off.
            guard AppModel.isTestCopy else { throw ControlFailure("Only in a test copy.") }
            let id = try requireItem(request, model: model)
            guard let terminal = model.controller(for: id) as? TerminalController, let window = terminal.terminalView.window else { throw ControlFailure("\(id) isn't a terminal on screen") }
            BlockedLinks.clicked = (terminal.terminalView, Date(), false)
            let alert = NSAlert()
            alert.messageText = "Link blocked"
            alert.informativeText = request.args["reason"]?.stringValue ?? "The target is not an absolute URL with a scheme."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
            let text = NSTextView(frame: scroll.contentView.bounds)
            text.string = request.args["target"]?.stringValue ?? ""
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in }
            let shown = window.attachedSheet != nil
            if shown, let sheet = window.attachedSheet { window.endSheet(sheet) }
            return .object(["alertShown": .bool(shown)])

        case "dev-compose":
            guard Bundle.main.bundleIdentifier?.contains(".test.") == true else { throw ControlFailure("Only in a test copy.") }
            guard let view = model.frontEditor?.codeView, let text = request.args["text"]?.stringValue else { throw ControlFailure("No file in front.") }
            if request.args["commit"]?.boolValue == true {
                view.insertText(text, replacementRange: view.markedRange().location == NSNotFound ? NSRange(location: NSNotFound, length: 0) : view.markedRange())
            } else {
                view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return .object([:])

        case "perf":
            var object: [String: JSONValue] = ["footprintMB": .double(ProcessClock.footprintMegabytes())]
            if let switching = model.lastSwitchMilliseconds { object["lastSwitchMs"] = .double(switching) }
            object["plugins"] = .int(model.plugins.plugins.count)
            object["pluginsOn"] = .int(model.plugins.enabled.count)
            object["pluginProcesses"] = .int(model.plugins.processes.runningCount)
            if let scan = model.plugins.scanMilliseconds { object["pluginScanMs"] = .double(scan) }
            if let launch = model.launchMilliseconds { object["launchMs"] = .double(launch) }
            if let open = model.lastOpenMilliseconds { object["lastOpenMs"] = .double(open) }
            object["indexedFiles"] = .int(model.fileIndex.files.count)
            object["firstResponder"] = .string(model.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
            if let editor = model.frontEditor { object["completion"] = editor.completion.state }
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
