import SwiftUI
import TiriCore

/// Where the Run terminal opens, as three drawings of the window: the file, and the terminal in your accent color
/// below it, beside it, or as a tab over it. Picking one is clicking it.
struct RunPlacementPicker: View {
    let selection: RunPlacement
    let choose: (RunPlacement) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(RunPlacement.allCases, id: \.self) { placement in
                RunPlacementTile(placement: placement, isChosen: placement == selection) { choose(placement) }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

private struct RunPlacementTile: View {
    let placement: RunPlacement
    let isChosen: Bool
    let action: () -> Void
    @State private var hovering = false

    private var name: String {
        switch placement {
        case .below: String(localized: "Below")
        case .right: String(localized: "Beside")
        case .tab: String(localized: "Tab")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RunPlacementDrawing(placement: placement)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isChosen ? Color.accentColor : Color.primary.opacity(hovering ? 0.32 : 0.13), lineWidth: isChosen ? 2 : 1)
                    }
                Text(name)
                    .font(.system(size: 12, weight: isChosen ? .medium : .regular))
                    .foregroundStyle(isChosen || hovering ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The window, very small: a sidebar, the file's lines, and the terminal with its prompt.
struct RunPlacementDrawing: View {
    let placement: RunPlacement

    var body: some View {
        Canvas { context, size in draw(&context, size) }
            .aspectRatio(1.55, contentMode: .fit)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            .clipShape(.rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let ink = Color.primary.opacity(0.18)
        let faint = Color.primary.opacity(0.08)
        let accent = Color.accentColor
        func box(_ rect: CGRect, _ color: Color, radius: CGFloat = 1.5) {
            context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
        }
        // The sidebar.
        let side = w * 0.2
        box(CGRect(x: 0, y: 0, width: side, height: h), faint, radius: 0)
        for row in 0..<3 { box(CGRect(x: 5, y: 7 + CGFloat(row) * 7, width: side - 10, height: 2.5), ink) }
        let area = CGRect(x: side, y: 0, width: w - side, height: h)

        func code(in rect: CGRect) {
            let widths: [CGFloat] = [0.62, 0.45, 0.7, 0.38, 0.55]
            for (row, fraction) in widths.enumerated() {
                let y = rect.minY + 7 + CGFloat(row) * 7
                guard y + 3 < rect.maxY - 3 else { break }
                box(CGRect(x: rect.minX + 6 + (row % 2 == 1 ? 5 : 0), y: y, width: (rect.width - 14) * fraction, height: 2.5), ink)
            }
        }
        func terminal(in rect: CGRect) {
            box(rect, accent.opacity(0.18), radius: 0)
            box(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), accent.opacity(0.55), radius: 0)
            let left = rect.minX + 6
            box(CGRect(x: left, y: rect.minY + 6, width: 4, height: 2.5), accent)
            box(CGRect(x: left + 7, y: rect.minY + 6, width: min(rect.width * 0.45, 40), height: 2.5), accent.opacity(0.75))
            box(CGRect(x: left, y: rect.minY + 13, width: min(rect.width * 0.3, 26), height: 2.5), accent.opacity(0.5))
        }

        switch placement {
        case .below:
            let split = area.minY + area.height * 0.56
            code(in: CGRect(x: area.minX, y: area.minY, width: area.width, height: split - area.minY))
            terminal(in: CGRect(x: area.minX, y: split, width: area.width, height: area.maxY - split))
        case .right:
            let split = area.minX + area.width * 0.52
            code(in: CGRect(x: area.minX, y: area.minY, width: split - area.minX, height: area.height))
            terminal(in: CGRect(x: split, y: area.minY, width: area.maxX - split, height: area.height))
        case .tab:
            // Two tabs, the terminal's in front, and it fills the pane.
            let strip: CGFloat = 9
            box(CGRect(x: area.minX + 4, y: 3, width: 18, height: strip - 4), ink)
            box(CGRect(x: area.minX + 25, y: 3, width: 18, height: strip - 4), accent)
            terminal(in: CGRect(x: area.minX, y: strip + 2, width: area.width, height: area.height - strip - 2))
        }
    }
}

/// A command as it reads: its words, with what Tiri fills in shown as small tags, `file` for `$file` and so on.
struct RunCommandText: View {
    let command: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(RunCommandParts.split(command).enumerated()), id: \.offset) { _, part in
                switch part {
                case .words(let text):
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                case .filled(let token):
                    Text(RunCommandParts.label(token))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: .capsule)
                        .padding(.horizontal, 1)
                        .help(RunCommandParts.meaning(token))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

enum RunCommandParts {
    enum Part: Equatable {
        case words(String)
        case filled(String)
    }

    /// The command in pieces: `python3 $file` is "python3 " and file.
    static func split(_ command: String) -> [Part] {
        let pattern = #"\"\$\{?(file|name|dir|path|out)\}?\"|\$\{(file|name|dir|path|out)\}|\$(file|name|dir|path|out)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.words(command)] }
        var parts: [Part] = []
        var last = command.startIndex
        for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
            guard let whole = Range(match.range, in: command),
                  let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }),
                  let word = Range(match.range(at: group), in: command) else { continue }
            if last < whole.lowerBound { parts.append(.words(String(command[last..<whole.lowerBound]))) }
            parts.append(.filled(String(command[word])))
            last = whole.upperBound
        }
        if last < command.endIndex { parts.append(.words(String(command[last...]))) }
        return parts
    }

    static func label(_ token: String) -> String {
        switch token {
        case "file": String(localized: "file")
        case "name": String(localized: "name")
        case "dir": String(localized: "folder")
        case "path": String(localized: "path")
        default: String(localized: "program")
        }
    }

    static func meaning(_ token: String) -> String {
        switch token {
        case "file": String(localized: "The file's name, like two_sum.py")
        case "name": String(localized: "The file's name without its extension, like two_sum")
        case "dir": String(localized: "The file's folder")
        case "path": String(localized: "The file's whole path")
        default: String(localized: "Where the compiled program goes, in /tmp")
        }
    }
}
