import Foundation

/// A plugin as one file, to hand to someone.
///
/// A `.tiriplugin` is a zip holding `tiri-package.json`, which says what it is, and `plugin/`, the
/// plugin's folder. What a lockfile rebuilds isn't in it, and neither are its settings or its panels'
/// storage, which live outside the folder and can hold someone's tokens. Importing runs nothing and
/// leaves it off: turning it on still asks, and says what it adds and runs.
///
/// The hash says the file arrived whole. It isn't a signature, and doesn't say who made it.
public enum PluginPackage {
    public static let fileExtension = "tiriplugin"
    public static let currentFormat = 1
    static let headerName = "tiri-package.json"
    static let payloadName = "plugin"
    static let maximumBytes: Int64 = 500 * 1024 * 1024
    static let maximumFiles = 50_000

    public struct Failure: Error, CustomStringConvertible, Equatable, Sendable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    struct Header: Codable, Equatable {
        var format: Int
        var name: String
        var version: String
        var hash: String
        var files: Int
        var exportedBy: String
    }

    public struct Exported: Sendable, Equatable {
        public var name: String
        public var version: String
        public var file: URL
        public var files: Int
        /// Files that usually hold secrets, which stayed behind.
        public var leftOut: [String]

        public var text: String {
            var lines = ["Exported \(name) \(version) to \(file.path), \(files) file\(files == 1 ? "" : "s")."]
            if !leftOut.isEmpty { lines.append("Left out, in case they hold secrets: " + leftOut.joined(separator: ", ")) }
            lines.append("Its settings aren't in it. To bring it in, double-click it or run tiri plugin import.")
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Unpacked and checked, and not installed yet.
    public struct Opened: Sendable, Equatable {
        public var name: String
        public var title: String
        public var version: String
        public var hash: String
        public var folder: URL
        var scratch: URL?

        public func discard() {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
    }

    public static func defaultFileName(name: String, version: String) -> String {
        "\(name)-\(version).\(fileExtension)"
    }

    // MARK: Export

    public static func export(_ folder: URL, to file: URL) throws -> Exported {
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.load(from: folder)
        } catch {
            throw Failure(PluginManifest.explain(error))
        }
        try requireValid(manifest, folder: folder)
        let manager = FileManager.default
        let scratch = try makeScratch()
        defer { try? manager.removeItem(at: scratch) }
        let payload = scratch.appendingPathComponent(payloadName, isDirectory: true)
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        var leftOut: [String] = []
        try copyTree(from: folder.resolvingSymlinksInPath(), to: payload, relative: "", leftOut: &leftOut)

        let hashes = PluginTree.hashes(payload, listing: PluginTree.list(payload))
        var size: Int64 = 0
        for relative in hashes.keys {
            size += ((try? manager.attributesOfItem(atPath: payload.path + "/" + relative))?[.size] as? Int64) ?? 0
        }
        guard size <= maximumBytes, hashes.count <= maximumFiles else {
            throw Failure(String(localized: "It's too big to export: \(hashes.count) files, \(size / 1_048_576) MB, and the most is \(maximumFiles) files, \(maximumBytes / 1_048_576) MB. Whatever is rebuilt from a lockfile can stay out of it."))
        }
        let header = Header(format: currentFormat, name: manifest.name, version: manifest.version, hash: PluginTree.treeHash(hashes),
                            files: hashes.count, exportedBy: TiriCoreVersion.string)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(header).write(to: scratch.appendingPathComponent(headerName))

        let built = scratch.appendingPathComponent("package.zip")
        // -y keeps links as links and -X leaves out what only this Mac cares about.
        let zipped = run("/usr/bin/zip", ["-q", "-r", "-y", "-X", built.path, headerName, payloadName], in: scratch)
        guard zipped.code == 0 else { throw Failure(String(localized: "Couldn't pack it: \(zipped.output)")) }
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        try manager.moveItem(at: built, to: file)
        return Exported(name: manifest.name, version: manifest.version, file: file, files: hashes.count, leftOut: leftOut.sorted())
    }

    /// Only what's approved goes: what a lockfile rebuilds stays, along with what usually holds a secret.
    private static func copyTree(from source: URL, to target: URL, relative: String, leftOut: inout [String]) throws {
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: source.path).sorted() {
            if name == ".DS_Store" || name == "__MACOSX" || (relative.isEmpty && PluginTree.skippedAtTop.contains(name)) { continue }
            let inner = relative.isEmpty ? name : relative + "/" + name
            if name == ".env" || name.hasPrefix(".env.") {
                leftOut.append(inner)
                continue
            }
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            var info = stat()
            guard lstat(from.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try manager.createDirectory(at: to, withIntermediateDirectories: true)
                try copyTree(from: from, to: to, relative: inner, leftOut: &leftOut)
            } else {
                try manager.copyItem(at: from, to: to)
            }
        }
    }

    // MARK: Import

    /// A `.tiriplugin`, a `.zip` of a plugin's folder (which is what a download from GitHub is), or a folder.
    public static func open(_ source: URL) throws -> Opened {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw Failure(String(localized: "There's nothing at \(source.path).")) }
        if isFolder.boolValue {
            guard manager.fileExists(atPath: PluginManifest.url(in: source).path) else {
                throw Failure(String(localized: "\(source.lastPathComponent) isn't a plugin: it has no \(PluginManifest.folderName)/plugin.json."))
            }
            return try opened(folder: source, scratch: nil)
        }
        let scratch = try makeScratch()
        do {
            try unpack(source, into: scratch)
            if manager.fileExists(atPath: scratch.appendingPathComponent(headerName).path) {
                return try openPackage(in: scratch, named: source.lastPathComponent)
            }
            if source.pathExtension.lowercased() == fileExtension {
                throw Failure(String(localized: "\(source.lastPathComponent) isn't a Tiri plugin: it has no \(headerName)."))
            }
            return try opened(folder: try findPlugin(in: scratch, named: source.lastPathComponent), scratch: scratch)
        } catch {
            try? manager.removeItem(at: scratch)
            throw error
        }
    }

