import AppKit
import SwiftUI
import TiriCore

/// Settings as an item, like everything else. Its settings come from `SettingsSchema`.
final class SettingsController: ItemController {
    let itemID: ItemID
    private let host: NSView

    var view: NSView { host }

    init(itemID: ItemID, model: AppModel) {
        self.itemID = itemID
        host = NSHostingView(rootView: SettingsView().environment(model))
    }

    func focus() { host.window?.makeFirstResponder(host) }
    func didAttach() { AppModel.shared.viewerReady(itemID) }
}

/// Where you are in Settings. It lasts as long as the app, so ⌘, goes back to where you were.
@Observable final class SettingsNavigation {
    var pane = SettingsPane.general
    var query = ""
    /// A row to scroll to, and then to mark for a moment.
    var reveal: String?
    var highlighted: String?
    var searchFocusRequests = 0
    /// What's being asked for, which shouldn't vanish on a look at another pane.
    var newPluginRequest = ""
    var shortcutFilter = ShortcutFilter.all
    var shortcutKeys: [KeyStroke] = []
    var expandedAgent: String?
    /// The heading to scroll to, and the one that's at the top of the page now.
    var jumpTarget: String?
    var currentSection: String?
    /// A test copy pretending about Apple Intelligence, which the screen has to notice.
    var macModelChanges = 0
    /// A jump's own scrolling shouldn't move the marker it just set.
    @ObservationIgnored var markerHeldUntil = Date.distantPast

    func jump(to section: String) {
        currentSection = section
        markerHeldUntil = Date().addingTimeInterval(0.5)
        jumpTarget = section
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    var isSearching: Bool { !trimmedQuery.isEmpty }
}

enum ShortcutNotice: Equatable {
    case problem(command: String, message: String)
    case conflict(command: String, key: String, holders: [String])

    var command: String {
        switch self {
        case .problem(let command, _), .conflict(let command, _, _): command
        }
    }
}

/// Where each heading is on the page, so the list beside it can follow the scrolling.
struct SectionPositions: PreferenceKey {
    static let pageEnd = "\u{0}end"
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// Written out rather than with `@Entry`, whose macro plugin ships only inside Xcode. See scripts/swift-setup.sh.
private struct SettingsRowsStackKey: EnvironmentKey { static let defaultValue = false }
private struct SettingsIsTightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Too narrow for a control beside its words, so it goes beneath them.
    var settingsRowsStack: Bool {
        get { self[SettingsRowsStackKey.self] }
        set { self[SettingsRowsStackKey.self] = newValue }
    }
    /// The panes are in a menu, which already says which one this is.
    var settingsIsTight: Bool {
        get { self[SettingsIsTightKey.self] }
        set { self[SettingsIsTightKey.self] = newValue }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private static let navigationWidth: CGFloat = 196
    /// Below this the panes move into a menu, and the page gets the whole width.
    private static let tightWidth: CGFloat = 640
    private static let rowsStackBelow: CGFloat = 440

    var body: some View {
        GeometryReader { geometry in
            let tight = geometry.size.width < Self.tightWidth
            let room = geometry.size.width - (tight ? 0 : Self.navigationWidth) - 2 * SettingsContent.margin
            Group {
                if tight {
                    VStack(spacing: 0) {
                        SettingsCompactBar()
                        Divider()
                        SettingsContent()
                    }
                } else {
                    HStack(spacing: 0) {
                        SettingsNavigationColumn()
                            .frame(width: Self.navigationWidth)
                        Divider()
                        SettingsContent()
                    }
                }
            }
            .environment(\.settingsRowsStack, room < Self.rowsStackBelow)
            .environment(\.settingsIsTight, tight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            model.cancelRecordingShortcut()
            model.cancelFindingShortcutKey()
        }
    }
}

// MARK: - Finding your way

extension AppModel {
    var shortcutSectionsMatchingQuery: [ShortcutSection] {
        ShortcutIndex.sections(commands: shortcutCommands, bindings: keybindings, changed: changedShortcuts, query: settingsUI.trimmedQuery)
    }

    func agentEntriesMatching(_ query: String) -> [AgentEntry] {
        agentEntries.filter { SettingsSchema.matches(query, in: [$0.name, $0.command, "agents hooks resume"]) }
    }

    func pluginsMatching(_ query: String) -> [InstalledPlugin] {
        plugins.plugins.filter { SettingsSchema.matches(query, in: [$0.title, $0.name, $0.manifest?.description ?? "", "plugins extensions"]) }
    }

    func languagesMatching(_ query: String) -> [LanguageServerDefinition] {
        LanguageServerCatalog.all.filter { SettingsSchema.matches(query, in: [$0.language, $0.id, "language server"]) }
    }

    /// How much a search finds in each pane.
    var settingsMatchCounts: [SettingsPane: Int] {
        let query = settingsUI.trimmedQuery
        var counts: [SettingsPane: Int] = [:]
        for definition in SettingsSchema.everything where !definition.shownElsewhere && SettingsSchema.matches(query, definition) {
            counts[definition.pane, default: 0] += 1
        }
        counts[.plugins, default: 0] += pluginsMatching(query).count
        counts[.agents, default: 0] += agentEntriesMatching(query).count
        counts[.languages, default: 0] += languagesMatching(query).count
        if CommandLineRow.matches(query) { counts[.general, default: 0] += 1 }
        counts[.keyboard] = shortcutSectionsMatchingQuery.reduce(0) { $0 + $1.commands.count }
        return counts.filter { $0.value > 0 }
    }
}

struct SettingsNavigationColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ui = model.settingsUI
        let counts = ui.isSearching ? model.settingsMatchCounts : [:]
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField()
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.settingsPanes) { pane in
                        SettingsNavigationRow(pane: pane, count: counts[pane])
                        if pane == .keyboard, ui.pane == .keyboard, !ui.isSearching {
                            ShortcutJumpList()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your AI can explain or change any of this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AskAgentMenu()
            }
        }
        .padding(12)
    }
}

