import AppKit
import SwiftUI
import TiriCore

struct RootView: View {
    var windowID = WindowPlan.main
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Which workspace this window shows, for everything inside it.
    private var scope: WindowScope {
        WindowScope(window: windowID, workspace: model.windowWorkspaces[windowID] ?? model.activeID)
    }

    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        if model.windowWorkspaces[windowID] != nil {
            window
        } else {
            // A window that's been closed, which SwiftUI may keep, shows nothing, so it can't take a terminal
            // from where it's shown. The main window, opened again, is given a workspace here.
            Color.clear.background(WindowAccessor { [windowID] window in model.windowDidAppear(window, id: windowID) })
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: model.sidebarVisibility(ofWindow: windowID)) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 270, max: 460)
            } detail: {
                DetailView()
                    .toolbar { MainToolbar() }
            }
            .navigationTitle(here.active.name)
            .navigationSubtitle(subtitle)
            .background(WindowAccessor { [windowID] window in model.windowDidAppear(window, id: windowID) })
            // What floats over a window, and dragging a tab, belong to the window in front.
            .overlay(alignment: .top) { if here.isCurrent { ChromeOverlays() } }
            .overlay { if here.isCurrent { TabDragOverlay() } }
            StatusBar()
        }
        .environment(\.windowScope, scope)
        .onAppear { model.adoptOpenWindow(openWindow) }
    }

    private var subtitle: String {
        let folders = here.active.folders
        switch folders.count {
        case 0: return ""
        case 1:
            if let host = here.active.remote { return SSHConfigFile.displayName(of: host) + ": " + model.prettyPath(folders[0]) }
            return (folders[0] as NSString).abbreviatingWithTildeInPath
        default: return "\(folders.count) folders"
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // One button, one menu. A button and not a SwiftUI menu, because a toolbar drops a menu's title
            // when it shows icons and text, and this one would be the only one without words.
            Button { NewMenu.popUp(model: model, folders: here.active.folders) } label: {
                Label("New", systemImage: "plus")
            }
            .help("New terminal or agent")
            .accessibilityLabel("New Terminal or Agent")

            Button { model.openConversationPicker() } label: {
                Label("Past Conversations", systemImage: "clock.arrow.circlepath")
            }
            .help("Find and go back to a past conversation (⇧⌘H)")

            Button { model.chooseFilesForAgent() } label: {
                Label("Add Files", systemImage: "paperclip")
            }
            .help("Add files or images to your agent (⇧⌘L)")

            Button { model.splitActive(.right) } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .help(String("Split Right (⌘\\)"))

            Button { model.splitActive(.down) } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .help(String("Split Down (⌘K ⌘\\)"))
        }
    }
}

/// The + button's menu: an agent or a shell, in which folder when there are several.
@MainActor
enum NewMenu {
    private final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func popUp(model: AppModel, folders: [String]) {
        let menu = NSMenu()
        var handlers: [Handler] = []
        func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
            let handler = Handler(run)
            handlers.append(handler)
            let item = NSMenuItem(title: title, action: #selector(Handler.fire), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            return item
        }
        for preset in model.settings.activePresets {
            if folders.count > 1 {
                let sub = NSMenu()
                for folder in folders {
                    sub.addItem(item(MainToolbar.folderLabel(folder, among: folders)) { model.newTerminal(command: preset.command, cwd: folder) })
                }
                let parent = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            } else {
                menu.addItem(item(preset.name) { model.startTerminal(command: preset.command) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Past Conversations…") { model.openConversationPicker() })
        menu.addItem(item("Manage Agents…") { model.openAgentSettings() })
        // Under the button that was pressed, the way a toolbar menu opens.
        guard let event = NSApp.currentEvent, let window = event.window, let content = window.contentView else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let point = content.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: point.x - 12, y: point.y - 22), in: content)
        _ = handlers
    }
}

extension MainToolbar {
    /// Two folders can share a name, and the choice decides where an agent works.
    static func folderLabel(_ folder: String, among folders: [String]) -> String {
        let name = (folder as NSString).lastPathComponent
        let shared = folders.filter { ($0 as NSString).lastPathComponent == name }.count > 1
        return shared ? (folder as NSString).abbreviatingWithTildeInPath : name
    }
}

// MARK: - Detail: panes plus the floating Peek

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        ZStack(alignment: .trailing) {
            PaneNodeView(node: here.active.layout)
                .background(Color(nsColor: TerminalTheme.background(dark: model.effectiveDark)))
            if let peek = here.active.peek {
                PeekView(item: peek)
                    .transition(.asymmetric(insertion: AccessibilityDisplay.shared.slide(from: .trailing), removal: .opacity))
                    .id(peek.id)
            }
        }
        .animation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.22)), value: here.active.peek?.id)
    }
}

