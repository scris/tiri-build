import AppKit
import IOKit.ps
import SwiftUI
import TiriCore

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

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var trialTimer: Timer?
    @ObservationIgnored private var repairing: String?
    @ObservationIgnored private var isResumingUpdate = false
    @ObservationIgnored private var resumedReleases: Set<String> = []
    @ObservationIgnored private var updateTimer: Timer?

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
        loaded.notice = nil
        try? loaded.save()
        state = loaded
        refresh()
        watchTrial()
        watchForUpdates()
        if PlainForNow.isOn {
            model?.showToast(title: "Plain Tiri, for this run", detail: "Your changes are still yours. They'll be back next time.", symbol: "option", tint: .secondary,
                             actionTitle: "Back to Your Tiri", duration: 12) { [weak self] in self?.useYours() }
        }
        if let notice {
            model?.showToast(title: "Back to a copy that starts", detail: notice, symbol: "arrow.uturn.backward", tint: .orange, duration: 20)
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
                self.startRepairIfAllowed()
                self.resumeWaitingUpdate()
                self.leaveOutIfRepairsAreOff()
            }
        }
    }

    private func announce(_ ready: ReadyCopy) {
        dismissedReady = nil
        guard let model, wasBuiltJustNow(ready) else { return }
        if let item = ready.item, model.active.activeItem?.id == item { return }
        model.showToast(title: ready.kind == .update ? "An update is ready" : "Ready to try", detail: ready.sentence, symbol: "sparkles", tint: .accentColor,
                        actionTitle: "Show", duration: 12) { [weak self] in self?.showReady() }
    }

    private func wasBuiltJustNow(_ ready: ReadyCopy) -> Bool { Date().timeIntervalSince(ready.builtAt) < 60 }

    func showReady() {
        guard let model else { return }
        if let item = ready?.item, model.anyItem(item) != nil {
            model.focusItem(item)
        } else {
            model.openSettings(pane: .yourTiri)
        }
    }

    var isUsed: Bool { update != nil || !changes.isEmpty || draft != nil || ready != nil || state?.active == .personal || isPersonalCopy }
    var onChanges: [PersonalChange] { changes.filter(\.isOn) }

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
        guard let model, let preset = model.runnableAgentPresets().first else { return }
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
        model.openPrompt(title: "What should be different?", initial: initial) { [weak self] text in
            let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            self?.startChange(sentence: sentence, surface: surface, preset: preset)
        }
        var note = "\(preset.name) changes Tiri, and you try it first."
        if !SourceRepo().exists {
            note += " The first time takes about 1 GB of build files."
            if preset.command.contains("claude") { note += " If Claude Code asks about trusting the folder, choose Yes." }
        }
        model.palette?.note = note
    }

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

    static func prompt(sentence: String, surface: String?) -> String {
        let pointing = surface.map { " I was pointing at: \($0)." } ?? ""
        let flag = surface.map { " --surface \(ShellQuote.quote($0))" } ?? ""
        return "Change Tiri for me: \(sentence).\(pointing) This folder is Tiri's own source, for the version I'm running. Read the Change Tiri section of `tiri --skill` and CHANGING.md, then begin with `tiri change start \(ShellQuote.quote(sentence))\(flag)`. Open each file you edit with `tiri open <file>`, so I can watch. Build with `tiri change build`, write its check, and finish with `tiri change ready`, giving that a few minutes. I'll try it from the card on this tab. Don't ask me to run anything.\(cliNote)"
    }

    /// In a tab of its own, in Your Tiri. It never types into an agent that's working on something else.
    @discardableResult
    func startChange(sentence: String, surface: String?, preset: TerminalPreset) -> Task<Void, Never> {
        recordFacts()
        let archive = URL(fileURLWithPath: state?.plainPath ?? Bundle.main.bundlePath).appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive)
        let version = Self.version
        return Task { [weak self] in
            let failure: String? = await Task.detached {
                do {
                    try SourceRepo().prepare(archive: archive, version: version)
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
            let workspace = model.yourTiriWorkspace()
            let command = preset.command + " " + ShellQuote.quote(Self.prompt(sentence: sentence, surface: surface))
            // Its name is what was asked. It stays through the switch, where it's looked at hardest.
            let item = model.newTerminal(command: command, cwd: YourTiri.source.path, in: workspace, title: sentence)
            model.agentAsked[item] = sentence
            self.refresh()
        }
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
        if yes { startRepairIfAllowed() } else { leaveOutIfRepairsAreOff() }
    }

    /// One at a time, in a tab of its own, without coming to the front. Asked once, and never again after that.
    private func startRepairIfAllowed() {
        guard let model, let update, update.phase == .needsRepair, state?.repairsAllowed == true, let entry = update.needsRepair.first,
              repairing != entry.id, let preset = model.runnableAgentPresets().first else { return }
        repairing = entry.id
        let folder = YourTiri.source.path
        let title = "Mend: \(entry.sentence)"
        // One from before a relaunch is still at it.
        let already = model.workspaces.flatMap(\.items).contains { item in
            if case .terminal(let spec) = item.content { return spec.title == title }
            return false
        }
        if already { return }
        let workspace = model.workspaces.first { $0.folders == [folder] }?.id
            ?? model.createWorkspace(name: "Your Tiri", folders: [folder], activating: false, initialTerminal: false).id
        let command = preset.command + " " + ShellQuote.quote(UpdateTools.repairPrompt(entry, status: update) + Self.cliNote)
        let item = model.newTerminal(command: command, cwd: folder, in: workspace, title: "Mend: \(entry.sentence)")
        model.agentAsked[item] = "Mend: \(entry.sentence)"
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

    /// Only with a feed named in the app, and only when this Mac is plugged in and nobody's using it.
    private func watchForUpdates() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "TiriUpdateFeed") as? String, !feed.isEmpty else { return }
        let tiri = Bundle.main.resourceURL?.appendingPathComponent("bin/tiri").path ?? "tiri"
        let look: @Sendable () -> Void = {
            Task { @MainActor [weak self] in
                guard let self, Self.isPluggedIn, Self.isIdle else { return }
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
