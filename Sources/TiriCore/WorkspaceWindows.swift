import Foundation

/// A window and the workspace it shows. Saved, so windows come back where they were after a relaunch.
public struct SavedWindow: Codable, Equatable, Sendable {
    /// `main` for the first window, which is always there. Any other is made up when the window opens.
    public var id: String
    public var workspace: WorkspaceID
    /// x, y, width and height on screen, as AppKit measures them.
    public var frame: [Double]?

    public init(id: String, workspace: WorkspaceID, frame: [Double]? = nil) {
        self.id = id
        self.workspace = workspace
        self.frame = frame
    }
}

/// The rules for which window shows which workspace. A terminal's view can only be in one place, so a
/// workspace is in one window at most.
public enum WindowPlan {
    public static let main = "main"

    /// What to open at launch: the main window first, then each other saved window whose workspace still exists
    /// and isn't already showing. The main window shows what it showed, or else `active`.
    public static func restore(_ saved: [SavedWindow], workspaces: [WorkspaceID], active: WorkspaceID) -> [SavedWindow] {
        let known = Set(workspaces)
        var shown: Set<WorkspaceID> = []
        var main = saved.first { $0.id == Self.main } ?? SavedWindow(id: Self.main, workspace: active)
        if !known.contains(main.workspace) { main.workspace = known.contains(active) ? active : (workspaces.first ?? active) }
        shown.insert(main.workspace)
        var result = [main]
        var ids: Set<String> = [Self.main]
        for placement in saved where placement.id != Self.main && known.contains(placement.workspace) && !shown.contains(placement.workspace) {
            guard ids.insert(placement.id).inserted else { continue }
            shown.insert(placement.workspace)
            result.append(placement)
        }
        return result
    }

    /// A workspace for a window that needs one: the most recently shown of those no window has, `preferring` first.
    /// Nil when every workspace is in a window already, and a new one has to be made.
    public static func unshown(_ workspaces: [WorkspaceID], shown: Set<WorkspaceID>, preferring: WorkspaceID? = nil) -> WorkspaceID? {
        if let preferring, workspaces.contains(preferring), !shown.contains(preferring) { return preferring }
        return workspaces.first { !shown.contains($0) }
    }

    /// The window showing a workspace, if one is.
    public static func window(showing workspace: WorkspaceID, in windows: [String: WorkspaceID]) -> String? {
        // Main first, then the rest in a fixed order, so the answer doesn't depend on a dictionary's.
        if windows[Self.main] == workspace { return Self.main }
        return windows.filter { $0.value == workspace }.keys.sorted().first
    }
}
