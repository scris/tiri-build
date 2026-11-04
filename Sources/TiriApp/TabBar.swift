import AppKit
import SwiftUI
import TiriCore
import UniformTypeIdentifiers

/// An item's icon. Terminals show their live status instead.
struct ItemIcon: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item.content {
        case .terminal:
            TerminalStatusIcon(runtime: model.runtimes[item.id] ?? TerminalRuntime())
        case .file(let spec):
            Image(systemName: FileIcons.symbolName(forName: (spec.path as NSString).lastPathComponent, isDirectory: false))
                .foregroundStyle(.secondary)
        case .web:
            Image(systemName: "globe").foregroundStyle(.secondary)
        case .settings:
            Image(systemName: "gearshape").foregroundStyle(.secondary)
        case .diff:
            Image(systemName: "plus.forwardslash.minus").foregroundStyle(.secondary)
        }
    }
}

struct TerminalStatusIcon: View {
    let runtime: TerminalRuntime

    var body: some View {
        switch runtime.status {
        case .idle:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        case .working:
            Image(systemName: "circle.dotted.circle")
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .help("Working")
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help(runtime.message ?? "Needs input")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(runtime.message ?? "Done")
        case .exited:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .help(runtime.exitCode.map { "Exited with code \($0)" } ?? "Exited")
        }
    }
}

struct TabBar: View {
    let group: TabGroup
    @Environment(AppModel.self) private var model
    private var isFocusedGroup: Bool { model.active.focusedGroup == group.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element) { index, id in
                        if let item = model.active.item(id) {
                            HStack(spacing: 0) {
                                if showInsertMarker(before: index) { insertMarker }
                                TabView(item: item, group: group, isActive: group.active == id, isFocusedGroup: isFocusedGroup)
                                if index == group.tabs.count - 1, showInsertMarker(before: index + 1) { insertMarker }
                            }
                            .id(id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .onChange(of: group.active) { _, new in
                if let new { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(new) } }
            }
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            // Dragging a file from the tree or Finder onto a tab bar opens it there.
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let path = url?.path else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let model = AppModel.shared
                            model.updateActive { $0.focusGroup(id: group.id) }
                            model.open(path: path, intent: .pinned)
                            model.requestFocus()
                        }
                    }
                }
            }
            return true
        }
    }

    private func showInsertMarker(before index: Int) -> Bool {
        if case .tabBar(let target, let position) = model.tabDrag?.target {
            return target == group.id && position == index
        }
        return false
    }

    private var insertMarker: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 20)
            .padding(.horizontal, 1)
    }
}

struct TabView: View {
    let item: Item
    let group: TabGroup
    let isActive: Bool
    let isFocusedGroup: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var owner = UUID()

    private var runtime: TerminalRuntime? { model.runtimes[item.id] }
    private var title: String {
        let _ = model.controllerRevision
        return model.title(for: item)
    }

    var body: some View {
        HStack(spacing: 6) {
            ItemIcon(item: item)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12))
                .italic(item.isPreview)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .foregroundStyle(isActive ? .primary : .secondary)
            // Always holds its room, so tabs don't move as the mouse crosses them.
            ZStack { closeOrDot }
                .frame(width: 14, height: 14)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(backgroundFill)
        }
        .overlay {
            if isActive, isFocusedGroup, model.active.groups.count > 1 {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(ClickOrDrag(item: item.id, title: title) { clickCount in
            model.focusItem(item.id)
            if clickCount >= 2 { model.updateActive { $0.pin(item.id) } }
        })
        .contextMenu { TabContextMenu(item: item, group: group) }
        .reportingFrame { frame in
            // A tab that just moved has an outgoing view in its old group. Only the view in the
            // group that holds the item now gets to say where it is.
            if model.active.group(containing: item.id)?.id == group.id {
                model.layoutRegistry.setTab(item.id, frame: frame, owner: owner)
            }
        }
        .onDisappear { model.layoutRegistry.removeTab(item.id, owner: owner) }
    }

    private var backgroundFill: Color {
        if isActive { return Color.primary.opacity(0.11) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    @ViewBuilder
    private var closeOrDot: some View {
        if hovering {
            Button {
                model.requestClose(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (⌘W)")
        } else if model.existingController(for: item.id)?.isDirty == true {
            Circle()
                .fill(Color.primary.opacity(0.7))
                .frame(width: 7, height: 7)
                .help("Unsaved changes")
        } else if runtime?.unseen == true {
            // The attention dot: something happened here you haven't seen.
            Circle()
                .fill(runtime?.status == .needsInput ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
        }
    }
}

struct TabContextMenu: View {
    let item: Item
    let group: TabGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Close") { model.requestClose(item.id) }
        Button("Close Others") {
            for id in group.tabs where id != item.id { model.requestClose(id) }
        }
        if let index = group.tabs.firstIndex(of: item.id), index < group.tabs.count - 1 {
            Button("Close to the Right") {
                for id in group.tabs[(index + 1)...] { model.requestClose(id) }
            }
        }
        Divider()
        if item.isPreview {
            Button("Keep Open") { model.updateActive { $0.pin(item.id) } }
        }
        if model.detachedItems.contains(item.id) {
            Button("Bring Back to This Window") { model.bringBack(item.id) }
        } else {
            Button("Move to New Window") { model.moveToNewWindow(item.id) }
        }
        Button("Split Right") {
            model.focusItem(item.id)
            model.splitActive(.right)
        }
        Button("Split Down") {
            model.focusItem(item.id)
            model.splitActive(.down)
        }
        if let path = item.filePath {
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(RemoteRegistry.shared.displayPath(path), forType: .string)
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.active.relativePath(path), forType: .string)
            }
            Button("Reveal in Explorer") { model.revealOrOffer(path: path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Open in External Editor") { model.openExternally(path: path) }
        }
        if case .terminal = item.content, model.runtimes[item.id]?.status == .exited {
            Divider()
            Button("Restart") { (model.existingController(for: item.id) as? TerminalController)?.restart() }
        }
    }
}

/// One gesture that decides between a click and a drag by how far the mouse moved. Separate tap,
/// double-tap and drag gestures on the same view compete, and an active tab stopped dragging.
struct ClickOrDrag: ViewModifier {
    let item: ItemID
    let title: String
    let onClick: (_ clickCount: Int) -> Void
    @Environment(AppModel.self) private var model
    @State private var dragging = false

    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if dragging || moved > 5 {
                    dragging = true
                    model.updateTabDrag(item: item, title: title, location: value.location)
                }
            }
            .onEnded { _ in
                if dragging {
                    dragging = false
                    model.endTabDrag()
                } else {
                    onClick(NSApp.currentEvent?.clickCount ?? 1)
                }
            })
    }
}
