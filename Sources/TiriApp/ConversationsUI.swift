import AppKit
import Foundation
import IOKit.ps
import SwiftUI
import TiriCore

/// Past conversations, read from the agents' own files, on this Mac or the server in front.
extension AppModel {
    private var conversationRoot: String {
        (RemoteMirror.root as NSString).deletingLastPathComponent + "/Conversations"
    }

    /// Runs a script where the conversations are.
    private func runForConversations(_ script: String, timeout: TimeInterval = 60) async -> Data? {
        if let destination = active.remote {
            guard let connection = remote.existingConnection(destination), connection.state.isReady else { return nil }
            return await Task.detached(priority: .userInitiated) { connection.run(script, timeout: timeout)?.output }.value
        }
        var environment = ProcessInfo.processInfo.environment
        // A test copy looks at made-up conversations.
        if let home = environment["TIRI_CONVERSATIONS_HOME"], !home.isEmpty {
            environment["HOME"] = home
            for profile in AgentCatalog.all { if let name = profile.configDirectoryVariable { environment[name] = nil } }
        }
        // Here too, the time it's given: a disk that's stopped answering shouldn't leave the list waiting forever.
        guard let result = await BoundedRun.run("/bin/sh", ["-c", script], environment: environment, timeout: timeout), !result.timedOut else { return nil }
        return result.output
    }

    private var conversationIndexFile: String {
        conversationRoot + "/index-" + (active.remote.map(RemoteMirror.key(for:)) ?? "local") + ".json"
    }

    /// What's been read before, so that only what's new or changed is read again.
    private struct IndexEntry: Codable {
        var seconds: Int
        var summary: ConversationSummary?
    }

    /// Each batch shows as it arrives: the first look at years of sessions takes a while.
    func loadConversations(progress: (([ConversationSummary]) -> Void)? = nil) async -> [ConversationSummary] {
        let place = active.remote
        if let look = conversationLook, look.place == place { return await look.task.value }
        let task = Task { await self.lookForConversations(progress: progress) }
        conversationLook = (place, task)
        let found = await task.value
        if conversationLook?.place == place { conversationLook = nil }
        return found
    }

