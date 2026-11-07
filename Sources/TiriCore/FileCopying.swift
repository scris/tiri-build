import Foundation

/// Files brought into a folder from Finder or elsewhere in the explorer, pasted or dropped, as
/// VS Code and Finder do it: copies, never moves, and a name that's taken gets " copy".
public enum FileCopying {
    /// `report.pdf`, then `report copy.pdf`, `report copy 2.pdf`. A folder or a name with no
    /// extension gets it at the end, and so does a dotfile: `.env copy`.
    public static func freeName(for name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        // NSString counts a leading dot as part of the name: `.env` has no extension, `.eslintrc.json` has `json`.
        let hasExtension = !ext.isEmpty
        var base = hasExtension ? ns.deletingPathExtension : name
        let suffix = hasExtension ? "." + ext : ""
        var number = 1
        // A copy of a copy counts on, as Finder does: `notes copy.txt` again is `notes copy 2.txt`.
        if let match = base.firstMatch(of: /^(.+) copy(?: (\d+))?$/) {
            base = String(match.1)
            number = match.2.flatMap { Int($0) } ?? 1
        }
        while true {
            let candidate = base + (number == 1 ? " copy" : " copy \(number)") + suffix
            if !taken(candidate) { return candidate }
            number += 1
        }
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        /// A folder can't be copied into itself or anything inside it.
        case intoItself(String)
        case failed(String, String)

        public var description: String {
            switch self {
            case .intoItself(let name): String(localized: "\(name) can't go inside itself.")
            case .failed(let name, let reason): "\(name): \(reason)"
            }
        }
    }

    /// Copies each item into the folder, under a free name. Returns where each one went, in order,
    /// and what couldn't be copied.
    public static func copy(_ sources: [String], into folder: String, fileManager: FileManager = .default) -> (copied: [String], problems: [Problem]) {
        var copied: [String] = []
        var problems: [Problem] = []
        let destination = (folder as NSString).standardizingPath
        for source in sources {
            let path = (source as NSString).standardizingPath
            let name = (path as NSString).lastPathComponent
            if destination == path || destination.hasPrefix(path + "/") {
                problems.append(.intoItself(name))
                continue
            }
            let free = freeName(for: name) { fileManager.fileExists(atPath: (destination as NSString).appendingPathComponent($0)) }
            let target = (destination as NSString).appendingPathComponent(free)
            do {
                try fileManager.copyItem(atPath: path, toPath: target)
                copied.append(target)
            } catch {
                problems.append(.failed(name, error.localizedDescription))
            }
        }
        return (copied, problems)
    }
}
