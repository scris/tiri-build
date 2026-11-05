import SwiftUI
import TiriCore

extension AppModel {
    var agentEntries: [AgentEntry] { AgentRoster.entries(settings.terminalPresets) }

    private func writePresets(_ presets: [TerminalPreset]) {
        _ = setSetting("terminal.presets", to: TerminalPreset.json(presets))
    }

    /// Everything that offers agents reads the one list, so this is all it takes.
    private func changeRoster(_ change: ([TerminalPreset]) throws -> [TerminalPreset]) -> String? {
        do {
            let updated = try change(settings.terminalPresets)
            if updated != settings.terminalPresets { writePresets(updated) }
            refreshAvailableCommands()
            return nil
        } catch {
            return "\(error)"
        }
    }

    @discardableResult
    func setAgent(_ query: String, enabled: Bool) -> String? {
        let problem = changeRoster { try AgentRoster.setEnabled(enabled, query, in: $0) }
        // One that comes back should come back whole, wherever else it had been taken out.
        if problem == nil, enabled, let entry = AgentRoster.find(query, in: settings.terminalPresets),
           let command = entry.profile?.continueCommand, settings.terminalResume[entry.id] == nil {
            setResume(entry.id, command: command)
        }
        return problem
    }

    @discardableResult
    func addAgent(name: String, command: String) -> String? {
        let problem = changeRoster { try AgentRoster.add(name: name, command: command, to: $0) }
        if let tool = AgentRoster.tool(of: command), let resume = AgentCatalog.profile(executable: tool)?.continueCommand, problem == nil, settings.terminalResume[tool] == nil {
            setResume(tool, command: resume)
        }
        return problem
    }

    @discardableResult
    func removeAgent(_ query: String) -> String? {
        let entry = AgentRoster.find(query, in: settings.terminalPresets)
        let problem = changeRoster { try AgentRoster.remove(query, from: $0) }
        // Yours is gone altogether. One of Tiri's own only went quiet, and keeps how it resumes.
        if problem == nil, let entry, entry.isCustom, settings.terminalResume[entry.id] != nil {
            setResume(entry.id, command: nil)
        }
        return problem
    }

    @discardableResult
    func updateAgent(_ id: String, name: String, command: String) -> String? {
        changeRoster { try AgentRoster.update(id, name: name, command: command, in: $0) }
    }

    func setResume(_ tool: String, command: String?) {
        var map = settings.terminalResume
        map[tool] = command
        _ = setSetting("terminal.resume", to: .object(map.mapValues(JSONValue.string)))
    }

    func openAgentSettings() { openSettings(pane: .agents) }

    func isAgentEnabled(_ agent: AgentIdentity) -> Bool {
        agentEntries.first { $0.agent == agent }?.isEnabled ?? false
    }
}

