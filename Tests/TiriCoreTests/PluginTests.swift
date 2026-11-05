import Foundation
import Testing
@testable import TiriCore

/// These change what's process-wide (the catalog, and the environment for where plugins live).
@Suite(.serialized)
struct PluginTests {
    private func makeFolder(_ manifest: String, files: [String: String] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(PluginManifest.folderName), withIntermediateDirectories: true)
        try manifest.write(to: PluginManifest.url(in: folder), atomically: true, encoding: .utf8)
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if path.hasPrefix("bin/") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return folder
    }

    private func issues(_ manifest: String, files: [String: String] = [:]) throws -> [String] {
        let folder = try makeFolder(manifest, files: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        return PluginValidator.validate(try PluginManifest.load(from: folder), folder: folder).filter { $0.severity == .error }.map(\.message)
    }

    private let base = #""name": "demo", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0""#

    // MARK: The guide

    @Test func theGuidesExampleIsAManifestThisBuildReads() throws {
        let manifest = try PluginManifest.decode(Data(PluginGuide.exampleManifest.utf8))
        #expect(manifest.name == "leetcode")
        #expect(manifest.commands?.count == 5)
        #expect(manifest.panels?.first?.allow?.network == ["https://leetcode.com"])
        #expect(manifest.additions.contains("1 panel"))
        #expect(PluginGuide.markdown.contains(manifest.commands?.first?.title ?? "missing"))
    }

    @Test func aManifestSaysWhatItDoesBeforeAnythingRuns() throws {
        let manifest = try PluginManifest.decode(Data(PluginGuide.exampleManifest.utf8))
        #expect(manifest.programs.contains("bin/lc submit ${file}"))
        #expect(manifest.programs.contains("bin/server"))
        #expect(manifest.networkAddresses == ["https://leetcode.com"])
        #expect(manifest.runsPrograms)
    }

    // MARK: Validating

    @Test func aMinimalPluginIsFine() throws {
        #expect(try issues("{\(base)}").isEmpty)
    }

    @Test func aBadNameOrVersionIsCaught() throws {
        #expect(try issues(#"{"name": "Bad Name", "version": "1.0.0", "apiVersion": 1}"#).contains { $0.contains("lowercase") })
        #expect(try issues(#"{"name": "ok", "version": "soon", "apiVersion": 1}"#).contains { $0.contains("version") })
    }

    @Test func anotherAPIOrTiriVersionIsCaught() throws {
        #expect(try issues(#"{"name": "ok", "version": "1.0.0", "apiVersion": 99}"#).contains { $0.contains("plugin API 99") })
        #expect(try issues(#"{"name": "ok", "version": "1.0.0", "apiVersion": 1, "tiri": ">=99"}"#).contains { $0.contains("needs Tiri") })
        #expect(try issues(#"{"name": "ok", "version": "1.0.0", "apiVersion": 1, "tiri": "soon"}"#).contains { $0.contains("version range") })
    }

    @Test func aCommandDoesOneThing() throws {
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A"}]}"#).contains { $0.contains("should do one thing") })
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "ask": "x", "panel": "p"}], "panels": []}"#).contains { $0.contains("should do one thing") })
        #expect(try issues(#"{\#(base), "commands": [{"id": "a b", "title": "A", "ask": "x"}]}"#).contains { $0.contains("should be letters") })
        #expect(try issues(#"{\#(base), "commands": [{"id": "a", "title": "A", "ask": "x"}, {"id": "a", "title": "B", "ask": "y"}]}"#).contains { $0.contains("two commands") })
    }

    @Test func programsAreCheckedAndCantLeave() throws {
        let missing = #"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/nope"]}]}"#
        #expect(try issues(missing).contains { $0.contains("doesn't exist") })
        let outside = #"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["../../bin/sh"]}]}"#
        #expect(try issues(outside).contains { $0.contains("outside the plugin") })
        let notExecutable = #"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["tools/x"]}]}"#
        #expect(try issues(notExecutable, files: ["tools/x": "#!/bin/sh\n"]).contains { $0.contains("isn't executable") })
        let good = #"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["bin/x"]}, {"id": "b", "title": "B", "exec": ["git", "status"]}]}"#
        #expect(try issues(good, files: ["bin/x": "#!/bin/sh\n"]).isEmpty)
    }

    @Test func aLinkLeavingThePluginIsCaught() throws {
        let folder = try makeFolder("{\(base)}")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("inside").path, withDestinationPath: PluginManifest.folderName)
        let found = PluginValidator.validate(try PluginManifest.load(from: folder), folder: folder).map(\.message)
        #expect(found.contains { $0.contains("escape is a link") })
        #expect(!found.contains { $0.contains("inside is a link") })
    }

    @Test func aPanelsScriptsLiveInFiles() throws {
        let manifest = #"{\#(base), "panels": [{"id": "p", "title": "P", "entry": "p.html"}]}"#
        #expect(try issues(manifest, files: ["p.html": "<script>alert(1)</script>"]).contains { $0.contains("script inside the page") })
        #expect(try issues(manifest, files: ["p.html": "<script src=\"p.js\"></script>"]).isEmpty)
        #expect(try issues(manifest).contains { $0.contains("doesn't exist") })
    }

    @Test func aPanelsAddressesAreOrigins() throws {
        func manifest(_ address: String) -> String { #"{\#(base), "panels": [{"id": "p", "title": "P", "entry": "p.html", "allow": {"network": ["\#(address)"]}}]}"# }
        let page = ["p.html": "<p>"]
        #expect(try issues(manifest("https://example.com"), files: page).isEmpty)
        #expect(try issues(manifest("https://*.example.com"), files: page).isEmpty)
        #expect(try issues(manifest("http://localhost:3000"), files: page).isEmpty)
        for bad in ["*", "example.com", "file:///etc", "https://exa mple.com", "https://example.com; script-src *", "https://example.com/path", "https://*"] {
            #expect(try issues(manifest(bad), files: page).contains { $0.contains("isn't an address") }, "\(bad)")
        }
    }

    @Test func dependenciesNeedALockfile() throws {
        let package = #"{"dependencies": {"left-pad": "1.0.0"}}"#
        #expect(try issues("{\(base)}", files: ["package.json": package]).contains { $0.contains("package-lock.json") })
        #expect(try issues("{\(base)}", files: ["package.json": package, "package-lock.json": "{}"]).isEmpty)
    }

    @Test func aGrammarHasToBeWhatItSays() throws {
        let manifest = #"{\#(base), "grammars": [{"scope": "source.demo", "path": "g.json"}], "languages": [{"id": "demo", "extensions": ["demo"], "grammar": "source.demo"}]}"#
        #expect(try issues(manifest, files: ["g.json": #"{"scopeName": "source.demo", "patterns": []}"#]).isEmpty)
        #expect(try issues(manifest, files: ["g.json": #"{"scopeName": "source.other"}"#]).contains { $0.contains("says its scope") })
        #expect(try issues(manifest, files: ["g.json": "nonsense"]).contains { $0.contains("isn't a JSON") })
        let unknown = #"{\#(base), "languages": [{"id": "demo", "extensions": ["demo"], "grammar": "source.nothing"}]}"#
        #expect(try issues(unknown).contains { $0.contains("neither this plugin nor Tiri") })
        let dotted = #"{\#(base), "languages": [{"id": "demo", "extensions": [".demo"]}]}"#
        #expect(try issues(dotted).contains { $0.contains("without its dot") })
    }

    @Test func nothingDeclaredCanLiveWhereItWouldntBeHashed() throws {
        let program = #"{\#(base), "commands": [{"id": "a", "title": "A", "exec": ["node_modules/.bin/x"]}]}"#
        #expect(try issues(program, files: ["node_modules/.bin/x": "#!/bin/sh\n"]).contains { $0.contains("isn't part of what's approved") })
        let page = #"{\#(base), "panels": [{"id": "p", "title": "P", "entry": ".venv/p.html"}]}"#
        #expect(try issues(page, files: [".venv/p.html": "<p>"]).contains { $0.contains("isn't part of what's approved") })
        let part = #"{\#(base), "agent": {"claude": ".git/hooks"}}"#
        #expect(try issues(part, files: [".git/hooks/x": ""]).contains { $0.contains("isn't part of what's approved") })
    }

    @Test func aValueCantBeQuotedByHand() throws {
        func manifest(_ line: String) -> String { #"{\#(base), "commands": [{"id": "a", "title": "A", "terminal": "\#(line)"}]}"# }
        #expect(try issues(manifest(#"git log \"${file}\""#)).contains { $0.contains("inside quotes") })
        #expect(try issues(manifest(#"git log '${file}'"#)).contains { $0.contains("inside quotes") })
        #expect(try issues(manifest(#"git log ${file} 'other'"#)).isEmpty)
        #expect(PluginTemplate.hasQuotedValue(#"x "${a}""#))
        #expect(!PluginTemplate.hasQuotedValue(#"x ${a} "$HOME" 'y'"#))
    }

    @Test func nothingAgentsOrTerminalsTakeAsKeysGetsThrough() {
        #expect(PluginTemplate.plain("ok\u{1B}[201~\rrm -rf\u{03}\u{7F}\u{9B}") == "ok[201~rm -rf")
        #expect(PluginTemplate.plain("two\nlines\tand 中文") == "two\nlines\tand 中文")
    }

    @Test func anAddressIsShownAsWhatItGrants() throws {
        #expect(PluginNetwork.source("https://github.com@evil.example") == nil)
        #expect(PluginNetwork.source("https://user:pass@evil.example") == nil)
        var manifest = PluginManifest(name: "x", version: "1.0.0")
        manifest.panels = [.init(id: "p", title: "P", entry: "p.html", symbol: nil, allow: .init(network: ["HTTPS://Example.com/", "https://github.com@evil.example"], commands: nil, processes: nil, agent: nil, openFiles: nil))]
        #expect(manifest.networkAddresses == ["https://Example.com"])
    }

    @Test func aPersonIsToldWhatAViewerAndAnAgentGet() {
        var manifest = PluginManifest(name: "x", version: "1.0.0")
        manifest.viewers = [.init(panel: "p", patterns: ["*"], priority: nil, writes: true)]
        var command = PluginManifest.Command(id: "a", title: "A")
        command.ask = "Run this for me"
        manifest.commands = [command]
        let said = manifest.panelPowers.joined(separator: " ")
        #expect(said.contains("read and change * files"))
        #expect(said.contains("Run this for me"))
    }

    @Test func dependenciesAreWatchedWithoutBeingHashed() throws {
        let folder = try makeFolder("{\(base)}")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(PluginTree.dependencyFingerprint(folder) == "")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "one".write(to: folder.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        let first = PluginTree.dependencyFingerprint(folder)
        #expect(first != "")
        try "other".write(to: folder.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        #expect(PluginTree.dependencyFingerprint(folder) != first)
    }

    @Test func foldersDeeperDownAreStillPartOfIt() throws {
        let folder = try makeFolder("{\(base)}", files: ["panel/__pycache__/x.js": "a", "lib/node_modules/y.js": "b", "lib/.DS_Store": "c"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let listed = PluginTree.list(folder).stats.keys
        #expect(listed.contains("panel/__pycache__/x.js"))
        #expect(listed.contains("lib/node_modules/y.js"))
        #expect(!listed.contains("lib/.DS_Store"))
    }

    @Test func aPipeIsRefusedAndNeverRead() throws {
        let folder = try makeFolder("{\(base)}")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(mkfifo(folder.appendingPathComponent("trap").path, 0o644) == 0)
        // This would hang forever if it read it.
        _ = PluginTree.hashes(folder, listing: PluginTree.list(folder))
        #expect(PluginValidator.validate(try PluginManifest.load(from: folder), folder: folder).contains { $0.message.contains("isn't a regular file") })
    }

    @Test func aRefreshCantBeTooOften() throws {
        let manifest = #"{\#(base), "statusBar": [{"id": "s", "provider": {"exec": ["date"]}, "refresh": {"every": 1}}]}"#
        #expect(try issues(manifest).contains { $0.contains("30 is the shortest") })
    }

    @Test func aDecodeFailureNamesTheField() throws {
        do {
            _ = try PluginManifest.decode(Data(#"{"name": "x", "apiVersion": 1}"#.utf8))
            Issue.record("should have failed")
        } catch {
            #expect(PluginManifest.explain(error).contains("version"))
        }
        do {
            _ = try PluginManifest.decode(Data(#"{"name": "x", "version": "1", "apiVersion": 1, "commands": [{"id": 3, "title": "x"}]}"#.utf8))
            Issue.record("should have failed")
        } catch {
            #expect(PluginManifest.explain(error).contains("commands"))
        }
    }

    // MARK: Small parts

    @Test func versionRanges() {
        #expect(PluginVersionRange.contains("0.1.0", range: ">=0.1.0 <2") == true)
        #expect(PluginVersionRange.contains("2.0.0", range: ">=0.1.0 <2") == false)
        #expect(PluginVersionRange.contains("1.2", range: "=1.2.0") == true)
        #expect(PluginVersionRange.contains("1.10.0", range: ">1.9") == true)
        #expect(PluginVersionRange.contains("1.0.0", range: "~1") == nil)
        #expect(PluginVersionRange.contains("1.0.0", range: "") == nil)
    }

    @Test func filePatterns() {
        #expect(PluginPattern.matches("*.csv", path: "/a/b/data.CSV"))
        #expect(!PluginPattern.matches("*.csv", path: "/a/b/data.csv.bak"))
        #expect(PluginPattern.matches("Cargo.toml", path: "/a/Cargo.toml"))
        #expect(PluginPattern.matches("src/**/*.rs", path: "/p/src/a/b/c.rs"))
        #expect(PluginPattern.matches("src/**/*.rs", path: "/p/src/c.rs"))
        #expect(!PluginPattern.matches("src/*.rs", path: "/p/src/a/c.rs"))
        #expect(PluginPattern.matches("**/leetcode/*.py", path: "/h/leetcode/1.py"))
        #expect(!PluginPattern.matches("*.py", path: "/a/py"))
        #expect(PluginPattern.matches("data?.txt", path: "/a/data1.txt"))
    }

    @Test func fillingInKeepsValuesWhole() {
        let context = PluginContext(plugin: "/p", file: "/a b/it's.py", folder: "/a b", line: 3, args: ["id": .int(12), "name": "x"])
        #expect(PluginTemplate.fill("${plugin}/bin/x ${args.id} ${line}", context) == "/p/bin/x 12 3")
        #expect(PluginTemplate.fill("cat ${file}", context, quoting: ShellQuote.quote) == #"cat '/a b/it'\''s.py'"#)
        #expect(PluginTemplate.fill("${nothing}-${args.missing}-${unclosed", context) == "---${unclosed".replacingOccurrences(of: "---", with: "--"))
    }

    @Test func aCommandCantBeInjectedThroughAValue() {
        let context = PluginContext(plugin: "/p", args: ["x": "; rm -rf ~ #"])
        #expect(PluginTemplate.fill("bin/go ${args.x}", context, quoting: ShellQuote.quote) == "bin/go '; rm -rf ~ #'")
    }

    @Test func contentPolicyOnlyReachesWhatsDeclared() {
        let policy = PluginNetwork.contentPolicy(allowing: ["https://a.example", "not an address", "https://b.example; script-src *"], scheme: "tiri-plugin")
        #expect(policy.contains("connect-src tiri-plugin: https://a.example"))
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("script-src tiri-plugin:;"))
        #expect(!policy.contains("b.example"))
        #expect(!policy.contains("not an address"))
        #expect(!policy.contains("unsafe-eval"))
    }

    @Test func resolvingStaysInside() throws {
        let folder = try makeFolder("{\(base)}", files: ["a/b.txt": "x"])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(PluginValidator.resolve("a/b.txt", in: folder) != nil)
        #expect(PluginValidator.resolve("a/../a/b.txt", in: folder) != nil)
        #expect(PluginValidator.resolve("../other", in: folder) == nil)
        #expect(PluginValidator.resolve("a/../../other", in: folder) == nil)
        #expect(PluginValidator.resolve("/etc/passwd", in: folder) == nil)
        #expect(PluginValidator.resolve("~/x", in: folder) == nil)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("out").path, withDestinationPath: "/etc")
        #expect(PluginValidator.resolve("out/passwd", in: folder) == nil)
    }

    @Test func treeItemsAreBounded() {
        let value = JSONValue.object(["items": .array((0..<20).map { .object(["id": .int($0), "title": .string("t\($0)"), "children": .array([.object(["title": "c"])])]) })])
        let all = PluginTreeItem.list(from: value)
        #expect(all.count == 20)
        #expect(all[3].title == "t3")
        #expect(all[3].children.first?.title == "c")
        #expect(PluginTreeItem.list(from: value, limit: 5).count < 6)
        #expect(PluginTreeItem.list(from: .array([.object(["nope": "x"]), .object(["title": "kept"])])).map(\.title) == ["kept"])
        // Same ids don't make SwiftUI confuse two rows.
        let twins = PluginTreeItem.list(from: .array([.object(["id": "a", "title": "1"]), .object(["id": "a", "title": "2"])]))
        #expect(twins[0].id != twins[1].id)
    }

    @Test func aStatusNeedsText() {
        #expect(PluginStatusContent(.object(["text": "5", "symbol": "flame", "args": .object(["x": 1])]))?.args["x"] == 1)
        #expect(PluginStatusContent(.object(["symbol": "flame"])) == nil)
    }

    // MARK: Hashing and approval

    @Test func anyChangeChangesTheHash() throws {
        let folder = try makeFolder("{\(base)}", files: ["bin/x": "#!/bin/sh\n", "panel/a.html": "<p>"])
        defer { try? FileManager.default.removeItem(at: folder) }
        func hash() -> String { PluginTree.treeHash(PluginTree.hashes(folder, listing: PluginTree.list(folder))) }
        let first = hash()
        #expect(hash() == first)
        try "<p>changed".write(to: folder.appendingPathComponent("panel/a.html"), atomically: true, encoding: .utf8)
        let second = hash()
        #expect(second != first)
        // Being executable counts too: that's what decides whether it runs.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent("bin/x").path)
        let third = hash()
        #expect(third != second)
        try "new".write(to: folder.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        #expect(hash() != third)
    }

    @Test func whatsRebuiltIsntPartOfTheHash() throws {
        let folder = try makeFolder("{\(base)}")
        defer { try? FileManager.default.removeItem(at: folder) }
        func hash() -> String { PluginTree.treeHash(PluginTree.hashes(folder, listing: PluginTree.list(folder))) }
        let first = hash()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        try ".".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        #expect(hash() == first)
    }

    @Test func changesSayWhatChanged() {
        let changes = PluginChanges(from: ["a": "1", "b": "2", "gone": "3"], to: ["a": "1", "b": "9", "new": "4"])
        #expect(changes.changed == ["b"])
        #expect(changes.added == ["new"])
        #expect(changes.removed == ["gone"])
        #expect(changes.summary.contains("Changed: b"))
    }

    /// Everything about turning on, against a real folder and real files.
    @Test func nothingIsOnUntilApprovedAndAnyChangeTurnsItOff() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        setenv("TIRI_HOME", home.appendingPathComponent("home").path, 1)
        setenv("TIRI_CONFIG_HOME", home.appendingPathComponent("config").path, 1)
        defer {
            unsetenv("TIRI_HOME")
            unsetenv("TIRI_CONFIG_HOME")
        }
        let outcome = PluginTools.run(.new(name: "demo", folder: nil), cwd: "/")
        #expect(outcome.code == 0, "\(outcome.errors)")

        var found = try #require(PluginLibrary.scan().first)
        #expect(found.name == "demo")
        #expect(found.state == .off)
        #expect(!found.isOn)

        PluginLibrary.approve(found)
        found = try #require(PluginLibrary.scan().first)
        #expect(found.isOn)

        // An edit, of any kind, and it's no longer what was approved.
        try "changed\n".write(to: found.folder.appendingPathComponent("panel/panel.css"), atomically: true, encoding: .utf8)
        found = try #require(PluginLibrary.scan().first)
        guard case .changed(let changes) = found.state else {
            Issue.record("should have stopped, and it's \(found.state)")
            return
        }
        #expect(changes.changed == ["panel/panel.css"])

        PluginLibrary.approve(found)
        #expect(try #require(PluginLibrary.scan().first).isOn)
        PluginLibrary.turnOff("demo")
        #expect(try #require(PluginLibrary.scan().first).state == .off)
        PluginLibrary.forget("demo")
        #expect(PluginLibrary.approvals().isEmpty)
    }

    @Test func aFolderMustMatchItsName() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        setenv("TIRI_HOME", home.appendingPathComponent("home").path, 1)
        setenv("TIRI_CONFIG_HOME", home.appendingPathComponent("config").path, 1)
        defer {
            unsetenv("TIRI_HOME")
            unsetenv("TIRI_CONFIG_HOME")
        }
        #expect(PluginTools.run(.new(name: "real", folder: nil), cwd: "/").code == 0)
        try FileManager.default.moveItem(at: PluginLibrary.folder.appendingPathComponent("real"), to: PluginLibrary.folder.appendingPathComponent("other"))
        let found = try #require(PluginLibrary.scan().first)
        guard case .broken(let why) = found.state else {
            Issue.record("should be broken")
            return
        }
        #expect(why.contains("its folder is other"))

        // A stray copy can't take a real plugin's name away from it.
        #expect(PluginTools.run(.new(name: "real", folder: nil), cwd: "/").code == 0)
        let all = PluginLibrary.scan()
        #expect(all.first { $0.name == "real" }?.state == .off)
    }

    // MARK: Languages

    @Test func aPluginsLanguageComesAndGoesCleanly() {
        let path = "/p/thing.tiridemo"
        #expect(LanguageCatalog.language(forPath: path) == nil)
        #expect(!LanguageCatalog.isCertainlyText(path: path))
        let count = LanguageCatalog.all.count
        let added = LanguageDefinition(id: "tiridemo", name: "Tiri Demo", grammar: nil, extensions: ["tiridemo"], fileNames: ["tiridemofile"], interpreters: ["tiridemo"],
                                       aliases: ["td"], comment: CommentSyntax(line: "!!"), isCertainlyText: true)
        LanguageCatalog.setPluginLanguages([added])
        #expect(LanguageCatalog.language(forPath: path)?.name == "Tiri Demo")
        #expect(LanguageCatalog.language(forPath: "/p/tiridemofile")?.id == "tiridemo")
        #expect(LanguageCatalog.language(forPath: "/p/x", firstLine: "#!/usr/bin/env tiridemo")?.id == "tiridemo")
        #expect(LanguageCatalog.language(named: "td")?.id == "tiridemo")
        #expect(LanguageCatalog.isCertainlyText(path: path))
        #expect(CommentSyntax.forFile(path)?.line == "!!")
        #expect(FileClassifier.classify(path: path) == .text)
        #expect(LanguageCatalog.all.count == count + 1)
        LanguageCatalog.setPluginLanguages([])
        #expect(LanguageCatalog.language(forPath: path) == nil)
        #expect(LanguageCatalog.language(named: "td") == nil)
        #expect(!LanguageCatalog.isCertainlyText(path: path))
        #expect(LanguageCatalog.all.count == count)
    }

    @Test func aPluginCanAddToALanguageAndTakeOverAnExtension() {
        let before = LanguageCatalog.language(id: "rust")
        LanguageCatalog.setPluginLanguages([
            LanguageDefinition(id: "rust", name: "", grammar: nil, extensions: ["rsx"], fileNames: [], interpreters: [], aliases: [], comment: nil),
            LanguageDefinition(id: "mine", name: "Mine", grammar: nil, extensions: ["py"], fileNames: [], interpreters: [], aliases: [], comment: nil),
        ])
        #expect(LanguageCatalog.language(forPath: "/a.rsx")?.id == "rust")
        #expect(LanguageCatalog.language(id: "rust")?.grammar == before?.grammar)
        #expect(LanguageCatalog.language(id: "rust")?.name == before?.name)
        // You turned it on, so it wins over what Tiri would have said.
        #expect(LanguageCatalog.language(forPath: "/a.py")?.id == "mine")
        LanguageCatalog.setPluginLanguages([])
        #expect(LanguageCatalog.language(forPath: "/a.py")?.id == "python")
    }

    @Test func aPluginsServerIsFound() throws {
        let folder = try makeFolder(#"{\#(base), "languages": [{"id": "tiridemo2", "name": "Demo", "extensions": ["tiridemo2"], "server": {"commands": [["bin/serve", "--stdio"], ["demo-lsp"]], "rootMarkers": ["demo.toml"], "languageID": "demolang"}}]}"#,
                                    files: ["bin/serve": "#!/bin/sh\n"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = try PluginManifest.load(from: folder)
        let plugin = InstalledPlugin(name: "demo", folder: folder, manifest: manifest, issues: [], hash: "", files: [:], state: .on)
        LanguageCatalog.setPluginLanguages(PluginLibrary.languages(of: plugin))
        LanguageServerCatalog.setPluginServers(PluginLibrary.servers(of: plugin))
        defer {
            LanguageCatalog.setPluginLanguages([])
            LanguageServerCatalog.setPluginServers([])
        }
        let server = try #require(LanguageServerCatalog.definition(for: "/p/a.tiridemo2"))
        #expect(server.id == "demo.tiridemo2")
        #expect(server.commands[0][0] == folder.appendingPathComponent("bin/serve").path)
        #expect(server.commands[1] == ["demo-lsp"])
        #expect(server.languageID(for: "/p/a.tiridemo2") == "demolang")
    }

    @Test func grammarsComeAsJSONOrPropertyLists() throws {
        let folder = try makeFolder("{\(base)}")
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("a.json")
        try #"{"scopeName": "source.a"}"#.write(to: json, atomically: true, encoding: .utf8)
        let plist = folder.appendingPathComponent("b.tmLanguage")
        try #"<?xml version="1.0"?><plist version="1.0"><dict><key>scopeName</key><string>source.b</string></dict></plist>"#.write(to: plist, atomically: true, encoding: .utf8)
        PluginGrammars.set([.init(scope: "source.a", file: json, injectTo: []), .init(scope: "source.b", file: plist, injectTo: [])])
        defer { PluginGrammars.set([]) }
        #expect(PluginGrammars.json(scope: "source.a")?.contains("source.a") == true)
        #expect(PluginGrammars.json(scope: "source.b")?.contains("source.b") == true)
        #expect(PluginGrammars.json(scope: "source.c") == nil)
    }

    // MARK: Settings

    @Test func settingsKeepTheirOwnStore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        setenv("TIRI_CONFIG_HOME", home.path, 1)
        defer { unsetenv("TIRI_CONFIG_HOME") }
        let name = "settingstest-\(UUID().uuidString.prefix(6).lowercased())"
        var manifest = PluginManifest(name: name, version: "1.0.0")
        manifest.settings = [
            .init(key: "lang", title: "Language", explanation: "x", type: .choice, options: [.init(value: "py", label: "Python"), .init(value: "swift", label: nil)], min: nil, max: nil, step: nil, placeholder: nil, default: "py"),
            .init(key: "on", title: "On", explanation: nil, type: .toggle, options: nil, min: nil, max: nil, step: nil, placeholder: nil, default: nil),
        ]
        SettingsSchema.setPluginDefinitions(SettingsSchema.definitions(for: manifest))
        defer { SettingsSchema.setPluginDefinitions([]) }
        let key = SettingsSchema.pluginKey(name, "lang")
        let definition = try #require(SettingsSchema.definition(for: key))
        #expect(definition.value(TiriSettings()) == "py")
        #expect(throws: SettingsSchema.InvalidValue.self) { _ = try SettingsSchema.value(from: "cobol", for: key) }
        #expect(try SettingsSchema.value(from: "swift", for: key) == "swift")
        PluginSettingsStore.set(name, key: "lang", to: "swift")
        #expect(definition.value(TiriSettings()) == "swift")
        #expect(PluginSettingsStore.resolved(manifest)["lang"] == "swift")
        #expect(PluginSettingsStore.resolved(manifest)["on"] == .null)
        #expect(SettingsSchema.splitPluginKey(key)?.key == "lang")
        #expect(SettingsSchema.everything.count == SettingsSchema.all.count + 2)
        // Plugins can't touch Tiri's own settings by naming them.
        #expect(SettingsSchema.definition(for: "theme") != nil)
        #expect(SettingsSchema.splitPluginKey("theme") == nil)
        PluginSettingsStore.remove(name)
        #expect(definition.value(TiriSettings()) == "py")
    }

    // MARK: Keys

    @Test func aPluginCantTakeAKeyThatsTaken() {
        let taken = Keymap.build(user: [], plugins: [("cmd+p", "demo.mine"), ("cmd+alt+y", "demo.free"), ("cmd+alt+y", "other.late")])
        #expect(taken.first { $0.strokes == Keymap.parseStrokes("cmd+p") }?.command == "quickOpen")
        #expect(taken.first { $0.strokes == Keymap.parseStrokes("cmd+alt+y") }?.command == "demo.free")
        #expect(!taken.contains { $0.command == "other.late" })
        // A key that's only a letter would stop typing from working.
        #expect(!Keymap.build(user: [], plugins: [("x", "demo.typing")]).contains { $0.command == "demo.typing" })
        // And you still decide.
        let yours = Keymap.build(user: [("cmd+alt+y", "splitDown")], plugins: [("cmd+alt+y", "demo.free")])
        #expect(yours.first { $0.strokes == Keymap.parseStrokes("cmd+alt+y") }?.command == "splitDown")
    }

    // MARK: The CLI

    private let environment = CLIParser.Environment(cwd: "/tmp", itemID: nil, fileExists: { _ in false }, readStdin: { Data() })

    private func parse(_ words: String...) throws -> CLIParser.Parsed { try CLIParser.parse(words, environment: environment) }

    /// Requests each have an id of their own, so it's what they ask that gets compared.
    private func asked(_ parsed: CLIParser.Parsed) -> (cmd: String, args: [String: JSONValue])? {
        if case .request(let request, _) = parsed { return (request.cmd, request.args) }
        return nil
    }

    @Test func theCLIReadsPluginCommands() throws {
        #expect(asked(try parse("plugin"))?.cmd == "plugin.list")
        #expect(asked(try parse("plugin", "enable", "x"))?.cmd == "plugin.enable")
        #expect(asked(try parse("plugin", "enable", "x"))?.args == ["name": "x"])
        #expect(try parse("plugin", "validate", "x") == .local(.validate("x")))
        #expect(try parse("plugin", "new", "x", "--dir", "/d") == .local(.new(name: "x", folder: "/d")))
        #expect(try parse("plugin", "verify", "--tests") == .local(.verify(name: nil, runTests: true)))
        #expect(try parse("plugin", "import", "a.vsix") == .local(.importFile(file: "a.vsix", folder: nil)))
        #expect(try parse("plugin", "install", "a.tiriplugin") == .local(.importFile(file: "a.tiriplugin", folder: nil)))
        #expect(try parse("plugin", "export", "x") == .local(.export(target: "x", to: nil)))
        #expect(try parse("plugin", "export", "x", "--to", "/d") == .local(.export(target: "x", to: "/d")))
        #expect(asked(try parse("plugin", "post", "x.main", "hi", "{\"a\":1}"))?.args == ["name": "x.main", "event": "hi", "data": .object(["a": 1])])
        #expect(throws: CLIParser.UsageError.self) { try parse("plugin", "nonsense") }
        #expect(throws: CLIParser.UsageError.self) { try parse("plugin", "update", "x", "sidebar", "id", "not json") }
        if case .printText(let text) = try parse("plugin", "api") { #expect(text.contains("Writing a Tiri plugin")) } else { Issue.record("api prints") }
    }

    @Test func theCLIPassesArgumentsToACommand() throws {
        #expect(asked(try parse("run", "splitRight"))?.args == ["command": "splitRight"])
        #expect(asked(try parse("run", "x.open", "id=12", "name=a=b"))?.args == ["command": "x.open", "args": .object(["id": "12", "name": "a=b"])])
        #expect(throws: CLIParser.UsageError.self) { try parse("run", "x.open", "loose") }
        #expect(throws: CLIParser.UsageError.self) { try parse("run") }
    }

    @Test func aNewPluginValidatesAndItsTestsPass() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-new-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(PluginTools.run(.new(name: "my-thing", folder: parent.path), cwd: "/").code == 0)
        let folder = parent.appendingPathComponent("my-thing").path
        let checked = PluginTools.run(.validate(folder), cwd: "/")
        #expect(checked.code == 0, "\(checked.output)")
        #expect(checked.output.contains("2 commands, 1 panel"))
        #expect(checked.output.contains("bin/hello"))
        let tested = PluginTools.run(.test(folder), cwd: "/")
        #expect(tested.code == 0, "\(tested.output)")
        #expect(tested.output.contains("hello works"))
        #expect(PluginTools.run(.new(name: "my-thing", folder: parent.path), cwd: "/").code != 0)
        #expect(PluginTools.run(.new(name: "Bad Name", folder: parent.path), cwd: "/").code == 2)
    }

    // MARK: Importing

    private func makeVSIX(_ files: [String: String]) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-vsix-src-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let archive = scratch.appendingPathComponent("out.vsix")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "extension"]
        zip.currentDirectoryURL = scratch
        try zip.run()
        zip.waitUntilExit()
        return archive
    }

    @Test func anExtensionsLanguagesComeAcrossAndTheRestIsListed() throws {
        let package = #"""
        {
          // VS Code's own files can have comments.
          "name": "demo-lang", "displayName": "Demo Lang", "version": "2.3.4", "main": "./out/extension.js",
          "contributes": {
            "languages": [{"id": "demolang", "aliases": ["Demo Lang", "dl"], "extensions": [".dl", ".dlang"], "filenames": ["Demofile"], "configuration": "./lang.json", "firstLine": "^#!"}],
            "grammars": [{"language": "demolang", "scopeName": "source.dl", "path": "./syntaxes/dl.tmLanguage"},
                         {"scopeName": "source.dl.inject", "path": "./syntaxes/inject.json", "injectTo": ["source.dl"]},
                         {"scopeName": "source.gone", "path": "./syntaxes/missing.json"}],
            "commands": [{"command": "a"}, {"command": "b"}],
            "snippets": [{"language": "demolang", "path": "./s.json"}]
          },
          "extensionDependencies": ["other.thing"]
        }
        """#
        let plist = #"<?xml version="1.0"?><plist version="1.0"><dict><key>scopeName</key><string>source.dl</string><key>patterns</key><array/></dict></plist>"#
        let archive = try makeVSIX([
            "extension/package.json": package,
            "extension/lang.json": #"{ "comments": { "lineComment": "//", "blockComment": ["/*", "*/"] }, /* a comment */ "brackets": [] }"#,
            "extension/syntaxes/dl.tmLanguage": plist,
            "extension/syntaxes/inject.json": #"{"scopeName": "source.dl.inject", "patterns": []}"#,
            "extension/LICENSE.txt": "MIT",
            "extension/out/extension.js": "evil()",
        ])
        let parent = archive.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let report = try VSIXImporter.importFile(archive.path, into: parent)
        #expect(report.name == "demo-lang")
        #expect(report.languages == ["demolang"])
        #expect(report.grammars == ["source.dl", "source.dl.inject"])
        #expect(report.dropped.contains { $0.contains("source.gone") })
        #expect(report.dropped.contains { $0.contains("contributes.commands: 2") })
        #expect(report.dropped.contains { $0.contains("contributes.snippets: 1") })
        #expect(report.dropped.contains { $0.contains("firstLine") })
        #expect(report.dropped.contains { $0.contains("./out/extension.js") })
        #expect(report.dropped.contains { $0.contains("other.thing") })

        let folder = parent.appendingPathComponent("demo-lang")
        let manifest = try PluginManifest.load(from: folder)
        #expect(manifest.title == "Demo Lang")
        #expect(manifest.version == "2.3.4")
        #expect(manifest.commands == nil)
        let language = try #require(manifest.languages?.first)
        #expect(language.extensions == ["dl", "dlang"])
        #expect(language.fileNames == ["Demofile"])
        #expect(language.comment?.line == "//")
        #expect(language.comment?.block == ["/*", "*/"])
        #expect(language.grammar == "source.dl")
        #expect(manifest.grammars?.first { $0.scope == "source.dl.inject" }?.injectTo == ["source.dl"])
        // None of its code came with it, its licence did, and what it left behind is written down.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out/extension.js").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("LICENSE.txt").path))
        #expect(try String(contentsOf: folder.appendingPathComponent("IMPORT-REPORT.md"), encoding: .utf8).contains("contributes.commands"))
        // A property list became JSON, and all of it validates.
        #expect(PluginValidator.validate(manifest, folder: folder).filter { $0.severity == .error }.isEmpty)
        #expect(!manifest.runsPrograms)
        #expect(throws: VSIXImporter.Failure.self) { _ = try VSIXImporter.importFile(archive.path, into: parent) }
    }

    @Test func anExtensionCantClimbOut() throws {
        let archive = try makeVSIX(["extension/package.json": #"{"name": "x", "contributes": {"grammars": [{"scopeName": "source.x", "path": "../../../../../etc/hosts"}], "languages": [{"id": "x", "extensions": [".x"], "configuration": "../../../etc/hosts"}]}}"#])
        let parent = archive.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let report = try VSIXImporter.importFile(archive.path, into: parent)
        #expect(report.grammars.isEmpty)
        #expect(report.dropped.contains { $0.contains("source.x") })
    }

    @Test func somethingThatIsntAnExtensionSaysSo() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-notvsix-\(UUID().uuidString)")
        try "nope".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(throws: VSIXImporter.Failure.self) { _ = try VSIXImporter.importFile(scratch.path, into: scratch.deletingLastPathComponent()) }
        #expect(throws: VSIXImporter.Failure.self) { _ = try VSIXImporter.importFile("/nonexistent.vsix", into: scratch.deletingLastPathComponent()) }
    }

    // MARK: Items

    @Test func aPanelSurvivesARelaunch() throws {
        let item = Item(content: .plugin(PluginPanelSpec(plugin: "x", panel: "p", title: "Problem", args: ["id": 12])))
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(Item.self, from: data)
        #expect(back == item)
        #expect(back.content.kindName == "plugin")
        #expect(back.defaultTitle == "Problem")
    }

    @Test func aFileRemembersItsViewerAndOldFilesStillLoad() throws {
        let old = #"{"path": "/a.csv"}"#
        #expect(try JSONDecoder().decode(FileSpec.self, from: Data(old.utf8)).viewer == nil)
        let spec = FileSpec(path: "/a.csv", viewer: "plot.main")
        #expect(try JSONDecoder().decode(FileSpec.self, from: JSONEncoder().encode(spec)).viewer == "plot.main")
    }
}
