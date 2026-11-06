import Foundation
import Testing
@testable import TiriCore

@Suite struct UnsavedEditsTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("unsaved-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func keepsReadsAndDrops() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let edit = UnsavedEdit(path: "/w/a.txt", text: "typed", onDisk: "on disk")
        try UnsavedEdits.write(edit, for: "i-abc", in: folder)
        #expect(UnsavedEdits.read("i-abc", in: folder) == edit)
        #expect(UnsavedEdits.all(in: folder) == ["i-abc"])
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("i-abc.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        UnsavedEdits.remove("i-abc", in: folder)
        #expect(UnsavedEdits.read("i-abc", in: folder) == nil)
        #expect(UnsavedEdits.all(in: folder).isEmpty)
    }

    @Test func knowsWhenTheFileChangedUnderIt() {
        let edit = UnsavedEdit(path: "/w/a.txt", text: "typed", onDisk: "on disk")
        #expect(!edit.diskChanged(now: "on disk"))
        #expect(edit.diskChanged(now: "an agent wrote this"))
    }

    @Test func onlyPlainIDsMakeFileNames() throws {
        let folder = folder().appendingPathComponent("inner", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try UnsavedEdits.write(UnsavedEdit(path: "/x", text: "t", onDisk: ""), for: "../escape", in: folder)
        #expect(UnsavedEdits.read("../escape", in: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escape.json").path))
    }
}
