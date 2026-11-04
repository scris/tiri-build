import Foundation
import Testing
@testable import TiriCore

@Suite struct RemoteMirrorTests {
    @Test func mapsBothWays() {
        let map = RemotePathMap(destination: "gpu", localRoot: "/cache/gpu")
        #expect(map.local("/home/me/a.py") == "/cache/gpu/home/me/a.py")
        #expect(map.local("/") == "/cache/gpu")
        #expect(map.remote("/cache/gpu/home/me/a.py") == "/home/me/a.py")
        #expect(map.remote("/cache/gpu") == "/")
        #expect(map.remote("/cache/gpu2/home") == nil)
        #expect(map.remote("/elsewhere") == nil)
        #expect(map.contains("/cache/gpu/x"))
        #expect(!map.contains("/cache/gpux"))
    }

    @Test func textLosesTheLocalRootOnly() {
        let map = RemotePathMap(destination: "gpu", localRoot: "/cache/gpu")
        #expect(map.remoteText("see /cache/gpu/home/a.py and /cache/gpu2/b") == "see /home/a.py and /cache/gpu2/b")
    }

    @Test func folderNamesAreSafe() {
        #expect(RemoteMirror.key(for: "gpu-box.lab") == "gpu-box.lab")
        let awkward = RemoteMirror.key(for: "me@host:22")
        #expect(!awkward.contains("@") && !awkward.contains(":"))
        #expect(RemoteMirror.key(for: "a/b") != RemoteMirror.key(for: "a_b"))
    }
}

@Suite struct RemoteRecordTests {
    @Test func readsRecordsAndSignalsAcrossChunks() {
        var reader = RemoteRecordReader()
        let first = reader.read(Data("f\t100\t5\t/a b/c.txt\0!rea".utf8))
        #expect(first == [.record(RemoteRecord(kind: .file, modified: 100, size: 5, path: "/a b/c.txt"))])
        let second = reader.read(Data("dy\0d\t1\t2\t/x\0".utf8))
        #expect(second == [.signal("ready"), .record(RemoteRecord(kind: .folder, modified: 1, size: 2, path: "/x"))])
    }

    @Test func aPathCanHoldTabs() {
        var reader = RemoteRecordReader()
        let events = reader.read(Data("f\t1\t2\t/a\tb\0".utf8))
        #expect(events == [.record(RemoteRecord(kind: .file, modified: 1, size: 2, path: "/a\tb"))])
    }

    @Test func nonsenseIsSkipped() {
        var reader = RemoteRecordReader()
        #expect(reader.read(Data("garbage\0z\t1\t2\t/a\0f\tx\t2\t/a\0".utf8)).isEmpty)
    }

    @Test func gone() {
        var reader = RemoteRecordReader()
        #expect(reader.read(Data("-\t0\t0\t/a\0".utf8)) == [.record(RemoteRecord(kind: .gone, modified: 0, size: 0, path: "/a"))])
    }
}

@Suite struct SSHConfigTests {
    @Test func listsHostsAndSkipsPatterns() {
        let text = """
        # comment
        Host gpu gpu2
          HostName 10.0.0.5
          User me
        Host *
          ServerAliveInterval 10
        Host !bad wild* web
          hostname = web.example.com
        Match host foo
          User nobody
        """
        let hosts = SSHConfigFile.parse(text)
        #expect(hosts.map(\.alias) == ["gpu", "gpu2", "web"])
        #expect(hosts[0].hostName == "10.0.0.5")
        #expect(hosts[0].user == "me")
        #expect(hosts[2].hostName == "web.example.com")
        #expect(hosts[2].user == nil)
        #expect(hosts[0].detail == "me@10.0.0.5")
    }

    @Test(arguments: [
        ("gpu", "gpu"), ("me@gpu", "me@gpu"), ("ssh me@gpu", "me@gpu"), ("ssh -p 2222 me@gpu", "ssh://me@gpu:2222"),
        ("me@gpu:2222", "ssh://me@gpu:2222"), ("ssh://me@gpu:22/", "ssh://me@gpu:22"), ("  gpu  ", "gpu"),
    ])
    func understandsWhatsTyped(typed: String, expected: String) {
        #expect(SSHConfigFile.destination(from: typed) == expected)
    }

    @Test(arguments: ["", "-oProxyCommand=evil", "ssh -oProxyCommand=evil host", "host; rm -rf /", "two words", "ho$(st)"])
    func refusesWhatCantBeAPlace(typed: String) {
        #expect(SSHConfigFile.destination(from: typed) == nil)
    }
}

