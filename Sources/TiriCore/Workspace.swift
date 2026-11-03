import Foundation

// MARK: - Identifiers

public typealias ItemID = String
public typealias GroupID = String
public typealias WorkspaceID = String

public enum TiriID {
    /// Short ids: the agent has to type them, so they stay readable.
    public static func make(_ prefix: String) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var out = prefix + "-"
        for _ in 0..<6 { out.append(alphabet.randomElement()!) }
        return out
    }
}

// MARK: - Items: terminals, files and previews are peers

public struct TerminalSpec: Codable, Hashable, Sendable {
    /// nil or empty = the user's login shell.
    public var command: String?
    public var cwd: String
    public var title: String?
    /// The agent's own session id, reported by `tiri hook`. Lets a relaunch resume exactly
    /// this conversation; `--continue` would pick the latest in the folder, so two
    /// terminals in one folder would collide.
    public var sessionID: String?
    public init(command: String? = nil, cwd: String, title: String? = nil, sessionID: String? = nil) {
        self.command = command
        self.cwd = cwd
        self.title = title
        self.sessionID = sessionID
    }
    public var isShell: Bool { (command ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

public struct FileSpec: Codable, Hashable, Sendable {
    public var path: String
    public var line: Int?
    public var col: Int?
    public var showSource: Bool?
    public var forceDark: Bool?
    public init(path: String, line: Int? = nil, col: Int? = nil, showSource: Bool? = nil, forceDark: Bool? = nil) {
        self.path = path
        self.line = line
        self.col = col
        self.showSource = showSource
        self.forceDark = forceDark
    }
}

public struct WebSpec: Codable, Hashable, Sendable {
    public var url: String
    public var forceDark: Bool?
    public var title: String?
    public init(url: String, forceDark: Bool? = nil, title: String? = nil) {
        self.url = url
        self.forceDark = forceDark
        self.title = title
    }
}

public enum ItemContent: Codable, Hashable, Sendable {
    case terminal(TerminalSpec)
    case file(FileSpec)
    case web(WebSpec)
    case settings

    public var kindName: String {
        switch self {
        case .terminal: "terminal"
        case .file: "file"
        case .web: "web"
        case .settings: "settings"
        }
    }
}

public struct Item: Codable, Hashable, Identifiable, Sendable {
    public var id: ItemID
    public var content: ItemContent
    /// A preview tab: italic title, replaced by the next preview in its group.
    public var isPreview: Bool

    public init(id: ItemID = TiriID.make("i"), content: ItemContent, isPreview: Bool = false) {
        self.id = id
        self.content = content
        self.isPreview = isPreview
    }

    public var filePath: String? {
        if case .file(let spec) = content { return spec.path }
        return nil
    }

    public var defaultTitle: String {
        switch content {
        case .terminal(let spec):
            if let title = spec.title, !title.isEmpty { return title }
            if spec.isShell { return (spec.cwd as NSString).lastPathComponent }
            return spec.command ?? "terminal"
        case .file(let spec):
            return (spec.path as NSString).lastPathComponent
        case .web(let spec):
            if let title = spec.title, !title.isEmpty { return title }
            return URL(string: spec.url)?.host ?? spec.url
        case .settings:
            return "Settings"
        }
    }
}

// MARK: - Pane tree

public enum SplitAxis: String, Codable, Sendable {
    case horizontal  // children side by side
    case vertical    // children stacked
}

public enum SplitDirection: String, Codable, Sendable {
    case right, down, left, up

    public var axis: SplitAxis { (self == .right || self == .left) ? .horizontal : .vertical }
    public var isAfter: Bool { self == .right || self == .down }
}

public struct TabGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: GroupID
    public var tabs: [ItemID]
    public var active: ItemID? {
        didSet {
            guard let active else { return }
            mru.removeAll { $0 == active }
            mru.insert(active, at: 0)
        }
    }
    /// Most recently used first. Closing a tab returns to the one you came from, as in VS Code.
    public var mru: [ItemID]

    public init(id: GroupID = TiriID.make("g"), tabs: [ItemID] = [], active: ItemID? = nil) {
        self.id = id
        self.tabs = tabs
        self.active = active ?? tabs.first
        self.mru = (active ?? tabs.first).map { [$0] } ?? []
    }

    mutating func remove(_ id: ItemID) {
        tabs.removeAll { $0 == id }
        mru.removeAll { $0 == id }
        if active == id {
            active = mru.first(where: tabs.contains) ?? tabs.first
        }
    }
}

public struct PaneSplit: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var axis: SplitAxis
    public var children: [PaneNode]
    /// Same length as children, sums to 1.
    public var ratios: [Double]
    public init(id: String = TiriID.make("s"), axis: SplitAxis, children: [PaneNode], ratios: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.ratios = ratios ?? Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
    }
}

public indirect enum PaneNode: Codable, Hashable, Sendable {
    case group(TabGroup)
    case split(PaneSplit)

    /// Groups in reading order. This is what ⌘1…⌘9 index into.
    public var groups: [TabGroup] {
        switch self {
        case .group(let group): [group]
        case .split(let split): split.children.flatMap(\.groups)
        }
    }

    func mapGroup(_ id: GroupID, _ transform: (inout TabGroup) -> Void) -> PaneNode {
        switch self {
        case .group(var group):
            if group.id == id { transform(&group) }
            return .group(group)
        case .split(var split):
            split.children = split.children.map { $0.mapGroup(id, transform) }
            return .split(split)
        }
    }

    /// Replace a group leaf with an arbitrary node. Used to split it.
    func replacingGroup(_ id: GroupID, with make: (TabGroup) -> PaneNode) -> PaneNode {
        switch self {
        case .group(let group):
            return group.id == id ? make(group) : self
        case .split(var split):
            split.children = split.children.map { $0.replacingGroup(id, with: make) }
            return .split(split).flattened()
        }
    }

    /// Merge a split nested inside a same-axis parent, so three side-by-side panes
    /// are one split with three children rather than a chain of two-way splits.
    func flattened() -> PaneNode {
        guard case .split(var split) = self else { return self }
        var children: [PaneNode] = []
        var ratios: [Double] = []
        for (child, ratio) in zip(split.children, split.ratios) {
            if case .split(let inner) = child, inner.axis == split.axis {
                for (innerChild, innerRatio) in zip(inner.children, inner.ratios) {
                    children.append(innerChild)
                    ratios.append(ratio * innerRatio)
                }
            } else {
                children.append(child)
                ratios.append(ratio)
            }
        }
        split.children = children
        split.ratios = ratios
        return .split(split)
    }

    /// Remove empty groups and collapse splits left with one child.
    /// Returns nil when nothing is left.
    func pruned() -> PaneNode? {
        switch self {
        case .group(let group):
            return group.tabs.isEmpty ? nil : self
        case .split(var split):
            var children: [PaneNode] = []
            var ratios: [Double] = []
            for (child, ratio) in zip(split.children, split.ratios) {
                if let kept = child.pruned() {
                    children.append(kept)
                    ratios.append(ratio)
                }
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            let total = ratios.reduce(0, +)
            split.children = children
            split.ratios = ratios.map { $0 / total }
            return PaneNode.split(split).flattened()
        }
    }

    func mapSplit(_ id: String, _ transform: (inout PaneSplit) -> Void) -> PaneNode {
        guard case .split(var split) = self else { return self }
        if split.id == id {
            transform(&split)
        } else {
            split.children = split.children.map { $0.mapSplit(id, transform) }
        }
        return .split(split)
    }
}

// MARK: - Workspace

public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public var id: WorkspaceID
    public var name: String
    /// Absolute paths. Multi-root, as in a VS Code multi-root workspace.
    public var folders: [String]
    public var items: [Item]
    public var layout: PaneNode
    public var focusedGroup: GroupID {
        didSet {
            groupMRU.removeAll { $0 == focusedGroup }
            groupMRU.insert(focusedGroup, at: 0)
        }
    }
    /// Most recently focused first. Closing a group's last tab returns here.
    public var groupMRU: [GroupID] = []
    /// For ⌘⇧T. Most recent last.
    public var closed: [Item]
    /// Expanded tree folders, so the explorer comes back the way it was left.
    public var expandedFolders: [String] = []
    /// The floating Peek: an item that isn't in any tab group until it's promoted.
    /// Deliberately not persisted, since a Peek is a glance, not part of the session.
    public var peek: Item?

    public init(id: WorkspaceID = TiriID.make("w"), name: String, folders: [String] = []) {
        self.id = id
        self.name = name
        self.folders = folders
        self.items = []
        let group = TabGroup()
        self.layout = .group(group)
        self.focusedGroup = group.id
        self.closed = []
        self.peek = nil
    }

    // MARK: Peek

    public enum PeekResult: Equatable, Sendable {
        /// A new floating Peek. `replaced` is the Peek it took over from.
        case peeking(ItemID, replaced: ItemID?)
        /// Already open as a tab, so that tab was focused instead of floating a copy.
        case revealedExisting(ItemID)
    }

    /// Show a file in the Peek. A new Peek replaces the old one, so going through a list of
    /// files in an agent's output doesn't pile anything up. A person asking for a file that's
    /// already a tab gets that tab. An agent doesn't get to switch tabs under them
    /// (`revealExisting: false`): it floats, and the layout stays as it was.
    @discardableResult
    public mutating func peekFile(path: String, line: Int? = nil, col: Int? = nil,
                                  revealExisting: Bool = true) -> PeekResult {
        if revealExisting, let existing = fileItem(path: path) {
            setFileLocation(existing.id, line: line, col: col)
            activate(existing.id)
            peek = nil
            return .revealedExisting(existing.id)
        }
        return setPeek(Item(content: .file(FileSpec(path: path, line: line, col: col))))
    }

    @discardableResult
    public mutating func peekWeb(url: String) -> PeekResult {
        setPeek(Item(content: .web(WebSpec(url: url))))
    }

    private mutating func setPeek(_ item: Item) -> PeekResult {
        let replaced = peek?.id
        peek = item
        return .peeking(item.id, replaced: replaced)
    }

    /// Promote the Peek to a real, pinned tab. The item keeps its id, so the live viewer
    /// (scroll position and all) moves with it.
    @discardableResult
    public mutating func promotePeek(split: SplitDirection? = nil) -> ItemID? {
        guard var item = peek else { return nil }
        peek = nil
        item.isPreview = false
        addItem(item, split: split)
        return item.id
    }

    @discardableResult
    public mutating func dismissPeek() -> ItemID? {
        defer { peek = nil }
        return peek?.id
    }

    /// The first terminal a new workspace opens with: cwd = first folder.
    /// What a workspace is called before you've chosen a folder for it.
    public static let placeholderName = "Home"

    /// The first folder chosen for a placeholder workspace also names it.
    public mutating func adoptFolder(_ path: String, named newName: String) {
        if folders.isEmpty, name == Self.placeholderName { name = newName }
        addFolder(path)
    }

    public mutating func addInitialTerminal(fallbackCwd: String) {
        guard items.isEmpty else { return }
        addItem(Item(content: .terminal(TerminalSpec(cwd: folders.first ?? fallbackCwd))))
    }

    // MARK: Lookup

    public var groups: [TabGroup] { layout.groups }

    public func item(_ id: ItemID) -> Item? { items.first { $0.id == id } }

    public func group(containing id: ItemID) -> TabGroup? {
        groups.first { $0.tabs.contains(id) }
    }

    public func group(id: GroupID) -> TabGroup? { groups.first { $0.id == id } }

    public var focused: TabGroup {
        group(id: focusedGroup) ?? groups[0]
    }

    public var activeItem: Item? {
        guard let id = focused.active else { return nil }
        return item(id)
    }

    public func fileItem(path: String) -> Item? {
        items.first { $0.filePath == path }
    }

    // MARK: Adding

    private mutating func updateGroup(_ id: GroupID, _ transform: (inout TabGroup) -> Void) {
        layout = layout.mapGroup(id, transform)
    }

    /// Add an item as a tab in the focused group, or in a new group split off it.
    @discardableResult
    public mutating func addItem(_ item: Item, inGroup: GroupID? = nil, split: SplitDirection? = nil) -> GroupID {
        let target = inGroup.flatMap { group(id: $0)?.id } ?? focused.id
        items.append(item)

        if let split {
            // An empty group has nothing to split away from: just use it.
            if group(id: target)?.tabs.isEmpty != true {
                let newGroup = TabGroup(tabs: [item.id], active: item.id)
                insertSplit(newGroup, beside: target, direction: split)
                focusedGroup = newGroup.id
                return newGroup.id
            }
        }

        // A new preview takes over from the old one. As in VS Code it lands to the right of the
        // active tab, so it's next to what you're looking at, not where the old one happened to be.
        if item.isPreview, let group = group(id: target),
           let oldPreview = group.tabs.first(where: { self.item($0)?.isPreview == true && $0 != item.id }) {
            updateGroup(target) { group in
                if group.active == oldPreview {
                    let index = group.tabs.firstIndex(of: oldPreview)!
                    group.tabs[index] = item.id
                    group.mru.removeAll { $0 == oldPreview }
                } else {
                    group.remove(oldPreview)
                    let index = group.active.flatMap { group.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? group.tabs.count
                    group.tabs.insert(item.id, at: index)
                }
                group.active = item.id
            }
            items.removeAll { $0.id == oldPreview }
        } else {
            updateGroup(target) { group in
                // New tabs land right after the active one, as in Cursor.
                if let active = group.active, let index = group.tabs.firstIndex(of: active) {
                    group.tabs.insert(item.id, at: index + 1)
                } else {
                    group.tabs.append(item.id)
                }
                group.active = item.id
            }
        }
        focusedGroup = target
        return target
    }

    private mutating func insertSplit(_ newGroup: TabGroup, beside target: GroupID, direction: SplitDirection) {
        layout = layout.replacingGroup(target) { existing in
            let children: [PaneNode] = direction.isAfter
                ? [.group(existing), .group(newGroup)]
                : [.group(newGroup), .group(existing)]
            return .split(PaneSplit(axis: direction.axis, children: children))
        }.flattened()
    }

    // MARK: Files

    public enum OpenResult: Equatable, Sendable {
        case opened(ItemID)
        case revealedExisting(ItemID)
    }

    /// Open a file. Revisits an already-open tab unless a split was explicitly asked for.
    @discardableResult
    public mutating func openFile(path: String, line: Int? = nil, col: Int? = nil,
                                  preview: Bool, split: SplitDirection? = nil) -> OpenResult {
        if split == nil, let existing = fileItem(path: path) {
            setFileLocation(existing.id, line: line, col: col)
            if !preview { pin(existing.id) }
            activate(existing.id)
            return .revealedExisting(existing.id)
        }
        let item = Item(content: .file(FileSpec(path: path, line: line, col: col)),
                        isPreview: preview && split == nil)
        addItem(item, split: split)
        return .opened(item.id)
    }

    public mutating func setFileLocation(_ id: ItemID, line: Int?, col: Int?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .file(var spec) = items[index].content else { return }
        spec.line = line
        spec.col = col
        items[index].content = .file(spec)
    }

    /// A file moved on disk. Its tabs and Peek stay exactly where they are and follow it.
    /// Returns the items affected, whose viewers need to reopen the new path.
    @discardableResult
    public mutating func retargetFiles(from old: String, to new: String) -> [ItemID] {
        func moved(_ path: String) -> String? {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return nil
        }
        var changed: [ItemID] = []
        for index in items.indices {
            if case .file(var spec) = items[index].content, let path = moved(spec.path) {
                spec.path = path
                items[index].content = .file(spec)
                changed.append(items[index].id)
            }
        }
        if case .file(var spec)? = peek?.content, let path = moved(spec.path) {
            spec.path = path
            peek?.content = .file(spec)
            if let id = peek?.id { changed.append(id) }
        }
        return changed
    }

    public mutating func updateItem(_ id: ItemID, _ transform: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
    }

    public mutating func pin(_ id: ItemID) {
        updateItem(id) { $0.isPreview = false }
    }

    // MARK: Focus

    public mutating func activate(_ id: ItemID) {
        guard let group = group(containing: id) else { return }
        updateGroup(group.id) { $0.active = id }
        focusedGroup = group.id
    }

    public mutating func focusGroup(index: Int) {
        let all = groups
        guard index >= 0, index < all.count else { return }
        focusedGroup = all[index].id
    }

    public mutating func focusGroup(id: GroupID) {
        if group(id: id) != nil { focusedGroup = id }
    }

    public mutating func cycleTab(by offset: Int) {
        let group = focused
        guard !group.tabs.isEmpty else { return }
        let index = group.active.flatMap { group.tabs.firstIndex(of: $0) } ?? 0
        let next = (index + offset + group.tabs.count) % group.tabs.count
        updateGroup(group.id) { $0.active = $0.tabs[next] }
    }

    // MARK: Closing

    @discardableResult
    public mutating func close(_ id: ItemID, remember: Bool = true) -> Item? {
        guard let item = item(id), let group = group(containing: id) else { return nil }
        let wasFocused = group.id == focusedGroup
        updateGroup(group.id) { $0.remove(id) }
        items.removeAll { $0.id == id }
        if remember {
            closed.append(item)
            if closed.count > 30 { closed.removeFirst() }
        }
        normalize(preferring: wasFocused ? nil : focusedGroup)
        return item
    }

    /// Prune empty groups after a mutation, always keeping at least one group.
    private mutating func normalize(preferring preferred: GroupID?) {
        if let pruned = layout.pruned() {
            layout = pruned
        } else {
            let empty = TabGroup()
            layout = .group(empty)
        }
        let remaining = groups
        if let preferred, remaining.contains(where: { $0.id == preferred }) {
            focusedGroup = preferred
        } else if !remaining.contains(where: { $0.id == focusedGroup }) {
            let ids = Set(remaining.map(\.id))
            focusedGroup = groupMRU.first(where: ids.contains) ?? remaining[0].id
        }
    }

    public mutating func popClosed() -> Item? {
        closed.popLast()
    }

    // MARK: Moving tabs

    public mutating func moveTab(_ id: ItemID, toGroup target: GroupID, index: Int? = nil) {
        guard let source = group(containing: id), group(id: target) != nil else { return }
        // A tab you arranged is one you want to keep.
        pin(id)
        if source.id == target {
            updateGroup(target) { group in
                let from = group.tabs.firstIndex(of: id)!
                group.tabs.remove(at: from)
                var to = index ?? group.tabs.count
                if to > from { to -= 1 }
                group.tabs.insert(id, at: min(max(to, 0), group.tabs.count))
                group.active = id
            }
            focusedGroup = target
            return
        }
        updateGroup(source.id) { $0.remove(id) }
        updateGroup(target) { group in
            group.tabs.insert(id, at: min(index ?? group.tabs.count, group.tabs.count))
            group.active = id
        }
        focusedGroup = target
        normalize(preferring: target)
    }

    public mutating func moveTab(_ id: ItemID, splitting target: GroupID, direction: SplitDirection) {
        guard let source = group(containing: id), group(id: target) != nil else { return }
        // Dragging a group's only tab to its own edge would leave things as they are.
        if source.id == target, source.tabs.count == 1 { return }
        pin(id)
        let newGroup = TabGroup(tabs: [id], active: id)
        // Add first so the target can't be pruned out from under the split.
        insertSplit(newGroup, beside: target, direction: direction)
        updateGroup(source.id) { $0.remove(id) }
        focusedGroup = newGroup.id
        normalize(preferring: newGroup.id)
    }

    public mutating func setRatios(splitID: String, ratios: [Double]) {
        layout = layout.mapSplit(splitID) { split in
            guard ratios.count == split.children.count else { return }
            let total = ratios.reduce(0, +)
            guard total > 0 else { return }
            split.ratios = ratios.map { $0 / total }
        }
    }

    // MARK: Folders

    public mutating func addFolder(_ path: String) {
        if !folders.contains(path) { folders.append(path) }
    }

    public mutating func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
    }

    /// The workspace folder containing a path, for breadcrumbs and relative paths.
    public func folder(containing path: String) -> String? {
        folders
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    public func relativePath(_ path: String) -> String {
        guard let folder = folder(containing: path), path != folder else { return path }
        return String(path.dropFirst(folder.count).drop { $0 == "/" })
    }
}
