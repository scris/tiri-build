import AppKit
import Foundation
import TiriCore

// What keeps a plugin's process from costing the app: its output read off the main thread, and one
// that keeps dying, or stops answering, not started again and again.

/// A process's stdout, split into lines and decoded on a queue of its own. The main thread gets what
/// it said in batches, at most every 16 ms while it's talking, with only the latest of each event.
nonisolated final class PluginOutputReader: @unchecked Sendable {
    /// Like a program's whole output: a line longer than this is a program that's gone wrong.
    static let longestLine = 8 * 1024 * 1024
    static let gap: Double = 0.016

    struct Batch {
        var answers: [JSONValue] = []
        /// Each name once, its latest, in the order they first came.
        var events: [(name: String, data: JSONValue)] = []
        var askedToRefresh = false
        /// When it last ended a line, of any kind.
        var heard: Date?
        var lineTooLong = false

        var isEmpty: Bool { answers.isEmpty && events.isEmpty && !askedToRefresh && heard == nil && !lineTooLong }
    }

    let queue: DispatchQueue
    private let logName: String
    private let deliver: @MainActor (Batch) -> Void
    // Only on `queue`.
    private var buffer = Data()
    private var searched = 0
    // Under `lock`.
    private let lock = NSLock()
    private var ready = Batch()
    private var scheduled = false
    private var lastFlush: Double = 0

    init(logName: String, deliver: @escaping @MainActor (Batch) -> Void) {
        self.logName = logName
        self.deliver = deliver
        queue = DispatchQueue(label: "tiri.plugins.process-output")
    }

    func received(_ data: Data) {
        queue.async { self.split(data) }
    }

    private func split(_ data: Data) {
        buffer.append(data)
        var found = Batch()
        var start = buffer.startIndex
        var from = buffer.startIndex + searched
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            start = buffer.index(after: newline)
            from = start
            found.heard = Date()
            read(line, into: &found)
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        searched = buffer.count
        // A program that never ends a line doesn't get to fill the app's memory.
        if buffer.count > Self.longestLine {
            buffer = Data()
            searched = 0
            found.lineTooLong = true
        }
        guard !found.isEmpty else { return }
        lock.withLock {
            ready.answers += found.answers
            for event in found.events {
                if let index = ready.events.firstIndex(where: { $0.name == event.name }) { ready.events[index].data = event.data } else { ready.events.append(event) }
            }
            ready.askedToRefresh = ready.askedToRefresh || found.askedToRefresh
            ready.heard = found.heard ?? ready.heard
            ready.lineTooLong = ready.lineTooLong || found.lineTooLong
            guard !scheduled else { return }
            scheduled = true
            let wait = max(0, lastFlush + Self.gap - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
                MainActor.assumeIsolated { flush() }
            }
        }
    }

    private func read(_ line: Data, into batch: inout Batch) {
        guard !line.isEmpty else { return }
        // Only an object is a message, so a line of debugging isn't decoded first.
        let opens = line.first { $0 != 0x20 && $0 != 0x09 } == UInt8(ascii: "{")
        guard opens, let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            PluginProcesses.log(logName, "not JSON on stdout: " + String(decoding: line.prefix(300), as: UTF8.self) + "\n")
            return
        }
        if message["id"]?.intValue != nil {
            batch.answers.append(message)
            return
        }
        switch message["method"]?.stringValue {
        case "refresh":
            batch.askedToRefresh = true
        case "event":
            guard let name = message["params"]?["name"]?.stringValue else { return }
            let data = message["params"]?["data"] ?? .null
            if let index = batch.events.firstIndex(where: { $0.name == name }) { batch.events[index].data = data } else { batch.events.append((name, data)) }
        default:
            break
        }
    }

    /// Whatever's been read so far, now. Before it's taken as having ended, so its last answer counts.
    @MainActor func flush() {
        let batch = lock.withLock {
            scheduled = false
            lastFlush = ProcessInfo.processInfo.systemUptime
            defer { ready = Batch() }
            return ready
        }
        if !batch.isEmpty { deliver(batch) }
    }
}

