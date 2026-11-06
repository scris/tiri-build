import Foundation
import Testing
@testable import TiriCore

@Suite struct ProblemReportTests {
    private func ips(bundle: String) -> Data {
        let header = #"{"app_name":"Tiri","app_version":"0.1.0","bundleID":"\#(bundle)","incident_id":"X"}"#
        let report = #"""
        {"crashReporterKey":"SECRET-KEY","procPath":"/Users/someone/Applications/Tiri.app",
         "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":1,
         "usedImages":[{"name":"Tiri"},{"name":"libdispatch.dylib"}],
         "threads":[{"frames":[{"imageIndex":1,"symbol":"other"}]},
                    {"frames":[{"imageIndex":0,"symbol":"HandOff.watch(_:)"},{"imageIndex":1,"symbol":"_dispatch_call_block"}]}]}
        """#
        return Data((header + "\n" + report).utf8)
    }

    @Test func aCrashIsOnlyWhereItWentWrong() throws {
        let crash = try #require(ProblemReport.parse(ips(bundle: "dev.tiri.app.personal"), bundleID: "dev.tiri.app", date: Date()))
        #expect(crash.exception == "EXC_BREAKPOINT SIGTRAP")
        #expect(crash.frames == ["Tiri  HandOff.watch(_:)", "libdispatch.dylib  _dispatch_call_block"])
        #expect(ProblemReport.parse(ips(bundle: "com.other.app"), bundleID: "dev.tiri.app", date: Date()) == nil)
        let body = ProblemReport.body(.init(version: "0.1.0", build: "7", commit: "abc", macOS: "macOS 26.1", mac: "Apple M4",
                                            agents: ["Claude Code"], changesOn: 2, crash: crash))
        // Identifiers and paths in the report never reach the issue.
        #expect(!body.contains("SECRET-KEY") && !body.contains("/Users/someone"))
        #expect(body.contains("Your own changes on: 2") && body.contains("HandOff.watch"))
    }

    @Test func theNewestOfThisAppSinceTheLastLook() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-ips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("Tiri-old.ips"), new = folder.appendingPathComponent("Tiri-new.ips")
        try ips(bundle: "dev.tiri.app").write(to: old)
        try ips(bundle: "dev.tiri.app").write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        #expect(ProblemReport.latestCrash(bundleID: "dev.tiri.app", since: Date(timeIntervalSinceNow: -60), in: folder) != nil)
        #expect(ProblemReport.latestCrash(bundleID: "dev.tiri.app", since: Date(), in: folder) == nil)
    }

    @Test func anIssueAddressStaysShortEnoughForGitHub() {
        let url = ProblemReport.issueURL(title: "Crash", body: String(repeating: "frame\n", count: 5000))
        #expect(url.absoluteString.hasPrefix("https://github.com/tiri-build/tiri/issues/new?title=Crash&body="))
        #expect(url.absoluteString.count < 8200)
    }
}
