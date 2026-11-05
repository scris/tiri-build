import AppKit
import SwiftUI
import TiriCore

/// On the agent's tab, when its work can be tried. Never a dialog, and never over anything else's work.
struct ReadyCard: View {
    let copy: ReadyCopy
    @Environment(AppModel.self) private var model

    private var details: String {
        var parts = [copy.size]
        switch copy.checkPassed {
        case true?: parts.append("check passed")
        case false?: parts.append("check failed")
        case nil: break
        }
        return parts.joined(separator: ", ") + ". Tiri reopens with this, and your agents keep running."
    }

    var body: some View {
        CardShell(symbol: "sparkles", title: "Ready to try", sentence: copy.sentence, detail: details) {
            Button("Not Now") { model.yourTiri.notNow() }
                .controlSize(.regular)
            if copy.change != nil, copy.kind == .change {
                Button("See What Changed") { model.yourTiri.showDiff(of: copy) }
                    .controlSize(.regular)
            }
            Button("Try It") { model.yourTiri.tryReady() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }
}

/// While the agent works, because what's on this tab is otherwise a stranger's terminal.
struct MakingCard: View {
    let draft: ChangeDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        let row = draft.item.flatMap { item in model.agentRows.first { $0.item == item } }
        let agent = row?.agent ?? "Your agent"
        CardShell(symbol: "hammer", title: "\(agent) is rewriting Tiri", sentence: draft.sentence,
                  detail: row?.status == .needsInput ? "It needs you, below." : "This takes a few minutes, and Tiri says when it's ready.") {
            Button("Keep Working") { model.yourTiri.keepWorking() }
                .controlSize(.regular)
        }
    }
}

/// For the ten minutes after a switch. Going back loses nothing.
struct TrialCard: View {
    let trial: CopyState.Trial
    @Environment(AppModel.self) private var model

    private var detail: String {
        let keeps = "Keep it, or go back to how it was. It keeps itself after ten minutes."
        return trial.firstPersonal ? keeps + " macOS may ask about your folders once more." : keeps
    }

    var body: some View {
        CardShell(symbol: "checkmark.circle", title: "You're trying this", sentence: trial.sentence, detail: detail) {
            Button("Go Back") { model.yourTiri.back() }
                .controlSize(.regular)
            Button("Keep") { model.yourTiri.keep() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }
}

private struct CardShell<Buttons: View>: View {
    let symbol: String
    let title: String
    let sentence: String
    let detail: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(title). \(detail)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { buttons }
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - The list

/// The screen people will show each other: their Tiri, as sentences in their own words.
struct YourTiriPane: View {
    @Environment(AppModel.self) private var model

    private var yours: YourTiriModel { model.yourTiri }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let trial = yours.state?.trial { TrialRow(trial: trial) }
            // An update's copy goes in with its own one button, with the app it belongs to.
            if let ready = yours.ready, ready.kind != .update { ReadyRow(copy: ready) }
            if let draft = yours.draft { BeingMadeRow(draft: draft) }
            if yours.changes.isEmpty {
                EmptyYourTiri()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // One waiting to be tried is the row above, and isn't on yet.
                    ForEach(Array(yours.changes.reversed().filter { $0.id != yours.ready?.change }.enumerated()), id: \.element.id) { index, change in
                        if index > 0 { Divider().opacity(0.6) }
                        PersonalChangeRow(change: change)
                    }
                }
            }
            if yours.entriesAreOn {
                Button("Change Tiri…") { yours.beginChange(surface: nil) }
                    .controlSize(.large)
            }
            Divider()
            UpdateLine()
            RunningLine()
        }
        .onAppear { yours.refresh() }
    }
}

private struct EmptyYourTiri: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChangeStory(agent: model.yourTiri.chosenAgent(from: model.runnableAgentPresets())?.name ?? "Your agent")
            .frame(maxWidth: 620, alignment: .leading)
    }
}

private struct PersonalChangeRow: View {
    let change: PersonalChange
    @Environment(AppModel.self) private var model
    @AppStorage private var isOpen: Bool
    @State private var files: [String] = []

    init(change: PersonalChange) {
        self.change = change
        _isOpen = AppStorage(wrappedValue: false, "YourTiri.open.\(change.id)")
    }

