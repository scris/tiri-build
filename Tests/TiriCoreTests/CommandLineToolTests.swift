import Foundation
import Testing
@testable import TiriCore

@Suite struct ShellLookupTests {
    @Test func onlyMarkedLinesCount() {
        let output = "Welcome back!\nnvm: tiri-found:fake\ntiri-found:claude\n\ntiri-found:codex\n"
        #expect(ShellLookup.found(in: output) == ["claude", "codex"])
    }

    @Test func scriptLeavesOutAnythingThatIsntAName() {
        let script = ShellLookup.script(for: ["claude", "rm -rf x", "a;b", "$(boom)"])
        #expect(script.contains("command -v claude "))
        #expect(!script.contains("rm"))
        #expect(!script.contains("boom"))
        #expect(!script.contains("a;b"))
    }

    private func emptyZsh() throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ["ZDOTDIR": directory.path, "HOME": directory.path, "PATH": "/usr/bin:/bin"]
    }

    @Test func asksARealShell() async throws {
        let found = await ShellLookup.run(names: ["ls", "tiri-no-such-tool"], shell: "/bin/zsh", environment: try emptyZsh())
        #expect(found == ["ls"])
    }

    @Test func seesAnAliasFromTheShellsSetup() async throws {
        let environment = try emptyZsh()
        try "alias tiri-test-agent=ls\n".write(toFile: environment["ZDOTDIR"]! + "/.zshrc", atomically: true, encoding: .utf8)
        let found = await ShellLookup.run(names: ["tiri-test-agent"], shell: "/bin/zsh", environment: environment)
        #expect(found == ["tiri-test-agent"])
    }

    @Test func aHungShellIsUnknownRatherThanMissing() async throws {
        let environment = try emptyZsh()
        try "sleep 30\n".write(toFile: environment["ZDOTDIR"]! + "/.zshrc", atomically: true, encoding: .utf8)
        let found = await ShellLookup.run(names: ["ls"], shell: "/bin/zsh", environment: environment, timeout: 0.5)
        #expect(found == nil)
    }
}

@Suite struct CommandLineToolTests {
    private func place() throws -> (link: URL, bundled: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Tiri.app/Contents/Resources/bin/tiri")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "tool".write(to: bundled, atomically: true, encoding: .utf8)
        return (root.appendingPathComponent("home/.local/bin/tiri"), bundled)
    }

    @Test func installAndRemove() throws {
        let (link, bundled) = try place()
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .notInstalled)
        try CommandLineTool.install(link: link, bundled: bundled)
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .installed)
        #expect(try String(contentsOf: link, encoding: .utf8) == "tool")
        try CommandLineTool.remove(link: link)
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: bundled.path))
    }

    @Test func aMovedAppLeavesAStaleLinkThatInstallRepairs() throws {
        let (link, bundled) = try place()
        let moved = bundled.deletingLastPathComponent().appendingPathComponent("moved")
        try CommandLineTool.install(link: link, bundled: moved)
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .stale)
        try CommandLineTool.install(link: link, bundled: bundled)
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .installed)
    }

    @Test func removeLeavesAnotherFileAlone() throws {
        let (link, bundled) = try place()
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "someone else's".write(to: link, atomically: true, encoding: .utf8)
        #expect(CommandLineTool.state(link: link, bundled: bundled) == .otherFile)
        try CommandLineTool.remove(link: link)
        #expect(try String(contentsOf: link, encoding: .utf8) == "someone else's")
    }

    @Test func refusesPlacesThatWontLast() {
        #expect(CommandLineTool.problem(appPath: "/Applications/Tiri.app") == nil)
        #expect(CommandLineTool.problem(appPath: "/Volumes/Tiri/Tiri.app") != nil)
        #expect(CommandLineTool.problem(appPath: "/private/var/folders/x/AppTranslocation/y/d/Tiri.app") != nil)
    }
}

@Suite struct ShellPathTests {
    @Test func readsThePathFromTheShellsSetup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "export PATH=\"/custom/with space:$PATH\"\necho noise\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let path = await ShellLookup.path(shell: "/bin/zsh", environment: ["ZDOTDIR": directory.path, "HOME": directory.path, "PATH": "/usr/bin:/bin"])
        #expect(path?.hasPrefix("/custom/with space:") == true)
    }
}
