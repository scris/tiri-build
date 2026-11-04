import Foundation
import Testing
@testable import TiriCore

@Suite struct AgentCatalogTests {
    @Test(arguments: [
        (["grok"], AgentIdentity.grok),
        (["/Users/r/.local/bin/grok", "--model", "x"], .grok),
        (["/Users/r/.grok/downloads/grok-1.0.70-macos-aarch64"], .grok),
        (["/Users/r/.grok/bin/grok"], .grok),
        (["claude"], .claude),
        (["/Users/r/.local/share/claude/versions/2.1.318"], .claude),
        (["/opt/node", "/x/bin/codex"], .codex),
    ])
    func recognizesWhatsRunning(commandLine: [String], agent: AgentIdentity) {
        #expect(AgentCatalog.identify(commandLine: commandLine, command: nil) == agent)
    }

    @Test func oneShotRunsDontSpeakForTheSession() {
        let session = ["/Users/r/.local/bin/grok", "--resume", "abc"]
        #expect(!AgentCatalog.isOneShotRun(ancestors: [["/bin/sh", "-c", "tiri hook grok"], session, ["/bin/zsh", "-l", "-i", "-c", "grok --resume abc"]]))
        // Started by the session around it: the nearest agent is the one that counts.
        #expect(AgentCatalog.isOneShotRun(ancestors: [["/bin/sh", "-c", "tiri hook"], ["grok", "-p", "fix it"], session]))
        #expect(AgentCatalog.isOneShotRun(ancestors: [["node", "/x/@openai/codex/bin/codex.js", "exec", "fix it"]]))
        #expect(AgentCatalog.isOneShotRun(ancestors: [["/opt/bin/codex", "exec", "fix it"], ["codex"]]))
        #expect(!AgentCatalog.isOneShotRun(ancestors: [["codex", "resume", "abc"]]))
        #expect(!AgentCatalog.isOneShotRun(ancestors: [["/bin/zsh"], ["launchd"]]))
        #expect(!AgentCatalog.isOneShotRun(ancestors: []))
    }

    // Each agent's real words for an unknown session, from running it with a made-up ID.
    @Test(arguments: [
        ("claude --resume abc", "No conversation found with session ID: abc", true),
        ("claude --continue", "No conversation found to continue", true),
        ("codex resume abc", "Error: No saved session found with ID abc.", true),
        ("grok --resume abc", "Error: Failed to restore session from remote: fetching session record: session get failed: 404 Not Found", true),
        ("/opt/bin/claude --resume abc", "No conversation found with session ID: abc", true),
        // The conversation may well still be there.
        ("claude --resume abc", "API Error: Connection error.", false),
        ("claude --resume abc", "Please run /login", false),
        ("grok --resume abc", "Error: Failed to restore session from remote: connection refused", false),
        // Only its own words count, and an agent Tiri doesn't know can't say.
        ("codex resume abc", "No conversation found", false),
        ("aider --resume", "No conversation found", false),
    ])
    func toldWhenThereIsNothingToResume(command: String, output: String, nothing: Bool) {
        #expect(AgentCatalog.hasNothingToResume(command: command, output: output) == nothing)
    }

    @Test func recognizesATerminalsCommand() {
        #expect(AgentCatalog.identify(commandLine: [], command: "grok --continue") == .grok)
    }

    @Test func aFileNamedAfterAnAgentIsNotOne() {
        #expect(AgentCatalog.identify(commandLine: ["/usr/bin/vim", "grok.md"], command: nil) == nil)
        #expect(AgentCatalog.identify(commandLine: ["/bin/zsh"], command: nil) == nil)
    }

    @Test func anythingInTheMenuCanCountAsAnAgent() {
        #expect(AgentCatalog.identify(commandLine: ["aider"], command: nil) == nil)
        let found = AgentCatalog.identify(commandLine: ["/opt/bin/aider", "--yes"], command: nil, custom: ["aider"])
        #expect(found == .other)
        #expect(found?.profile == nil)
        #expect(found?.title == "Agent")
    }

    @Test func onlyKnownNamesAreAgents() {
        #expect(AgentIdentity(rawValue: "grok") == .grok)
        #expect(AgentIdentity(rawValue: "nonsense") == nil)
        #expect(AgentIdentity.allCases.map(\.rawValue) == ["claude", "codex", "grok"])
    }