@Suite struct RemoteSearchTests {
    @Test func readsGitGrep() {
        let output = Data("src/a.py\u{0}12\u{0}def Hello():\ndocs/b.md\u{0}3\u{0}say hello\n".utf8)
        let found = RemoteSearch.parse(output, root: "/m/proj", query: "hello")
        #expect(found.map(\.path) == ["/m/proj/src/a.py", "/m/proj/docs/b.md"])
        #expect(found.map(\.line) == [12, 3])
        #expect(found[0].text == "def Hello():")
    }

    @Test func readsGrep() {
        let found = RemoteSearch.parse(Data("./a b.txt\u{0}7:has: colons hello\n".utf8), root: "/m", query: "hello")
        #expect(found.map(\.path) == ["/m/a b.txt"])
        #expect(found[0].line == 7)
        #expect(found[0].text == "has: colons hello")
    }
}

@Suite struct RemoteHelperTests {
    @Test func picksAHelperForWhatServersRun() {
        #expect(RemoteConnection.helperName(kind: "Linux x86_64") == "tiri-remote-linux-x86_64")
        #expect(RemoteConnection.helperName(kind: "Linux aarch64") == "tiri-remote-linux-aarch64")
        #expect(RemoteConnection.helperName(kind: "Darwin arm64") == "tiri-remote-darwin-arm64")
        #expect(RemoteConnection.helperName(kind: "FreeBSD amd64") == nil)
    }

    @Test func explainsFailuresInPlainWords() {
        #expect(RemoteConnection.explain("ssh: Could not resolve hostname x", destination: "x") == "x isn't a host this Mac can find.")
        #expect(RemoteConnection.explain("me@x: Permission denied (publickey).", destination: "x") == "x didn't accept your key or password.")
        #expect(RemoteConnection.explain("", destination: "x") == "x closed the connection.")
    }
}

@Suite struct LSPOverSSHTests {
    @Test func translatesAtTheEdges() {
        let map = RemotePathMap(destination: "gpu", localRoot: "/cache/gpu")
        let out = LSP.toServer(Data(#"{"uri":"file:\/\/\/cache\/gpu\/home\/a.py","rootUri":"file:///cache/gpu/home"}"#.utf8), map: map)
        #expect(String(decoding: out, as: UTF8.self) == #"{"uri":"file:\/\/\/home\/a.py","rootUri":"file:///home"}"#)
        let back = LSP.fromServer(Data(#"{"uri":"file:///home/a.py"}"#.utf8), map: map)
        #expect(String(decoding: back, as: UTF8.self) == #"{"uri":"file:///cache/gpu/home/a.py"}"#)
    }
}

@Suite struct CursorRemoteWorkspaceTests {
    private func imported(_ text: String) throws -> CodeWorkspaceImporter.Imported {
        try CodeWorkspaceImporter.parse(data: Data(text.utf8), fileURL: URL(fileURLWithPath: "/tmp/team.code-workspace"))
    }

    @Test func readsAPlainHost() throws {
        let result = try imported(#"{ "folders": [ { "uri": "vscode-remote://ssh-remote+gpu/home/me/a" }, { "uri": "vscode-remote://ssh-remote%2Bgpu/home/me/b%20c" } ] }"#)
        #expect(result.remote == "gpu")
        #expect(result.folders == ["/home/me/a", "/home/me/b c"])
        #expect(result.name == "team")
    }

    @Test func readsAHexHost() throws {
        let hex = Data(#"{"hostName":"box.lab","user":"me"}"#.utf8).map { String(format: "%02x", $0) }.joined()
        let result = try imported("{ \"folders\": [ { \"uri\": \"vscode-remote://ssh-remote+\(hex)/srv\" } ] }")
        #expect(result.remote == "me@box.lab")
        #expect(result.folders == ["/srv"])
    }

    @Test func aHostCantBeAnOption() {
        #expect(CodeWorkspaceImporter.remoteFolder(uri: "vscode-remote://ssh-remote+-oProxyCommand=evil/srv") == nil)
    }

    @Test func localFoldersWinInAMixture() throws {
        let result = try imported(#"{ "folders": [ { "path": "/tmp/x" }, { "uri": "vscode-remote://ssh-remote+gpu/a" } ] }"#)
        #expect(result.remote == nil)
        #expect(result.folders == ["/tmp/x"])
        #expect(result.skipped == 1)
    }

    @Test func onlyOneServer() throws {
        let result = try imported(#"{ "folders": [ { "uri": "vscode-remote://ssh-remote+a/x" }, { "uri": "vscode-remote://ssh-remote+b/y" } ] }"#)
        #expect(result.remote == "a")
        #expect(result.folders == ["/x"])
        #expect(result.skipped == 1)
    }
}
