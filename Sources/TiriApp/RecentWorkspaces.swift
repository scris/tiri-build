import AppKit
import Observation
import SwiftUI
import TiriCore

/// Workspaces closed in Tiri, and folders used lately in an editor or by an agent: File → Open Recent, the
/// Workspaces + menu, ⌥⌘O and an empty workspace. What it leaves out is in `RecentPlaces.rank`.
@MainActor
@Observable
final class RecentWorkspaces {
    private(set) var places: [RecentPlace] = []
    @ObservationIgnored var store: RecentStore
    @ObservationIgnored fileprivate var sightings: [RecentPlaces.Sighting] = []
    @ObservationIgnored fileprivate var gatheredAt: Date?
    @ObservationIgnored fileprivate var gathering = false

    static var file: URL { TiriPaths.supportDirectory.appendingPathComponent("recent.json") }
    /// Whose editors and agents to look through. A test copy can be given a made-up home.
    static var home: String { ProcessInfo.processInfo.environment["TIRI_RECENT_HOME"] ?? NSHomeDirectory() }

    init() {
        store = RecentStore.load(from: Self.file)
    }

    func save() { store.save(to: Self.file) }

    fileprivate func set(_ places: [RecentPlace]) {
        if places != self.places { self.places = places }
    }
}

extension AppModel {
    // MARK: The list

    /// Looks through editors and agents again if it's been a minute, off the main thread, then ranks.
    func refreshRecents(force: Bool = false) {
        rankRecents()
        let recents = self.recents
        guard !recents.gathering, force || recents.gatheredAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        recents.gathering = true
        let home = RecentWorkspaces.home
        Task.detached(priority: .utility) { [weak self] in
            let found = RecentPlaces.sightings(home: home)
            await MainActor.run {
                recents.sightings = found
                recents.gatheredAt = Date()
                recents.gathering = false
                self?.rankRecents()
            }
        }
    }

    func rankRecents() {
        let places = RecentPlaces.rank(sightings: recents.sightings, closed: recents.store.closed, hidden: recents.store.hidden,
                                       openFolders: workspaces.flatMap(\.folders), home: RecentWorkspaces.home,
                                       exists: { FileManager.default.fileExists(atPath: $0) })
        recents.set(places)
        // The palette showing them keeps up, as what's gathered arrives or a row is removed.
        if let palette, case .choices(let title, _) = palette.mode, title == Self.recentTitle {
            palette.mode = .choices(title: title, rows: recentRows())
            palette.refresh()
        }
    }

    static var recentTitle: String { String(localized: "Open Recent") }

    /// Where it is, as the list shows it under or beside its name.
    func recentLocation(_ place: RecentPlace) -> String {
        switch place.kind {
        case .closed:
            if place.folders.count > 1 { return String(localized: "\(place.folders.count) folders") }
            return place.folders.first.map { prettyPath(($0 as NSString).deletingLastPathComponent) } ?? ""
        case .folder(let path), .codeWorkspace(let path):
            return prettyPath((path as NSString).deletingLastPathComponent)
        }
    }

    static func recentSymbol(_ place: RecentPlace) -> String {
        switch place.kind {
        case .closed: return place.folders.count > 1 ? "square.stack.3d.up.fill" : "folder.fill"
        case .folder: return "folder"
        case .codeWorkspace: return "square.stack.3d.up"
        }
    }

    // MARK: Closing and opening