    @Test func everyEntryIsComplete() throws {
        #expect(Set(AgentCatalog.all.map(\.id)).count == AgentCatalog.all.count)
        for profile in AgentCatalog.all {
            #expect(!profile.executableNames.isEmpty)
            #expect(profile.executableNames.contains(profile.command))
            #expect(URL(string: profile.website) != nil)
            #expect(profile.resumeCommand?.contains("{id}") == true)
            #expect(profile.continueCommand != nil)
            if profile.hookInstall != nil {
                #expect(profile.parseHook != nil)
                #expect(profile.hookExample != nil)
                #expect(!profile.hookEvents.isEmpty)
            }
        }
    }

    @Test func eachWritesMentionsItsOwnWay() {
        func text(_ agent: AgentIdentity) -> String {
            AgentReference.text(path: "/p/src/a.ts", cwd: "/p", firstLine: 11, lastLine: 19, agent: agent)
        }
        #expect(text(.claude) == "@src/a.ts#L12-20 ")
        #expect(text(.codex) == "src/a.ts:12-20 ")
        #expect(text(.grok) == "@src/a.ts:12-20 ")
        #expect(text(.other) == "src/a.ts:12-20 ")
        #expect(AgentReference.text(path: "/p/a b.ts", cwd: "/p", firstLine: nil, lastLine: nil, agent: .grok) == "@\"a b.ts\" ")
    }

    @Test func onlyClaudeSpeaksTheEditorProtocol() {
        #expect(AgentIdentity.claude.profile?.speaksEditorProtocol == true)
        #expect(AgentIdentity.grok.profile?.speaksEditorProtocol == false)
        #expect(AgentIdentity.codex.profile?.speaksEditorProtocol == false)
    }
}

@Suite struct AgentSettingsTests {
    @Test func theMenuAndResumeComeFromTheCatalog() {
        let settings = TiriSettings()
        #expect(settings.terminalPresets.map(\.command) == ["", "claude", "codex", "grok"])
        #expect(settings.terminalResume["grok"] == "grok --continue")
    }

    @Test func theDefaultFileSaysTheSame() throws {
        let parsed = try TiriSettings.parse(TiriSettings.defaultFileContents)
        #expect(parsed.terminalPresets == TiriSettings().terminalPresets)
        #expect(parsed.terminalResume == TiriSettings().terminalResume)
    }

    @Test func yourResumeCommandsAreLeftAlone() throws {
        let parsed = try TiriSettings.parse(#"{ "terminal.resume": { "claude": "claude --continue --verbose" } }"#)
        #expect(parsed.terminalResume == ["claude": "claude --continue --verbose"])
    }

    private let oldResume = ["claude": "claude --continue", "codex": "codex resume --last"]

    @Test func aNewAgentCanBeResumedOnce() {
        let first = AgentCatalog.adopting(into: oldMenu, resume: oldResume, known: AgentCatalog.alwaysKnown)
        #expect(first.resume["grok"] == "grok --continue")
        // Deleted after that, it stays deleted.
        #expect(AgentCatalog.adopting(into: oldMenu, resume: oldResume, known: first.known).resume["grok"] == nil)
    }

    @Test func yourOwnResumeCommandForANewAgentStays() {
        let mine = oldResume.merging(["grok": "grok -c --model fast"]) { _, new in new }
        #expect(AgentCatalog.adopting(into: oldMenu, resume: mine, known: AgentCatalog.alwaysKnown).resume["grok"] == "grok -c --model fast")
    }

    private let oldMenu = [TerminalPreset(name: "Shell", command: ""), TerminalPreset(name: "Claude Code", command: "claude"), TerminalPreset(name: "Codex", command: "codex")]

    @Test func aNewAgentJoinsAMenuThatWasListedInFull() {
        let result = AgentCatalog.adopting(into: oldMenu, resume: oldResume, known: AgentCatalog.alwaysKnown)
        #expect(result.presets.map(\.command) == ["", "claude", "codex", "grok"])
        #expect(result.known.contains("grok"))
    }

    @Test func removingItKeepsItRemoved() {
        let first = AgentCatalog.adopting(into: oldMenu, resume: oldResume, known: AgentCatalog.alwaysKnown)
        let second = AgentCatalog.adopting(into: oldMenu, resume: oldResume, known: first.known)
        #expect(second.presets == oldMenu)
    }

    @Test func anAgentYouAlreadyAddedIsNotAddedAgain() {
        let menu = oldMenu + [TerminalPreset(name: "My Grok", command: "grok --model fast")]
        #expect(AgentCatalog.adopting(into: menu, resume: oldResume, known: AgentCatalog.alwaysKnown).presets == menu)
    }

    @Test func aMenuWithoutAnyAgentsStillHearsOfANewOne() {
        let menu = [TerminalPreset(name: "Shell", command: "")]
        #expect(AgentCatalog.adopting(into: menu, resume: oldResume, known: AgentCatalog.alwaysKnown).presets.map(\.command) == ["", "grok"])
    }
}

@Suite struct AgentRestoreTests {
    private func plan(_ command: String, session: String? = nil) -> TerminalRestore.Plan {
        TerminalRestore.plan(for: command, sessionID: session, resume: AgentCatalog.defaultResume, enabled: true)
    }