struct PaneNodeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .group(let group):
            // Identity follows the group. Otherwise a workspace switch reuses this view for a
            // different group, and the old group's geometry is never unregistered.
            TabGroupView(group: group).id(group.id)
        case .split(let split):
            SplitNodeView(split: split).id(split.id)
        }
    }
}

extension PaneNode {
    var stableID: String {
        switch self {
        case .group(let group): group.id
        case .split(let split): split.id
        }
    }
}

/// A split with draggable dividers. The ratios live in the workspace, so they persist.
struct SplitNodeView: View {
    let split: PaneSplit
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }
    @State private var dragStartRatios: [Double]?
    private let dividerThickness: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let horizontal = split.axis == .horizontal
            let total = (horizontal ? geometry.size.width : geometry.size.height)
                - dividerThickness * CGFloat(split.children.count - 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.children.enumerated()), id: \.element.stableID) { index, child in
                    let length = max(total * split.ratios[safe: index, default: 0], 0)
                    PaneNodeView(node: child)
                        .frame(width: horizontal ? length : nil, height: horizontal ? nil : length)
                    if index < split.children.count - 1 {
                        divider(after: index, total: total, horizontal: horizontal)
                    }
                }
            }
        }
    }

    private func divider(after index: Int, total: CGFloat, horizontal: Bool) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? dividerThickness : nil, height: horizontal ? nil : dividerThickness)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (horizontal ? NSCursor.columnResize : NSCursor.rowResize).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartRatios ?? split.ratios
                            if dragStartRatios == nil { dragStartRatios = start }
                            let delta = Double((horizontal ? value.translation.width : value.translation.height) / max(total, 1))
                            var ratios = start
                            // Neither side gets smaller than a usable pane.
                            let minimum = Double(120 / max(total, 1))
                            let pair = start[index] + start[index + 1]
                            let first = min(max(start[index] + delta, minimum), pair - minimum)
                            ratios[index] = first
                            ratios[index + 1] = pair - first
                            model.update(workspace: here.activeID) { $0.setRatios(splitID: split.id, ratios: ratios) }
                        }
                        .onEnded { _ in dragStartRatios = nil })
            }
            .zIndex(1)
    }
}

/// Reports a view's window-space frame when it appears and whenever it changes. onGeometryChange
/// alone isn't enough: it stays silent for a view whose first layout is already its final one.
struct FrameReporter: ViewModifier {
    let action: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onAppear { action(frame) }
                    .onChange(of: frame) { _, new in action(new) }
            }
        }
    }
}

extension View {
    func reportingFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        modifier(FrameReporter(action: action))
    }
}

extension Array {
    subscript(safe index: Int, default fallback: @autoclosure () -> Element) -> Element {
        indices.contains(index) ? self[index] : fallback()
    }
}

// MARK: - A tab group

struct TabGroupView: View {
    let group: TabGroup
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }
    @State private var owner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                TabBar(group: group)
            }
            if let activeID = group.active, let item = here.active.item(activeID) {
                ItemHeader(item: item)
                ItemContentView(item: item, group: group.id)
            } else {
                EmptyGroupView()
            }
        }
        .reportingFrame { frame in
            model.layoutRegistry.setGroup(
                group.id,
                bar: group.tabs.isEmpty ? nil : CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34),
                content: CGRect(x: frame.minX, y: frame.minY + 34, width: frame.width, height: frame.height - 34),
                owner: owner)
        }
        .onDisappear { model.layoutRegistry.removeGroup(group.id, owner: owner) }
    }
}

struct ItemContentView: View {
    let item: Item
    let group: GroupID
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.detachedItems.contains(item.id) {
                DetachedPlaceholder(itemID: item.id)
            } else {
                ItemHost(itemID: item.id, group: group)
            }
            if let find = model.find, find.targetItem == item.id {
                FindBar()
                    .padding(.top, 8)
                    .padding(.trailing, 14)
            }
            YourTiriCards(item: item.id)
        }
    }
}

