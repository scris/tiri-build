import AppKit
import SwiftUI
import TiriCore

/// A row of the explorer, which can say the file has changed.
final class FileTreeCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    /// What the name is tinted, unless the row is selected.
    var tint: NSColor? { didSet { applyColors() } }
    var plainColor: NSColor = .labelColor { didSet { applyColors() } }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        // On a selection's color, a tint is hard to read.
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .alternateSelectedControlTextColor : (tint ?? plainColor)
        badge.textColor = selected ? .alternateSelectedControlTextColor : (tint ?? plainColor)
    }

    /// `letter` for a file, and a dot for a folder with something changed under it.
    func showMark(_ text: String, tint: NSColor?) {
        badge.stringValue = text
        badge.font = text == "●" ? .systemFont(ofSize: 7) : .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        self.tint = tint
    }
}

enum ChangeTint {
    /// Cursor's colors. Text in them needs to stay readable in light and dark.
    static func color(_ status: ChangeStatus) -> NSColor {
        switch status {
        case .modified: dynamic(dark: (0.89, 0.75, 0.55), light: (0.54, 0.33, 0.01))
        case .added, .untracked, .renamed: dynamic(dark: (0.45, 0.79, 0.57), light: (0.30, 0.50, 0.05))
        case .deleted: dynamic(dark: (0.85, 0.42, 0.34), light: (0.68, 0.20, 0.12))
        case .conflicted: dynamic(dark: (0.89, 0.40, 0.42), light: (0.68, 0.10, 0.20))
        }
    }

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }

    /// Which color a folder takes, with several kinds of change under it.
    static func rank(_ status: ChangeStatus) -> Int {
        switch status {
        case .conflicted: 3
        case .modified: 2
        case .deleted: 1
        case .added, .untracked, .renamed: 0
        }
    }
}

final class FileNode: NSObject {
    let path: String
    var name: String
    let isDirectory: Bool
    let isRoot: Bool
    weak var parent: FileNode?
    var children: [FileNode]?
    /// A row that exists only while its name is being typed.
    var pendingCreation: PendingKind?

    enum PendingKind { case file, folder }

    init(path: String, name: String, isDirectory: Bool, isRoot: Bool = false, parent: FileNode? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isRoot = isRoot
        self.parent = parent
    }
}

/// Explorer keys, as in Cursor on macOS: Enter renames, ⌘↓ opens, Space previews, ⌘⌫ trashes.
final class TreeOutlineView: NSOutlineView {
    weak var tree: FileTreeController?

    override func keyDown(with event: NSEvent) {
        // Only the modifiers a person holds: arrow keys also carry numericPad and function.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 36, 76 where flags.isEmpty:
            tree?.renameSelected()
        case 125 where flags == .command:
            tree?.openSelected(pin: true)
        case 49 where flags.isEmpty:
            tree?.openSelected(pin: false)
        case 51 where flags == .command:
            tree?.trashSelected()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return tree?.contextMenu(forRow: row)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row)
    }
}

