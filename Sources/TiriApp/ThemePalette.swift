import AppKit
import SwiftTerm
import TiriCore

/// The colors terminals and the editor paint with. With no theme chosen it's Tiri's own, which follows light and dark
/// through the system's colors. Each color here is one AppKit asks for again whenever it draws, so changing the theme
/// only needs a redraw, not a new attribute on every word of every open file.
nonisolated enum ThemePalette {
    /// The chosen theme, or nil for Tiri's own. Set on the main thread; read while drawing.
    nonisolated(unsafe) static var current: Theme?
    /// Increase Contrast, for the colors that fall back to the system's: faint ones get less faint.
    nonisolated(unsafe) static var increaseContrast = false

    static func color(_ hex: String) -> NSColor {
        let color = ThemeColor(hex) ?? .black
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func dynamic(_ pick: @escaping @Sendable (Theme) -> NSColor, otherwise: @escaping @Sendable (Bool) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if let theme = current { return pick(theme) }
            return otherwise(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }

    // MARK: The editor

    static let editorBackground = dynamic({ color($0.editor.background) }, otherwise: { _ in .textBackgroundColor })
    static let editorForeground = dynamic({ color($0.editor.foreground) }, otherwise: { _ in .labelColor })
    static let lineNumber = dynamic({ color($0.editor.foreground).withAlphaComponent(0.4) }, otherwise: { _ in increaseContrast ? .secondaryLabelColor : .tertiaryLabelColor })
    static let currentLineNumber = dynamic({ color($0.editor.foreground).withAlphaComponent(0.7) }, otherwise: { _ in .secondaryLabelColor })
    static let currentLine = dynamic({ color($0.editor.foreground).withAlphaComponent(0.055) }, otherwise: { _ in NSColor.labelColor.withAlphaComponent(0.055) })
    static let editorSelection = dynamic({ color($0.editor.selection) }, otherwise: { _ in .selectedTextBackgroundColor })
    static let editorCursor = dynamic({ color($0.editor.cursor) }, otherwise: { _ in .textInsertionPointColor })

    /// Code colors by kind, in `TokenKind` order.
    static let tokens: [NSColor] = {
        func fixed(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> @Sendable (Bool) -> NSColor {
            { isDark in
                let (red, green, blue) = isDark ? dark : light
                return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            }
        }
        return [
            editorForeground,
            dynamic({ color($0.editor.comment) }, otherwise: { _ in .secondaryLabelColor }),
            dynamic({ color($0.editor.string) }, otherwise: fixed((0.09, 0.48, 0.2), (0.45, 0.83, 0.56))),
            dynamic({ color($0.editor.number) }, otherwise: fixed((0.6, 0.4, 0), (0.9, 0.75, 0.48))),
            dynamic({ color($0.editor.keyword) }, otherwise: fixed((0.53, 0.2, 0.68), (0.78, 0.57, 0.92))),
            dynamic({ color($0.editor.function) }, otherwise: fixed((0.1, 0.34, 0.75), (0.51, 0.71, 0.98))),
            dynamic({ color($0.editor.type) }, otherwise: fixed((0.03, 0.44, 0.47), (0.42, 0.82, 0.82))),
            dynamic({ color($0.editor.attribute) }, otherwise: fixed((0.65, 0.27, 0.07), (0.93, 0.62, 0.47))),
        ]
    }()

    // MARK: Terminals

    static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let color = ThemeColor(hex) ?? .black
        func channel(_ value: Double) -> UInt16 { UInt16((value * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(color.red), green: channel(color.green), blue: channel(color.blue))
    }
}
