import Foundation
import SQLite3

/// A place worth going back to: a workspace closed in Tiri, or a folder used lately in an editor or by an
/// agent. One list, newest first, with the noise taken out (see `RecentPlaces.rank`).
public struct RecentPlace: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A workspace closed in Tiri, which comes back with its tabs.
        case closed(WorkspaceID)
        case folder(String)
        /// A `.code-workspace` file an editor opened.
        case codeWorkspace(String)
    }

    public var kind: Kind
    public var name: String
    public var folders: [String]
    public var lastUsed: Date

    public var id: String {
        switch kind {
        case .closed(let id): return "closed:" + id
        case .folder(let path): return path
        case .codeWorkspace(let path): return path
        }
    }

    /// The path that stands for it when typed, shown or removed.
    public var path: String {
        switch kind {
        case .closed: return folders.first ?? ""
        case .folder(let path), .codeWorkspace(let path): return path
        }
    }
}

/// A workspace taken out of the sidebar but kept, tabs and all.
public struct ClosedWorkspace: Codable, Hashable, Sendable {
    public var workspace: Workspace
    public var closedAt: Date

    public init(workspace: Workspace, closedAt: Date) {
        self.workspace = workspace
        self.closedAt = closedAt
    }
}

/// What Tiri keeps for the list: closed workspaces, and what was removed from it and when. A removed
/// folder comes back only once it's used again after that.
public struct RecentStore: Codable, Equatable, Sendable {
    public var closed: [ClosedWorkspace] = []
    public var hidden: [String: Date] = [:]

    public static let closedLimit = 30

    public init() {}