    private func lookForConversations(progress: (([ConversationSummary]) -> Void)?) async -> [ConversationSummary] {
        let onServer = active.remote
        guard let listed = await runForConversations(Conversations.discoveryScript(limit: onServer == nil ? 1500 : 300), timeout: 60) else { return [] }
        let found = Conversations.parseDiscovery(listed)
        let file = conversationIndexFile
        var index = (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap { try? JSONDecoder().decode([String: IndexEntry].self, from: $0) } ?? [:]
        let folders = active.folders.map { folder in onServer.flatMap { remote.existingConnection($0)?.map.remote(folder) } ?? folder }
        let current = { () -> [ConversationSummary] in
            let all = found.compactMap { index[$0.file]?.summary }.sorted { $0.date > $1.date }
            // This workspace's first, the newest of each.
            let isHere = { (conversation: ConversationSummary) -> Bool in
                guard let cwd = conversation.cwd else { return false }
                return folders.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
            }
            return all.filter(isHere) + all.filter { !isHere($0) }
        }
        let unread = found.filter { index[$0.file]?.seconds != $0.seconds }.sorted { $0.seconds > $1.seconds }
        progress?(current())
        for start in stride(from: 0, to: unread.count, by: 60) {
            let batch = Array(unread[start..<min(start + 60, unread.count)])
            let script = Conversations.startsScript(batch, maximumBytes: onServer == nil ? 512_000 : 128_000)
            guard let data = await runForConversations(script, timeout: 120) else { break }
            let parsed = await Task.detached(priority: .userInitiated) { Conversations.parseListing(data, destination: onServer) }.value
            for item in batch { index[item.file] = IndexEntry(seconds: item.seconds, summary: nil) }
            for summary in parsed { index[summary.file]?.summary = summary }
            progress?(current())
        }
        if !unread.isEmpty, let data = try? JSONEncoder().encode(index) {
            try? FileManager.default.createDirectory(atPath: conversationRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
        let everything = current()
        updateConversationIndex(everything, found: found)
        return everything
    }

    // MARK: Searching what was said

    /// The index, on this Mac. A server's conversations are searched where they are.
    private func openConversationIndex() -> ConversationIndex? {
        guard active.remote == nil else { return nil }
        if conversationIndex == nil { conversationIndex = try? ConversationIndex(path: conversationRoot + "/search.sqlite") }
        return conversationIndex
    }

    /// Reads what's new or changed, a file at a time, at a priority that stays out of the way.
    private func updateConversationIndex(_ all: [ConversationSummary], found: [Conversations.Found]) {
        guard !conversationsIndexing, let index = openConversationIndex() else { return }
        conversationsIndexing = true
        conversationIndexing = Task.detached(priority: .utility) { [weak self] in
            let known = index.known()
            let dates = Dictionary(found.map { ($0.file, $0.seconds) }, uniquingKeysWith: { first, _ in first })
            var changed = false
            for conversation in all {
                let seconds = dates[conversation.file] ?? 0
                guard known[conversation.file] != seconds else { continue }
                autoreleasepool {
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: conversation.file), options: .mappedIfSafe) else { return }
                    index.store(file: conversation.file, seconds: seconds, title: conversation.title, place: conversation.cwd,
                                text: Conversations.text(of: data, agent: conversation.agent))
                    changed = true
                }
            }
            // Only those truly gone: the list of what's found stops at the newest 1,500 of each agent.
            let gone = known.keys.filter { dates[$0] == nil && !FileManager.default.fileExists(atPath: $0) }
            if !gone.isEmpty { index.remove(files: gone) }
            await MainActor.run {
                self?.conversationsIndexing = false
                if changed { self?.palette?.refresh() }
            }
        }
    }

    /// Where these words were said, best first, with what was said around them.
    func conversationMatches(_ query: String, related: [String] = [], among all: [ConversationSummary]) async -> (conversations: [ConversationSummary], excerpts: [String: String]) {
        let known = Dictionary(all.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        if let index = openConversationIndex() {
            let words = ConversationIndex.terms(in: query)
            let hits = await Task.detached(priority: .userInitiated) { index.search(words: words, related: related, limit: 200) }.value
            var conversations = hits.compactMap { known[$0.file] }
            let excerpts = Dictionary(hits.map { ($0.file, $0.excerpt) }, uniquingKeysWith: { first, _ in first })
            // The first look at years of sessions takes a while, and plain search still works meanwhile.
            if conversationsIndexing, query.count >= 3 {
                let said = await conversationsSaying(query, among: all)
                conversations += said.filter { !conversations.contains($0) }
            }
            return (conversations, excerpts)
        }
        var conversations = await conversationsSaying(query, among: all)
        if !related.isEmpty, let data = await runForConversations(Conversations.searchScript(anyOf: related, limit: 60)) {
            let files = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
            conversations += files.compactMap { known[$0] }.filter { !conversations.contains($0) }
        }
        return (conversations, [:])
    }

    /// For when it takes real thought: an agent can try other words, and read what it finds.
    private func askAgentToFind(_ query: String, preset: TerminalPreset) {
        askAgent(preset: preset, prompt: "I'm looking for one of my past conversations with a coding agent. What I remember: \"\(query)\". Search with `tiri conversations <words>`, trying different words if the first don't find it, and read likely ones with `tiri conversations read <session>`, which prints a path to read. Tell me which conversation it is and why you think so, with its session ID.")
    }

    private func conversationRow(_ conversation: ConversationSummary, excerpt: String? = nil) -> PaletteModel.Row {
        let profile = AgentCatalog.profile(id: conversation.agent)
        let place = conversation.cwd.map { ($0 as NSString).lastPathComponent }
        let detail = [profile?.title, place, RelativeTime.display(conversation.date)].compactMap { $0 }.joined(separator: " · ")
        let title = conversationTitle(conversation)
        // Beneath the title: where a search matched, or else what you actually asked, in your own words.
        // Saying the title again wouldn't tell you anything.
        let prompt = Conversations.readableTitle(conversation.title)
        let excerpt = excerpt.flatMap { title.contains(ConversationIndex.plain($0)) ? nil : $0 } ?? (title == prompt ? nil : prompt)
        let read = { [weak self] in
            guard let self else { return }
            self.closePalette(restoreFocus: false)
            Task { await self.showConversation(conversation) }
        }
        return PaletteModel.Row(id: conversation.id, title: title, detail: detail, excerpt: excerpt, twoLines: true, symbol: profile?.symbol ?? "text.bubble",
                                button: .init(title: String(localized: "Read"), action: read), appeared: { [weak self] in self?.wantLabel(for: conversation) }) { [weak self] alternate in
            guard let self else { return }
            if alternate {
                read()
            } else {
                self.closePalette(restoreFocus: false)
                self.reopen(conversation)
            }
        }
    }

    // MARK: Clear titles

    /// What the Mac's model called it, or else its first prompt, with links and paths made short.
    func conversationTitle(_ conversation: ConversationSummary) -> String {
        if let label = conversationLabelsLoaded()?[conversation.file]?.label, !label.isEmpty { return label }
        return Conversations.readableTitle(conversation.title)
    }

    // MARK: Conversations still going

    private func agentSession(_ item: Item) -> String? {
        if case .terminal(let spec) = item.content { return spec.sessionID }
        return nil
    }

    /// What's been asked in this terminal, oldest first.
    private func agentPrompts(_ id: ItemID) -> [String] {
        var prompts = turns.filter { $0.item == id }.sorted { $0.started < $1.started }.compactMap(\.prompt)
        if prompts.isEmpty, let latest = runtimes[id]?.prompt { prompts = [latest] }
        return prompts
    }

    /// The same title a past conversation has, once this one has one. Until then, what was last asked.
    func agentConversationName(_ item: Item) -> String {
        if let asked = agentAsked[item.id], agentPrompts(item.id).count <= 1 { return asked }
        if let session = agentSession(item), let found = conversationsLoaded?.first(where: { $0.session == session }),
           let label = conversationLabels?[found.file]?.label, !label.isEmpty {
            return label
        }
        if let title = agentTitles[item.id] { return title }
        if let asked = runtimes[item.id]?.prompt ?? agentPrompts(item.id).last { return Conversations.readableTitle(asked) }
        return Self.unnamedConversation
    }

    /// Worth asking about once it's said something, and again as there's more of it to go on.
    func wantAgentTitles(_ rows: [AgentOverviewRow]) {
        guard mayLabelConversations else { return }
        for row in rows {
            guard let item = anyItem(row.item) else { continue }
            let said = agentPrompts(row.item).count
            guard said > 0 || agentSession(item) != nil else { continue }
            if let asked = agentTitlesAsked[row.item], said < max(asked, 1) * 3 { continue }
            agentTitlesAsked[row.item] = said
            agentTitlesWanted.append(row.item)
        }
        guard agentTitler == nil, !agentTitlesWanted.isEmpty else { return }
        agentTitler = Task { [weak self] in
            while let self, !self.agentTitlesWanted.isEmpty {
                let id = self.agentTitlesWanted.removeFirst()
                await self.titleAgent(id)
                self.agentRowsChanged()
            }
            self?.agentTitler = nil
        }
    }

    private func titleAgent(_ id: ItemID) async {
        guard let item = anyItem(id) else { return }
        // With a file to read, and on this Mac: the very title it'll have among past conversations.
        if active.remote == nil, let session = agentSession(item) {
            if conversationsLoaded?.contains(where: { $0.session == session }) != true,
               ProcessClock.now() - lastAgentConversationLook > 60_000 {
                lastAgentConversationLook = ProcessClock.now()
                conversationsLoaded = await loadConversations()
            }
            _ = conversationLabelsLoaded()
            if let found = conversationsLoaded?.first(where: { $0.session == session }) {
                await label(found)
                return
            }
        }
        // Otherwise it's only just begun, or it's on a server: what's been asked is enough.
        guard let digest = Conversations.labelDigest(agentPrompts(id).map { (you: $0, agent: "") }) else { return }
        let title = await Task.detached(priority: .utility) { await ConversationAssistant.label(digest: digest) }.value
        if let title, !title.isEmpty { agentTitles[id] = title }
    }

    private func conversationLabelsLoaded() -> [String: (label: String, seconds: Int)]? {
        if conversationLabels == nil, let index = openConversationIndex() { conversationLabels = index.labels() }
        return conversationLabels
    }

    private var mayLabelConversations: Bool {
        settings.conversationsUseMacModel && ConversationAssistant.isAvailable
    }

    /// A row came into view. On a server the whole file would have to come over first, so those keep their first prompts.
    private func wantLabel(for conversation: ConversationSummary) {
        guard mayLabelConversations, conversation.destination == nil,
              conversationLabelsLoaded()?[conversation.file]?.seconds != Int(conversation.date.timeIntervalSince1970) else { return }
        conversationsWantingLabels.removeAll { $0.id == conversation.id }
        conversationsWantingLabels.append(conversation)
        // Scrolling past hundreds shouldn't leave a queue of them.
        if conversationsWantingLabels.count > 40 { conversationsWantingLabels.removeFirst(conversationsWantingLabels.count - 40) }
        runConversationLabeler()
    }

    /// One at a time, since the model takes one at a time: what's in view, the latest first, then, if
    /// you've said so in Settings and it's plugged in, everything else.
    private func runConversationLabeler() {
        guard conversationLabeler == nil else { return }
        conversationLabeler = Task { [weak self] in
            while let self, let next = self.nextConversationToLabel() {
                await self.label(next.conversation)
                // In the background, it should never be the reason a Mac's fans come on.
                if next.inBackground { try? await Task.sleep(for: .seconds(1)) }
            }
            self?.conversationLabeler = nil
        }
    }

    private func nextConversationToLabel() -> (conversation: ConversationSummary, inBackground: Bool)? {
        if palette == nil { conversationsWantingLabels.removeAll() }
        if let wanted = conversationsWantingLabels.popLast() { return (wanted, false) }
        guard settings.conversationsSummarizeAll, mayLabelConversations, Self.isPluggedIn, let all = conversationsLoaded, let labels = conversationLabelsLoaded() else { return nil }
        let local = all.filter { $0.destination == nil }
        conversationsSummarized = (local.filter { labels[$0.file] != nil }.count, local.count)
        return local.first { labels[$0.file] == nil }.map { ($0, true) }
    }

    private func label(_ conversation: ConversationSummary) async {
        guard let index = openConversationIndex() else { return }
        let seconds = Int(conversation.date.timeIntervalSince1970)
        let label = await Task.detached(priority: .utility) { () -> String in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: conversation.file), options: .mappedIfSafe),
                  let digest = Conversations.labelDigest(Conversations.turns(of: data, agent: conversation.agent)) else { return "" }
            return await ConversationAssistant.label(digest: digest) ?? ""
        }.value
        // Couldn't is remembered too, so that it isn't tried again until the conversation changes.
        let kept = label.isEmpty ? (conversationLabels?[conversation.file]?.label ?? "") : label
        index.storeLabel(file: conversation.file, seconds: seconds, label: kept)
        conversationLabels?[conversation.file] = (kept, seconds)
        if !kept.isEmpty { palette?.retitle(conversation.id, kept, below: Conversations.readableTitle(conversation.title)) }
    }

