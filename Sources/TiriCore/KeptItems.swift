import Foundation

/// A tab this build can't show: a kind another copy of Tiri added, or one it can't read. It's kept out of sight,
/// exactly as it was written, and goes back where it was at the next save, so the copy that made it finds it again.
public struct KeptItem: Codable, Hashable, Sendable {
    public var raw: JSONValue
    /// The tab group it was in, and where in it.
    public var group: GroupID?
    public var index: Int?
    /// From the list ⌘⇧T reopens, rather than from a tab.
    public var closed: Bool

    public var id: ItemID? { raw["id"]?.stringValue }

    public init(raw: JSONValue, group: GroupID? = nil, index: Int? = nil, closed: Bool = false) {
        self.raw = raw
        self.group = group
        self.index = index
        self.closed = closed
    }
}

/// One entry of a saved list of items: one this build knows, or one it keeps as it came. Read one at a time, so
/// one it can't read never takes the others with it.
enum SavedItem: Codable {
    case known(Item)
    case kept(JSONValue)

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        if let item = try? Item(from: decoder), !item.content.isUnknown {
            self = .known(item)
        } else {
            self = .kept(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .known(let item): try item.encode(to: encoder)
        case .kept(let raw): try raw.encode(to: encoder)
        }
    }
}

extension Workspace {
    /// What came from a saved layout: known items as they are, the rest set aside with where their tabs were.
    mutating func take(items saved: [SavedItem], closed savedClosed: [SavedItem]) {
        var kept: [KeptItem] = []
        items = []
        for entry in saved {
            switch entry {
            case .known(let item): items.append(item)
            case .kept(let raw):
                var entry = KeptItem(raw: raw)
                if let id = entry.id, let group = group(containing: id) {
                    entry.group = group.id
                    entry.index = group.tabs.firstIndex(of: id)
                }
                kept.append(entry)
            }
        }
        closed = savedClosed.compactMap { if case .known(let item) = $0 { item } else { nil } }
        for case .kept(let raw) in savedClosed { kept.append(KeptItem(raw: raw, closed: true)) }
        // A tab with no item behind it can't be shown either.
        let known = Set(items.map(\.id))
        let hidden = Set(kept.compactMap(\.id))
        if !hidden.isEmpty || groups.contains(where: { $0.tabs.contains { !known.contains($0) } }) {
            for group in groups {
                layout = layout.mapGroup(group.id) { group in
                    for id in group.tabs where !known.contains(id) { group.remove(id) }
                }
            }
            pruneEmptyGroups()
        }
        self.kept = kept.isEmpty ? nil : kept
    }

    /// The items and layout to save: what's shown, with what was set aside back in its place.
    func savedForm() -> (items: [SavedItem], closed: [SavedItem], layout: PaneNode) {
        var layout = layout
        var items = items.map(SavedItem.known)
        var closed = closed.map(SavedItem.known)
        let groups = layout.groups
        for entry in kept ?? [] {
            if entry.closed {
                closed.append(.kept(entry.raw))
                continue
            }
            items.append(.kept(entry.raw))
            guard let id = entry.id, !groups.isEmpty else { continue }
            let target = groups.first { $0.id == entry.group }?.id ?? groups[0].id
            layout = layout.mapGroup(target) { group in
                guard !group.tabs.contains(id) else { return }
                group.tabs.insert(id, at: min(entry.index ?? group.tabs.count, group.tabs.count))
            }
        }
        return (items, closed, layout)
    }
}
