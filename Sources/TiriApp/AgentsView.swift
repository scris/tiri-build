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

    func openAgentSettings() {
        openSettings()
        settingsAnchor = AgentsSection.anchor
    }

    func isAgentEnabled(_ agent: AgentIdentity) -> Bool {
        agentEntries.first { $0.agent == agent }?.isEnabled ?? false
    }
}

/// Every agent in one place: whether it's on, how it runs, how it reports and how it comes back.
struct AgentsSection: View {
    static let anchor = "agents"
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Your Agents").font(.headline)
                Text("Only the ones that are on appear in the + menu, on a new workspace and everywhere else Tiri offers them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                let entries = model.agentEntries
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    AgentRow(entry: entry)
                }
                Divider()
                addRow
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
        .id(Self.anchor)
        .onAppear { model.refreshAvailableCommands() }
    }

    @ViewBuilder private var addRow: some View {
        if adding {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    TextField("Command, like aider", text: $newCommand)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        adding = false
                        problem = nil
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
    @State private var expanded = false
    @State private var problem: String?

    /// Nil until the shell has answered, so nothing is called missing on a guess.
    private var isFound: Bool? {
        guard let found = model.availableCommands else { return nil }
        return found.contains(entry.id) || !ShellLookup.isPlainName(entry.id)
    }

    private var detail: String {
        guard entry.isEnabled else { return "Off. Tiri won't offer it. Sessions already running carry on." }
        if isFound == false { return "On, but your shell can't find \(entry.id)." }
        guard let agent = entry.agent, agent.profile?.hookInstall != nil else {
            return "Runs \(entry.command). Takes files and lines as plain text. Tiri estimates its status."
        }
        if model.hooksInstalled(agent) { return "Reports exactly when it's working, waiting for you or done, and resumes the right conversation." }
        if let other = model.hooksCoverage(agent) { return "Reports through your \(other.title) hooks, which it runs too. It asks you to trust a folder before they do." }
        return "Tiri is estimating its status from terminal activity. A hook makes it exact."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
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
                if entry.isEnabled, isFound == false, let website = entry.profile?.website, let url = URL(string: website) {
                    Link("Get It", destination: url)
                        .font(.caption)
                }
                if entry.isEnabled, isFound != false, let agent = entry.agent, agent.profile?.hookInstall != nil {
                    let installed = model.hooksInstalled(agent)
                    Button(installed ? "Remove Hooks" : "Install…") { model.confirmHooks(agent, install: !installed) }
                        .controlSize(.small)
                }
                Button {
                    withAnimation(.smooth(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(expanded ? "Hide its commands" : "Its name and commands")
                .accessibilityLabel(expanded ? "Hide details for \(entry.name)" : "Show details for \(entry.name)")
                if entry.isCustom {
                    Button {
                        model.removeAgent(entry.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete \(entry.name)")
                    .accessibilityLabel("Delete \(entry.name)")
                }
                Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { model.setAgent(entry.id, enabled: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(entry.isEnabled ? "Turn \(entry.name) off" : "Turn \(entry.name) on")
                    .accessibilityLabel("Use \(entry.name)")
            }
            if expanded { details }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        }
        .padding(.leading, 28)
    }

    private func field(_ label: String, value: String, placeholder: String, commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            CommitField(placeholder: placeholder, text: value, commit: commit)
        }
    }
}
