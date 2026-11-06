import Darwin
import Foundation
import Testing
@testable import TiriCore

@Suite struct SafeWriteTests {
    private func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("safewrite-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func inode(_ path: String) -> (ino: UInt64, links: UInt16) {
        var info = stat()
        _ = stat(path, &info)
        return (info.st_ino, info.st_nlink)
    }

    @Test func aSymlinkStaysALinkAndItsTargetChanges() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "old".write(toFile: dir + "/AGENTS.md", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/CLAUDE.md", withDestinationPath: "AGENTS.md")
        try SafeWrite.write(Data("new".utf8), to: dir + "/CLAUDE.md")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/CLAUDE.md") == "AGENTS.md")
        #expect(text(dir + "/AGENTS.md") == "new")
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["AGENTS.md", "CLAUDE.md"])
    }

    @Test func aChainOfLinksInAnotherFolderIsFollowed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try "old".write(toFile: dir + "/real/file.txt", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/second", withDestinationPath: dir + "/real/file.txt")
        try FileManager.default.createSymbolicLink(atPath: dir + "/first", withDestinationPath: "second")
        #expect(try SafeWrite.write(Data("new".utf8), to: dir + "/first") == .atomic)
        #expect(text(dir + "/real/file.txt") == "new")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/first") == "second")
    }

    @Test func aHardLinkStaysLinked() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "old".write(toFile: dir + "/a.txt", atomically: false, encoding: .utf8)
        try FileManager.default.linkItem(atPath: dir + "/a.txt", toPath: dir + "/b.txt")
        let before = inode(dir + "/a.txt")
        #expect(try SafeWrite.write(Data("newer and longer".utf8), to: dir + "/a.txt") == .inPlace)
        #expect(text(dir + "/b.txt") == "newer and longer")
        #expect(inode(dir + "/a.txt").ino == before.ino)
        #expect(inode(dir + "/a.txt").links == 2)
        try SafeWrite.write(Data("s".utf8), to: dir + "/b.txt")
        #expect(text(dir + "/a.txt") == "s")
    }

    @Test func extendedAttributesAndModeAreKept() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/script.sh"
        try "echo old".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(chmod(path, 0o751) == 0)
        let value = Array("kept".utf8)
        #expect(setxattr(path, "build.tiri.test", value, value.count, 0, 0) == 0)
        let before = inode(path)
        #expect(try SafeWrite.write(Data("echo new".utf8), to: path) == .atomic)
        #expect(text(path) == "echo new")
        // Replaced by rename, so a new file, carrying the old one's metadata.
        #expect(inode(path).ino != before.ino)
        var info = stat()
        _ = stat(path, &info)
        #expect(info.st_mode & 0o7777 == 0o751)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = getxattr(path, "build.tiri.test", &buffer, buffer.count, 0, 0)
        #expect(count == value.count)
        #expect(Array(buffer.prefix(max(count, 0))) == value)
        // And its time is now, not the old file's.
        #expect(Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < 60)
    }

    @Test func aWritableFileInAReadOnlyFolderSaves() throws {
        let dir = try folder()
        defer {
            chmod(dir, 0o755)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let path = dir + "/notes.txt"
        try "old".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(chmod(dir, 0o555) == 0)
        #expect(try SafeWrite.write(Data("new".utf8), to: path) == .inPlace)
        #expect(text(path) == "new")
        // Shorter than before, and nothing of the old is left at the end.
        try SafeWrite.write(Data("n".utf8), to: path)
        #expect(text(path) == "n")
    }

    @Test func aNewFileIsCreatedAndAReadOnlyOneRefused() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try SafeWrite.write(Data("hello".utf8), to: dir + "/new.txt") == .created)
        #expect(text(dir + "/new.txt") == "hello")
        let locked = dir + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try "old".write(toFile: locked + "/file.txt", atomically: false, encoding: .utf8)
        chmod(locked + "/file.txt", 0o444)
        chmod(locked, 0o555)
        defer { chmod(locked, 0o755) }
        #expect(throws: CocoaError.self) { try SafeWrite.write(Data("new".utf8), to: locked + "/file.txt") }
        #expect(text(locked + "/file.txt") == "old")
    }
}

@Suite struct PathCaseTests {
    @Test func spelledAsOnDiskBelowTheFolderAsGiven() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathcase-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Sources/App", withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/Sources/App/ReadMe.md", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/Link.md", withDestinationPath: "Sources/App/ReadMe.md")
        #expect(PathCase.onDisk(dir + "/sources/app/readme.MD", below: dir) == dir + "/Sources/App/ReadMe.md")
        // A link keeps its own name rather than becoming its target's.
        #expect(PathCase.onDisk(dir + "/link.md", below: dir) == dir + "/Link.md")
        // What isn't there yet stays as typed, below the part that is.
        #expect(PathCase.onDisk(dir + "/sources/New/file.md", below: dir) == dir + "/Sources/New/file.md")
        #expect(PathCase.onDisk("/elsewhere/a", below: dir) == "/elsewhere/a")
        #expect(PathCase.onDisk(dir, below: dir) == dir)
    }
}
