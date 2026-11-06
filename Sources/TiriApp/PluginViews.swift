import AppKit
import SwiftUI
import TiriCore
import TiriHighlight
import UniformTypeIdentifiers

// MARK: - In Settings

/// How to get a plugin, and what you've got. Turning one on always asks.
struct PluginsSection: View {
    @Environment(AppModel.self) private var model
    @State private var isDropping = false

    var body: some View {
        let host = model.plugins
        let _ = host.revision
        VStack(alignment: .leading, spacing: 28) {
            NewPluginSection()
            SettingsGroup(String(localized: "Installed")) {
                Button("Import…") { host.chooseFileToImport() }
                    .controlSize(.small)
                    .help("A .tiriplugin file, a plugin's folder, a .zip of one, or a VS Code .vsix")
            } content: {
                SettingsCard {
                    let waiting = host.liveBuilds.filter { build in build.plugin.map { host.plugin(named: $0) == nil } ?? true }
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { index, build in
                        if index > 0 { SettingsRowDivider() }
                        PluginBuildRow(title: build.request ?? build.plugin ?? String(localized: "A new plugin"), symbol: "puzzlepiece.extension", item: build.item)
                    }
                    if !waiting.isEmpty, !host.plugins.isEmpty { SettingsRowDivider() }
                    if host.plugins.isEmpty, waiting.isEmpty {
                        Text("None yet. Make one above, or drop a .tiriplugin file here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                    ForEach(Array(host.plugins.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { SettingsRowDivider() }
                        if let build = host.build(of: plugin.name) {
                            PluginBuildRow(title: build.request ?? plugin.title, symbol: plugin.manifest?.panels?.first?.symbol ?? "puzzlepiece.extension", item: build.item)
                        } else {
                            PluginRow(plugin: plugin)
                        }
                    }
                }
                .overlay {
                    if isDropping {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropping) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { AppModel.shared.plugins.importPlugin(at: url) }
                        }
                    }
                    return true
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Skills, hooks and MCP servers belong in your agent's own plugins.")
                Spacer(minLength: 8)
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: PluginLibrary.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(PluginLibrary.folder)
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Saying what you want is all it takes. Open at first, and it stays how you leave it.
struct NewPluginSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settings.plugins.newOpen") private var isOpen = true
    @FocusState private var typing: Bool

    private struct Example: Identifiable {
        let kind: PluginMiniature.Kind
        let caption: String
        /// What goes in the box. Without it, the caption's words do.
        var start: String?
        var request: String { start ?? caption }
        var id: String { caption }
    }

    private static let examples = [
        Example(kind: .port, caption: String(localized: "Port a VS Code extension by name"), start: String(localized: "Port the VS Code extension ")),
        Example(kind: .sidebar, caption: String(localized: "Show my pull requests in the sidebar")),
        Example(kind: .viewer, caption: String(localized: "Open .csv files as a chart")),
        Example(kind: .button, caption: String(localized: "Add a Run button above test files")),
        Example(kind: .status, caption: String(localized: "Show today's token usage in the bottom bar")),
        Example(kind: .language, caption: String(localized: "Add colors for a language Tiri doesn't know")),
    ]

    private var trimmed: String { model.settingsUI.newPluginRequest.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FoldHeading(title: String(localized: "New plugin"), isOpen: $isOpen)
            if isOpen {
                content
                    .transition(.opacity)
            }
        }
    }

    private var content: some View {
        @Bindable var ui = model.settingsUI
        return VStack(alignment: .leading, spacing: 18) {
            Text("Plugins add what a terminal can't draw. Say what you want and your agent builds it.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                TextField("What should Tiri show or do?", text: $ui.newPluginRequest, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
                    .focused($typing)
                    .onSubmit { if let first = model.runnableAgentPresets().first { ask(first) } }
                HStack(alignment: .center, spacing: 8) {
                    Text("You'll see what it adds and runs before it turns on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    askButton
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(typing ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.1), lineWidth: typing ? 1.5 : 1)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(Self.examples) { example in
                    MiniatureButton(kind: example.kind, caption: example.caption, isChosen: trimmed == example.request.trimmingCharacters(in: .whitespaces)) {
                        ui.newPluginRequest = example.request
                        typing = true
                        // Focus selects what's in a field, and the next key would replace it.
                        DispatchQueue.main.async {
                            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                        }
                    }
                }
            }
        }
    }

    /// The first agent on the button, and the others behind it.
    @ViewBuilder private var askButton: some View {
        let presets = model.runnableAgentPresets()
        if let first = presets.first {
            if presets.count > 1 {
                Menu("Ask \(first.name)") {
                    ForEach(presets.dropFirst()) { preset in
                        Button("Ask \(preset.name)") { ask(preset) }
                    }
                } primaryAction: {
                    ask(first)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(trimmed.isEmpty)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ask \(first.name)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { if !trimmed.isEmpty { ask(first) } }
                .accessibilityActions {
                    ForEach(presets.dropFirst()) { preset in
                        Button("Ask \(preset.name)") { ask(preset) }
                    }
                }
            } else {
                Button("Ask \(first.name)") { ask(first) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        } else {
            Button("Choose Agents…") { model.openAgentSettings() }
        }
    }

    private func ask(_ preset: TerminalPreset) {
        guard !trimmed.isEmpty else { return }
        model.askAgentToBuildPlugin(preset: preset, request: trimmed)
        model.settingsUI.newPluginRequest = ""
    }
}

/// A heading that folds what's under it.
struct FoldHeading: View {
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.2))) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(title).font(.headline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? String(localized: "Fold \(title)") : String(localized: "Unfold \(title)"))
    }
}

/// A plugin's own settings, out of the way until you want them, and as you left them after that.
struct PluginSettingsGroup: View {
    let name: String
    let settings: [SettingDefinition]
    @AppStorage private var isOpen: Bool

    init(name: String, settings: [SettingDefinition]) {
        self.name = name
        self.settings = settings
        _isOpen = AppStorage(wrappedValue: false, "settings.plugins.open.\(settings.first?.key ?? name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FoldHeading(title: String(localized: "\(name) settings"), isOpen: $isOpen)
            if isOpen {
                SettingRows(definitions: settings)
                    .transition(.opacity)
            }
        }
    }
}

/// A place a plugin can go, and the request that puts something there.
private struct MiniatureButton: View {
    let kind: PluginMiniature.Kind
    let caption: String
    let isChosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                PluginMiniature(kind: kind)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isChosen ? Color.accentColor : Color.primary.opacity(hovering ? 0.32 : 0.13), lineWidth: isChosen ? 2 : 1)
                    }
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering || isChosen ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start from this")
    }
}

