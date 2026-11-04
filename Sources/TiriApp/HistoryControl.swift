import Foundation
import TiriCore

/// `tiri changes --branch`, `--commit`, `tiri log`, and diffs of those. Each asks git several
/// things, so they run away from the main thread and the app keeps responding.
extension ControlHandler {
    static func history(_ request: ControlRequest) async -> ControlResponse? {
        switch request.cmd {
        case "changes.branch":
            let folders = await MainActor.run { AppModel.shared.active.folders }
            let found = await Task.detached(priority: .userInitiated) { Git.branchChanges(in: folders) }.value
            return .success(id: request.id, .object([
                "bases": .array(found.bases.map { base in
                    var object: [String: JSONValue] = ["root": .string(base.root), "description": .string(base.description)]
                    if case .found(let name, let commit, _) = base.state {
                        object["base"] = .string(name)
                        object["commit"] = .string(commit)
                    }
                    return .object(object)
                }),
                "changes": list(found.files),
            ]))

        case "changes.commit":
            guard let revision = request.args["commit"]?.stringValue else { return .failure(id: request.id, "Missing argument \"commit\"") }
            let folders = await MainActor.run { AppModel.shared.active.folders }
            let found = await Task.detached(priority: .userInitiated) { () -> (CommitSummary, [ChangedFile])? in
                guard let commit = Git.findCommit(revision, in: folders) else { return nil }
                return (commit, Git.commitChanges(commit.oid, root: commit.root, in: folders))
            }.value
            guard let found else { return .failure(id: request.id, "No commit \(revision) in this workspace's repositories. Run tiri log.") }
            return .success(id: request.id, .object(["commit": describe(found.0), "changes": list(found.1)]))

        case "log":
            let folders = await MainActor.run { AppModel.shared.active.folders }
            let limit = request.args["limit"]?.intValue ?? 30
            let commits = await Task.detached(priority: .userInitiated) { Git.recentCommits(in: folders, limit: limit) }.value
            return .success(id: request.id, .array(commits.map(describe)))

        case "diff":
            let revision = request.args["commit"]?.stringValue
            let branch = request.args["branch"]?.boolValue == true
            guard revision != nil || branch, let rawPath = request.args["path"]?.stringValue else { return nil }
            // A deleted file's path can't be tidied up by looking at it, so it's matched to the workspace's folders.
            let path = await MainActor.run { AppModel.shared.aliasedPath(rawPath) }
            var spec = DiffSpec(path: path, branch: branch)
            if let revision {
                let oid = await Task.detached(priority: .userInitiated) { () -> String? in
                    Git.repositoryRoot(ofFile: path).flatMap { Git.resolveCommit(revision, in: $0) }
                }.value
                guard let oid else { return .failure(id: request.id, "No commit \(revision) in the repository of \(path). Run tiri log.") }
                spec = DiffSpec(path: path, commit: oid)
            }
            let opened = spec
            await MainActor.run {
                if request.args["mode"]?.stringValue == "tab" {
                    AppModel.shared.openDiff(opened, preview: false)
                } else {
                    AppModel.shared.peekDiff(opened, takeFocus: false)
                }
            }
            return .success(id: request.id, .object([:]))

        default:
            return nil
        }
    }

    private static func list(_ files: [ChangedFile]) -> JSONValue {
        .array(files.map { file in
            var object: [String: JSONValue] = ["status": .string(file.status.letter), "path": .string(file.path)]
            if let old = file.oldRelative { object["old"] = .string(old) }
            return .object(object)
        })
    }

    private static func describe(_ commit: CommitSummary) -> JSONValue {
        .object(["hash": .string(commit.oid), "short": .string(commit.shortOID), "subject": .string(commit.subject),
                 "author": .string(commit.author), "when": .string(RelativeTime.text(commit.date)),
                 "date": .string(ISO8601DateFormatter().string(from: commit.date)), "root": .string(commit.root),
                 "parents": .array(commit.parents.map(JSONValue.string))])
    }
}
