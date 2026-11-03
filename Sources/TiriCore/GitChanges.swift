import Foundation

public enum ChangeStatus: String, Sendable, Equatable {
    case modified, added, deleted, renamed, untracked, conflicted

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }
}

public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var path: String
    public var root: String
    public var relative: String
    public var status: ChangeStatus
    /// Where a renamed file came from, relative to the repository.
    public var oldRelative: String?
    public var id: String { path }

    public init(path: String, root: String, relative: String, status: ChangeStatus, oldRelative: String? = nil) {
        self.path = path
        self.root = root
        self.relative = relative
        self.status = status
        self.oldRelative = oldRelative
    }
}

public enum GitStatusParser {
    /// `git status --porcelain=v1 -z`: `XY path\0`, with a rename's old path as the next field.
    public static func parse(_ output: String, root: String) -> [ChangedFile] {
        var result: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst() {
            guard field.count > 3 else { continue }
            let codes = Array(field.prefix(2))
            let relative = String(field.dropFirst(3))
            var old: String?
            if codes.contains("R") || codes.contains("C") { old = fields.popFirst() }
            result.append(ChangedFile(path: root + "/" + relative, root: root, relative: relative,
                                      status: status(codes), oldRelative: old))
        }
        return result
    }

    private static func status(_ codes: [Character]) -> ChangeStatus {
        let (index, tree) = (codes[0], codes[1])
        if index == "?" { return .untracked }
        if index == "U" || tree == "U" || (index == "A" && tree == "A") || (index == "D" && tree == "D") { return .conflicted }
        if index == "R" || tree == "R" { return .renamed }
        if index == "D" || tree == "D" { return .deleted }
        if index == "A" { return .added }
        return .modified
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed, hunk }
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String

    public init(kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public struct FileDiff: Sendable, Equatable {
    public var lines: [DiffLine]
    public var isBinary: Bool
    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
    public var isEmpty: Bool { lines.isEmpty && !isBinary }

    public init(lines: [DiffLine] = [], isBinary: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
    }

    /// A file git doesn't track yet: all of it is new.
    public static func allAdded(_ text: String) -> FileDiff {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return FileDiff(lines: lines.enumerated().map { DiffLine(kind: .added, newLine: $0.offset + 1, text: $0.element) })
    }
}

public enum DiffParser {
    public static func parse(_ output: String) -> FileDiff {
        var diff = FileDiff()
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                diff.isBinary = true
                continue
            }
            if line.hasPrefix("@@") {
                if let (old, new) = hunkStart(line) {
                    oldLine = old
                    newLine = new
                    inHunk = true
                    diff.lines.append(DiffLine(kind: .hunk, text: line))
                }
                continue
            }
            guard inHunk, let first = line.first else { continue }
            let text = String(line.dropFirst())
            switch first {
            case "+":
                diff.lines.append(DiffLine(kind: .added, newLine: newLine, text: text))
                newLine += 1
            case "-":
                diff.lines.append(DiffLine(kind: .removed, oldLine: oldLine, text: text))
                oldLine += 1
            case " ":
                diff.lines.append(DiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: text))
                oldLine += 1
                newLine += 1
            case "\\":
                break  // "\ No newline at end of file"
            case "d":
                inHunk = false  // The next file's header.
            default:
                break
            }
        }
        return diff
    }

    /// `@@ -12,3 +14,5 @@ optional context`
    private static func hunkStart(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }
}

/// Runs git, read-only, for the changes view.
public enum Git {
    private static func run(_ arguments: [String], in directory: String) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        // Looking at a repository shouldn't write to it, or the watcher hears git and asks again.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    public static func repositoryRoot(of folder: String) -> String? {
        guard let result = run(["rev-parse", "--show-toplevel"], in: folder), result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Changes under a workspace folder, reported by the path that folder is known by.
    public static func changes(in folder: String) -> [ChangedFile] {
        guard let root = repositoryRoot(of: folder),
              let result = run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], in: folder),
              result.status == 0 else { return [] }
        let found = GitStatusParser.parse(String(decoding: result.output, as: UTF8.self), root: root)
        let realFolder = real(folder)
        // git reports real paths. The workspace may know this folder by a link to it.
        return found.map { file in
            var file = file
            if file.path.hasPrefix(realFolder + "/") {
                file.path = folder + file.path.dropFirst(realFolder.count)
            }
            return file
        }
    }

    /// All the changes in a workspace, in the order the explorer would show them.
    public static func changesAcross(_ folders: [String]) -> [ChangedFile] {
        var seen = Set<String>()
        var result: [ChangedFile] = []
        for folder in folders {
            for file in changes(in: folder).sorted(by: { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending })
            where seen.insert(file.path).inserted {
                result.append(file)
            }
        }
        return result
    }

    public static func diff(path: String) -> FileDiff {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = FileManager.default.fileExists(atPath: parent) ? parent : nearestExistingFolder(of: parent)
        guard let root = repositoryRoot(of: directory) else { return untrackedDiff(path) }
        let realPath = real(path)
        let realRoot = real(root)
        guard realPath.hasPrefix(realRoot + "/") else { return untrackedDiff(path) }
        let relative = String(realPath.dropFirst(realRoot.count + 1))
        if let status = run(["status", "--porcelain=v1", "-z", "--", relative], in: root),
           String(decoding: status.output, as: UTF8.self).hasPrefix("??") {
            return untrackedDiff(path)
        }
        if let result = run(["diff", "HEAD", "--no-color", "--no-ext-diff", "-U3", "--", relative], in: root), result.status == 0 {
            return DiffParser.parse(String(decoding: result.output, as: UTF8.self))
        }
        // A repository with no commits yet has no HEAD to compare with.
        return untrackedDiff(path)
    }

    /// The real path, even for a file that's gone: it's the deleted ones git has most to say about.
    static func real(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/")
    }

    private static func nearestExistingFolder(of path: String) -> String {
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }

    private static func untrackedDiff(_ path: String) -> FileDiff {
        guard let handle = FileHandle(forReadingAtPath: path) else { return FileDiff() }
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        guard FileClassifier.isLikelyText(data.prefix(8192)) else { return FileDiff(isBinary: true) }
        return .allAdded(String(decoding: data, as: UTF8.self))
    }
}
