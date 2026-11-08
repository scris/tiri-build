import AppKit
import TiriCore

/// Files that come from outside Tiri: Finder's Open With, the Dock icon, `tiri://` links, `tiri open` from another
/// terminal, and the editor other programs start. Like VS Code, each goes to the workspace that has its folder.
extension AppModel {
    /// The workspace with the folder that holds this file most closely. The one in front wins a tie, and gets
    /// any file that's in none of them.
    func workspaceForOutsideFile(_ rawPath: String) -> WorkspaceID {
        var best: (id: WorkspaceID, length: Int)?
        for workspace in workspaces where workspace.remote == nil {
            guard let folder = workspace.folder(containing: aliasedPath(rawPath, in: workspace.id)) else { continue }
            if let current = best, folder.count < current.length || (folder.count == current.length && workspace.id != activeID) { continue }
            best = (workspace.id, folder.count)
        }
        return best?.id ?? activeID
    }

    /// Opens it as a tab where it belongs, going to that workspace. `asSource` shows a page as its text.
    @discardableResult
    func openFromOutside(_ path: String, line: Int? = nil, col: Int? = nil, asSource: Bool = false) -> ItemID? {
        let target = workspaceForOutsideFile(path)
        if target != activeID { switchWorkspace(target) }
        guard let id = open(path: path, line: line, col: col, intent: .pinned, in: target) else { return nil }
        if asSource { showAsText(id) }
        requestFocus()
        return id
    }

    /// Its text rather than what it renders to: a page that came from a link isn't run, and a Markdown file
    /// opened for typing in, like Claude Code's prompt, can be typed in.
    func showAsText(_ id: ItemID) {
        if let markdown = existingController(for: id) as? MarkdownController {
            if !markdown.showingSource { markdown.toggleSource() }
            return
        }
        guard existingController(for: id) == nil else { return }
        func asText(_ item: inout Item) {
            guard case .file(var spec) = item.content else { return }
            spec.showSource = true
            // Tiri's own viewer, not a plugin's, which might render it after all.
            spec.viewer = "text"
            item.content = .file(spec)
        }
        updateWorkspace(containing: id) { workspace in
            if workspace.peek?.id == id { asText(&workspace.peek!) } else { workspace.updateItem(id, asText) }
        }
    }

    /// A `tiri://` link. Any web page can make one, so it only ever shows a file: a folder isn't opened as a
    /// workspace, and a page is shown as its text, since running it would let it read the files beside it.
    func openLink(_ url: URL) {
        guard let link = FileLink(url) else {
            showToast(title: String(localized: "Tiri can't open this link"), detail: url.absoluteString, symbol: "link", tint: .orange)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory) else {
            showToast(title: String(localized: "No such file"), detail: link.path, symbol: "questionmark.folder", tint: .orange)
            return
        }
        guard !isDirectory.boolValue else {
            showToast(title: String(localized: "Links open files, not folders"), detail: link.path, symbol: "folder", tint: .orange)
            return
        }
        // Not a device or a pipe, which a link could name to hang the reader.
        guard (try? FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeRegular else {
            showToast(title: String(localized: "No such file"), detail: link.path, symbol: "questionmark.folder", tint: .orange)
            return
        }
        // Outside your workspaces, a link's file doesn't start a language server by itself: some, like rust-analyzer,
        // run code from the project around it, and a web page shouldn't get to choose that project.
        if workspaces.allSatisfy({ $0.folder(containing: aliasedPath(link.path, in: $0.id)) == nil }) {
            linkOnlyFiles.insert(Git.real(link.path))
        }
        openFromOutside(link.path, line: link.line, col: link.col, asSource: Self.runsAsPage(link.path))
    }

    /// Files Tiri would run as a web page.
    static func runsAsPage(_ path: String) -> Bool {
        ["html", "htm", "xhtml", "shtml"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Something waits for this file back. A Peek is held, so nothing else replaces or drops it; a tab is kept,
    /// so a preview opened next doesn't take its place. Nobody at the terminal that asked: it says it needs them.
    func beginWaiting(on id: ItemID, from source: ItemID?, seen: Bool) {
        waitingFor.insert(id)
        showAsText(id)
        updateWorkspace(containing: id) { workspace in
            if workspace.peek?.id == id { workspace.heldPeek = id } else { workspace.pin(id) }
        }
        if !seen, let source, let item = anyItem(id) {
            setStatus(source, .needsInput, message: String(localized: "Waiting for you to finish \(title(for: item))"))
        }
    }

    /// Whether someone is at this terminal: Tiri in front, and it the item they're in.
    func isAtTerminal(_ id: ItemID) -> Bool {
        if isLookingAt(id) { return true }
        // A hidden test copy is never in front, so it's told to act as if someone were looking.
        return Self.isTestCopy && ProcessInfo.processInfo.environment["TIRI_DEV_LOOKING"] != nil && active.focused.active == id
    }

    /// Done with a file something is waiting on: saved if it needs to be, then closed, which hands it back.
    func finishWaiting(_ id: ItemID) {
        let close = { [weak self] in
            guard let self else { return }
            if self.active.peek?.id == id { self.dismissPeek() } else { self.requestClose(id) }
        }
        if let controller = existingController(for: id), controller.isDirty {
            save(controller, then: close)
        } else {
            close()
        }
    }
}
