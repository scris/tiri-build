import SwiftUI
import TiriCore

/// Every command and its keys, under headings, with the ones you can't remember easy to find.
struct KeyboardSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @Environment(\.settingsIsTight) private var isTight

    var body: some View {
        let sections = model.shortcutSectionsShown
        VStack(alignment: .leading, spacing: 20) {
            // Beside the panes there's room for one row, and the jumps are in the list.
            if isTight {
                VStack(alignment: .leading, spacing: 8) {
                    filterPicker
                    HStack(spacing: 8) {
                        jumpMenu(sections)
                        findByKey
                    }
                }
            } else {
                HStack(spacing: 12) {
                    filterPicker
                    Spacer(minLength: 0)
                    findByKey
                }
            }
            if sections.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ShortcutSections(sections: sections, tracksPosition: true)
            }
        }
    }

    /// The same jumps as the list beside the page, for when that's folded into a menu.
    private func jumpMenu(_ sections: [ShortcutSection]) -> some View {
        Menu("Jump To") {
            ForEach(sections) { section in
                Button(section.shownName) { model.settingsUI.jump(to: section.name) }
            }
        }
        .fixedSize()
    }

    private var filterPicker: some View {
        @Bindable var ui = model.settingsUI
        let picker = Picker("", selection: $ui.shortcutFilter) {
            ForEach(ShortcutFilter.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!ui.shortcutKeys.isEmpty)
        .accessibilityLabel("Show")
        return Group {
            if rowsStack {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
    }

    private var emptyMessage: String {
        let ui = model.settingsUI
        if !ui.shortcutKeys.isEmpty { return String(localized: "Nothing uses \(ui.shortcutKeys.map(\.symbol).joined(separator: " ")). It's free to use.") }
        switch ui.shortcutFilter {
        case .changed: return String(localized: "You haven't changed any shortcuts.")
        default: return String(localized: "No commands here.")
        }
    }

    /// What does this key do, and is it free?
    @ViewBuilder private var findByKey: some View {
        let ui = model.settingsUI
        if model.isFindingShortcutKey {
            Button("Press a Key…") { model.cancelFindingShortcutKey() }
                .fixedSize()
                .help("Click or press Esc to cancel")
        } else if !ui.shortcutKeys.isEmpty {
            HStack(spacing: 6) {
                KeyCaps(strokes: ui.shortcutKeys)
                Button {
                    ui.shortcutKeys = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show every command again")
                .accessibilityLabel("Stop finding by key")
            }
        } else {
            Button("Find by Key…") { model.beginFindingShortcutKey() }
                .fixedSize()
                .help("Press a key to see what it does")
        }
    }
}

extension AppModel {
    /// What the Keyboard pane lists right now, with its filter and any key being looked up.
    var shortcutSectionsShown: [ShortcutSection] {
        ShortcutIndex.sections(commands: shortcutCommands, bindings: keybindings, changed: changedShortcuts,
                               filter: settingsUI.shortcutFilter, keys: settingsUI.shortcutKeys)
    }
}

/// Every heading in the Keyboard pane, under its name beside the page. Marks the one you're at.
struct ShortcutJumpList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ui = model.settingsUI
        let sections = model.shortcutSectionsShown
        let current = sections.contains { $0.name == ui.currentSection } ? ui.currentSection : sections.first?.name
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                ShortcutJumpRow(name: section.name, shownName: section.shownName, isCurrent: section.name == current)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ShortcutJumpRow: View {
    let name: String
    let shownName: String
    let isCurrent: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.settingsUI.jump(to: name)
        } label: {
            Text(shownName)
                .font(.callout)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .frame(height: 23)
                .currentMark(isCurrent, hovering: hovering, cornerRadius: 5, strength: 0.07)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Jump to \(shownName)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct ShortcutSections: View {
    let sections: [ShortcutSection]
    var tracksPosition = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let bindings = Dictionary(grouping: model.keybindings, by: \.command)
        let changed = model.changedShortcuts
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections) { section in
                SettingsGroup(section.shownName) {
                    SettingsCard {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { SettingsRowDivider() }
                            switch row {
                            case .command(let command):
                                ShortcutRowView(command: command, bindings: bindings[command.id] ?? [], isChanged: changed.contains(command.id))
                            case .family(let id, let title, let members):
                                ShortcutFamilyRow(id: id, title: title, members: members, bindings: bindings, changed: changed)
                            }
                        }
                    }
                }
                // Just above the heading, so a jump leaves room over it.
                .background(alignment: .top) {
                    Color.clear.frame(height: 1).offset(y: -14).id(section.name)
                }
                .background {
                    if tracksPosition {
                        GeometryReader { place in
                            Color.clear.preference(key: SectionPositions.self, value: [section.name: place.frame(in: .named(SettingsContent.page)).minY])
                        }
                    }
                }
            }
        }
    }
}

