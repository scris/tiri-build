import Foundation
import Testing
@testable import TiriCore

@Suite struct AgentRosterTests {
    private let shell = TerminalPreset(name: "Shell", command: "")
    private let claude = TerminalPreset(name: "Claude Code", command: "claude")
    private let codex = TerminalPreset(name: "Codex", command: "codex")
    private let grok = TerminalPreset(name: "Grok", command: "grok")
    private var all: [TerminalPreset] { [shell, claude, codex, grok] }

    @Test func listsAgentsAndNotTheShell() {
        #expect(AgentRoster.entries(all).map(\.id) == ["claude", "codex", "grok"])
        #expect(AgentRoster.entries(all).allSatisfy { $0.isEnabled })
    }

    @Test func anAgentMissingFromTheListShowsAsOff() {
        let entries = AgentRoster.entries([shell, claude])
        #expect(entries.map(\.id) == ["claude", "codex", "grok"])
        #expect(entries.map(\.isEnabled) == [true, false, false])
    }

    @Test func keepsYourCommandAndNameForAKnownAgent() throws {
        let entry = try #require(AgentRoster.entries([TerminalPreset(name: "Fast", command: "/opt/bin/grok --model fast")]).first)
        #expect(entry.id == "grok")
        #expect(entry.agent == .grok)
        #expect(entry.name == "Fast")
        #expect(!entry.isCustom)
    }

    @Test func turningOffKeepsItAndTheActiveListDropsIt() throws {
        let presets = try AgentRoster.setEnabled(false, "codex", in: all)
        #expect(presets.count == 4)
        #expect(AgentRoster.find("codex", in: presets)?.isEnabled == false)
        var settings = TiriSettings()
        settings.terminalPresets = presets
        #expect(settings.activePresets.map(\.command) == ["", "claude", "grok"])
    }

    /// The case someone actually has: only one agent, or two of them.
    @Test func oneOrAnyTwo() throws {
        var settings = TiriSettings()
        settings.terminalPresets = try AgentRoster.setEnabled(false, "grok", in: AgentRoster.setEnabled(false, "codex", in: all))
        #expect(settings.activePresets.filter { !$0.command.isEmpty }.map(\.name) == ["Claude Code"])
        settings.terminalPresets = try AgentRoster.setEnabled(false, "claude", in: all)
        #expect(settings.activePresets.filter { !$0.command.isEmpty }.map(\.name) == ["Codex", "Grok"])
    }

    @Test func turningOnBringsItBackInPlace() throws {
        let off = try AgentRoster.setEnabled(false, "claude", in: all)
        #expect(try AgentRoster.setEnabled(true, "claude", in: off) == all)
    }

    @Test func turningOnOneNotInTheListAddsIt() throws {
        let presets = try AgentRoster.setEnabled(true, "grok", in: [shell, claude])
        #expect(presets.last == grok)
    }

    @Test func turningOffOneNotInTheListChangesNothing() throws {
        #expect(try AgentRoster.setEnabled(false, "grok", in: [shell, claude]) == [shell, claude])
    }

    @Test func findsItByAnyOfItsNames() {
        for name in ["claude", "Claude Code", "CLAUDE CODE", " claude "] {
            #expect(AgentRoster.find(name, in: all)?.id == "claude")
        }
        #expect(AgentRoster.find("nonsense", in: all) == nil)
    }

