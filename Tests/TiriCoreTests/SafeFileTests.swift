import Foundation
import Testing
@testable import TiriCore

@Suite(.serialized) struct SafeFileTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-safefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    private func isLink(_ url: URL) -> Bool {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & S_IFMT == S_IFLNK
    }

    @Test func aLinkStaysALinkAndTheFileKeepsItsMode() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotfiles = root.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: target)
        chmod(target.path, 0o600)
        let link = root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")

        try SafeFile.replace(link, with: Data("new".utf8))
        #expect(isLink(link))
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(mode(target) == 0o600)

        chmod(target.path, 0o640)
        try SafeFile.replace(link, with: Data("again".utf8))
        #expect(mode(target) == 0o640)
        // Nothing left over beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dotfiles.path) == ["settings.json"])
    }

    @Test func aNewFileIsPrivate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("new.json")
        try SafeFile.replace(file, with: Data("x".utf8))
        #expect(mode(file) == 0o600)
        chmod(file.path, 0o644)
        try SafeFile.replace(file, with: Data("y".utf8), forcing: 0o600)
        #expect(mode(file) == 0o600)
    }

    @Test func withoutFollowingLinksTheLinkIsReplaced() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere")
        try Data("keep".utf8).write(to: elsewhere)
        let lock = root.appendingPathComponent("1.lock")
        try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: elsewhere.path)
        try SafeFile.replace(lock, with: Data("token".utf8), forcing: 0o600, followingLinks: false)
        #expect(!isLink(lock))
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "keep")
    }

    @Test func onlyTheFirstCopyIsKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("settings.json.tiri-backup")
        #expect(try SafeFile.keepFirstCopy(Data("original".utf8), at: backup))
        #expect(mode(backup) == 0o600 && !isLink(backup))
        #expect(try !SafeFile.keepFirstCopy(Data("with hooks".utf8), at: backup))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
        // A link where the copy would go isn't written through.
        let trap = root.appendingPathComponent("trap")
        let linked = root.appendingPathComponent("other.tiri-backup")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: trap.path)
        #expect(try !SafeFile.keepFirstCopy(Data("x".utf8), at: linked))
        #expect(!FileManager.default.fileExists(atPath: trap.path))
    }

    @Test func onlyAMissingFileReadsAsNothing() throws {
        let root = try scratch()
        defer {
            chmod(root.appendingPathComponent("locked").path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try SafeFile.readText(root.appendingPathComponent("missing")) == nil)
        let bad = root.appendingPathComponent("bad")
        try Data([0x7B, 0xFF, 0xFE, 0x7D]).write(to: bad)
        #expect(throws: SafeFile.Failure.self) { try SafeFile.readText(bad) }
        let locked = root.appendingPathComponent("locked")
        try Data("{}".utf8).write(to: locked)
        chmod(locked.path, 0o000)
        #expect(throws: (any Error).self) { try SafeFile.readText(locked) }
        #expect(throws: (any Error).self) { try SafeFile.readText(root) }
        let good = root.appendingPathComponent("good")
        try Data("é\r\n".utf8).write(to: good)
        #expect(try SafeFile.readText(good) == "é\r\n")
    }

    @Test func privateDirectories() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("a/ide")
        try SafeFile.makePrivateDirectory(fresh)
        #expect(mode(fresh) == 0o700)
        let open = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        chmod(open.path, 0o755)
        try SafeFile.makePrivateDirectory(open)
        #expect(mode(open) == 0o700)
    }

    /// The server's script, run here by the shells a server is likely to have.
    @Test(arguments: ["/bin/sh", "/bin/dash", "/bin/bash"], [false, true])
    func theRemoteScriptKeepsLinksAndModes(shell: String, withoutReadlinkF: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        try manager.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        let target = home.appendingPathComponent("dotfiles/settings.json")
        try Data("old".utf8).write(to: target)
        chmod(target.path, 0o640)
        let link = home.appendingPathComponent(".claude/settings.json")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/settings.json")

        var path = "/usr/bin:/bin"
        if withoutReadlinkF {
            // A server whose readlink has no -f.
            let bin = home.appendingPathComponent("bin")
            try manager.createDirectory(at: bin, withIntermediateDirectories: true)
            let fake = bin.appendingPathComponent("readlink")
            try Data("#!/bin/sh\n[ \"$1\" = -f ] && exit 1\nexec /usr/bin/readlink \"$@\"\n".utf8).write(to: fake)
            chmod(fake.path, 0o755)
            path = bin.path + ":" + path
        }
        func run(_ input: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", SafeFile.remoteReplaceScript(homeRelativePath: ".claude/settings.json")]
            process.environment = ["HOME": home.path, "PATH": path]
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run("new") == 0)
        #expect(isLink(link))
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(mode(target) == 0o640)
        let backup = home.appendingPathComponent(".claude/settings.json.tiri-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
        #expect(mode(backup) == 0o600 && !isLink(backup))
        #expect(try run("newer") == 0)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
        #expect(try manager.contentsOfDirectory(atPath: home.appendingPathComponent("dotfiles").path) == ["settings.json"])

        // No file yet: one is made, private.
        try manager.removeItem(at: link)
        try manager.removeItem(at: backup)
        #expect(try run("fresh") == 0)
        #expect(mode(link) == 0o600 && !isLink(link))
        #expect(!manager.fileExists(atPath: backup.path))
    }
}
