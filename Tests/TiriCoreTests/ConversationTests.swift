import Foundation
import Testing
@testable import TiriCore

/// Shaped like real files of each agent, field for field.
@Suite struct ConversationTests {
    private func lines(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    private let claude: [[String: Any]] = [
        ["type": "mode", "mode": "x", "sessionId": "abc"],
        ["type": "user", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>x"], "cwd": "/work", "sessionId": "abc"],
        ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"], "cwd": "/work", "sessionId": "abc"],
        ["type": "user", "isSidechain": true, "message": ["role": "user", "content": "a helper's prompt"], "cwd": "/work", "sessionId": "abc"],
        ["type": "user", "message": ["role": "user", "content": "Fix the login"], "cwd": "/work", "sessionId": "abc", "entrypoint": "cli"],
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "secret"], ["type": "text", "text": "Looking."],
                                                                            ["type": "tool_use", "name": "Edit", "input": ["file_path": "/work/a.ts"]]]], "sessionId": "abc"],
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "lots of output"]]], "sessionId": "abc"],
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Fixed."]]], "sessionId": "abc"],
    ]

    @Test func claudeConversation() throws {
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/abc.jsonl", date: Date(timeIntervalSince1970: 0), head: lines(claude)))
        #expect(summary.title == "Fix the login")
        #expect(summary.session == "abc")
        #expect(summary.cwd == "/work")
        #expect(summary.resumeCommand == "claude --resume abc")
        let text = Conversations.markdown(lines(claude), summary: summary)
        #expect(text.contains("## You\n\nFix the login"))
        #expect(text.contains("## Claude Code"))
        #expect(text.contains("Looking."))
        #expect(text.contains("- `Edited a.ts`"))
        #expect(text.contains("Fixed."))
        #expect(!text.contains("secret"))
        #expect(!text.contains("lots of output"))
        #expect(!text.contains("a helper's prompt"))
    }

    @Test func aOneShotClaudeRunIsNothingToComeBackTo() {
        let run: [[String: Any]] = [["type": "user", "message": ["content": "x"], "sessionId": "s", "cwd": "/w", "entrypoint": "sdk-cli"]]
        #expect(Conversations.summary(agent: "claude", file: "/h/s.jsonl", date: Date(), head: lines(run)) == nil)
        #expect(Conversations.summary(agent: "claude", file: "/h/s.jsonl", date: Date(), head: Data("not json".utf8)) == nil)
    }

    private let codex: [[String: Any]] = [
        ["type": "session_meta", "payload": ["id": "cdx", "cwd": "/work", "source": "cli"]],
        ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x"]]]],
        ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Add dark mode"]]]],
        ["type": "response_item", "payload": ["type": "function_call", "name": "shell", "arguments": "{\"command\":\"npm test\"}"]],
        ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]],
        ["type": "event_msg", "payload": ["type": "token_count"]],
    ]

    @Test func codexConversation() throws {
        let summary = try #require(Conversations.summary(agent: "codex", file: "/h/rollout.jsonl", date: Date(), head: lines(codex)))
        #expect(summary.title == "Add dark mode")
        #expect(summary.session == "cdx")
        #expect(summary.resumeCommand == "codex resume cdx")
        let text = Conversations.markdown(lines(codex), summary: summary)
        #expect(text.contains("## You\n\nAdd dark mode"))
        #expect(text.contains("- `Ran npm test`"))
        #expect(text.contains("## Codex"))
        #expect(text.contains("Done."))
    }

    @Test func aCodexExecRunIsNothingToComeBackTo() {
        let run: [[String: Any]] = [["type": "session_meta", "payload": ["id": "e", "cwd": "/w", "source": "exec"]],
                                    ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "x"]]]]]
        #expect(Conversations.summary(agent: "codex", file: "/h/r.jsonl", date: Date(), head: lines(run)) == nil)
    }

    @Test func grokConversation() throws {
        let chat: [[String: Any]] = [
            ["type": "system", "content": "you are"],
            ["type": "user", "content": [["type": "text", "text": "Update the docs"]]],
            ["type": "assistant", "content": "On it.", "tool_calls": [["id": "1", "name": "edit_file", "arguments": "{\"path\":\"/w/README.md\"}"]]],
            ["type": "tool_result", "tool_call_id": "1", "content": "output"],
        ]
        let file = "/h/sessions/%2FUsers%2Fme%2Fwork/019a-id/chat_history.jsonl"
        let summary = try #require(Conversations.summary(agent: "grok", file: file, date: Date(), head: lines(chat)))
        #expect(summary.session == "019a-id")
        #expect(summary.cwd == "/Users/me/work")
        #expect(summary.title == "Update the docs")
        let text = Conversations.markdown(lines(chat), summary: summary)
        #expect(text.contains("- `Edited README.md`"))
        #expect(text.contains("On it."))
        #expect(!text.contains("output"))
    }

    @Test func grokWrapsWhatWasTyped() throws {
        let chat: [[String: Any]] = [
            ["type": "user", "content": [["type": "text", "text": "<user_info>os</user_info><git_status>x</git_status>"]]],
            ["type": "user", "content": [["type": "text", "text": "<system-reminder>y</system-reminder>"]]],
            ["type": "user", "content": [["type": "text", "text": "<image_files>z</image_files>\n<user_query>\nMake it faster\n</user_query>"]]],
        ]
        let summary = try #require(Conversations.summary(agent: "grok", file: "/h/sessions/a/b/chat_history.jsonl", date: Date(), head: lines(chat)))
        #expect(summary.title == "Make it faster")
        let text = Conversations.markdown(lines(chat), summary: summary)
        #expect(text.contains("## You\n\nMake it faster"))
        #expect(!text.contains("system-reminder"))
    }

    @Test func subagentsAreNotConversations() {
        let run: [[String: Any]] = [["type": "session_meta", "payload": ["id": "e", "cwd": "/w", "source": ["subagent": ["thread_spawn": "x"]]]],
                                    ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "x"]]]]]
        #expect(Conversations.summary(agent: "codex", file: "/h/r.jsonl", date: Date(), head: lines(run)) == nil)
    }

    /// Only the lines that say what it's about reach the parser, wherever they are in the file.
    @Test func theListingFindsAPromptFarIntoAFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-conv-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/.codex/sessions/2026/11/04"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var rows = [String]()
        rows.append(#"{"type":"session_meta","payload":{"id":"far","cwd":"/w","source":"cli"}}"#)
        for _ in 0..<400 { rows.append(#"{"type":"world_state","payload":{"state":""# + "\"" + String(repeating: "x", count: 1000) + "\"}}") }
        rows.append(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Far in"}]}}"#)
        try rows.joined(separator: "\n").write(toFile: folder + "/rollout-x.jsonl", atomically: true, encoding: .utf8)
        func run(_ script: String) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": base, "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        let found = Conversations.parseDiscovery(try run(Conversations.discoveryScript(limit: 10)))
        #expect(found.map(\.agent) == ["codex"])
        #expect(found.first?.file.hasSuffix("/rollout-x.jsonl") == true)
        #expect((found.first?.seconds ?? 0) > 1_000_000)
        let data = try run(Conversations.startsScript(found, maximumBytes: 48_000))
        #expect(data.count < 2000)
        #expect(Conversations.parseListing(data).map(\.title) == ["Far in"])
    }

    @Test func aListingIsSplitBackIntoFiles() {
        var data = Data()
        for (agent, file, seconds, body) in [("claude", "/h/a b.jsonl", "200", lines(claude)), ("codex", "/h/r.jsonl", "300", lines(codex))] {
            data.append(contentsOf: [0x1E])
            data.append(Data("\(agent)\t\(seconds)\t\(file)\n".utf8))
            data.append(body)
            data.append(10)
        }
        let found = Conversations.parseListing(data, destination: "gpu")
        #expect(found.map(\.agent) == ["codex", "claude"])
        #expect(found[1].file == "/h/a b.jsonl")
        #expect(found[0].destination == "gpu")
    }

    @Test func aLongConversationKeepsItsEnd() throws {
        var long = claude
        for index in 0..<400 { long.append(["type": "assistant", "message": ["content": [["type": "text", "text": "reply \(index) " + String(repeating: "x", count: 200)]]], "sessionId": "abc"]) }
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/abc.jsonl", date: Date(), head: lines(claude)))
        let text = Conversations.markdown(lines(long), summary: summary, limit: 5000)
        #expect(text.contains("only its end is here"))
        #expect(text.contains("reply 399"))
        #expect(!text.contains("reply 0 "))
    }

    @Test func theScriptsCoverEveryAgent() {
        let listing = Conversations.discoveryScript(limit: 10)
        #expect(listing.contains("\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/projects/*/*.jsonl"))
        #expect(listing.contains("036codex"))
        #expect(listing.contains("036grok"))
        #expect(Conversations.searchScript(words: "it's", limit: 5).contains("'it'\\''s'"))
        #expect(Conversations.searchScript(anyOf: ["it's", "ssh"], limit: 5).contains("-e 'it'\\''s' -e ssh"))
        #expect(Conversations.searchScript(anyOf: [], limit: 5) == "exit 0\n")
    }

    // MARK: The index

    private func temporaryIndex() throws -> ConversationIndex {
        let folder = NSTemporaryDirectory() + "tiri-index-" + UUID().uuidString
        return try ConversationIndex(path: folder + "/search.sqlite")
    }

    @Test func aFileBecomesWhatWasSaidAndNotItsToolOutput() throws {
        let text = try #require(Conversations.text(of: lines(claude), agent: "claude"))
        #expect(text.you == "Fix the login\n")
        #expect(text.agent == "Looking.\nFixed.\n")
        #expect(text.did == "Edited a.ts\n")
        let turns = Conversations.turns(of: lines(claude), agent: "claude")
        #expect(turns.count == 1)
        #expect(turns.first?.you == "Fix the login")
        #expect(Conversations.text(of: lines([["type": "mode"]]), agent: "claude") == nil)
    }

    @Test func aHugeToolResultIsSkippedWithoutBeingParsed() throws {
        let noise = String(repeating: "translucent ", count: 4000)
        let result: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "Fix the login"], "sessionId": "abc"],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": noise]]], "sessionId": "abc"],
        ]
        let text = try #require(Conversations.text(of: lines(result), agent: "claude"))
        #expect(!text.you.contains("translucent"))
    }

    @Test func anAgentTalkingAboutToolResultsAtLengthIsStillRead() throws {
        let long = #"the "type":"tool_result" field "# + String(repeating: "is explained here ", count: 2000)
        let message: [[String: Any]] = [["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": long]]], "sessionId": "abc"]]
        // The marker is far enough in that it isn't taken for tool output's own.
        let padded: [[String: Any]] = [["sessionId": String(repeating: "x", count: 700), "type": "assistant", "message": message[0]["message"]!]]
        #expect(Conversations.text(of: lines(padded), agent: "claude")?.agent.contains("is explained here") == true)
    }

    @Test func allYourWordsComeBeforeAnyOfThem() throws {
        let index = try temporaryIndex()
        index.store(file: "/a", seconds: 1, title: "Terminal colors", place: nil, text: ConversationText(you: "terminal colors terminal colors terminal"))
        index.store(file: "/b", seconds: 1, title: "Other", place: nil, text: ConversationText(you: "make the terminal see-through please"))
        let hits = index.search(words: ConversationIndex.terms(in: "terminal see-through"))
        #expect(hits.map(\.file) == ["/b", "/a"])
        #expect(hits[0].excerpt.contains(ConversationIndex.markOpen))
        #expect(ConversationIndex.plain(hits[0].excerpt).contains("make the terminal"))
    }

    @Test func relatedWordsFindWhatYourWordsDoNot() throws {
        let index = try temporaryIndex()
        index.store(file: "/a", seconds: 1, title: "x", place: "/work", text: ConversationText(agent: "the window is translucent now"))
        #expect(index.search(words: ["see-through"]).isEmpty)
        #expect(index.search(words: ["see-through"], related: ["translucent"]).map(\.file) == ["/a"])
    }

    @Test func whatYouSaidCountsForMoreThanWhatTheAgentDid() throws {
        let index = try temporaryIndex()
        index.store(file: "/agent", seconds: 1, title: "x", place: nil, text: ConversationText(agent: "we looked at the keychain and the keychain again"))
        index.store(file: "/you", seconds: 1, title: "x", place: nil, text: ConversationText(you: "the keychain is broken"))
        #expect(index.search(words: ["keychain"]).first?.file == "/you")
    }

    @Test func chineseIsFoundInsideARunOfIt() throws {
        let index = try temporaryIndex()
        index.store(file: "/a", seconds: 1, title: "x", place: nil, text: ConversationText(you: "把终端改成半透明的效果"))
        let hits = index.search(words: ConversationIndex.terms(in: "半透明"))
        #expect(hits.map(\.file) == ["/a"])
        // The spaces that made it searchable don't show.
        #expect(ConversationIndex.plain(hits[0].excerpt).contains("半透明"))
        #expect(!ConversationIndex.plain(hits[0].excerpt).contains("半 透"))
        #expect(ConversationIndex.readable(" 效 果 ， 看 看 ") == "效果，看看")
        #expect(ConversationIndex.readable("the \u{1}word\u{2}  is\nhere") == "the \u{1}word\u{2} is here")
        #expect(ConversationIndex.readable("\u{1} 半 透 \u{2} 明") == "\u{1}半透\u{2}明")
    }

    @Test func oddQueriesDoNoHarm() throws {
        let index = try temporaryIndex()
        index.store(file: "/a", seconds: 1, title: "x", place: nil, text: ConversationText(you: "it's \"quoted\" OR NEAR(a b)"))
        for query in ["\"", "*", "OR", "NEAR(", "a\"b", "col:thing", "-", "(", "it's"] {
            _ = index.search(words: ConversationIndex.terms(in: query))
            _ = index.search(words: [query], related: [query])
        }
        #expect(index.search(words: ["\"quoted\""]).map(\.file) == ["/a"])
        #expect(index.search(words: []).isEmpty)
    }

    @Test func aFileReadAgainReplacesWhatWasThere() throws {
        let index = try temporaryIndex()
        index.store(file: "/a", seconds: 1, title: "x", place: nil, text: ConversationText(you: "first thoughts"))
        index.store(file: "/a", seconds: 2, title: "x", place: nil, text: ConversationText(you: "second thoughts"))
        #expect(index.known()["/a"] == 2)
        #expect(index.search(words: ["first"]).isEmpty)
        #expect(index.search(words: ["second"]).count == 1)
        index.remove(files: ["/a"])
        #expect(index.known().isEmpty)
        #expect(index.search(words: ["second"]).isEmpty)
    }

    @Test func itsFileIsPrivateAndComesBack() throws {
        let path = NSTemporaryDirectory() + "tiri-index-" + UUID().uuidString + "/search.sqlite"
        do {
            let index = try ConversationIndex(path: path)
            index.store(file: "/a", seconds: 1, title: "x", place: nil, text: ConversationText(you: "still here"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try ConversationIndex(path: path).search(words: ["still"]).count == 1)
    }

    @Test func wordsNotWorthLookingForAreDropped() {
        #expect(ConversationIndex.terms(in: "the time we fixed The login") == ["time", "fixed", "login"])
        #expect(ConversationIndex.terms(in: "云 服务器").contains("云"))
    }

    // MARK: Titles

    @Test func aTitleSaysWhatALinkOrPathIsRatherThanSpellingItOut() {
        #expect(Conversations.readableTitle("https://canvas.cmu.edu/courses/57016/assignments/1042795 so about this personal assignment") == "canvas.cmu.edu so about this personal assignment")
        #expect(Conversations.readableTitle("'/Users/r/Documents/chore-tools/iti-pdd' now this is the newest requirement") == "iti-pdd now this is the newest requirement")
        #expect(Conversations.readableTitle("so i want to see how to make '/Users/r/Documents/sem/p1-ai-podcast' online") == "so i want to see how to make p1-ai-podcast online")
        #expect(Conversations.readableTitle("https://www.dmv.ca.gov/portal/file/california-driver-handbook-pdf") == "dmv.ca.gov · california driver handbook pdf")
        #expect(Conversations.readableTitle("Fix the login") == "Fix the login")
        #expect(Conversations.readableTitle("and/or this / that") == "and/or this / that")
    }

    @Test func whatTheModelReadsFitsItsContextHoweverLongTheConversation() throws {
        let turns = (0..<500).map { (you: "request number \($0) " + String(repeating: "x", count: 400), agent: "answer \($0)") }
        let digest = try #require(Conversations.labelDigest(turns))
        #expect(digest.count < 4000)
        #expect(digest.contains("request number 0 "))
        #expect(digest.contains("request number 499 "))
        #expect(digest.contains("answer 499"))
        #expect(Conversations.labelDigest([(you: "", agent: "only the agent")]) == nil)
    }

    @Test func aModelsAnswerIsMadeFitToShow() {
        #expect(Conversations.cleanLabel("\"Fix the login page.\"") == "Fix the login page")
        #expect(Conversations.cleanLabel("Title: Terminal translucency\nmore") == "Terminal translucency")
        #expect(Conversations.cleanLabel("把终端改成半透明。") == "把终端改成半透明")
        #expect(Conversations.cleanLabel("") == nil)
        #expect(Conversations.cleanLabel(String(repeating: "long ", count: 40)) == nil)
    }

    @Test func labelsAreKeptAndGoWithTheFile() throws {
        let index = try temporaryIndex()
        index.storeLabel(file: "/a", seconds: 5, label: "Terminal translucency")
        index.storeLabel(file: "/a", seconds: 6, label: "Newer")
        index.storeLabel(file: "/b", seconds: 1, label: "")
        #expect(index.labels()["/a"]?.label == "Newer")
        #expect(index.labels()["/a"]?.seconds == 6)
        #expect(index.labels()["/b"]?.label == "")
        index.remove(files: ["/a"])
        #expect(index.labels()["/a"] == nil)
    }

    @Test func whatsPastedIsntATitle() {
        #expect(Conversations.readableTitle("[Image #4] are these all my duty?") == "are these all my duty?")
        #expect(Conversations.readableTitle("Look at [Pasted text #1 +20 lines] please") == "Look at please")
        #expect(Conversations.readableTitle("[Image #1]") == "Shared an image")
        #expect(Conversations.readableTitle("[Pasted text #1 +20 lines]") == "Pasted something")
        #expect(Conversations.readableTitle("fix array[0] please") == "fix array[0] please")
    }
}