/// Tiri itself, very small, with what a plugin would add in your accent color. Its parts are where
/// they are in the real window, so it says where a plugin goes without any words.
struct PluginMiniature: View {
    enum Kind { case port, sidebar, viewer, button, status, language }
    let kind: Kind

    private static let aspect: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in draw(&context, size) }
            .aspectRatio(Self.aspect, contentMode: .fit)
            .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let ink = Color.primary.opacity(0.17)
        let faint = Color.primary.opacity(0.1)
        let accent = Color.accentColor
        var c = context
        func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color, radius: CGFloat = 1.5) {
            c.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius), with: .color(color))
        }

        // The window: its title bar, sidebar and bottom bar, wherever they really are.
        c.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color.primary.opacity(0.045)))
        let top = h * 0.13
        let bottom = h * 0.9
        let side = w * 0.27
        c.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8))
        bar(0, 0, side, h, Color.primary.opacity(0.045), radius: 0)
        for index in 0..<3 {
            let dot = CGRect(x: 7 + CGFloat(index) * 6, y: top * 0.5 - 1.75, width: 3.5, height: 3.5)
            c.fill(Path(ellipseIn: dot), with: .color(ink))
        }
        bar(side, 0, 0.5, h, faint, radius: 0)
        bar(side, top, w - side, 0.5, faint, radius: 0)
        bar(0, bottom, w, 0.5, faint, radius: 0)

        let row = h * 0.055
        let gap = h * 0.095
        let main = side + w * 0.05
        let room = w - main - w * 0.05
        func files(_ count: Int) {
            for index in 0..<count {
                bar(w * 0.04, top + h * 0.06 + CGFloat(index) * gap, side * [0.72, 0.5, 0.62, 0.42][index % 4], row, faint)
            }
        }
        func text(from y: CGFloat, count: Int, x: CGFloat? = nil, width: CGFloat? = nil, color: Color? = nil) {
            for index in 0..<count {
                let share: CGFloat = [0.82, 0.55, 0.68, 0.36, 0.74, 0.48][index % 6]
                bar(x ?? main, y + CGFloat(index) * gap, (width ?? room) * share, row, color ?? ink)
            }
        }

        switch kind {
        case .sidebar:
            files(2)
            text(from: top + h * 0.06, count: 6)
            let start = bottom - gap * 3.6
            bar(0, start - gap * 0.4, side, bottom - start + gap * 0.4, accent.opacity(0.16), radius: 0)
            for index in 0..<3 {
                bar(w * 0.04, start + CGFloat(index) * gap, side * [0.72, 0.58, 0.66][index], row, accent)
            }
        case .viewer:
            files(4)
            let floor = bottom - h * 0.08
            let heights: [CGFloat] = [0.22, 0.34, 0.27, 0.45, 0.38, 0.58]
            let width = room / CGFloat(heights.count) * 0.66
            for (index, height) in heights.enumerated() {
                let x = main + CGFloat(index) * (room / CGFloat(heights.count))
                bar(x, floor - h * height, width, h * height, accent, radius: 1.5)
            }
            bar(main, floor + 1.5, room, 0.75, ink, radius: 0)
        case .port:
            // A whole extension's worth: a list, a page and a status item, all arriving at once.
            files(2)
            let split = side + (w - side) * 0.44
            text(from: top + h * 0.06, count: 6, x: side + w * 0.035, width: split - side - w * 0.06)
            let start = bottom - gap * 3.6
            bar(0, start - gap * 0.4, side, bottom - start + gap * 0.4, accent.opacity(0.16), radius: 0)
            for index in 0..<3 {
                bar(w * 0.04, start + CGFloat(index) * gap, side * [0.72, 0.58, 0.66][index], row, accent)
            }
            let area = CGRect(x: split, y: top, width: w - split, height: bottom - top)
            c.fill(Path(area), with: .color(accent.opacity(0.16)))
            bar(split, top, 1, bottom - top, accent, radius: 0)
            bar(split + w * 0.035, top + h * 0.06, area.width * 0.55, row * 1.3, accent)
            text(from: top + h * 0.06 + gap * 1.25, count: 4, x: split + w * 0.035, width: area.width * 0.78, color: accent.opacity(0.55))
            bar(side, bottom, w - side, h - bottom, accent.opacity(0.16), radius: 0)
            let pill = CGRect(x: w * 0.72, y: bottom + (h - bottom) * 0.28, width: w * 0.23, height: (h - bottom) * 0.44)
            c.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(accent))
        case .button:
            files(4)
            let strip = top + h * 0.13
            bar(side, strip, w - side, 0.5, faint, radius: 0)
            bar(main, top + h * 0.04, room * 0.32, row, ink)
            let pill = CGRect(x: w - w * 0.2, y: top + h * 0.02, width: w * 0.16, height: h * 0.09)
            c.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(accent))
            var play = Path()
            let tip = pill.height * 0.3
            play.move(to: CGPoint(x: pill.midX - tip * 0.7, y: pill.midY - tip))
            play.addLine(to: CGPoint(x: pill.midX + tip, y: pill.midY))
            play.addLine(to: CGPoint(x: pill.midX - tip * 0.7, y: pill.midY + tip))
            play.closeSubpath()
            c.fill(play, with: .color(.white))
            text(from: strip + h * 0.05, count: 5)
        case .status:
            files(4)
            text(from: top + h * 0.06, count: 6)
            bar(0, bottom, w, h - bottom, accent.opacity(0.16), radius: 0)
            let pill = CGRect(x: w * 0.68, y: bottom + (h - bottom) * 0.28, width: w * 0.27, height: (h - bottom) * 0.44)
            c.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(accent))
        case .language:
            files(4)
            // Real colors from the highlighter, on lines shaped like code.
            let keyword = Color(nsColor: TokenKind.keyword.color)
            let function = Color(nsColor: TokenKind.function.color)
            let string = Color(nsColor: TokenKind.string.color)
            let type = Color(nsColor: TokenKind.type.color)
            let comment = Color(nsColor: TokenKind.comment.color).opacity(0.6)
            let lines: [(indent: CGFloat, pieces: [(CGFloat, Color)])] = [
                (0, [(0.16, keyword), (0.3, function), (0.14, type)]),
                (0.08, [(0.12, keyword), (0.16, ink), (0.36, string)]),
                (0.08, [(0.52, comment)]),
                (0.08, [(0.14, keyword), (0.22, function), (0.2, type)]),
                (0.16, [(0.1, ink), (0.3, string)]),
                (0, [(0.08, ink)]),
            ]
            for (index, line) in lines.enumerated() {
                var x = main + line.indent * room
                for piece in line.pieces {
                    bar(x, top + h * 0.06 + CGFloat(index) * gap, room * piece.0, row, piece.1)
                    x += room * piece.0 + room * 0.025
                }
            }
        }
        context = c
    }
}

