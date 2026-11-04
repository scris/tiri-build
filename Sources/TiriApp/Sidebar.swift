import AppKit
import SwiftUI
import TiriCore

/// Workspace switcher, then the multi-root tree, then the open items.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var itemsHeight: CGFloat = 180
    @State private var dragStart: CGFloat?

    // Which sections are open is remembered across launches.
    @AppStorage(SidebarSection.explorer.rawValue) private var explorerOpen = true
    @AppStorage(SidebarSection.changes.rawValue) private var changesOpen = true
    @AppStorage(SidebarSection.items.rawValue) private var itemsOpen = true
    @AppStorage(SidebarSection.agents.rawValue) private var agentsOpen = true
    @AppStorage(SidebarSection.review.rawValue) private var reviewOpen = true

    var body: some View {
        GeometryReader { geometry in
        // With the explorer folded, what's still open takes the room it left.
        // In a repository, always: with everything committed, a branch and its commits are still there to read.
        let hasChangesSection = model.barHasRepositories || !model.changes.isEmpty || !model.offeredTurns.isEmpty
        let rowHeight: CGFloat = {
            if case .recentCommits = model.changesScope { return 37 }
            if case .otherWork = model.changesScope { return 37 }
            return 25
        }()
        let changesFill = !explorerOpen && changesOpen && hasChangesSection
        let itemsFill = !explorerOpen && !changesFill && itemsOpen
        VStack(spacing: 0) {
            WorkspaceSwitcher()
            sectionHeader("Explorer", isOpen: $explorerOpen) {
                // With no folder there's nowhere to put one.
                if !model.active.folders.isEmpty {
                    Button { model.fileTree.beginCreating(.file, in: nil) } label: { Image(systemName: "doc.badge.plus") }
                        .help("New File")
                    Button { model.fileTree.beginCreating(.folder, in: nil) } label: { Image(systemName: "folder.badge.plus") }
                        .help("New Folder")
                }
                Button { model.addFolderInteractive() } label: { Image(systemName: "plus") }
                    .help("Add Folder to Workspace")
            }
            if model.active.folders.isEmpty {
                if explorerOpen {
                    NoFoldersView()
                        .frame(maxHeight: .infinity)
                }
            } else {
                // Stays alive while folded, so it keeps what's expanded and where it's scrolled.
                FileTreeRepresentable(controller: model.fileTree)
                    .frame(maxHeight: explorerOpen ? .infinity : 0)
                    .opacity(explorerOpen ? 1 : 0)
                    .allowsHitTesting(explorerOpen)
                    .clipped()
            }
            if hasChangesSection {
                Divider()
                sectionHeader("Changes", isOpen: $changesOpen) {
                    ChangesScopeMenu()
                    Text("\(model.visibleChangesCount)")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                if changesOpen {
                    if let turn = model.scopedTurn {
                        TurnCaption(turn: turn)
                    } else if case .branch = model.changesScope, !model.branchBases.isEmpty {
                        BranchCaption(bases: model.branchBases)
                    } else if case .commit(let commit) = model.changesScope {
                        CommitCaption(commit: commit)
                    } else if case .work(let work) = model.changesScope {
                        WorkCaption(work: work)
                    }
                    if !model.otherWork.isEmpty, model.changesScope != .otherWork {
                        if case .work = model.changesScope {} else { OtherWorkHint() }
                    }
                    if changesFill {
                        ChangesList()
                            .frame(maxHeight: .infinity)
                    } else {
                        ChangesList()
                            .frame(height: min(CGFloat(max(model.visibleChangesCount, 1)) * rowHeight + 6, max(geometry.size.height * 0.28, 60)))
                    }
                }
            }
            if !model.active.review.isEmpty {
                Divider()
                sectionHeader("Review", isOpen: $reviewOpen) {
                    ReviewHeaderActions()
                }
                if reviewOpen {
                    ReviewList()
                        .frame(height: min(CGFloat(model.active.review.count) * 41 + 6, max(geometry.size.height * 0.28, 60)))
                }
            }
            if explorerOpen, itemsOpen {
                resizeHandle
            } else {
                Divider()
            }
            let agents = model.agentRows
            if !agents.isEmpty {
                sectionHeader("Agents", isOpen: $agentsOpen) {
                    Button { model.openConversationPicker() } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Past Conversations (⇧⌘H)")
                    Text("\(agents.count)")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                if agentsOpen {
                    AgentOverviewList(rows: agents)
                }
                Divider()
            }
            sectionHeader("Open Items", isOpen: $itemsOpen) {
                Text("\(model.active.items.count)")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            if itemsOpen {
                if itemsFill {
                    OpenItemsList()
                        .frame(maxHeight: .infinity)
                } else {
                    OpenItemsList()
                        // On a short window the tree still gets most of the room.
                        .frame(height: min(itemsHeight, max(geometry.size.height * 0.3, 60)))
                }
            }
            if !explorerOpen, !changesFill, !itemsFill {
                Spacer(minLength: 0)
            }
        }
        }
    }

    private var resizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.rowResize.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? itemsHeight
                            if dragStart == nil { dragStart = start }
                            itemsHeight = min(max(start - value.translation.height, 60), 520)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }

    private func sectionHeader<Actions: View>(_ title: String, isOpen: Binding<Bool>, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isOpen.wrappedValue ? "Fold \(title)" : "Unfold \(title)")
            .help(isOpen.wrappedValue ? "Fold \(title)" : "Unfold \(title)")
            Spacer()
            actions()
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 26)
    }
}

