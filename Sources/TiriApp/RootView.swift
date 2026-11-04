import AppKit
import SwiftUI
import TiriCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 270, max: 460)
            } detail: {
                DetailView()
                    .toolbar { MainToolbar() }
            }
            .navigationTitle(model.active.name)
            .navigationSubtitle(subtitle)
            .background(WindowAccessor { window in model.windowDidAppear(window) })
            .overlay(alignment: .top) { ChromeOverlays() }
            .overlay { TabDragOverlay() }
            StatusBar()
        }
    }

    private var subtitle: String {
        let folders = model.active.folders
        switch folders.count {
        case 0: return ""
        case 1: return (folders[0] as NSString).abbreviatingWithTildeInPath
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

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // One button, one menu. Its size and shape match the buttons beside it.
            Menu {
                ForEach(model.settings.activePresets) { preset in
                    if model.active.folders.count > 1 {
                        Menu(preset.name) {
                            ForEach(model.active.folders, id: \.self) { folder in
                                Button(folderLabel(folder)) { model.newTerminal(command: preset.command, cwd: folder) }
                            }
                        }
                    } else {
                        Button(preset.name) { model.startTerminal(command: preset.command) }
                    }
                }
                Divider()
                Button("Manage Agents…") { model.openAgentSettings() }
            } label: {
                Label("New Terminal", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .help("New terminal or agent")

            Button { model.chooseFilesForAgent() } label: {
                Label("Add Files or Images to Agent", systemImage: "paperclip")
            }
            .help("Add files or images to your agent (⇧⌘L)")

            Button { model.splitActive(.right) } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .help("Split Right (⌘\\)")

            Button { model.splitActive(.down) } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .help("Split Down (⌘K ⌘\\)")
        }
    }
}

extension MainToolbar {
    /// Two folders can share a name, and the choice decides where an agent works.
    private func folderLabel(_ folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        let shared = model.active.folders.filter { ($0 as NSString).lastPathComponent == name }.count > 1
        return shared ? (folder as NSString).abbreviatingWithTildeInPath : name
    }
}

// MARK: - Detail: panes plus the floating Peek

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .trailing) {
            PaneNodeView(node: model.active.layout)
                .background(Color(nsColor: TerminalTheme.background(dark: model.effectiveDark)))
            if let peek = model.active.peek {
                PeekView(item: peek)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .id(peek.id)
            }
        }
        .animation(.smooth(duration: 0.22), value: model.active.peek?.id)
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
                            model.updateActive { $0.setRatios(splitID: split.id, ratios: ratios) }
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
    @State private var owner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                TabBar(group: group)
            }
            if let activeID = group.active, let item = model.active.item(activeID) {
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

    final class Host: NSView {
        weak var installed: NSView?
        private static var created = 0
        let serial: Int
        var ownsInstalledItem: (() -> Bool)?

        override init(frame: NSRect) {
            Self.created += 1
            serial = Self.created
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            autoresizesSubviews = false
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
            installed?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> Host {
        Host()
    }

    func updateNSView(_ host: Host, context: Context) {
        if let group { model.groupHosts[group] = AppModel.WeakView(view: host) }
        // A view on its way out (a Peek fading after being promoted, a tab that just moved) still
        // gets updated. It must not pull the viewer back from where the item lives now.
        let owns = { [model, group, itemID, isDetached] () -> Bool in
            if model.detachedItems.contains(itemID) { return isDetached }
            if let group { return model.active.group(id: group)?.active == itemID }
            return model.active.peek?.id == itemID
        }
        guard owns(), model.accessReady, let controller = model.controller(for: itemID) else { return }
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
            let isFocusTarget = model.peekHasKeyboard ? model.active.peek?.id == itemID
                                                      : model.active.focused.active == itemID
            // A single click in the tree previews the file and leaves the keyboard in the tree,
            // so arrow keys can keep browsing and Enter can rename.
            let browsingTree = model.window?.firstResponder is TreeOutlineView
            if isFocusTarget, model.palette == nil, !browsingTree { model.requestFocus() }
        }
    }
}

struct EmptyGroupView: View {
    @Environment(AppModel.self) private var model

    private func row(_ title: String, _ command: String) -> some View {
        HStack(spacing: 24) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(model.shortcutSymbol(for: command) ?? "")
                .foregroundStyle(.tertiary)
                .font(.system(.body, design: .default).monospacedDigit())
        }
        .frame(width: 240)
    }

    var body: some View {
        Group {
            if model.active.folders.isEmpty {
                start
            } else {
                VStack(spacing: 22) {
                    agentButtons
                    VStack(spacing: 8) {
                        row("Open a file", "quickOpen")
                        row("New terminal", "newTerminal")
                        row("All commands", "commandPalette")
                        row("Toggle sidebar", "toggleSidebar")
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

    /// One folder or none: the button starts the agent, asking for a folder first if it has to.
    /// Several: it asks which, as the toolbar's + does.
    @ViewBuilder
    private var agentButtons: some View {
        let presets = model.runnableAgentPresets()
        if !presets.isEmpty {
            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    if model.active.folders.count > 1 {
                        Menu(preset.name) {
                            ForEach(model.active.folders, id: \.self) { folder in
                                Button((folder as NSString).lastPathComponent) { model.newTerminal(command: preset.command, cwd: folder) }
                            }
                        }
                        .fixedSize()
                    } else {
                        Button(model.active.folders.isEmpty ? preset.name + "…" : preset.name) {
                            model.startTerminal(command: preset.command)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .controlSize(.large)
        }
    }

    private var start: some View {
        let noneOn = model.agentPresets().isEmpty
        let noAgents = model.availableCommands != nil && model.runnableAgentPresets().isEmpty
        return VStack(spacing: 16) {
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
                    .buttonStyle(.glassProminent)
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
                agentButtons
            }
            HStack(spacing: 18) {
                Button("Shell…") { model.startTerminal() }
                Button("Just Open a Folder…") {
                    model.chooseFolderForActiveWorkspace { _ in }
                }
            }
            .buttonStyle(.link)
        }
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
                .foregroundStyle(.tertiary)
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

    var body: some View {
        switch item.content {
        case .terminal, .settings:
            EmptyView()
        case .file(let spec):
            if model.accessReady, let web = model.controller(for: item.id) as? WebController {
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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct FileActions: View {
    let item: Item
    let path: String
    @Environment(AppModel.self) private var model

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
        if case .diff = item.content, let diff = model.controller(for: item.id) as? DiffController {
            if diff.diff.additions + diff.diff.deletions > 0 {
                HStack(spacing: 4) {
                    Text("+\(diff.diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.diff.deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
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
        if case .file = item.content, model.hasChanges(path) {
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
        if model.accessReady, let document = model.controller(for: item.id) as? ForceDarkCapable, document.supportsForceDark {
            Button {
                model.setForceDark(!document.forceDarkActive, item: item.id)
            } label: {
                Image(systemName: document.forceDarkActive ? "moon.fill" : "moon")
            }
            .buttonStyle(.plain)
            .foregroundStyle(document.forceDarkActive ? Color.accentColor : .secondary)
            .help(document.forceDarkActive ? "Showing dark. Click for true colors" : "Show this document dark")
        }
        if model.accessReady, let markdown = model.controller(for: item.id) as? MarkdownController {
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
            .help(markdown.showingSource ? "Show rendered markdown" : "Show markdown source")
        }
        Button {
            model.openExternally(path: path, line: nil, col: nil)
        } label: {
            Label("Open in External Editor", systemImage: "arrow.up.forward.square")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open in External Editor")
    }
}

struct Breadcrumbs: View {
    let path: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let parts = crumbs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                }
            }
        }
    }

    private var crumbs: [(name: String, path: String)] {
        // The path within its workspace folder. Files elsewhere show their full path.
        var result: [(String, String)] = []
        if let folder = model.active.folder(containing: path) {
            result.append(((folder as NSString).lastPathComponent, folder))
            var current = folder
            for component in path.dropFirst(folder.count).split(separator: "/") {
                current += "/" + component
                result.append((String(component), current))
            }
        } else {
            var current = ""
            let abbreviated = (path as NSString).abbreviatingWithTildeInPath
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
            if let filePath {
                Button { model.openExternally(path: filePath) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .help("Open in External Editor")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func navigationButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Find

struct FindBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let binding = Binding(
            get: { model.find?.query ?? "" },
            set: { value in
                model.find?.query = value
                model.runFind()
            })
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: binding)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .focused($focused)
                .onSubmit { model.runFind(backwards: NSEvent.modifierFlags.contains(.shift)) }
            if model.find?.notFound == true {
                Text("No results").font(.caption).foregroundStyle(.secondary)
            }
            Button { model.runFind(backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
            Button { model.runFind() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
            Button { model.closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .onChange(of: model.find?.focusNonce) { focused = true }
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
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    Button("Dismiss") { model.banner = nil }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let palette = model.palette {
                PaletteView(palette: palette)
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { ToastStack() }
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
                        VStack(alignment: .leading, spacing: 1) {
                            Text(toast.title).font(.callout.weight(.medium)).lineLimit(1)
                            if let detail = toast.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        if let title = toast.actionTitle {
                            Button(title) {
                                toast.action?()
                                model.dismissToast(toast.id)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        Button { model.dismissToast(toast.id) } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 380, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(14)
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
                            .animation(.smooth(duration: 0.12), value: rect)
                    }
                    Text(drag.title)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
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
