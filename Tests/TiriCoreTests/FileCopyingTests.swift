import Foundation
import Testing
@testable import TiriCore

@Suite struct FileCopyingTests {
    @Test func aTakenNameGetsCopyAsFinderDoes() {
        let taken: Set<String> = ["report.pdf", "report copy.pdf", "Makefile", ".env", "src"]
        #expect(FileCopying.freeName(for: "notes.md") { taken.contains($0) } == "notes.md")
        #expect(FileCopying.freeName(for: "report.pdf") { taken.contains($0) } == "report copy 2.pdf")
        #expect(FileCopying.freeName(for: "Makefile") { taken.contains($0) } == "Makefile copy")
        #expect(FileCopying.freeName(for: ".env") { taken.contains($0) } == ".env copy")
        #expect(FileCopying.freeName(for: "src") { taken.contains($0) } == "src copy")
        // A copy of a copy counts on.
        #expect(FileCopying.freeName(for: "report copy.pdf") { taken.contains($0) } == "report copy 2.pdf")
        let more: Set<String> = ["a copy 2.txt", "a copy 3.txt"]
        #expect(FileCopying.freeName(for: "a copy 2.txt") { more.contains($0) } == "a copy 4.txt")
    }

    @Test func copiesFilesAndFoldersIntoAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-copy-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let from = root + "/from", to = root + "/project/src"
        try FileManager.default.createDirectory(atPath: from + "/assets", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
        try "a".write(toFile: from + "/logo.svg", atomically: true, encoding: .utf8)
        try "b".write(toFile: from + "/assets/icon.png", atomically: true, encoding: .utf8)
        try "old".write(toFile: to + "/logo.svg", atomically: true, encoding: .utf8)

        let result = FileCopying.copy([from + "/logo.svg", from + "/assets"], into: to)
        #expect(result.problems.isEmpty)
        #expect(result.copied == [to + "/logo copy.svg", to + "/assets"])
        #expect(try String(contentsOfFile: to + "/logo.svg", encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: to + "/assets/icon.png", encoding: .utf8) == "b")
        // The originals stay where they were.
        #expect(FileManager.default.fileExists(atPath: from + "/logo.svg"))
    }

    @Test func aFolderCantGoInsideItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-copy-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        let result = FileCopying.copy([root + "/a"], into: root + "/a/b")
        #expect(result.copied.isEmpty)
        #expect(result.problems == [.intoItself("a")])
        // Into the folder it's already in, it's a copy beside it.
        #expect(FileCopying.copy([root + "/a/b"], into: root + "/a").copied == [root + "/a/b copy"])
    }
}
