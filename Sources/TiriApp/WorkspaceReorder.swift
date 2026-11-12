import SwiftUI
import TiriCore

/// The workspace being dragged in the sidebar's list, and where it's held. Every row reads it, so
/// the rows it passes can step aside.
@MainActor
@Observable
final class WorkspaceDrag {
    static let shared = WorkspaceDrag()
    /// One row and the gap under it.
    static let rowPitch: Double = 29

    var id: WorkspaceID?
    var from = 0
    var to = 0
    var translation: Double = 0
}

/// Lets a workspace row be dragged up and down its list to reorder it. A click still switches.
struct WorkspaceDragReorder: ViewModifier {
    let id: WorkspaceID
    let index: Int
    @Environment(AppModel.self) private var model
    private var drag: WorkspaceDrag { .shared }

    private var isDragged: Bool { drag.id == id }

    private var offset: Double {
        guard drag.id != nil else { return 0 }
        if isDragged { return drag.translation }
        return Double(ListReorder.shift(of: index, from: drag.from, to: drag.to)) * WorkspaceDrag.rowPitch
    }

    func body(content: Content) -> some View {
        content
            .opacity(isDragged ? 0.85 : 1)
            .shadow(color: .black.opacity(isDragged ? 0.25 : 0), radius: 4, y: 1)
            .offset(y: offset)
            .zIndex(isDragged ? 1 : 0)
            .animation(isDragged ? nil : .easeOut(duration: 0.15), value: offset)
            .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { value in
                    let count = model.workspaces.count
                    if drag.id == nil {
                        guard count > 1, let from = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
                        drag.from = from
                        drag.to = from
                        drag.id = id
                    }
                    guard drag.id == id else { return }
                    let pitch = WorkspaceDrag.rowPitch
                    drag.translation = ListReorder.clamped(translation: value.translation.height, from: drag.from, rowHeight: pitch, count: count)
                    drag.to = ListReorder.target(from: drag.from, translation: drag.translation, rowHeight: pitch, count: count)
                }
                .onEnded { _ in
                    guard drag.id == id else { return }
                    // Everything lands where it already appears to be, so nothing should slide again.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        model.moveWorkspace(id, to: drag.to)
                        drag.id = nil
                        drag.translation = 0
                    }
                })
    }
}

extension AppModel {
    /// Puts a workspace at `index` in the list, as the sidebar shows it. The order is saved.
    func moveWorkspace(_ id: WorkspaceID, to index: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }), from != index, workspaces.indices.contains(index) else { return }
        workspaces = ListReorder.moved(workspaces, from: from, to: index)
        scheduleSave()
    }
}
