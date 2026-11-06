import Foundation
import Testing
@testable import TiriCore

/// Installing Tiri's hooks changes only Tiri's lines in someone's settings.json.
@Suite struct ClaudeSettingsEditTests {
    private func object(_ text: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private func install(_ text: String) throws -> String { try AgentHooks.installing(.claude, in: text) }
    private func remove(_ text: String) throws -> String { try AgentHooks.removing(.claude, from: text) }

    /// Every event has exactly one entry of Tiri's, and nothing else of the file changed meaning.
    private func expectInstalled(_ installed: String, over original: String) throws {
        let after = try object(installed)
        let before = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSDictionary() : try object(original)
        for key in before.allKeys as! [String] where key != "hooks" {
            #expect((after[key] as AnyObject).isEqual(before[key]), "\(key)")
        }
        let hooks = try #require(after["hooks"] as? [String: [[String: Any]]])
        for event in AgentHooks.claudeEvents {
            let tiris = hooks[event, default: []].filter { (($0["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == AgentHooks.claudeCommand } }
            #expect(tiris.count == 1, "\(event)")
        }
    }

    private let handWritten = """
    {
      "zeta": 1,
      "model": "opus",
      "temperature": 0.7,
      "big": 100000000000000000000,
      "exp": 1e3,
      "env": { "ANTHROPIC_API_KEY": "sk-not-real" }
    }

    """

    @Test func noHooksKeyAddsOneMemberAtTheEnd() throws {
        let installed = try install(handWritten)
        try expectInstalled(installed, over: handWritten)
        // What was there is still there, byte for byte, digits and order included.
        let kept = handWritten.components(separatedBy: "\n}")[0]
        #expect(installed.hasPrefix(kept + ",\n  \"hooks\": {\n    \"SessionStart\": [\n      {\n        \"hooks\": [\n          {\n"))
        #expect(installed.contains("0.7,") && !installed.contains("0.69999"))
        #expect(installed.contains("100000000000000000000") && installed.contains("1e3"))
        #expect(installed.hasSuffix("\n}\n"))
        #expect(try remove(installed) == handWritten)
    }

    @Test func anEmptyFileGetsHooks() throws {
        for text in ["", "  \n"] {
            let installed = try install(text)
            try expectInstalled(installed, over: text)
        }
    }

    @Test func anEmptyObjectGetsHooks() throws {
        let installed = try install("{}\n")
        try expectInstalled(installed, over: "{}")
        #expect(installed.hasPrefix("{\n  \"hooks\": {\n    \"SessionStart\": ["))
        #expect(installed.hasSuffix("\n}\n"))
    }

    @Test func existingHooksForTheSameEventStayFirst() throws {
        let original = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "say done" }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{ "type": "command", "command": "gate.sh" }]
              }
            ]
          },
          "model": "opus"
        }
        """
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        let hooks = try #require(try object(installed)["hooks"] as? [String: [[String: Any]]])
        #expect((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect(hooks["PreToolUse"]?.count == 1)
        // Their lines are untouched; Tiri's entry follows theirs at the same depth.
        #expect(installed.contains("""
                  { "type": "command", "command": "say done" }
                ]
              },
              {
                "hooks": [
        """))
        #expect(installed.contains(#""hooks": [{ "type": "command", "command": "gate.sh" }]"#))
        #expect(installed.hasSuffix("  \"model\": \"opus\"\n}"))
        #expect(try remove(installed) == original)
    }

    @Test func anEmptyEventListIsFilled() throws {
        let original = "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        #expect(installed.hasPrefix("{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": ["))
    }

    @Test func tabsStayTabs() throws {
        let original = "{\n\t\"model\": \"opus\",\n\t\"hooks\": {\n\t\t\"Stop\": [\n\t\t\t{ \"hooks\": [] }\n\t\t]\n\t}\n}\n"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        let added = installed.split(separator: "\n").filter { $0.contains("tiri hook claude") }
        #expect(!added.isEmpty)
        #expect(added.allSatisfy { $0.hasPrefix("\t") && !$0.hasPrefix(" ") && !$0.contains("  ") })
        #expect(!installed.contains("  \""))
        #expect(try remove(installed) == original)
    }

    @Test func fourSpacesStayFourSpaces() throws {
        let original = "{\n    \"model\": \"opus\",\n    \"permissions\": {\n        \"allow\": [\"Bash(ls)\"]\n    }\n}"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        #expect(installed.contains("\n    \"hooks\": {\n        \"SessionStart\": [\n            {\n                \"hooks\": ["))
        #expect(try remove(installed) == original)
    }

    @Test func crlfStaysCRLF() throws {
        let original = "{\r\n  \"model\": \"opus\",\r\n  \"hooks\": {\r\n    \"Stop\": [\r\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"say\" } ] }\r\n    ]\r\n  }\r\n}\r\n"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        let bytes = Array(installed.utf8)
        #expect(bytes.indices.allSatisfy { bytes[$0] != 0x0A || ($0 > 0 && bytes[$0 - 1] == 0x0D) })
        #expect(try remove(installed) == original)
    }

    @Test func oneLineStaysOneLine() throws {
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say"}]}]}}"#
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        #expect(!installed.contains("\n"))
        #expect(installed.hasPrefix(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say"}]}, "#))
        #expect(try remove(installed) == original)
    }

    @Test func unicodeAndEscapesSurvive() throws {
        let original = "{\n  \"名前\": \"テスト ✓ 🎉\",\n  \"path\": \"C:\\\\x\\\"y\\u00e9\",\n  \"\\u0068ooks\": {\n    \"Stop\": []\n  }\n}\n"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        #expect(installed.hasPrefix("{\n  \"名前\": \"テスト ✓ 🎉\",\n  \"path\": \"C:\\\\x\\\"y\\u00e9\",\n  \"\\u0068ooks\": {\n    \"Stop\": [\n"))
    }

    @Test func installingTwiceChangesNothing() throws {
        let once = try install(handWritten)
        #expect(try install(once) == once)
    }

    @Test func removingSomethingNotThereChangesNothing() throws {
        #expect(try remove(handWritten) == handWritten)
    }

    @Test func removalTakesOnlyTirisHookFromASharedEntry() throws {
        let original = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "tiri hook claude 2>/dev/null || true" },
                  { "type": "command", "command": "say done" }
                ]
              }
            ],
            "Notification": [
              { "hooks": [{ "type": "command", "command": "tiri hook claude 2>/dev/null || true" }] },
              { "hooks": [{ "type": "command", "command": "notify.sh" }] }
            ],
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "tiri hook claude 2>/dev/null || true" }] }
            ]
          }
        }
        """
        let removed = try remove(original)
        #expect(!AgentHooks.isInstalled(.claude, in: removed))
        #expect(removed == """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "say done" }
                ]
              }
            ],
            "Notification": [
              { "hooks": [{ "type": "command", "command": "notify.sh" }] }
            ]
          }
        }
        """)
    }

    @Test func removingTheLastHookTakesTheHooksKey() throws {
        let installed = try install("{\n  \"model\": \"opus\"\n}\n")
        #expect(try remove(installed) == "{\n  \"model\": \"opus\"\n}\n")
        let alone = try install("{}")
        #expect(try object(try remove(alone)).count == 0)
    }

    @Test func oddShapesStillComeOutRight() throws {
        // Not what Claude Code writes: these fall back to writing the whole file, which still keeps every setting.
        for original in [#"{"hooks": {"Stop": "say done"}, "model": "opus"}"#, #"{"hooks": [], "model": "opus"}"#,
                         #"{"hooks": {"Stop": []}, "hooks": {"Notification": []}, "model": "opus"}"#] {
            let installed = try install(original)
            #expect(AgentHooks.isInstalled(.claude, in: installed))
            #expect(try object(installed)["model"] as? String == "opus")
        }
    }

    @Test func notJSONIsLeftAlone() {
        #expect(throws: (any Error).self) { try install("{ \"a\": 1 ") }
        #expect(throws: (any Error).self) { try install("[1, 2]") }
        #expect(throws: (any Error).self) { try install("{ \"a\": 1 } // a comment") }
    }

    @Test func aTrailingCommaStays() throws {
        // Foundation reads these, so they were there before Tiri and stay after it.
        let original = "{\n  \"model\": \"opus\",\n}\n"
        let installed = try install(original)
        try expectInstalled(installed, over: original)
        #expect(installed.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {\n"))
        #expect(installed.hasSuffix("\n  },\n}\n"))
        #expect(try remove(installed) == original)
    }

    @Test func theScannerFindsSpans() throws {
        let document = try JSONTextEdit.Document(#" { "a" : [1, {"b": null}], "c": "}" } "#)
        #expect(document.root.members.map(\.key) == ["a", "c"])
        let array = try #require(document.root.member("a"))
        #expect(array.kind == .array && array.elements.count == 2)
        #expect(document.root.member("c")?.kind == .scalar)
        #expect(throws: (any Error).self) { try JSONTextEdit.Document(#"{"a": 1} x"#) }
        #expect(throws: (any Error).self) { try JSONTextEdit.Document(#"{"a": "#) }
    }
}
