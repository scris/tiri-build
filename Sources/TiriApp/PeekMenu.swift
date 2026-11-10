import AppKit
import SwiftUI
import TiriCore

/// Everything a tab's menu does, for a file that isn't a tab yet: where to put it, and what its path is good for.
/// It's behind the Peek's title, and a right-click anywhere on its header.
struct PeekMenu: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.waitingFor.contains(item.id) {
            Button("Done") { model.finishWaiting(item.id) }
        } else {
            Button("Open as Tab") { model.promotePeek() }
            Button("Open to the Side") { model.promotePeek(split: .right) }
            Button("Open Below") { model.promotePeek(split: .down) }
            Button("Move to New Window") {
                model.promotePeek()
                model.moveToNewWindow(item.id)
            }
        }
        if let path = item.filePath ?? diffPath {
            Divider()
            FilePathMenu(path: path)
        }
        if case .web = item.content, let url = (model.existingController(for: item.id) as? WebController)?.addressForBrowser {
            Divider()
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Open in \(DefaultBrowser.name)") { model.movePageToBrowser(item.id) }
        }
        Divider()
        Button("Close Peek") { model.dismissPeek() }
    }

    private var diffPath: String? {
        if case .diff(let spec) = item.content { return spec.path }
        return nil
    }
}

/// What a file's path is good for, the same in a tab's menu and a Peek's.
struct FilePathMenu: View {
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RemoteRegistry.shared.displayPath(path), forType: .string)
        }
        Button("Copy Relative Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(here.active.relativePath(path), forType: .string)
        }
        Button("Reveal in Explorer") { model.revealOrOffer(path: path) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Button("Open in External Editor") { model.openExternally(path: path) }
    }
}

/// A Peek's header has no room for words beside its glyphs: "Changes" broke over two lines there.
extension EnvironmentValues {
    @Entry var fileActionsAreGlyphs = false
}

/// A file action's label: its word and glyph above a tab's file, the glyph alone in a Peek's header.
struct FileActionLabel: LabelStyle {
    @Environment(\.fileActionsAreGlyphs) private var glyphs

    func makeBody(configuration: Configuration) -> some View {
        if glyphs {
            configuration.icon.font(.system(size: 12))
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title.lineLimit(1).fixedSize()
            }
        }
    }
}
