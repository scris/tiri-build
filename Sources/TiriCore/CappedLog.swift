import Foundation

/// What a program said on stderr, kept for when someone asks why it stopped. Never large: past
/// the limit, only the newer half stays.
public enum CappedLog {
    private static let lock = NSLock()

    public static func append(_ data: Data, to file: URL, limit: Int = 1_000_000) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            // Added to the end, so a server that talks a lot isn't copying the whole file each time.
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            try? handle.close()
            guard Int(size) + data.count > limit, let whole = try? Data(contentsOf: file) else { return }
            try? whole.suffix(limit / 2).write(to: file, options: .atomic)
        }
    }

    /// The last few lines that say something.
    public static func lastLines(of file: URL, count: Int = 5) -> [String] {
        guard let data = lock.withLock({ try? Data(contentsOf: file) }) else { return [] }
        let text = String(decoding: data.suffix(16_384), as: UTF8.self)
        return Array(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count))
    }
}