/// Appended to, not rewritten: a process that logs a line at a time costs a write per line. Past
/// 1 MB, only the newest half is kept.
nonisolated enum PluginLogFiles {
    static let longest: UInt64 = 1_000_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var open: [String: FileHandle] = [:]

    static func append(_ text: String, to file: URL) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        lock.withLock {
            guard let handle = handle(for: file) else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                try? handle.close()
                open[file.path] = nil
                return
            }
            // Its size as it is, whoever else has emptied it since.
            var info = stat()
            if fstat(handle.fileDescriptor, &info) == 0, UInt64(info.st_size) > longest { rollOver(file, handle) }
        }
    }

    private static func handle(for file: URL) -> FileHandle? {
        if let handle = open[file.path] {
            // Still the file at that path: it may have been removed, with its plugin.
            var info = stat()
            if fstat(handle.fileDescriptor, &info) == 0, info.st_nlink > 0 { return handle }
            try? handle.close()
            open[file.path] = nil
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Appending, so each write lands at the end, wherever that is now.
        let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        open[file.path] = handle
        return handle
    }

    private static func rollOver(_ file: URL, _ handle: FileHandle) {
        try? handle.close()
        open[file.path] = nil
        guard let reading = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? reading.close() }
        let size = (try? reading.seekToEnd()) ?? 0
        let keep = longest / 2
        try? reading.seek(toOffset: size > keep ? size - keep : 0)
        guard let newest = try? reading.readToEnd() else { return }
        try? newest.write(to: file, options: .atomic)
    }
}

/// When a process ends without being asked, three times in five minutes, it isn't started again by
/// itself, as VS Code does with its extension host, until the plugin changes or someone says so.
struct PluginCrashRecord {
    static let limit = 3
    static let window: TimeInterval = 300

    var hash: String
    var times: [Date] = []
    var announced = false

    func recent(_ now: Date = Date()) -> [Date] { times.filter { now.timeIntervalSince($0) < Self.window } }
    func isStopped(_ now: Date = Date()) -> Bool { recent(now).count >= Self.limit }
}

extension PluginProcesses {
    /// Why it won't be started, if it won't.
    func refusal(_ key: Key, plugin: InstalledPlugin) -> Failure? {
        guard let record = crashes[key] else { return nil }
        guard record.hash == plugin.hash else {
            // Changed since, so it gets a new start.
            crashes[key] = nil
            return nil
        }
        guard record.isStopped() else { return nil }
        return Failure(message: "It stopped \(PluginCrashRecord.limit) times in 5 minutes, so it isn't started again by itself. See tiri plugin logs \(plugin.name), then turn it off and on.")
    }

    /// An end nobody asked for: it crashed, exited, or was stopped for not answering.
    func countEnd(of key: Key, hash: String, saying why: String) {
        PluginProcesses.log(key.plugin, "\(key.process) \(why)\n")
        var record = crashes[key].flatMap { $0.hash == hash ? $0 : nil } ?? PluginCrashRecord(hash: hash)
        let now = Date()
        record.times = record.recent(now) + [now]
        let stoppedNow = record.isStopped(now) && !record.announced
        if stoppedNow { record.announced = true }
        crashes[key] = record
        guard stoppedNow else { return }
        PluginProcesses.log(key.plugin, "\(key.process) stopped \(PluginCrashRecord.limit) times in 5 minutes, so it isn't started again until the plugin changes, it's turned off and on, or you press Start Again.\n")
        let host = self.host
        let name = key.plugin
        let title = host.plugin(named: name)?.title ?? name
        host.model.showToast(title: String(localized: "\(title) keeps stopping"), detail: String(localized: "It stopped 3 times in 5 minutes, so it won't start again by itself."),
                             symbol: "exclamationmark.triangle", tint: .orange, actionTitle: String(localized: "Logs"), duration: 20,
                             other: (String(localized: "Start Again"), { [weak self] in
                                 self?.forgetEnds(of: name)
                                 host.refreshProviders(of: name, onlyIfUnloaded: false)
                             })) {
            host.showLog(name)
        }
    }

    func forgetEnds(of plugin: String) {
        for key in crashes.keys where key.plugin == plugin { crashes[key] = nil }
    }

    /// How the program ended, in a few words for its log.
    static func ending(of process: Process) -> String {
        process.terminationReason == .uncaughtSignal ? "was ended by signal \(process.terminationStatus)" : "exited with status \(process.terminationStatus)"
    }
}