    @Test func anUnknownNameIsAClearProblem() {
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.setEnabled(true, "nonsense", in: all) }
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.remove("nonsense", from: all) }
    }

    @Test func anyCommandCanBeAnAgent() throws {
        let presets = try AgentRoster.add(name: "Aider", command: "aider --yes", to: all)
        let entry = try #require(AgentRoster.find("aider", in: presets))
        #expect(entry.isCustom)
        #expect(entry.name == "Aider")
        #expect(entry.command == "aider --yes")
    }

    @Test func aMissingNameComesFromTheCommand() throws {
        #expect(try AgentRoster.add(name: "", command: "/opt/bin/aider", to: all).last?.name == "aider")
    }

    @Test func addingOneAlreadyThereTurnsItOn() throws {
        let off = try AgentRoster.setEnabled(false, "grok", in: all)
        #expect(try AgentRoster.add(name: "Whatever", command: "grok", to: off) == all)
    }

    @Test func addingAKnownAgentGivesItItsOwnName() throws {
        #expect(try AgentRoster.add(name: "", command: "grok", to: [shell]).last?.name == "Grok")
    }

    @Test func addingNeedsACommandAndAFreeName() {
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.add(name: "X", command: "  ", to: all) }
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.add(name: "codex", command: "aider", to: all) }
    }

    @Test func yourOwnCanBeDeleted() throws {
        let added = try AgentRoster.add(name: "Aider", command: "aider", to: all)
        #expect(try AgentRoster.remove("aider", from: added) == all)
    }

    @Test func oneOfTirisOwnIsOnlyTurnedOff() throws {
        let presets = try AgentRoster.remove("codex", from: all)
        #expect(AgentRoster.find("codex", in: presets)?.isEnabled == false)
    }

    @Test func aNewAgentDoesNotComeBackAfterBeingTurnedOff() throws {
        let off = try AgentRoster.setEnabled(false, "grok", in: all)
        let adopted = AgentCatalog.adopting(into: off, resume: [:], known: AgentCatalog.alwaysKnown)
        #expect(adopted.presets == off)
    }

    @Test func changingItsCommandAndName() throws {
        let presets = try AgentRoster.update("grok", name: "Fast", command: "grok --model fast", in: all)
        let entry = try #require(AgentRoster.find("grok", in: presets))
        #expect(entry.name == "Fast")
        #expect(entry.command == "grok --model fast")
    }

    @Test func changesThatWouldCollideAreRefused() {
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.update("grok", name: "Grok", command: "codex", in: all) }
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.update("grok", name: "Codex", command: "grok", in: all) }
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.update("grok", name: "", command: "grok", in: all) }
        #expect(throws: AgentRoster.Problem.self) { try AgentRoster.update("grok", name: "Grok", command: " ", in: all) }
    }

    @Test func offIsStoredAndComesBack() throws {
        let presets = try AgentRoster.setEnabled(false, "codex", in: all)
        let data = try JSONEncoder().encode(TerminalPreset.json(presets))
        let text = "{ \"terminal.presets\": \(String(decoding: data, as: UTF8.self)) }"
        #expect(try TiriSettings.parse(text).terminalPresets == presets)
        #expect(!String(decoding: try JSONEncoder().encode(TerminalPreset.json(all)), as: UTF8.self).contains("enabled"))
    }

    @Test func aSettingsFileWithoutTheFlagMeansOn() throws {
        let parsed = try TiriSettings.parse(#"{ "terminal.presets": [{ "name": "Codex", "command": "codex" }] }"#)
        #expect(parsed.terminalPresets.first?.isEnabled == true)
    }

    @Test func theCommandLineReadsIt() throws {
        let environment = CLIParser.Environment(cwd: "/p", itemID: nil, fileExists: { _ in false }, readStdin: { Data() })
        func request(_ arguments: [String]) throws -> ControlRequest? {
            if case .request(let request, _) = try CLIParser.parse(arguments, environment: environment) { return request }
            return nil
        }
        #expect(try request(["agents"])?.cmd == "agents.list")
        #expect(try request(["agents", "off", "codex"])?.args["on"]?.boolValue == false)
        #expect(try request(["agents", "add", "Aider", "aider", "--yes"])?.args["command"]?.stringValue == "aider --yes")
        #expect(throws: CLIParser.UsageError.self) { try request(["agents", "off"]) }
        #expect(throws: CLIParser.UsageError.self) { try request(["agents", "nonsense"]) }
    }
}
