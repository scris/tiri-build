import Foundation
import Testing
@testable import TiriCore

struct ThemeTests {
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-themes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func colors() {
        #expect(ThemeColor("#fff")?.hex == "#ffffff")
        #expect(ThemeColor("1d1f21")?.hex == "#1d1f21")
        #expect(ThemeColor("#878b9180")?.hex == "#878b9180")
        #expect(ThemeColor("#12345") == nil)
        #expect(ThemeColor("red") == nil)
        #expect((ThemeColor("#000")!.contrast(with: .white) - 21).magnitude < 0.01)
    }

    @Test func ghostty() throws {
        let text = """
        # Dracula
        palette = 0=#21222c
        palette = 1=#ff5555
        palette = 2 = #50fa7b
        palette = 3=#f1fa8c
        palette = 4=#bd93f9
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#f8f8f2
        palette = 8=#6272a4
        background = #282a36
        foreground = f8f8f2
        cursor-color = #f8f8f2
        selection-background = #44475a
        """
        let theme = try ThemeImport.ghostty(text, name: "Dracula")
        #expect(theme.terminal.background == "#282a36")
        #expect(theme.terminal.ansi[2] == "#50fa7b")
        #expect(theme.terminal.selection == "#44475a")
        // The editor takes the palette's colors.
        #expect(theme.editor.string == "#50fa7b")
        #expect(theme.editor.keyword == "#ff79c6")
        #expect(theme.editor.comment == "#6272a4")
        #expect(theme.isDark)
        #expect(throws: ThemeImport.Failure.self) { try ThemeImport.ghostty("font-size = 13", name: "x") }
    }

    @Test func eightColorsMakeSixteen() throws {
        let text = (0..<8).map { "palette = \($0)=#0\($0)0\($0)0\($0)" }.joined(separator: "\n") + "\nbackground = #ffffff"
        let theme = try ThemeImport.ghostty(text, name: "Eight")
        #expect(theme.terminal.ansi[9] == theme.terminal.ansi[1])
        #expect(!theme.isDark)
    }

    @Test func commentsStayReadable() throws {
        // Solarized's bright black is nearly its background.
        let theme = try ThemeImport.ghostty("background = #002b36\nforeground = #839496\npalette = 8=#002b36", name: "Solarized")
        #expect(ThemeColor(theme.editor.comment)!.contrast(with: ThemeColor("#002b36")!) > 2)
    }

