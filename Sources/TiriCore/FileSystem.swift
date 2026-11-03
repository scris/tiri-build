import Foundation

// MARK: - File access, behind a protocol so a remote (SSH) backend can be added later

public struct FileEntry: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

public protocol FileSystemProviding: Sendable {
    /// One directory's visible entries: folders first, then natural name order.
    func list(directory: String, excludes: ExcludeMatcher) throws -> [FileEntry]
}

public struct ExcludeMatcher: Sendable, Equatable {
    private var exactNames: Set<String> = []
    private var globs: [String] = []

    public init(patterns: [String]) {
        for pattern in patterns {
            // VS Code writes `**/node_modules`; that's the same as the bare name here.
            let trimmed = pattern.hasPrefix("**/") ? String(pattern.dropFirst(3)) : pattern
            if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("/") {
                globs.append(trimmed)
            } else {
                exactNames.insert(trimmed)
            }
        }
    }

    public func excludes(name: String, relativePath: String? = nil) -> Bool {
        if exactNames.contains(name) { return true }
        for glob in globs {
            if fnmatch(glob, name, 0) == 0 { return true }
            if let relativePath, fnmatch(glob, relativePath, 0) == 0 { return true }
        }
        return false
    }
}

public struct LocalFileSystem: FileSystemProviding {
    public init() {}

    public func list(directory: String, excludes: ExcludeMatcher) throws -> [FileEntry] {
        guard let dir = opendir(directory) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: directory])
        }
        defer { closedir(dir) }
        var entries: [FileEntry] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || excludes.excludes(name: name) { continue }
            let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            let type = Int32(entry.pointee.d_type)
            var isDirectory = type == DT_DIR
            let isSymlink = type == DT_LNK
            if isSymlink {
                var target = stat()
                if stat(path, &target) == 0 {
                    isDirectory = (target.st_mode & S_IFMT) == S_IFDIR
                }
            }
            entries.append(FileEntry(name: name, path: path, isDirectory: isDirectory, isSymlink: isSymlink))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }
}

// MARK: - Quick-open index

public struct IndexedFile: Sendable, Equatable {
    public var path: String
    public var root: String
    /// `folder/rel/path` for multi-root disambiguation, as Cursor shows it.
    public var relative: String
    public var name: String
}

public enum FileIndexer {
    /// Walk folders without following symlinks. Stops at `limit` files so opening a huge
    /// folder (a home directory, say) can't run away.
    public static func walk(roots: [String], excludes: ExcludeMatcher, limit: Int = 200_000,
                            isCancelled: () -> Bool = { false }) -> [IndexedFile] {
        var files: [IndexedFile] = []
        files.reserveCapacity(4096)
        for root in roots {
            var stack = [root]
            while let directory = stack.popLast() {
                if files.count >= limit || isCancelled() { return files }
                guard let dir = opendir(directory) else { continue }
                defer { closedir(dir) }
                while let entry = readdir(dir) {
                    let length = Int(entry.pointee.d_namlen)
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: UInt8.self, capacity: length) {
                            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
                        }
                    }
                    if name == "." || name == ".." || excludes.excludes(name: name) { continue }
                    let path = directory + "/" + name
                    switch Int32(entry.pointee.d_type) {
                    case DT_DIR:
                        stack.append(path)
                    case DT_REG, DT_LNK:
                        let relative = String(path.dropFirst(root.count + 1))
                        files.append(IndexedFile(path: path, root: root, relative: relative, name: name))
                    default:
                        break
                    }
                }
            }
        }
        return files
    }
}

// MARK: - Fuzzy matching

public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// Matched offsets into the candidate.
        public var positions: [Int]
    }

    /// Subsequence match, favouring word starts, consecutive runs and the filename.
    public static func match(query: [UInt8], candidate: [UInt8], nameStart: Int) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, positions: []) }
        guard query.count <= candidate.count else { return nil }
        // Quick reject: all query bytes must appear in order.
        var scan = 0
        for byte in query {
            while scan < candidate.count, lower(candidate[scan]) != byte { scan += 1 }
            if scan == candidate.count { return nil }
            scan += 1
        }

        let n = query.count
        let m = candidate.count
        // Best score ending with query[i] matched at candidate[j].
        let none = Int.min / 2
        var previous = [Int](repeating: none, count: m)
        var current = [Int](repeating: none, count: m)
        var from = [Int32](repeating: -1, count: n * m)

        for i in 0..<n {
            var bestPrior = none
            var bestPriorIndex = -1
            for j in 0..<m {
                current[j] = none
                if i > 0, j > 0, previous[j - 1] > bestPrior {
                    bestPrior = previous[j - 1]
                    bestPriorIndex = j - 1
                }
                guard lower(candidate[j]) == query[i] else { continue }
                var bonus = 1
                let isBoundary = j == 0 || isSeparator(candidate[j - 1])
                    || (isUpper(candidate[j]) && !isUpper(candidate[j - 1]))
                if isBoundary { bonus += 8 }
                if j >= nameStart { bonus += 4 }
                if j == nameStart { bonus += 6 }
                if i == 0 {
                    current[j] = bonus - min(j, 12) / 4
                } else {
                    let consecutive = (j > 0 && previous[j - 1] > none) ? previous[j - 1] + bonus + 10 : none
                    let gapped = bestPrior > none ? bestPrior + bonus - 1 : none
                    if consecutive >= gapped, consecutive > none {
                        current[j] = consecutive
                        from[i * m + j] = Int32(j - 1)
                    } else if gapped > none {
                        current[j] = gapped
                        from[i * m + j] = Int32(bestPriorIndex)
                    }
                }
            }
            swap(&previous, &current)
        }

        var bestScore = none
        var bestEnd = -1
        for j in 0..<m where previous[j] > bestScore {
            bestScore = previous[j]
            bestEnd = j
        }
        guard bestEnd >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: n)
        var cursor = bestEnd
        var i = n - 1
        while i >= 0 {
            positions[i] = cursor
            if i > 0 { cursor = Int(from[i * m + cursor]) }
            i -= 1
        }
        // Shorter paths win ties.
        return Match(score: bestScore - m / 16, positions: positions)
    }

    public static func match(query: String, candidate: String, nameStart: Int? = nil) -> Match? {
        let bytes = Array(candidate.utf8)
        let start = nameStart ?? ((bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1)
        return match(query: normalize(query), candidate: bytes, nameStart: start)
    }

    public static func normalize(_ query: String) -> [UInt8] {
        query.utf8.filter { $0 != UInt8(ascii: " ") }.map(lower)
    }

    @inline(__always) private static func lower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    @inline(__always) private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }

    @inline(__always) private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "/") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: " ")
    }
}