    /// Low Power Mode doesn't come into it: some people leave it on all the time, and this was asked for.
    static var isPluggedIn: Bool {
        (IOPSGetProvidingPowerSourceType(nil).takeUnretainedValue() as String) == "AC Power"
    }

    /// Summarizing everything is something you ask for in Settings. While it's on, it looks again now and
    /// then for new conversations, and for having been plugged back in.
    func updateSummarizingAll() {
        conversationSummarizing?.cancel()
        conversationSummarizing = nil
        guard settings.conversationsSummarizeAll else {
            conversationsSummarized = nil
            return
        }
        conversationSummarizing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Nothing to do without the model, and reading every conversation again isn't free.
                if Self.isPluggedIn, self.mayLabelConversations, self.active.remote == nil {
                    self.conversationsLoaded = await self.loadConversations()
                    self.runConversationLabeler()
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Titles as you type, then what was said, then, after a pause, what the Mac's model can add.
    func openConversationPicker() {
        conversationsLoading = true
        Task {
            let all = await self.loadConversations { [weak self] partial in
                self?.conversationsLoaded = partial
                self?.palette?.refresh()
            }
            self.conversationsLoaded = all
            self.conversationsLoading = false
            self.palette?.refresh()
        }
        openPalette(.dynamic(title: String(localized: "Past conversations. Describe what you remember."), provider: { [weak self] query, deliver in
            MainActor.assumeIsolated {
                guard let self else { return }
                let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                let all = self.conversationsLoaded ?? []
                let inTitle = words.isEmpty ? all : all.filter { conversation in
                    let text = (conversation.title + " " + self.conversationTitle(conversation) + " " + (conversation.cwd ?? "") + " " + (AgentCatalog.profile(id: conversation.agent)?.title ?? "")).lowercased()
                    return words.allSatisfy(text.contains)
                }
                let agent = self.settings.activePresets.first { AgentCatalog.profile(executable: $0.command.split(separator: " ").first.map(String.init) ?? "") != nil }
                let finish = { [weak self] (conversations: [ConversationSummary], excerpts: [String: String], status: String) -> [PaletteModel.Row] in
                    guard let self else { return [] }
                    var rows = conversations.prefix(200).map { self.conversationRow($0, excerpt: excerpts[$0.file]) }
                    // Something other than asking an agent always comes first, so that Return can't start one by accident.
                    if rows.isEmpty { rows = [PaletteModel.Row(id: "status", title: status, symbol: "clock") { _ in }] }
                    if !query.isEmpty, let agent {
                        rows.append(PaletteModel.Row(id: "ask-agent", title: String(localized: "Ask \(agent.name) to find it"), detail: String(localized: "It can try other words and read what it finds"), symbol: "sparkle.magnifyingglass") { [weak self] _ in
                            self?.closePalette(restoreFocus: false)
                            self?.askAgentToFind(query, preset: agent)
                        })
                    }
                    return rows
                }
                let nothing = String(localized: "No conversation says that")
                let searches = query.count >= 2
                deliver(finish(inTitle, [:], self.conversationsLoading || searches ? String(localized: "Looking through conversations…") : nothing))
                guard searches else { return }
                Task {
                    let merged = { (found: [ConversationSummary]) in inTitle + found.filter { !inTitle.contains($0) } }
                    let first = await self.conversationMatches(query, among: all)
                    // Exact words are enough, and typing shouldn't set the model off at every key.
                    let assists = self.settings.conversationsUseMacModel && ConversationAssistant.isAvailable && first.conversations.count < 10
                    deliver(finish(merged(first.conversations), first.excerpts, assists ? String(localized: "Trying other words…") : nothing))
                    guard assists else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard self.palette?.query == query else { return }
                    let related = await Task.detached(priority: .userInitiated) { await ConversationAssistant.relatedTerms(for: query) }.value
                    guard self.palette?.query == query else { return }
                    guard !related.isEmpty else {
                        deliver(finish(merged(first.conversations), first.excerpts, nothing))
                        return
                    }
                    var second = await self.conversationMatches(query, related: related, among: all)
                    deliver(finish(merged(second.conversations), second.excerpts, nothing))
                    // With nothing exact to go on, the model's own reading of the likeliest is worth having.
                    guard first.conversations.isEmpty, inTitle.isEmpty, second.conversations.count > 1 else { return }
                    let top = Array(second.conversations.prefix(15))
                    let candidates = top.map { (title: $0.title, excerpt: second.excerpts[$0.file] ?? "") }
                    let chosen = await Task.detached(priority: .userInitiated) { await ConversationAssistant.best(for: query, among: candidates) }.value
                    guard self.palette?.query == query, !chosen.isEmpty else { return }
                    let picked = chosen.map { top[$0] }
                    second.conversations = picked + second.conversations.filter { !picked.contains($0) }
                    deliver(finish(second.conversations, second.excerpts, nothing))
                }
            }
        }))
    }

    /// Those whose files hold these words.
    func conversationsSaying(_ words: String, among all: [ConversationSummary]) async -> [ConversationSummary] {
        guard let data = await runForConversations(Conversations.searchScript(words: words, limit: 60)) else { return [] }
        let files = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            line.split(separator: "\t", maxSplits: 1).last.map(String.init)
        }
        let known = Dictionary(all.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { known[$0] }
    }

    private func fullText(of conversation: ConversationSummary) async -> Data? {
        if conversation.destination != nil {
            return await runForConversations("cat -- \(ShellQuote.quote(conversation.file))", timeout: 300)
        }
        let path = conversation.file
        return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
    }

    /// Written out as a document, so that it reads like one and any viewer's tools work on it.
    @discardableResult
    func showConversation(_ conversation: ConversationSummary) async -> String? {
        guard let path = await writeConversation(conversation) else { return nil }
        open(path: path, intent: .pinned)
        requestFocus()
        return path
    }

    /// As a document on disk, without showing it, so that an agent can read it and you can carry on.
    func writeConversation(_ conversation: ConversationSummary) async -> String? {
        guard let data = await fullText(of: conversation) else {
            showToast(title: String(localized: "Couldn't read that conversation"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            return nil
        }
        var titled = conversation
        titled.title = conversationTitle(conversation)
        let shown = titled
        let text = await Task.detached(priority: .userInitiated) { Conversations.markdown(data, summary: shown) }.value
        let safe = titled.title.prefix(48).map { $0 == "/" || $0 == ":" ? "-" : String($0) }.joined()
        let folder = conversationRoot + "/" + (conversation.agent + "-" + conversation.session).replacingOccurrences(of: "/", with: "-")
        let path = folder + "/" + safe + ".md"
        do {
            // They can hold anything anyone ever pasted to an agent.
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try JSONEncoder().encode(conversation).write(to: URL(fileURLWithPath: folder + "/conversation.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            showToast(title: String(localized: "Couldn't save that conversation"), detail: error.localizedDescription, symbol: "exclamationmark.triangle", tint: .orange)
            return nil
        }
        return path
    }

    /// The conversation a document in front came from, if it did.
    func conversation(shownAt path: String) -> ConversationSummary? {
        guard path.hasPrefix(conversationRoot + "/") else { return nil }
        let file = (path as NSString).deletingLastPathComponent + "/conversation.json"
        return (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap { try? JSONDecoder().decode(ConversationSummary.self, from: $0) }
    }

    /// Back in a terminal, in the folder it was in, in the workspace that has that folder if one does.
    func reopen(_ conversation: ConversationSummary) {
        // Already open: a second copy of a running conversation would only get in its way.
        for workspace in workspaces where workspace.remote == conversation.destination {
            let running = workspace.items.first { item in
                guard case .terminal(let spec) = item.content else { return false }
                return spec.sessionID == conversation.session
            }
            if let running {
                focusItem(running.id)
                return
            }
        }
        // What can't be carried on can still be read.
        guard let command = conversation.resumeCommand else {
            Task { await showConversation(conversation) }
            return
        }
        var directory = conversation.cwd
        if let destination = conversation.destination, let cwd = conversation.cwd, let connection = remote.existingConnection(destination) {
            directory = connection.map.local(cwd)
        }
        let target = directory.flatMap { place in
            workspaces.first { $0.folders.contains { place == $0 || place.hasPrefix($0 + "/") } }
        }
        if let directory, !FileManager.default.fileExists(atPath: directory) {
            showToast(title: String(localized: "That folder isn't there any more, so here's what was said"), detail: directory, symbol: "exclamationmark.triangle", tint: .orange)
            Task { await showConversation(conversation) }
            return
        }
        // Not bringing the app forward: an agent can ask for this while you're elsewhere.
        let opened = newTerminal(command: command, cwd: directory, in: target?.id)
        // Known from the start, so that asking again before its first report comes back here.
        if let index = workspaces.firstIndex(where: { $0.item(opened) != nil }) {
            workspaces[index].updateItem(opened) { item in
                if case .terminal(var spec) = item.content {
                    spec.sessionID = conversation.session
                    item.content = .terminal(spec)
                }
            }
            scheduleSave()
        }
        focusItem(opened)
    }

    /// Another agent picks it up by reading it, which works whichever agents they are.
    func hand(_ conversation: ConversationSummary, shownAt path: String, to preset: TerminalPreset) {
        let title = AgentCatalog.profile(id: conversation.agent)?.title ?? "another agent"
        let ask = { [weak self] (place: String) in
            self?.askAgent(preset: preset, prompt: "Here's an earlier conversation with \(title): \(place)\nPlease read it, then carry on from where it left off. Ask me if it isn't clear what's next.")
        }
        guard let destination = conversation.destination, let connection = remote.existingConnection(destination),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            ask(path)
            return
        }
        // It's for an agent there, so it has to be there.
        let name = (conversation.agent + "-" + conversation.session).replacingOccurrences(of: "/", with: "-") + ".md"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                connection.run("mkdir -p \"$HOME\"/.tiri/conversations && chmod 700 \"$HOME\"/.tiri/conversations && cat > \"$HOME\"/.tiri/conversations/\(ShellQuote.quote(name)) && printf %s \"$HOME\"/.tiri/conversations/\(ShellQuote.quote(name))", stdin: data, timeout: 120)
            }.value
            guard let result, result.succeeded else {
                showToast(title: String(localized: "Couldn't send that conversation to the server"), detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
                return
            }
            ask(result.text)
        }
    }
}

/// Above a past conversation: bring it back, or give it to someone else.
struct ConversationBar: View {
    let conversation: ConversationSummary
    let path: String
    @Environment(AppModel.self) private var model

    private var agents: [TerminalPreset] {
        model.settings.activePresets.filter { AgentCatalog.profile(executable: $0.command.split(separator: " ").first.map(String.init) ?? "") != nil }
    }

    var body: some View {
        Button {
            model.reopen(conversation)
        } label: {
            Label("Reopen", systemImage: "arrow.counterclockwise").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.caption)
        .help("Carry on with this conversation in a terminal")
        Menu {
            ForEach(agents) { preset in
                Button(preset.name) { model.hand(conversation, shownAt: path, to: preset) }
            }
        } label: {
            Text("Hand To").font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Ask an agent to read this and carry on")
    }
}
