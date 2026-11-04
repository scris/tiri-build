import Foundation
import SQLite3

/// What's readable in a conversation, kept apart so that what the person said can count for more.
/// Tool output isn't here: it's most of the file, and it's why plain search matches nearly everything.
public struct ConversationText: Equatable, Sendable {
    public var you: String
    public var agent: String
    public var did: String

    public init(you: String = "", agent: String = "", did: String = "") {
        self.you = you
        self.agent = agent
        self.did = did
    }
}

public struct ConversationHit: Equatable, Sendable {
    public var file: String
    /// Where it matched, with the matching words between `ConversationIndex.markOpen` and `markClose`.
    public var excerpt: String
    public init(file: String, excerpt: String) {
        self.file = file
        self.excerpt = excerpt
    }
}

/// A private full-text index of past conversations, so that search is instant and looks only at what was said.
/// Everything in it comes from the agents' own files, so it can always be thrown away and read again.
public final class ConversationIndex: @unchecked Sendable {
    public static let markOpen = "\u{1}"
    public static let markClose = "\u{2}"
    /// Raise this when what's stored changes, and everything is read again.
    private static let version: Int32 = 1
    private static let excerptsPerSearch = 20

    public enum Failure: Error { case cannotOpen(String) }

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try open(path)
        if userVersion != Self.version {
            // Built from other files, so starting again loses nothing.
            sqlite3_close(db)
            db = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            try open(path)
            try createSchema()
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    deinit { sqlite3_close(db) }

    private func open(_ path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure.cannotOpen(path)
        }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    private var userVersion: Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private func createSchema() throws {
        let schema = """
        CREATE TABLE files(file TEXT PRIMARY KEY, seconds INTEGER NOT NULL);
        CREATE VIRTUAL TABLE conversations USING fts5(file UNINDEXED, title, you, agent, did, place, tokenize = 'porter unicode61');
        PRAGMA user_version = \(Self.version);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw Failure.cannotOpen(String(cString: sqlite3_errmsg(db))) }
    }

    /// What's been read, and the date each file had then.
    public func known() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var result: [String: Int] = [:]
        guard sqlite3_prepare_v2(db, "SELECT file, seconds FROM files", -1, &statement, nil) == SQLITE_OK else { return result }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let file = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: file)] = Int(sqlite3_column_int64(statement, 1))
        }
        return result
    }

    /// Replaces what's known about this file. Empty text still records the date, so it isn't read again.
    public func store(file: String, seconds: Int, title: String, place: String?, text: ConversationText?) {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        run("DELETE FROM conversations WHERE file = ?", [file])
        run("INSERT OR REPLACE INTO files(file, seconds) VALUES(?, ?)", [file, seconds])
        if let text {
            run("INSERT INTO conversations(file, title, you, agent, did, place) VALUES(?, ?, ?, ?, ?, ?)",
                [file, Self.searchable(title), Self.searchable(text.you), Self.searchable(text.agent), Self.searchable(text.did), Self.searchable(place ?? "")])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func remove(files: [String]) {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        for file in files {
            run("DELETE FROM conversations WHERE file = ?", [file])
            run("DELETE FROM files WHERE file = ?", [file])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func run(_ sql: String, _ values: [Any]) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(statement, values)
        sqlite3_step(statement)
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Any]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (position, value) in values.enumerated() {
            if let text = value as? String {
                sqlite3_bind_text(statement, Int32(position + 1), text, -1, transient)
            } else if let number = value as? Int {
                sqlite3_bind_int64(statement, Int32(position + 1), Int64(number))
            }
        }
    }

    /// Those with every one of your words first, then those with any of your words or the related ones.
    /// A term of several words has to appear as a phrase.
    public func search(words: [String], related: [String] = [], limit: Int = 200) -> [ConversationHit] {
        var hits: [ConversationHit] = []
        var seen = Set<String>()
        if words.count > 1, let all = Self.matchExpression(words, joinedBy: " AND ") {
            for hit in query(all, limit: limit) where seen.insert(hit.file).inserted { hits.append(hit) }
        }
        if let any = Self.matchExpression(words + related, joinedBy: " OR ") {
            for hit in query(any, limit: limit) where seen.insert(hit.file).inserted { hits.append(hit) }
        }
        return Array(hits.prefix(limit))
    }

    /// The best matches for any of these terms, best first.
    public func search(terms: [String], limit: Int = 200) -> [ConversationHit] {
        search(words: [], related: terms, limit: limit)
    }

    private func query(_ match: String, limit: Int) -> [ConversationHit] {
        lock.lock()
        defer { lock.unlock() }
        // What you said is what you'll remember, so it counts most.
        var ranking: OpaquePointer?
        defer { sqlite3_finalize(ranking) }
        guard sqlite3_prepare_v2(db, "SELECT rowid, file FROM conversations WHERE conversations MATCH ? ORDER BY bm25(conversations, 0, 6.0, 3.0, 1.0, 0.5, 1.0) LIMIT ?", -1, &ranking, nil) == SQLITE_OK else { return [] }
        bind(ranking, [match, limit])
        var found: [(row: Int64, file: String)] = []
        while sqlite3_step(ranking) == SQLITE_ROW {
            guard let file = sqlite3_column_text(ranking, 1) else { continue }
            found.append((sqlite3_column_int64(ranking, 0), String(cString: file)))
        }
        // An excerpt is most of the cost of a search, and only the first few are ever seen.
        var excerpting: OpaquePointer?
        defer { sqlite3_finalize(excerpting) }
        let canExcerpt = sqlite3_prepare_v2(db, "SELECT snippet(conversations, -1, ?, ?, '…', 22) FROM conversations WHERE conversations MATCH ? AND rowid = ?", -1, &excerpting, nil) == SQLITE_OK
        return found.enumerated().map { position, hit in
            guard canExcerpt, position < Self.excerptsPerSearch else { return ConversationHit(file: hit.file, excerpt: "") }
            sqlite3_reset(excerpting)
            bind(excerpting, [Self.markOpen, Self.markClose, match, Int(hit.row)])
            guard sqlite3_step(excerpting) == SQLITE_ROW, let excerpt = sqlite3_column_text(excerpting, 0) else { return ConversationHit(file: hit.file, excerpt: "") }
            return ConversationHit(file: hit.file, excerpt: Self.readable(String(cString: excerpt)))
        }
    }

    /// The words of something typed that are worth looking for.
    public static func terms(in query: String) -> [String] {
        let separated = query.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }
        var seen = Set<String>()
        return separated.map(String.init).filter { word in
            !stopWords.contains(word) && (word.count > 1 || word.unicodeScalars.contains(where: isCJK)) && seen.insert(word).inserted
        }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "about", "as", "at", "be", "been", "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have",
        "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "that", "the", "their", "them", "then", "there", "these",
        "this", "those", "to", "up", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your",
    ]

    static func matchExpression(_ terms: [String], joinedBy joiner: String) -> String? {
        let parts = terms.compactMap { term -> String? in
            let spaced = searchable(term).replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return spaced.isEmpty ? nil : "\"" + spaced + "\""
        }
        return parts.isEmpty ? nil : parts.joined(separator: joiner)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// The tokenizer treats a run of Chinese as one word, so each character becomes its own, and a term
    /// is then found as a phrase wherever it appears.
    static func searchable(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isCJK) else { return text }
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count + 16)
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                result.append(" ")
                result.append(scalar)
                result.append(" ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// An excerpt without its marks.
    public static func plain(_ excerpt: String) -> String {
        excerpt.replacingOccurrences(of: markOpen, with: "").replacingOccurrences(of: markClose, with: "")
    }

    /// Back to how it was written, on one line.
    static func readable(_ excerpt: String) -> String {
        // Chinese and its punctuation take no spaces: any here are only what `searchable` added.
        let closesUp = { (scalar: Unicode.Scalar) in
            isCJK(scalar) || (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
        }
        let isMark = { (scalar: Unicode.Scalar) in scalar.value <= 2 }
        var result = String.UnicodeScalarView()
        let scalars = Array(excerpt.unicodeScalars)
        var last: Unicode.Scalar?
        var spaceWaiting = false
        for (position, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace {
                spaceWaiting = true
                continue
            }
            if spaceWaiting {
                let next = isMark(scalar) ? scalars[(position + 1)...].first { !$0.properties.isWhitespace && !isMark($0) } : scalar
                if let last, let next, !(closesUp(last) && closesUp(next)) { result.append(" ") }
                spaceWaiting = false
            }
            result.append(scalar)
            if !isMark(scalar) { last = scalar }
        }
        return String(result)
    }
}

extension Conversations {
    /// A file read line by line: they run to hundreds of megabytes, nearly all of it tool output.
    public static func text(of data: Data, agent: String, limit: Int = 4_000_000) -> ConversationText? {
        var text = ConversationText()
        forEachPiece(of: data, agent: agent, limit: limit) { piece in
            switch piece {
            case .you(let said): text.you += said + "\n"
            case .agent(let said): text.agent += said + "\n"
            case .did(let done): text.did += done + "\n"
            }
        }
        return text.you.isEmpty && text.agent.isEmpty ? nil : text
    }

    /// One thing the person said with what the agent said back, as a unit of meaning.
    public static func turns(of data: Data, agent: String, limit: Int = 4_000_000) -> [(you: String, agent: String)] {
        var turns: [(you: String, agent: String)] = []
        forEachPiece(of: data, agent: agent, limit: limit) { piece in
            switch piece {
            case .you(let said): turns.append((said, ""))
            case .agent(let said):
                if turns.isEmpty { turns.append(("", "")) }
                turns[turns.count - 1].agent += said + "\n"
            case .did: break
            }
        }
        return turns
    }

    private static func forEachPiece(of data: Data, agent: String, limit: Int, _ body: (Piece) -> Void) {
        guard let format = AgentCatalog.profile(id: agent)?.conversationFormat else { return }
        var size = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count, size < limit {
                let remaining = count - start
                let found = memchr(base + start, 10, remaining)
                let end = found.map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base } ?? count
                defer { start = end + 1 }
                guard end > start, !isOnlyToolOutput(base + start, length: end - start) else { continue }
                autoreleasepool {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start, deallocator: .none)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                    for piece in pieces(of: object, format: format) {
                        switch piece {
                        case .you(let said), .agent(let said), .did(let said): size += said.utf8.count
                        }
                        body(piece)
                    }
                }
            }
        }
    }

    /// Most of the file, recognized without the cost of parsing it. Only long lines are worth skipping,
    /// and the marker has to be right at the start, where an agent's own words can't put it.
    private static func isOnlyToolOutput(_ line: UnsafePointer<UInt8>, length: Int) -> Bool {
        guard length > 16_384 else { return false }
        let head = UnsafeRawBufferPointer(start: line, count: min(length, 600))
        for marker in [#""type":"tool_result""#, #""type":"function_call_output""#, #""type":"custom_tool_call_output""#, #""type": "tool_result""#] {
            if head.firstRange(of: Data(marker.utf8)) != nil { return true }
        }
        return false
    }
}
