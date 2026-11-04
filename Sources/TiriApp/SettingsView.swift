import AppKit
import SwiftUI
import TiriCore

/// Settings as an item, like everything else. Built entirely from `SettingsSchema`.
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

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var visible: [SettingDefinition] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return SettingsSchema.all }
        return SettingsSchema.all.filter {
            [$0.title, $0.explanation, $0.section, $0.key].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    static let shortcutsAnchor = "keyboard-shortcuts"

    private var visibleCommands: [AppCommand] {
        let text = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        return model.allCommands.filter { command in
            guard seen.insert(command.id).inserted else { return false }
            guard !text.isEmpty else { return true }
            let keys = model.shortcutSymbol(for: command.id) ?? ""
            return [command.title, command.category, command.id, keys].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AskAgentCard()
                TextField("Search settings", text: $query)
                    .textFieldStyle(.roundedBorder)
                let shown = visible
                let commands = visibleCommands
                if shown.isEmpty, commands.isEmpty {
                    Text("No settings match \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
                ForEach(SettingsSchema.sections, id: \.self) { section in
                    let rows = shown.filter { $0.section == section }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section)
                                .font(.headline)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, definition in
                                    if index > 0 { Divider() }
                                    SettingRow(definition: definition)
                                }
                            }
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                        }
                    }
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    AgentHooksSection()
                    CommandLineSection()
                }
                if !commands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keyboard Shortcuts").font(.headline)
                            Text("Click a shortcut, then press the keys. Esc cancels, Delete removes it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                if index > 0 { Divider() }
                                ShortcutRow(command: command)
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    }
                    .id(Self.shortcutsAnchor)
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { scrollToAnchor(proxy) }
        .onChange(of: model.settingsAnchor) { _, _ in scrollToAnchor(proxy) }
        .onDisappear { model.cancelRecordingShortcut() }
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = model.settingsAnchor else { return }
        // After this tab's first layout, or there's nothing to scroll to yet.
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            model.settingsAnchor = nil
        }
    }
}