/// Every agent in one place: whether it's on, how it runs, how it reports and how it comes back.
struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        SettingsGroup("Your Agents", caption: "Tiri only offers the ones that are on, in the + menu and everywhere else.") {
            SettingsCard {
                let entries = model.agentEntries
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SettingsRowDivider() }
                    AgentRow(entry: entry)
                }
                SettingsRowDivider()
                addRow
            }
        }
        .onAppear { model.refreshAvailableCommands() }
    }

    @ViewBuilder private var addRow: some View {
        if adding {
            VStack(alignment: .leading, spacing: 6) {
                if rowsStack {
                    newNameField
                    newCommandField
                    HStack(spacing: 8) { addButtons }
                } else {
                    HStack(spacing: 8) {
                        newNameField.frame(maxWidth: 150)
                        newCommandField
                        addButtons
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        } else {
            Button {
                adding = true
            } label: {
                Label("Add an Agent", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var newNameField: some View {
        TextField("Name", text: $newName)
            .textFieldStyle(.roundedBorder)
    }

    private var newCommandField: some View {
        TextField("Command, like aider", text: $newCommand)
            .textFieldStyle(.roundedBorder)
            .onSubmit(add)
    }

    @ViewBuilder private var addButtons: some View {
        Button("Add", action: add)
            .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Cancel") {
            adding = false
            problem = nil
        }
    }

    private func add() {
        problem = model.addAgent(name: newName, command: newCommand)
        guard problem == nil else { return }
        newName = ""
        newCommand = ""
        adding = false
    }
}

struct AgentRow: View {
    let entry: AgentEntry
    @Environment(AppModel.self) private var model
    @Environment(\.settingsRowsStack) private var rowsStack
    @State private var problem: String?

    private var expanded: Bool { model.settingsUI.expandedAgent == entry.id }

    /// Nil until the shell has answered, so nothing is called missing on a guess.
    private var isFound: Bool? {
        guard let found = model.availableCommands else { return nil }
        return found.contains(entry.id) || !ShellLookup.isPlainName(entry.id)
    }

    private var detail: String {
        guard entry.isEnabled else { return "Off. Any session already running carries on." }
        if isFound == false { return "On, but your shell can't find \(entry.id)." }
        guard let agent = entry.agent, agent.profile?.hookInstall != nil else {
            return "Runs \(entry.command). Tiri guesses when it's working from terminal activity."
        }
        if model.hooksInstalled(agent) { return "Hooks tell Tiri exactly when it's working, waiting or done." }
        if let other = model.hooksCoverage(agent) { return "Tells Tiri when it's working through your \(other.title) hooks, once you trust a folder." }
        return "Tiri guesses when it's working from terminal activity. Hooks tell it exactly."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.smooth(duration: 0.15)) {
                        model.settingsUI.expandedAgent = expanded ? nil : entry.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: entry.profile?.symbol ?? "terminal")
                            .foregroundStyle(entry.isEnabled ? .secondary : .tertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide its commands" : "Its name and commands")
                .accessibilityLabel(expanded ? "Hide details for \(entry.name)" : "Show details for \(entry.name)")
                if !rowsStack { actions }
                Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { model.setAgent(entry.id, enabled: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(entry.isEnabled ? "Turn \(entry.name) off" : "Turn \(entry.name) on")
                    .accessibilityLabel("Use \(entry.name)")
            }
            if rowsStack { actions.padding(.leading, 38) }
            if expanded { details }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// What it's missing, if anything.
    @ViewBuilder private var actions: some View {
        if entry.isEnabled, isFound == false, let website = entry.profile?.website, let url = URL(string: website) {
            Link("Get It", destination: url)
                .font(.caption)
        }
        if entry.isEnabled, isFound != false, let agent = entry.agent, agent.profile?.hookInstall != nil, !model.hooksInstalled(agent) {
            Button("Install Hooks…") { model.confirmHooks(agent, install: true) }
                .controlSize(.small)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Name", value: entry.name, placeholder: "Name") { problem = model.updateAgent(entry.id, name: $0, command: entry.command) }
            field("Command", value: entry.command, placeholder: "What runs it") { problem = model.updateAgent(entry.id, name: entry.name, command: $0) }
            field("To resume", value: model.settings.terminalResume[entry.id] ?? "", placeholder: "How it comes back after a relaunch") {
                model.setResume(entry.id, command: $0.isEmpty ? nil : $0)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let removesHooks = entry.agent.map { model.hooksInstalled($0) } ?? false
            if removesHooks || entry.isCustom {
                HStack(spacing: 8) {
                    if removesHooks, let agent = entry.agent {
                        Button("Remove Hooks…") { model.confirmHooks(agent, install: false) }
                    }
                    if entry.isCustom {
                        Button("Delete \(entry.name)") { model.removeAgent(entry.id) }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 70)
                .padding(.top, 2)
            }
        }
        .padding(.leading, rowsStack ? 0 : 38)
    }

    private func field(_ label: String, value: String, placeholder: String, commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            CommitField(placeholder: placeholder, text: value, commit: commit)
                .accessibilityLabel(label)
        }
    }
}
