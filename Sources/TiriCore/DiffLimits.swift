import Foundation

/// How big a diff Tiri shows, like VS Code's diff limits. Past them the viewer says the file is too
/// large instead of reading and laying out more than anyone could look through.
extension Git {
    /// Past this much output, git is stopped.
    public static let largestDiffOutput = 8 * 1024 * 1024
    /// A file bigger than this, on either side, isn't compared at all.
    public static let largestDiffedFile = 50 * 1024 * 1024

    /// Whether either side of a file is too big to compare: its copy at each revision, and the working
    /// copy if that's one side. Asked before running the diff, as `blob` asks before reading a version.
    static func tooLargeToDiff(root: String, relatives: [String], revisions: [String], workingCopy: String?) -> Bool {
        if let workingCopy, RemoteRegistry.shared.connection(forLocal: workingCopy) == nil,
           let size = (try? FileManager.default.attributesOfItem(atPath: workingCopy))?[.size] as? Int, size > largestDiffedFile {
            return true
        }
        for revision in revisions {
            for relative in relatives {
                guard let result = runGit(["cat-file", "-s", revision + ":" + relative], in: root), result.status == 0,
                      let size = Int(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                if size > largestDiffedFile { return true }
            }
        }
        return false
    }
}

extension FileDiff {
    public static var tooLarge: FileDiff {
        var diff = FileDiff()
        diff.isTooLarge = true
        return diff
    }
}
