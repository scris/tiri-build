import AppKit
import SwiftUI
import TiriCore

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
        outline.autoresizesOutlineColumn = true
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
        for child in children(of: node) where child.isDirectory {
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
        outline.reloadItem(node, reloadChildren: true)
        restoringExpansion = true
        for child in node.children ?? [] where child.isDirectory && expanded.contains(child.path) {
            restoreExpansion(child)
        }
        restoringExpansion = false
        select(paths: selection)
    }

    // MARK: Selection and reveal

    private func selectedNodes() -> [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    private func selectedPaths() -> [String] { selectedNodes().map(\.path) }

    private func select(paths: [String]) {
        var rows = IndexSet()
        for path in paths {
            if let node = findLoaded(path) {
                let row = outline.row(forItem: node)
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
            if node.path != path, !outline.isItemExpanded(node) { outline.expandItem(node) }
        }
        if expand, node.isDirectory { outline.expandItem(node) }
        let row = outline.row(forItem: node)
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
            return String(repeating: "  ", count: outline.level(forRow: row)) + node.name + (node.isDirectory ? "/" : "")
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
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            model?.openFromTree(path: node.path, pin: pin)
            if !pin { outline.window?.makeFirstResponder(outline) }
        }
    }

    func renameSelected() {
        guard let node = selectedNodes().first, !node.isRoot else { return }
        beginEditing(node)
    }

    func trashSelected() {
        let nodes = selectedNodes().filter { !$0.isRoot }
        guard !nodes.isEmpty, let window = outline.window else { return }
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
        guard let directory = targetDirectory(for: target) else { return }
        outline.expandItem(directory)
        expanded.insert(directory.path)
        let pending = FileNode(path: directory.path + "/", name: "", isDirectory: kind == .folder, parent: directory)
        pending.pendingCreation = kind
        var list = children(of: directory)
        let index = kind == .folder ? 0 : (list.firstIndex { !$0.isDirectory } ?? list.count)
        list.insert(pending, at: index)
        directory.children = list
        outline.insertItems(at: IndexSet(integer: index), inParent: directory, withAnimation: [])
        beginEditing(pending)
    }

    private func beginEditing(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        editingNode = node
        cancelEdit = false
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
            if let parent { outline.reloadItem(parent, reloadChildren: true) }
            guard !cancelled, !name.isEmpty, let parent else { return }
            create(kind, name: name, in: parent)
            return
        }
        guard !cancelled, !name.isEmpty, name != node.name else {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
            return
        }
        let destination = ((node.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(atPath: node.path, toPath: destination)
            model?.fileRenamed(from: node.path, to: destination)
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
        let node = row >= 0 ? outline.item(atRow: row) as? FileNode : nil
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

    @objc private func menuOpenExternal(_ sender: NSMenuItem) {
        if let node = menuNode(sender) { model?.openExternally(path: node.path) }
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let node = menuNode(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
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
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.pendingCreation == nil else { return nil }
        return URL(fileURLWithPath: node.path) as NSURL
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoringExpansion, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expanded.insert(node.path)
        saveExpansion()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoringExpansion, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expanded.remove(node.path)
        saveExpansion()
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? FileNode)?.isRoot == true ? 26 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.isRoot ? "root" : "row")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? makeCell(identifier: identifier, isRoot: node.isRoot)
        let field = cell.textField
        field?.stringValue = node.isRoot ? node.name.uppercased() : node.name
        if node.isRoot {
            cell.imageView?.image = nil
        } else {
            cell.imageView?.image = FileIcons.image(forName: node.name, isDirectory: node.isDirectory)
            cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, isRoot: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = isRoot ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
        field.textColor = isRoot ? .secondaryLabelColor : .labelColor
        field.cell?.isScrollable = true
        cell.addSubview(field)
        cell.textField = field
        if isRoot {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