/// One prompt away: an agent can explain and change everything here.
struct AskAgentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask your AI").font(.headline)
                Text("Your agent can explain every setting and shortcut here and change them for you. Send it this prompt:")
                    .foregroundStyle(.secondary)
            }
            Text(SettingsSchema.agentPrompt)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack(spacing: 8) {
                ForEach(model.settings.terminalPresets.filter { !$0.command.isEmpty }) { preset in
                    Button("Ask \(preset.name)") {
                        model.askAgentAboutSettings(preset: preset)
                    }
                    .help("Sends this prompt to \(preset.name) in this workspace")
                }
                Button("Copy Prompt") { Clipboard.copy(SettingsSchema.agentPrompt) }
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

struct SettingRow: View {
    let definition: SettingDefinition
    @Environment(AppModel.self) private var model

    private var value: JSONValue { definition.value(model.settings) }

    private func set(_ value: JSONValue) { model.setSetting(definition.key, to: value) }

    private var isWide: Bool {
        switch definition.kind {
        case .presets, .commandMap: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(definition.title)
                    Text(definition.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isWide { control }
            }
            if isWide { control }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Prompt About This Setting") { Clipboard.copy(SettingsSchema.agentPrompt(about: definition)) }
            Button("Reset to Default") { model.resetSetting(definition.key) }
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { value.boolValue ?? false }, set: { set(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .choice(let options):
            Picker("", selection: Binding(get: { value.stringValue ?? "" }, set: { set(.string($0)) })) {
                ForEach(options, id: \.self) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        case .number(let minimum, let maximum, let step):
            let current = value.numberValue ?? minimum
            Stepper(value: Binding(get: { current }, set: { set($0 == $0.rounded() ? .int(Int($0)) : .double($0)) }),
                    in: minimum...maximum, step: step) {
                Text(SettingsSchema.display(value)).monospacedDigit()
            }
            .fixedSize()
        case .font:
            FontPicker(selection: value.stringValue ?? "") { set(.string($0)) }
        case .text(let placeholder):
            CommitField(placeholder: placeholder, text: value.stringValue ?? "") { set(.string($0)) }
                .frame(width: 220)
        case .list(let placeholder):
            let items = value.arrayValue?.compactMap(\.stringValue) ?? []
            CommitField(placeholder: placeholder, text: items.joined(separator: ", ")) { text in
                set(.array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }))
            }
            .frame(width: 260)
        case .presets:
            PairsEditor(firstPlaceholder: "Name", secondPlaceholder: "Command, or empty for a shell",
                        pairs: (value.arrayValue ?? []).map { ($0["name"]?.stringValue ?? "", $0["command"]?.stringValue ?? "") }) { pairs in
                set(.array(pairs.map { .object(["name": .string($0.0), "command": .string($0.1)]) }))
            }
        case .commandMap:
            PairsEditor(firstPlaceholder: "Tool", secondPlaceholder: "Resume command",
                        pairs: value.objectValue.sorted { $0.key < $1.key }.map { ($0.key, $0.value.stringValue ?? "") }) { pairs in
                set(.object(Dictionary(pairs.map { ($0.0, JSONValue.string($0.1)) }, uniquingKeysWith: { _, last in last })))
            }
        }
    }
}

struct AgentHooksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Status").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(AgentHooks.Tool.allCases.enumerated()), id: \.element) { index, tool in
                    if index > 0 { Divider() }
                    let installed = model.hooksInstalled(tool)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.title)
                            Text(installed
                                 ? "Reports exactly when it's working, waiting for you or done, and resumes the right conversation."
                                 : "Tiri is estimating its status from terminal activity. A hook makes it exact.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(installed ? "Remove" : "Install…") { model.confirmHooks(tool, install: !installed) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }
}

struct CommandLineSection: View {
    @Environment(AppModel.self) private var model

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
        VStack(alignment: .leading, spacing: 8) {
            Text("Command Line").font(.headline)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("tiri command")
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                let installed = model.commandLineState() == .installed
                Button(installed ? "Remove" : "Install…") { model.confirmCommandLineTool(install: !installed) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }
}

struct ShortcutRow: View {
    let command: AppCommand
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.recordingShortcutFor == command.id }

    var body: some View {
        HStack(spacing: 8) {
            Text(command.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.shortcutIsCustom(command.id), !isRecording {
                Button {
                    model.resetShortcut(command.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to the default")
            }
            Button {
                if isRecording {
                    model.cancelRecordingShortcut()
                } else {
                    model.beginRecordingShortcut(for: command.id)
                }
            } label: {
                Text(isRecording ? "Press keys…" : (model.shortcutSymbol(for: command.id) ?? "Add"))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? Color.accentColor : (model.shortcutSymbol(for: command.id) == nil ? .secondary : .primary))
                    .frame(minWidth: 70)
            }
            .help("Click, then press the keys")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Prompt About This Shortcut") {
                Clipboard.copy("Change the Tiri keyboard shortcut for \"\(command.title)\" (\(command.id)) to what I ask, using `tiri keys set \(command.id) <key>`. Run `tiri keys` to see what's taken. Don't edit any file.")
            }
            Button("Remove Shortcut") { model.setShortcut(command.id, key: nil) }
            Button("Reset to Default") { model.resetShortcut(command.id) }
        }
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

struct PairsEditor: View {
    let firstPlaceholder: String
    let secondPlaceholder: String
    let pairs: [(String, String)]
    let commit: ([(String, String)]) -> Void
    @State private var addingRow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                HStack(spacing: 6) {
                    CommitField(placeholder: firstPlaceholder, text: pair.0) { replace(index, first: $0) }
                        .frame(width: 150)
                    CommitField(placeholder: secondPlaceholder, text: pair.1) { replace(index, second: $0) }
                    Button {
                        var updated = pairs
                        updated.remove(at: index)
                        commit(updated)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
            }
            if addingRow {
                NewPairRow(firstPlaceholder: firstPlaceholder, secondPlaceholder: secondPlaceholder) { first, second in
                    addingRow = false
                    if !first.isEmpty { commit(pairs + [(first, second)]) }
                }
            } else {
                Button {
                    addingRow = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func replace(_ index: Int, first: String? = nil, second: String? = nil) {
        var updated = pairs
        updated[index] = (first ?? updated[index].0, second ?? updated[index].1)
        commit(updated)
    }
}

struct NewPairRow: View {
    let firstPlaceholder: String
    let secondPlaceholder: String
    let done: (String, String) -> Void
    @State private var first = ""
    @State private var second = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(firstPlaceholder, text: $first)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            TextField(secondPlaceholder, text: $second)
                .textFieldStyle(.roundedBorder)
                .onSubmit { done(first, second) }
            Button("Add") { done(first, second) }
                .disabled(first.isEmpty)
        }
    }
}