    @Test func comesBackToTheExactConversation() {
        #expect(plan("grok", session: "01a1a56a-c60d") == .run("grok --resume 01a1a56a-c60d"))
        #expect(plan("claude", session: "abc") == .run("claude --resume abc"))
        #expect(plan("codex", session: "abc") == .run("codex resume abc"))
    }

    @Test func withoutAnIDItContinues() {
        #expect(plan("grok") == .run("grok --continue"))
    }

    @Test func keepsOptions() {
        #expect(plan("grok --model fast", session: "abc") == .run("grok --resume abc --model fast"))
    }

    @Test func aOneShotHasNothingToComeBackTo() {
        #expect(plan("grok -p hello") == .prefill("grok -p hello"))
        #expect(plan("grok --single hello") == .prefill("grok --single hello"))
        #expect(plan("grok agent stdio") == .prefill("grok agent stdio"))
        #expect(plan("codex exec go") == .prefill("codex exec go"))
    }

    @Test func aPromptOnTheCommandLineIsNotRunAgain() {
        #expect(plan("grok \"delete everything\"", session: "abc") == .run("grok --resume abc"))
    }

    @Test func alreadyResumingStaysAsItIs() {
        #expect(plan("grok --continue") == .run("grok --continue"))
        #expect(plan("grok -r abc") == .run("grok -r abc"))
    }
}

/// Grok's payloads as Grok really sent them, cut down.
@Suite struct GrokHookTests {
    private func grok(_ json: String) -> AgentHookEvent? { AgentHookEvent.parseGrok(Data(json.utf8)) }

