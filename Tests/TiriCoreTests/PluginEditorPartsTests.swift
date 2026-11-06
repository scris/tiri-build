import Foundation
import Testing
@testable import TiriCore

/// Colors on text, questions before a command, marks on files, row menus and events.
struct PluginEditorPartsTests {
    private let base = #""name": "demo", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0""#

    private func issues(_ manifest: String) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(PluginManifest.folderName), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try manifest.write(to: PluginManifest.url(in: folder), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let program = folder.appendingPathComponent("bin/list")
        try "#!/bin/sh\necho '[]'\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return PluginValidator.validate(try PluginManifest.load(from: folder), folder: folder).filter { $0.severity == .error }.map(\.message)
    }

    // MARK: Highlights

    @Test func aGoodHighlightPasses() throws {
        let manifest = #"{\#(base), "settings": [{"key": "tags", "title": "Tags", "type": "list", "default": ["TODO", "[ ]"]}],"#
            + ##" "highlights": [{"pattern": "(?://|#)\\s*(${settings.tags})", "group": 1, "color": "orange", "background": "#ffcc0033", "onlyInComments": true}]}"##
        #expect(try issues(manifest).isEmpty)
    }

    @Test func aHighlightThatCantWorkIsCaught() throws {
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "(unclosed", "color": "red"}]}"#).contains { $0.contains("isn't a regular expression") })
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "TODO"}]}"#).contains { $0.contains("says nothing about how it looks") })
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "TODO", "color": "chartreuse"}]}"#).contains { $0.contains("isn't a color") })
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "TODO", "group": 2, "color": "red"}]}"#).contains { $0.contains("has 0") })
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "x*", "color": "red"}]}"#).contains { $0.contains("matches nothing at all") })
        #expect(try issues(#"{\#(base), "highlights": [{"pattern": "${settings.nope}", "color": "red"}]}"#).contains { $0.contains("isn't one of its settings") })
    }

    @Test func aSettingInAPatternMeansItselfAndAListIsAnyOfIt() {
        let filled = PluginHighlightPattern.fill("#\\s*(${settings.tags})", settings: ["tags": .array([.string("TODO"), .string("[ ]")])])
        #expect(filled.hasPrefix("#\\s*((?:TODO|"))
        let expression = try! NSRegularExpression(pattern: filled)
        #expect(PluginHighlightPattern.matches(expression, group: 1, in: "x = 1  # [ ] later") == [NSRange(location: 9, length: 3)])
        #expect(PluginHighlightPattern.matches(expression, group: 1, in: "# TODONE").count == 1)
        // An empty list matches nothing, rather than everything.
        let none = try! NSRegularExpression(pattern: PluginHighlightPattern.fill("(${settings.tags})", settings: ["tags": .array([])]))
        #expect(PluginHighlightPattern.matches(none, group: nil, in: "anything").isEmpty)
    }

    @Test func aVeryLongLineIsLeftAlone() {
        let expression = try! NSRegularExpression(pattern: "TODO")
        #expect(PluginHighlightPattern.matches(expression, group: nil, in: String(repeating: "a", count: 3_000) + "TODO").isEmpty)
    }

    @Test func colorsAreNamesOrHex() {
        #expect(PluginColor.parse("Orange") == .named("orange"))
        #expect(PluginColor.parse("#fff") == .rgba(1, 1, 1, 1))
        #expect(PluginColor.parse("#ff000080") == .rgba(1, 0, 0, Double(0x80) / 255))
        #expect(PluginColor.parse("#12345") == nil)
        #expect(PluginColor.parse("fuchsia") == nil)
    }

    // MARK: Questions and saving

    @Test func inputsAreCheckedAndTheirKindFollowsFromWhatTheyHave() throws {
        let manifest = try PluginManifest.decode(Data(#"""
        {"name": "demo", "version": "1.0.0", "apiVersion": 1, "commands": [{"id": "a", "title": "A", "exec": ["bin/list"], "save": "front",
          "input": [{"name": "word", "prompt": "Word"}, {"name": "pick", "prompt": "Pick", "options": [{"value": "x"}]}]}]}
        """#.utf8))
        #expect(manifest.commands?.first?.save == .front)
        #expect(manifest.commands?.first?.input?.map(\.kind) == [.text, .choice])
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/list"], "input": [{"name": "x", "prompt": "X", "type": "choice"}]}]}"#)
            .contains { $0.contains("needs options or optionsFrom") })
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/list"], "input": [{"name": "x", "prompt": "X"}, {"name": "x", "prompt": "Y"}]}]}"#)
            .contains { $0.contains("twice") })
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/list"], "input": [{"name": "x", "prompt": "X", "optionsFrom": {"exec": ["bin/list"]}}]}]}"#).isEmpty)
    }

    @Test func choicesComeAsWordsOrRows() {
        #expect(PluginManifest.Choice.list(from: .array([.string("a"), .string("b")])).map(\.value) == ["a", "b"])
        let rows = PluginManifest.Choice.list(from: .object(["items": .array([.object(["value": .int(2), "label": .string("Two"), "detail": .string("easy")])])]))
        #expect(rows == [PluginManifest.Choice(value: "2", label: "Two", detail: "easy")])
    }

    @Test func aProgramThatGivesChoicesIsSaidBeforeTurningOn() throws {
        let manifest = try PluginManifest.decode(Data(#"{"name": "d", "version": "1", "apiVersion": 1, "commands": [{"id": "a", "title": "A", "ask": "hi", "input": [{"name": "x", "prompt": "X", "optionsFrom": {"exec": ["bin/list", "--all"]}}]}]}"#.utf8))
        #expect(manifest.programs == ["bin/list --all"])
    }

    // MARK: Rows, marks and events

    @Test func aRowsColorAndMenuAreRead() {
        let items = PluginTreeItem.list(from: .array([.object([
            "title": .string("Fix this"), "color": .string("red"), "symbolColor": .string("#00ff00"),
            "menu": .array([.object(["title": .string("Hide"), "command": .string("hide"), "symbol": .string("eye.slash")]), .object(["title": .string("no command")])]),
        ])]))
        #expect(items.first?.color == "red")
        #expect(items.first?.symbolColor == "#00ff00")
        #expect(items.first?.menu == [PluginManifest.MenuItem(title: "Hide", command: "hide", symbol: "eye.slash")])
    }

    @Test func aMenuRunsOnlyItsOwnCommands() throws {
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/list"]}], "sidebar": [{"id": "s", "title": "S", "menu": [{"title": "X", "command": "other.thing"}]}]}"#)
            .contains { $0.contains("isn't one of its own commands") })
    }

    @Test func fileMarksAreReadFromEitherShape() {
        let marks = PluginFileMark.list(from: .object([
            "files": .object(["src/a.py": .object(["badge": .int(12), "color": .string("orange")]), "b.py": .object(["tooltip": .string("only a tip")])]),
            "items": .array([.object(["path": .string("/elsewhere/c.py"), "badge": .string("!!!")])]),
        ]), folder: "/work")
        #expect(marks["/work/src/a.py"] == PluginFileMark(badge: "12", color: "orange"))
        // Nothing to show is no mark at all.
        #expect(marks["/work/b.py"] == nil)
        #expect(marks["/elsewhere/c.py"]?.badge == "!!")
    }

    @Test func fileMarksNeedAProviderThatWorks() throws {
        #expect(try issues(#"{\#(base), "fileMarks": [{"id": "m", "provider": {"exec": ["bin/list"]}, "refresh": {"onFileChange": true, "onFrontFile": true}}]}"#).isEmpty)
        #expect(try issues(#"{\#(base), "fileMarks": [{"id": "m", "provider": {"process": "nope", "method": "x"}}]}"#).contains { $0.contains("isn't declared") })
    }

    @Test func eventsAreNamedOrTheManifestSaysWhy() throws {
        let manifest = try PluginManifest.decode(Data(#"{"name": "d", "version": "1", "apiVersion": 1, "processes": [{"id": "p", "exec": ["bin/x"], "events": ["frontFile", "filesChanged"]}]}"#.utf8))
        #expect(manifest.processes?.first?.events == [.frontFile, .filesChanged])
        #expect(throws: DecodingError.self) {
            try PluginManifest.decode(Data(#"{"name": "d", "version": "1", "apiVersion": 1, "processes": [{"id": "p", "exec": ["bin/x"], "events": ["typing"]}]}"#.utf8))
        }
    }

    @Test func aPanelThatSeesOpenFilesSaysSo() throws {
        let manifest = try PluginManifest.decode(Data(#"{"name": "d", "version": "1", "apiVersion": 1, "panels": [{"id": "p", "title": "P", "entry": "p.html", "allow": {"editor": true}}], "highlights": [{"pattern": "x", "color": "red"}]}"#.utf8))
        #expect(manifest.panelPowers.contains { $0.contains("which files you have open") })
        #expect(manifest.additions.contains("1 color in the editor"))
    }
}
