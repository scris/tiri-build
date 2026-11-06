import CryptoKit
import Foundation

/// Edits that aren't saved yet, kept beside Tiri's state so a quit, a crash, a logout or a power cut
/// doesn't take them. Each open file with edits has one, under its tab's id, until it's saved, its
/// edits are thrown away, or its tab is closed.
public struct UnsavedEdit: Codable, Equatable, Sendable {
    public var path: String
    public var text: String
    /// A hash of what was on disk when the edits began. Different now means the file changed while Tiri
    /// wasn't looking, and both versions matter.
    public var base: String

    public init(path: String, text: String, onDisk: String) {
        self.path = path
        self.text = text
        self.base = Self.hash(onDisk)
    }

    public func diskChanged(now onDisk: String) -> Bool { Self.hash(onDisk) != base }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public enum UnsavedEdits {
    public static var directory: URL { TiriPaths.supportDirectory.appendingPathComponent("unsaved", isDirectory: true) }

    private static func url(_ item: String, _ folder: URL) -> URL { folder.appendingPathComponent(item + ".json") }

    /// Only Tiri's own ids make file names here.
    private static func isPlain(_ item: String) -> Bool {
        !item.isEmpty && item.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func write(_ edit: UnsavedEdit, for item: String, in folder: URL = directory) throws {
        guard isPlain(item) else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DurableFile.write(JSONEncoder().encode(edit), to: url(item, folder), permissions: 0o600)
        // What someone was typing is nobody else's to read.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(item, folder).path)
    }

    public static func read(_ item: String, in folder: URL = directory) -> UnsavedEdit? {
        guard isPlain(item), let data = try? Data(contentsOf: url(item, folder)) else { return nil }
        return try? JSONDecoder().decode(UnsavedEdit.self, from: data)
    }

    public static func remove(_ item: String, in folder: URL = directory) {
        guard isPlain(item) else { return }
        try? FileManager.default.removeItem(at: url(item, folder))
    }

    /// Every tab id with edits kept for it.
    public static func all(in folder: URL = directory) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}
