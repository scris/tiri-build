import SwiftUI
import TiriCore

/// Settings → Run: one row per kind of file, each with its switch and the command it runs. Ones whose program
/// isn't on this Mac fold away, and kinds Tiri doesn't know can be added at the end.
struct RunLanguagesSection: View {
    /// Just these, for a search. Otherwise every language, and what's been added.
    var only: [RunLanguage]?

    @Environment(AppModel.self) private var model
    @State private var showsMissing = false
    @State private var adding = false

    static func matching(_ query: String) -> [RunLanguage] {
        RunCommands.languages.filter {
            SettingsSchema.matches(query, in: [$0.name, $0.id, $0.shownExtensions, $0.command, "run", String(localized: "Run")])
        }
    }

    private struct Entry: Identifiable {
        var key: String
        var name: String
        var extensions: String
        var standard: String?
        var id: String { key }
    }

    private var entries: [Entry] {
        (only ?? RunCommands.languages).map { Entry(key: $0.id, name: $0.name, extensions: $0.shownExtensions, standard: $0.command) }
    }

    private var added: [Entry] {
        guard only == nil else { return [] }
        return model.settings.runCommands.keys.filter { $0.hasPrefix(".") }.sorted()
            .map { Entry(key: $0, name: $0, extensions: "", standard: nil) }
    }

    private func isMissing(_ entry: Entry) -> Bool {
        guard let tool = RunCommands.tool(of: command(entry)) else { return false }
        return model.runner.located[tool] == false
    }

    private func command(_ entry: Entry) -> String { model.settings.runCommands[entry.key] ?? entry.standard ?? "" }

    /// Which rows are folded is settled once, when the shell has said what's here, so a row never jumps away while you type in it.
    @State private var foldedKeys: Set<String>?

    private func settleFold() {
        guard foldedKeys == nil, !model.runner.located.isEmpty else { return }
        foldedKeys = Set(entries.filter { isMissing($0) && model.settings.runCommands[$0.key] == nil }.map(\.key))
    }

    /// A row someone was sent to is never left folded.
    private func unfoldForReveal() {
        guard let target = model.settingsUI.reveal, target.hasPrefix("run."),
              foldedKeys?.contains(String(target.dropFirst(4))) == true else { return }
        showsMissing = true
    }

    var body: some View {
        let all = entries
        // Folded only when it's known to be missing and nobody's changed it.
        let folded = only == nil ? all.filter { foldedKeys?.contains($0.key) == true } : []
        let shown = all.filter { entry in !folded.contains { $0.key == entry.key } } + added
        SettingsGroup(only == nil ? String(localized: "Languages") : "") {
            SettingsCard {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SettingsRowDivider() }
                    row(entry)
                }
                if only == nil {
                    SettingsRowDivider()
                    if adding || model.runner.adding != nil {
                        AddRunFileType(ext: model.runner.adding ?? "") {
                            adding = false
                            model.runner.adding = nil
                        }
                    } else {
                        Button {
                            adding = true
                        } label: {
                            Label("Add a File Type", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !folded.isEmpty {
                Button {
                    withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.2))) { showsMissing.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showsMissing ? 90 : 0))
                        Text("Not on this Mac (\(folded.count))")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.top, 4)
                if showsMissing {
                    SettingsCard {
                        ForEach(Array(folded.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { SettingsRowDivider() }
                            row(entry)
                        }
                    }
                }
            }
        }
        .onAppear {
            model.runner.lookForTools()
            settleFold()
            unfoldForReveal()
        }
        .onChange(of: model.runner.located) { _, _ in
            settleFold()
            unfoldForReveal()
        }
        .onChange(of: model.settingsUI.reveal) { _, _ in unfoldForReveal() }
    }

    private func row(_ entry: Entry) -> some View {
        RunLanguageRow(key: entry.key, name: entry.name, extensions: entry.extensions, standard: entry.standard,
                       command: command(entry), isOn: !model.settings.runOff.contains(entry.key),
                       missingTool: isMissing(entry) ? RunCommands.tool(of: command(entry)) : nil)
    }
}

private struct RunLanguageRow: View {
    let key: String
    let name: String
    let extensions: String
    /// Nil for a kind of file someone added.
    let standard: String?
    let command: String
    let isOn: Bool
    let missingTool: String?

    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var editing: Bool

