import AppKit
import SwiftUI
import TiriCore
import WebKit

/// Nobody has seen this before, so the first thing it does is show what it is. Three small drawings of Tiri itself,
/// because a sentence about an app rewriting itself means nothing until you've seen it happen.
struct ChangeStory: View {
    let agent: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tiri can rewrite itself for you.")
                .font(.system(size: 15, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                StoryFrame(caption: String(localized: "You say what you want"), detail: String(localized: "In your own words")) { SayDrawing() }
                StoryFrame(caption: String(localized: "\(agent) builds it"), detail: String(localized: "A few minutes. Keep working")) { BuildDrawing() }
                StoryFrame(caption: String(localized: "Tiri reopens with it"), detail: String(localized: "Keep it, or go back")) { TryDrawing() }
            }
        }
    }
}

private struct StoryFrame<Drawing: View>: View {
    let caption: String
    let detail: String
    @ViewBuilder let drawing: Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MiniWindow { drawing }
            VStack(alignment: .leading, spacing: 1) {
                Text(caption).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tiri, very small: a sidebar and a tab. The welcome draws with it too.
struct MiniWindow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(index == 0 ? 0.28 : 0.14)).frame(height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 34)
            .background(Color.primary.opacity(0.05))
            content
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 74)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.13), lineWidth: 1) }
    }
}

struct SayDrawing: View {
    var body: some View {
        Text("“Show how long each agent has been working”")
            .font(.system(size: 9.5))
            .lineLimit(3)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.2), in: .rect(cornerRadius: 6))
    }
}

private struct BuildDrawing: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 34, height: 3)
            }
            ForEach(Array([46, 38, 52].enumerated()), id: \.offset) { index, width in
                HStack(spacing: 3) {
                    Text(verbatim: "+").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                    Capsule().fill(Color.green.opacity(0.45 - Double(index) * 0.08)).frame(width: CGFloat(width), height: 3)
                }
            }
        }
    }
}

private struct TryDrawing: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 24, height: 3)
                Text(verbatim: "3:12")
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Back").padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.12), in: .capsule)
                Text("Keep").foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.accentColor, in: .capsule)
            }
            .font(.system(size: 8.5, weight: .medium))
        }
    }
}