    private static let dateFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated)

    var body: some View {
        let yours = model.yourTiri
        let isBuilding = yours.toggling.contains(change.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { isOpen.toggle() }
                } label: {
                    Text(change.sentence)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(change.isOn ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(change.size). Click for what it touched.")
                if change.repairedFor != nil {
                    Text("repaired")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(change.date, format: Self.dateFormat)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                if isBuilding {
                    ProgressView().controlSize(.small).frame(width: 38)
                } else {
                    Toggle("", isOn: Binding(get: { change.isOn }, set: { yours.setChange(change, on: $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            if isOpen {
                ChangeFiles(change: change, files: files)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 13)
        .onAppear { if isOpen { files = yours.filesIn(change) } }
        .onChange(of: isOpen) { _, open in if open { files = yours.filesIn(change) } }
    }
}

private struct ChangeFiles: View {
    let change: PersonalChange
    let files: [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(files, id: \.self) { file in
                Button {
                    model.openDiff(DiffSpec(path: YourTiri.source.appendingPathComponent(file).path, commit: change.commit), preview: false)
                } label: {
                    Text(file)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .underline(false)
                }
                .buttonStyle(.plain)
            }
            Text(change.hasCheck ? "Has a check, so updates can look after it." : "No check, so updates will ask you to look at it.")
                .font(.system(size: 12))
                .foregroundStyle(change.hasCheck ? Color.secondary : Color.orange)
                .padding(.top, 2)
            if let version = change.repairedFor {
                Text(repairLine(version))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func repairLine(_ version: String) -> String {
        guard !change.repairTouched.isEmpty else { return "Repaired for Tiri \(version), with nothing to change." }
        let names = change.repairTouched.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "Repaired for Tiri \(version), in \(names.formatted(.list(type: .and)))."
    }
}

private struct ReadyRow: View {
    let copy: ReadyCopy
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.sentence)
                    .font(.system(size: 15, weight: .semibold))
                Text("Ready to try")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try It") { model.yourTiri.tryReady() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

private struct TrialRow: View {
    let trial: CopyState.Trial
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trial.sentence)
                    .font(.system(size: 15, weight: .semibold))
                Text("You're trying this")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Go Back") { model.yourTiri.back() }
            Button("Keep") { model.yourTiri.keep() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

private struct BeingMadeRow: View {
    let draft: ChangeDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        let row = draft.item.flatMap { item in model.agentRows.first { $0.item == item } }
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.sentence)
                    .font(.system(size: 15))
                Text(row?.status == .needsInput ? "\(row?.agent ?? "Your agent") needs you" : "\(row?.agent ?? "Your agent") is making this")
                    .font(.system(size: 12))
                    .foregroundStyle(row?.status == .needsInput ? Color.orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let item = draft.item, model.anyItem(item) != nil {
                Button("Show") { model.focusItem(item) }
            } else {
                Button("Give Up") { model.yourTiri.giveUp() }
                    .help("Its agent has gone. This discards what it had edited.")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RunningLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let yours = model.yourTiri
        HStack(spacing: 12) {
            Text(yours.runningLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if yours.isPersonalCopy {
                Button("Plain Tiri") { yours.usePlain() }
                    .help("The app you installed, with none of these changes. They stay here.")
            } else if FileManager.default.fileExists(atPath: YourTiri.current.path) {
                Button("Back to Your Tiri") { yours.useYours() }
            }
        }
    }
}

/// The cards on one agent's tab. Along the top, over what's oldest: an agent's input is at the bottom.
struct YourTiriCards: View {
    let item: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        let yours = model.yourTiri
        VStack {
            if let trial = yours.trialForItem(item) {
                TrialCard(trial: trial)
            } else if let copy = yours.cardForItem(item) {
                ReadyCard(copy: copy)
            } else if let draft = yours.makingForItem(item) {
                MakingCard(draft: draft)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: yours.ready)
        .animation(.smooth(duration: 0.25), value: yours.draft)
        .animation(.smooth(duration: 0.25), value: yours.state?.trial)
    }
}

/// The one line about updates, and the one button, which only exists when it's all been done already.
struct UpdateLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let yours = model.yourTiri
        if let update = yours.update {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if [.replaying, .building, .checking].contains(update.phase) { ProgressView().controlSize(.small) }
                    Text(update.line)
                        .font(.system(size: 13))
                        .foregroundStyle(update.phase == .failed ? Color.orange : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if update.phase == .ready {
                        Button("Update") { yours.applyUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if update.phase == .needsRepair, yours.state?.repairsAllowed == nil, let preset = model.runnableAgentPresets().first {
                    HStack(spacing: 10) {
                        Text("\(preset.name) can redo it for you, now and at future updates.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Skip It") { yours.answerRepairs(false) }
                        Button("Redo It") { yours.answerRepairs(true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}
