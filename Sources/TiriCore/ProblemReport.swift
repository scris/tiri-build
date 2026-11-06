import Foundation

/// Report a Problem: a new GitHub issue, filled in, that the person reads in their browser and sends themselves.
/// Tiri sends nothing anywhere. What goes in is only what's below: no file names, paths, or anything from a project.
public enum ProblemReport {
    public static let issues = "https://github.com/tiri-build/tiri/issues/new"

    /// The part of a crash report that says where it went wrong. The rest of the file holds identifiers and paths.
    public struct Crash: Equatable, Sendable {
        public var date: Date
        public var version: String
        public var exception: String
        public var frames: [String]
    }

    public struct Facts: Sendable {
        public var version: String
        public var build: String
        public var commit: String
        public var macOS: String
        public var mac: String
        public var agents: [String]
        public var changesOn: Int
        public var crash: Crash?

        public init(version: String, build: String, commit: String, macOS: String, mac: String, agents: [String], changesOn: Int, crash: Crash?) {
            (self.version, self.build, self.commit, self.macOS, self.mac, self.agents, self.changesOn, self.crash) = (version, build, commit, macOS, mac, agents, changesOn, crash)
        }
    }

    public static func body(_ facts: Facts) -> String {
        var text = """
        **What happened**


        **What you expected**


        **Steps to make it happen again**
        1.

        ---
        - Tiri \(facts.version) (\(facts.build), \(facts.commit.prefix(12)))
        - \(facts.macOS), \(facts.mac)
        - Agents: \(facts.agents.isEmpty ? "none" : facts.agents.joined(separator: ", "))
        """
        if facts.changesOn > 0 { text += "\n- Your own changes on: \(facts.changesOn)" }
        if let crash = facts.crash {
            text += "\n\n**Last crash** (\(crash.version), \(crash.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))))\n"
            text += "```\n\(crash.exception)\n" + crash.frames.enumerated().map { "\($0.offset)  \($0.element)" }.joined(separator: "\n") + "\n```"
        }
        return text + "\n"
    }

    public static func issueURL(title: String, body: String) -> URL {
        var components = URLComponents(string: issues)!
        // GitHub turns away very long addresses, and a long body is only ever frames.
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        return components.url!
    }

    public static var crashReports: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// The newest crash of this app or a personal copy of it, after `since` if given.
    public static func latestCrash(bundleID: String, since: Date? = nil, in folder: URL = crashReports) -> Crash? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return nil }
        let files = names.filter { $0.hasPrefix("Tiri") && $0.hasSuffix(".ips") }
            .map { folder.appendingPathComponent($0) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
                if let since, date <= since { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, date) in files.prefix(20) {
            guard let data = try? Data(contentsOf: url), let crash = parse(data, bundleID: bundleID, date: date) else { continue }
            return crash
        }
        return nil
    }

    /// An `.ips` file is a line of JSON about the app, then the report as JSON.
    static func parse(_ data: Data, bundleID: String, date: Date) -> Crash? {
        guard let text = String(data: data, encoding: .utf8), let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              let id = header["bundleID"] as? String, id == bundleID || id == bundleID + ".personal",
              let report = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any] else { return nil }
        let exception = report["exception"] as? [String: Any]
        let termination = report["termination"] as? [String: Any]
        var summary = [exception?["type"] as? String, exception?["signal"] as? String].compactMap { $0 }.joined(separator: " ")
        if summary.isEmpty, let indicator = termination?["indicator"] as? String { summary = indicator }
        var frames: [String] = []
        if let threads = report["threads"] as? [[String: Any]], let faulting = report["faultingThread"] as? Int, threads.indices.contains(faulting),
           let stack = threads[faulting]["frames"] as? [[String: Any]] {
            let images = (report["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
            frames = stack.prefix(12).map { frame in
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                return "\(image)  \(frame["symbol"] as? String ?? "???")"
            }
        }
        return Crash(date: date, version: header["app_version"] as? String ?? "?", exception: summary.isEmpty ? "unknown" : summary, frames: frames)
    }
}