struct SettingsNavigationRow: View {
    let pane: SettingsPane
    let count: Int?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let ui = model.settingsUI
        let isCurrent = !ui.isSearching && ui.pane == pane
        let isEmptySearch = ui.isSearching && count == nil
        Button {
            model.cancelRecordingShortcut()
            ui.query = ""
            ui.pane = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(pane.title)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .opacity(isEmptySearch ? 0.45 : 1)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct SettingsSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ui = model.settingsUI
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $ui.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { ui.query = "" }
            if !ui.query.isEmpty {
                Button {
                    ui.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
        .onChange(of: ui.searchFocusRequests) { _, _ in focused = true }
    }
}

/// The panes in a menu, for when Settings is in a narrow pane of its own.
struct SettingsCompactBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack

    private var paneMenu: some View {
        let ui = model.settingsUI
        return Menu {
            ForEach(model.settingsPanes) { pane in
                Button {
                    model.cancelRecordingShortcut()
                    ui.query = ""
                    ui.pane = pane
                } label: {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
        } label: {
            Text(ui.pane.title)
        }
        .fixedSize()
    }

    var body: some View {
        Group {
            if rowsStack {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        paneMenu
                        Spacer(minLength: 0)
                        AskAgentMenu(iconOnly: true)
                    }
                    SettingsSearchField()
                }
            } else {
                HStack(spacing: 8) {
                    paneMenu
                    SettingsSearchField()
                    AskAgentMenu(iconOnly: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One prompt away: an agent can explain and change everything here.
struct AskAgentMenu: View {
    var iconOnly = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let presets = model.runnableAgentPresets()
        Group {
            if let first = presets.first {
                Menu {
                    ForEach(presets.dropFirst()) { preset in
                        Button("Ask \(preset.name)") { model.askAgentAboutSettings(preset: preset) }
                    }
                    if presets.count > 1 { Divider() }
                    Button("Copy Prompt") { Clipboard.copy(SettingsSchema.agentPrompt) }
                } label: {
                    if iconOnly {
                        Image(systemName: "sparkles")
                    } else {
                        Text("Ask \(first.name)")
                    }
                } primaryAction: {
                    model.askAgentAboutSettings(preset: first)
                }
                .help("Sends \(first.name) this prompt: \(SettingsSchema.agentPrompt)")
                .accessibilityLabel("Ask \(first.name) about your settings")
                .fixedSize(horizontal: iconOnly, vertical: false)
            } else {
                Button("Copy Prompt") { Clipboard.copy(SettingsSchema.agentPrompt) }
                    .help(SettingsSchema.agentPrompt)
            }
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - The page

struct SettingsContent: View {
    static let margin: CGFloat = 28
    static let page = "settings-page"
    @Environment(AppModel.self) private var model
    @Environment(\.settingsIsTight) private var isTight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ui = model.settingsUI
        GeometryReader { geometry in
        let margin = isTight ? 16 : Self.margin
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if ui.isSearching {
                        SettingsSearchResults()
                    } else {
                        if !isTight {
                            Text(ui.pane.title)
                                .font(.title2.weight(.semibold))
                        }
                        paneBody(ui.pane)
                    }
                }
                // What's there and no more, so nothing inside can push the page past the edge.
                .frame(width: min(660, max(geometry.size.width - 2 * margin, 0)), alignment: .leading)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: SectionPositions.self, value: [SectionPositions.pageEnd: content.frame(in: .named(Self.page)).maxY])
                    }
                }
                .padding(.horizontal, margin)
                .padding(.vertical, isTight ? 16 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A pane starts at its top, wherever the last one was scrolled to.
            .id(ui.isSearching ? "search" : ui.pane.rawValue)
            .onAppear { reveal(proxy) }
            .coordinateSpace(name: Self.page)
            .onChange(of: ui.reveal) { _, _ in reveal(proxy) }
            .onChange(of: ui.jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
                ui.jumpTarget = nil
            }
            .onPreferenceChange(SectionPositions.self) { positions in
                let height = geometry.size.height
                MainActor.assumeIsolated { follow(positions, pageHeight: height) }
            }
        }
        }
    }

    /// The last heading to have reached the top. At the end of the page, the last one there is,
    /// since a short last section can never reach the top.
    private func follow(_ positions: [String: CGFloat], pageHeight: CGFloat) {
        let ui = model.settingsUI
        guard Date() >= ui.markerHeldUntil else { return }
        var headings = positions
        let end = headings.removeValue(forKey: SectionPositions.pageEnd)
        let ordered = headings.sorted { $0.value < $1.value }
        guard let last = ordered.last else { return }
        let current: String
        if let end, end <= pageHeight + 1 {
            current = last.key
        } else {
            current = ordered.last { $0.value <= 40 }?.key ?? ordered[0].key
        }
        if ui.currentSection != current { ui.currentSection = current }
    }

    @ViewBuilder private func paneBody(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            SchemaGroups(pane: .general)
            SettingsGroup("Command Line") {
                SettingsCard { CommandLineRow() }
            }
        case .agents:
            AgentsSection()
            SchemaGroups(pane: .agents)
        case .terminal:
            SchemaGroups(pane: .terminal)
        case .editor:
            SchemaGroups(pane: .editor)
        case .languages:
            SchemaGroups(pane: .languages)
            LanguageServersSection()
        case .plugins:
            PluginsSection()
            // What's on brings its own settings, each under its plugin's name.
            let _ = model.plugins.revision
            ForEach(SettingsSchema.groups(in: .plugins, from: SettingsSchema.fromPlugins), id: \.name) { group in
                PluginSettingsGroup(name: group.name, settings: group.settings)
            }
        case .yourTiri:
            YourTiriPane()
        case .files:
            SchemaGroups(pane: .files)
        case .keyboard:
            KeyboardSettings()
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        let ui = model.settingsUI
        guard let target = ui.reveal else { return }
        // After this page's first layout, or there's nothing to scroll to yet.
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
            ui.reveal = nil
            ui.highlighted = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if ui.highlighted == target { ui.highlighted = nil }
            }
        }
    }
}

struct SettingsSearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.settingsUI.trimmedQuery
        let counts = model.settingsMatchCounts
        if counts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if model.yourTiri.entriesAreOn, let preset = model.runnableAgentPresets().first {
                    Button("Ask \(preset.name) to add this") {
                        model.yourTiri.beginChange(surface: "Settings, searching for \u{201C}\(query)\u{201D}", initial: query)
                    }
                }
                Text("Nothing here matches \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(.secondary)
                if let preset = model.runnableAgentPresets().first {
                    Button("Ask \(preset.name)") { model.askAgentAboutSettings(preset: preset) }
                }
            }
        }
        ForEach(SettingsPane.allCases.filter { counts[$0] != nil }) { pane in
            VStack(alignment: .leading, spacing: 8) {
                Text(pane.title).font(.title3.weight(.semibold))
                results(in: pane, query: query)
            }
        }
    }

    @ViewBuilder private func results(in pane: SettingsPane, query: String) -> some View {
        let settings = SettingsSchema.everything.filter { $0.pane == pane && !$0.shownElsewhere && SettingsSchema.matches(query, $0) }
        switch pane {
        case .plugins:
            let found = model.pluginsMatching(query)
            if !found.isEmpty {
                SettingsCard {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { SettingsRowDivider() }
                        PluginRow(plugin: plugin)
                    }
                }
            }
            if !settings.isEmpty { SettingRows(definitions: settings) }
        case .keyboard:
            ShortcutSections(sections: model.shortcutSectionsMatchingQuery)
        case .languages:
            if !settings.isEmpty { SettingRows(definitions: settings) }
            let languages = model.languagesMatching(query)
            if !languages.isEmpty { LanguageServersSection(only: languages) }
        case .agents:
            let agents = model.agentEntriesMatching(query)
            if !agents.isEmpty {
                SettingsCard {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsRowDivider() }
                        AgentRow(entry: entry)
                    }
                }
            }
            if !settings.isEmpty { SettingRows(definitions: settings) }
        case .general:
            if !settings.isEmpty { SettingRows(definitions: settings) }
            if CommandLineRow.matches(query) { SettingsCard { CommandLineRow() } }
        default:
            if !settings.isEmpty { SettingRows(definitions: settings) }
        }
    }
}

