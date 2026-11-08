import Foundation

/// A conversation an agent has had, found in the agent's own files. Tiri only reads them.
public struct ConversationSummary: Codable, Hashable, Identifiable, Sendable {
    public var agent: String
    public var session: String
    public var file: String
    public var title: String
    public var cwd: String?
    public var date: Date
    /// The server it's on, if it's on one.
    public var destination: String?

    public var id: String { agent + ":" + session }

    public init(agent: String, session: String, file: String, title: String, cwd: String?, date: Date, destination: String? = nil) {
        self.agent = agent
        self.session = session
        self.file = file
        self.title = title
        self.cwd = cwd
        self.date = date
        self.destination = destination
    }

    /// What brings it back.
    public var resumeCommand: String? {
        AgentCatalog.profile(id: agent)?.resumeCommand?.replacingOccurrences(of: "{id}", with: session)
    }
}

public enum ConversationFormat: Sendable {
    /// One event per line, with `type` and `message`: Claude Code.
    case claude
    /// One item per line, with `type` and `payload`: Codex.
    case codex
    /// One message per line, with `type` and `content`, in a folder named after the session: Grok.
    case grok
}

public enum Conversations {
    private static let separator: UInt8 = 0x1E

    // MARK: Finding them

    /// Where each agent keeps them, the newest first, with their dates and nothing else, so that it's
    /// cheap to ask often. The same on a Mac and on a server, so nothing else needs to know which it is.
    public static func discoveryScript(limit: Int) -> String {
        var script = ""
        for profile in AgentCatalog.all where profile.conversationFiles != nil {
            script += "printf '\\036\(profile.id)\\n'; ls -t \(globs(profile)) 2>/dev/null | head -n \(limit) | tr '\\n' '\\000' | xargs -0 sh -c 'stat -c \"%Y %n\" \"$@\" 2>/dev/null || stat -f \"%m %N\" \"$@\"' _ 2>/dev/null\n"
        }
        return script + "exit 0\n"
    }

    public struct Found: Equatable, Sendable {
        public var agent: String
        public var file: String
        public var seconds: Int
        public init(agent: String, file: String, seconds: Int) {
            self.agent = agent
            self.file = file
            self.seconds = seconds
        }
    }