    private static func openPackage(in scratch: URL, named file: String) throws -> Opened {
        let data = (try? Data(contentsOf: scratch.appendingPathComponent(headerName))) ?? Data()
        // The format first: a newer one may not have the other fields.
        struct Version: Decodable { var format: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else { throw Failure(String(localized: "\(file) is damaged: its \(headerName) can't be read.")) }
        guard version.format <= currentFormat else { throw Failure(String(localized: "\(file) was made by a newer Tiri. Update Tiri to import it.")) }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw Failure(String(localized: "\(file) is damaged: its \(headerName) can't be read.")) }
        let payload = scratch.appendingPathComponent(payloadName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: PluginManifest.url(in: payload).path) else { throw Failure(String(localized: "\(file) is damaged: it has no plugin inside.")) }
        let opened = try opened(folder: payload, scratch: scratch)
        guard opened.name == header.name else { throw Failure(String(localized: "\(file) is damaged: it says it's \(header.name), and what's inside is \(opened.name).")) }
        guard opened.hash == header.hash else { throw Failure(String(localized: "\(file) is damaged, or something in it changed after it was exported.")) }
        return opened
    }

    private static func opened(folder: URL, scratch: URL?) throws -> Opened {
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.load(from: folder)
        } catch {
            throw Failure(PluginManifest.explain(error))
        }
        try requireValid(manifest, folder: folder)
        let hash = PluginTree.treeHash(PluginTree.hashes(folder, listing: PluginTree.list(folder)))
        return Opened(name: manifest.name, title: manifest.title ?? manifest.name, version: manifest.version, hash: hash, folder: folder, scratch: scratch)
    }

    /// Unpacks into a throwaway folder that nothing is run from. A hostile archive doesn't get to climb
    /// out, fill the disk, or write through a link it made a moment earlier.
    private static func unpack(_ file: URL, into scratch: URL) throws {
        let name = file.lastPathComponent
        let listed = run("/usr/bin/unzip", ["-Z1", file.path])
        guard listed.code == 0 else { throw Failure(String(localized: "\(name) won't open: it isn't a zip, or it's damaged.")) }
        let entries = listed.output.split(whereSeparator: \.isNewline).map(String.init)
        guard entries.count <= maximumFiles else { throw Failure(String(localized: "\(name) has too many files: \(entries.count), and the most is \(maximumFiles).")) }
        for entry in entries where entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
            throw Failure(String(localized: "\(name) has a file outside itself: \(entry)."))
        }
        let detail = run("/usr/bin/unzip", ["-Z", file.path]).output.split(whereSeparator: \.isNewline).map(String.init)
        let links = entries.filter { entry in detail.contains { $0.hasPrefix("l") && $0.hasSuffix(" " + entry) } }
        for link in links where entries.contains(where: { $0.hasPrefix(link + "/") }) {
            throw Failure(String(localized: "\(name) has files inside a link: \(link)."))
        }
        // The last line says how much it unpacks to, whatever its size on disk.
        if let total = detail.last?.split(separator: " ").map(String.init), let index = total.firstIndex(where: { $0.hasPrefix("bytes") }), index > 0,
           let bytes = Int64(total[index - 1]), bytes > maximumBytes {
            throw Failure(String(localized: "\(name) is too big: it unpacks to \(bytes / 1_048_576) MB, and the most is \(maximumBytes / 1_048_576) MB."))
        }
        let unpacked = run("/usr/bin/unzip", ["-q", "-o", file.path, "-d", scratch.path])
        guard unpacked.code == 0 else { throw Failure(String(localized: "Couldn't unpack \(name).")) }
        let manager = FileManager.default
        try? manager.removeItem(at: scratch.appendingPathComponent("__MACOSX"))
        if let walker = manager.enumerator(atPath: scratch.path) {
            var clutter: [String] = []
            while let inner = walker.nextObject() as? String {
                if (inner as NSString).lastPathComponent == ".DS_Store" { clutter.append(inner) }
            }
            for inner in clutter { try? manager.removeItem(atPath: scratch.path + "/" + inner) }
        }
    }

    /// Its folder is the zip's top, or the one folder there.
    private static func findPlugin(in scratch: URL, named file: String) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: PluginManifest.url(in: scratch).path) { return scratch }
        let found = ((try? manager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [])
            .filter { manager.fileExists(atPath: PluginManifest.url(in: $0).path) }
        guard let first = found.first else { throw Failure(String(localized: "\(file) has no Tiri plugin in it: no \(PluginManifest.folderName)/plugin.json at its top or one folder down.")) }
        guard found.count == 1 else {
            throw Failure(String(localized: "\(file) holds \(found.count) plugins: \(found.map(\.lastPathComponent).sorted().joined(separator: ", ")). Import them one at a time."))
        }
        return first
    }

    private static func requireValid(_ manifest: PluginManifest, folder: URL) throws {
        let errors = PluginValidator.validate(manifest, folder: folder).filter { $0.severity == .error }
        guard errors.isEmpty else { throw Failure(String(localized: "\(manifest.name) has errors: \(errors.map(\.message).joined(separator: "; "))")) }
    }

    private static func makeScratch() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