extension AppModel {
    static func newPluginPrompt(_ request: String) -> String {
        "Write me a Tiri plugin: \(request). Read `tiri plugin api` first. Make it with `tiri plugin new`, check it with `tiri plugin validate` and `tiri plugin test`, and then ask me to turn it on with `tiri plugin enable`. Tell me plainly what it adds and what it runs."
    }

    func askAgentToBuildPlugin(preset: TerminalPreset, request: String) {
        if let item = askAgent(preset: preset, prompt: Self.newPluginPrompt(request), about: request) {
            plugins.building(item: item, request: request)
        }
    }

    /// From the palette or the menu: one line, and it's with your agent.
    func promptForNewPlugin() {
        guard let preset = runnableAgentPresets().first ?? firstAgentPreset else {
            openPluginSettings()
            return
        }
        openPrompt(title: String(localized: "What should the plugin do? \(preset.name) will write it, and you'll turn it on."), initial: "") { [weak self] text in
            let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { return }
            self?.askAgentToBuildPlugin(preset: preset, request: request)
        }
    }
}

/// Something an agent is still writing. There's nothing to turn on yet, only somewhere to go and watch.
struct PluginBuildRow: View {
    let title: String
    let symbol: String
    let item: ItemID
    @Environment(AppModel.self) private var model