/// Keys as they are on the keyboard: one cap for each press.
struct KeyCaps: View {
    let strokes: [KeyStroke]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(strokes.enumerated()), id: \.offset) { _, stroke in
                Text(stroke.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(Color.primary.opacity(0.09), in: .rect(cornerRadius: 5))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ShortcutRowView: View {
    let command: ShortcutCommand
    let bindings: [Keybinding]
    let isChanged: Bool
    var indent: CGFloat = 0
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var hovering = false

    private var isRecording: Bool { model.recordingShortcutFor == command.id }

    private var notice: ShortcutNotice? {
        guard let notice = model.shortcutNotice, notice.command == command.id else { return nil }
        return notice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(command.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isChanged, !isRecording {
                    Button {
                        model.resetShortcut(command.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to the default")
                    .accessibilityLabel("Reset the shortcut for \(command.title)")
                }
                keysButton
            }
            if isRecording {
                caption(String(localized: "Press the keys, or ⌫ to remove it. Esc cancels."))
            }
            if let notice { noticeView(notice) }
        }
        .padding(.leading, 12 + indent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(RevealableRow(id: command.id))
        .contextMenu {
            Button("Copy Prompt About This Shortcut") {
                Clipboard.copy("Change the Tiri keyboard shortcut for \"\(command.englishTitle)\" (\(command.id)) to what I ask, using `tiri keys set \(command.id) <key>`. Run `tiri keys` to see what's taken. Don't edit any file.")
            }
            Button("Remove Shortcut") { model.setShortcut(command.id, key: nil) }
            Button("Reset to Default") { model.resetShortcut(command.id) }
        }
    }

    private var keysButton: some View {
        Button {
            if isRecording {
                model.cancelRecordingShortcut()
            } else {
                model.beginRecordingShortcut(for: command.id)
            }
        } label: {
            keysLabel
                .fixedSize()
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .overlay {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bindings.isEmpty ? String(localized: "Click, then press the keys") : String(localized: "Click to change it"))
        .accessibilityLabel(bindings.isEmpty ? String(localized: "Add a shortcut for \(command.title)")
            : String(localized: "Change the shortcut for \(command.title), now \(bindings.map(\.symbol).formatted(.list(type: .or)))"))
    }

    @ViewBuilder private var keysLabel: some View {
        if isRecording {
            if model.recordedStrokes.isEmpty {
                Text("Press Keys…")
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
            } else {
                KeyCaps(strokes: model.recordedStrokes)
            }
        } else if bindings.isEmpty {
            // A hundred buttons saying Add say nothing. It's here when you point at the command.
            Text("Add Shortcut")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .opacity(hovering ? 1 : 0)
        } else {
            HStack(spacing: 5) {
                ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                    if index > 0 {
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    KeyCaps(strokes: binding.strokes)
                }
            }
        }
    }

    @ViewBuilder private func noticeView(_ notice: ShortcutNotice) -> some View {
        switch notice {
        case .problem(_, let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .conflict(_, let key, let holders):
            let symbol = Keymap.parseStrokes(key)?.map(\.symbol).joined(separator: " ") ?? key
            HStack(spacing: 8) {
                Text(holders.count == 1 ? String(localized: "\(symbol) is \(holders.formatted(.list(type: .and))). Replacing it leaves that without this key.")
                    : String(localized: "\(symbol) is \(holders.formatted(.list(type: .and))). Replacing it leaves those without this key."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Replace") { model.confirmShortcutConflict() }
                    .controlSize(.small)
                Button("Cancel") { model.shortcutNotice = nil }
                    .controlSize(.small)
            }
            .padding(.trailing, 4)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Focus Group 1 to 9 is one idea, not nine rows.
struct ShortcutFamilyRow: View {
    let id: String
    let title: String
    let members: [ShortcutCommand]
    let bindings: [String: [Keybinding]]
    let changed: Set<String>
    @State private var expanded = false

    /// The first and last keys, when each member has one.
    private var range: (first: [KeyStroke], last: [KeyStroke])? {
        let keys = members.compactMap { bindings[$0.id]?.first?.strokes }
        guard keys.count == members.count, let first = keys.first, let last = keys.last else { return nil }
        return (first, last)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(AccessibilityDisplay.shared.motion(.smooth(duration: 0.15))) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !expanded {
                        if let range {
                            HStack(spacing: 5) {
                                KeyCaps(strokes: range.first)
                                Text("to")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                KeyCaps(strokes: range.last)
                            }
                            .padding(.horizontal, 4)
                        } else {
                            Text("Some changed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? String(localized: "Hide \(title)") : String(localized: "Show \(title)"))
            if expanded {
                ForEach(members) { member in
                    SettingsRowDivider()
                    ShortcutRowView(command: member, bindings: bindings[member.id] ?? [], isChanged: changed.contains(member.id), indent: 18)
                }
            }
        }
    }
}
