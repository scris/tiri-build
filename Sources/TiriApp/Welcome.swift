import AppKit
import SwiftUI
import TiriCore

/// Hello, once, on a new install: one screen, three small drawings of what nobody finds alone, and a way out.
/// Everything else is learned where it happens, from tips that go away by themselves.
@MainActor
enum Welcome {
    private static let shownKey = "welcomeShown"

    /// After launch, never as part of it. Someone who used Tiri before this existed has seen Tiri already.
    static func showIfNew(model: AppModel, isNewInstall: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)
        // A test copy has its own home and shows this only when asked to.
        let environment = ProcessInfo.processInfo.environment
        let isTestCopy = environment["TIRI_HOME"] != nil && environment["TIRI_DEV_WELCOME"] == nil
        guard isNewInstall, !isTestCopy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { show(model: model) }
    }

    /// Help → Welcome to Tiri, any time.
    static func show(model: AppModel) {
        guard let window = model.window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let close = { [weak window, weak sheet] in
            guard let sheet else { return }
            window?.endSheet(sheet)
        }
        // Someone coming from Cursor or VS Code can bring their setup with them, here, once.
        let editor = model.editorsToImport().first?.editor
        let bringIn = editor.map { editor in { [weak model] in
            close()
            model?.importFromEditor(editor)
        } }
        sheet.contentViewController = NSHostingController(rootView: WelcomeView(showsChange: model.yourTiri.entriesAreOn, importFrom: editor?.name,
                                                                                bringIn: bringIn, close: close))
        window.beginSheet(sheet)
    }
}

private struct WelcomeView: View {
    let showsChange: Bool
    let importFrom: String?
    let bringIn: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Tiri")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Keep your agent. Get everything around it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                WelcomeFrame(caption: "⌘-click any path", detail: "The file floats over the session") { PeekDrawing() }
                WelcomeFrame(caption: "Every agent at a glance", detail: "The one that needs you is marked") { WorkspacesDrawing() }
                if showsChange {
                    WelcomeFrame(caption: "It improves itself", detail: "Ask, and your agent rewrites it") { SayDrawing() }
                }
            }
            HStack {
                if let importFrom, let bringIn {
                    Button("Bring In My \(importFrom) Setup", action: bringIn)
                        .controlSize(.large)
                }
                Spacer()
                Button("Start", action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: showsChange ? 600 : 430)
        .onExitCommand(perform: close)
    }
}

private struct WelcomeFrame<Drawing: View>: View {
    let caption: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let drawing: Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MiniWindow { drawing }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A terminal's lines, one of them a path underlined as ⌘ shows it, and the file floating over the corner.
private struct PeekDrawing: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 40, height: 3)
                HStack(spacing: 3) {
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: 12, height: 3)
                    Text(verbatim: "notes.md")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.accentColor).frame(height: 1).offset(y: 1.5) }
                }
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 30, height: 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array([30, 22, 26].enumerated()), id: \.offset) { _, width in
                    Capsule().fill(Color.primary.opacity(0.28)).frame(width: CGFloat(width), height: 2.5)
                }
            }
            .padding(6)
            .background(.background, in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.2) }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .offset(x: 2, y: 2)
        }
    }
}

/// Three tasks, side by side in the sidebar's way: one working, one done, one waiting on you.
private struct WorkspacesDrawing: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(Color.accentColor, width: 34, highlighted: true)
            row(Color.green, width: 26, highlighted: false)
            row(Color.orange, width: 40, highlighted: false)
        }
    }

    private func row(_ dot: Color, width: CGFloat, highlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Capsule().fill(Color.primary.opacity(highlighted ? 0.32 : 0.18)).frame(width: width, height: 3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(highlighted ? 0.08 : 0), in: .rect(cornerRadius: 4))
    }
}

/// On the path itself, the first time there is one: how to open it. It never waits to be closed.
struct PeekTipChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: "⌘")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.12), in: .rect(cornerRadius: 3.5))
            Text("click to Peek")
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .tiriMaterial(in: .capsule)
        .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command-click a path to Peek at it")
    }
}

/// Tips are shown once each, at the moment they apply, and leave by themselves.
@MainActor
enum Tips {
    static var peekShown: Bool {
        get { UserDefaults.standard.bool(forKey: "tip.peek") }
        set { UserDefaults.standard.set(newValue, forKey: "tip.peek") }
    }

    /// For the terminal, which is AppKit's.
    static func peekChip() -> NSView { NSHostingView(rootView: PeekTipChip()) }
}
