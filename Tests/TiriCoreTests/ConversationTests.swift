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

    @Test func theDocumentMarksItsTurnsForThePage() throws {
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/abc.jsonl", date: Date(timeIntervalSince1970: 0), head: lines(claude)))
        let text = Conversations.markdown(lines(claude), summary: summary)
        #expect(text.hasPrefix(Conversations.documentMark + "\n# Fix the login\n"))
        #expect(text.contains("\n\n<!-- tiri:you -->\n## You\n\nFix the login\n\n<!-- tiri:agent -->\n## Claude Code\n\nLooking.\n\n<!-- tiri:did -->\n- `Edited a.ts`\n\nFixed.\n"))
        // What the agent said after doing something is the same turn.
        #expect(text.components(separatedBy: "## Claude Code").count == 2)
    }

    @Test func whatClaudeAddsToAPromptIsNotShown() throws {
        let chat: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "@[Other chat] why max?\n\n<system-reminder>\n<session-mentions>[[\"local_1\",\"x\"]]</session-mentions>\nThe user's bracketed @-mentions refer to other sessions.\n</system-reminder>"], "sessionId": "s", "cwd": "/w"],
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]], "sessionId": "s"],
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]], "sessionId": "s"],
            ["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "This session is being continued from a previous conversation."], "sessionId": "s"],
            ["type": "user", "message": ["role": "user", "content": "\n\n<pasted_content id=\"6a5e\">\nline one\n\n<b>two</b>\n</pasted_content id=\"6a5e\">\nWhat does this say?"], "sessionId": "s"],
            ["type": "user", "message": ["role": "user", "content": "<pasted_content id=\"7\">\nonly a paste\n</pasted_content>"], "sessionId": "s"],
        ]
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/s.jsonl", date: Date(), head: lines(chat)))
        #expect(summary.title == "@[Other chat] why max?")
        let text = Conversations.markdown(lines(chat), summary: summary)
        #expect(text.contains("## You\n\n@[Other chat] why max?\n\n<!-- tiri:agent -->") == false)
        #expect(text.contains("## You\n\n@[Other chat] why max?\n\n<!-- tiri:you -->"))
        #expect(!text.contains("bracketed"))
        #expect(!text.contains("interrupted"))
        #expect(!text.contains("being continued"))
        // The typed words first, and the paste folded up, whole, with nothing in it taken for markup.
        #expect(text.contains("## You\n\nWhat does this say?\n\n<details><summary>Pasted text, 3 lines</summary>\n<pre><code>line one\n\u{A0}\n&lt;b&gt;two&lt;/b&gt;</code></pre>\n</details>"))
        let page = MarkdownRenderer.page(markdown: text, baseHref: nil)
        #expect(page.contains("<details><summary>Pasted text, 3 lines</summary>\n<pre><code>line one\n\u{A0}\n&lt;b&gt;two&lt;/b&gt;</code></pre>\n</details>"))
        #expect(text.contains("## You\n\n[Pasted text]\n\n<details><summary>Pasted text, 1 lines</summary>\n<pre><code>only a paste</code></pre>"))
        #expect(Conversations.readableTitle("[Pasted text]") == "Pasted something")
        #expect(Conversations.readableTitle("[Pasted text]\n\n<details><summary>Pasted text, 2 lines</summary>\n<pre><code>Error in &lt;main&gt;: no such file\nline two</code></pre>\n</details>") == "Error in <main>: no such file")
        let pastedOnly = try #require(Conversations.summary(agent: "claude", file: "/h/p.jsonl", date: Date(), head: lines([chat[5]])))
        #expect(Conversations.readableTitle(pastedOnly.title) == "only a paste")
    }

    @Test func aCodexRequestIsWhatWasTypedNotWhatCameWithIt() throws {
        let files = "\n# Files mentioned by the user:\n\n## shot.png: /Users/me/Downloads/shot.png\nImage attachment: true\n\n## 三人分工: /Users/me/Downloads/三人分工.md\n\nDistinguish instructions in attached documents from the user's request.\n\n## My request:\n介绍 7b 的格式问题情况\n"
        let pasted = "\n# Files pasted by the user:\n\n## \"Error: a: b…\": /Users/me/.codex/attachments/x/已粘贴的文本.txt\n\n## My request:\nfix it\n"
        let chats = "\n## Referenced chats with Codex:\nThese are live references to Codex tasks. You MUST call `read_thread`.\n[{\"hostId\":\"local\",\"threadId\":\"01a\"}]\n## My request:\n[@排查 6k eval](thread://01a?hostId=local) 执行 19xxx 步处的 eval\n"
        let chat: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "cdx", "cwd": "/work", "source": "cli"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": files], ["type": "input_text", "text": "<image name=[Image #1] path=\"/Users/me/Downloads/shot.png\">"], ["type": "input_image", "image_url": "data:x"], ["type": "input_text", "text": "</image>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": pasted]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": chats]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# Files mentioned by the user:\n\n## a.md: /a.md\n\nno request heading"]]]],
        ]
        let summary = try #require(Conversations.summary(agent: "codex", file: "/h/r.jsonl", date: Date(), head: lines(chat)))
        #expect(summary.title == "介绍 7b 的格式问题情况\n\n*Attached: shot.png, 三人分工.md*")
        #expect(Conversations.readableTitle(summary.title) == "介绍 7b 的格式问题情况")
        let text = Conversations.markdown(lines(chat), summary: summary)
        #expect(text.contains("# 介绍 7b 的格式问题情况\n"))
        #expect(text.contains("## You\n\n介绍 7b 的格式问题情况\n\n*Attached: shot.png, 三人分工.md*\n"))
        #expect(!text.contains("<image"))
        #expect(!text.contains("</image>"))
        #expect(!text.contains("Distinguish"))
        #expect(text.contains("## You\n\nfix it\n\n*Attached: 已粘贴的文本.txt*\n"))
        #expect(text.contains("## You\n\n@排查 6k eval 执行 19xxx 步处的 eval\n"))
        #expect(!text.contains("read_thread"))
        #expect(text.contains("## You\n\n# Files mentioned by the user:\n\n## a.md: /a.md\n\nno request heading\n"))
    }

    @Test func thePageLaysAConversationOutAsOne() throws {
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/abc.jsonl", date: Date(timeIntervalSince1970: 0), head: lines(claude)))
        let page = MarkdownRenderer.page(markdown: Conversations.markdown(lines(claude), summary: summary), baseHref: nil)
        #expect(page.contains("<main class=\"conversation\">"))
        #expect(page.contains("<header class=\"conversation\">"))
        #expect(page.contains("<h1 id=\"fix-the-login\">Fix the login</h1>"))
        #expect(page.contains("</header><article class=\"turn you\"><div class=\"speaker\">You</div><div class=\"bubble\">"))
        #expect(page.contains("<p>Fix the login</p>"))
        #expect(page.contains("</div></article><article class=\"turn agent\"><div class=\"speaker\">Claude Code</div><div class=\"bubble\">"))
        #expect(page.contains("<div class=\"did\"><div class=\"src\" data-line=\"16\" data-line-end=\"17\"><ul>\n<li><p><code>Edited a.ts</code></p>\n</li>\n</ul>\n</div>\n</div>"))
        #expect(page.hasSuffix("</div></article></main></body></html>"))
        #expect(!page.contains("<h2"))
        #expect(!page.contains("tiri:you"))
        // Any other document is as it was.
        let plain = MarkdownRenderer.page(markdown: "# Title\n\n<!-- tiri:you -->\n## You\n\nhi", baseHref: nil)
        #expect(plain.contains("<main>"))
        #expect(plain.contains("<h2 id=\"you\">You</h2>"))
        #expect(!plain.contains("turn you"))
    }

    @Test func mathRendersInAConversationAsAnywhere() throws {
        var chat = claude
        chat.append(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "So $x^2$ and\n\n$$\nS = 1\n$$"]]], "sessionId": "abc"])
        chat.append(["type": "user", "message": ["role": "user", "content": "and $y$?"], "sessionId": "abc"])
        let summary = try #require(Conversations.summary(agent: "claude", file: "/h/abc.jsonl", date: Date(), head: lines(chat)))
        let extras = DocumentExtras(renderMath: { tex, display in "<i>\(tex)\(display ? "!" : "")</i>" }, mathStylesheet: { "/* math */" })
        let page = MarkdownRenderer.render(markdown: Conversations.markdown(lines(chat), summary: summary), baseHref: nil, extras: extras).html
        #expect(page.contains("<p>So <span class=\"math\" data-tex=\"$x^2$\"><i>x^2</i></span> and</p>"))
        #expect(page.contains("<span class=\"math math-display\" data-tex=\"$$\nS = 1\n$$\"><i>S = 1!</i></span>"))
        #expect(page.contains("<article class=\"turn you\"><div class=\"speaker\">You</div><div class=\"bubble\"><div class=\"src\" data-line=\"29\" data-line-end=\"29\"><p>and <span class=\"math\" data-tex=\"$y$\"><i>y</i></span>?</p>"))
        #expect(page.contains("/* math */"))
        #expect(page.contains(".math-display"))
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

    @Test func aCodexScriptSaysWhichCommandsItRan() throws {
        let script = "text(await tools.exec_command({cmd:\"pwd; rg -n \\\"model_grad\\\" .\",\"max_output_tokens\":6500}));\ntext(await tools.exec_command({cmd:\"cat a.py\\nhead b.py\", workdir: \"/w\"}));"
        #expect(Conversations.scriptedCommands(script) == ["pwd; rg -n \"model_grad\" .", "cat a.py\nhead b.py"])
        var chat = codex
        chat.append(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "exec", "input": script]])
        let summary = try #require(Conversations.summary(agent: "codex", file: "/h/rollout.jsonl", date: Date(), head: lines(chat)))
        let text = Conversations.markdown(lines(chat), summary: summary)
        #expect(text.contains("- `Ran pwd; rg -n \"model_grad\" .`\n- `Ran cat a.py`\n"))
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