    public static func parseDiscovery(_ data: Data) -> [Found] {
        var found: [Found] = []
        var agent: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "\u{1E}" {
                agent = String(line.dropFirst())
            } else if let agent, let space = line.firstIndex(of: " "), let seconds = Int(line[..<space]) {
                found.append(Found(agent: agent, file: String(line[line.index(after: space)...]), seconds: seconds))
            }
        }
        return found
    }

    /// The lines of these files that say what they're about.
    public static func startsScript(_ files: [Found], maximumBytes: Int) -> String {
        var script = ""
        for file in files {
            guard let start = AgentCatalog.profile(id: file.agent)?.conversationStart else { continue }
            let path = ShellQuote.quote(file.file)
            script += "printf '\\036%s\\t%s\\t%s\\n' \(file.agent) \(file.seconds) \(path); grep -a -m 30 -E \(ShellQuote.quote(start)) \(path) | head -c \(maximumBytes); printf '\\n'\n"
        }
        return script + "exit 0\n"
    }

    /// Files holding some words, by agent. `grep` over everything, since nothing is indexed.
    public static func searchScript(words: String, limit: Int) -> String {
        var script = ""
        for profile in AgentCatalog.all where profile.conversationFiles != nil {
            script += "grep -l -i -F -- \(ShellQuote.quote(words)) \(globs(profile)) 2>/dev/null | head -n \(limit) | sed 's/^/\(profile.id)\t/'\n"
        }
        return script + "exit 0\n"
    }

    /// Files holding any of these, where there's no index: on a server.
    public static func searchScript(anyOf terms: [String], limit: Int) -> String {
        let patterns = terms.map { "-e " + ShellQuote.quote($0) }.joined(separator: " ")
        guard !patterns.isEmpty else { return "exit 0\n" }
        var script = ""
        for profile in AgentCatalog.all where profile.conversationFiles != nil {
            script += "grep -l -i -F \(patterns) -- \(globs(profile)) 2>/dev/null | head -n \(limit) | sed 's/^/\(profile.id)\t/'\n"
        }
        return script + "exit 0\n"
    }

    private static func globs(_ profile: AgentProfile) -> String {
        let home = profile.configDirectoryVariable.map { "\"${\($0):-$HOME/\(profile.configDirectory)}\"" } ?? "\"$HOME/\(profile.configDirectory)\""
        return home + "/" + (profile.conversationFiles ?? "")
    }

    public static func parseListing(_ data: Data, destination: String? = nil) -> [ConversationSummary] {
        var found: [ConversationSummary] = []
        var seen = Set<String>()
        for chunk in data.split(separator: separator) {
            guard let end = chunk.firstIndex(of: 10) else { continue }
            let header = String(decoding: chunk[chunk.startIndex..<end], as: UTF8.self).split(separator: "\t", maxSplits: 2).map(String.init)
            guard header.count == 3, let seconds = Double(header[1]) else { continue }
            guard let summary = summary(agent: header[0], file: header[2], date: Date(timeIntervalSince1970: seconds),
                                        head: Data(chunk[chunk.index(after: end)...]), destination: destination),
                  seen.insert(summary.id).inserted else { continue }
            found.append(summary)
        }
        return found.sorted { $0.date > $1.date }
    }

    /// What a conversation was about, from the start of its file. Nil if it's nothing to come back to:
    /// one with no prompt in it, or a one-shot run.
    public static func summary(agent: String, file: String, date: Date, head: Data, destination: String? = nil) -> ConversationSummary? {
        guard let format = AgentCatalog.profile(id: agent)?.conversationFormat else { return nil }
        var session: String?
        var cwd: String?
        var title: String?
        for line in head.split(separator: 10) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            switch format {
            case .claude:
                if (object["entrypoint"] as? String)?.hasPrefix("sdk") == true { return nil }
                session = session ?? object["sessionId"] as? String
                cwd = cwd ?? object["cwd"] as? String
                if title == nil, let text = claudePrompt(object) { title = text }
            case .codex:
                let payload = object["payload"] as? [String: Any]
                if object["type"] as? String == "session_meta" {
                    // `exec` is a one-shot, and a subagent's is described by an object.
                    if let source = payload?["source"], (source as? String) != "cli", (source as? String) != "vscode" { return nil }
                    session = session ?? payload?["id"] as? String
                    cwd = cwd ?? payload?["cwd"] as? String
                } else if title == nil, let text = codexPrompt(object) {
                    title = text
                }
            case .grok:
                if title == nil, object["type"] as? String == "user", let text = realPrompt(contentText(object["content"])) { title = text }
            }
            if title != nil, session != nil || format == .grok, cwd != nil || format == .grok { break }
        }
        if format == .grok {
            let folder = (file as NSString).deletingLastPathComponent
            session = (folder as NSString).lastPathComponent
            cwd = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent.removingPercentEncoding
        }
        guard let title, let session = session ?? Optional((file as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")) else { return nil }
        return ConversationSummary(agent: agent, session: session, file: file, title: title, cwd: cwd, date: date, destination: destination)
    }

    /// Whichever text is there, in either of the shapes a message's content comes in.
    private static func contentText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let type = part["type"] as? String, ["text", "input_text", "output_text"].contains(type) else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// What the person typed. Agents put their own notes in as user messages, in tags, and add notes of
    /// their own after what was typed.
    private static func realPrompt(_ text: String?) -> String? {
        guard var trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        // Grok wraps what was typed along with what it adds.
        if let open = trimmed.range(of: "<user_query>"), let close = trimmed.range(of: "</user_query>", range: open.upperBound..<trimmed.endIndex) {
            let query = trimmed[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        }
        // Claude Code keeps what was pasted apart from what was typed, and puts reminders of its own after
        // both. Codex names an image after the words about it.
        let pasted = pastedContent(&trimmed)
        trimmed = trimmed.replacing(/<system-reminder>.*?<\/system-reminder>/.dotMatchesNewlines(), with: "")
            .replacing(/<image name=\[[^\]]*\] path="[^"]*">\s*(?:<\/image>)?/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") || trimmed.hasPrefix("Caveat:") || trimmed.hasPrefix("# AGENTS.md") { return nil }
        // Stopping the agent is recorded as something said, and isn't.
        if trimmed.wholeMatch(of: /\[Request interrupted by user[^\]]*\]/) != nil { return nil }
        let typed = codexRequest(trimmed) ?? trimmed
        if typed.isEmpty { return pasted.isEmpty ? nil : "[Pasted text]" + pasted }
        return typed + pasted
    }

    /// Takes the `<pasted_content>` blocks out of a Claude Code prompt and gives them back folded up, the
    /// way the agent shows them, so the typed words come first: they're what was asked. One HTML block
    /// each, with nothing the markdown parser would split it on, so a page keeps it whole: a blank line
    /// would end the block, so an empty line holds a no-break space, which reads as nothing.
    private static func pastedContent(_ text: inout String) -> String {
        let pattern = /<pasted_content id="[^"]*">(.*?)<\/pasted_content(?: id="[^"]*")?>/.dotMatchesNewlines()
        var folded = ""
        for match in text.matches(of: pattern) {
            let content = String(match.1).trimmingCharacters(in: .newlines)
            let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let shown = lines.map { $0.allSatisfy(\.isWhitespace) ? "\u{A0}" : MarkdownRenderer.escapeText(String($0)) }.joined(separator: "\n")
            folded += "\n\n<details><summary>Pasted text, \(lines.count) lines</summary>\n<pre><code>\(shown)</code></pre>\n</details>"
        }
        if !folded.isEmpty { text = text.replacing(pattern, with: "") }
        return folded
    }

    /// Codex puts what was typed under "My request:" when files or other chats came with it, after what it
    /// says about them. The request is what was asked, and what came with it is named in a line.
    static func codexRequest(_ text: String) -> String? {
        guard text.hasPrefix("# Files ") || text.hasPrefix("## Referenced chats with Codex:"),
              let marker = text.range(of: "## My request:") else { return nil }
        // A chat is referred to by a link, and its name is what reads.
        let request = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/\[([^\]]*)\]\(thread:\/\/[^)]*\)/) { String($0.1) }
        let files = text[..<marker.lowerBound].split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("## "), let colon = line.range(of: ": /", options: .backwards) else { return nil }
            return (String(line[line.index(after: colon.lowerBound)...]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        }
        let attached = files.isEmpty ? "" : "*Attached: " + files.joined(separator: ", ") + "*"
        return [request, attached].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func claudePrompt(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "user", object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
              object["isCompactSummary"] as? Bool != true else { return nil }
        return realPrompt(contentText((object["message"] as? [String: Any])?["content"]))
    }

    private static func codexPrompt(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message", payload["role"] as? String == "user" else { return nil }
        return realPrompt(contentText(payload["content"]))
    }

    // MARK: Reading one

    enum Piece {
        case you(String)
        case agent(String)
        case did(String)
    }

    static func pieces(of object: [String: Any], format: ConversationFormat) -> [Piece] {
        switch format {
        case .claude: claudePieces(object)
        case .codex: codexPieces(object)
        case .grok: grokPieces(object)
        }
    }

    /// The first line of a conversation written out. A document starting with it is laid out as a conversation
    /// (see `ConversationPage.swift`), and the other marks say where each turn begins. They're HTML comments,
    /// so a page shows nothing for them and an agent reading the file passes over them.
    public static let documentMark = "<!-- tiri:conversation -->"
    static let youMark = "<!-- tiri:you -->"
    static let agentMark = "<!-- tiri:agent -->"
    static let didMark = "<!-- tiri:did -->"

    /// The whole of it as a document: what was said, and what was done in a line each. Tool output is left
    /// out: it's most of the file and little of the conversation.
    public static func markdown(_ data: Data, summary: ConversationSummary, limit: Int = 1_500_000) -> String {
        guard let profile = AgentCatalog.profile(id: summary.agent), profile.conversationFormat != nil else { return "" }
        var pieces: [Piece] = []
        // Line by line in place, and the long lines of tool output aren't parsed at all.
        forEachPiece(of: data, agent: summary.agent, limit: .max) { pieces.append($0) }
        var body = ""
        var last = ""
        for piece in pieces {
            switch piece {
            case .you(let text):
                body += "\n\n" + youMark + "\n## You\n\n" + text
                last = "you"
            case .agent(let text):
                // One turn of the agent's, whatever it did along the way.
                if last != "agent" && last != "did" { body += "\n\n" + agentMark + "\n## " + profile.title }
                body += "\n\n" + text
                last = "agent"
            case .did(let text):
                if last != "agent" && last != "did" { body += "\n\n" + agentMark + "\n## " + profile.title }
                // In code style, so a command can't be taken for formatting. Several in a row are one list.
                body += (last == "did" ? "\n" : "\n\n" + didMark + "\n") + "- `" + text.replacingOccurrences(of: "`", with: "'") + "`"
                last = "did"
            }
        }
        var note = ""
        if body.utf8.count > limit {
            body = String(decoding: Array(body.utf8.suffix(limit)), as: UTF8.self)
            // From the start of a turn, so that the layout holds.
            if let start = [youMark, agentMark].compactMap({ body.range(of: "\n\n" + $0)?.lowerBound }).min() { body = String(body[start...]) }
            note = "\n\n*This is a long one, so only its end is here.*"
        }
        let place = summary.cwd.map { " · `" + $0 + "`" } ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return documentMark + "\n# " + (AgentHookEvent.promptLine(summary.title) ?? "Conversation") + "\n\n*" + profile.title + "*" + place + " · " + formatter.string(from: summary.date) + note + body + "\n"
    }

    private static func describeCall(name: String?, input: [String: Any]?) -> Piece? {
        AgentHookEvent.describe(tool: name, input: input).activity.map { .did($0) }
    }

    private static func parsedArguments(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func claudePieces(_ object: [String: Any]) -> [Piece] {
        if object["isSidechain"] as? Bool == true { return [] }
        if let prompt = claudePrompt(object) { return [.you(prompt)] }
        guard object["type"] as? String == "assistant", let content = (object["message"] as? [String: Any])?["content"] else { return [] }
        if let text = content as? String { return [.agent(text)] }
        return (content as? [[String: Any]] ?? []).compactMap { part in
            switch part["type"] as? String {
            case "text": (part["text"] as? String).map { .agent($0) }
            case "tool_use": describeCall(name: part["name"] as? String, input: part["input"] as? [String: Any])
            default: nil
            }
        }
    }

    private static func codexPieces(_ object: [String: Any]) -> [Piece] {
        if let prompt = codexPrompt(object) { return [.you(prompt)] }
        guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "message":
            guard payload["role"] as? String == "assistant", let text = contentText(payload["content"]) else { return [] }
            return [.agent(text)]
        case "function_call", "custom_tool_call":
            // Newer Codex runs commands from a script it writes, and a script can run several.
            if let script = (payload["input"] ?? payload["arguments"]) as? String, !script.hasPrefix("{") {
                let commands = scriptedCommands(script)
                if !commands.isEmpty { return commands.compactMap { describeCall(name: "shell", input: ["command": $0]) } }
            }
            return describeCall(name: payload["name"] as? String, input: parsedArguments(payload["arguments"] ?? payload["input"])).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// The commands in a Codex tool script: `text(await tools.exec_command({cmd:"ls -la", ...}))`, as
    /// many as it has, each read back out of its JavaScript string.
    static func scriptedCommands(_ script: String) -> [String] {
        script.matches(of: /cmd:\s*"((?:[^"\\]|\\.)*)"/).map { match in
            var command = ""
            var escaped = false
            for character in match.1 {
                if escaped {
                    switch character {
                    case "n": command.append("\n")
                    case "t": command.append("\t")
                    default: command.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    command.append(character)
                }
            }
            return command
        }
    }

    private static func grokPieces(_ object: [String: Any]) -> [Piece] {
        switch object["type"] as? String {
        case "user":
            return realPrompt(contentText(object["content"])).map { [.you($0)] } ?? []
        case "assistant":
            var pieces: [Piece] = []
            if let text = contentText(object["content"]), !text.isEmpty { pieces.append(.agent(text)) }
            for call in object["tool_calls"] as? [[String: Any]] ?? [] {
                if let piece = describeCall(name: call["name"] as? String, input: parsedArguments(call["arguments"])) { pieces.append(piece) }
            }
            return pieces
        default:
            return []
        }
    }
}