    private var isAdded: Bool { standard == nil }
    private var isChanged: Bool { standard.map { $0 != command } ?? false }
    /// What it would type for a file of this kind, as you edit.
    private var example: String {
        let ext = isAdded ? key : (RunCommands.language(key)?.extensions.first.map { "." + $0 } ?? "")
        return RunCommands.expand(draft, path: "/tmp/hello" + ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rowsStack {
                words
                HStack(spacing: 10) { field; trailing }
            } else {
                HStack(spacing: 12) {
                    words.frame(width: 118, alignment: .leading)
                    field
                    trailing
                }
            }
            if editing, !draft.trimmingCharacters(in: .whitespaces).isEmpty, example != draft {
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, rowsStack ? 7 : 137)
                    .accessibilityLabel(String(localized: "Runs \(example)"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(RevealableRow(id: "run.\(key)"))
        .contextMenu {
            if isChanged { Button("Reset to Default") { setCommand(standard ?? "") } }
            if isAdded { Button("Remove") { remove() } }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: name)
            if let missingTool {
                Text("Needs \(missingTool)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !extensions.isEmpty {
                Text(verbatim: extensions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(isOn ? 1 : 0.5)
    }

    private var field: some View {
        // Reads as the command itself, and shows it's a field when you point at it or type in it.
        TextField(standard ?? "", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(editing ? 0.09 : hovering ? 0.05 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(editing ? 0.7 : 0), lineWidth: 1)
                    }
            }
            .onHover { hovering = $0 }
            .focused($editing)
            .disabled(!isOn)
            .opacity(isOn ? 1 : 0.5)
            .onAppear { draft = command }
            .onChange(of: command) { _, value in if !editing { draft = value } }
            .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
            .onSubmit { commit() }
            .help("$file is the file, $name it without its extension, $dir its folder, $out a place in /tmp for a compiled program")
            .accessibilityLabel(String(localized: "Command for \(name)"))
    }

    @ViewBuilder private var trailing: some View {
        if isChanged {
            Button {
                setCommand(standard ?? "")
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the default: \(standard ?? "")")
            .accessibilityLabel(String(localized: "Reset \(name)"))
        } else if isAdded {
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove \(name)")
            .accessibilityLabel(String(localized: "Remove \(name)"))
        }
        Toggle("", isOn: Binding(get: { isOn }, set: { setOn($0) }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Run \(name) files"))
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptied, a language goes back to its own command, and an added kind keeps the one it had.
        if text.isEmpty { draft = command; if !isAdded { setCommand(standard ?? "") }; return }
        if text != command { setCommand(text) }
    }

    private func setCommand(_ text: String) {
        var commands = model.settings.runCommands
        if let standard, text == standard { commands[key] = nil } else { commands[key] = text }
        draft = text
        _ = model.setSetting("run.commands", to: .object(commands.mapValues(JSONValue.string)))
    }

    private func setOn(_ on: Bool) {
        var off = model.settings.runOff.filter { $0 != key }
        if !on { off.append(key) }
        _ = model.setSetting("run.off", to: .array(off.map(JSONValue.string)))
    }

    private func remove() {
        var commands = model.settings.runCommands
        commands[key] = nil
        _ = model.setSetting("run.commands", to: .object(commands.mapValues(JSONValue.string)))
        if model.settings.runOff.contains(key) { setOn(true) }
    }
}

/// The last row, while adding: which extension, and what runs it.
private struct AddRunFileType: View {
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var ext: String
    @State private var command = ""

    init(ext: String, done: @escaping () -> Void) {
        _ext = State(initialValue: ext)
        self.done = done
    }
    @FocusState private var focus: Field?
    private enum Field { case ext, command }

    /// An example, not words.
    private static let extensionHint = ".kt"

    private var tidy: String? { RunCommands.tidyExtension(ext) }
    private var canAdd: Bool { tidy != nil && !command.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            TextField(Self.extensionHint, text: $ext)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 80)
                .focused($focus, equals: .ext)
                .onSubmit { focus = .command }
                .accessibilityLabel(String(localized: "File extension"))
            TextField("Command, like kotlin $file", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .focused($focus, equals: .command)
                .onSubmit(add)
                .accessibilityLabel(String(localized: "Command"))
            Button("Add", action: add)
                .disabled(!canAdd)
            Button("Cancel", action: done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { focus = ext.isEmpty ? .ext : .command }
        .onExitCommand(perform: done)
    }

    private func add() {
        guard canAdd, let tidy else { return }
        var commands = model.settings.runCommands
        commands[tidy] = command.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = model.setSetting("run.commands", to: .object(commands.mapValues(JSONValue.string)))
        done()
    }
}