    /// Takes a workspace out of the sidebar, tabs and all, to come back from Open Recent. Asks first only if
    /// an agent in it is in the middle of something.
    func confirmCloseWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let busy = workspace.items.filter { item in runtimes[item.id].map { $0.status == .working || $0.status == .needsInput } ?? false }.count
        guard busy > 0, let window else {
            closeWorkspace(id)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Close the workspace “\(workspace.shownName)”?")
        alert.informativeText = busy == 1
            ? String(localized: "An agent in it is working. It stops now, and picks up its conversation when you reopen the workspace.")
            : String(localized: "\(busy) agents in it are working. They stop now, and pick up their conversations when you reopen the workspace.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.closeWorkspace(id) }
            }
        }
    }

    func closeWorkspace(_ id: WorkspaceID) {
        guard var workspace = workspaces.first(where: { $0.id == id }) else { return }
        // An empty placeholder isn't worth coming back to.
        let keep = !workspace.folders.isEmpty || !workspace.items.isEmpty
        if keep {
            workspace.dismissPeek()
            workspace.heldPeek = nil
            recents.store.closed.removeAll { $0.workspace.id == id }
            recents.store.closed.insert(ClosedWorkspace(workspace: workspace, closedAt: Date()), at: 0)
            while recents.store.closed.count > RecentStore.closedLimit {
                forgetClosed(recents.store.closed.removeLast().workspace)
            }
            recents.save()
        }
        deleteWorkspace(id, keepingEdits: keep)
        rankRecents()
    }

    func openRecent(_ place: RecentPlace) {
        // However it was chosen, the list it was chosen from has done its job.
        if let palette, case .choices(let title, _) = palette.mode, title == Self.recentTitle { closePalette(restoreFocus: false) }
        switch place.kind {
        case .closed(let id):
            guard let index = recents.store.closed.firstIndex(where: { $0.workspace.id == id }) else { return }
            var workspace = recents.store.closed.remove(at: index).workspace
            recents.save()
            if workspaces.contains(where: { $0.id == workspace.id }) { workspace.id = Workspace(name: workspace.name).id }
            workspace.name = uniqueName(workspace.name)
            // Its programs ended when it closed, so they come back as after a relaunch: agents resume.
            for item in workspace.items {
                if case .terminal = item.content { restoredItems.insert(item.id) }
            }
            keptEdits.subtract(workspace.items.map(\.id))
            workspaces.append(workspace)
            switchWorkspace(workspace.id)
            editorBridge.writeLock()
        case .folder(let path):
            openFolderAsWorkspace(path)
        case .codeWorkspace(let path):
            _ = importWorkspace(url: URL(fileURLWithPath: path))
        }
        rankRecents()
    }

    /// Off the list. A folder comes back once it's used again; a closed workspace is gone for good.
    func removeRecent(_ place: RecentPlace, saving: Bool = true) {
        switch place.kind {
        case .closed(let id):
            if let index = recents.store.closed.firstIndex(where: { $0.workspace.id == id }) {
                forgetClosed(recents.store.closed.remove(at: index).workspace)
            }
        case .folder(let path), .codeWorkspace(let path):
            recents.store.hidden[path] = Date()
        }
        if saving {
            recents.save()
            rankRecents()
        }
    }

    func clearRecents() {
        for place in recents.places { removeRecent(place, saving: false) }
        recents.save()
        rankRecents()
    }

    private func forgetClosed(_ workspace: Workspace) {
        for item in workspace.items {
            keptEdits.remove(item.id)
            UnsavedEdits.remove(item.id)
        }
    }

    func recentPlace(matching text: String) -> RecentPlace? {
        let places = recents.places
        if let number = Int(text), places.indices.contains(number - 1) { return places[number - 1] }
        let path = (text as NSString).expandingTildeInPath
        return places.first { $0.path == path || $0.id == text }
            ?? places.first { $0.name == text }
            ?? places.first { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    // MARK: The palette

    func openRecentPalette() {
        refreshRecents()
        openPalette(.choices(title: Self.recentTitle, rows: recentRows()))
    }

    func recentRows() -> [PaletteModel.Row] {
        recents.places.map { place in
            PaletteModel.Row(id: place.id, title: place.name, detail: recentLocation(place),
                             shortcut: RecentPlaces.age(of: place.lastUsed), symbol: Self.recentSymbol(place),
                             button: .init(title: String(localized: "Remove")) { [weak self] in self?.removeRecent(place) },
                             action: { [weak self] _ in
                                 self?.closePalette()
                                 self?.openRecent(place)
                             })
        }
    }
}

// MARK: Views

/// File → Open Recent and the Workspaces + menu: the newest few, then the rest in the palette.
struct OpenRecentMenu: View {
    let model: AppModel
    static let shown = 8

    var body: some View {
        let places = Array(model.recents.places.prefix(Self.shown))
        let names = Dictionary(grouping: places, by: \.name)
        Menu("Open Recent") {
            ForEach(places) { place in
                // Only a name that's there twice needs to say where it is.
                Button(names[place.name, default: []].count > 1 ? place.name + "  " + model.recentLocation(place) : place.name) {
                    model.openRecent(place)
                }
            }
            if !places.isEmpty { Divider() }
            Button("More…") { model.openRecentPalette() }
                .modifier(MenuShortcut(binding: model.firstSingleStrokeBinding(for: "openRecent")))
            Button("Clear Menu") { model.clearRecents() }
                .disabled(places.isEmpty)
        }
    }
}

/// The newest few, where a workspace has nothing in it yet.
struct RecentPlacesList: View {
    @Environment(AppModel.self) private var model
    static let shown = 5

    var body: some View {
        let places = Array(model.recents.places.prefix(Self.shown))
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("Recent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 3)
                ForEach(places) { place in
                    RecentPlaceRow(place: place)
                }
            }
            .frame(maxWidth: 280)
        }
    }
}

struct RecentPlaceRow: View {
    let place: RecentPlace
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: AppModel.recentSymbol(place))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(place.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Text(model.recentLocation(place))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.removeRecent(place)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from Recent")
                .accessibilityLabel("Remove from Recent")
            } else {
                Text(RecentPlaces.age(of: place.lastUsed))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .currentMark(false, hovering: hovering, cornerRadius: 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openRecent(place) }
        .help(place.folders.isEmpty ? model.prettyPath(place.path) : place.folders.map { model.prettyPath($0) }.joined(separator: "\n"))
        .accessibleRow(place.name, value: model.recentLocation(place), selected: false) { model.openRecent(place) }
        .accessibilityAction(named: "Remove from Recent") { model.removeRecent(place) }
    }
}
