import CryptoKit
import Foundation

/// One kept change as a file for someone else's Tiri: `git format-patch` of its commit, its check and trailers
/// included, with the Tiri it was made on and a digest. It's plain text a person or their agent can read. The digest
/// shows it arrived whole. Who it says it's from, nothing can show.
///
/// It's a deliberate way in, by file only: no link, no gallery. It arrives off, and turning it on is the same
/// build, Try It and Keep or Back as any change of their own.
public struct SharedChange: Equatable, Sendable {
    public static let fileExtension = "tirichange"
    static let releaseHeader = "X-Tiri-Release"
    static let digestHeader = "X-Tiri-Digest"

    public struct File: Equatable, Sendable {
        public var path: String
        public var added: Int
        public var removed: Int
    }

    /// The whole file, as it came.
    public var text: String
    public var sentence: String
    public var id: String
    public var surface: String?
    /// Who it says it's from, and the address beside it. Unverified.
    public var from: String?
    var fromEmail: String
    /// The version of Tiri it was made on, and the commit of Tiri's own source, when the file says.
    public var madeOn: String?
    public var madeOnCommit: String?
    public var files: [File]
    public var digest: String

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
    public var hasCheck: Bool { files.contains { $0.path == "checks/\(id).sh" } }
    public var size: String { PersonalChange.size(files: files.count, lines: added + removed) }

    // MARK: Reading one