/// Above the palette's list while someone is asking for a change: what this is, and how to say what you mean.
struct ChangePanel: View {
    let palette: PaletteModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let yours = model.yourTiri
        let presets = model.runnableAgentPresets()
        let agent = yours.chosenAgent(from: presets)?.name ?? String(localized: "Your agent")
        VStack(alignment: .leading, spacing: 12) {
            if yours.hasNeverChanged {
                ChangeStory(agent: agent)
            } else {
                Text("\(agent) rewrites Tiri in a new tab. Nothing changes until you try it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            if let mark = yours.mark {
                HStack(spacing: 10) {
                    Image(nsImage: mark.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 54, alignment: .leading)
                        .clipShape(.rect(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                    Text("\(agent) sees this part.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Remove") { yours.clearMark() }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                Button {
                    yours.beginMarking(query: palette.query)
                } label: {
                    Label(yours.mark == nil ? String(localized: "Mark It on Screen") : String(localized: "Mark Again"), systemImage: "viewfinder")
                }
                .controlSize(.small)
                .help("Drag a box around the part of Tiri you mean, so \(agent) can see it.")
                if presets.count > 1 {
                    Menu("With \(agent)") {
                        ForEach(presets, id: \.name) { preset in
                            Button(preset.name) { yours.chooseAgent(preset) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                if yours.hasNeverChanged {
                    Text("Uses your \(agent) account. About 1 GB, the first time")
                        .font(.system(size: 11))
                        .foregroundStyle(.faint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// What's waiting for you about changes, in the bar along the bottom of every workspace, for as long as it's
/// waiting. Nobody goes to Settings to find out, so nothing here needs them to.
struct YourTiriStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let yours = model.yourTiri
        if let waiting = yours.waiting {
            HStack(spacing: 7) {
                if waiting.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: waiting.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(waiting.isTrouble ? Color.orange : Color.accentColor)
                }
                Text(waiting.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 460, alignment: .leading)
                    .help(waiting.text)
                ForEach(waiting.actions) { action in
                    if action.isMain {
                        Button(action.title, action: action.run)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    } else {
                        Button(action.title, action: action.run)
                            .controlSize(.mini)
                    }
                }
                if waiting.laterKey != nil {
                    // Busy now: out of the way, with nothing decided. It comes back, and Change Tiri… has it meanwhile.
                    Button { yours.putOffWaiting() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Later. It's back in a few hours, and in Change Tiri… until then.")
                    .accessibilityLabel("Later")
                }
            }
        }
    }
}

/// Drag a box around what you mean. The window dims, nothing is clickable, and Esc gets you out.
struct ChangeMarkingOverlay: View {
    @Environment(AppModel.self) private var model
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        // The mouse never reaches this: EventRouter takes it first, so the toolbar can't move the window
        // and a click can't close the Peek. This only draws.
        let box = model.yourTiri.markingBox
        GeometryReader { _ in
            ZStack(alignment: .top) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.45)))
                    if let box {
                        context.blendMode = .clear
                        context.fill(Path(box), with: .color(.black))
                        context.blendMode = .normal
                        context.stroke(Path(box), with: .color(.accentColor), lineWidth: 2)
                    }
                }
                .allowsHitTesting(false)
                // Out of the way once a box is started: it may be over the very part being marked.
                if box == nil {
                    Text("Drag a box around the part you mean. Esc cancels.")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .tiriMaterial(in: .capsule)
                        .padding(.top, 64)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear { NSCursor.crosshair.push() }
        .onDisappear { NSCursor.pop() }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onAppear { hasKeyboard = true }
        .onKeyPress(.escape) {
            model.yourTiri.cancelMarking()
            return .handled
        }
    }
}

/// A part of the window, as it looks, without asking macOS for permission to record the screen.
/// What views draw for themselves is all this can see: terminals keep their background in a layer, so that's put
/// back underneath, and web views keep everything to themselves, so they're asked one at a time.
@MainActor
enum WindowPicture {
    /// `box` is measured from the top left of the window's content.
    static func take(_ box: CGRect, of window: NSWindow, done: @escaping (NSImage?) -> Void) {
        guard let content = window.contentView else { return done(nil) }
        // The toolbar is drawn by the frame around the content, so the picture is taken of that frame.
        let root = content.superview ?? content
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return done(nil) }
        root.cacheDisplay(in: root.bounds, to: rep)
        let size = root.bounds.size
        /// From top-left measurements to a view's own, and back: the same flip either way.
        func flip(_ rect: CGRect, in view: NSView) -> CGRect {
            view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let wanted = content.convert(flip(box, in: content), to: root)
        let fromTop = flip(wanted, in: root)
        let webViews = allWebViews(in: content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: root).intersects(wanted) }
        var snapshots: [(CGRect, NSImage)] = []
        var pending = webViews.count
        func finish() {
            let picture = NSImage(size: size)
            picture.lockFocus()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                CGRect(origin: .zero, size: size).fill()
            }
            NSImage(size: size).then { $0.addRepresentation(rep) }.draw(in: CGRect(origin: .zero, size: size))
            // The picture is drawn from the bottom left, whichever way the frame counts.
            for (frame, snapshot) in snapshots { snapshot.draw(in: root.isFlipped ? flip(frame, in: root) : frame) }
            picture.unlockFocus()
            guard let whole = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return done(nil) }
            let drawn = CGFloat(whole.width) / max(size.width, 1)
            let pixels = CGRect(x: fromTop.minX * drawn, y: fromTop.minY * drawn, width: fromTop.width * drawn, height: fromTop.height * drawn)
            done(whole.cropping(to: pixels).map { NSImage(cgImage: $0, size: box.size) })
        }
        if pending == 0 { return finish() }
        for webView in webViews {
            webView.takeSnapshot(with: nil) { snapshot, _ in
                if let snapshot { snapshots.append((webView.convert(webView.bounds, to: root), snapshot)) }
                pending -= 1
                if pending == 0 { finish() }
            }
        }
    }

    private static func allWebViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        for child in view.subviews {
            if let web = child as? WKWebView { found.append(web) } else { found += allWebViews(in: child) }
        }
        return found
    }
}

private extension NSImage {
    func then(_ change: (NSImage) -> Void) -> NSImage {
        change(self)
        return self
    }
}
