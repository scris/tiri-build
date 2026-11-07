import AppKit
import TiriCore

/// Files coming into the explorer, as in VS Code: copied in Finder and pasted on a folder, or dropped
/// on one. Either way they're copies, and a name that's taken gets " copy". ⌘C in the explorer puts
/// the files themselves on the clipboard, for Finder or another folder here.
extension FileTreeController {
    /// A test copy keeps to a pasteboard of its own, so a check never touches what someone copied.
    static let pasteboard: NSPasteboard = AppModel.isTestCopy ? NSPasteboard(name: NSPasteboard.Name("app.tiri.test.files")) : .general

    var hasFilesToPaste: Bool {
        Self.pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func copySelectedFiles() {
        let nodes = selectedNodes().filter { !$0.isRoot && $0.pendingCreation == nil }.map(tail)
        guard !nodes.isEmpty else { return }
        Self.pasteboard.clearContents()
        Self.pasteboard.writeObjects(nodes.map { URL(fileURLWithPath: $0.path) as NSURL })
    }

    /// Into the folder, or the folder a file is in, or the first root with nothing chosen.
    func pasteFiles(into node: FileNode?) {
        let urls = Self.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, var folder = targetDirectory(for: node.map(tail)).map(tail) else { return }
        // A folder pasted with itself selected goes beside it, as a copy, as VS Code does.
        let here = (folder.path as NSString).standardizingPath
        if urls.contains(where: { ($0.path as NSString).standardizingPath == here }), let parent = folder.parent { folder = parent }
        receive(urls.map(\.path), into: folder)
    }

    /// Where a drop on this row goes: a folder takes it, a file's folder takes it for the file.
    func dropFolder(for item: Any?) -> FileNode? {
        guard let node = item as? FileNode else { return roots.count == 1 ? roots[0] : nil }
        let deepest = tail(of: node)
        return deepest.isDirectory ? deepest : deepest.parent
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Rows dragged inside the explorer go to terminals and agents. Moving them about isn't this.
        guard (info.draggingSource as? NSView) !== outline, let folder = dropFolder(for: item) else { return [] }
        // The whole folder lights up, wherever in it the pointer is.
        outlineView.setDropItem(head(of: folder), dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let folder = dropFolder(for: item) else { return false }
        receive(urls.map(\.path), into: folder)
        return true
    }

    /// Into a folder on a server: what's on this Mac goes over the connection, packed with tar so a folder
    /// keeps its contents and modes, and what's already on that server is copied there. Names are checked
    /// on the server. Returns the copies as this Mac's paths for them, as the tree shows them.
    nonisolated static func send(_ paths: [String], into folder: String, on connection: RemoteConnection) -> (copied: [String], problems: [FileCopying.Problem]) {
        guard let target = connection.map.remote(folder) else { return ([], [.failed((folder as NSString).lastPathComponent, String(localized: "Not connected."))]) }
        var copied: [String] = []
        var problems: [FileCopying.Problem] = []
        var taken = Set((connection.run("ls -A -- \(ShellQuote.quote(target))")?.text ?? "").split(separator: "\n").map(String.init))
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let free = FileCopying.freeName(for: name) { taken.contains($0) }
            let into = target + "/" + free
            let script: String
            var data: Data?
            if let source = connection.map.remote(path) {
                guard target != source, !target.hasPrefix(source + "/") else {
                    problems.append(.intoItself(name))
                    continue
                }
                script = "cp -R -- \(ShellQuote.quote(source)) \(ShellQuote.quote(into))"
            } else if RemoteRegistry.shared.connection(forLocal: path) != nil {
                problems.append(.failed(name, String(localized: "It's on another server.")))
                continue
            } else {
                guard let packed = pack(path) else {
                    problems.append(.failed(name, String(localized: "It couldn't be read.")))
                    continue
                }
                data = packed
                // Unpacked beside where it goes, then renamed, so a half-sent copy never has its name.
                let quoted = ShellQuote.quote(target)
                script = "set -e; tmp=$(mktemp -d \(quoted)/.tiri-paste.XXXXXX); trap 'rm -rf \"$tmp\"' EXIT; tar -C \"$tmp\" -xf - 2>/dev/null; mv -- \"$tmp\"/\(ShellQuote.quote(name)) \(ShellQuote.quote(into))"
            }
            guard let result = connection.run(script, stdin: data, timeout: 600), result.succeeded else {
                problems.append(.failed(name, String(localized: "The connection dropped, or the server said no.")))
                continue
            }
            taken.insert(free)
            connection.refresh([into])
            copied.append((folder as NSString).appendingPathComponent(free))
        }
        return (copied, problems)
    }

    /// A file or folder as tar, without the Mac's own extras, which a Linux tar would only complain about.
    nonisolated private static func pack(_ path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--no-mac-metadata", "--no-xattrs", "--no-acls", "-C", (path as NSString).deletingLastPathComponent, "-cf", "-", (path as NSString).lastPathComponent]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// A drop of what's on the test pasteboard on the row showing this path, through the same two
    /// questions AppKit asks of a real one. What it says is what the pointer would have shown.
    func dropForTest(on path: String?) -> String {
        let drag = TestDrag(pasteboard: Self.pasteboard)
        var row: Any? = nil
        if let path {
            reveal(path: path, expand: false, quiet: true)
            row = selectedNodes().first.map(head)
        }
        let operation = outlineView(outline, validateDrop: drag, proposedItem: row, proposedChildIndex: NSOutlineViewDropOnItemIndex)
        guard operation == .copy else { return "refused" }
        return outlineView(outline, acceptDrop: drag, item: row, childIndex: NSOutlineViewDropOnItemIndex) ? "copied" : "refused"
    }

    /// Copies them in away from the main thread, then shows and selects what arrived.
    func receive(_ paths: [String], into folder: FileNode) {
        guard !paths.isEmpty else { return }
        let destination = folder.path
        let connection = RemoteRegistry.shared.connection(forLocal: destination)
        if let connection {
            let host = SSHConfigFile.displayName(of: connection.destination)
            let sending = paths.count == 1 ? String(localized: "Sending \((paths[0] as NSString).lastPathComponent) to \(host)") : String(localized: "Sending \(paths.count) files to \(host)")
            model?.showToast(title: sending, detail: nil, symbol: "arrow.up.circle", tint: .secondary)
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                connection.map { Self.send(paths, into: destination, on: $0) } ?? FileCopying.copy(paths, into: destination)
            }.value
            guard let self else { return }
            if let problem = result.problems.first {
                let title = result.problems.count == 1 ? String(localized: "Couldn't copy that here") : String(localized: "Couldn't copy \(result.problems.count) of those here")
                self.model?.showToast(title: title, detail: problem.description, symbol: "exclamationmark.triangle", tint: .orange)
            }
            guard !result.copied.isEmpty else { return }
            self.refreshNow(folder)
            self.outline.expandItem(self.head(of: folder))
            for path in result.copied { self.reveal(path: path, expand: false, quiet: true) }
            self.select(paths: result.copied)
        }
    }
}

/// What a drag from another app looks like to the explorer, for a test copy, which can't be dragged onto.
private final class TestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