    public static func read(_ url: URL) throws -> SharedChange {
        guard let data = try? Data(contentsOf: url) else { throw ChangeFailure(String(localized: "There's nothing at \(url.path).")) }
        guard data.count < 16 << 20, let text = String(data: data, encoding: .utf8) else { throw ChangeFailure(String(localized: "That isn't a shared change.")) }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> SharedChange {
        let notOne = ChangeFailure(String(localized: "That isn't a shared change."))
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, isMessageStart(first), let blank = lines.firstIndex(of: "") else { throw notOne }
        // One change, never several: format-patch starts each with a line like the first.
        guard !lines.dropFirst().contains(where: isMessageStart) else { throw notOne }
        let header = lines[..<blank]
        func value(_ key: String) -> String? {
            header.first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
        }
        guard let stated = value(digestHeader), stated.hasPrefix("sha256:") else { throw notOne }
        let digestLine = "\(digestHeader): \(stated)\n"
        guard let range = text.range(of: digestLine) else { throw notOne }
        var unsigned = text
        unsigned.removeSubrange(range)
        guard digest(of: unsigned) == String(stated.dropFirst("sha256:".count)) else {
            throw ChangeFailure(String(localized: "It changed after it was shared, so it can't be added."))
        }

        // Git reads the rest, as `git am` will: folded and encoded headers, the message, the diff.
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("tirichange-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        let file = place.appendingPathComponent("in.patch")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let info = Tool.run("/bin/sh", ["-c", "exec /usr/bin/git mailinfo msg patch < in.patch"], in: place)
        guard info.ok else { throw notOne }
        var fields: [String: String] = [:]
        for line in info.output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let message = (try? String(contentsOf: place.appendingPathComponent("msg"), encoding: .utf8)) ?? ""
        func trailer(_ key: String) -> String? {
            message.split(separator: "\n").last { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
        }
        let numstat = Tool.run("/usr/bin/git", ["apply", "--numstat", "patch"], in: place)
        guard numstat.ok else { throw notOne }
        let files = numstat.output.split(separator: "\n").compactMap { line -> File? in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return File(path: String(parts[2]), added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
        guard let sentence = fields["Subject"], !sentence.isEmpty, !files.isEmpty else { throw notOne }
        let release = value(releaseHeader)?.split(separator: " ").map(String.init) ?? []
        let author = fields["Author"].flatMap { $0.isEmpty ? nil : $0 }
        return SharedChange(text: text, sentence: sentence, id: trailer("Tiri-Change") ?? "", surface: trailer("Tiri-Surface"),
                            from: author == SourceRepo.ownName ? nil : author, fromEmail: fields["Email"] ?? "",
                            madeOn: release.first, madeOnCommit: release.count > 1 ? release[1] : nil, files: files,
                            digest: String(stated.dropFirst("sha256:".count)))
    }

    /// `From <commit> Mon Sep 17 00:00:00 2001`, which is how format-patch begins each one.
    private static func isMessageStart(_ line: String) -> Bool {
        line.hasPrefix("From ") && line.hasSuffix(" Mon Sep 17 00:00:00 2001")
    }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Ids name refs and files, so one from a file is used only if it's plainly an id.
    static func isUsableID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: Making one

    /// Its first few words, since that's how someone will know the file.
    public static func fileName(for change: PersonalChange) -> String { fileName(sentence: change.sentence, id: change.id) }

    public static func fileName(sentence: String, id: String) -> String {
        let words = sentence.lowercased().split { !($0.isLetter || $0.isNumber) }.prefix(6)
        var name = String(words.joined(separator: "-").prefix(48))
        while name.hasSuffix("-") { name.removeLast() }
        return (name.isEmpty ? id : name) + "." + fileExtension
    }

    /// Who it says it's from: the name in Git, which is what people sign their work with, or this Mac's.
    public static func sender(repo: SourceRepo = SourceRepo()) -> (name: String, email: String) {
        // A name only: sharing a change shouldn't hand out an email address.
        let name = (try? repo.text(["config", "--global", "user.name"])) ?? ""
        return (name.isEmpty ? NSFullUserName() : name, "")
    }

    /// The Tiri a change was made on: the release it sits on, and the commit of Tiri's own source when that's the
    /// one installed now.
    static func madeOn(_ change: PersonalChange, repo: SourceRepo) throws -> (version: String, commit: String?) {
        let base = try repo.text(["merge-base", change.commit, "release"])
        let subject = try repo.text(["log", "-1", "--format=%s", base])
        let version = subject.hasPrefix("Tiri ") ? String(subject.dropFirst("Tiri ".count)) : ""
        guard base == (try? repo.releaseCommit()), let plain = CopyState.load()?.plainPath, CopyState.load()?.plainVersion == version,
              let commit = Bundle(path: plain)?.object(forInfoDictionaryKey: YourTiri.commitKey) as? String, !commit.isEmpty else { return (version, nil) }
        return (version, commit)
    }

    /// The change's commit and nothing else: its diff, its check, its sentence and trailers. Written as from `sender`.
    @discardableResult
    public static func export(_ change: PersonalChange, in repo: SourceRepo, to file: URL,
                              sender named: (name: String, email: String)? = nil, release stated: (version: String, commit: String?)? = nil) throws -> SharedChange {
        guard !change.needsRedo else { throw ChangeFailure(String(localized: "“\(change.sentence)” has to be redone before it can be shared.")) }
        let sender = named ?? Self.sender(repo: repo)
        let release = try stated ?? madeOn(change, repo: repo)
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("tirichange-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        // The same tree, parent and message, under the name it's shared as. Nothing points at it afterwards.
        let message = place.appendingPathComponent("message")
        try repo.text(["log", "-1", "--format=%B", change.commit]).write(to: message, atomically: true, encoding: .utf8)
        let date = try repo.text(["log", "-1", "--format=%aI", change.commit])
        let named = try repo.text(["commit-tree", change.commit + "^{tree}", "-p", change.commit + "^", "-F", message.path],
                                  environment: ["GIT_AUTHOR_NAME": sender.name, "GIT_AUTHOR_EMAIL": sender.email, "GIT_AUTHOR_DATE": date])
        let out = place.appendingPathComponent("out.patch")
        let header = "\(releaseHeader): \(release.version)\(release.commit.map { " \($0)" } ?? "")"
        try repo.git(["-c", "format.encodeEmailHeaders=false", "format-patch", "-1", "--no-signature", "--zero-commit", "--binary",
                      "--add-header", header, "--output", out.path, named], check: true)
        let made = try String(contentsOf: out, encoding: .utf8)
        guard let end = made.range(of: "\n\n") else { throw ChangeFailure("Git wrote something unexpected.") }
        var text = made
        text.insert(contentsOf: "\n\(digestHeader): sha256:\(digest(of: made))", at: end.lowerBound)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        return try parse(text)
    }
}

/// A shared change put on this release, or found not to go on, before anyone has said Add.
public struct StagedShare: Equatable, Sendable {
    public var shared: SharedChange
    /// Its own id, or a new one when that's taken here.
    public var id: String
    /// Nil when it doesn't go on this release, and has to be redone.
    public var commit: String?
    /// What it would be in the list, for See What Changed.
    public var preview: PersonalChange?

    public var fits: Bool { commit != nil }
}

extension SourceRepo {
    static let ownName = "Your Tiri"
    static let trailerRedo = "Tiri-Redo"

    func text(_ arguments: [String], environment: [String: String]) throws -> String {
        let result = Tool.run("/usr/bin/git", arguments, in: folder,
                              environment: ["GIT_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"].merging(environment) { _, new in new })
        guard result.ok else { throw ChangeFailure("git \(arguments.first ?? "") failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same change already here: the same diff, or for one that has to be redone, the same file.
    public func alreadyHas(_ shared: SharedChange) throws -> PersonalChange? {
        let incoming = try patchID(ofText: shared.text)
        for change in try changes() {
            if change.needsRedo {
                if let kept = sharedText(of: change), (try? SharedChange.parse(kept))?.digest == shared.digest { return change }
            } else if let id = try? patchID(of: change.commit), id == incoming, !id.isEmpty {
                return change
            }
        }
        return nil
    }

    private func patchID(ofText text: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tirichange-\(UUID().uuidString.prefix(8)).patch")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return Tool.shell("/usr/bin/git patch-id --stable < \(ShellQuote.quote(file.path))", in: folder).output.split(separator: " ").first.map(String.init) ?? ""
    }

    private func patchID(of commit: String) throws -> String {
        guard commit.allSatisfy(\.isHexDigit) else { return "" }
        return Tool.shell("/usr/bin/git show --format= --binary \(commit) | /usr/bin/git patch-id --stable", in: folder).output.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Onto `release` in a worktree of its own, so nothing anyone is working on moves. `git am` with three-way
    /// merging, as people apply each other's patches. Nothing builds and nothing in it runs.
    public func stage(_ shared: SharedChange, alsoTaken: [String] = []) throws -> StagedShare {
        let taken = Set(try changes().map(\.id) + alsoTaken)
        let id = SharedChange.isUsableID(shared.id) && !taken.contains(shared.id) ? shared.id : ChangeTools.newID()
        let place = folder.deletingLastPathComponent().appendingPathComponent("sharing-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let patch = place.appendingPathExtension("patch")
        try shared.text.write(to: patch, atomically: true, encoding: .utf8)
        defer {
            _ = try? git(["worktree", "remove", "--force", place.path])
            try? FileManager.default.removeItem(at: place)
            try? FileManager.default.removeItem(at: patch)
            _ = try? git(["worktree", "prune"])
        }
        try git(["worktree", "add", "-q", "--detach", place.path, "release"], check: true)
        let there = SourceRepo(folder: place)
        guard (try? there.text(["am", "-q", "--3way", "--ignore-date", patch.path], environment: [:])) != nil else {
            _ = try? there.git(["am", "--abort"])
            return StagedShare(shared: shared, id: id, commit: nil, preview: nil)
        }
        // Its own id here, its check under that id, and nothing about repairs on someone else's Mac.
        let old = try there.text(["log", "-1", "--format=%B", "HEAD"])
        let message = Self.arrivedMessage(old, id: id)
        if id != shared.id, FileManager.default.fileExists(atPath: place.appendingPathComponent("checks/\(shared.id).sh").path), SharedChange.isUsableID(shared.id) {
            try there.git(["mv", "checks/\(shared.id).sh", "checks/\(id).sh"], check: true)
        }
        if message != old.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" || !there.isClean {
            let file = place.appendingPathExtension("message")
            try message.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            try there.git(["commit", "-q", "--amend", "--allow-empty", "-F", file.path], check: true)
        }
        let commit = try there.text(["rev-parse", "HEAD"])
        let preview = try change(commit: commit, isOn: false, checks: [])
        return StagedShare(shared: shared, id: id, commit: commit, preview: preview)
    }

    static func arrivedMessage(_ old: String, id: String) -> String {
        var lines = old.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").filter { !$0.hasPrefix("Tiri-Repair") }
        if let index = lines.firstIndex(where: { $0.hasPrefix("Tiri-Change: ") }) {
            lines[index] = "Tiri-Change: \(id)"
        } else {
            lines += lines.count == 1 ? ["", "Tiri-Change: \(id)"] : ["Tiri-Change: \(id)"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// In the list, off. One that doesn't fit is kept as its words on this release, needing to be redone, with the
    /// file beside it for whoever redoes it.
    @discardableResult
    public func add(_ staged: StagedShare) throws -> PersonalChange {
        if let commit = staged.commit {
            try git(["update-ref", "refs/tiri/off/\(staged.id)", commit, ""], check: true)
            return try change(named: staged.id)
        }
        let shared = staged.shared
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("tirichange-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        var message = commitMessage(sentence: shared.sentence, id: staged.id, surface: shared.surface)
        message += "\(Self.trailerRedo): \(shared.madeOn.map { $0.isEmpty ? "another version" : $0 } ?? "another version")\n"
        let messageFile = place.appendingPathComponent("message")
        try message.write(to: messageFile, atomically: true, encoding: .utf8)
        let commit = try text(["commit-tree", "release^{tree}", "-p", "release", "-F", messageFile.path],
                              environment: ["GIT_AUTHOR_NAME": shared.from ?? Self.ownName, "GIT_AUTHOR_EMAIL": shared.fromEmail])
        let textFile = place.appendingPathComponent("shared.patch")
        try shared.text.write(to: textFile, atomically: true, encoding: .utf8)
        let blob = try text(["hash-object", "-w", textFile.path])
        try git(["update-ref", "refs/tiri/shared/\(staged.id)", blob], check: true)
        try git(["update-ref", "refs/tiri/off/\(staged.id)", commit, ""], check: true)
        return try change(named: staged.id)
    }

    /// The file a change that has to be redone came in.
    public func sharedText(of change: PersonalChange) -> String? {
        guard SharedChange.isUsableID(change.id) else { return nil }
        return try? git(["cat-file", "blob", "refs/tiri/shared/\(change.id)"], check: true).output
    }

    /// Beside the source, where an agent can read it, and where Git doesn't count it as part of anything.
    public func writeSharedText(of change: PersonalChange) throws -> URL? {
        guard let text = sharedText(of: change) else { return nil }
        let file = folder.appendingPathComponent(".tiri-shared-\(change.id).patch")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let exclude = folder.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !existing.contains(".tiri-") {
            try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (existing + "\n.tiri-*\n").write(to: exclude, atomically: true, encoding: .utf8)
        }
        return file
    }

    /// As much of their diff as goes on, into the working files, conflicts marked. What's said is for the agent.
    func beginRedo(_ change: PersonalChange) throws -> String {
        guard let file = try writeSharedText(of: change) else { return "There's no diff kept for it. Make it from the sentence.\n" }
        let applied = try git(["apply", "--3way", "--whitespace=nowarn", file.path])
        let conflicted = try !text(["diff", "--name-only", "--diff-filter=U"]).isEmpty
        let said = isClean ? "None of it goes on here, so make it from their diff."
            : conflicted || !applied.ok ? "Some of it is in your working files, with conflicts marked."
            : "It goes on now, and may only need adapting. It's in your working files."
        return "\(said) Their diff is \(file.path):\n\n" + (sharedText(of: change) ?? "")
    }

    /// When its redo is ready, the file it came in has done its work.
    func finishRedo(id: String) {
        guard SharedChange.isUsableID(id) else { return }
        _ = try? git(["update-ref", "-d", "refs/tiri/shared/\(id)"])
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".tiri-shared-\(id).patch"))
    }
}

extension ChangeTools {
    /// To a file, or into a folder under its own name.
    static func share(_ id: String, to path: String) throws -> String {
        let repo = SourceRepo()
        guard repo.exists else { throw ChangeFailure("There are no changes to share yet.") }
        let change = try repo.change(named: id)
        let name = SharedChange.fileName(for: change)
        var file = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue { file.appendPathComponent(name) }
        let shared = try SharedChange.export(change, in: repo, to: file)
        return "Wrote \(file.path): “\(shared.sentence)”, \(shared.size)\(shared.hasCheck ? ", with its check" : ", no check"), made on Tiri \(shared.madeOn ?? "?"). It holds this change and nothing else.\n"
    }

    static func importShared(_ path: String) throws -> String {
        let state = try facts()
        let repo = SourceRepo()
        let app = URL(fileURLWithPath: state.plainPath ?? "")
        try repo.prepare(archive: app.appendingPathComponent("Contents/Resources").appendingPathComponent(YourTiri.sourceArchive), version: state.plainVersion ?? "",
                         changeUnderway: loadDraft() != nil)
        let shared = try SharedChange.read(URL(fileURLWithPath: path))
        if let have = try repo.alreadyHas(shared) { return "Already here: \(have.id) “\(have.sentence)”, \(have.isOn ? "on" : "off").\n" }
        let staged = try repo.stage(shared, alsoTaken: loadDraft().map { [$0.id] } ?? [])
        let change = try repo.add(staged)
        tellTheApp()
        var text = "Added \(change.id) “\(change.sentence)”, off."
        if let from = shared.from { text += " It says it's from \(from), which nothing checks." }
        if staged.fits {
            text += " \(change.size)\(change.hasCheck ? ", with a check" : ", no check"). Nothing runs until it's on: tiri change show \(change.id) for its diff, tiri change on \(change.id) to build a copy with it for the person to try.\n"
        } else {
            text += " It was made on Tiri \(shared.madeOn ?? "?") and doesn't go on this one, so it has to be redone: tiri change revise \(change.id) puts what fits into the source and shows their diff.\n"
        }
        return text
    }
}