    private func status(of row: AppModel.AgentOverviewRow?) -> String {
        let needsYou = row?.status == .needsInput
        guard let agent = row?.agent else { return needsYou ? String(localized: "Your agent needs you") : String(localized: "Your agent is building this") }
        return needsYou ? String(localized: "\(agent) needs you") : String(localized: "\(agent) is building this")
    }

    var body: some View {
        let row = model.agentRows.first { $0.item == item }
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(status(of: row))
                    .font(.caption)
                    .foregroundStyle(row?.status == .needsInput ? Color.orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show") { model.focusItem(item) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct PluginRow: View {
    let plugin: InstalledPlugin
    @Environment(AppModel.self) private var model
    @State private var showsDetail = false

    private var note: (text: String, tint: Color)? {
        switch plugin.state {
        case .on, .off: nil
        case .changed: (String(localized: "Changed since you approved it, so it's off"), .orange)
        case .broken(let why): (why, .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: plugin.manifest?.panels?.first?.symbol ?? "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(plugin.isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background((plugin.isOn ? Color.accentColor : Color.primary).opacity(plugin.isOn ? 0.16 : 0.06), in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(plugin.title)
                        if let version = plugin.manifest?.version {
                            Text(version).font(.caption).foregroundStyle(.faint)
                        }
                    }
                    if let description = plugin.manifest?.description, description != PluginTools.placeholderDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(note.text)
                            .font(.caption)
                            .foregroundStyle(note.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showsDetail.toggle()
                } label: {
                    Image(systemName: showsDetail ? "chevron.up" : "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsDetail ? String(localized: "Hide") : String(localized: "What it adds and runs"))
                .accessibilityLabel(showsDetail ? String(localized: "Hide details of \(plugin.title)") : String(localized: "What \(plugin.title) adds and runs"))
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Export, Show in Finder, Show Log, Remove")
                .accessibilityLabel("More for \(plugin.title)")
                if case .changed = plugin.state {
                    Button("Review…") { model.plugins.askToEnable(plugin.name) }
                        .controlSize(.small)
                    Button("Turn Off") { model.plugins.disable(plugin.name) }
                        .controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { plugin.isOn }, set: { on in
                        if on { model.plugins.askToEnable(plugin.name) } else { model.plugins.disable(plugin.name) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isBroken)
                    .accessibilityLabel(plugin.title)
                }
            }
            if showsDetail, let manifest = plugin.manifest {
                VStack(alignment: .leading, spacing: 3) {
                    if !manifest.additions.isEmpty {
                        Text("Adds \(manifest.shownAdditions.formatted(.list(type: .and, width: .narrow))).")
                    }
                    if !manifest.programs.isEmpty {
                        Text("Runs with your full access: \(manifest.programs.joined(separator: ", "))")
                            .textSelection(.enabled)
                    }
                    if !manifest.networkAddresses.isEmpty {
                        Text("Its panels can reach \(manifest.networkAddresses.joined(separator: ", ")).")
                    }
                    ForEach(Array(plugin.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.description)
                            .foregroundStyle(issue.severity == .error ? Color.red : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Export…") { model.plugins.chooseWhereToExport(plugin.name) }
            .disabled(isBroken)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([plugin.folder]) }
        Button("Show Log") { model.plugins.showLog(plugin.name) }
        Divider()
        Button("Remove…", role: .destructive) { model.plugins.askToRemove(plugin.name) }
    }

    private var isBroken: Bool {
        if case .broken = plugin.state { return true }
        return false
    }
}

// MARK: - In the sidebar

/// A plugin's section: the plugin says what's in it, and Tiri draws it, so it looks like the rest.
struct PluginSidebarSection: View {
    let section: PluginHost.Section
    @Environment(AppModel.self) private var model
    @AppStorage private var isOpen: Bool
    @State private var expanded: Set<String> = []

    init(section: PluginHost.Section) {
        self.section = section
        _isOpen = AppStorage(wrappedValue: true, "sidebar.plugin." + section.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.18))) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 10)
                        Text(section.section.title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isOpen ? String(localized: "Fold \(section.section.title)") : String(localized: "Unfold \(section.section.title)"))
                Spacer()
                if section.state.isLoading {
                    ProgressView().controlSize(.mini)
                }
                ForEach(Array((section.section.buttons ?? []).enumerated()), id: \.offset) { _, button in
                    Button {
                        let id = PluginHost.fullID(plugin: section.plugin.name, command: button.command)
                        Task { await model.plugins.run(id, args: [:]) }
                    } label: {
                        Image(systemName: button.symbol ?? "bolt")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .help(button.title)
                    .accessibilityLabel(button.title)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 26)
            if isOpen {
                content
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { model.plugins.sectionAppeared(plugin: section.plugin.name, section: section.section.id) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let problem = section.state.problem, section.state.items.isEmpty {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        } else if section.state.items.isEmpty {
            Text(section.state.hasLoaded || section.section.provider == nil ? (section.section.emptyText ?? String(localized: "Nothing here")) : String(localized: "Loading…"))
                .font(.caption)
                .foregroundStyle(.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows(section.state.items, depth: 0)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func rows(_ items: [PluginTreeItem], depth: Int) -> AnyView {
        AnyView(ForEach(items) { item in
            PluginTreeRow(item: item, depth: depth, isExpanded: expanded.contains(item.id)) {
                if item.children.isEmpty {
                    model.plugins.activate(item, plugin: section.plugin.name)
                } else if expanded.contains(item.id) {
                    expanded.remove(item.id)
                } else {
                    expanded.insert(item.id)
                }
            }
            if expanded.contains(item.id) { rows(item.children, depth: depth + 1) }
        })
    }
}

struct PluginTreeRow: View {
    let item: PluginTreeItem
    let depth: Int
    let isExpanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if !item.children.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14 + CGFloat(depth) * 12)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.tooltip ?? item.title)
        .accessibilityValue(item.children.isEmpty ? (item.detail ?? "") : isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
    }
}

// MARK: - In the status bar

struct PluginStatusItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.plugins.statusItems) { status in
            Button {
                guard let command = status.content.command else { return }
                let id = PluginHost.fullID(plugin: status.plugin.name, command: command)
                Task { await model.plugins.run(id, args: status.content.args) }
            } label: {
                HStack(spacing: 4) {
                    if let symbol = status.content.symbol {
                        Image(systemName: symbol).font(.system(size: 11))
                    }
                    Text(status.content.text)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(status.content.command == nil)
            .fixedSize()
            .help(status.content.tooltip ?? status.plugin.title)
        }
    }
}

// MARK: - Above a file

struct PluginFileButtons: View {
    let item: Item
    let path: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let host = model.plugins
        let _ = host.revision
        let buttons = host.buttons(for: path)
        ForEach(Array(buttons.enumerated()), id: \.offset) { _, entry in
            Button {
                let id = PluginHost.fullID(plugin: entry.plugin.name, command: entry.button.command)
                Task { await host.run(id, args: [:]) }
            } label: {
                if let symbol = entry.button.symbol {
                    // More than a couple, and words would push the file's own name out of the bar.
                    if buttons.count > 2 {
                        Image(systemName: symbol)
                            .accessibilityLabel(entry.button.title)
                    } else {
                        Label(entry.button.title, systemImage: symbol).labelStyle(.titleAndIcon)
                    }
                } else {
                    Text(entry.button.title)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("\(entry.button.title), from \(entry.plugin.title)")
        }
        if case .file(let spec) = item.content {
            let choices = host.viewerChoices(for: path)
            let isPanel = host.viewer(for: spec) != nil
            if isPanel {
                Button {
                    model.setViewer(item.id, to: "text")
                } label: {
                    Label("Open Normally", systemImage: "doc.text").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .help("Show this file the way Tiri usually does")
            } else {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    Button {
                        model.setViewer(item.id, to: "\(choice.plugin.name).\(choice.panel.id)")
                    } label: {
                        Label(choice.panel.title, systemImage: choice.panel.symbol ?? "puzzlepiece.extension").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help("Show this file with \(choice.plugin.title)")
                }
            }
        }
    }
}

// MARK: - A language nothing covers

extension AppModel {
    /// The file in front is text in a language nobody here knows.
    var unknownLanguageExtension: String? {
        guard let item = active.peek ?? active.activeItem, case .file(let spec) = item.content else { return nil }
        guard existingController(for: item.id) is TextController, LanguageCatalog.language(forPath: spec.path) == nil else { return nil }
        let ext = (spec.path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    func askAgentToAddLanguage(_ ext: String) {
        let prompt = "Tiri doesn't know .\(ext) files, so they have no colors. Please write a Tiri plugin for this language. Read `tiri plugin api`, find a good TextMate grammar and check its licence, and add a language server if there's one worth having. Then check it with `tiri plugin validate` and ask me to turn it on with `tiri plugin enable`."
        guard let preset = firstAgentPreset else {
            showToast(title: String(localized: "No agent to ask"), detail: String(localized: "Turn one on in Settings."), symbol: "sparkles", tint: .secondary)
            return
        }
        askAgent(preset: preset, prompt: prompt)
    }
}

struct UnknownLanguageStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.controllerRevision
        if let ext = model.unknownLanguageExtension {
            Button {
                model.askAgentToAddLanguage(ext)
            } label: {
                Text(".\(ext): ask agent to add this language")
                    .font(.system(size: 11))
                    .foregroundStyle(.faint)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Your agent writes a plugin for it, and you turn it on")
        }
    }
}