// MARK: - File kinds

public enum FileKind: String, Sendable, Equatable {
    case markdown, text, image, svg, pdf, media, html, csv, office, quickLook
}

public enum FileClassifier {
    private static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "avif"]
    private static let media: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "mp4", "m4v", "mov", "webm", "avi", "mkv"]
    private static let office: Set<String> = ["pptx", "ppt", "docx", "doc", "xlsx", "xls", "key", "pages", "numbers", "rtf", "rtfd"]
    private static let knownText: Set<String> = [
        "txt", "text", "log", "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "xml", "plist",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "go", "rs", "py", "rb", "php", "lua",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "css", "scss", "less", "vue", "svelte", "sh", "bash", "zsh", "fish",
        "sql", "graphql", "proto", "r", "jl", "dart", "scala", "ex", "exs", "erl", "hs", "ml", "clj", "tex", "bib", "rst",
        "adoc", "gradle", "lock", "gitignore", "gitattributes", "editorconfig", "dockerfile", "makefile", "cmake", "tf",
        "code-workspace", "patch", "diff", "strings", "pbxproj", "entitlements", "xcconfig", "ipynb", "tsv",
    ]
    private static let knownTextNames: Set<String> = [
        "makefile", "dockerfile", "license", "licence", "readme", "changelog", "authors", "copying", "gemfile", "rakefile",
        "podfile", "procfile", "brewfile", ".gitignore", ".gitattributes", ".env", ".npmrc", ".zshrc", ".bashrc", ".prettierrc",
        ".eslintrc", ".editorconfig", ".dockerignore", "cname", "notice",
    ]

    public static func classify(path: String, head: () -> Data? = { nil }) -> FileKind {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if markdown.contains(ext) { return .markdown }
        if ext == "svg" { return .svg }
        if images.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if media.contains(ext) { return .media }
        if ext == "html" || ext == "htm" || ext == "xhtml" { return .html }
        if ext == "csv" { return .csv }
        if office.contains(ext) { return .office }
        if knownText.contains(ext) || knownTextNames.contains(name) { return .text }
        // Unknown extension: look at the bytes.
        if let data = head(), isLikelyText(data) { return .text }
        return .quickLook
    }

    /// No NUL bytes and valid-ish UTF-8. Empty files count as text.
    public static func isLikelyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let sample = data.prefix(8192)
        if sample.contains(0) { return false }
        if String(data: sample, encoding: .utf8) != nil { return true }
        // A multibyte character cut at the end of the sample shouldn't make it binary.
        for trim in 1...3 where sample.count > trim {
            if String(data: sample.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// Syntax family for the lightweight highlighter.
    public static func language(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

// MARK: - CSV

public enum CSVParser {
    public struct Table: Equatable, Sendable {
        public var header: [String]
        public var rows: [[String]]
        public var truncated: Bool
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    public static func parse(_ text: String, delimiter: Character? = nil, maxRows: Int = 100_000) -> Table {
        let separator = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var truncated = false
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                inQuotes = true
            } else if character == separator {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                if rows.count > maxRows {
                    truncated = true
                    break
                }
            } else {
                field.append(character)
            }
        }
        if !truncated, !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        let header = rows.first ?? []
        return Table(header: header, rows: Array(rows.dropFirst()), truncated: truncated)
    }

    private static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { !$0.isNewline }
        let candidates: [Character] = [",", "\t", ";", "|"]
        return candidates.max { lhs, rhs in
            firstLine.filter { $0 == lhs }.count < firstLine.filter { $0 == rhs }.count
        } ?? ","
    }
}

// MARK: - External editors

public enum ExternalEditor {
    /// Arguments that open a file, at a line when given, in a known editor.
    public static func arguments(editor: String, path: String, line: Int?, col: Int?) -> [String] {
        let name = (editor as NSString).lastPathComponent.lowercased()
        var location = path
        if let line {
            location += ":\(line)"
            if let col { location += ":\(col)" }
        }
        switch name {
        case "code", "code-insiders", "cursor", "windsurf", "codium":
            return line == nil ? [path] : ["--goto", location]
        case "zed", "subl", "sublime":
            return [location]
        default:
            return [path]
        }
    }

    /// Where GUI-launched apps don't have the shell's PATH, look here too.
    public static let extraSearchPaths = [
        "/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin",
    ]

    public static func locate(_ editor: String, pathEnv: String?) -> String? {
        if editor.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: editor) ? editor : nil
        }
        let directories = (pathEnv ?? "").split(separator: ":").map(String.init) + extraSearchPaths
        for directory in directories {
            let candidate = directory + "/" + editor
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