/// Puts an item's long-lived view into the SwiftUI tree. The view belongs to its
/// controller, not to SwiftUI, so switching tabs never restarts a terminal or reloads a page.
struct ItemHost: NSViewRepresentable {
    let itemID: ItemID
    var group: GroupID?
    /// In its own window, not in a tab or a Peek.
    var isDetached = false
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    final class Host: NSView {
        weak var installed: NSView?
        private static var created = 0
        let serial: Int
        var ownsInstalledItem: (() -> Bool)?
        /// While the sidebar moves, see `holdItemSizes`.
        static var holdsSizes = false
        static let sizesReleased = Notification.Name("TiriItemSizesReleased")

        override init(frame: NSRect) {
            Self.created += 1
            serial = Self.created
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            autoresizesSubviews = false
            NotificationCenter.default.addObserver(self, selector: #selector(takeNewSize), name: Self.sizesReleased, object: nil)
        }

        /// Right now, rather than whenever the window next lays out: the size is all that's been waiting.
        @objc private func takeNewSize() {
            layer?.backgroundColor = nil
            installed?.frame = bounds
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        func install(_ view: NSView) {
            guard installed !== view || view.superview !== self else { return }
            // When a pane is rebuilt, its old host is still updated for a moment and looks just as
            // entitled as the new one, which may not even be in the window yet. A newer host keeps
            // the view while it still owns the item. A promoted Peek doesn't, so the tab gets it.
            if let current = view.superview as? Host, current !== self, current.serial > serial,
               current.ownsInstalledItem?() == true {
                return
            }
            subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            // Sized in layout(), never by autoresizing: this host often starts at zero size,
            // and growing a scroll view from zero leaves it with a bad frame.
            view.frame = bounds
            addSubview(view)
            installed = view
            needsLayout = true
            Self.markNeedsDisplay(view)
        }

        /// A view moved to a new parent keeps its old backing layers until told to redraw.
        private static func markNeedsDisplay(_ view: NSView) {
            view.needsDisplay = true
            view.needsLayout = true
            for subview in view.subviews { markNeedsDisplay(subview) }
        }

        override func layout() {
            super.layout()
            // Only its width: what's anything else is a real change, like a pane being rearranged.
            if Self.holdsSizes, let installed, installed.frame.width > 0, abs(installed.frame.height - bounds.height) < 1 {
                // What it uncovers on the way, until it fills the new width, matches a terminal.
                layer?.backgroundColor = TerminalTheme.background(dark: AppModel.shared.effectiveDark).cgColor
                return
            }
            layer?.backgroundColor = nil
            installed?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> Host {
        Host()
    }

    func updateNSView(_ host: Host, context: Context) {
        let _ = model.remote.revision
        if let group { model.groupHosts[group] = AppModel.WeakView(view: host) }
        // A view on its way out (a Peek fading after being promoted, a tab that just moved) still
        // gets updated. It must not pull the viewer back from where the item lives now.
        let workspaceID = here.activeID
        let owns = { [model, group, itemID, isDetached, workspaceID] () -> Bool in
            if model.detachedItems.contains(itemID) { return isDetached }
            let workspace = model.workspaces.first { $0.id == workspaceID } ?? model.active
            if let group { return workspace.group(id: group)?.active == itemID }
            return workspace.peek?.id == itemID
        }
        guard owns(), here.accessReady, let controller = model.controller(for: itemID) else { return }
        host.ownsInstalledItem = owns
        let changed = host.installed !== controller.view
        host.install(controller.view)
        if changed {
            controller.didAttach()
            // Web-backed viewers report when their page has finished instead.
            if !(controller is MarkdownController || controller is WebController || controller is ImageController) {
                let id = itemID
                DispatchQueue.main.async { model.viewerReady(id) }
            }
            // Moving a view between parents drops first responder. Put it back.
            // Only in the window in front: one behind keeps the keyboard where it is.
            let isFocusTarget = here.isCurrent && (model.peekHasKeyboard ? model.active.peek?.id == itemID
                                                                         : model.active.focused.active == itemID)
            // A single click in the tree previews the file and leaves the keyboard in the tree,
            // so arrow keys can keep browsing and Enter can rename.
            let browsingTree = model.window?.firstResponder is TreeOutlineView
            if isFocusTarget, model.palette == nil, !browsingTree { model.requestFocus() }
        }
    }
}

struct EmptyGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    private func row(_ title: String, _ command: String) -> some View {
        HStack(spacing: 24) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(model.shortcutSymbol(for: command) ?? "")
                .foregroundStyle(.faint)
                .font(.system(.body, design: .default).monospacedDigit())
        }
        .frame(width: 240)
    }

    var body: some View {
        Group {
            if here.active.folders.isEmpty {
                start
            } else {
                VStack(spacing: 22) {
                    agentTiles
                    StartList {
                        StartRow(title: "Past Conversations", symbol: "clock.arrow.circlepath", shortcut: model.shortcutSymbol(for: "conversations")) { model.openConversationPicker() }
                        StartRow(title: "Open a File", symbol: "doc", shortcut: model.shortcutSymbol(for: "quickOpen")) { model.run("quickOpen") }
                        StartRow(title: "New Terminal", symbol: "terminal", shortcut: model.shortcutSymbol(for: "newTerminal")) { model.run("newTerminal") }
                        if model.yourTiri.entriesAreOn {
                            StartRow(title: "Change Tiri", symbol: "wand.and.stars", shortcut: nil) { model.yourTiri.beginChange(surface: nil) }
                        }
                        StartRow(title: "All Commands", symbol: "command", shortcut: model.shortcutSymbol(for: "commandPalette")) { model.run("commandPalette") }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Terminal") { model.startTerminal() }
        }
        // Coming back from installing an agent should show it without a relaunch.
        .onAppear { model.refreshAvailableCommands() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAvailableCommands()
        }
    }

    /// One folder or none: the tile starts the agent, asking for a folder first if it has to.
    /// Several: it asks which, as the toolbar's + does.
    @ViewBuilder
    private var agentTiles: some View {
        let presets = model.runnableAgentPresets()
        if !presets.isEmpty {
            VStack(spacing: 10) {
                // Four to a row keeps them all the same size, however many agents you've added.
                ForEach(Array(stride(from: 0, to: presets.count, by: 4)), id: \.self) { start in
                    HStack(spacing: 10) {
                        ForEach(presets[start..<min(start + 4, presets.count)]) { preset in
                            agentTile(preset)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func agentTile(_ preset: TerminalPreset) -> some View {
        let symbol = AgentCatalog.profile(executable: AppModel.tool(of: preset))?.symbol ?? "terminal"
        if here.active.folders.count > 1 {
            Menu {
                ForEach(here.active.folders, id: \.self) { folder in
                    Button((folder as NSString).lastPathComponent) { model.newTerminal(command: preset.command, cwd: folder) }
                }
            } label: {
                AgentTileLabel(name: preset.name, symbol: symbol)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Start \(preset.name) in one of this workspace's folders")
        } else {
            Button {
                model.startTerminal(command: preset.command)
            } label: {
                AgentTileLabel(name: preset.name, symbol: symbol)
            }
            .buttonStyle(.plain)
            .help(here.active.folders.isEmpty ? "Choose a folder, then start \(preset.name) there" : "Start \(preset.name)")
        }
    }

    private var start: some View {
        let noneOn = model.agentPresets().isEmpty
        let noAgents = model.availableCommands != nil && model.runnableAgentPresets().isEmpty
        return VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(noneOn ? "No agents are on" : (noAgents ? "No agents found" : "Start an agent"))
                    .font(.title3.weight(.semibold))
                Text(noneOn
                     ? "Turn on the ones you use, and they'll be here."
                     : noAgents
                     ? "Tiri works with the CLI agents you already use, and your shell can't find one yet. Once you've installed one, it appears here."
                     : "Choose the folder it works in, and it starts there.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if noneOn {
                Button("Choose Agents…") { model.openAgentSettings() }
                    .controlSize(.large)
            } else if noAgents {
                // Only the ones you've kept on are worth pointing you at.
                HStack(spacing: 18) {
                    ForEach(model.agentEntries.filter(\.isEnabled)) { entry in
                        if let website = entry.profile?.website, let url = URL(string: website) {
                            Link("Get \(entry.name)", destination: url)
                        }
                    }
                }
            } else {
                agentTiles
            }
            StartList {
                StartRow(title: "Past Conversations", symbol: "clock.arrow.circlepath", shortcut: model.shortcutSymbol(for: "conversations")) { model.openConversationPicker() }
                StartRow(title: "Shell", symbol: "terminal", shortcut: model.shortcutSymbol(for: "newTerminal")) { model.startTerminal() }
                StartRow(title: "Open a Folder", symbol: "folder", shortcut: nil) { model.chooseFolderForActiveWorkspace { _ in } }
                StartRow(title: "Connect to a Server", symbol: "server.rack", shortcut: nil) { model.connectToServerInteractive() }
                if model.yourTiri.entriesAreOn {
                    StartRow(title: "Change Tiri", symbol: "wand.and.stars", shortcut: nil) { model.yourTiri.beginChange(surface: nil) }
                }
            }
        }
    }
}

/// An agent to start: all of them the same size and weight, since none of them is the default.
private struct AgentTileLabel: View {
    let name: String
    let symbol: String
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(height: 24)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 112, height: 78)
        .background(Color.primary.opacity(hovering ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
        .overlay {
            // A faint edge is all that says this is a button, so Increase Contrast draws it clearly.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(AccessibilityDisplay.shared.increaseContrast ? 0.55 : hovering ? 0.14 : 0.07))
        }
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.12)), value: hovering)
    }
}

/// Everything else you might have come for, quietly.
private struct StartList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 1) { content }
            .frame(width: 356)
    }
}

private struct StartRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.faint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? .primary : .secondary)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - An item in its own window

final class DetachedWindowDelegate: NSObject, NSWindowDelegate {
    private let item: ItemID
    private unowned let model: AppModel

    init(item: ItemID, model: AppModel) {
        self.item = item
        self.model = model
    }

    /// Closing the window doesn't close the item. It goes back to its tab.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.bringBack(item)
        return false
    }
}

struct DetachedItemView: View {
    let itemID: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let item = model.anyItem(itemID) {
                ItemHeader(item: item)
            }
            ItemHost(itemID: itemID, group: nil, isDetached: true)
                .background(Color(nsColor: TerminalTheme.background(dark: model.effectiveDark)))
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

struct DetachedPlaceholder: View {
    let itemID: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.faint)
            Text("Showing in its own window")
                .foregroundStyle(.secondary)
            HStack {
                Button("Show Window") { model.showDetachedWindow(itemID) }
                Button("Bring Back") { model.bringBack(itemID) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Above a file or web item

struct ItemHeader: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        switch item.content {
        case .terminal, .settings:
            EmptyView()
        case .plugin(let spec):
            if let web = model.controller(for: item.id) as? WebController {
                PluginPanelHeader(spec: spec, controller: web)
            }
        case .file(let spec):
            if here.accessReady, let web = model.controller(for: item.id) as? WebController, web.panel == nil {
                WebHeader(controller: web, filePath: spec.path)
            } else {
                FileHeader(item: item, path: spec.path)
            }
        case .web:
            if let web = model.controller(for: item.id) as? WebController {
                WebHeader(controller: web, filePath: nil)
            }
        case .diff(let spec):
            FileHeader(item: item, path: spec.path)
        }
    }
}

struct FileHeader: View {
    let item: Item
    let path: String
    var showsActions = true
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Breadcrumbs(path: path)
            Spacer(minLength: 8)
            if showsActions { FileActions(item: item, path: path) }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .tiriBar()
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct FileActions: View {
    let item: Item
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        let _ = model.controllerRevision
        BackButton()
        Button {
            model.addFrontToAgent()
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Add this file or your selection to the agent (⌘L)")
        .accessibilityLabel("Add to Agent")
        if case .diff = item.content, let diff = model.controller(for: item.id) as? DiffController {
            if diff.diff.additions + diff.diff.deletions > 0 {
                HStack(spacing: 4) {
                    Text("+\(diff.diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.diff.deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
            Button {
                diff.toggleLayout()
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .buttonStyle(.plain)
            .foregroundStyle(diff.isSideBySide ? Color.accentColor : .secondary)
            .disabled(diff.isTooNarrowForTwoColumns)
            .help(diff.isTooNarrowForTwoColumns ? "There isn't room here for side by side" : (diff.isSideBySide ? "Show in one column" : "Show side by side"))
            .accessibilityLabel("Side by Side")
            .accessibilityAddTraits(diff.isSideBySide ? .isSelected : [])
            Button {
                model.toggleChangesForFront()
            } label: {
                Label("Open File", systemImage: "doc.text").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .disabled(!FileManager.default.fileExists(atPath: path))
            .help("Show the file itself")
        }
        if case .file = item.content, let text = model.controller(for: item.id) as? TextController, text.encoding != .utf8 {
            Button {
                model.chooseEncoding(for: item.id)
            } label: {
                Text(TextEncodings.name(of: text.encoding))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("This file isn't UTF-8. Click to read it another way, or save it as UTF-8")
        }
        if case .file = item.content, here.hasChanges(path) {
            Button {
                model.toggleChangesForFront()
            } label: {
                Label("Changes", systemImage: "plus.forwardslash.minus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Show what changed in this file")
        }
        if here.accessReady, let document = model.controller(for: item.id) as? ForceDarkCapable, document.supportsForceDark {
            Button {
                model.setForceDark(!document.forceDarkActive, item: item.id)
            } label: {
                Image(systemName: document.forceDarkActive ? "moon.fill" : "moon")
            }
            .buttonStyle(.plain)
            .foregroundStyle(document.forceDarkActive ? Color.accentColor : .secondary)
            .help(document.forceDarkActive ? "Showing dark. Click for true colors" : "Show this document dark")
            .accessibilityLabel(document.forceDarkActive ? "True Colors" : "Show Dark")
        }
        if here.accessReady, let pdf = (model.controller(for: item.id) as? TextController)?.compiledPDF {
            Button {
                model.open(path: pdf, intent: .split(.right))
            } label: {
                Label("PDF", systemImage: "doc.richtext").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Open \((pdf as NSString).lastPathComponent) to the Side")
        }
        if here.accessReady, let conversation = model.conversation(shownAt: path) {
            ConversationBar(conversation: conversation, path: path)
        }
        PluginFileButtons(item: item, path: path)
        if here.accessReady, let notebook = model.controller(for: item.id) as? MarkdownController, notebook.isNotebook, !notebook.showingSource, notebook.canToggleSource {
            NotebookBar(viewer: notebook, kernel: model.notebookKernels.kernel(for: notebook.path))
        }
        if here.accessReady, let markdown = model.controller(for: item.id) as? MarkdownController, markdown.canToggleSource {
            Button {
                model.toggleMarkdownSource(item.id)
            } label: {
                Label(markdown.showingSource ? "Rendered" : "Source",
                      systemImage: markdown.showingSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help(markdown.showingSource ? "Show rendered \(markdown.kindName)" : "Show \(markdown.kindName) source")
        }
        OpenElsewhereButton(page: model.controller(for: item.id) as? WebController, path: path)
    }
}

struct Breadcrumbs: View {
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        let parts = crumbs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption2)
                            .foregroundStyle(.faint)
                            .accessibilityHidden(true)
                    }
                    Text(part.name)
                        .font(.caption)
                        .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if index < parts.count - 1 { model.revealOrOffer(path: part.path) }
                        }
                        .accessibilityAddTraits(index < parts.count - 1 ? .isButton : [])
                        .accessibilityHint(index < parts.count - 1 ? "Reveals it in the explorer" : "")
                        .accessibilityAction { if index < parts.count - 1 { model.revealOrOffer(path: part.path) } }
                }
            }
        }
    }

    private var crumbs: [(name: String, path: String)] {
        // The path within its workspace folder. Files elsewhere show their full path.
        var result: [(String, String)] = []
        if let folder = here.active.folder(containing: path) {
            result.append(((folder as NSString).lastPathComponent, folder))
            var current = folder
            for component in path.dropFirst(folder.count).split(separator: "/") {
                current += "/" + component
                result.append((String(component), current))
            }
        } else {
            var current = ""
            let abbreviated = model.prettyPath(path)
            let components = abbreviated.split(separator: "/").map(String.init)
            for component in components {
                current = component == "~" ? NSHomeDirectory() : current + "/" + component
                result.append((component, current))
            }
        }
        return result
    }
}

struct WebHeader: View {
    @Bindable var controller: WebController
    let filePath: String?
    @Environment(AppModel.self) private var model
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            navigationButton("chevron.left", "Back", enabled: controller.canGoBack) { controller.goBack() }
            navigationButton("chevron.right", "Forward", enabled: controller.canGoForward) { controller.goForward() }
            navigationButton(controller.isLoading ? "xmark" : "arrow.clockwise", "Reload", enabled: true) {
                if controller.isLoading { controller.webView.stopLoading() } else { controller.reload() }
            }
            TextField("Address", text: $controller.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($addressFocused)
                .onSubmit {
                    controller.submitAddress()
                    controller.focus()
                }
            if controller.errorCount > 0 {
                Button { controller.quoteErrors() } label: {
                    Label("\(controller.errorCount)", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .fixedSize()
                .help("This page has errors. Click to quote them in your agent.")
            }
            Button { controller.startPicking() } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.picking ? Color.accentColor : .secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help("Pick something on the page and quote it in your agent")
            .accessibilityLabel("Pick on Page")
            .accessibilityAddTraits(controller.picking ? .isSelected : [])
            Button {
                controller.toggleForceDark()
            } label: {
                Image(systemName: controller.forceDarkActive ? "moon.fill" : "moon")
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.forceDarkActive ? Color.accentColor : .secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(controller.forceDarkActive ? "Forced dark is on" : "Force dark mode on this page")
            .accessibilityLabel(controller.forceDarkActive ? "True Colors" : "Show Dark")
            OpenElsewhereButton(page: controller, path: filePath)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .tiriBar()
        .overlay(alignment: .bottom) { Divider() }
    }

    private func navigationButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .faint)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Find

struct FindBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @FocusState private var replaceFocused: Bool

    private var canReplace: Bool {
        model.find.flatMap { model.existingController(for: $0.targetItem)?.supportsReplace } ?? false
    }

    /// `3 of 14`, where it's known, and `No results` when it's none.
    private var status: String? {
        guard let find = model.find else { return nil }
        if let replaced = find.replacedCount { return replaced == 1 ? "Replaced 1" : "Replaced \(replaced)" }
        if find.query.isEmpty { return nil }
        if find.notFound || find.total == 0 { return "No results" }
        guard let total = find.total else { return nil }
        return find.current > 0 ? "\(find.current) of \(total)" : "\(total) found"
    }

    var body: some View {
        @Bindable var model = model
        let query = Binding(
            get: { model.find?.query ?? "" },
            set: { value in
                model.find?.query = value
                model.runFind(incremental: true)
            })
        let replacement = Binding(
            get: { model.find?.replacement ?? "" },
            set: { model.find?.replacement = $0 })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if canReplace {
                    Button { model.find?.showReplace.toggle() } label: {
                        Image(systemName: model.find?.showReplace == true ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Replace (\(model.shortcutSymbol(for: "findReplace") ?? "⌥⌘F"))")
                    .accessibilityLabel(model.find?.showReplace == true ? "Hide Replace" : "Show Replace")
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                TextField("Find", text: query)
                    .textFieldStyle(.plain)
                    .frame(width: 190)
                    .focused($focused)
                    .onSubmit {
                        let goesBack = model.find.flatMap { model.existingController(for: $0.targetItem)?.findReturnGoesBackwards } ?? false
                        model.runFind(backwards: NSEvent.modifierFlags.contains(.shift) != goesBack)
                        focused = true
                    }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if canReplace {
                    Button {
                        model.find?.caseSensitive.toggle()
                        model.runFind(incremental: true)
                    } label: {
                        Text("Aa").font(.system(size: 12, weight: model.find?.caseSensitive == true ? .bold : .regular))
                            .foregroundStyle(model.find?.caseSensitive == true ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Match Case")
                    .accessibilityLabel("Match Case")
                }
                Button { model.runFind(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous Match")
                Button { model.runFind() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next Match")
                Button { model.closeFind() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
            }
            if canReplace, model.find?.showReplace == true {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 12, height: 1)
                    TextField("Replace", text: replacement)
                        .textFieldStyle(.plain)
                        .frame(width: 190)
                        .focused($replaceFocused)
                        .onSubmit {
                            model.replaceCurrentMatch()
                            replaceFocused = true
                        }
                    Button("Replace") { model.replaceCurrentMatch() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("All") { model.replaceAllMatches() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.return, modifiers: [.command, .option])
                        .help("Replace All (⌥⌘↩)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .tiriGlass(in: .rect(cornerRadius: 16))
        .onAppear {
            if (model.find?.replaceFocusNonce ?? 0) > 0 { replaceFocused = true } else { focused = true }
        }
        .onChange(of: model.find?.focusNonce) { focused = true }
        .onChange(of: model.find?.replaceFocusNonce) { replaceFocused = true }
    }
}

// MARK: - Banners and toasts

struct ChromeOverlays: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                HStack(spacing: 10) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(banner.isError ? .orange : .accentColor)
                    Text(banner.message)
                        .lineLimit(3)
                        .font(.callout)
                    if banner.opensPrivacySettings {
                        Button("Open Settings") { model.openPrivacySettings() }
                            .tiriGlassButton()
                            .controlSize(.small)
                    }
                    Button("Dismiss") { model.banner = nil }
                        .tiriGlassButton()
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .tiriGlass(in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(banner.isError ? "Problem" : "Notice")
                .transition(AccessibilityDisplay.shared.slide(from: .top))
            }
            if let palette = model.palette {
                // One palette replacing another is a new one. A text field being typed in keeps
                // what's in it otherwise, whatever it's told.
                PaletteView(palette: palette)
                    .id(ObjectIdentifier(palette))
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { ToastStack() }
        .overlay { if model.yourTiri.isMarking { ChangeMarkingOverlay().ignoresSafeArea() } }
    }
}

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(model.toasts) { toast in
                    HStack(spacing: 10) {
                        Image(systemName: toast.symbol).foregroundStyle(toast.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(toast.title).font(.callout.weight(.medium)).lineLimit(1)
                            if let detail = toast.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(width: textWidth(toast), alignment: .leading)
                        if let title = toast.otherTitle {
                            Button(title) {
                                toast.otherAction?()
                                model.dismissToast(toast.id)
                            }
                            .tiriGlassButton()
                            .controlSize(.small)
                        }
                        if let title = toast.actionTitle {
                            Button(title) {
                                toast.action?()
                                model.dismissToast(toast.id)
                            }
                            .tiriGlassButton()
                            .controlSize(.small)
                        }
                        Button {
                            toast.closed?()
                            model.dismissToast(toast.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .tiriGlass(in: .rect(cornerRadius: 14))
                    .accessibilityElement(children: .contain)
                    .transition(AccessibilityDisplay.shared.slide(from: .trailing))
                }
            }
        }
        .padding(14)
    }

    /// As wide as what it says, up to a limit, with no room left over after the X.
    private func textWidth(_ toast: AppToast) -> CGFloat {
        let title = (toast.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)]).width
        let detail = ((toast.detail ?? "") as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        // Buttons leave less room, which the detail can wrap into. The title has one line, so a
        // question is never cut short of what it asks.
        let room: CGFloat = toast.actionTitle == nil ? 300 : toast.otherTitle == nil ? 220 : 190
        return max(min(title, 300), min(detail, room)).rounded(.up) + 1
    }
}

// MARK: - Dragging a tab

struct TabDragOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let drag = model.tabDrag {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .global).origin
                ZStack(alignment: .topLeading) {
                    if let rect = highlightRect(drag.target) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.18))
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
                            .animation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.12)), value: rect)
                    }
                    Text(drag.title)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .tiriGlass(in: .capsule)
                        .offset(x: drag.location.x - origin.x + 8, y: drag.location.y - origin.y + 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .allowsHitTesting(false)
        }
    }

    private func highlightRect(_ target: TabDropTarget?) -> CGRect? {
        guard let target else { return nil }
        let registry = model.layoutRegistry
        switch target {
        case .tabBar(let group, _):
            return registry.barFrames[group]
        case .center(let group):
            return registry.contentFrames[group]
        case .edge(let group, let direction):
            guard let frame = registry.contentFrames[group] else { return nil }
            switch direction {
            case .left: return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
            case .right: return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
            case .up: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
            case .down: return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
            }
        }
    }
}

/// Above a notebook: run it or stop it, and what's running it.
private struct NotebookBar: View {
    let viewer: MarkdownController
    let kernel: NotebookKernel
    @Environment(AppModel.self) private var model

    private var status: String {
        switch kernel.state {
        case .off: kernel.title ?? "Kernel"
        case .finding: "Finding Python…"
        case .starting: "Starting…"
        case .reconnecting: "Reconnecting…"
        case .stopped: "Stopped"
        case .idle, .busy: kernel.question != nil ? "Waiting for input" : kernel.title ?? "Kernel"
        }
    }

    var body: some View {
        if kernel.isActive {
            Button {
                kernel.interrupt()
            } label: {
                Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Interrupt the kernel")
        } else {
            Button {
                viewer.runAllCells()
            } label: {
                Label("Run All", systemImage: "play.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Run every cell, top to bottom")
        }
        Menu {
            Button("Restart Kernel") { kernel.restart() }.disabled(!kernel.hasKernel)
            Button("Shut Down Kernel") { kernel.stop() }.disabled(!kernel.hasKernel)
            Divider()
            Button("Clear All Outputs") { viewer.clearOutputs() }
            Button("Add Code Cell") { viewer.addCell(kind: .code) }
            Button("Add Markdown Cell") { viewer.addCell(kind: .markdown) }
            Button("Delete Cell") { viewer.deleteCurrentCell() }
            Divider()
            Button("Choose Python…") { model.notebookKernels.chooseKernel(for: viewer.path) }
        } label: {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(kernel.pythonPath ?? "Which Python runs this notebook")
    }
}
