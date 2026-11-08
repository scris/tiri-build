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
        Self.retryUpdateAfterMove(installed: loaded.plainPath)
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
            model?.showToast(title: String(localized: "Plain Tiri, for this run"), detail: String(localized: "Your changes are still yours. They'll be back next time."), symbol: "option", tint: .secondary,
                             actionTitle: String(localized: "Back to Your Tiri"), duration: 12) { [weak self] in self?.useYours() }
        }
        if let trial = loaded.trial, model?.active.activeItem?.id != trial.item {
            model?.showToast(title: String(localized: "You're trying your change"), detail: ReadyCopy.shown(trial.sentence), symbol: "checkmark.circle", tint: .accentColor,
                             actionTitle: String(localized: "Go Back"), duration: 15) { [weak self] in self?.back() }
        }
        if let notice {
            model?.showToast(title: String(localized: "Back to a copy that starts"), detail: notice, symbol: "arrow.uturn.backward", tint: .orange, duration: 20)
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
        model.showToast(title: String(localized: "Ready to try"), detail: ready.shownSentence, symbol: "sparkles", tint: .accentColor,
                        actionTitle: String(localized: "Try It"), duration: 15) { [weak self] in self?.tryReady() }
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
            if update.retired.isEmpty {
                updateToast = model.showToast(title: String(localized: "\(update.shownName) is ready"), detail: update.readyDetail, symbol: "arrow.down.circle", tint: .accentColor,
                                              actionTitle: String(localized: "Update"), duration: 30) { [weak self] in self?.applyUpdate() }
            } else {
                let title = update.retired.count == 1 ? String(localized: "Tiri does your change itself now") : String(localized: "Tiri does \(update.retired.count) of your changes itself now")
                updateToast = model.showToast(title: title, detail: String(localized: "Update to use Tiri's own. \(UpdateStatus.names(update.retired))"),
                                              symbol: "checkmark.seal", tint: .accentColor, actionTitle: String(localized: "Update"), duration: 30) { [weak self] in self?.applyUpdate() }
            }
        case .needsRepair where state?.repairsAllowed == nil && !update.needsRepair.isEmpty:
            updateToast = model.showToast(title: update.needsRepair.count == 1 ? String(localized: "Your change needs redoing") : String(localized: "\(update.needsRepair.count) of your changes need redoing"),
                            detail: Self.redoExplained(update, agent: agentName), symbol: "arrow.down.circle", tint: .accentColor,
                            actionTitle: String(localized: "Redo It"), duration: 30) { [weak self] in self?.answerRepairs(true) }
        default: break
        }
    }

    private var entriesOrUsed: Bool { entriesAreOn || isUsed }

    private var agentName: String { model?.runnableAgentPresets().first?.name ?? String(localized: "Your agent") }

    /// Before anything is redone, what happened, in a line: the new Tiri is here, and a change of theirs doesn't fit it.
    /// Their own words last, where being cut short costs least.
    static func redoLine(_ update: UpdateStatus) -> String {
        let count = update.needsRepair.count
        return count == 1 ? String(localized: "Your change doesn't fit \(update.shownInSentence): \(update.needsRepair[0].sentence)")
            : String(localized: "\(count) of your changes don't fit \(update.shownInSentence): \(count) changes")
    }

    /// And what redoing is, since nobody has seen this before: who does it, what can come of it, and that nothing changes meanwhile.
    /// Two short lines in a toast: what's in the bar already isn't said again.
    static func redoExplained(_ update: UpdateStatus, agent: String) -> String {
        String(localized: "\(agent) can fit it to \(update.shownInSentence), or retire it if Tiri does this itself now.")
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
            return YourTiriWaiting(text: String(localized: "Trying: \(ReadyCopy.shown(trial.sentence))"), symbol: "checkmark.circle", actions: [
                .init(title: String(localized: "Go Back")) { [weak self] in self?.back() },
                .init(title: String(localized: "Keep"), isMain: true) { [weak self] in self?.keep() },
            ])
        }
        if let ready, ready.kind != .update {
            return YourTiriWaiting(text: String(localized: "Ready to try: \(ready.shownSentence)"), actions: [.init(title: String(localized: "Try It"), isMain: true) { [weak self] in self?.tryReady() }],
                                   laterKey: "ready-\(ready.builtAt.timeIntervalSince1970)")
        }
        if let draft {
            let row = draft.item.flatMap { item in model?.agentRows.first { $0.item == item } }
            let alive = draft.item.map { model?.anyItem($0) != nil } ?? false
            let action: YourTiriWaiting.Action = alive
                ? .init(title: String(localized: "Show")) { [weak self] in if let item = draft.item { self?.model?.focusItem(item) } }
                : .init(title: String(localized: "Give Up")) { [weak self] in self?.giveUp() }
            if row?.status == .needsInput {
                return YourTiriWaiting(text: String(localized: "\(row?.agent ?? String(localized: "Your agent")) needs you: \(draft.sentence)"), symbol: "exclamationmark.circle", isTrouble: true, actions: [action])
            }
            return YourTiriWaiting(text: String(localized: "Changing Tiri: \(draft.sentence)"), isBusy: alive, actions: [action])
        }
        if let update {
            return updateWaiting(update).map { item in
                var item = item
                item.laterKey = "update-\(update.newRelease)-\(update.phase)-\(state?.repairsAllowed.map { "\($0)" } ?? "")"
                return item
            }
        }
        if !toggling.isEmpty { return YourTiriWaiting(text: String(localized: "Making a copy of Tiri with that change"), isBusy: true) }
        return nil
    }

    private func updateWaiting(_ update: UpdateStatus) -> YourTiriWaiting? {
        switch update.phase {
        case .ready:
            // The news first, and their own words last, where being cut short costs least.
            let text = update.retired.isEmpty ? update.line
                : update.retired.count == 1 ? String(localized: "\(update.shownName) does your change itself now: \(update.retired[0].sentence)")
                : String(localized: "\(update.shownName) does \(update.retired.count) of your changes itself now")
            return YourTiriWaiting(text: text, symbol: update.retired.isEmpty ? "arrow.down.circle" : "checkmark.seal",
                                   actions: [.init(title: String(localized: "Update"), isMain: true) { [weak self] in self?.applyUpdate() }])
        case .needsRepair where state?.repairsAllowed == nil:
            return YourTiriWaiting(text: Self.redoLine(update), symbol: "arrow.down.circle", actions: [
                .init(title: String(localized: "Leave It Off")) { [weak self] in self?.answerRepairs(false) },
                .init(title: String(localized: "Redo It"), isMain: true) { [weak self] in self?.answerRepairs(true) },
            ])
        case .needsRepair:
            let entry = update.needsRepair.first
            let tab = entry.flatMap { redoTab(for: $0) }
            let text = entry.map { String(localized: "\(agentName) is fitting your change to \(update.shownInSentence): \($0.sentence)") }
                ?? String(localized: "\(agentName) is fitting your change to \(update.shownInSentence)")
            return YourTiriWaiting(text: text, isBusy: true,
                                   actions: tab.map { item in [.init(title: String(localized: "Show")) { [weak self] in _ = self?.model?.focusItem(item) }] } ?? [])
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
        if !isPersonalCopy { return String(localized: "Plain Tiri \(Self.version)") }
        return count == 1 ? String(localized: "Tiri \(Self.version) with 1 change") : String(localized: "Tiri \(Self.version) with \(count) changes")
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
            model.showToast(title: String(localized: "Another change is being made"), detail: draft.sentence, symbol: "hammer", tint: .secondary,
                            actionTitle: item.flatMap { model.anyItem($0) != nil ? String(localized: "Show") : nil }) { [weak model] in
                if let item { model?.focusItem(item) }
            }
            return
        }
        model.openPrompt(title: String(localized: "What do you want Tiri to do differently?"), initial: initial) { [weak self] text in
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
            // In the language people read, since the example becomes what they ask for.
            let examples = [String(localized: "Show how long each agent has been working"), String(localized: "Put Changes above Explorer in the sidebar")]
            return waitingRows() + examples.map { example in
                PaletteModel.Row(id: example, title: example, symbol: "text.quote") { [weak model] _ in model?.palette?.query = example }
            }
        }
        var rows = waitingRows()
        rows += changes.reversed().map { change in
            PaletteModel.Row(id: change.id, title: change.sentence,
                             detail: ready?.change == change.id ? String(localized: "ready to try") : change.isOn ? String(localized: "on") : String(localized: "off"),
                             symbol: ready?.change == change.id ? "sparkles" : change.isOn ? "checkmark.circle.fill" : "circle",
                             button: .init(title: change.isOn ? String(localized: "Turn Off") : String(localized: "Turn On")) { [weak self, weak model] in
                                 model?.closePalette()
                                 self?.setChange(change, on: !change.isOn)
                             }) { [weak self, weak model] _ in
                model?.closePalette()
                self?.showDiff(of: change)
            }
        }
        if isPersonalCopy {
            rows.append(PaletteModel.Row(id: "use-plain", title: String(localized: "Use Plain Tiri"), detail: String(localized: "as you installed it. Your changes stay"), symbol: "arrow.uturn.backward") { [weak self, weak model] _ in
                model?.closePalette()
                self?.usePlain()
            })
        } else if FileManager.default.fileExists(atPath: YourTiri.current.path) {
            rows.append(PaletteModel.Row(id: "use-yours", title: String(localized: "Back to Your Tiri"), symbol: "arrow.uturn.forward") { [weak self, weak model] _ in
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
        model?.showToast(title: String(localized: "Changing Tiri needs Apple's tools"), detail: nil, symbol: "hammer", tint: .secondary,
                         actionTitle: String(localized: "Install"), duration: 12) {
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
                model.showToast(title: String(localized: "Can't change this copy"), detail: failure, symbol: "exclamationmark.triangle", tint: .orange)
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
                    terminal.showNotice(String(localized: "Claude Code asks once whether it may work on Tiri's own code."), actionTitle: String(localized: "Trust Tiri's Code")) { [weak terminal] in
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
            model?.showToast(title: String(localized: "Couldn't switch"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
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
                current.notice = String(localized: "You're back, but “\(change.sentence)” can't be moved in your list until what's being made is finished.")
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

    /// An update that couldn't go in where Tiri was is ready again once Tiri is somewhere it can.
    private static func retryUpdateAfterMove(installed: String?) {
        guard let installed, var status = UpdateStatus.load(), status.phase == .failed, let failedAt = status.installFailedAt,
              failedAt != installed, InstallPlace.problem(appPath: installed) == nil,
              FileManager.default.isExecutableFile(atPath: status.app + "/Contents/MacOS/Tiri") else { return }
        status.phase = .ready
        status.message = nil
        status.installFailedAt = nil
        try? status.save()
    }

    /// One click: everything's been done already, beside what's running.
    func applyUpdate() {
        guard let update, update.phase == .ready else { return }
        if let problem = MoveToApplications.problem(), let model {
            MoveToApplications.offer(problem, model: model)
            return
        }
        guard AppDelegate.settleUnsavedFiles() else { return }
        do {
            guard let installed = CopyState.load()?.plainPath else { throw ChangeFailure(String(localized: "Can't find the Tiri that's installed.")) }
            try UpdateTools.checkRelease(URL(fileURLWithPath: update.app), replacing: URL(fileURLWithPath: installed))
        } catch {
            model?.showToast(title: String(localized: "Couldn't update"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
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
            model?.showToast(title: String(localized: "\(agentName) is redoing it"), detail: String(localized: "You'll hear when it's done, and it'll do this by itself at future updates."), symbol: "hammer", tint: .accentColor, duration: 10)
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
            ?? model.createWorkspace(name: String(localized: "Your Tiri"), folders: [folder], activating: false, initialTerminal: false).id
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
            model.showToast(title: String(localized: "Tiri can't find the app it came from"), detail: String(localized: "Open Tiri from where you've put it, and it'll know."), symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            return
        }
        // The other Tiri reads the API key without asking for the Mac's password only if it's on the key's list.
        ModelKeyStore.shareWithOtherCopies()
        guard model.relaunch(app: app, arguments: arguments) else {
            model.showToast(title: String(localized: "Couldn't restart Tiri"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
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
            model?.showToast(title: String(localized: "This copy doesn't look for updates"), detail: String(localized: "It was built from source. Pull and build to update it."), symbol: "arrow.down.circle", tint: .secondary)
            return
        }
        if let problem = MoveToApplications.problem(), let model {
            MoveToApplications.offer(problem, model: model)
            return
        }
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let checking = model?.showToast(title: String(localized: "Looking for a newer Tiri…"), detail: nil, symbol: "arrow.down.circle", tint: .secondary, duration: 60)
        Task { [weak self] in
            let result = await Task.detached { Tool.run(tiri, ["update", "check", "--feed", feed]) }.value
            guard let self, let model = self.model else { return }
            if let checking { model.dismissToast(checking) }
            self.refresh()
            let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.ok {
                model.showToast(title: String(localized: "Couldn't look for updates"), detail: said.isEmpty ? nil : said, symbol: "exclamationmark.triangle", tint: .orange, duration: 10)
            } else if self.update == nil {
                model.showToast(title: String(localized: "You have the newest Tiri"), detail: String(localized: "Tiri \(Self.version)"), symbol: "checkmark.circle", tint: .secondary)
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
                guard let self, self.model?.settings.updatesCheck ?? false, Self.isPluggedIn, Self.isIdle, MoveToApplications.problem() == nil else { return }
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
                self.model?.showToast(title: on ? String(localized: "Couldn't turn that on") : String(localized: "Couldn't turn that off"), detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
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
        return createWorkspace(name: String(localized: "Your Tiri"), folders: [folder], initialTerminal: false).id
    }
}
