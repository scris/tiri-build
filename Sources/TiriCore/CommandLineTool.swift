import Foundation

/// What the user's own shell can run. An app opened from Finder doesn't have their PATH, and agents
/// are often installed somewhere only their shell setup knows about, or as an alias. So this asks
/// that shell, the same way a terminal starts it.
public enum ShellLookup {
    private static let marker = "tiri-found:"

    /// A name that's safe to put in a script. A preset can hold anything, so anything else isn't asked about.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
    }

    /// One line per name, so a failure in one can't hide another. Written to work in fish too.
    public static func script(for names: [String]) -> String {
        names.filter(isPlainName)
            .map { "command -v \($0) >/dev/null 2>&1 && echo \(marker)\($0)" }
            .joined(separator: "; ")
    }

    /// Shell setup can print anything, so only whole lines with the marker count.
    public static func found(in output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker) {
            names.insert(String(line.dropFirst(marker.count)))
        }
        return names
    }

    /// Nil if the shell didn't answer in time. Slow or broken shell setup shouldn't look like a
    /// missing agent. Output goes to a file, because a daemon started by the shell's setup can
    /// hold a pipe open long after the shell has gone.
    public static func run(names: [String], shell: String, environment: [String: String]? = nil,
                           timeout: TimeInterval = 8) async -> Set<String>? {
        await output(of: script(for: names), shell: shell, environment: environment, timeout: timeout).map(found(in:))
    }

    private static func output(of script: String, shell: String, environment: [String: String]?, timeout: TimeInterval) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-lookup-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if let environment { process.environment = environment }

        let finished: Bool = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            process.terminationHandler = { _ in once.resume(true) }
            do {
                try process.run()
            } catch {
                once.resume(false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(false)
                if process.isRunning { process.terminate() }
            }
        }
        guard finished else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// The user's PATH, as their shell sets it up. Fish lists it with the marker on each part.
    public static func path(shell: String, environment: [String: String]? = nil, timeout: TimeInterval = 8) async -> String? {
        let pathMarker = "tiri-path:"
        guard let text = await output(of: "echo \(pathMarker)$PATH", shell: shell, environment: environment, timeout: timeout) else { return nil }
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(pathMarker) }) else { return nil }
        let value = line.dropFirst(pathMarker.count).replacingOccurrences(of: " " + pathMarker, with: ":")
        return value.isEmpty ? nil : value
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// `tiri` for terminals outside Tiri. Inside it, every terminal already has it on its PATH. This
/// is a link into the app, so updating the app updates the command.
public enum CommandLineTool {
    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// A link to a copy of Tiri that has moved or gone.
        case stale
        /// Something that isn't Tiri's link, such as the copy `build.sh` leaves.
        case otherFile
    }

    public static func link(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/tiri")
    }

    public static func state(link: URL, bundled: URL) -> State {
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
            // `fileExists` follows links, and this path isn't one.
            return manager.fileExists(atPath: link.path) ? .otherFile : .notInstalled
        }
        return destination == bundled.path ? .installed : .stale
    }

    /// Why a link made now wouldn't last. macOS runs an app opened from Downloads from a temporary
    /// place, and a disk image gets ejected.
    public static func problem(appPath: String) -> String? {
        guard appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") else { return nil }
        return "Move Tiri to your Applications folder first. From where it's running now, the link would stop working."
    }

    public static func install(link: URL, bundled: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not `fileExists`: that says no for a link whose target has gone.
        if (try? manager.attributesOfItem(atPath: link.path)) != nil { try manager.removeItem(at: link) }
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: bundled.path)
    }

    /// Only ever a link. A file that isn't one was put there by someone else.
    public static func remove(link: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try FileManager.default.removeItem(at: link)
    }
}
