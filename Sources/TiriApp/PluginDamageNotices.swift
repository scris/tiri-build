import SwiftUI
import TiriCore

extension PluginHost {
    /// A plugin file of Tiri's that couldn't be read is said once, when it's found. Its bytes are
    /// already kept beside it by then.
    func listenForDamagedFiles() {
        PluginDamagedFiles.listen { [weak self] notice in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.damaged(notice) }
            }
        }
    }

    private func damaged(_ notice: PluginDamagedFiles.Notice) {
        let kept = notice.keptAt.map { "kept at \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "left where it is, and not saved over"
        switch notice.kind {
        case .settings(let name):
            PluginProcesses.log(name, "Its settings file couldn't be read, so its settings are back to their defaults. The old file is \(kept).\n")
            let title = plugin(named: name)?.title ?? name
            model.showToast(title: String(localized: "Couldn't read \(title)'s settings"), detail: String(localized: "They're back to their defaults. The old file is kept."),
                            symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
        case .approvals:
            model.showToast(title: String(localized: "Couldn't read which plugins you approved"),
                            detail: String(localized: "Those it couldn't read are off until you turn them on again. The old file is kept."),
                            symbol: "exclamationmark.shield", tint: .orange, duration: 12)
        }
    }
}
