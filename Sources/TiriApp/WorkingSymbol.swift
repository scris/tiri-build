import AppKit
import QuartzCore
import SwiftUI

/// The working sign: a dotted circle that turns, in the accent color.
///
/// SwiftUI's `.symbolEffect(.rotate, options: .repeat(.continuous))` has the app redraw its window for every frame
/// the symbol turns. With agents working in the tabs on screen, that was about 12% of a core for Tiri, plus
/// WindowServer's share, for as long as they worked (measured 2026-11-08, on a 60 Hz display; more at 120 Hz).
/// Here the symbol is drawn once and Core Animation turns its layer in the render server, so Tiri does nothing
/// per frame.
struct WorkingSymbol: NSViewRepresentable {
    var turning: Bool

    func makeNSView(context: Context) -> WorkingSymbolView { WorkingSymbolView() }

    func updateNSView(_ view: WorkingSymbolView, context: Context) {
        let environment = context.environment
        view.show(
            font: environment.font ?? .body,
            color: Color.accentColor.resolve(in: environment),
            scale: environment.displayScale,
            turning: turning
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkingSymbolView, context: Context) -> CGSize? {
        nsView.symbolSize
    }
}

final class WorkingSymbolView: NSView {
    private let symbol = CALayer()
    private(set) var symbolSize = CGSize(width: 12, height: 12)
    private var drawn: (font: Font, color: Color.Resolved, scale: CGFloat)?
    private var turning = false
    private static let turn = "turn"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(symbol)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { symbolSize }

    // Clicks belong to the tab or row around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbol.bounds = CGRect(origin: .zero, size: symbolSize)
        symbol.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    // A layer can lose its animations while out of a window, as a tab being dragged is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTurning()
    }

    func show(font: Font, color: Color.Resolved, scale: CGFloat, turning: Bool) {
        if drawn == nil || drawn!.font != font || drawn!.color != color || drawn!.scale != scale {
            draw(font: font, color: color, scale: scale)
        }
        self.turning = turning
        applyTurning()
    }

    private func draw(font: Font, color: Color.Resolved, scale: CGFloat) {
        let renderer = ImageRenderer(content: Image(systemName: "circle.dotted.circle").font(font).foregroundStyle(Color(color)))
        renderer.scale = max(scale, 1)
        guard let image = renderer.cgImage else { return }
        drawn = (font, color, scale)
        symbolSize = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbol.contents = image
        symbol.contentsScale = renderer.scale
        CATransaction.commit()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyTurning() {
        guard turning, window != nil else {
            symbol.removeAnimation(forKey: Self.turn)
            return
        }
        guard symbol.animation(forKey: Self.turn) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise, as SF Symbols turn: a layer's positive angle goes the other way.
        animation.fromValue = 0
        animation.toValue = -2 * Double.pi
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // A small, slow turn looks the same at 30 frames a second, and a 120 Hz display would otherwise be redrawn
        // four times as often.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        symbol.add(animation, forKey: Self.turn)
    }
}
