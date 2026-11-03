import AppKit
import SwiftUI
import TiriCore

/// The Peek: a file from an agent's session, floating over the session.
///
/// Every other tool makes you choose between a new tab and nothing. This shows you the file
/// without changing your layout, and it takes one button to keep it. It sits on the
/// right so the terminal's list of files stays visible and clickable beside it.
struct PeekView: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @AppStorage("peekWidthFraction") private var widthFraction = 0.6
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = min(max(geometry.size.width * widthFraction, 380), geometry.size.width - 24)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel
                    .frame(width: width)
                    .overlay(alignment: .leading) { resizeHandle(total: geometry.size.width) }
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ItemHost(itemID: item.id, group: nil)
                .background(Color(nsColor: TerminalTheme.background(dark: model.effectiveDark)))
                .overlay(alignment: .topTrailing) {
                    if let find = model.find, find.targetItem == item.id {
                        FindBar().padding(10)
                    }
                }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        }
        // Glass on the frame only: what you're reading stays opaque.
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.32), radius: 26, y: 10)
        .reportingFrame { frame in
            model.layoutRegistry.peekFrame = frame
        }
        .onDisappear {
            if model.active.peek == nil { model.layoutRegistry.peekFrame = nil }
        }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                ItemIcon(item: item)
                    .font(.system(size: 12))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.title(for: item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if case .web = item.content, let web = model.controller(for: item.id) as? WebController {
                    PeekWebControls(controller: web)
                }
                if let path = item.filePath {
                    FileActions(item: item, path: path)
                } else if case .diff(let spec) = item.content {
                    FileActions(item: item, path: spec.path)
                }
                Button {
                    model.promotePeek(split: .right)
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                }
                .buttonStyle(.glass)
                .help("Open to the Side (⌥⌘↩)")

                Button {
                    model.promotePeek()
                } label: {
                    // The main action of the Peek keeps its words until there's truly no room.
                    ViewThatFits(in: .horizontal) {
                        Label("Open as Tab", systemImage: "plus.rectangle.on.rectangle")
                            .fixedSize()
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                }
                .buttonStyle(.glassProminent)
                .layoutPriority(1)
                .help("Open as Tab (⌘↩)")

                Button {
                    model.dismissPeek()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .help(model.peekHasKeyboard ? "Close (esc)" : "Close")
            }
            .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    private var detail: String? {
        switch item.content {
        case .file(let spec):
            let relative = model.active.relativePath(spec.path)
            let directory = (relative as NSString).deletingLastPathComponent
            return directory.isEmpty ? model.active.folder(containing: spec.path).map { ($0 as NSString).lastPathComponent }
                                     : (directory as NSString).abbreviatingWithTildeInPath
        case .web(let spec):
            return spec.url
        case .diff(let spec):
            let relative = model.active.relativePath(spec.path)
            let directory = (relative as NSString).deletingLastPathComponent
            return directory.isEmpty ? "changes" : directory + " · changes"
        case .terminal, .settings:
            return nil
        }
    }

    private func resizeHandle(total: CGFloat) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: -4)
            .onHover { inside in
                if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartFraction ?? widthFraction
                    if dragStartFraction == nil { dragStartFraction = start }
                    widthFraction = min(max(start - Double(value.translation.width / max(total, 1)), 0.3), 0.97)
                }
                .onEnded { _ in dragStartFraction = nil })
    }
}

/// A page in a Peek has to be able to go back and reload, the same as one in a tab.
struct PeekWebControls: View {
    @Bindable var controller: WebController

    var body: some View {
        HStack(spacing: 4) {
            Button { controller.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!controller.canGoBack)
                .help("Back")
            Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!controller.canGoForward)
                .help("Forward")
            Button {
                if controller.isLoading { controller.webView.stopLoading() } else { controller.reload() }
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(controller.isLoading ? "Stop" : "Reload (⌘R)")
        }
        .buttonStyle(.glass)
    }
}
