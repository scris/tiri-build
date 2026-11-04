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
    }
}