final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    weak var model: AppModel?
    let scrollView = NSScrollView()
    let outline = TreeOutlineView()
    private var roots: [FileNode] = []
    private var workspaceID: WorkspaceID?
    private var expanded: Set<String> = []
    private var excludes = ExcludeMatcher(patterns: [])
    private let fileSystem: FileSystemProviding = LocalFileSystem()
    private var editingNode: FileNode?
    private var cancelEdit = false
    private var restoringExpansion = false
    /// What's changed, from the list the Changes section already has: no git for any row.
    private var fileChanges: [String: ChangeStatus] = [:]
    /// Each folder with something changed under it, and what to tint it.
    private var folderChanges: [String: ChangeStatus] = [:]

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.tree = self
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 12
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([.copy], forLocal: true)
        // Growing it to fit an expanded row scrolled the whole tree sideways.
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    // MARK: Binding

    /// Show nothing, for now, without forgetting what was open.
    func clear() {
        saveExpansion()
        workspaceID = nil
        roots = []
        outline.reloadData()
    }

    func bind(_ workspace: Workspace) {
        // Leaving a workspace remembers what was open in it.
        saveExpansion()
        workspaceID = workspace.id
        excludes = ExcludeMatcher(patterns: model?.settings.filesExclude ?? [])
        expanded = Set(workspace.expandedFolders)
        // A folder with no expansion state starts open: its root is the first thing you want to see.
        for folder in workspace.folders where workspace.expandedFolders.isEmpty {
            expanded.insert(folder)
        }
        roots = workspace.folders.map { path in
            FileNode(path: path, name: (path as NSString).lastPathComponent, isDirectory: true, isRoot: true)
        }
        outline.reloadData()
        restoreExpansion()
    }

    private func saveExpansion() {
        guard let workspaceID, let model,
              let index = model.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let list = expanded.sorted()
        if model.workspaces[index].expandedFolders != list {
            model.workspaces[index].expandedFolders = list
            model.scheduleSave()
        }
    }

    private func restoreExpansion() {
        restoringExpansion = true
        defer { restoringExpansion = false }
        for root in roots { restoreExpansion(root) }
    }

    private func restoreExpansion(_ node: FileNode) {
        guard expanded.contains(node.path) else { return }
        outline.expandItem(node)
        for child in displayedChildren(of: node) where child.isDirectory {
            restoreExpansion(child)
        }
    }

    // MARK: Children

    private func children(of node: FileNode) -> [FileNode] {
        if let children = node.children { return children }
        let entries = (try? fileSystem.list(directory: node.path, excludes: excludes)) ?? []
        let children = entries.map { FileNode(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, parent: node) }
        node.children = children
        return children
    }

    // MARK: What's changed

    func changesUpdated(_ changes: [ChangedFile]) {
        var files: [String: ChangeStatus] = [:]
        var folders: [String: ChangeStatus] = [:]
        for change in changes {
            if change.status != .deleted { files[change.path] = change.status }
            var folder = (change.path as NSString).deletingLastPathComponent
            while folder.count > 1 {
                if let known = folders[folder], ChangeTint.rank(known) >= ChangeTint.rank(change.status) { break }
                folders[folder] = change.status
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        guard files != fileChanges || folders != folderChanges else { return }
        let (oldFiles, oldFolders) = (fileChanges, folderChanges)
        fileChanges = files
        folderChanges = folders
        // Rows out of sight pick theirs up as they come into view.
        let visible = outline.rows(in: outline.visibleRect)
        var rows = IndexSet()
        for row in visible.lowerBound..<NSMaxRange(visible) {
            guard let node = outline.item(atRow: row) as? FileNode, node !== editingNode else { continue }
            if node.isDirectory ? oldFolders[node.path] != folders[node.path] : oldFiles[node.path] != files[node.path] { rows.insert(row) }
        }
        if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
    }

    // MARK: Compact folders

    // A folder that only holds another folder shares a row with it. The tree of nodes stays as it
    // is on disk. The outline's rows are "heads", and a row shows and acts on its "tail", the
    // deepest folder in the run. A run only grows as far as what's been read, so a collapsed
    // folder isn't listed just to name its row: expanding it finds out, as in VS Code.

    private var compacts: Bool { model?.settings.explorerCompactFolders ?? false }

    /// A folder's only child, if that child can share its row.
    private func compactChild(of node: FileNode) -> FileNode? {
        guard let children = node.children, children.count == 1, let only = children.first,
              only.isDirectory, only.pendingCreation == nil else { return nil }
        return only
    }

    /// The deepest folder on this node's row.
    private func tail(of node: FileNode) -> FileNode {
        guard compacts, node.isDirectory, !node.isRoot, node.pendingCreation == nil else { return node }
        var current = node
        // Links can loop, and a run has to end somewhere.
        for _ in 0..<64 {
            guard let next = compactChild(of: current) else { break }
            current = next
        }
        return current
    }

    /// The row this node is on.
    private func head(of node: FileNode) -> FileNode {
        guard compacts, node.isDirectory else { return node }
        var current = node
        for _ in 0..<64 {
            guard let parent = current.parent, !parent.isRoot, compactChild(of: parent) === current else { break }
            current = parent
        }
        return current
    }

    private func run(from head: FileNode) -> [FileNode] {
        var list = [head]
        guard compacts, !head.isRoot, head.isDirectory else { return list }
        var current = head
        for _ in 0..<64 {
            guard let next = compactChild(of: current) else { break }
            list.append(next)
            current = next
        }
        return list
    }

    /// What shows under a row. Reading it can make the run longer.
    private func displayedChildren(of node: FileNode) -> [FileNode] {
        guard compacts, !node.isRoot else { return children(of: node) }
        var current = node
        var list = children(of: current)
        for _ in 0..<64 {
            guard list.count == 1, list[0].isDirectory, list[0].pendingCreation == nil else { break }
            current = list[0]
            list = children(of: current)
        }
        return list
    }

    private func rowName(_ node: FileNode) -> String {
        run(from: node).map(\.name).joined(separator: "/")
    }

    private func refreshRowLabel(_ head: FileNode) {
        let row = outline.row(forItem: head)
        if row >= 0 { outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
    }

    // MARK: Live updates

    func filesChanged(_ paths: [String]) {
        var directories: Set<String> = []
        for path in paths {
            directories.insert((path as NSString).deletingLastPathComponent)
            // A created or removed folder also means its own contents changed.
            directories.insert(path)
        }
        for directory in directories {
            if let node = findLoaded(directory), node.children != nil {
                refresh(node)
            }
        }
    }

    /// Everything that's showing, read again. For when the local copy of a server just changed.
    func reload() {
        func walk(_ node: FileNode) {
            guard node.children != nil else { return }
            refresh(node)
            node.children?.forEach(walk)
        }
        roots.forEach(walk)
    }

    private func findLoaded(_ path: String) -> FileNode? {
        for root in roots where path == root.path || path.hasPrefix(root.path + "/") {
            var node = root
            if path == root.path { return root }
            let components = path.dropFirst(root.path.count + 1).split(separator: "/")
            var failed = false
            for component in components {
                guard let next = node.children?.first(where: { $0.name == component }) else {
                    failed = true
                    break
                }
                node = next
            }
            if !failed { return node }
        }
        return nil
    }

    private func refresh(_ node: FileNode) {
        guard editingNode == nil else { return }
        guard FileManager.default.fileExists(atPath: node.path) else { return }
        let entries = (try? fileSystem.list(directory: node.path, excludes: excludes)) ?? []
        let old = node.children ?? []
        if old.map(\.path) == entries.map(\.path) { return }
        let byPath = Dictionary(old.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let selection = selectedPaths()
        // Keep the node objects that survive, so their expansion and scroll stay put.
        node.children = entries.map { entry in
            if let existing = byPath[entry.path], existing.isDirectory == entry.isDirectory { return existing }
            return FileNode(path: entry.path, name: entry.name, isDirectory: entry.isDirectory, parent: node)
        }
        // A folder gaining or losing a sibling can join or leave a row, so its whole row reloads.
        let row = head(of: node)
        outline.reloadItem(row, reloadChildren: true)
        restoringExpansion = true
        if outline.isItemExpanded(row) {
            for child in displayedChildren(of: row) where child.isDirectory && expanded.contains(child.path) {
                restoreExpansion(child)
            }
        }
        restoringExpansion = false
        select(paths: selection)
    }

    // MARK: Selection and reveal

    /// What selected rows act on: on a compact row, its deepest folder.
    private func selectedNodes() -> [FileNode] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode).map(tail) }
    }

    private func selectedPaths() -> [String] { selectedNodes().map(\.path) }

    private func select(paths: [String]) {
        var rows = IndexSet()
        for path in paths {
            if let node = findLoaded(path) {
                let row = outline.row(forItem: head(of: node))
                if row >= 0 { rows.insert(row) }
            }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Walk down from the root, expanding as needed. `quiet` is auto-reveal: it doesn't
    /// expand anything that would surprise you or take focus.
    func reveal(path: String, expand: Bool, quiet: Bool = false) {
        guard let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return }
        var node = root
        if !outline.isItemExpanded(root) { outline.expandItem(root) }
        let components = path.dropFirst(root.path.count).split(separator: "/")
        for component in components {
            guard let next = children(of: node).first(where: { $0.name == component }) else { return }
            node = next
            if node.path != path, !outline.isItemExpanded(head(of: node)) { outline.expandItem(head(of: node)) }
        }
        if expand, node.isDirectory { outline.expandItem(head(of: node)) }
        // Reading on the way down can have made its row's run longer.
        refreshRowLabel(head(of: node))
        let row = outline.row(forItem: head(of: node))
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        if !quiet { flash(row: row) }
    }

    private func flash(row: Int) {
        guard let view = outline.rowView(atRow: row, makeIfNecessary: false) else { return }
        view.wantsLayer = true
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.3
        animation.toValue = 1
        animation.duration = 0.35
        view.layer?.add(animation, forKey: "reveal")
    }

    func focus() {
        outline.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Visible rows as indented text, so tests and agents can read the tree.
    func visibleRows() -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? FileNode else { return nil }
            return String(repeating: "  ", count: outline.level(forRow: row)) + rowName(node) + (node.isDirectory ? "/" : "")
        }
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, editingNode == nil else { return }
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            model?.openFromTree(path: node.path, pin: false)
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, !node.isDirectory else { return }
        model?.openFromTree(path: node.path, pin: true)
    }

    func openSelected(pin: Bool) {
        guard let node = selectedNodes().first else { return }
        if node.isDirectory {
            let row = head(of: node)
            if outline.isItemExpanded(row) { outline.collapseItem(row) } else { outline.expandItem(row) }
        } else {
            model?.openFromTree(path: node.path, pin: pin)
            if !pin { outline.window?.makeFirstResponder(outline) }
        }
    }

    /// A server has no Trash to move things to, so this says what it really does.
    private func confirmDeleteOnServer(_ nodes: [FileNode], connection: RemoteConnection, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = nodes.count == 1
            ? "Delete \u{201C}\(nodes[0].name)\u{201D} from \(SSHConfigFile.displayName(of: connection.destination))?"
            : "Delete \(nodes.count) items from \(SSHConfigFile.displayName(of: connection.destination))?"
        alert.informativeText = "A server has no Trash, so this can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let model = self?.model else { return }
                let remotes = nodes.compactMap { connection.map.remote($0.path) }
                model.remote.perform("rm -rf -- \(RemoteShell.arguments(remotes))", affecting: remotes, on: connection,
                                     failure: "Couldn't delete \(nodes.count == 1 ? nodes[0].name : "those")")
            }
        }
    }

    func renameSelected() {
        guard let node = selectedNodes().first, !node.isRoot else { return }
        beginEditing(node)
    }

    func trashSelected() {
        let nodes = selectedNodes().filter { !$0.isRoot }
        guard !nodes.isEmpty, let window = outline.window else { return }
        if let connection = RemoteRegistry.shared.connection(forLocal: nodes[0].path) {
            confirmDeleteOnServer(nodes, connection: connection, window: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = nodes.count == 1
            ? "Are you sure you want to delete \u{201C}\(nodes[0].name)\u{201D}?"
            : "Are you sure you want to delete \(nodes.count) items?"
        alert.informativeText = "You can restore from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                for node in nodes {
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
                    } catch {
                        self?.model?.showToast(title: "Couldn't move \(node.name) to the Trash", detail: error.localizedDescription,
                                               symbol: "exclamationmark.triangle", tint: .orange)
                    }
                }
            }
        }
    }

    // MARK: Inline editing

    private func targetDirectory(for node: FileNode?) -> FileNode? {
        guard let node else { return roots.first }
        return node.isDirectory ? node : (node.parent ?? roots.first)
    }

    func beginCreating(_ kind: FileNode.PendingKind, in target: FileNode?) {
        guard let target = targetDirectory(for: target) else { return }
        let row = head(of: target)
        outline.expandItem(row)
        // Expanding can show that the row's run goes further down, and the new item goes at its end.
        let directory = tail(of: row)
        for part in run(from: row) { expanded.insert(part.path) }
        let pending = FileNode(path: directory.path + "/", name: "", isDirectory: kind == .folder, parent: directory)
        pending.pendingCreation = kind
        var list = children(of: directory)
        let index = kind == .folder ? 0 : (list.firstIndex { !$0.isDirectory } ?? list.count)
        list.insert(pending, at: index)
        directory.children = list
        outline.insertItems(at: IndexSet(integer: index), inParent: row, withAnimation: [])
        beginEditing(pending)
    }

    private func beginEditing(_ node: FileNode) {
        let row = outline.row(forItem: head(of: node))
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        editingNode = node
        cancelEdit = false
        // On a compact row, it's the deepest folder's name being changed.
        field.stringValue = node.name
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // A scrolling field doesn't truncate, so only while it's being typed in.
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        outline.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            // Rename selects the base name, as in Cursor.
            let name = node.name as NSString
            let base = (node.name as NSString).deletingPathExtension as NSString
            editor.selectedRange = node.isDirectory ? NSRange(location: 0, length: name.length)
                                                    : NSRange(location: 0, length: base.length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEdit = true
            outline.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = editingNode else { return }
        editingNode = nil
        field.cell?.isScrollable = false
        field.lineBreakMode = .byTruncatingMiddle
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        commit(node, name: name, cancelled: cancelEdit)
        outline.window?.makeFirstResponder(outline)
    }

    private func commit(_ node: FileNode, name: String, cancelled: Bool) {
        if let kind = node.pendingCreation {
            let parent = node.parent
            parent?.children?.removeAll { $0 === node }
            if let parent { outline.reloadItem(head(of: parent), reloadChildren: true) }
            guard !cancelled, !name.isEmpty, let parent else { return }
            create(kind, name: name, in: parent)
            return
        }
        guard !cancelled, !name.isEmpty, name != node.name else {
            refreshRowLabel(head(of: node))
            return
        }
        let destination = ((node.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        if let connection = RemoteRegistry.shared.connection(forLocal: node.path), let from = connection.map.remote(node.path), let to = connection.map.remote(destination) {
            let model = model
            let oldPath = node.path
            Task.detached(priority: .userInitiated) {
                let result = connection.perform("mv -- \(ShellQuote.quote(from)) \(ShellQuote.quote(to))", affecting: [from, to])
                await MainActor.run {
                    switch result {
                    case .success:
                        model?.fileRenamed(from: oldPath, to: destination)
                    case .failure(let failure):
                        model?.showToast(title: "Couldn't rename \((oldPath as NSString).lastPathComponent)", detail: failure.description, symbol: "exclamationmark.triangle", tint: .orange)
                    }
                    model?.fileTree.reload()
                }
            }
            return
        }
        do {
            try FileManager.default.moveItem(atPath: node.path, toPath: destination)
            model?.fileRenamed(from: node.path, to: destination)
            // A renamed folder stays as open as it was.
            let moved = expanded.filter { $0 == node.path || $0.hasPrefix(node.path + "/") }
            expanded.subtract(moved)
            expanded.formUnion(moved.map { destination + $0.dropFirst(node.path.count) })
        } catch {
            model?.showToast(title: "Couldn't rename \(node.name)", detail: error.localizedDescription,
                             symbol: "exclamationmark.triangle", tint: .orange)
        }
        if let parent = node.parent { refresh(parent) }
    }

    private func create(_ kind: FileNode.PendingKind, name: String, in parent: FileNode) {
        let path = (parent.path as NSString).appendingPathComponent(name)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: path) else {
            model?.showToast(title: "\(name) already exists", detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        if let connection = RemoteRegistry.shared.connection(forLocal: path), let remote = connection.map.remote(path) {
            let quoted = ShellQuote.quote(remote)
            let parentFolder = ShellQuote.quote((remote as NSString).deletingLastPathComponent)
            let script = kind == .folder ? "mkdir -p -- \(quoted)" : "mkdir -p -- \(parentFolder) && : >> \(quoted)"
            let model = model
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = connection.perform(script, affecting: [remote])
                await MainActor.run {
                    if case .failure(let failure) = result {
                        model?.showToast(title: "Couldn't create \(name)", detail: failure.description, symbol: "exclamationmark.triangle", tint: .orange)
                        return
                    }
                    self?.refresh(parent)
                    self?.reveal(path: path, expand: false, quiet: true)
                    if kind == .file { model?.openFromTree(path: path, pin: true) }
                }
            }
            return
        }
        do {
            switch kind {
            case .folder:
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            case .file:
                // `a/b.txt` creates the folder too.
                try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard manager.createFile(atPath: path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
            }
        } catch {
            model?.showToast(title: "Couldn't create \(name)", detail: error.localizedDescription,
                             symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        refresh(parent)
        reveal(path: path, expand: false, quiet: true)
        if kind == .file { model?.openFromTree(path: path, pin: true) }
    }

    // MARK: Context menu

    func contextMenu(forRow row: Int) -> NSMenu? {
        let node = row >= 0 ? (outline.item(atRow: row) as? FileNode).map(tail) : nil
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        add("New File…", #selector(menuNewFile))
        add("New Folder…", #selector(menuNewFolder))
        if node != nil {
            menu.addItem(.separator())
            add("Reveal in Finder", #selector(menuRevealInFinder))
            add("Open in Integrated Terminal", #selector(menuOpenTerminal))
            add("Add to Agent", #selector(menuAddToAgent), key: "l", modifiers: [.command])
            if node?.isDirectory == false { add("Open in External Editor", #selector(menuOpenExternal)) }
            menu.addItem(.separator())
            add("Copy Path", #selector(menuCopyPath), key: "c", modifiers: [.option, .command])
            add("Copy Relative Path", #selector(menuCopyRelativePath), key: "c", modifiers: [.option, .shift, .command])
            if node?.isRoot == false {
                menu.addItem(.separator())
                add("Rename", #selector(menuRename), key: "\r", modifiers: [])
                let delete = NSMenuItem(title: "Delete", action: #selector(menuDelete), keyEquivalent: "\u{8}")
                delete.keyEquivalentModifierMask = .command
                delete.target = self
                menu.addItem(delete)
            }
        }
        menu.addItem(.separator())
        add("Add Folder to Workspace…", #selector(menuAddFolder))
        if node?.isRoot == true { add("Remove Folder from Workspace", #selector(menuRemoveFolder)) }
        return menu
    }

    private func menuNode(_ sender: NSMenuItem) -> FileNode? { sender.representedObject as? FileNode }

    @objc private func menuNewFile(_ sender: NSMenuItem) { beginCreating(.file, in: menuNode(sender)) }
    @objc private func menuNewFolder(_ sender: NSMenuItem) { beginCreating(.folder, in: menuNode(sender)) }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        guard let node = menuNode(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    @objc private func menuOpenTerminal(_ sender: NSMenuItem) {
        guard let node = menuNode(sender) else { return }
        let directory = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        model?.newTerminal(cwd: directory)
    }

    @objc private func menuAddToAgent(_ sender: NSMenuItem) {
        guard let node = menuNode(sender) else { return }
        // Several selected rows, if the one clicked is among them.
        let selected = selectedPaths()
        model?.addFilesToAgent(selected.contains(node.path) ? selected : [node.path])
    }

    @objc private func menuOpenExternal(_ sender: NSMenuItem) {
        if let node = menuNode(sender) { model?.openExternally(path: node.path) }
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let node = menuNode(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RemoteRegistry.shared.displayPath(node.path), forType: .string)
    }

    @objc private func menuCopyRelativePath(_ sender: NSMenuItem) {
        guard let node = menuNode(sender), let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.active.relativePath(node.path), forType: .string)
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        if let node = menuNode(sender) { beginEditing(node) }
    }

    @objc private func menuDelete(_ sender: NSMenuItem) { trashSelected() }
    @objc private func menuAddFolder(_ sender: NSMenuItem) { model?.addFolderInteractive() }

    @objc private func menuRemoveFolder(_ sender: NSMenuItem) {
        if let node = menuNode(sender) { model?.removeFolder(node.path) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        return displayedChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return displayedChildren(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.pendingCreation == nil else { return nil }
        return URL(fileURLWithPath: tail(of: node).path) as NSURL
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        refreshRowLabel(node)
        guard !restoringExpansion else { return }
        for part in run(from: node) { expanded.insert(part.path) }
        saveExpansion()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoringExpansion, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        for part in run(from: node) { expanded.remove(part.path) }
        saveExpansion()
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? FileNode)?.isRoot == true ? 26 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.isRoot ? "root" : "row")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileTreeCell) ?? makeCell(identifier: identifier, isRoot: node.isRoot)
        let field = cell.textField
        field?.stringValue = node.isRoot ? node.name.uppercased() : rowName(node)
        if node.isRoot {
            cell.imageView?.image = nil
        } else {
            cell.imageView?.image = FileIcons.image(forName: node.name, isDirectory: node.isDirectory)
            cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        }
        if node.isDirectory {
            let status = folderChanges[node.path]
            // A root row keeps its heading's color.
            cell.showMark(status == nil ? "" : "●", tint: node.isRoot ? nil : status.map(ChangeTint.color))
        } else {
            let status = fileChanges[node.path]
            cell.showMark(status?.letter ?? "", tint: status.map(ChangeTint.color))
            cell.badge.toolTip = status?.rawValue.capitalized
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, isRoot: Bool) -> FileTreeCell {
        let cell = FileTreeCell()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = isRoot ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
        cell.plainColor = isRoot ? .secondaryLabelColor : .labelColor
        cell.addSubview(field)
        cell.textField = field
        let badge = cell.badge
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        cell.addSubview(badge)
        if isRoot {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}

enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func symbolName(forName name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx", "txt", "rst": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp", "ico", "icns": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "waveform"
        case "pptx", "ppt", "key": return "rectangle.on.rectangle"
        case "docx", "doc", "pages", "rtf": return "doc.richtext"
        case "xlsx", "xls", "numbers", "csv", "tsv": return "tablecells"
        case "html", "htm": return "globe"
        case "json", "yaml", "yml", "toml", "plist", "xml", "ini", "conf", "env": return "curlybraces"
        case "zip", "tar", "gz", "tgz", "7z", "rar": return "doc.zipper"
        case "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "cc", "cpp", "h", "m", "mm", "java", "kt", "cs", "php", "sh", "zsh", "bash", "css", "scss", "sql":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    static func image(forName name: String, isDirectory: Bool) -> NSImage? {
        let symbol = symbolName(forName: name, isDirectory: isDirectory)
        if let cached = cache[symbol] { return cached }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cache[symbol] = image
        return image
    }
}

struct FileTreeRepresentable: NSViewRepresentable {
    let controller: FileTreeController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

extension AppModel {
    /// Open tabs follow a rename, staying where they are.
    func fileRenamed(from old: String, to new: String) {
        var changed: [ItemID] = []
        for index in workspaces.indices {
            changed += workspaces[index].retargetFiles(from: old, to: new)
        }
        // Their viewers still point at the old path, so they reopen on next display.
        for id in changed { discardController(id) }
        controllerRevision += 1
        scheduleSave()
    }
}
