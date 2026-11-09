import Foundation
import Testing
@testable import TiriCore

@Suite struct AppRulesTests {
    @Test func aKindCoversEveryFileOfIt() {
        #expect(AppRules.matching(path: "/a/b/Poster.psd", in: [".psd"]) == ".psd")
        #expect(AppRules.matching(path: "/a/b/POSTER.PSD", in: [".psd"]) == ".psd")
        #expect(AppRules.matching(path: "/a/site.tar.gz", in: [".tar.gz"]) == ".tar.gz")
        #expect(AppRules.matching(path: "/a/deck.key", in: [".psd", ".key"]) == ".key")
    }

    @Test func onlyThatKind() {
        #expect(AppRules.matching(path: "/a/psd", in: [".psd"]) == nil)
        #expect(AppRules.matching(path: "/a/notes.psdx", in: [".psd"]) == nil)
        #expect(AppRules.matching(path: "/a/x.psd/readme.md", in: [".psd"]) == nil)
        #expect(AppRules.matching(path: "/a/main.swift", in: []) == nil)
    }

    @Test func howeverItWasWritten() {
        #expect(AppRules.tidy("psd") == ".psd")
        #expect(AppRules.tidy(" *.PSD ") == ".psd")
        #expect(AppRules.tidy(".tar.gz") == ".tar.gz")
        #expect(AppRules.tidy("") == nil)
        #expect(AppRules.tidy("*") == nil)
        #expect(AppRules.tidy("src/*.psd") == nil)
        // Kept as written, it still works as a rule.
        #expect(AppRules.matching(path: "/a/b.psd", in: ["*.PSD"]) == "*.PSD")
    }

    @Test func whatIsOffered() {
        #expect(AppRules.kind(of: "/a/Deck.KEY") == ".key")
        #expect(AppRules.kind(of: "/a/Makefile") == nil)
    }

    @Test func settingsKeepThemTidy() throws {
        let parsed = try TiriSettings.parse(#"{"files.openInDefaultApp": ["PSD", "*.key", "", "a/b"]}"#)
        #expect(parsed.filesOpenInDefaultApp == [".psd", ".key"])
        #expect(try TiriSettings.parse("{}").filesOpenInDefaultApp.isEmpty)
    }
}

@Suite struct SignInWallTests {
    private func wall(_ asked: String, _ answered: String? = nil, _ status: Int = 200) -> Bool {
        SignInWall.stands(asked: URL(string: asked)!, answered: URL(string: answered ?? asked)!, status: status)
    }

    @Test func aPrivateRepositoryLooksNotFound() {
        #expect(wall("https://github.com/acme/secret", nil, 404))
        #expect(wall("https://gist.github.com/acme/1", nil, 404))
        #expect(!wall("https://example.com/missing", nil, 404))
    }

    @Test func askedWhoIsThere() {
        #expect(wall("https://example.com/report", nil, 401))
        #expect(!wall("https://example.com/report", nil, 403))
        #expect(!wall("https://example.com/report"))
    }

    @Test func sentToASignIn() {
        #expect(wall("https://github.com/settings/profile", "https://github.com/login?return_to=x"))
        #expect(wall("https://gitlab.com/acme/app", "https://gitlab.com/users/sign_in"))
        #expect(wall("https://docs.google.com/document/d/1", "https://accounts.google.com/v3/signin"))
        // Asked for the sign-in itself: that's what they wanted here.
        #expect(!wall("https://github.com/login"))
        #expect(!wall("https://example.com/loginhelp", "https://example.com/loginhelp"))
    }

    @Test func neverTheirOwnServer() {
        #expect(!wall("http://localhost:3000/admin", nil, 401))
        #expect(!wall("http://127.0.0.1:8080/", "http://127.0.0.1:8080/login"))
    }
}
