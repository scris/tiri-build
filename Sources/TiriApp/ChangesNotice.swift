import SwiftUI
import TiriCore

/// Why the Changes list isn't the whole story: a repository with more changes than anyone reads, or
/// a git too slow to answer. Neither is the same as nothing changed.
enum ChangesNotice: Equatable {
    case limited(Int)
    case slow

    /// How long one look at the changes may take.
    nonisolated static let timeout: Double = 20

    /// After a look: the notice it calls for, and when to look again. A git that timed out leaves the list
    /// as it was, and is asked again later each time it does, up to five minutes. Past the limit, as VS Code
    /// does, files changing don't start another look: each would read ten thousand changes again for a list
    /// nobody reads that far. Opening Changes or clicking the notice does.
    static func record(_ scan: ChangesScan, in live: WorkspaceLive) {
        let notice: ChangesNotice?
        if scan.timedOut {
            live.changesBackoff = min(max(live.changesBackoff * 2, 30), 300)
            live.changesQuietUntil = Date().addingTimeInterval(live.changesBackoff)
            notice = .slow
        } else {
            live.changesBackoff = 0
            live.changesQuietUntil = nil
            notice = scan.limited ? .limited(scan.files.count) : nil
        }
        live.changesPaused = scan.limited
        if live.changesNotice != notice { live.changesNotice = notice }
    }

    /// The count beside Changes: "10,000+" when that's only the first of them.
    static func count(_ model: WindowModel) -> String {
        if model.changesScope == .sinceCommit, case .limited(let shown) = model.live.changesNotice { return shown.formatted() + "+" }
        return "\(model.visibleChangesCount)"
    }
}

extension AppModel {
    /// Asked for, so whatever was holding looks back doesn't.
    func refreshChangesNow(_ id: WorkspaceID) {
        guard let live = lives[id] else { return }
        live.changesPaused = false
        live.changesQuietUntil = nil
        refreshChanges(id)
    }
}

struct ChangesNoticeRow: View {
    let notice: ChangesNotice
    @Environment(AppModel.self) private var app
    @Environment(\.windowScope) private var scope

    var body: some View {
        Button {
            app.refreshChangesNow(WindowModel(app: app, scope: scope).activeID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: notice == .slow ? "hourglass" : "line.3.horizontal.decrease").font(.system(size: 9))
                switch notice {
                case .limited(let count): Text("Showing the first \(count) changes")
                case .slow: Text("Git is taking too long here")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Look Again")
        .padding(.horizontal, 16)
        .padding(.bottom, 3)
    }
}
