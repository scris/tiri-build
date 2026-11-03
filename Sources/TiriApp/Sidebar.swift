import AppKit
import SwiftUI
import TiriCore

/// Workspace switcher, then the multi-root tree, then the open items.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var itemsHeight: CGFloat = 180
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            WorkspaceSwitcher()
            sectionHeader("Explorer") {
                Button { model.fileTree.beginCreating(.file, in: nil) } label: { Image(systemName: "doc.badge.plus") }
                    .help("New File")
                Button { model.fileTree.beginCreating(.folder, in: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help("New Folder")
                Button { model.addFolderInteractive() } label: { Image(systemName: "plus") }
                    .help("Add Folder to Workspace")
            }
            if model.active.folders.isEmpty {
                NoFoldersView()
                    .frame(maxHeight: .infinity)
            } else {
                FileTreeRepresentable(controller: model.fileTree)
                    .frame(maxHeight: .infinity)
            }
            resizeHandle
            sectionHeader("Open Items") {
                Text("\(model.active.items.count)")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            OpenItemsList()
                // On a short window the tree still gets most of the room.
                .frame(height: min(itemsHeight, max(geometry.size.height * 0.3, 60)))
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

    private func sectionHeader<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            actions()
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }
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

    var body: some View {
        let counts = model.unseenCount(in: workspace)
        HStack(spacing: 8) {
            Image(systemName: workspace.folders.count > 1 ? "square.stack.3d.up.fill" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
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
        .help(workspace.folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
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
