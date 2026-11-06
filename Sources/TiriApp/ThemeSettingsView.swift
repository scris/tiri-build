import AppKit
import SwiftUI
import TiriCore

/// Themes in Settings: the theme for the look you're in, as a picture that's also its menu, and its colors to
/// change. Only that one: in light mode the dark theme is nothing to look at. When the Mac turns dark, or Increase
/// Contrast comes on, this shows that look's theme instead.
struct ThemeSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settings.themes.colorsOpen") private var colorsOpen = false
    @State private var bringing = false
    @State private var making = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ThemeSlotCard(slot: model.activeThemeSlot)
                    actions.padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ThemeSlotCard(slot: model.activeThemeSlot)
                    actions
                }
            }
            if colorsOpen { ThemeColorEditor() }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                bringing = true
            } label: {
                Label("Bring a Theme…", systemImage: "square.and.arrow.down")
            }
            .popover(isPresented: $bringing, arrowEdge: .bottom) { BringThemeList { bringing = false } }
            Button {
                making = true
            } label: {
                Label("Make One…", systemImage: "sparkles")
            }
            .popover(isPresented: $making, arrowEdge: .bottom) { MakeThemeWithAgent(slot: model.activeThemeSlot) { making = false } }
            fold("Colors", isOpen: $colorsOpen)
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func fold(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(AccessibilityDisplay.shared.motion(.snappy(duration: 0.2))) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(isOpen.wrappedValue ? "Hide \(title)" : "Show \(title)")
    }
}

/// One look's theme: its picture, and under it which look and which theme. A click offers the others.
struct ThemeSlotCard: View {
    let slot: ThemeSlot
    @Environment(AppModel.self) private var model

    var body: some View {
        let name = model.settings.themeName(for: slot)
        let theme = model.theme(named: name) ?? model.theme(named: Theme.defaultName(for: slot)) ?? .tiriDark
        Menu {
            themeChoices(selected: theme.name)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThemePreview(theme: theme)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(theme.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 220, alignment: .leading)
        .help("The \(slot.title.lowercased()) theme: \(theme.name)")
        .accessibilityLabel("\(slot.title) theme, \(theme.name)")
    }

    private var symbol: String {
        switch slot {
        case .dark: "moon"
        case .light: "sun.max"
        case .highContrastDark: "circle.righthalf.filled"
        case .highContrastLight: "circle.lefthalf.filled"
        }
    }

    @ViewBuilder private func themeChoices(selected: String) -> some View {
        let own = model.userThemes
        Section("Built In") {
            ForEach(Theme.builtIns, id: \.name) { choice($0, selected: selected) }
        }
        if !own.isEmpty {
            Section("Yours") {
                ForEach(own, id: \.name) { choice($0, selected: selected) }
            }
        }
    }

    private func choice(_ theme: Theme, selected: String) -> some View {
        Button {
            model.useTheme(theme.name, for: slot)
        } label: {
            if theme.name == selected {
                Label(theme.name, systemImage: "checkmark")
            } else {
                Text(theme.name)
            }
        }
    }
}

/// A theme as a few lines of code in its own colors, with its terminal colors and accent along the bottom.
struct ThemePreview: View {
    let theme: Theme
    var width: CGFloat = 200
    var height: CGFloat = 92

    private func c(_ hex: String) -> Color { Color(nsColor: ThemePalette.color(hex)) }

    var body: some View {
        let editor = theme.editor
        VStack(alignment: .leading, spacing: 3) {
            line([("func ", editor.keyword), ("greet", editor.function), ("(", editor.foreground), ("to", editor.attribute),
                  (": ", editor.foreground), ("Name", editor.type), (") {", editor.foreground)])
            line([("  // ", editor.comment), ("say hello", editor.comment)])
            line([("  print(", editor.foreground), ("\"hi\"", editor.string), (", ", editor.foreground), ("42", editor.number), (")", editor.foreground)])
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(1..<7, id: \.self) { index in
                    Circle().fill(c(theme.terminal.ansi[index])).frame(width: 7, height: 7)
                }
                Spacer(minLength: 0)
                AccentDot(accent: theme.accent).frame(width: 9, height: 9)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(c(editor.background), in: .rect(cornerRadius: 9))
        .accessibilityHidden(true)
    }

    private func line(_ parts: [(String, String)]) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor(c($1.1)) }
            .lineLimit(1)
    }
}

