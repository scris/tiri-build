import Foundation
import Testing
@testable import TiriCore

@Suite struct PluginPackageTests {
    private final class Place {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("package-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func plugin(_ name: String = "demo", version: String = "1.2.0", at folder: String? = nil) throws -> URL {
            let top = root.appendingPathComponent(folder ?? name, isDirectory: true)
            try FileManager.default.createDirectory(at: top.appendingPathComponent(".tiri-plugin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: top.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try """
            { "name": "\(name)", "version": "\(version)", "apiVersion": 1, "tiri": ">=0.1.0",
              "commands": [{ "id": "hi", "title": "Hi", "exec": ["bin/hi"] }] }
            """.write(to: PluginManifest.url(in: top), atomically: true, encoding: .utf8)
            let program = top.appendingPathComponent("bin/hi")
            try "#!/bin/sh\necho hi\n".write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            return top
        }

        func zip(_ file: String, _ names: [String], in directory: URL? = nil) throws -> URL {
            let out = root.appendingPathComponent(file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            // zip adds its own extension unless it's told the name is final.
            process.arguments = ["-q", "-r", "-y", "-X", out.path + ".zip"] + names
            process.currentDirectoryURL = directory ?? root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if !file.hasSuffix(".zip") { try FileManager.default.moveItem(atPath: out.path + ".zip", toPath: out.path) } else {
                try FileManager.default.moveItem(atPath: out.path + ".zip", toPath: out.path)
            }
            return out
        }
    }

    private func message(_ work: () throws -> Void) -> String {
        do {
            try work()
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test func aRoundTripGivesBackTheSamePlugin() throws {
        let place = try Place()
        let source = try place.plugin()
        try "secret".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "big".write(to: source.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("bin/also").path, withDestinationPath: "hi")

        let file = place.root.appendingPathComponent("out/demo.tiriplugin")
        let exported = try PluginPackage.export(source, to: file)
        #expect(exported.name == "demo")
        #expect(exported.leftOut == [".env"])
        #expect(exported.text.contains(".env"))

        let opened = try PluginPackage.open(file)
        defer { opened.discard() }
        #expect(opened.name == "demo")
        #expect(opened.version == "1.2.0")

        let parent = place.root.appendingPathComponent("installed", isDirectory: true)
        #expect(try PluginTools.install(opened, into: parent).hasPrefix("Installed demo 1.2.0"))
        let arrived = parent.appendingPathComponent("demo")
        let manager = FileManager.default
        #expect(manager.isExecutableFile(atPath: arrived.appendingPathComponent("bin/hi").path))
        #expect(try manager.destinationOfSymbolicLink(atPath: arrived.appendingPathComponent("bin/also").path) == "hi")
        #expect(!manager.fileExists(atPath: arrived.appendingPathComponent(".env").path))
        #expect(!manager.fileExists(atPath: arrived.appendingPathComponent("node_modules").path))
        // What's approved on one Mac is exactly what arrives on another.
        #expect(PluginTree.treeHash(PluginTree.hashes(arrived, listing: PluginTree.list(arrived))) == opened.hash)
    }

    @Test func anInvalidPluginIsntExported() throws {
        let place = try Place()
        let source = try place.plugin()
        try FileManager.default.removeItem(at: source.appendingPathComponent("bin/hi"))
        let file = place.root.appendingPathComponent("demo.tiriplugin")
        #expect(message { _ = try PluginPackage.export(source, to: file) }.contains("errors"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aChangedFileIsNoticed() throws {
        let place = try Place()
        let file = place.root.appendingPathComponent("demo.tiriplugin")
        _ = try PluginPackage.export(try place.plugin(), to: file)
        let inside = place.root.appendingPathComponent("inside", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", file.path, "-d", inside.path]
        try unzip.run()
        unzip.waitUntilExit()
        try "#!/bin/sh\ncurl evil\n".write(to: inside.appendingPathComponent("plugin/bin/hi"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inside.appendingPathComponent("plugin/bin/hi").path)
        let changed = try place.zip("changed.tiriplugin", ["tiri-package.json", "plugin"], in: inside)
        #expect(message { _ = try PluginPackage.open(changed) }.contains("changed after it was exported"))
    }

    @Test func aNewerFormatSaysSo() throws {
        let place = try Place()
        let inside = place.root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try #"{"format": 99}"#.write(to: inside.appendingPathComponent("tiri-package.json"), atomically: true, encoding: .utf8)
        let newer = try place.zip("newer.tiriplugin", ["tiri-package.json"], in: inside)
        #expect(message { _ = try PluginPackage.open(newer) }.contains("newer Tiri"))
    }

    @Test func whatIsntAPluginIsRefusedInWords() throws {
        let place = try Place()
        let text = place.root.appendingPathComponent("notes.tiriplugin")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        #expect(message { _ = try PluginPackage.open(text) }.contains("won't open"))

        let folder = place.root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(message { _ = try PluginPackage.open(folder) }.contains("isn't a plugin"))

        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let noHeader = try place.zip("bare.tiriplugin", ["a.txt"], in: folder)
        #expect(message { _ = try PluginPackage.open(noHeader) }.contains("isn't a Tiri plugin"))
        let noPlugin = try place.zip("bare.zip", ["a.txt"], in: folder)
        #expect(message { _ = try PluginPackage.open(noPlugin) }.contains("no Tiri plugin"))
        #expect(message { _ = try PluginPackage.open(place.root.appendingPathComponent("gone.tiriplugin")) }.contains("nothing at"))
    }

    @Test func aDownloadedZipWorks() throws {
        let place = try Place()
        _ = try place.plugin("from-github", at: "from-github-main")
        let zip = try place.zip("download.zip", ["from-github-main"])
        let opened = try PluginPackage.open(zip)
        defer { opened.discard() }
        #expect(opened.name == "from-github")
    }

    @Test func twoPluginsInAZipAreSaidToBeTwo() throws {
        let place = try Place()
        _ = try place.plugin("one")
        _ = try place.plugin("two")
        let zip = try place.zip("both.zip", ["one", "two"])
        #expect(message { _ = try PluginPackage.open(zip) }.contains("holds 2 plugins"))
    }

    @Test func aLinkOutOfThePluginIsRefused() throws {
        let place = try Place()
        let source = try place.plugin()
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("bin/keys").path, withDestinationPath: "/etc/hosts")
        let zip = try place.zip("links.zip", ["demo"])
        #expect(message { _ = try PluginPackage.open(zip) }.contains("errors"))
    }

    @Test func aBadNameCantLandElsewhere() throws {
        let place = try Place()
        _ = try place.plugin("../../evil", at: "escape")
        let zip = try place.zip("escape.zip", ["escape"])
        #expect(message { _ = try PluginPackage.open(zip) }.contains("errors"))
    }

    @Test func replacingSaysSo() throws {
        let place = try Place()
        let parent = place.root.appendingPathComponent("installed", isDirectory: true)
        let first = try PluginPackage.open(try place.plugin())
        _ = try PluginTools.install(first, into: parent)
        let next = try PluginPackage.open(try place.plugin(version: "1.3.0"))
        #expect(try PluginTools.install(next, into: parent).hasPrefix("Replaced demo 1.3.0"))
        #expect(try PluginManifest.load(from: parent.appendingPathComponent("demo")).version == "1.3.0")
    }
}
