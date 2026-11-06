import Foundation
import Testing
@testable import TiriCore

/// What Tiri's children get from it, and what happens when one of them stops cooperating. One at a
/// time: marking everything open would make the controls here pass for the wrong reason.
@Suite(.serialized) struct ChildProcessTests {
    private func temporaryFolder() throws -> URL {
        // Short: a socket's path has to fit in 104 bytes.
        let folder = URL(fileURLWithPath: "/tmp/tiri-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Starts a program the way a terminal does: fork and exec, keeping whatever isn't close-on-exec.
    private func spawnKeepingFiles(_ argv: [String]) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], &actions, nil, arguments, environ) == 0 else { return -1 }
        return pid
    }

    private func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return (status >> 8) & 0xFF
    }

    /// What the shell itself has open, asked with a builtin so nothing else is opened to find out. The
    /// file it's writing to becomes its stdout, so it doesn't add one.
    private static func listOpen(to path: String) -> String {
        "exec > \(path); for n in $(seq 0 255); do [ -e /dev/fd/$n ] && echo $n; done; true"
    }

    @Test func pipesForChildrenAreCloseOnExec() {
        let pipe = Pipe.notInherited()
        #expect(CloseOnExec.isMarked(pipe.fileHandleForReading.fileDescriptor))
        #expect(CloseOnExec.isMarked(pipe.fileHandleForWriting.fileDescriptor))
        // Not that Pipe does it by itself: this is what a terminal used to inherit.
        let plain = Pipe()
        #expect(!CloseOnExec.isMarked(plain.fileHandleForWriting.fileDescriptor))
    }

    /// Before a terminal starts, even what Foundation opened behind Tiri's back.
    @Test func everythingOpenCanBeMarked() {
        let plain = Pipe()
        let copy = dup(plain.fileHandleForReading.fileDescriptor)
        defer { close(copy) }
        #expect(!CloseOnExec.isMarked(copy))
        CloseOnExec.markAllOpen()
        #expect(CloseOnExec.isMarked(copy))
        #expect(CloseOnExec.isMarked(plain.fileHandleForWriting.fileDescriptor))
        #expect(!CloseOnExec.isMarked(1))
    }

    @Test func aProgramStartedLaterDoesNotGetThem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipe = Pipe.notInherited()
        let leaked = Pipe()
        let listing = folder.appendingPathComponent("fds").path
        let pid = spawnKeepingFiles(["/bin/sh", "-c", Self.listOpen(to: listing)])
        #expect(wait(pid) == 0)
        let fds = Set(try String(contentsOfFile: listing, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
        #expect(!fds.contains(pipe.fileHandleForReading.fileDescriptor))
        #expect(!fds.contains(pipe.fileHandleForWriting.fileDescriptor))
        // The control: one that isn't marked does go along.
        #expect(fds.contains(leaked.fileHandleForWriting.fileDescriptor))
    }

    /// The session helper, built from its source here, started the way SwiftTerm starts it, with a pipe
    /// and a listening socket of the app's open in it. The program inside must have neither.
    @Test func aTerminalSessionClosesWhatItInherited() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/tiri-session/main.c")
        let helper = folder.appendingPathComponent("tiri-session").path
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compile.arguments = ["-O1", "-o", helper, source.path]
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)

        // An app's pipe, at a number of its own, and a socket listening, neither close-on-exec.
        let leaked = Pipe()
        let pipeEnd = dup2(leaked.fileHandleForWriting.fileDescriptor, 47)
        defer { close(pipeEnd) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        let listing = folder.appendingPathComponent("fds").path
        let program = Self.listOpen(to: listing + ".tmp") + "; mv \(listing).tmp \(listing)"
        let pid = spawnKeepingFiles([helper, "attach", folder.appendingPathComponent("s.sock").path, "--", "/bin/sh", "-c", program])
        try #require(pid > 0)
        _ = wait(pid)
        var text: String?
        for _ in 0..<100 where text == nil {
            text = try? String(contentsOfFile: listing, encoding: .utf8)
            if text == nil { usleep(50_000) }
        }
        let fds = Set(try #require(text).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
        #expect(!fds.contains(47))
        #expect(!fds.contains(listener))
        // Only its terminal: 0, 1 and 2, and the listing it's writing to.
        #expect(fds == [0, 1, 2], "\(fds.sorted())")
        // And with everything else gone, the pipe sees its end: nobody else is holding it.
        close(pipeEnd)
        try leaked.fileHandleForWriting.close()
        var wait = pollfd(fd: leaked.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&wait, 1, 3000) == 1)
        #expect(leaked.fileHandleForReading.availableData.isEmpty)
    }

    // MARK: Programs that hang

    @Test func aProgramThatLeavesSomethingHoldingItsOutputIsStillDone() async throws {
        let started = Date()
        // A login shell's setup that starts a daemon is like this: the shell's gone, its output isn't.
        let result = try #require(await BoundedRun.run("/bin/sh", ["-c", "echo hello; sleep 30 & echo $! >&2; exit 0"], timeout: 20))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(String(decoding: result.output, as: UTF8.self) == "hello\n")
        #expect(result.succeeded)
        if let daemon = Int32(String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) { kill(daemon, SIGKILL) }
    }

    @Test func aProgramThatHangsIsStoppedWithWhatItStarted() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("child").path
        let started = Date()
        // It ignores being asked, and so does its child, which ignoring a signal passes on to.
        let script = "trap '' TERM; sleep 600 & echo $! > \(marker); wait"
        let result = try #require(await BoundedRun.run("/bin/sh", ["-c", script], timeout: 1))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(Date().timeIntervalSince(started) < 6)
        let child = try #require(Int32(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        #expect(kill(child, 0) != 0)
    }

    // MARK: Logs

    @Test func aLogStaysShort() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.log")
        for index in 0..<300 { CappedLog.append(Data("line \(index) \(String(repeating: "x", count: 90))\n".utf8), to: file, limit: 10_000) }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size <= 10_000)
        let last = CappedLog.lastLines(of: file, count: 2)
        #expect(last.count == 2)
        #expect(last[1].hasPrefix("line 299 "))
    }

    // MARK: A language server that stops reading

    private static let deafServer = #"""
    import os, signal, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sys.stderr.write("deaf server up\n"); sys.stderr.flush()
    while True: time.sleep(1)
    """#

    @Test func aServerThatStopsReadingDoesNotHoldUpItsClient() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("deaf.py")
        try Self.deafServer.write(to: file, atomically: true, encoding: .utf8)
        let log = folder.appendingPathComponent("deaf.log")
        let client = LSPClient(launch: .init(executable: "/usr/bin/python3", arguments: [file.path], directory: "/tmp", path: nil, log: log))
        try client.start()
        let pid = try #require(client.processIdentifier)
        // Far more than a pipe holds, so a write is waiting on the server for good.
        let big = JSONValue.string(String(repeating: "x", count: 256 * 1024))
        for _ in 0..<4 { client.notify("textDocument/didChange", .object(["text": big])) }
        let started = Date()
        let answer = await client.request("textDocument/hover", .null, timeout: 1)
        #expect(answer == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        // What it said on stderr is kept.
        for _ in 0..<50 where CappedLog.lastLines(of: log).isEmpty { usleep(50_000) }
        #expect(CappedLog.lastLines(of: log) == ["deaf server up"])
        // It ignores SIGTERM, so stopping it takes the kill that follows.
        client.stop()
        var gone = false
        for _ in 0..<80 where !gone {
            usleep(100_000)
            gone = kill(pid, 0) != 0
        }
        #expect(gone)
    }

    @Test func quittingStopsServersBeforeReturning() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("deaf.py")
        try Self.deafServer.write(to: file, atomically: true, encoding: .utf8)
        let client = LSPClient(launch: .init(executable: "/usr/bin/python3", arguments: [file.path], directory: "/tmp", path: nil))
        try client.start()
        let pid = try #require(client.processIdentifier)
        usleep(300_000)
        // It ignores SIGTERM, and nothing else signals it, so only the kill stopNow sends before returning ends it.
        LSPClient.stopNow([client])
        var gone = false
        for _ in 0..<20 where !gone {
            usleep(50_000)
            gone = kill(pid, 0) != 0
        }
        #expect(gone)
    }
}

/// A repository with more changes than anyone reads, and one whose git is too slow to answer.
@Suite struct ChangesLimitTests {
    private func repository(untracked count: Int) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tiri-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        made.arguments = ["init", "-q", folder.path]
        try made.run()
        made.waitUntilExit()
        for index in 0..<count { FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(index).txt").path, contents: Data()) }
        return folder
    }

    @Test func onlyTheFirstChangesAreRead() throws {
        let folder = try repository(untracked: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let limited = Git.scanChanges(in: folder.path, limit: 25)
        #expect(limited.files.count == 25)
        #expect(limited.limited)
        #expect(!limited.timedOut)
        let all = Git.scanChanges(in: folder.path, limit: 100)
        #expect(all.files.count == 60)
        #expect(!all.limited)
        #expect(Git.scanChangesAcross([folder.path], limit: 25).limited)
    }

    @Test func gitTooSlowIsNotClean() throws {
        let folder = try repository(untracked: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file system monitor that never answers in time makes git status wait, as a huge repository does.
        let hook = folder.appendingPathComponent(".git/slow-monitor").path
        try "#!/bin/sh\nsleep 4\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)
        try "[core]\n\tfsmonitor = \(hook)\n".write(toFile: folder.appendingPathComponent(".git/config").path, atomically: true, encoding: .utf8)
        let started = Date()
        let scan = Git.scanChanges(in: folder.path, timeout: 1)
        #expect(scan.timedOut)
        #expect(scan.files.isEmpty)
        #expect(Date().timeIntervalSince(started) < 3.5)
    }
}