/// The accent: a Mac accent's own color, or a wheel for "whatever your Mac uses".
struct AccentDot: View {
    let accent: ThemeAccent?
    private static let wheel = AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center)

    var body: some View {
        Group {
            if let accent {
                Circle().fill(Color(nsColor: ThemePalette.color(accent.hex)))
            } else {
                Circle().fill(Self.wheel)
            }
        }
        .overlay { Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5) }
    }
}

// MARK: - Changing colors

/// Every color of the theme showing now, each a well to pick from. Tiri's own themes become a copy on the first change.
struct ThemeColorEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.activeTheme
        VStack(alignment: .leading, spacing: 12) {
            if theme.isBuiltIn {
                Text("Changing \(theme.name) makes your own copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            group("Highlights") {
                HStack(spacing: 8) {
                    accentChoice(nil, chosen: theme.accent == nil, label: "Your Mac")
                    ForEach(ThemeAccent.allCases, id: \.self) { accent in
                        accentChoice(accent, chosen: theme.accent == accent, label: accent.rawValue.capitalized)
                    }
                }
            }
            group("Terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    wells(["terminal.background", "terminal.foreground", "terminal.cursor", "terminal.selection"],
                          labels: ["Background", "Text", "Cursor", "Selection"])
                    wells(Theme.ansiNames.prefix(8).map { "terminal." + $0 }, labels: nil)
                    wells(Theme.ansiNames.suffix(8).map { "terminal." + $0 }, labels: nil)
                }
            }
            group("Editor") {
                VStack(alignment: .leading, spacing: 8) {
                    wells(["editor.background", "editor.foreground", "editor.cursor", "editor.selection"],
                          labels: ["Background", "Text", "Cursor", "Selection"])
                    wells(["editor.comment", "editor.string", "editor.number", "editor.keyword", "editor.function", "editor.type", "editor.attribute"],
                          labels: ["Comment", "String", "Number", "Keyword", "Function", "Type", "Attribute"])
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func accentChoice(_ accent: ThemeAccent?, chosen: Bool, label: String) -> some View {
        Button {
            _ = model.setThemeColors([("accent", accent?.rawValue ?? "mac")])
        } label: {
            AccentDot(accent: accent)
                .frame(width: 16, height: 16)
                .padding(2.5)
                .overlay { Circle().strokeBorder(chosen ? Color.primary.opacity(0.5) : .clear, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("Highlights: \(label)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// A row of color wells, named under them, or by their color names when there are no labels (the terminal's sixteen).
    private func wells(_ keys: [String], labels: [String]?) -> some View {
        HStack(alignment: .top, spacing: labels == nil ? 6 : 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                let name = labels?[index] ?? Self.ansiLabel(key)
                VStack(spacing: 3) {
                    ColorPicker(name, selection: binding(key), supportsOpacity: key.hasSuffix("selection"))
                        .labelsHidden()
                        .help(name)
                        .accessibilityLabel(name)
                    if let labels {
                        Text(labels[index]).font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
        }
    }

    private static func ansiLabel(_ key: String) -> String {
        let name = key.replacingOccurrences(of: "terminal.", with: "")
        return name.hasPrefix("bright") ? "Bright " + name.dropFirst(6).lowercased() : name.capitalized
    }

    private func binding(_ key: String) -> Binding<Color> {
        Binding {
            Color(nsColor: ThemePalette.color(model.activeTheme[key] ?? "#000000"))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let hex = ThemeColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent).hex
            guard hex != model.activeTheme[key] else { return }
            _ = model.setThemeColors([(key, hex)])
        }
    }
}

// MARK: - Bringing one in

/// Themes this Mac's other apps already have, ready in one click, and a file for anything else.
struct BringThemeList: View {
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var found: [ThemeDiscovery.Found] = []
    @State private var inUse: [String: String] = [:]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List {
                if shown.isEmpty {
                    Text(found.isEmpty ? "No other app on this Mac has themes. Choose a file instead." : "Nothing matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { from, themes in
                    Section(from) {
                        ForEach(themes) { theme in
                            Button { bring(URL(fileURLWithPath: theme.path), named: theme.name) } label: { row(theme) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Choose a File…") { chooseFile() }
                    .help("A Ghostty theme, an iTerm2 .itermcolors file, or a VS Code or Cursor theme .json")
            }
            .padding(10)
        }
        .frame(width: 340, height: 420)
        .task {
            let (all, using) = await Task.detached { (ThemeDiscovery.available(), ThemeDiscovery.inUse()) }.value
            found = all
            inUse = using
        }
    }

    private var shown: [ThemeDiscovery.Found] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? found : found.filter { $0.name.localizedCaseInsensitiveContains(words) || $0.from.localizedCaseInsensitiveContains(words) }
    }

    private var groups: [(String, [ThemeDiscovery.Found])] {
        var order: [String] = []
        var byApp: [String: [ThemeDiscovery.Found]] = [:]
        for theme in shown {
            if byApp[theme.from] == nil { order.append(theme.from) }
            byApp[theme.from, default: []].append(theme)
        }
        // The theme an app is using first in its group.
        return order.map { app in
            (app, byApp[app]!.sorted { a, b in
                let (aUsed, bUsed) = (inUse[app] == a.name, inUse[app] == b.name)
                return aUsed != bUsed ? aUsed : a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
        }
    }

    private func row(_ theme: ThemeDiscovery.Found) -> some View {
        HStack(spacing: 8) {
            Image(systemName: theme.dark == false ? "sun.max" : "moon")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(theme.name).lineLimit(1)
            Spacer(minLength: 4)
            if inUse[theme.from] == theme.name {
                Text("In \(theme.from)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func bring(_ url: URL, named name: String? = nil) {
        do {
            let theme = try model.importTheme(from: url, named: name, use: false)
            model.useTheme(theme.name, for: model.activeThemeSlot)
            done()
        } catch let failure as ThemeImport.Failure {
            problem = failure.description
        } catch {
            problem = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "A Ghostty theme, an iTerm2 .itermcolors file, or a VS Code or Cursor theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bring(url)
    }
}

// MARK: - Making one with an agent

/// Say what the theme should be like, and an agent makes it with `tiri theme`, on screen as it goes.
struct MakeThemeWithAgent: View {
    let slot: ThemeSlot
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var description = ""
    @FocusState private var focused: Bool

    var body: some View {
        let presets = model.runnableAgentPresets()
        let prompt = model.makeThemePrompt(description, for: slot)
        VStack(alignment: .leading, spacing: 10) {
            TextField("Like a foggy harbor at dawn", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($focused)
                .onSubmit { send(presets.first, prompt) }
            HStack {
                Text("For \(slot.title.lowercased()) mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let first = presets.first {
                    Menu {
                        ForEach(presets.dropFirst()) { preset in
                            Button("Ask \(preset.name)") { send(preset, prompt) }
                        }
                        if presets.count > 1 { Divider() }
                        Button("Copy Prompt") { Clipboard.copy(prompt); done() }
                    } label: {
                        Text("Ask \(first.name)")
                    } primaryAction: {
                        send(first, prompt)
                    }
                    .fixedSize()
                    .disabled(isEmpty)
                } else {
                    Button("Copy Prompt") { Clipboard.copy(prompt); done() }
                        .disabled(isEmpty)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var isEmpty: Bool { description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send(_ preset: TerminalPreset?, _ prompt: String) {
        guard let preset, !isEmpty else { return }
        model.askAgent(preset: preset, prompt: prompt)
        done()
    }
}
