import AppKit
import IOKit.ps
import SwiftUI
import TiriCore

/// Something about changes that's waiting for you, wherever you are.
struct YourTiriWaiting {
    struct Action: Identifiable {
        var id: String { title }
        let title: String
        var isMain = false
        let run: () -> Void
    }

    var text: String
    var symbol = "sparkles"
    var isBusy = false
    var isTrouble = false
    var actions: [Action] = []
    /// Set when it can be put off: what it's remembered by, so that something new to say comes back at once.
    var laterKey: String?
}

/// The part of the window someone marked to say what they mean.
struct ChangeMark {
    let image: NSImage
    let file: URL
}

/// Everything the app itself does about Your Tiri: pointing, the card, trying, keeping, going back.
/// `tiri change` does the making. Switching is only here, behind a click, where an agent can't reach it.
@Observable final class YourTiriModel {
    private(set) var state: CopyState?
    private(set) var ready: ReadyCopy?
    private(set) var draft: ChangeDraft?
    private(set) var changes: [PersonalChange] = []
    private(set) var update: UpdateStatus?
    /// Changes being turned on or off, whose copy is building.
    private(set) var toggling: Set<String> = []
    private(set) var isUpdating = false
    /// A card you said Not now to, until another copy is ready.
    private var dismissedReady: Date?
    /// What someone said Later to in the bar, and when. Back after a while, at the next launch, or when there's news.
    private var putOff: [String: Date] = [:]
    static let putOffFor: TimeInterval = 3 * 3600
    /// Being dragged around right now, with the window dimmed.
    private(set) var isMarking = false
    /// The box being dragged, in the window's content coordinates from the top left.
    private(set) var markingBox: CGRect?
    @ObservationIgnored private var markingStart: CGPoint?
    private(set) var mark: ChangeMark?
    private var chosenAgentName = UserDefaults.standard.string(forKey: "YourTiri.agent")
    /// Where someone was when they asked, for Keep Working to go back to.
    private var cameFrom: WorkspaceID?
    private var hidMaking: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var trialTimer: Timer?
    @ObservationIgnored private var repairing: String?
    @ObservationIgnored private var isResumingUpdate = false
    @ObservationIgnored private var resumedReleases: Set<String> = []
    @ObservationIgnored private var updateTimer: Timer?
    @ObservationIgnored private var markingQuery = ""
    @ObservationIgnored private var announcedUpdate: String?
    /// What was said about the update last. A step later, or once answered, it's out of date and goes.
    @ObservationIgnored private var updateToast: UUID?

    let isPersonalCopy = Bundle.main.object(forInfoDictionaryKey: YourTiri.copyKey) as? String == "personal"

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Being here at all

    /// Someone who's never changed anything has no file, and nothing else here runs for them.
    func finishLaunching() {
        guard var loaded = CopyState.load() else { return }
        if !isPersonalCopy {
            // The app may have moved, and may have been updated.
            loaded.plainPath = Bundle.main.bundlePath
            loaded.plainBundleID = Bundle.main.bundleIdentifier
            loaded.plainVersion = Self.version
        }
        if let trial = loaded.trial, trial.hasExpired(now: Date()) { loaded.trial = nil }
        if let id = loaded.rejectedChange {
            // It kept a copy from starting. Off, so that the next copy doesn't have it too. Kept, so it can be mended.
            loaded.rejectedChange = nil
            Task.detached {
                let repo = SourceRepo()
                if let change = try? repo.change(named: id) { try? repo.turnOff(change) }
            }
        }
        let notice = loaded.notice
        let news = loaded.news
        loaded.notice = nil
        loaded.news = nil
        try? loaded.save()
        state = loaded
        refresh()
        watchTrial()
        watchForUpdates()
        if PlainForNow.isOn {
            model?.showToast(title: "Plain Tiri, for this run", detail: "Your changes are still yours. They'll be back next time.", symbol: "option", tint: .secondary,
                             actionTitle: "Back to Your Tiri", duration: 12) { [weak self] in self?.useYours() }
        }
        if let trial = loaded.trial, model?.active.activeItem?.id != trial.item {
            model?.showToast(title: "You're trying your change", detail: trial.sentence, symbol: "checkmark.circle", tint: .accentColor,
                             actionTitle: "Go Back", duration: 15) { [weak self] in self?.back() }
        }
        if let notice {
            model?.showToast(title: "Back to a copy that starts", detail: notice, symbol: "arrow.uturn.backward", tint: .orange, duration: 20)
        }
        if let news {
            model?.showToast(title: news.title, detail: news.detail, symbol: news.retired ? "checkmark.seal" : "arrow.down.circle",
                             tint: .accentColor, duration: news.retired ? 20 : 8)
        }
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? TiriCoreVersion.string }

    /// The app people installed, and the first thing `tiri change` asks.
    func recordFacts() {
        var current = CopyState.load() ?? CopyState()
        if !isPersonalCopy {
            current.plainPath = Bundle.main.bundlePath
            current.plainBundleID = Bundle.main.bundleIdentifier
            current.plainVersion = Self.version
        }
        try? current.save()
        state = current
    }