    @Test func aPromptStartsATurn() {
        let event = grok(#"{"hookEventName":"user_prompt_submit","sessionId":"s1","promptId":"p","prompt":"Reply with ok.","hook_event_name":"UserPromptSubmit","session_id":"s1"}"#)
        #expect(event == AgentHookEvent(state: "working", sessionID: "s1", turn: .start, prompt: "Reply with ok."))
    }

    @Test func stoppingEndsATurn() {
        let event = grok(#"{"hookEventName":"stop","sessionId":"s1","reason":"end_turn","stopHookActive":false,"hook_event_name":"Stop","session_id":"s1"}"#)
        #expect(event?.state == "done")
        #expect(event?.turn == .end)
    }

    /// It fires again as the session closes, after its last turn has already ended.
    @Test func closingIsNotTheEndOfATurn() {
        let event = grok(#"{"hookEventName":"stop","sessionId":"s1","reason":"shutdown","hook_event_name":"Stop","session_id":"s1"}"#)
        #expect(event?.state == nil)
        #expect(event?.turn == nil)
        #expect(event?.sessionID == "s1")
    }

    @Test func interruptingEndsATurnToo() {
        let event = grok(#"{"hookEventName":"stop_cancelled","reason":"user_interrupt","hook_event_name":"StopCancelled","sessionId":"s1"}"#)
        #expect(event?.turn == .end)
        #expect(event?.state == "done")
        #expect(event?.sessionID == "s1")
    }

    @Test func onlyAPermissionPromptIsWaitingForYou() {
        #expect(grok(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow this?"}"#)?.state == "needs-input")
        #expect(grok(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow this?"}"#)?.message == "Allow this?")
        #expect(grok(#"{"hook_event_name":"Notification","notificationType":"permission_prompt"}"#)?.state == "needs-input")
        #expect(grok(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","sessionId":"s"}"#)?.state == nil)
        #expect(grok(#"{"hook_event_name":"Notification","notification_type":"task_complete","sessionId":"s"}"#)?.state == nil)
    }

    @Test func aSessionStartingIsIdle() {
        #expect(grok(#"{"hook_event_name":"SessionStart","sessionId":"s1","source":"new"}"#) == AgentHookEvent(state: "idle", sessionID: "s1"))
    }

    @Test func toolsMeanWorking() {
        #expect(grok(#"{"hook_event_name":"PostToolUse","toolName":"read_file"}"#)?.state == "working")
    }

    @Test func nonsenseIsIgnored() {
        #expect(grok("not json") == nil)
        #expect(grok(#"{"hook_event_name":"Whatever"}"#) == nil)
    }

    /// Grok runs Claude Code's configured hooks, and those call `tiri hook claude`.
    @Test func theSenderIsWhoeverReallySentIt() throws {
        let grokPayload = #"{"hookEventName":"stop","hook_event_name":"Stop","reason":"end_turn","session_id":"g"}"#
        let environment = CLIParser.Environment(cwd: "/p", itemID: "i-1", fileExists: { _ in false }, readStdin: { Data() })
        guard case .request(let request, _) = try CLIParser.parse(["hook", "claude", grokPayload], environment: environment) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.args["tool"]?.stringValue == "grok")
        #expect(request.args["turn"]?.stringValue == "end")
    }

    @Test func aClaudePayloadStaysClaude() throws {
        let payload = #"{"hook_event_name":"Stop","session_id":"c"}"#
        let environment = CLIParser.Environment(cwd: "/p", itemID: "i-1", fileExists: { _ in false }, readStdin: { Data() })
        guard case .request(let request, _) = try CLIParser.parse(["hook", "claude", payload], environment: environment) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.args["tool"]?.stringValue == "claude")
    }

    /// Claude's one-shot check reads an environment variable that a Grok started by Claude inherits.
    @Test func claudesOneShotRuleIsNotGroks() throws {
        let environment = CLIParser.Environment(cwd: "/p", itemID: "i-1", claudeEntrypoint: "sdk-cli", fileExists: { _ in false }, readStdin: { Data() })
        #expect(try CLIParser.parse(["hook", "claude", #"{"hook_event_name":"Stop"}"#], environment: environment) == .quietSuccess)
        guard case .request = try CLIParser.parse(["hook", "grok", #"{"hookEventName":"stop","hook_event_name":"Stop"}"#], environment: environment) else {
            Issue.record("Expected a request")
            return
        }
    }

    @Test func aTerminalRunningGrokTakesOnlyGroksHooks() {
        let spec = TerminalSpec(command: "grok", cwd: "/p")
        #expect(spec.acceptsHook(from: "grok"))
        #expect(!spec.acceptsHook(from: "claude"))
    }

    @Test func installingIsAFileOfItsOwn() throws {
        let text = try AgentHooks.installing(.grok, in: "")
        #expect(AgentHooks.isInstalled(.grok, in: text))
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let hooks = decoded?["hooks"] as? [String: Any]
        #expect(hooks?.keys.contains("StopCancelled") == true)
        #expect(text.contains("tiri hook grok"))
        #expect(!text.contains("async"))
        #expect(try AgentHooks.removing(.grok, from: text).isEmpty)
    }

    @Test func itsFileIsInGroksHooksFolder() {
        let home = URL(fileURLWithPath: "/h")
        #expect(AgentHooks.configURL(for: .grok, environment: [:], home: home).path == "/h/.grok/hooks/tiri.json")
        #expect(AgentHooks.configURL(for: .grok, environment: ["GROK_HOME": "/elsewhere"], home: home).path == "/elsewhere/hooks/tiri.json")
        #expect(AgentHooks.configURL(for: .claude, environment: [:], home: home).path == "/h/.claude/settings.json")
        #expect(AgentHooks.configURL(for: .codex, environment: [:], home: home).path == "/h/.codex/config.toml")
    }

    @Test func theCommandLineKnowsAboutIt() throws {
        let environment = CLIParser.Environment(cwd: "/p", itemID: nil, fileExists: { _ in false }, readStdin: { Data() })
        guard case .printText(let text) = try CLIParser.parse(["hooks", "grok"], environment: environment) else {
            Issue.record("Expected text")
            return
        }
        #expect(text.contains("tiri hook grok"))
        guard case .request(let request, _) = try CLIParser.parse(["hooks", "install", "grok"], environment: environment) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.cmd == "hooks.install")
        #expect(throws: CLIParser.UsageError.self) { try CLIParser.parse(["hook", "nonsense"], environment: environment) }
        #expect(throws: CLIParser.UsageError.self) { try CLIParser.parse(["hooks", "install", "other"], environment: environment) }
    }
}