// MARK: - Building blocks

struct SettingsGroup<Content: View, Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    trailing
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

struct SettingsRowDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

struct SchemaGroups: View {
    let pane: SettingsPane

    var body: some View {
        ForEach(SettingsSchema.groups(in: pane), id: \.name) { group in
            SettingsGroup(group.name) {
                SettingRows(definitions: group.settings)
            }
        }
    }
}

struct SettingRows: View {
    let definitions: [SettingDefinition]

    var body: some View {
        SettingsCard {
            ForEach(Array(definitions.enumerated()), id: \.element.id) { index, definition in
                if index > 0 { SettingsRowDivider() }
                SettingRow(definition: definition)
            }
        }
    }
}

/// A row a request can point at: it scrolls into view and is marked for a moment.
struct RevealableRow: ViewModifier {
    let id: String
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(model.settingsUI.highlighted == id ? 0.14 : 0))
                    .animation(.easeOut(duration: 0.3), value: model.settingsUI.highlighted)
            }
    }
}

struct SettingRow: View {
    let definition: SettingDefinition
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var showsNote = false

    private var value: JSONValue {
        _ = model.plugins.revision
        return definition.value(model.settings)
    }

    private func set(_ value: JSONValue) { model.setSetting(definition.key, to: value) }

    private var isWide: Bool {
        switch definition.kind {
        case .list, .presets, .commandMap: true
        default: false
        }
    }

