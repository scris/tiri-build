import Testing
@testable import TiriCore

@Suite struct ShortcutIndexTests {
    private let commands = [
        ShortcutCommand(id: "quickOpen", title: "Go to File…", group: "Navigation"),
        ShortcutCommand(id: "goBack", title: "Go Back", group: "Navigation"),
        ShortcutCommand(id: "gitFetch", title: "Git: Fetch", group: "Changes and Git"),
        ShortcutCommand(id: "splitDown", title: "Split Down", group: "Tabs and Splits"),
    ] + (1...3).map { ShortcutCommand(id: "focusGroup\($0)", title: "Focus Group \($0)", group: "Tabs and Splits") }

    private var bindings: [Keybinding] { Keymap.build(user: []) }

    private func ids(_ sections: [ShortcutSection]) -> [String] { sections.flatMap(\.commands).map(\.id) }

    @Test func groupsKeepTheOrderTheyFirstAppear() {
        let sections = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [])
        #expect(sections.map(\.name) == ["Navigation", "Changes and Git", "Tabs and Splits"])
    }

    @Test func numberedCommandsFoldIntoOneRow() throws {
        let sections = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [])
        let tabs = try #require(sections.last)
        #expect(tabs.rows.count == 2)
        guard case .family(let id, _, let members) = tabs.rows[1] else {
            Issue.record("Expected a family")
            return
        }
        #expect(id == "focusGroup" && members.count == 3)
        #expect(tabs.commands.count == 4)
    }

    @Test func searchingOpensTheFold() {
        let sections = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], query: "focus group 2")
        #expect(ids(sections) == ["focusGroup2"])
        #expect(sections[0].rows == [.command(commands[5])])
    }

    @Test func filtersLeaveOutTheRest() {
        let assigned = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], filter: .assigned)
        #expect(!ids(assigned).contains("gitFetch"))
        #expect(ids(assigned).contains("quickOpen"))
        let changed = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: ["gitFetch"], filter: .changed)
        #expect(ids(changed) == ["gitFetch"])
    }

    @Test func searchLooksPastTheFilter() {
        let found = ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], filter: .changed, query: "fetch")
        #expect(ids(found) == ["gitFetch"])
    }

    @Test func aWordSearchNeedsAllItsWords() {
        #expect(ids(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], query: "git fetch")) == ["gitFetch"])
        #expect(ids(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], query: "git nothing")).isEmpty)
    }

    @Test func aKeyFindsWhatItStarts() throws {
        let k = try #require(KeyStroke(parsing: "cmd+k"))
        #expect(ids(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], keys: [k])) == ["splitDown"])
        let j = try #require(KeyStroke(parsing: "cmd+j"))
        #expect(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], keys: [j]).isEmpty)
    }

    @Test func aKeyCanBeTypedOrPasted() {
        #expect(ids(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], query: "cmd+p")) == ["quickOpen"])
        #expect(ids(ShortcutIndex.sections(commands: commands, bindings: bindings, changed: [], query: "⌘P")).contains("quickOpen"))
    }

    @Test func aPlainWordIsNeverAKey() {
        #expect(ShortcutIndex.strokes(typed: "fetch") == nil)
        #expect(ShortcutIndex.strokes(typed: "cmd+k cmd+i")?.count == 2)
    }

    @Test func holdersAreWhoeverElseHasTheKey() {
        #expect(ShortcutIndex.holders(of: "cmd+b", except: "goBack", in: bindings) == ["toggleSidebar"])
        #expect(ShortcutIndex.holders(of: "cmd+b", except: "toggleSidebar", in: bindings).isEmpty)
        #expect(ShortcutIndex.holders(of: "cmd+j", except: "goBack", in: bindings).isEmpty)
        // Two commands can share a key by default, and both would lose it.
        #expect(Set(ShortcutIndex.holders(of: "cmd+enter", except: "goBack", in: bindings)) == ["promotePeek", "insertLineBelow"])
    }

    @Test func changedCountsAnUnboundDefault() {
        let changed = ShortcutIndex.changedCommands(user: [("cmd+b", "-toggleSidebar"), ("cmd+j", "toggleSidebar"), ("cmd+u", "goBack")])
        #expect(changed == ["toggleSidebar", "goBack"])
    }
}
