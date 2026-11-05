import Foundation
import Testing
@testable import TiriCore

@Suite struct CompiledPDFTests {
    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "tiri-pdf-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path + "/paper", withIntermediateDirectories: true)
        return path
    }

    private func touch(_ path: String, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
    }

    @Test func nothingBuiltYet() throws {
        let root = try folder()
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == nil)
    }

    @Test func findsOneBesideIt() throws {
        let root = try folder()
        try touch(root + "/paper/main.pdf")
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == root + "/paper/main.pdf")
    }

    @Test(arguments: ["build", "out", "output", "_build"])
    func findsOneInABuildFolder(build: String) throws {
        let root = try folder()
        try touch(root + "/paper/\(build)/main.pdf")
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == root + "/paper/\(build)/main.pdf")
    }

    @Test func findsOneInASiblingBuildFolder() throws {
        let root = try folder()
        try touch(root + "/build/main.pdf")
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == root + "/build/main.pdf")
    }

    @Test func prefersTheNewest() throws {
        let root = try folder()
        try touch(root + "/paper/main.pdf", age: 100)
        try touch(root + "/paper/build/main.pdf")
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == root + "/paper/build/main.pdf")
    }

    @Test func anotherNameIsntIt() throws {
        let root = try folder()
        try touch(root + "/paper/other.pdf")
        #expect(CompiledPDF.find(forTex: root + "/paper/main.tex") == nil)
    }

    @Test func latexFamilyUsesTheLatexGrammar() {
        #expect(FileClassifier.language(path: "a.sty") == "latex")
        #expect(FileClassifier.language(path: "a.tex") == "latex")
    }
}