    /// Everything the list and the card show. Files and Git, so it's off the main thread.
    func refresh() {
        Task.detached { [weak self] in
            let read = (CopyState.load(), ReadyCopy.load(), ChangeTools.loadDraft(), (try? SourceRepo().changes()) ?? [], UpdateStatus.load())
            await MainActor.run { [weak self] in
                guard let self else { return }
                let wasReady = self.ready
                (self.state, self.ready, self.draft, self.changes, self.update) = read
                if let ready = self.ready, ready != wasReady { self.announce(ready) }
                self.announceUpdate()
                self.startRepairIfAllowed()
                self.resumeWaitingUpdate()
                self.leaveOutIfRepairsAreOff()
            }
        }
    }

    /// At the moment it's ready, with the button right there. An update has its own announcement.
    private func announce(_ ready: ReadyCopy) {
        dismissedReady = nil
        guard let model, ready.kind != .update, wasBuiltJustNow(ready) else { return }
        if let item = ready.item, model.active.activeItem?.id == item { return }
        model.showToast(title: "Ready to try", detail: ready.sentence, symbol: "sparkles", tint: .accentColor,
                        actionTitle: "Try It", duration: 15) { [weak self] in self?.tryReady() }
    }

    private func wasBuiltJustNow(_ ready: ReadyCopy) -> Bool { Date().timeIntervalSince(ready.builtAt) < 60 }

    /// Once for each thing an update comes to need. It stays in the bar along the bottom after this.
    private func announceUpdate() {
        guard let model, let update, entriesOrUsed else { return }
        let key = "\(update.newRelease)-\(update.phase)"
        guard key != announcedUpdate else { return }
        announcedUpdate = key
        if let updateToast { model.dismissToast(updateToast) }
        updateToast = nil
        switch update.phase {
        case .ready:
            // What retired leads: it's the one thing the update did that nobody would otherwise know. Short, then
            // what to do, then their own words, which are long and can be cut.
            let rest = update.line.replacingOccurrences(of: "\(update.name) is ready, with", with: "With").replacingOccurrences(of: "\(update.name) is ready.", with: "")
                .trimmingCharacters(in: .whitespaces)
            if update.retired.isEmpty {
                updateToast = model.showToast(title: "\(update.name) is ready", detail: rest.isEmpty ? nil : rest, symbol: "arrow.down.circle", tint: .accentColor,
                                              actionTitle: "Update", duration: 30) { [weak self] in self?.applyUpdate() }
            } else {
                let which = update.retired.count == 1 ? "your change" : "\(update.retired.count) of your changes"
                updateToast = model.showToast(title: "Tiri does \(which) itself now", detail: "Update to use Tiri's own. \(UpdateStatus.names(update.retired))",
                                              symbol: "checkmark.seal", tint: .accentColor, actionTitle: "Update", duration: 30) { [weak self] in self?.applyUpdate() }
            }
        case .needsRepair where state?.repairsAllowed == nil && !update.needsRepair.isEmpty:
            updateToast = model.showToast(title: update.needsRepair.count == 1 ? "Your change needs redoing" : "\(update.needsRepair.count) of your changes need redoing",
                            detail: Self.redoExplained(update, agent: agentName), symbol: "arrow.down.circle", tint: .accentColor,
                            actionTitle: "Redo It", duration: 30) { [weak self] in self?.answerRepairs(true) }
        default: break
        }
    }

    private var entriesOrUsed: Bool { entriesAreOn || isUsed }

    private var agentName: String { model?.runnableAgentPresets().first?.name ?? "Your agent" }

    /// Before anything is redone, what happened, in a line: the new Tiri is here, and a change of theirs doesn't fit it.
    static func redoTitle(_ update: UpdateStatus) -> String {
        let which = update.needsRepair.count == 1 ? "Your change doesn't" : "\(update.needsRepair.count) of your changes don't"
        return "\(which) fit \(update.inSentence)"
    }

    /// And what redoing is, since nobody has seen this before: who does it, what can come of it, and that nothing changes meanwhile.
    /// Two short lines in a toast: what's in the bar already isn't said again.
    static func redoExplained(_ update: UpdateStatus, agent: String) -> String {
        "\(agent) can fit it to \(update.inSentence), or retire it if Tiri does this itself now."
    }

    /// What the bar along the bottom says. Nothing at all when nothing's happening, or when it's been put off.
    var waiting: YourTiriWaiting? {
        guard let waiting = waitingNow else { return nil }
        if let key = waiting.laterKey, let at = putOff[key], Date().timeIntervalSince(at) < Self.putOffFor { return nil }
        return waiting
    }