enum SidebarSection: String {
    case agents = "sidebar.agents"
    case explorer = "sidebar.explorerOpen"
    case changes = "sidebar.changesOpen"
    case items = "sidebar.itemsOpen"
    case review = "sidebar.reviewOpen"

    private var isOpen: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
    func open() { UserDefaults.standard.set(true, forKey: rawValue) }
    func toggle() { UserDefaults.standard.set(!isOpen, forKey: rawValue) }
}

struct NoFoldersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Text("No folders in this workspace")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Folder…") { model.addFolderInteractive() }
                .buttonStyle(.glass)
            Button("Import .code-workspace…") { model.importWorkspaceInteractive() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("WORKSPACES")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New Workspace…") { model.newWorkspaceInteractive() }
                    Button("Connect to Server…") { model.connectToServerInteractive() }
                    Button("Import .code-workspace…") { model.importWorkspaceInteractive() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .help("New Workspace")
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceRow(workspace: workspace, index: index)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: min(CGFloat(model.workspaces.count) * 29, 150))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    let index: Int
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var isActive: Bool { workspace.id == model.activeID }

    /// A connection that's down shows here too, since its terminals may be behind this workspace.
    private var connectionTint: Color? {
        guard let host = workspace.remote else { return nil }
        switch model.remote.state(of: host) {
        case .reconnecting, .connecting: return .orange
        case .failed: return .red
        case .ready, .idle: return nil
        }
    }

    var body: some View {
        let counts = model.unseenCount(in: workspace)
        HStack(spacing: 8) {
            Image(systemName: workspace.remote != nil ? "server.rack" : workspace.folders.count > 1 ? "square.stack.3d.up.fill" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(connectionTint ?? (isActive ? Color.accentColor : .secondary))
                .frame(width: 16)
            Text(workspace.name)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if counts.needsInput > 0 {
                AttentionBadge(count: counts.needsInput, color: .orange)
            }
            if counts.done > 0 {
                AttentionBadge(count: counts.done, color: .green)
            }
            if hovering, index < 9 {
                Text("⌃\(index + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.switchWorkspace(workspace.id) }
        .contextMenu {
            Button("Rename…") { model.promptRenameWorkspace(workspace.id) }
            Divider()
            Button("Delete…", role: .destructive) { model.confirmDeleteWorkspace(workspace.id) }
        }
        .help(workspace.folders.map { model.prettyPath($0) }.joined(separator: "\n"))
    }
}

struct AttentionBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(color, in: .capsule)
    }
}

struct OpenItemsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(model.active.items) { item in
                    OpenItemRow(item: item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

struct OpenItemRow: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var isActive: Bool { model.active.focused.active == item.id }
    private var runtime: TerminalRuntime? { model.runtimes[item.id] }

    private var statusText: String? {
        guard let runtime else { return nil }
        switch runtime.status {
        case .working: return "working"
        case .needsInput: return "needs input"
        case .done: return "done"
        case .exited: return "exited"
        case .idle: return nil
        }
    }

    var body: some View {
        let _ = model.controllerRevision
        HStack(spacing: 7) {
            ItemIcon(item: item)
                .font(.system(size: 11))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title(for: item))
                    .font(.system(size: 12.5))
                    .italic(item.isPreview)
                    .strikethrough(item.filePath.map(model.deletedFiles.contains) ?? false)
                    .lineLimit(1)
                if let message = runtime?.message, runtime?.status == .needsInput || runtime?.status == .done {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.requestClose(item.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if let statusText {
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(runtime?.status == .needsInput ? Color.orange : .secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(ClickOrDrag(item: item.id, title: model.title(for: item)) { _ in
            model.focusItem(item.id)
        })
    }
}

/// Every agent, in every workspace, and what it's up to, so that's one glance rather than a walk
/// through the tabs. Only what the agents report: nothing here is guessed from their screens.
struct AgentOverviewList: View {
    let rows: [AppModel.AgentOverviewRow]

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(rows) { row in
                    AgentOverviewRowView(row: row)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .frame(maxHeight: min(CGFloat(rows.count) * 46 + 8, 200))
    }
}

struct AgentOverviewRowView: View {
    let row: AppModel.AgentOverviewRow
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    /// What it just did, or what it said when it stopped, and where.
    private var detail: String {
        var parts: [String] = []
        if !row.isInActiveWorkspace { parts.append(row.workspace) }
        if let doing = row.doing, row.status == .working || row.message == nil { parts.append(doing) } else if let message = row.message { parts.append(message) }
        if !row.files.isEmpty { parts.append(row.files.count == 1 ? "1 file" : "\(row.files.count) files") }
        return parts.isEmpty ? row.agent : parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusIcon: some View {
        switch row.status {
        case .working: ProgressView().controlSize(.mini)
        case .needsInput: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .exited: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .idle: Image(systemName: row.symbol).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            statusIcon
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.prompt ?? row.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.focusItem(row.item) }
        .help(row.agent + (row.files.isEmpty ? "" : ": " + row.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")))
    }
}
