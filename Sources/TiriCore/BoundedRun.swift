import Foundation

/// A program run to its end, but never waited on forever. Output goes to files, not pipes: a login
/// shell's setup can leave a daemon holding a pipe open long after the shell has gone, and reading
/// that to its end never ends. Past the time it's given, it and everything it started are stopped.
public enum BoundedRun {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var errors: Data
        public var timedOut: Bool
        public var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Nil if it couldn't be started.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           directory: String? = nil, timeout: TimeInterval) async -> Result? {
        let folder = FileManager.default.temporaryDirectory
        let outputFile = folder.appendingPathComponent("tiri-run-\(UUID().uuidString).out")
        let errorFile = folder.appendingPathComponent("tiri-run-\(UUID().uuidString).err")
        let manager = FileManager.default
        guard manager.createFile(atPath: outputFile.path, contents: nil), manager.createFile(atPath: errorFile.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputFile), let errors = try? FileHandle(forWritingTo: errorFile) else { return nil }
        CloseOnExec.mark(output.fileDescriptor, errors.fileDescriptor)
        defer {
            try? output.close()
            try? errors.close()
            try? manager.removeItem(at: outputFile)
            try? manager.removeItem(at: errorFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let timedOut = Flag()
        let finished: Bool = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            process.terminationHandler = { _ in once.resume(true) }
            do {
                try process.run()
            } catch {
                once.resume(false)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                // Process gives it a group of its own, so what it started goes too. Asked, then told.
                signal(SIGTERM, group: pid)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    signal(SIGKILL, group: pid)
                    once.resume(true)
                }
            }
        }
        guard finished else { return nil }
        let printed = (try? Data(contentsOf: outputFile)) ?? Data()
        let said = (try? Data(contentsOf: errorFile)) ?? Data()
        return Result(status: process.isRunning ? -1 : process.terminationStatus, output: printed, errors: said, timedOut: timedOut.value)
    }

    private static func signal(_ signal: Int32, group pid: Int32) {
        guard pid > 1 else { return }
        if killpg(pid, signal) != 0 { kill(pid, signal) }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        func set() { lock.withLock { isSet = true } }
        var value: Bool { lock.withLock { isSet } }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ value: Bool) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
