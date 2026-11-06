import CryptoKit
import Foundation
import Testing
@testable import TiriCore

@Suite struct RemoteOutputStartTests {
    private let marker = RemoteShell.outputMarker

    @Test func dropsWhatTheShellPrintedFirst() {
        let (out, noise) = RemoteOutputStart.strip(Data("hi from bashrc\n\(marker)real".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "real")
        #expect(noise)
    }

    @Test func aQuietShellIsntNoise() {
        let (out, noise) = RemoteOutputStart.strip(Data("\(marker)real\n".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "real\n")
        #expect(!noise)
    }

    @Test func findsAMarkerSplitAcrossChunks() {
        var start = RemoteOutputStart()
        let whole = Data("noise\(marker)body".utf8)
        var out = Data()
        for byte in whole { out.append(start.feed(Data([byte]))) }
        out.append(start.finish())
        #expect(String(decoding: out, as: UTF8.self) == "body")
        #expect(start.noise)
    }

    @Test func withoutAMarkerEverythingStays() {
        let (out, noise) = RemoteOutputStart.strip(Data("plain".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "plain")
        #expect(!noise)
    }

    /// A login shell that echoes, then the wrapped script, the way sshd runs it.
    @Test func noisyLoginShellLeavesFilesAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-noise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.txt")
        try Data("line one\nline two\n".utf8).write(to: source)
        let wrapped = RemoteShell.wrap("head -c 100 -- \(ShellQuote.quote(source.path))", marked: true)
        // runProcess gives a pipe 2 seconds to drain after the process ends, which a whole test run
        // starving the thread pool can miss. That's not what this is about, so it asks again.
        func run(_ command: String, file: URL? = nil) -> RemoteResult? {
            for _ in 0..<5 {
                let result = RemoteConnection.runProcess(executable: "/bin/sh", arguments: ["-c", command], timeout: 10, outputFile: file, marked: true)
                if file != nil || result?.output.isEmpty == false { return result }
            }
            return nil
        }
        let piped = try #require(run("echo hi; printf 'no newline'; " + wrapped))
        #expect(piped.text == "line one\nline two\n")
        #expect(piped.noise)
        let file = folder.appendingPathComponent("fetched")
        let written = try #require(run("echo hi; " + wrapped, file: file))
        #expect(written.succeeded && written.noise)
        #expect(try String(contentsOf: file, encoding: .utf8) == "line one\nline two\n")
        let quiet = try #require(run(wrapped))
        #expect(quiet.text == "line one\nline two\n" && !quiet.noise)
    }
}

@Suite struct RemoteSpoolTests {
    /// A spool line, made the way `tiri` makes one: the request says when it was made, and so does the line.
    private func line(_ stamp: Int64, _ argv: [String], item: String?) -> String {
        "\(stamp) \(String(decoding: request(stamp, argv, item: item), as: UTF8.self))\n"
    }

    private func request(_ stamp: Int64, _ argv: [String], item: String?) -> Data {
        var object: [String: Any] = ["argv": argv, "at": stamp]
        if let item { object["item"] = item }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func onlyTheNewestOfEachTerminal() {
        let now: Int64 = 10_000_000
        let body = line(now - 5000, ["hook", "claude"], item: "i-1") + line(now - 1000, ["hook", "claude"], item: "i-1")
            + line(now - 3000, ["notify", "done"], item: "i-2") + line(now - 2000, ["ping"], item: "i-3") + "garbage\n"
        let chosen = RemoteSpool.choose(Data(body.utf8), serverNow: now, lastLive: [:])
        #expect(chosen.count == 2)
        #expect(chosen.compactMap(RemoteSpool.statusItem) == ["i-2", "i-1"])
        #expect(String(decoding: chosen[1], as: UTF8.self).contains("claude"))
    }

    @Test func nothingThatsBeenOvertaken() {
        let now: Int64 = 10_000_000
        let body = line(now - 60_000, ["hook", "claude"], item: "i-1") + line(now - 60_000, ["hook", "claude"], item: "i-2")
        // i-1 reported live after the spooled one was made. i-2 last did before.
        let live: [String: Int64] = ["i-1": now - 30_000, "i-2": now - 120_000]
        #expect(RemoteSpool.choose(Data(body.utf8), serverNow: now, lastLive: live).compactMap(RemoteSpool.statusItem) == ["i-2"])
        // The same report, which got here live after the server gave up waiting for an answer.
        #expect(RemoteSpool.choose(Data(line(now - 500, ["hook", "claude"], item: "i-1").utf8), serverNow: now, lastLive: ["i-1": now - 500]).isEmpty)
        // A few milliseconds after the last live one is news, however close: a tool's report, then the turn's end.
        #expect(RemoteSpool.choose(Data(line(now - 500, ["hook", "claude"], item: "i-1").utf8), serverNow: now, lastLive: ["i-1": now - 520]).count == 1)
    }

    @Test func liveRequestsSayWhenByTheServersClock() {
        let status = RemoteSpool.status(request(1234, ["hook", "claude"], item: "i-9"))
        #expect(status?.item == "i-9" && status?.at == 1234)
        #expect(RemoteSpool.status(request(1, ["open", "x"], item: "i-9")) == nil)
    }

    @Test func aDayOldIsHistory() {
        let now: Int64 = 200_000_000
        let body = line(now - 25 * 3600 * 1000, ["hook", "claude"], item: "i-1")
        #expect(RemoteSpool.choose(Data(body.utf8), serverNow: now, lastLive: [:]).isEmpty)
    }
}

/// The scripts that put the helper on a server, run here against a folder standing in for a home.
@Suite(.serialized) struct RemoteHelperScriptTests {
    private func sh(_ script: String, stdin: Data? = nil) -> RemoteResult {
        RemoteConnection.runProcess(executable: "/bin/sh", arguments: ["-c", script], stdin: stdin, timeout: 20)!
    }

    private func helper(_ version: String) -> Data { Data("#!/bin/sh\n[ \"$1\" = version ] && echo \(version) || sleep \"$1\"\n".utf8) }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func makeHome() throws -> String {
        // Short and real: /private/var, not /var, so `pwd -P` agrees.
        let home = (FileManager.default.temporaryDirectory.path as NSString).resolvingSymlinksInPath + "/th-" + UUID().uuidString.prefix(6)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    @Test func installsIntoItsVersionsFolder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let base = home + "/.tiri", versioned = base + "/bin/v2-linux-x86_64", run = base + "/run"
        #expect(sh(RemoteHelperScripts.check(base: base, versioned: versioned, run: run)).text != "v2\n")
        let binary = helper("v2")
        let upload = sh(RemoteHelperScripts.upload(base: base, versioned: versioned, size: binary.count, sha256: sha(binary)), stdin: binary)
        #expect(upload.text == "v2\n")
        #expect(sh(RemoteHelperScripts.check(base: base, versioned: versioned, run: run)).text == "v2\n")
        _ = sh(RemoteHelperScripts.tidy(versioned: versioned))
        #expect(sh("\(versioned)/tiri version").text == "v2\n")
        #expect(sh("\(base)/bin/tiri version").text == "v2\n")
        #expect(sh("stat -f %Lp \(base) \(run)").text == "700\n700\n")
    }

    @Test func aBadUploadChangesNothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let base = home + "/.tiri", versioned = base + "/bin/v3-linux-x86_64"
        let binary = helper("v3")
        // Cut short, as a dropped connection would.
        let short = sh(RemoteHelperScripts.upload(base: base, versioned: versioned, size: binary.count, sha256: sha(binary)), stdin: binary.prefix(10))
        #expect(!short.succeeded)
        // All there, and not what was meant.
        var wrong = binary
        wrong[wrong.count - 2] = UInt8(ascii: "x")
        let corrupt = sh(RemoteHelperScripts.upload(base: base, versioned: versioned, size: binary.count, sha256: sha(binary)), stdin: wrong)
        #expect(!corrupt.succeeded)
        #expect(!FileManager.default.fileExists(atPath: versioned + "/tiri-remote"))
        let left = try FileManager.default.contentsOfDirectory(atPath: base + "/bin").filter { $0.hasPrefix(".upload-") }
        #expect(left.isEmpty)
    }

    @Test func otherVersionsStayWhileUsedOrRecent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let base = home + "/.tiri", bin = base + "/bin"
        let current = bin + "/v9-linux-x86_64"
        for name in ["v1-linux-x86_64", "v2-linux-x86_64", "v3-linux-x86_64", "v9-linux-x86_64"] {
            try FileManager.default.createDirectory(atPath: bin + "/" + name, withIntermediateDirectories: true)
            try helper(name).write(to: URL(fileURLWithPath: bin + "/" + name + "/tiri-remote"))
            chmod(bin + "/" + name + "/tiri-remote", 0o755)
        }
        try helper("flat").write(to: URL(fileURLWithPath: bin + "/tiri-remote-oldflat"))
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: bin + "/tiri-kernel-1.py"))
        // An older Tiri's layout: plain names pointing at a flat file that's about to go.
        symlink("tiri-remote-oldflat", bin + "/tiri")
        symlink("tiri-remote-oldflat", bin + "/tiri-remote")
        // v1 and v2 unused for three weeks, v3 just used. v2 has a session running from it.
        _ = sh("cd \(bin) && touch -t 202001010000 v1-linux-x86_64 v2-linux-x86_64 tiri-remote-oldflat")
        let running = Process()
        running.executableURL = URL(fileURLWithPath: bin + "/v2-linux-x86_64/tiri-remote")
        running.arguments = ["30"]
        try running.run()
        defer { running.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        _ = sh(RemoteHelperScripts.tidy(versioned: current))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: bin))
        #expect(!left.contains("v1-linux-x86_64"))
        #expect(left.contains("v2-linux-x86_64"))
        #expect(left.contains("v3-linux-x86_64"))
        #expect(left.contains("v9-linux-x86_64"))
        #expect(left.contains("tiri-kernel-1.py"))
        #expect(!left.contains("tiri-remote-oldflat"))
        // The plain names were left pointing at nothing, so they point at this one now.
        #expect(sh("\(bin)/tiri version").text == "v9-linux-x86_64\n")
    }

    @Test func plainNamesThatWorkAreLeftAlone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/.tiri/bin", current = bin + "/v9-linux-x86_64"
        try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: true)
        try helper("v9").write(to: URL(fileURLWithPath: current + "/tiri-remote"))
        try helper("older").write(to: URL(fileURLWithPath: bin + "/tiri-remote-older"))
        chmod(current + "/tiri-remote", 0o755)
        chmod(bin + "/tiri-remote-older", 0o755)
        symlink("tiri-remote-older", bin + "/tiri-remote")
        _ = sh(RemoteHelperScripts.tidy(versioned: current))
        // An older Tiri still connected runs that name. Pointing it elsewhere would change its helper.
        #expect(sh("\(bin)/tiri-remote version").text == "older\n")
        #expect(sh("\(current)/tiri version").text == "v9\n")
    }

    @Test func aRunFolderUnderTmpHasToBeOurs() {
        let script = RemoteHelperScripts.check(base: "/home/me/.tiri", versioned: "/home/me/.tiri/bin/v-x", run: "/tmp/.tiri-501/run")
        let parent = ShellQuote.quote("/tmp/.tiri-501"), run = ShellQuote.quote("/tmp/.tiri-501/run")
        #expect(script.contains("[ -O \(parent) ] && [ ! -L \(parent) ]"))
        #expect(script.contains("[ -O \(run) ] && [ ! -L \(run) ]"))
    }
}
