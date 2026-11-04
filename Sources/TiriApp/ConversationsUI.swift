import AppKit
import Foundation
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
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            var environment = ProcessInfo.processInfo.environment
            // A test copy looks at made-up conversations.
            if let home = environment["TIRI_CONVERSATIONS_HOME"], !home.isEmpty {
                environment["HOME"] = home
                for profile in AgentCatalog.all { if let name = profile.configDirectoryVariable { environment[name] = nil } }
            }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
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
        return current()
    }

    private func conversationRow(_ conversation: ConversationSummary) -> PaletteModel.Row {
        let profile = AgentCatalog.profile(id: conversation.agent)
        let place = conversation.cwd.map { ($0 as NSString).lastPathComponent }
        let detail = [profile?.title, place, RelativeTime.text(conversation.date)].compactMap { $0 }.joined(separator: " · ")
        return PaletteModel.Row(id: conversation.id, title: AgentHookEvent.promptLine(conversation.title) ?? conversation.title, detail: detail,
                                symbol: profile?.symbol ?? "text.bubble") { [weak self] alternate in
            guard let self else { return }
            self.closePalette(restoreFocus: false)
            if alternate {
                self.reopen(conversation)
            } else {
                Task { await self.showConversation(conversation) }
            }
        }
    }

    /// Everything it's easy to know as you type, then what `grep` finds in what was said.
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
        openPalette(.dynamic(title: "Past conversations. Type to search everything said in them. ↩ reads, ⌘↩ reopens.", provider: { [weak self] query, deliver in
            MainActor.assumeIsolated {
                guard let self else { return }
                let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                let all = self.conversationsLoaded ?? []
                var shown = words.isEmpty ? all : all.filter { conversation in
                    let text = (conversation.title + " " + (conversation.cwd ?? "") + " " + (AgentCatalog.profile(id: conversation.agent)?.title ?? "")).lowercased()
                    return words.allSatisfy(text.contains)
                }
                var rows = shown.prefix(200).map(self.conversationRow)
                if rows.isEmpty {
                    rows = [PaletteModel.Row(id: "looking", title: self.conversationsLoading ? "Looking through conversations…" : "No conversations found", symbol: "clock") { _ in }]
                }
                deliver(rows)
                guard query.count >= 3 else { return }
                Task {
                    let said = await self.conversationsSaying(query, among: all)
                    let more = said.filter { candidate in !shown.contains { $0.id == candidate.id } }
                    guard !more.isEmpty else { return }
                    shown += more
                    deliver(shown.prefix(200).map(self.conversationRow))
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
        guard let data = await fullText(of: conversation) else {
            showToast(title: "Couldn't read that conversation", detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
            return nil
        }
        let text = await Task.detached(priority: .userInitiated) { Conversations.markdown(data, summary: conversation) }.value
        let safe = (AgentHookEvent.promptLine(conversation.title) ?? "Conversation").prefix(48).map { $0 == "/" || $0 == ":" ? "-" : String($0) }.joined()
        let folder = conversationRoot + "/" + (conversation.agent + "-" + conversation.session).replacingOccurrences(of: "/", with: "-")
        let path = folder + "/" + safe + ".md"
        do {
            // They can hold anything anyone ever pasted to an agent.
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try JSONEncoder().encode(conversation).write(to: URL(fileURLWithPath: folder + "/conversation.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            showToast(title: "Couldn't save that conversation", detail: error.localizedDescription, symbol: "exclamationmark.triangle", tint: .orange)
            return nil
        }
        open(path: path, intent: .pinned)
        requestFocus()
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
        guard let command = conversation.resumeCommand else { return }
        var directory = conversation.cwd
        if let destination = conversation.destination, let cwd = conversation.cwd, let connection = remote.existingConnection(destination) {
            directory = connection.map.local(cwd)
        }
        let target = directory.flatMap { place in
            workspaces.first { $0.folders.contains { place == $0 || place.hasPrefix($0 + "/") } }
        }
        if let directory, !FileManager.default.fileExists(atPath: directory) {
            showToast(title: "That folder isn't there any more", detail: directory, symbol: "exclamationmark.triangle", tint: .orange)
            return
        }
        // Not bringing the app forward: an agent can ask for this while you're elsewhere.
        focusItem(newTerminal(command: command, cwd: directory, in: target?.id))
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
                showToast(title: "Couldn't send that conversation to the server", detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
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
