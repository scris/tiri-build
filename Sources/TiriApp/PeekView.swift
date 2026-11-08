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
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }
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
        .tiriGlass(in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek")
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.32), radius: 26, y: 10)
        .reportingFrame { frame in
            if here.isCurrent { model.layoutRegistry.peekFrame = frame }
        }
        .onDisappear {
            if here.isCurrent, model.active.peek == nil { model.layoutRegistry.peekFrame = nil }
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
                // What the content can do: quiet glyphs, so the way to keep it is the one thing that stands out.
                HStack(spacing: 10) {
                    if case .web = item.content, let web = model.controller(for: item.id) as? WebController {
                        PeekWebControls(controller: web)
                        OpenElsewhereButton(page: web, path: nil)
                    }
                    if let path = item.filePath {
                        FileActions(item: item, path: path)
                    } else if case .diff(let spec) = item.content {
                        FileActions(item: item, path: spec.path)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .controlSize(.regular)
                .padding(.trailing, 6)
                if model.waitingFor.contains(item.id) {
                    // Something is waiting for this file back, like git or Claude Code's Ctrl-G. Keeping it isn't the point.
                    Button {
                        model.finishWaiting(item.id)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Done", systemImage: "checkmark")
                                .fixedSize()
                            Image(systemName: "checkmark")
                        }
                    }
                    .tiriGlassButton(prominent: true)
                    .layoutPriority(1)
                    .help("Done (⌘↩)")
                } else {
                    Button {
                        model.promotePeek(split: .right)
                    } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                    }
                    .tiriGlassButton()
                    .help("Open to the Side (⌥⌘↩)")
                    .accessibilityLabel("Open to the Side")

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
                    .tiriGlassButton(prominent: true)
                    .layoutPriority(1)
                    .help("Open as Tab (⌘↩)")
                }

                Button {
                    model.dismissPeek()
                } label: {
                    Image(systemName: "xmark")
                }
                .tiriGlassButton()
                .help(model.peekHasKeyboard ? String(localized: "Close (esc)") : String(localized: "Close"))
                .accessibilityLabel("Close Peek")
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
            let relative = here.active.relativePath(spec.path)
            let directory = (relative as NSString).deletingLastPathComponent
            return directory.isEmpty ? here.active.folder(containing: spec.path).map { ($0 as NSString).lastPathComponent }
                                     : (directory as NSString).abbreviatingWithTildeInPath
        case .web(let spec):
            return spec.url
        case .diff(let spec):
            let relative = here.active.relativePath(spec.path)
            let directory = (relative as NSString).deletingLastPathComponent
            return directory.isEmpty ? spec.scopeWord : directory + " · " + spec.scopeWord
        case .terminal, .settings, .unknown:
            return nil
        case .plugin(let spec):
            return model.plugins.plugin(named: spec.plugin)?.title
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

/// A page in a Peek has to be able to go back and reload, the same as one in a tab. Back and forward
/// only show when there's somewhere to go: most Peeks are one page.
struct PeekWebControls: View {
    @Bindable var controller: WebController

    var body: some View {
        if controller.canGoBack || controller.canGoForward {
            glyph("chevron.left", String(localized: "Back"), enabled: controller.canGoBack) { controller.goBack() }
            glyph("chevron.right", String(localized: "Forward"), enabled: controller.canGoForward) { controller.goForward() }
        }
        glyph(controller.isLoading ? "xmark" : "arrow.clockwise", controller.isLoading ? String(localized: "Stop") : String(localized: "Reload (⌘R)"), enabled: true) {
            if controller.isLoading { controller.webView.stopLoading() } else { controller.reload() }
        }
    }

    private func glyph(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