    public static func load(from url: URL) -> RecentStore {
        guard let data = try? Data(contentsOf: url) else { return RecentStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RecentStore.self, from: data)) ?? RecentStore()
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public enum RecentPlaces {
    /// One place something was seen used, and when, if that's known.
    public struct Sighting: Hashable, Sendable {
        public var path: String
        public var date: Date?
        public var isCodeWorkspace: Bool

        public init(path: String, date: Date?, isCodeWorkspace: Bool = false) {
            self.path = path
            self.date = date
            self.isCodeWorkspace = isCodeWorkspace
        }
    }

    // MARK: Ranking

    /// Folders that hold projects rather than being one. Opening one of these isn't a sign of working there.
    static let containers = ["", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications", "Library"]

    /// The list as shown. Leaves out what isn't a project (temporary, hidden, gone, `~/Library`, a container
    /// like `~/Documents`), what's open in the sidebar already, and what was removed and not used since.
    /// A folder inside another one listed counts as that one, so a project's subfolders don't crowd it.
    public static func rank(sightings: [Sighting], closed: [ClosedWorkspace], hidden: [String: Date], openFolders: [String],
                            home: String, exists: (String) -> Bool) -> [RecentPlace] {
        let containerPaths = Set(containers.map { $0.isEmpty ? home : home + "/" + $0 })
        func isProject(_ path: String) -> Bool {
            guard path.hasPrefix("/"), !containerPaths.contains(path) else { return false }
            for prefix in ["/tmp/", "/private/", "/var/", "/System/", "/Library/", "/usr/", "/opt/", "/bin/", "/sbin/", "/cores/"]
                where path.hasPrefix(prefix) || path + "/" == prefix { return false }
            if path.hasPrefix(home + "/Library/") { return false }
            let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
            return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        func within(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

        // The newest sighting of each folder, and whether it's a `.code-workspace` file.
        var newest: [String: Date] = [:]
        var codeWorkspaces: Set<String> = []
        for sighting in sightings where isProject(sighting.path) {
            let date = sighting.date ?? .distantPast
            if newest[sighting.path].map({ $0 < date }) ?? true { newest[sighting.path] = date }
            if sighting.isCodeWorkspace { codeWorkspaces.insert(sighting.path) }
        }
        // Subfolders fold into the project above them.
        let folders = newest.keys.filter { !codeWorkspaces.contains($0) }
        // A `.code-workspace` file is a workspace of its own, wherever it's kept.
        for path in newest.keys where !codeWorkspaces.contains(path) {
            guard let parent = folders.filter({ $0 != path && within(path, $0) }).min(by: { $0.count < $1.count }) else { continue }
            if let date = newest[path], newest[parent].map({ $0 < date }) ?? true { newest[parent] = date }
            newest[path] = nil
        }

        // Closed workspaces stand for their folders, and are as recent as any of them.
        var places: [RecentPlace] = []
        var claimed: Set<String> = []
        for entry in closed {
            let workspace = entry.workspace
            var date = entry.closedAt
            for folder in workspace.folders {
                for (path, seen) in newest where within(path, folder) || within(folder, path) {
                    if seen > date { date = seen }
                    claimed.insert(path)
                }
            }
            places.append(RecentPlace(kind: .closed(workspace.id), name: workspace.shownName, folders: workspace.folders, lastUsed: date))
        }

        for (path, date) in newest where !claimed.contains(path) {
            if openFolders.contains(where: { within(path, $0) }) { continue }
            if let removed = hidden[path], date <= removed { continue }
            guard exists(path) else { continue }
            let name = (path as NSString).lastPathComponent
            if codeWorkspaces.contains(path) {
                places.append(RecentPlace(kind: .codeWorkspace(path), name: (name as NSString).deletingPathExtension, folders: [], lastUsed: date))
            } else {
                places.append(RecentPlace(kind: .folder(path), name: name, folders: [path], lastUsed: date))
            }
        }
        return places.sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Where they come from

    /// Everything seen, from every source this Mac has. Reads files only, so it's for a background queue.
    public static func sightings(home: String = NSHomeDirectory(), now: Date = Date()) -> [Sighting] {
        var all = editors(home: home)
        all += claudeCode(home: home)
        all += codex(home: home, since: now.addingTimeInterval(-120 * 86_400))
        return all.map { sighting in
            var resolved = sighting
            resolved.path = (URL(fileURLWithPath: sighting.path).resolvingSymlinksInPath().path as NSString).standardizingPath
            return resolved
        }
    }

    /// Cursor, VS Code and their kin keep the folders they opened in a small database, and a folder per
    /// place they've opened whose date says when it was last used.
    static let editorNames = ["Cursor", "Code", "Code - Insiders", "Windsurf", "VSCodium"]

    static func editors(home: String) -> [Sighting] {
        var found: [Sighting] = []
        for editor in editorNames {
            let user = home + "/Library/Application Support/" + editor + "/User"
            guard FileManager.default.fileExists(atPath: user) else { continue }
            let used = lastUse(workspaceStorage: user + "/workspaceStorage")
            for entry in recentlyOpened(database: user + "/globalStorage/state.vscdb") {
                found.append(Sighting(path: entry.path, date: used[entry.path], isCodeWorkspace: entry.isCodeWorkspace))
            }
        }
        return found
    }

    /// `history.recentlyOpenedPathsList`: folders and `.code-workspace` files. Files and remote places are left out.
    static func recentlyOpened(database: String) -> [(path: String, isCodeWorkspace: Bool)] {
        guard FileManager.default.fileExists(atPath: database) else { return [] }
        var db: OpaquePointer?
        let uri = "file:" + (database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return [] }
        let data: Data
        if let blob = sqlite3_column_blob(statement, 0) {
            data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
        } else if let text = sqlite3_column_text(statement, 0) {
            data = Data(String(cString: text).utf8)
        } else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            if let uri = entry["folderUri"] as? String, let path = localPath(uri) { return (path, false) }
            if let workspace = entry["workspace"] as? [String: Any], let uri = workspace["configPath"] as? String, let path = localPath(uri) {
                return (path, true)
            }
            return nil
        }
    }

    static func lastUse(workspaceStorage: String) -> [String: Date] {
        var used: [String: Date] = [:]
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: workspaceStorage)) ?? [] {
            let folder = workspaceStorage + "/" + name
            guard let data = manager.contents(atPath: folder + "/workspace.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = (json["folder"] as? String) ?? (json["workspace"] as? String), let path = localPath(uri) else { continue }
            let state = folder + "/state.vscdb"
            let date = modified(manager.fileExists(atPath: state) ? state : folder)
            if let date, used[path].map({ $0 < date }) ?? true { used[path] = date }
        }
        return used
    }

    static func localPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// Each conversation's file starts with the folder it ran in. The newest file in a project folder says when.
    static func claudeCode(home: String) -> [Sighting] {
        let projects = home + "/.claude/projects"
        let manager = FileManager.default
        var found: [Sighting] = []
        for name in (try? manager.contentsOfDirectory(atPath: projects)) ?? [] {
            let folder = projects + "/" + name
            let files = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".jsonl") }
            let dated = files.compactMap { file -> (String, Date)? in modified(folder + "/" + file).map { (folder + "/" + file, $0) } }
                .sorted { $0.1 > $1.1 }
            guard let latest = dated.first else { continue }
            // The newest says when; any of the newest few can say where, if that one doesn't.
            if let cwd = dated.prefix(5).lazy.compactMap({ firstValue(of: "cwd", in: $0.0) }).first {
                found.append(Sighting(path: cwd, date: latest.1))
            }
        }
        return found
    }

    /// `sessions/YYYY/MM/DD/*.jsonl`, the first line saying where it ran. Only days since `since` are read.
    static func codex(home: String, since: Date) -> [Sighting] {
        let sessions = home + "/.codex/sessions"
        let manager = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var found: [String: Date] = [:]
        var day = calendar.startOfDay(for: since)
        let today = Date()
        while day <= today {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            if let year = parts.year, let month = parts.month, let date = parts.day {
                let folder = String(format: "%@/%04d/%02d/%02d", sessions, year, month, date)
                for file in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".jsonl") {
                    let path = folder + "/" + file
                    guard let cwd = firstValue(of: "cwd", in: path), let when = modified(path) else { continue }
                    if found[cwd].map({ $0 < when }) ?? true { found[cwd] = when }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return found.map { Sighting(path: $0.key, date: $0.value) }
    }

    /// The first `"key":"/…"` in the start of a JSON-lines file. Found in the raw text, since a line can be far
    /// longer than what's read (a pasted picture), and only the value is decoded.
    static func firstValue(of key: String, in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s*:\\s*(\"/(?:[^\"\\\\]|\\\\.)*\")"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[range].utf8), options: .fragmentsAllowed)) as? String
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Showing

    /// How long ago, in a word: "now", "3h", "2d", "5w", "4mo".
    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if date == .distantPast { return "" }
        if seconds < 3_600 { return String(localized: "now") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds < 86_400 ? [.hour] : seconds < 14 * 86_400 ? [.day] : seconds < 60 * 86_400 ? [.weekOfMonth] : [.month, .year]
        return formatter.string(from: seconds) ?? ""
    }
}
