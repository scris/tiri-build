import AppKit
import SwiftUI
import TiriCore

/// Tiri running from a disk image, or from Downloads where macOS runs it from a temporary place, can't be updated.
/// Rather than fetch an update that could never go in, it says so, and offers to move itself, as LetsMove does.
enum MoveToApplications {
    /// Where the installed app is, and what keeps an update from going there, if anything.
    static func problem() -> InstallPlace.Problem? {
        InstallPlace.problem(appPath: CopyState.load()?.plainPath ?? Bundle.main.bundlePath)
    }

    /// A test copy moves only into the folder its test names, and never into the real Applications.
    private static var destinationFolder: URL? {
        if AppModel.isTestCopy {
            guard let folder = ProcessInfo.processInfo.environment["TIRI_DEV_APPLICATIONS"], !folder.isEmpty else { return nil }
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if access(system.path, W_OK) == 0 { return system }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Says why there's no update from here, with the move one click away when it would help.
    @MainActor static func offer(_ problem: InstallPlace.Problem, model: AppModel) {
        let canMove = problem.isMovable && !model.yourTiri.isPersonalCopy && destinationFolder != nil
        model.showToast(title: String(localized: "Tiri can't update from here"), detail: problem.shown, symbol: "arrow.down.app", tint: .orange,
                        actionTitle: canMove ? String(localized: "Move to Applications") : nil, duration: 20) {
            if canMove { move(model: model) }
        }
    }

    @MainActor private static func move(model: AppModel) {
        guard let folder = destinationFolder else { return }
        let source = Bundle.main.bundleURL
        let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        let moving = model.showToast(title: String(localized: "Moving Tiri to Applications…"), detail: nil, symbol: "arrow.down.app", tint: .secondary, duration: 60)
        Task {
            let failure: String? = await Task.detached {
                let manager = FileManager.default
                try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
                // One already there is an older Tiri: it goes to the Trash, where it can be got back.
                if manager.fileExists(atPath: destination.path) {
                    do { try manager.trashItem(at: destination, resultingItemURL: nil) } catch { return "\(error.localizedDescription)" }
                }
                let copied = Tool.run("/usr/bin/ditto", [source.path, destination.path])
                guard copied.ok else { return copied.output.trimmingCharacters(in: .whitespacesAndNewlines) }
                // It was opened once already. Left quarantined, macOS would run it from a temporary place again.
                Tool.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
                return nil
            }.value
            model.dismissToast(moving)
            if let failure {
                model.showToast(title: String(localized: "Couldn't move Tiri"), detail: failure, symbol: "exclamationmark.triangle", tint: .orange)
                return
            }
            // The copy that opens next notes where it is, and updates go there.
            if !model.relaunch(app: destination.path) {
                model.showToast(title: String(localized: "Couldn't restart Tiri"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
    }
}