    private var isChanged: Bool {
        SettingsSchema.json(value) != SettingsSchema.json(definition.value(TiriSettings()))
    }

    private var macModelState: MacModelState {
        _ = model.settingsUI.macModelChanges
        return ConversationAssistant.state
    }

    /// The row that can't do anything without Apple Intelligence: it says why, instead of a switch.
    private var isBlockedModelRow: Bool { definition.key == "conversations.useMacModel" && macModelState != .ready }
    private var needsModel: Bool { definition.key == "conversations.summarizeAll" }

    private var applies: Bool {
        if needsModel, macModelState != .ready { return false }
        return definition.applies?(model.settings) ?? true
    }

    /// Something on and waiting can still be turned off.
    private var canChange: Bool { applies || value.boolValue == true }

    private var waitingLine: String? {
        guard needsModel, !applies else { return nil }
        if model.settings.conversationsSummarizeAll { return "On, and waiting for Apple Intelligence." }
        return macModelState == .ready ? "Needs Titles and search with Apple Intelligence, above." : "Needs Apple Intelligence."
    }

    var body: some View {
        let beneath = isWide || rowsStack
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                words.frame(maxWidth: .infinity, alignment: .leading)
                if isChanged, !isBlockedModelRow { resetButton }
                if !beneath { rowControl }
            }
            if beneath { rowControl }
        }
        .opacity(applies ? 1 : 0.5)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .modifier(RevealableRow(id: definition.key))
        .contextMenu {
            Button("Copy Prompt About This Setting") { Clipboard.copy(SettingsSchema.agentPrompt(about: definition)) }
            Button("Reset to Default") { model.resetSetting(definition.key) }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(definition.title)
                if let note = definition.note, !isBlockedModelRow {
                    Button {
                        showsNote.toggle()
                    } label: {
                        Image(systemName: showsNote ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(note)
                    .accessibilityLabel(showsNote ? "Hide more about \(definition.title)" : "More about \(definition.title)")
                }
            }
            if isBlockedModelRow, let message = macModelState.message {
                caption(message)
            } else if !definition.titleIsEnough {
                caption(definition.explanation)
            }
            if let waitingLine { caption(waitingLine) }
            if showsNote, let note = definition.note {
                caption(note)
            }
            if definition.key == "conversations.summarizeAll", model.settings.conversationsSummarizeAll {
                let done = model.conversationsSummarized.map { $0.done >= $0.total ? "All \($0.total) summarized" : "\($0.done) of \($0.total) summarized" }
                let waiting = AppModel.isPluggedIn ? nil : "Waiting to be plugged in"
                let status = [done, waiting].compactMap { $0 }
                if !status.isEmpty { caption(status.joined(separator: ". ")) }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resetButton: some View {
        Button {
            model.resetSetting(definition.key)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Back to the default: \(SettingsSchema.display(definition.value(TiriSettings())))")
        .accessibilityLabel("Reset \(definition.title)")
    }

    @ViewBuilder private var rowControl: some View {
        if isBlockedModelRow {
            switch macModelState {
            case .turnedOff:
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .fixedSize()
                .help("Apple Intelligence & Siri is where it's turned on")
            case .gettingReady:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Getting Ready").foregroundStyle(.secondary)
                }
                .fixedSize()
            default:
                Text("Not Available")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        } else {
            control.disabled(!canChange)
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { value.boolValue ?? false }, set: { set(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(definition.title)
        case .choice(let options):
            let picker = Picker("", selection: Binding(get: { value.stringValue ?? "" }, set: { set(.string($0)) })) {
                ForEach(options, id: \.self) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(definition.title)
            // Segments don't fold, and they're no use cut off, so they're only for a few short choices.
            if rowsStack || options.count > 4 || options.contains(where: { $0.label.count > 14 }) {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        case .number(let minimum, let maximum, let step):
            NumberControl(title: definition.title, value: value.numberValue ?? minimum, range: minimum...maximum, step: step) { number in
                set(number == number.rounded() ? .int(Int(number)) : .double(number))
            }
        case .font:
            FontPicker(selection: value.stringValue ?? "") { set(.string($0)) }
                .accessibilityLabel(definition.title)
        case .text(let placeholder):
            CommitField(placeholder: placeholder, text: value.stringValue ?? "") { set(.string($0)) }
                .frame(maxWidth: rowsStack ? .infinity : 220)
                .accessibilityLabel(definition.title)
        case .list(let placeholder):
            TokenList(title: definition.title, placeholder: placeholder, items: value.arrayValue?.compactMap(\.stringValue) ?? []) { items in
                set(.array(items.map(JSONValue.string)))
            }
        case .presets, .commandMap:
            EmptyView()
        }
    }
}

/// A number you can type or step, kept to what the setting allows.
struct NumberControl: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isLarge: Bool { range.upperBound >= 10_000 }

    private func text(_ number: Double) -> String {
        if isLarge { return number.formatted(.number.grouping(.automatic)) }
        return SettingsSchema.display(number == number.rounded() ? .int(Int(number)) : .double(number))
    }

    private func save() {
        let digits = draft.filter { !$0.isWhitespace && $0 != "," }
        if let number = Double(digits) {
            let kept = min(max(number, range.lowerBound), range.upperBound)
            if kept != value { commit(kept) }
            draft = text(kept)
        } else {
            draft = text(value)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: isLarge ? 72 : 44)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                .accessibilityLabel(title)
            Stepper("", value: Binding(get: { value }, set: commit), in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .onAppear { draft = text(value) }
        .onChange(of: value) { _, updated in if !focused { draft = text(updated) } }
    }
}

/// Monospaced fonts installed on this Mac, plus whatever's already chosen.
struct FontPicker: View {
    let selection: String
    let commit: (String) -> Void

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFont(name: family, size: 12)?.isFixedPitch == true
    }

    var body: some View {
        let options = Self.families.contains(selection) ? Self.families : [selection] + Self.families
        Picker("", selection: Binding(get: { selection }, set: commit)) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A text field that saves when you press Return or move away, not on every keystroke.
struct CommitField: View {
    let placeholder: String
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, value in if !focused { draft = value } }
            .onChange(of: focused) { _, isFocused in if !isFocused, draft != text { commit(draft) } }
            .onSubmit { if draft != text { commit(draft) } }
    }
}

/// A short list of words: each can be taken out, and new ones typed at the end.
struct TokenList: View {
    let title: String
    let placeholder: String
    let items: [String]
    let commit: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item)
                    Button {
                        commit(items.filter { $0 != item })
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(item)")
                    .accessibilityLabel("Remove \(item) from \(title)")
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: 22)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 150)
                .onSubmit(add)
                .accessibilityLabel("Add to \(title)")
        }
    }

    private func add() {
        let new = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !items.contains($0) }
        draft = ""
        if !new.isEmpty { commit(items + new) }
    }
}

/// Lays its children in rows, starting a new row when one runs out of room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = []
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows.isEmpty || used + size.width > width {
                rows.append(([index], size.height))
                used = size.width + spacing
            } else {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
                used += size.width + spacing
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        let found = rows(width, subviews)
        return CGSize(width: width, height: found.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(found.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}

struct CommandLineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack

    static func matches(_ query: String) -> Bool {
        SettingsSchema.matches(query, in: ["tiri command", "command line", "install"])
    }

    private var path: String { (model.commandLineLink.path as NSString).abbreviatingWithTildeInPath }

    private var detail: String {
        switch model.commandLineState() {
        case .installed: "Works in your other terminals too, through a link at \(path)."
        case .notInstalled: "Works in every terminal inside Tiri. This adds it to your other terminals, at \(path)."
        case .stale: "The link at \(path) points to a copy of Tiri that has moved. Install fixes it."
        case .otherFile: "There's another file at \(path). Install replaces it with a link to this copy of Tiri."
        }
    }

    var body: some View {
        let installed = model.commandLineState() == .installed
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("tiri command")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(installed ? "Remove" : "Install…") { model.confirmCommandLineTool(install: !installed) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
