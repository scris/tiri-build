import SwiftUI
import TiriCore

/// In place of the changes when a folder is a repository and this Mac has no git yet. Apple's installer only ever
/// comes up from this button, never from Tiri looking at a folder.
struct NeedsGitRow: View {
    @Environment(AppModel.self) private var model
    @State private var installing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            Text(installing ? String(localized: "Installing Apple's tools…") : String(localized: "Changes need Git, from Apple's free tools"))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !installing {
                Button("Install") { install() }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func install() {
        installing = true
        Task.detached { Tool.run("/usr/bin/xcode-select", ["--install"]) }
        // Apple's installer takes minutes and says nothing to Tiri when it's done.
        Task { @MainActor in
            for _ in 0..<360 {
                try? await Task.sleep(for: .seconds(10))
                if await Task.detached(operation: { DeveloperTools.git != nil }).value { break }
            }
            installing = false
            model.refreshChanges()
        }
    }
}
