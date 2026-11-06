import AppKit
import SwiftUI

/// Reduce Transparency, Increase Contrast and Reduce Motion, read once for the whole app and kept
/// current when they change in System Settings. SwiftUI's own environment values only follow the
/// Mac's switches, so everything Tiri paints itself asks here instead, which a test copy can also
/// pretend with `TIRI_DEV_A11Y` (see scripts/dev-app.sh) without changing this Mac's settings.
@MainActor
@Observable
final class AccessibilityDisplay {
    static let shared = AccessibilityDisplay()

    /// Sent after any of them changes, for the AppKit views that hold their look.
    static let didChange = Notification.Name("TiriAccessibilityDisplayDidChange")

    private(set) var reduceTransparency = false
    private(set) var increaseContrast = false
    private(set) var reduceMotion = false

    /// What a test copy pretends on top of the Mac's own settings.
    private var pretended: Set<String> = []

    private init() {
        if AppModel.isTestCopy {
            pretended = Self.parse(ProcessInfo.processInfo.environment["TIRI_DEV_A11Y"] ?? "")
        }
        read()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AccessibilityDisplay.shared.read() }
        }
    }

    private static func parse(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() })
    }

    private func read() {
        let workspace = NSWorkspace.shared
        // On a Mac, turning on Increase Contrast turns on Reduce Transparency too.
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast || pretended.contains("contrast")
        let transparency = workspace.accessibilityDisplayShouldReduceTransparency || pretended.contains("transparency") || contrast
        let motion = workspace.accessibilityDisplayShouldReduceMotion || pretended.contains("motion")
        guard (transparency, contrast, motion) != (reduceTransparency, increaseContrast, reduceMotion) else { return }
        reduceTransparency = transparency
        increaseContrast = contrast
        reduceMotion = motion
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A test copy changing what it pretends, the way a change in System Settings arrives.
    func pretendForTest(_ list: String) {
        guard AppModel.isTestCopy else { return }
        pretended = Self.parse(list)
        read()
    }

    var pretendedForTest: [String] { pretended.sorted() }

    // MARK: Motion

    /// An animation, or none with Reduce Motion.
    func motion(_ animation: Animation) -> Animation? { reduceMotion ? nil : animation }

    /// Moving in from an edge, or only fading with Reduce Motion.
    func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    // MARK: Speaking

    /// The last few things said to VoiceOver, so a test copy can check them without it.
    private(set) var spoken: [String] = []

    /// Says something to VoiceOver that appeared without the keyboard going there, like a toast.
    /// Nothing is heard when VoiceOver is off.
    func announce(_ text: String, interrupting: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if AppModel.isTestCopy {
            spoken.append(text)
            if spoken.count > 20 { spoken.removeFirst() }
        }
        // Posted to the app, as VoiceOver expects for an announcement, a moment later so it isn't cut off by the change that caused it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: (interrupting ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Liquid glass, or with Reduce Transparency an opaque surface with an edge, so nothing behind
    /// shows through. Increase Contrast adds a clear border either way.
    func tiriGlass<S: Shape>(in shape: S) -> some View {
        modifier(TiriGlass(shape: shape))
    }

    /// The toolbar-like strip under tabs and panels: the system's bar material, or solid.
    func tiriBar() -> some View {
        modifier(TiriBarBackground())
    }

    /// A material behind a small card or capsule, or solid with Reduce Transparency.
    func tiriMaterial<S: Shape>(in shape: S) -> some View {
        modifier(TiriMaterial(shape: shape))
    }

    /// `.glass` for a button on a glass surface, or the plain bordered look on a solid one.
    func tiriGlassButton(prominent: Bool = false) -> some View {
        modifier(TiriGlassButton(prominent: prominent))
    }

    /// Marks what's current, a tab or a row, with a fill. With Increase Contrast the fill is
    /// stronger and gets an outline, since a faint grey is the only thing telling it apart.
    func currentMark(_ isCurrent: Bool, hovering: Bool = false, cornerRadius: CGFloat, strength: Double = 0.1) -> some View {
        modifier(CurrentMark(isCurrent: isCurrent, hovering: hovering, cornerRadius: cornerRadius, strength: strength))
    }

    /// A row pressed with the mouse, made one element VoiceOver can name and press.
    func accessibleRow(_ label: String, value: String? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

private struct TiriGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        let display = AccessibilityDisplay.shared
        if display.reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.stroke(display.increaseContrast ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1) }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct TiriBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if AccessibilityDisplay.shared.reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content.background(.bar)
        }
    }
}

private struct TiriMaterial<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        let display = AccessibilityDisplay.shared
        if display.reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { if display.increaseContrast { shape.stroke(Color.primary.opacity(0.6), lineWidth: 1) } }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct TiriGlassButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        switch (AccessibilityDisplay.shared.reduceTransparency, prominent) {
        case (true, false): content.buttonStyle(.bordered)
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, false): content.buttonStyle(.glass)
        case (false, true): content.buttonStyle(.glassProminent)
        }
    }
}

private struct CurrentMark: ViewModifier {
    let isCurrent: Bool
    let hovering: Bool
    let cornerRadius: CGFloat
    let strength: Double

    func body(content: Content) -> some View {
        let contrast = AccessibilityDisplay.shared.increaseContrast
        content.background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            if isCurrent {
                shape.fill(Color.primary.opacity(contrast ? strength * 2 : strength))
                    .overlay { if contrast { shape.strokeBorder(Color.primary.opacity(0.7), lineWidth: 1) } }
            } else if hovering {
                shape.fill(Color.primary.opacity(contrast ? 0.1 : 0.05))
            }
        }
    }
}

// MARK: - Text

extension ShapeStyle where Self == HierarchicalShapeStyle {
    /// `.tertiary`, or `.secondary` with Increase Contrast, for faint text that still says something.
    static var faint: HierarchicalShapeStyle {
        MainActor.assumeIsolated { AccessibilityDisplay.shared.increaseContrast } ? .secondary : .tertiary
    }
}

extension NSColor {
    /// The tertiary label color, or the secondary one with Increase Contrast.
    @MainActor static var faintLabel: NSColor {
        AccessibilityDisplay.shared.increaseContrast ? .secondaryLabelColor : .tertiaryLabelColor
    }
}
