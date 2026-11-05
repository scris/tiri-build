import Foundation
import Testing
@testable import TiriCore

@Suite struct BrowserRulesTests {
    private func rule(_ address: String, _ rules: [String]) -> String? {
        BrowserRules.matching(URL(string: address)!, in: rules)
    }

    @Test func aSiteCoversAllOfIt() {
        #expect(rule("https://github.com/RinkaSnow/PTTS-Main/pull/113", ["github.com"]) == "github.com")
        #expect(rule("https://www.github.com/", ["github.com"]) == "github.com")
        #expect(rule("https://gist.github.com/x", ["github.com"]) == "github.com")
        #expect(rule("http://GitHub.com", ["github.com"]) == "github.com")
    }

    @Test func onlyThatSite() {
        #expect(rule("https://notgithub.com/", ["github.com"]) == nil)
        #expect(rule("https://github.com.evil.example/", ["github.com"]) == nil)
        #expect(rule("http://localhost:3000/", ["github.com"]) == nil)
    }

    @Test func onePlaceOnASite() {
        let rules = ["github.com/acme"]
        #expect(rule("https://github.com/acme", rules) == "github.com/acme")
        #expect(rule("https://github.com/acme/app/pull/1", rules) == "github.com/acme")
        #expect(rule("https://github.com/Acme/app", rules) == "github.com/acme")
        #expect(rule("https://github.com/acmeco", rules) == nil)
        #expect(rule("https://github.com/", rules) == nil)
    }

    @Test func aStarCoversItsParts() {
        #expect(rule("https://docs.google.com/d/1", ["*.google.com"]) == "*.google.com")
        #expect(rule("https://google.com", ["*.google.com"]) == "*.google.com")
    }

    @Test func onlyWebAddresses() {
        #expect(rule("file:///Users/me/github.com/index.html", ["github.com"]) == nil)
        #expect(BrowserRules.site(of: URL(fileURLWithPath: "/tmp/a.html")) == nil)
    }

    @Test func whatIsOfferedAndKept() {
        #expect(BrowserRules.site(of: URL(string: "https://www.GitHub.com/a/b")!) == "github.com")
        #expect(BrowserRules.tidy(" https://www.github.com/acme/ ") == "github.com/acme")
        #expect(BrowserRules.tidy("github.com/*") == "github.com")
        #expect(BrowserRules.tidy("user@example.com:8080") == "example.com")
        #expect(BrowserRules.tidy("   ") == nil)
        // Pasted as an address, it still works as a rule.
        #expect(rule("https://github.com/x", ["https://github.com/"]) == "https://github.com/")
    }

    @Test func settingsKeepThemTidy() throws {
        let parsed = try TiriSettings.parse(#"{"web.openInBrowser": ["https://www.github.com/", "", "linear.app"]}"#)
        #expect(parsed.webOpenInBrowser == ["github.com", "linear.app"])
        #expect(try TiriSettings.parse("{}").webOpenInBrowser.isEmpty)
    }
}
