import AppKit
import SwiftUI
import TiriCore
import UniformTypeIdentifiers

/// Someone else's change, between opening its file and pressing Add. Nothing of it is in the list yet.
struct ArrivingChange {
    let staged: StagedShare
    let file: URL
}

/// Sharing a kept change as a `.tirichange` file, and adding one someone shared. It arrives off, like a plugin:
/// turning it on is the same build, Try It and Keep or Back as any change, and nothing runs before that.
extension YourTiriModel {
    static var sharedType: UTType { UTType(filenameExtension: SharedChange.fileExtension, conformingTo: .plainText) ?? .plainText }

    // MARK: Sharing one

    func chooseWhereToShare(_ change: PersonalChange) {
        guard let window = model?.window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SharedChange.fileName(for: change)
        panel.allowedContentTypes = [Self.sharedType]
        panel.prompt = String(localized: "Share")
        panel.message = String(localized: "One file to hand to someone, with this change and nothing else.")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { self?.share(change, to: url) }
            }
        }
    }

    /// Import… beside the list: the same way in as a double-click.
    func chooseSharedChangeToOpen() {
        guard let window = model?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sharedType]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { self?.openShared(url) }
            }
        }
    }

    /// Each file it touched, as a diff against what was there before it.
    func showChanges(of change: PersonalChange) {
        guard let model else { return }
        for file in filesIn(change) {
            model.openDiff(DiffSpec(path: YourTiri.source.appendingPathComponent(file).path, commit: change.commit), preview: false)
        }
    }

    func share(_ change: PersonalChange, to file: URL) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SharedChange, Error> in
                Result { try SharedChange.export(change, in: SourceRepo(), to: file) }
            }.value
            guard let self, let model = self.model else { return }
            switch result {
            case .failure(let error):
                self.lastShare = "failed: \(error)"
                model.showToast(title: String(localized: "Couldn't share that"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            case .success:
                self.lastShare = "shared \(change.id)"
                model.showToast(title: String(localized: "Ready to hand to someone"), detail: file.lastPathComponent, symbol: "square.and.arrow.up", tint: .green,
                                actionTitle: String(localized: "Show in Finder"), duration: 10) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
    }

    // MARK: One arriving

    /// A double-click, Open With, a drop, or `tiri open`'s way in. Asks before anything is in the list.
    func openShared(_ url: URL) {
        guard let model else { return }
        model.openSettings(pane: .yourTiri)
        recordFacts()
        let archive = URL(fileURLWithPath: state?.plainPath ?? Bundle.main.bundlePath).appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive)
        let version = Self.version
        let making = draft?.id
        lastShare = ""
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(StagedShare?, PersonalChange?, SharedChange), Error> in
                Result {
                    let repo = SourceRepo()
                    try repo.prepare(archive: archive, version: version, changeUnderway: making != nil)
                    let shared = try SharedChange.read(url)
                    if let have = try repo.alreadyHas(shared) { return (nil, have, shared) }
                    return (try repo.stage(shared, alsoTaken: making.map { [$0] } ?? []), nil, shared)
                }
            }.value
            guard let self, let model = self.model else { return }
            switch result {
            case .failure(let error):
                self.lastShare = "failed: \(error)"
                model.showToast(title: String(localized: "Couldn't add \(url.lastPathComponent)"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            case .success((_, let have?, _)):
                self.lastShare = "already \(have.id)"
                model.showToast(title: String(localized: "You already have this"), detail: have.sentence, symbol: "checkmark.circle", tint: .secondary)
            case .success((let staged?, nil, _)):
                self.askToAdd(ArrivingChange(staged: staged, file: url))
            case .success:
                break
            }
        }
    }

    /// The words of the question, which `dev-your-tiri` reads back too.
    static func question(_ staged: StagedShare) -> (title: String, words: [String]) {
        let shared = staged.shared
        var words: [String] = []
        var files = shared.files.prefix(8).map { "• " + $0.path }
        if shared.files.count > 8 { files.append(String(localized: "• and \(shared.files.count - 8) more")) }
        words.append(shared.files.count == 1 ? String(localized: "+\(shared.added) −\(shared.removed) in 1 file:\n\(files.joined(separator: "\n"))")
            : String(localized: "+\(shared.added) −\(shared.removed) in \(shared.files.count) files:\n\(files.joined(separator: "\n"))"))
        if !staged.fits {
            if let made = shared.madeOn, made != version {
                words.append(String(localized: "Made on Tiri \(made), and it doesn't fit this one, so it arrives needing to be redone."))
            } else {
                words.append(String(localized: "It doesn't fit your Tiri as it is, so it arrives needing to be redone."))
            }
        } else {
            words.append(shared.hasCheck ? String(localized: "Its check runs at every update.") : String(localized: "No check, so updates will ask you to look at it."))
        }
        if let from = shared.from { words.append(String(localized: "Says it's from \(from).")) }
        words.append(String(localized: "It arrives off. Once on, it's code that runs with your full access, including all your files."))
        return (String(localized: "Add “\(shared.sentence)” to your Tiri?"), words)
    }

    /// Modelled on turning on a plugin: Return is Cancel, because this can land while someone is typing.
    func askToAdd(_ arriving: ArrivingChange) {
        guard let window = model?.window, window.attachedSheet == nil else {
            // Something else is being asked. The bar holds it until then.
            self.arriving = arriving
            return
        }
        let alert = NSAlert()
        let question = Self.question(arriving.staged)
        alert.messageText = question.title
        alert.informativeText = question.words.joined(separator: "\n\n")
        let add = alert.addButton(withTitle: String(localized: "Add"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "See What Changed"))
        add.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        shareAlert = alert
        self.arriving = nil
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.shareAlert = nil
                switch response {
                case .alertFirstButtonReturn: self?.add(arriving)
                case .alertThirdButtonReturn: self?.seeWhatsArriving(arriving)
                default: self?.lastShare = "cancelled"
                }
            }
        }
    }

    /// Its diff, as any change's, with Add still at hand in the bar along the bottom.
    func seeWhatsArriving(_ arriving: ArrivingChange) {
        self.arriving = arriving
        lastShare = "looking"
        if let preview = arriving.staged.preview {
            showDiff(of: preview)
        } else if let model {
            // Nothing here to compare it with: the file itself, which is a diff.
            let file = YourTiri.root.appendingPathComponent("arriving/\(SharedChange.fileName(sentence: arriving.staged.shared.sentence, id: arriving.staged.id)).patch")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? arriving.staged.shared.text.write(to: file, atomically: true, encoding: .utf8)
            _ = model.open(path: file.path, intent: .pinned)
        }
    }

    var arrivingWaiting: YourTiriWaiting? {
        guard let arriving else { return nil }
        return YourTiriWaiting(text: String(localized: "Add “\(arriving.staged.shared.sentence)” to your Tiri?"), symbol: "square.and.arrow.down", actions: [
            .init(title: String(localized: "Cancel")) { [weak self] in
                self?.arriving = nil
                self?.lastShare = "cancelled"
            },
            .init(title: String(localized: "Add"), isMain: true) { [weak self] in self?.add(arriving) },
        ])
    }

    func add(_ arriving: ArrivingChange) {
        self.arriving = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PersonalChange, Error> in
                Result { try SourceRepo().add(arriving.staged) }
            }.value
            guard let self, let model = self.model else { return }
            switch result {
            case .failure(let error):
                self.lastShare = "failed: \(error)"
                model.showToast(title: String(localized: "Couldn't add \(arriving.file.lastPathComponent)"), detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange, duration: 12)
            case .success(let change):
                self.lastShare = "added \(change.id)"
                self.refresh()
                model.openSettings(pane: .yourTiri)
                model.showToast(title: String(localized: "Added to your Tiri"), detail: change.sentence, symbol: "square.and.arrow.down", tint: .accentColor,
                                actionTitle: change.needsRedo ? String(localized: "Redo It") : String(localized: "Turn On"), duration: 12) { [weak self] in
                    if change.needsRedo { self?.redoShared(change) } else { self?.setChange(change, on: true) }
                }
            }
        }
    }

    /// What the buttons do, for a test copy. A real answer takes a real press.
    func answerShareForTest(_ answer: String) -> Bool {
        if let shareAlert {
            let index = ["add": 0, "cancel": 1, "see": 2][answer] ?? 1
            shareAlert.buttons[index].performClick(nil)
            return true
        }
        guard let main = arrivingWaiting?.actions.first(where: { $0.isMain == (answer == "add") }) else { return false }
        main.run()
        return true
    }

    var shareQuestion: String {
        if let shareAlert { return shareAlert.messageText + "\n\n" + shareAlert.informativeText }
        return arriving.map { Self.question($0.staged).title } ?? ""
    }

    // MARK: Redoing one that doesn't fit

    /// Its words and their diff go to an agent, in a tab of its own, which makes it again on this version as a
    /// change like any other: built, then tried from the card, then kept or not.
    func redoShared(_ change: PersonalChange) {
        guard let model, change.needsRedo else { return }
        guard let preset = chosenAgent(from: model.runnableAgentPresets()) else { return }
        if let draft {
            model.showToast(title: String(localized: "Another change is being made"), detail: draft.sentence, symbol: "hammer", tint: .secondary)
            return
        }
        guard let patch = try? SourceRepo().writeSharedText(of: change) else { return }
        let brief = Self.redoBrief(change, patch: patch.lastPathComponent)
        startChange(sentence: change.sentence, surface: change.surface, preset: preset, brief: brief, prompt: Self.redoPrompt(change))
    }

    static func redoPrompt(_ change: PersonalChange) -> String {
        "Redo a change someone shared with me: \(change.sentence). Everything you need is in \(briefFile), so read that first."
    }

    static func redoBrief(_ change: PersonalChange, patch: String) -> String {
        let made = change.madeOn.flatMap { $0 == version ? nil : " It was made on Tiri \($0), and I'm on \(version)." } ?? ""
        let from = change.from.map { " It says it's from \($0)." } ?? ""
        return "Someone shared a change to Tiri with me, and it doesn't go on the version I'm running.\(made)\(from) The change, in their words: \(change.sentence). Their diff is \(patch), in this folder. This folder is Tiri's own source, for the version I'm running. Read the Change Tiri section of `tiri --skill` and CHANGING.md, then run `tiri change revise \(change.id)`, which puts as much of their diff into these files as goes on, with conflicts marked, and shows all of it. Make what the sentence asks for on this version, the way their diff did, and change nothing else. Read their diff before you use it: it's someone else's code. Open each file you edit with `tiri open <file>`, so I can watch. Build with `tiri change build`, write checks/\(change.id).sh, and finish with `tiri change ready`, giving that a few minutes. I'll try it from the card on your tab. Don't ask me to run anything.\(cliNote)\n"
    }
}

/// Where a `.tirichange` can be dropped in the app: on the list of changes.
struct SharedChangeDrop: ViewModifier {
    @State private var isDropping = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isDropping { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == SharedChange.fileExtension else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { AppModel.shared.yourTiri.openShared(url) }
                    }
                }
                return true
            }
    }
}

/// At the end of a change's details in Settings: who a shared one says it's from, or why it has to be redone.
struct SharedChangeFold: View {
    let change: PersonalChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if change.needsRedo {
                Text(change.madeOn.flatMap { $0 == YourTiriModel.version ? nil : String(localized: "Made on Tiri \($0), so it has to be redone to fit this one.") }
                     ?? String(localized: "It didn't fit as it came, so it has to be redone."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let from = change.from {
                Text("Says it's from \(from).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension YourTiriModel {
    /// The file a change that has to be redone came in, which is a diff.
    func showSharedText(of change: PersonalChange) {
        guard let model, let file = try? SourceRepo().writeSharedText(of: change) else { return }
        _ = model.open(path: file.path, intent: .pinned)
    }
}