    @Test func iTerm() throws {
        func entry(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": "sRGB"]
        }
        var plist: [String: Any] = ["Background Color": entry(0, 0, 0), "Foreground Color": entry(1, 1, 1), "Cursor Color": entry(1, 0, 0)]
        for index in 0..<16 { plist["Ansi \(index) Color"] = entry(Double(index) / 15, 0.5, 0.25) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let file = temporary().appendingPathComponent("Test.itermcolors")
        try data.write(to: file)
        let theme = try ThemeImport.read(file: file)
        #expect(theme.name == "Test")
        #expect(theme.source == "iTerm2")
        #expect(theme.terminal.background == "#000000")
        #expect(theme.terminal.cursor == "#ff0000")
        #expect(theme.terminal.ansi[15] == "#ff8040")
    }

    @Test func vsCode() throws {
        let folder = temporary()
        // A parent with terminal colors, and a child with comments and trailing commas, as real ones are written.
        try #"""
        { "type": "dark", "colors": { "terminal.ansiRed": "#cd3131", "editor.background": "#000000" },
          "tokenColors": [ { "scope": "comment", "settings": { "foreground": "#6A9955" } } ] }
        """#.write(to: folder.appendingPathComponent("parent.json"), atomically: true, encoding: .utf8)
        try #"""
        {
          // Monokai, more or less
          "name": "Child",
          "include": "./parent.json",
          "colors": { "editor.background": "#272822", "editor.foreground": "#f8f8f2", /* the text */ },
          "tokenColors": [
            { "scope": ["keyword", "storage"], "settings": { "foreground": "#F92672" } },
            { "scope": "keyword.operator", "settings": { "foreground": "#ffffff" } },
            { "scope": "string, string.quoted", "settings": { "foreground": "#E6DB74" } },
            { "scope": "meta.embedded string", "settings": { "foreground": "#000001" } },
            { "scope": "entity.name.function", "settings": { "foreground": "#A6E22E" } },
          ],
        }
        """#.write(to: folder.appendingPathComponent("child.json"), atomically: true, encoding: .utf8)
        let theme = try ThemeImport.read(file: folder.appendingPathComponent("child.json"))
        #expect(theme.name == "Child")
        #expect(theme.editor.background == "#272822")
        #expect(theme.editor.keyword == "#f92672")
        #expect(theme.editor.string == "#e6db74")
        #expect(theme.editor.function == "#a6e22e")
        #expect(theme.editor.comment == "#6a9955")
        #expect(theme.terminal.ansi[1] == "#cd3131")
        #expect(theme.terminal.background == "#272822")
        #expect(theme.isDark)
    }

    @Test func mostSpecificRuleWins() {
        let rules = [ThemeImport.TokenRule(selectors: ["keyword"], foreground: "#111111"),
                     ThemeImport.TokenRule(selectors: ["keyword.control"], foreground: "#222222"),
                     ThemeImport.TokenRule(selectors: ["keyword"], foreground: "#333333")]
        #expect(ThemeImport.match(["keyword.control.flow"], in: rules) == "#222222")
        #expect(ThemeImport.match(["keyword.other"], in: rules) == "#333333")
        #expect(ThemeImport.match(["string"], in: rules) == nil)
    }

    @Test func setByName() {
        var theme = Theme.tiriDark
        #expect(theme.set("terminal.brightRed", to: "#FF0000") == nil)
        #expect(theme.terminal.ansi[9] == "#ff0000")
        #expect(theme.set("editor.comment", to: "abc") == nil)
        #expect(theme.editor.comment == "#aabbcc")
        #expect(theme.set("terminal.4", to: "#000") == nil)
        #expect(theme.terminal.ansi[4] == "#000000")
        #expect(theme.set("accent", to: "pink") == nil && theme.accent == .pink)
        #expect(theme.set("accent", to: "mac") == nil && theme.accent == nil)
        #expect(theme.set("editor.sparkle", to: "#000") != nil)
        #expect(theme.set("editor.comment", to: "blue") != nil)
        #expect(Theme.colorKeys.count == 4 + 16 + 11)
        #expect(Theme.colorKeys.allSatisfy { theme[$0] != nil })
    }

    @Test func slots() {
        #expect(ThemeSlot.current(dark: true, increaseContrast: false) == .dark)
        #expect(ThemeSlot.current(dark: false, increaseContrast: true) == .highContrastLight)
        #expect(ThemeSlot.natural(for: .tiriPinkLight) == .light)
        #expect(ThemeSlot.natural(for: .tiriHighContrastDark) == .highContrastDark)
        #expect(Theme.tiriPinkDark.accent == .pink && Theme.tiriDark.accent == nil)
        #expect(Set(Theme.builtIns.map(\.name)).count == Theme.builtIns.count)
    }

    @Test func library() throws {
        let library = ThemeLibrary(directory: temporary())
        var theme = Theme.tiriDark
        theme.name = "Night Owl"
        try library.save(theme)
        #expect(library.all().map(\.name) == ["Night Owl"])
        #expect(library.theme(named: "night owl")?.name == "Night Owl")
        #expect(library.theme(named: "Tiri Pink Dark")?.accent == .pink)
        #expect(library.freeName(for: "Night Owl") == "Night Owl 2")
        #expect(library.freeName(for: "Tiri Dark") == "Tiri Dark 2")
        try library.delete(named: "Night Owl")
        #expect(library.all().isEmpty)
    }

    /// Cursor's own themes, where Cursor is installed: every one must read, with code colors that differ.
    @Test func cursorsThemes() throws {
        let found = ThemeDiscovery.available().filter { $0.from == "Cursor" && $0.path.hasPrefix("/Applications") }
        guard !found.isEmpty else { return }
        #expect(found.contains { $0.name == "Monokai" })
        #expect(!found.contains { $0.name.hasPrefix("%") })
        for theme in found {
            let read = try ThemeImport.read(file: URL(fileURLWithPath: theme.path))
            #expect(read.editor.keyword != read.editor.string, "\(theme.name)")
            if let dark = theme.dark { #expect(read.isDark == dark || theme.name.contains("Contrast"), "\(theme.name)") }
        }
    }

    @Test func stripsJSONC() throws {
        let plain = ThemeImport.stripJSONC(#"{ "a": "http://x // not a comment", /* gone */ "b": [1, 2,], }"#)
        let object = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any]
        #expect(object?["a"] as? String == "http://x // not a comment")
        #expect((object?["b"] as? [Int]) == [1, 2])
    }
}