    /// Hidden from the bar for a while, with nothing decided. Change Tiri… still has it.
    func putOffWaiting() {
        guard let key = waitingNow?.laterKey else { return }
        putOff[key] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.putOffFor + 1) { [weak self] in self?.putOff[key] = nil }
    }

    private var waitingNow: YourTiriWaiting? {
        if let trial = state?.trial {
            return YourTiriWaiting(text: "Trying: \(trial.sentence)", symbol: "checkmark.circle", actions: [
                .init(title: "Go Back") { [weak self] in self?.back() },
                .init(title: "Keep", isMain: true) { [weak self] in self?.keep() },
            ])
        }
        if let ready, ready.kind != .update {
            return YourTiriWaiting(text: "Ready to try: \(ready.sentence)", actions: [.init(title: "Try It", isMain: true) { [weak self] in self?.tryReady() }],
                                   laterKey: "ready-\(ready.builtAt.timeIntervalSince1970)")
        }
        if let draft {
            let row = draft.item.flatMap { item in model?.agentRows.first { $0.item == item } }
            let alive = draft.item.map { model?.anyItem($0) != nil } ?? false
            let action: YourTiriWaiting.Action = alive
                ? .init(title: "Show") { [weak self] in if let item = draft.item { self?.model?.focusItem(item) } }
                : .init(title: "Give Up") { [weak self] in self?.giveUp() }
            if row?.status == .needsInput {
                return YourTiriWaiting(text: "\(row?.agent ?? "Your agent") needs you: \(draft.sentence)", symbol: "exclamationmark.circle", isTrouble: true, actions: [action])
            }
            return YourTiriWaiting(text: "Changing Tiri: \(draft.sentence)", isBusy: alive, actions: [action])
        }
        if let update {
            return updateWaiting(update).map { item in
                var item = item
                item.laterKey = "update-\(update.newRelease)-\(update.phase)-\(state?.repairsAllowed.map { "\($0)" } ?? "")"
                return item
            }
        }
        if !toggling.isEmpty { return YourTiriWaiting(text: "Making a copy of Tiri with that change", isBusy: true) }
        return nil
    }

    private func updateWaiting(_ update: UpdateStatus) -> YourTiriWaiting? {
        switch update.phase {
        case .ready:
            // The news first, and their own words last, where being cut short costs least.
            let text = update.retired.isEmpty ? update.line
                : update.retired.count == 1 ? "\(update.name) does your change itself now: \(update.retired[0].sentence)"
                : "\(update.name) does \(update.retired.count) of your changes itself now"
            return YourTiriWaiting(text: text, symbol: update.retired.isEmpty ? "arrow.down.circle" : "checkmark.seal",
                                   actions: [.init(title: "Update", isMain: true) { [weak self] in self?.applyUpdate() }])
        case .needsRepair where state?.repairsAllowed == nil:
            // Their own words last, where being cut short costs least.
            let what = update.needsRepair.count == 1 ? update.needsRepair[0].sentence : "\(update.needsRepair.count) changes"
            return YourTiriWaiting(text: "\(Self.redoTitle(update)): \(what)", symbol: "arrow.down.circle", actions: [
                .init(title: "Leave It Off") { [weak self] in self?.answerRepairs(false) },
                .init(title: "Redo It", isMain: true) { [weak self] in self?.answerRepairs(true) },
            ])
        case .needsRepair:
            let entry = update.needsRepair.first
            let tab = entry.flatMap { redoTab(for: $0) }
            return YourTiriWaiting(text: "\(agentName) is fitting your change to \(update.inSentence)\(entry.map { ": \($0.sentence)" } ?? "")", isBusy: true,
                                   actions: tab.map { item in [.init(title: "Show") { [weak self] in _ = self?.model?.focusItem(item) }] } ?? [])
        case .failed:
            return YourTiriWaiting(text: update.line, symbol: "exclamationmark.triangle", isTrouble: true)
        case .replaying, .building, .checking, .waiting:
            return YourTiriWaiting(text: update.line, isBusy: true)
        }
    }

    var isUsed: Bool { update != nil || !changes.isEmpty || draft != nil || ready != nil || state?.active == .personal || isPersonalCopy }
    var onChanges: [PersonalChange] { changes.filter(\.isOn) }
    /// Who hasn't seen this happen yet, and so gets shown what it is.
    var hasNeverChanged: Bool { changes.isEmpty && !isPersonalCopy && state?.active != .personal }

    /// Which copy is running, in the words the list uses.
    var runningLine: String {
        let count = onChanges.count
        if !isPersonalCopy { return "Plain Tiri \(Self.version)" }
        return "Tiri \(Self.version) with \(count) \(count == 1 ? "change" : "changes")"
    }

    // MARK: Pointing

    /// Whether anything about this should be offered right now.
    var entriesAreOn: Bool {
        guard let model else { return false }
        return model.settings.changeEntries && !model.runnableAgentPresets().isEmpty
    }

    /// The one line, in the palette, with the agent named. Return is the only thing that spends anything.
    func beginChange(surface: String?, initial: String = "") {
        guard let model, !model.runnableAgentPresets().isEmpty else { return }
        guard SwiftTools.areHere() else {
            offerSwiftTools()
            return
        }
        if let draft {
            let item = draft.item
            model.showToast(title: "Another change is being made", detail: draft.sentence, symbol: "hammer", tint: .secondary,
                            actionTitle: item.flatMap { model.anyItem($0) != nil ? "Show" : nil }) { [weak model] in
                if let item { model?.focusItem(item) }
            }
            return
        }
        model.openPrompt(title: "What do you want Tiri to do differently?", initial: initial) { [weak self] text in
            let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty, let self, let chosen = self.chosenAgent(from: model.runnableAgentPresets()) else { return }
            self.startChange(sentence: sentence, surface: surface, preset: chosen)
        }
        model.palette?.showsChangePanel = true
        model.palette?.setPromptRows(promptRows())
    }

    /// Under the question: what it could be, for someone new, and what you've got, for everyone else.
    /// All of it can be done from here, because nobody goes to Settings to look for it.
    /// Whatever the bar is waiting on, put off there or not: Change Tiri… is where it can always be found again.
    private func waitingRows() -> [PaletteModel.Row] {
        guard let waiting = waitingNow, let main = waiting.actions.first(where: \.isMain) else { return [] }
        return [PaletteModel.Row(id: "waiting", title: waiting.text, symbol: waiting.symbol,
                                 button: .init(title: main.title) { [weak model] in
                                     model?.closePalette()
                                     main.run()
                                 }) { [weak model] _ in
            model?.closePalette()
            main.run()
        }]
    }

    private func promptRows() -> [PaletteModel.Row] {
        guard let model else { return [] }
        if hasNeverChanged {
            return waitingRows() + ["Show how long each agent has been working", "Put Changes above Explorer in the sidebar"].map { example in
                PaletteModel.Row(id: example, title: example, symbol: "text.quote") { [weak model] _ in model?.palette?.query = example }
            }
        }
        var rows = waitingRows()
        rows += changes.reversed().map { change in
            PaletteModel.Row(id: change.id, title: change.sentence, detail: ready?.change == change.id ? "ready to try" : change.isOn ? "on" : "off",
                             symbol: ready?.change == change.id ? "sparkles" : change.isOn ? "checkmark.circle.fill" : "circle",
                             button: .init(title: change.isOn ? "Turn Off" : "Turn On") { [weak self, weak model] in
                                 model?.closePalette()
                                 self?.setChange(change, on: !change.isOn)
                             }) { [weak self, weak model] _ in
                model?.closePalette()
                self?.showDiff(of: change)
            }
        }
        if isPersonalCopy {
            rows.append(PaletteModel.Row(id: "use-plain", title: "Use Plain Tiri", detail: "as you installed it. Your changes stay", symbol: "arrow.uturn.backward") { [weak self, weak model] _ in
                model?.closePalette()
                self?.usePlain()
            })
        } else if FileManager.default.fileExists(atPath: YourTiri.current.path) {
            rows.append(PaletteModel.Row(id: "use-yours", title: "Back to Your Tiri", symbol: "arrow.uturn.forward") { [weak self, weak model] _ in
                model?.closePalette()
                self?.useYours()
            })
        }
        return rows
    }

    func chosenAgent(from presets: [TerminalPreset]) -> TerminalPreset? {
        presets.first { $0.name == chosenAgentName } ?? presets.first
    }

    func chooseAgent(_ preset: TerminalPreset) {
        chosenAgentName = preset.name
        UserDefaults.standard.set(preset.name, forKey: "YourTiri.agent")
    }

    // MARK: Marking what you mean

    func beginMarking(query: String) {
        markingQuery = query
        model?.closePalette(restoreFocus: false)
        markingStart = nil
        markingBox = nil
        isMarking = true
    }

    func cancelMarking() {
        isMarking = false
        markingStart = nil
        markingBox = nil
        beginChange(surface: nil, initial: markingQuery)
    }

    /// The mouse while marking. Any button but the left one does nothing.
    func markingMouse(_ type: NSEvent.EventType, at point: CGPoint) {
        switch type {
        case .leftMouseDown:
            markingStart = point
            markingBox = nil
        case .leftMouseDragged:
            guard let start = markingStart else { return }
            let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
            markingBox = box.width >= 4 || box.height >= 4 ? box : nil
        case .leftMouseUp:
            let chosen = markingBox
            markingStart = nil
            markingBox = nil
            if let chosen, chosen.width > 8, chosen.height > 8 { finishMarking(chosen) }
        default:
            break
        }
    }

    /// Back to the question, with the part they marked beside it. The dimming has to be gone from the picture first.
    func finishMarking(_ box: CGRect) {
        isMarking = false
        guard let window = model?.window else { return }
        let query = markingQuery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            WindowPicture.take(box, of: window) { [weak self] image in
                guard let self else { return }
                if let image, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    let file = YourTiri.root.appendingPathComponent("mark.png")
                    try? FileManager.default.createDirectory(at: YourTiri.root, withIntermediateDirectories: true)
                    if (try? png.write(to: file)) != nil { self.mark = ChangeMark(image: image, file: file) }
                }
                self.beginChange(surface: nil, initial: query)
            }
        }
    }

    func clearMark() { mark = nil }

    /// Agents hit this every time otherwise, and on a first run it's the whole of what can go wrong.
    private func offerSwiftTools() {
        model?.showToast(title: "Changing Tiri needs Apple's tools", detail: nil, symbol: "hammer", tint: .secondary,
                         actionTitle: "Install", duration: 12) {
            Tool.run("/usr/bin/xcode-select", ["--install"])
        }
    }

    /// Someone's shell setup can put an older `tiri` first on the PATH, one with no such commands. Real agents
    /// lost a step to that every time, so they're told which one this is.
    static var cliNote: String {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path else { return "" }
        return " Where it says `tiri`, use \"\(path)\"."
    }

    nonisolated static let briefFile = ".tiri-brief.md"
    nonisolated static let markFile = ".tiri-mark.png"
    nonisolated static let repairFile = ".tiri-repair.md"

    /// What the person sees on the tab: what they asked for. The rest is for the agent, in a file beside it.
    static func prompt(sentence: String) -> String {
        "Change Tiri for me: \(sentence). Everything you need is in \(briefFile), so read that first."
    }

    static func brief(sentence: String, surface: String?, hasMark: Bool) -> String {
        let pointing = surface.map { " I was pointing at: \($0)." } ?? ""
        let marked = hasMark ? " I marked the part I mean on screen, and that picture is \(markFile). Look at it." : ""
        let flag = surface.map { " --surface \(ShellQuote.quote($0))" } ?? ""
        return "I asked: \(sentence).\(pointing)\(marked) This folder is Tiri's own source, for the version I'm running. Read the Change Tiri section of `tiri --skill` and CHANGING.md, then begin with `tiri change start \(ShellQuote.quote(sentence))\(flag)`. Open each file you edit with `tiri open <file>`, so I can watch. Build with `tiri change build`, write its check, and finish with `tiri change ready`, giving that a few minutes. I'll try it from the card on your tab. Don't ask me to run anything.\(cliNote)\n"
    }

    /// Git mustn't count these as part of anyone's change.
    nonisolated static func leaveNote(_ text: String, named name: String, extra: (URL, String)? = nil) throws {
        let folder = YourTiri.source
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let (file, target) = extra {
            let destination = folder.appendingPathComponent(target)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
        let exclude = folder.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !existing.contains(".tiri-") {
            try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (existing + "\n.tiri-*\n").write(to: exclude, atomically: true, encoding: .utf8)
        }
    }

    /// In a tab of its own, in Your Tiri. It never types into an agent that's working on something else.
    @discardableResult
    func startChange(sentence: String, surface: String?, preset: TerminalPreset) -> Task<Void, Never> {
        recordFacts()
        let archive = URL(fileURLWithPath: state?.plainPath ?? Bundle.main.bundlePath).appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive)
        let version = Self.version
        let brief = Self.brief(sentence: sentence, surface: surface, hasMark: mark != nil)
        let markFile = mark?.file
        return Task { [weak self] in
            let failure: String? = await Task.detached {
                do {
                    try SourceRepo().prepare(archive: archive, version: version)
                    try Self.leaveNote(brief, named: Self.briefFile, extra: markFile.map { ($0, Self.markFile) })
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            guard let self, let model = self.model else { return }
            if let failure {
                model.showToast(title: "Can't change this copy", detail: failure, symbol: "exclamationmark.triangle", tint: .orange)
                return
            }
            self.mark = nil
            self.cameFrom = model.activeID
            let workspace = model.yourTiriWorkspace()
            if self.cameFrom == workspace { self.cameFrom = nil }
            let command = preset.command + " " + ShellQuote.quote(Self.prompt(sentence: sentence))
            // Its name is what was asked. It stays through the switch, where it's looked at hardest.
            let item = model.newTerminal(command: command, cwd: YourTiri.source.path, in: workspace, title: sentence)
            model.agentAsked[item] = sentence
            self.answerTrustQuestion(on: item)
            self.refresh()
        }
    }

    /// Claude Code asks once whether it may work in a folder it hasn't seen, with "No, exit" chosen, so Return
    /// ends it. Tiri's source is new to it on a first change. The question gets a button on the tab, and only
    /// pressing it answers: nothing is chosen for anyone.
    private func answerTrustQuestion(on item: ItemID) {
        Task { @MainActor [weak self] in
            var shown = false
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let terminal = self?.model?.existingController(for: item) as? TerminalController else {
                    if shown { return } else { continue }
                }
                let asking = Self.isTrustQuestion(terminal.readText(lines: 40))
                if asking, !shown {
                    shown = true
                    terminal.showNotice("Claude Code asks once whether it may work on Tiri's own code.", actionTitle: "Trust Tiri's Code") { [weak terminal] in
                        guard let terminal else { return }
                        let screen = terminal.readText(lines: 40)
                        terminal.showNotice(nil)
                        guard Self.isTrustQuestion(screen) else { return }
                        Task { @MainActor in
                            if !Self.yesIsChosen(screen) {
                                terminal.send(text: "\u{1B}[B")
                                try? await Task.sleep(for: .milliseconds(150))
                            }
                            terminal.send(text: "\r")
                        }
                    }
                } else if !asking, shown {
                    // Answered, either way, by the button or by hand.
                    terminal.showNotice(nil)
                    return
                }
            }
        }
    }

    nonisolated static func isTrustQuestion(_ screen: String) -> Bool {
        screen.contains("Yes, I trust this folder") && screen.contains("No, exit")
    }

    nonisolated static func yesIsChosen(_ screen: String) -> Bool {
        screen.split(separator: "\n").contains { $0.contains("❯") && $0.contains("Yes, I trust this folder") }
    }

    /// On the agent's tab while it works, so that nobody is left wondering what they're looking at.
    func makingForItem(_ item: ItemID) -> ChangeDraft? {
        guard let draft, draft.item == item, hidMaking != draft.id else { return nil }
        return draft
    }

    /// Back to what they were doing. Tiri says when it's ready, wherever they are.
    func keepWorking() {
        hidMaking = draft?.id
        if let cameFrom, model?.workspaces.contains(where: { $0.id == cameFrom }) == true { model?.switchWorkspace(cameFrom) }
    }

    // MARK: The card

    func cardForItem(_ item: ItemID) -> ReadyCopy? {
        guard let ready, ready.kind != .update, dismissedReady == nil, ready.item == item else { return nil }
        return ready
    }

    /// On the tab of the agent that made it. With no such tab any more, on whichever tab is in front,
    /// because Keep and Back have to be somewhere.
    func trialForItem(_ item: ItemID) -> CopyState.Trial? {
        guard let trial = state?.trial, let model else { return nil }
        if trial.item == item { return trial }
        let hasHome = trial.item.map { model.anyItem($0) != nil } ?? false
        return !hasHome && model.active.activeItem?.id == item ? trial : nil
    }

    func notNow() { dismissedReady = Date() }

    /// Whose diff it is, for the card.
    func showDiff(of copy: ReadyCopy) {
        guard let id = copy.change, let change = changes.first(where: { $0.id == id }) else { return }
        showDiff(of: change)
    }

    func showDiff(of change: PersonalChange) {
        guard let model else { return }
        let files = filesIn(change)
        guard let first = files.first else { return }
        for file in files.dropFirst().reversed() {
            model.openDiff(DiffSpec(path: YourTiri.source.appendingPathComponent(file).path, commit: change.commit), preview: false)
        }
        model.openDiff(DiffSpec(path: YourTiri.source.appendingPathComponent(first).path, commit: change.commit), preview: false)
    }

    func filesIn(_ change: PersonalChange) -> [String] {
        // Its check too: that's a script that runs at every update, so it's part of what's being agreed to.
        let listed = Tool.run("/usr/bin/git", ["diff", "--name-only", change.commit + "^", change.commit], in: YourTiri.source).output
        return listed.split(separator: "\n").map(String.init)
    }

    // MARK: Switching. Only a click gets here

    func tryReady() {
        // From the file: this runs on a click, and the note says what's really there.
        guard let ready = ReadyCopy.load(), AppDelegate.settleUnsavedFiles() else { return }
        var current = CopyState.load() ?? CopyState()
        do {
            let hasPrevious = try CopyFiles.promoteReady()
            let wasPersonal = current.active == .personal
            current.trial = CopyState.Trial(sentence: ready.sentence, change: ready.change, item: ready.item, startedAt: Date(),
                                            previous: wasPersonal ? .personal : .plain, hasPreviousCopy: hasPrevious && wasPersonal, firstPersonal: !hasPrevious)
            current.trial?.wasTurnedOff = ready.kind == .toggled && ready.sentence.hasPrefix("Turn off:")
            current.active = .personal
            current.attempts = 0
            if isPersonalCopy == false { current.plainPath = Bundle.main.bundlePath }
            try current.save()
            try? FileManager.default.removeItem(at: YourTiri.readyNote)
            relaunch(into: current)
        } catch {
            model?.showToast(title: "Couldn't switch", detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    func keep() {
        guard var current = CopyState.load() else { return }
        current.trial = nil
        try? current.save()
        state = current
    }

    /// One click, and nothing is lost: the change stays in the list, turned off.
    func back() {
        guard var current = CopyState.load(), let trial = current.trial, AppDelegate.settleUnsavedFiles() else { return }
        if trial.previous == .personal, trial.hasPreviousCopy {
            guard (try? CopyFiles.swap(YourTiri.current, YourTiri.previous)) != nil else { return }
            current.active = .personal
        } else {
            // Out of the way, or Back to Your Tiri would be back to what was just gone back from.
            try? CopyFiles.move(YourTiri.current, to: YourTiri.rejected)
            current.active = .plain
        }
        current.trial = nil
        // The list goes back with the copy: what was tried goes off, or what was turned off comes back.
        let repo = SourceRepo()
        if let id = trial.change, let change = try? repo.change(named: id) {
            do {
                if trial.wasTurnedOff { try repo.turnOn(change) } else { try repo.turnOff(change) }
            } catch {
                current.notice = "You're back, but “\(change.sentence)” can't be moved in your list until what's being made is finished."
            }
        }
        try? current.save()
        relaunch(into: current)
    }

    func usePlain() {
        guard var current = CopyState.load(), AppDelegate.settleUnsavedFiles() else { return }
        current.active = .plain
        current.trial = nil
        try? current.save()
        relaunch(into: current)
    }

    func useYours() {
        guard var current = CopyState.load(), FileManager.default.fileExists(atPath: YourTiri.current.path), AppDelegate.settleUnsavedFiles() else { return }
        current.active = .personal
        current.attempts = 0
        try? current.save()
        relaunch(into: current)
    }

    // MARK: Updates

    /// One click: everything's been done already, beside what's running.
    func applyUpdate() {
        guard let update, update.phase == .ready, AppDelegate.settleUnsavedFiles() else { return }
        do {
            guard let installed = CopyState.load()?.plainPath else { throw ChangeFailure("Can't find the Tiri that's installed.") }
            try UpdateTools.checkRelease(URL(fileURLWithPath: update.app), replacing: URL(fileURLWithPath: installed))
        } catch {
            model?.showToast(title: "Couldn't update", detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        let current = CopyState.load() ?? CopyState()
        guard let installed = current.plainPath else { return }
        relaunch(into: current, app: update.app, arguments: [UpdateInstall.flag, installed])
    }

    /// It waited for a change to be finished, and now it has been.
    /// Once for each launch: what stopped it may well stop it again, and this isn't to go round and round on battery.
    private func resumeWaitingUpdate() {
        guard let update, draft == nil, !isResumingUpdate else { return }
        isResumingUpdate = true
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let already = resumedReleases
        Task { [weak self] in
            let started: String? = await Task.detached {
                _ = UpdateTools.recoverIfInterrupted()
                guard let current = UpdateStatus.load(), current.phase == .waiting, !already.contains(current.newRelease), SourceRepo().isClean else { return nil }
                return current.newRelease
            }.value
            guard let self else { return }
            guard let started else {
                self.isResumingUpdate = false
                return
            }
            self.resumedReleases.insert(started)
            _ = await Task.detached { Tool.run(tiri, ["update", "prepare", update.app]) }.value
            self.isResumingUpdate = false
            self.refresh()
        }
    }

    /// Said no to repairs: what can't be carried is left out, kept, and named, and the update goes on without it.
    private func leaveOutIfRepairsAreOff() {
        guard let update, update.phase == .needsRepair, state?.repairsAllowed == false, !update.needsRepair.isEmpty, !isResumingUpdate else { return }
        isResumingUpdate = true
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let ids = update.needsRepair.map(\.id)
        Task { [weak self] in
            await Task.detached {
                for id in ids { Tool.run(tiri, ["update", "leave-out", id]) }
            }.value
            self?.isResumingUpdate = false
            self?.refresh()
        }
    }

    func answerRepairs(_ yes: Bool) {
        guard var current = CopyState.load() else { return }
        current.repairsAllowed = yes
        try? current.save()
        state = current
        if let updateToast { model?.dismissToast(updateToast) }
        updateToast = nil
        if yes {
            startRepairIfAllowed()
            model?.showToast(title: "\(agentName) is redoing it", detail: "You'll hear when it's done, and it'll do this by itself at future updates.", symbol: "hammer", tint: .accentColor, duration: 10)
        } else {
            leaveOutIfRepairsAreOff()
        }
    }

    /// The tab where a change is being redone, if it's still open.
    private func redoTab(for entry: UpdateStatus.Named) -> ItemID? {
        let title = "Redo: \(entry.sentence)"
        return model?.workspaces.flatMap(\.items).first { item in
            if case .terminal(let spec) = item.content { return spec.title == title }
            return false
        }?.id
    }

    /// One at a time, in a tab of its own, without coming to the front. Asked once, and never again after that.
    private func startRepairIfAllowed() {
        guard let model, let update, update.phase == .needsRepair, state?.repairsAllowed == true, let entry = update.needsRepair.first,
              repairing != entry.id, let preset = model.runnableAgentPresets().first else { return }
        repairing = entry.id
        let folder = YourTiri.source.path
        let title = "Redo: \(entry.sentence)"
        // One from before a relaunch is still at it.
        let already = model.workspaces.flatMap(\.items).contains { item in
            if case .terminal(let spec) = item.content { return spec.title == title }
            return false
        }
        if already { return }
        let workspace = model.workspaces.first { $0.folders == [folder] }?.id
            ?? model.createWorkspace(name: "Your Tiri", folders: [folder], activating: false, initialTerminal: false).id
        try? Self.leaveNote(UpdateTools.repairPrompt(entry, status: update) + Self.cliNote + "\n", named: Self.repairFile)
        let asked = "\(update.name) is out, and my change “\(entry.sentence)” has to be redone to fit it. Everything you need is in \(Self.repairFile), so read that first."
        let command = preset.command + " " + ShellQuote.quote(asked)
        let item = model.newTerminal(command: command, cwd: folder, in: workspace, title: title)
        model.agentAsked[item] = title
        // A tab in a workspace nobody's looking at would otherwise wait for someone to look.
        (model.controller(for: item) as? TerminalController)?.startIfNeeded(fallbackSize: true)
    }

    /// Through the app people installed, which looks at state, starts the right copy and watches it come up.
    private func relaunch(into state: CopyState, app explicit: String? = nil, arguments: [String] = []) {
        guard let model else { return }
        let app = explicit ?? state.plainPath ?? Bundle.main.bundlePath
        guard FileManager.default.isExecutableFile(atPath: app + "/Contents/MacOS/Tiri") else {
            // Quitting now would leave nothing running. Opening the app from wherever it is now puts this right.
            model.showToast(title: "Tiri can't find the app it came from", detail: "Open Tiri from where you've put it, and it'll know.", symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            return
        }
        model.keepTerminalsThroughQuit = true
        model.skipQuitConfirmation = true
        // -n, because the app it opens may still be there, waiting to see that this copy stayed up, and
        // being asked to open by something already running only brings it forward.
        var script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.02; done; exec /usr/bin/open -n"
        if AppModel.isTestCopy {
            script += " -g"
            for (key, value) in ProcessInfo.processInfo.environment where (key.hasPrefix("TIRI_") && key != "TIRI_PLAIN_ONCE" && key != "TIRI_DEV_OPTION") || key == "CODEX_HOME" || key == "GROK_HOME" {
                script += " --env " + ShellQuote.quote("\(key)=\(value)")
            }
        }
        script += " " + ShellQuote.quote(app)
        if !arguments.isEmpty { script += " --args " + arguments.map(ShellQuote.quote).joined(separator: " ") }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        guard (try? helper.run()) != nil else {
            model.showToast(title: "Couldn't restart Tiri", detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        NSApp.terminate(nil)
    }

    /// The feed named in a release. A build from source has none, and a test copy can be given one.
    static var updateFeed: String? {
        if AppModel.isTestCopy, let feed = ProcessInfo.processInfo.environment["TIRI_UPDATE_FEED"], !feed.isEmpty { return feed }
        if let feed = Bundle.main.object(forInfoDictionaryKey: "TiriUpdateFeed") as? String, !feed.isEmpty { return feed }
        // A personal copy is built from source, with no feed of its own. The app it was made from has one.
        guard let plain = CopyState.load()?.plainPath, plain != Bundle.main.bundlePath,
              let feed = Bundle(path: plain)?.object(forInfoDictionaryKey: "TiriUpdateFeed") as? String, !feed.isEmpty else { return nil }
        return feed
    }

    /// Check for Updates…: now, whatever the power or the hour, and it says what it found.
    func checkForUpdatesNow() {
        guard let feed = Self.updateFeed else {
            model?.showToast(title: "This copy doesn't look for updates", detail: "It was built from source. Pull and build to update it.", symbol: "arrow.down.circle", tint: .secondary)
            return
        }
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let checking = model?.showToast(title: "Looking for a newer Tiri…", detail: nil, symbol: "arrow.down.circle", tint: .secondary, duration: 60)
        Task { [weak self] in
            let result = await Task.detached { Tool.run(tiri, ["update", "check", "--feed", feed]) }.value
            guard let self, let model = self.model else { return }
            if let checking { model.dismissToast(checking) }
            self.refresh()
            let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.ok {
                model.showToast(title: "Couldn't look for updates", detail: said.isEmpty ? nil : said, symbol: "exclamationmark.triangle", tint: .orange, duration: 10)
            } else if self.update == nil {
                model.showToast(title: "You have the newest Tiri", detail: "Tiri \(Self.version)", symbol: "checkmark.circle", tint: .secondary)
            }
            // Otherwise the bottom bar now offers it, as it does after a look of its own.
        }
    }

    /// Only with a feed named in the app, with Look for Updates on, and only when this Mac is plugged in and nobody's using it.
    private func watchForUpdates() {
        guard let feed = Self.updateFeed else { return }
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let look: @Sendable () -> Void = {
            Task { @MainActor [weak self] in
                guard let self, self.model?.settings.updatesCheck ?? false, Self.isPluggedIn, Self.isIdle else { return }
                _ = await Task.detached { Tool.run(tiri, ["update", "check", "--feed", feed]) }.value
                self.refresh()
            }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in look() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { look() }
    }

    private static var isPluggedIn: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    private static var isIdle: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 300
    }

    private func watchTrial() {
        trialTimer?.invalidate()
        guard let trial = state?.trial else { return }
        let left = max(1, YourTiri.trialLength - Date().timeIntervalSince(trial.startedAt))
        trialTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.keep() }
        }
    }

    /// For a change whose agent has gone. Whatever was edited for it goes too.
    func giveUp() {
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        Task { [weak self] in
            _ = await Task.detached { Tool.run(tiri, ["change", "drop"]) }.value
            self?.refresh()
        }
    }

    // MARK: The switches

    /// Builds a copy with or without it, which then waits on a card like any other.
    func setChange(_ change: PersonalChange, on: Bool) {
        guard !toggling.contains(change.id) else { return }
        toggling.insert(change.id)
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        Task { [weak self] in
            let result = await Task.detached { Tool.run(tiri, ["change", on ? "on" : "off", change.id]) }.value
            guard let self else { return }
            self.toggling.remove(change.id)
            if !result.ok {
                self.model?.showToast(title: "Couldn't turn that \(on ? "on" : "off")", detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                      symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            }
            self.refresh()
        }
    }
}

extension AppModel {
    /// The workspace holding Tiri's source: made once, with no shell in it, since a change starts its own tab.
    func yourTiriWorkspace() -> WorkspaceID {
        let folder = YourTiri.source.path
        if let found = workspaces.first(where: { $0.folders == [folder] }) {
            if found.id != activeID { switchWorkspace(found.id) }
            return found.id
        }
        return createWorkspace(name: "Your Tiri", folders: [folder], initialTerminal: false).id
    }
}
