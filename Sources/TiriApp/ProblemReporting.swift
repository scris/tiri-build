import AppKit
import SwiftUI
import TiriCore

/// Report a Problem opens a GitHub issue in the browser, filled in. Nothing is sent until the person sends it there.
extension AppModel {
    /// The plain app's ID, which a personal copy's crashes are filed under too.
    static var reportBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? "dev.tiri.app"
        return id.hasSuffix(".personal") ? String(id.dropLast(".personal".count)) : id
    }

    func problemFacts(crash: ProblemReport.Crash?) -> ProblemReport.Facts {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = ProcessInfo.processInfo.operatingSystemVersionString.split(separator: "Build ").last.map { String($0.dropLast()) } ?? ""
        return ProblemReport.Facts(
            version: YourTiriModel.version, build: info["CFBundleVersion"] as? String ?? "?",
            commit: info[YourTiri.commitKey] as? String ?? "unknown",
            macOS: "macOS \(os.majorVersion).\(os.minorVersion)\(os.patchVersion > 0 ? ".\(os.patchVersion)" : "")\(build.isEmpty ? "" : " (\(build))")",
            mac: [Self.sysctl("machdep.cpu.brand_string"), Self.sysctl("hw.model")].compactMap { $0 }.joined(separator: ", "),
            agents: agentPresets().map(\.name), changesOn: yourTiri.changes.filter(\.isOn).count, crash: crash)
    }

    func reportProblem(crash: ProblemReport.Crash? = nil, title: String = "") {
        // A crash in the last week is likely what they're reporting.
        let crash = crash ?? ProblemReport.latestCrash(bundleID: Self.reportBundleID, since: Date().addingTimeInterval(-7 * 86400))
        NSWorkspace.shared.open(ProblemReport.issueURL(title: title, body: ProblemReport.body(problemFacts(crash: crash))))
    }

    /// At launch: if Tiri crashed since it last looked, offer to report it, once.
    func offerCrashReport() {
        let key = "ProblemReport.lookedForCrashes"
        let defaults = UserDefaults.standard
        let since = defaults.object(forKey: key) as? Date
        defaults.set(Date(), forKey: key)
        // The first launch has nothing of its own to report.
        guard let since else { return }
        let bundleID = Self.reportBundleID
        Task.detached(priority: .utility) {
            // macOS writes the report a moment after the crash, which can be after a quick relaunch.
            try? await Task.sleep(for: .seconds(3))
            guard let crash = ProblemReport.latestCrash(bundleID: bundleID, since: since) else { return }
            await MainActor.run { [weak self] in
                _ = self?.showToast(title: "Tiri closed unexpectedly", detail: "You can tell us what happened, on GitHub.", symbol: "exclamationmark.bubble",
                                    tint: .orange, actionTitle: "Report", duration: 20) { [weak self] in
                    self?.reportProblem(crash: crash, title: "Crash: \(crash.exception)")
                }
            }
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
