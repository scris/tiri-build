import Foundation
import Testing
@testable import TiriCore

/// What the seven separate lists said before they became one. These must not drift.
@Suite struct LanguageCatalogTests {
    private func expectComments(_ syntax: CommentSyntax, _ names: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for name in names.split(separator: " ") {
            #expect(CommentSyntax.forFile("/a/b.\(name)") == syntax, "\(name)", sourceLocation: sourceLocation)
        }
    }

    @Test func commentsAreWhatTheyWere() {
        let slashes = CommentSyntax(line: "//", block: ("/*", "*/"))
        let hash = CommentSyntax(line: "#")
        expectComments(slashes, "swift m mm h hpp hh hxx c cc cpp cxx cs java kt kts go rs js jsx mjs cjs ts tsx mts cts scss less php dart scala proto gradle groovy jsonc json5 code-workspace zig v sol glsl metal fs fsx")
        expectComments(hash, "py pyi rb sh bash zsh fish yaml yml toml r pl pm ex exs conf ini env tf tfvars gitignore dockerignore cfg properties mk cmake nim jl ps1 awk sed")
        expectComments(CommentSyntax(line: "--"), "sql lua hs elm ada")
        expectComments(CommentSyntax(block: ("<!--", "-->")), "html htm xml xhtml svg vue svelte md markdown mdx plist")
        expectComments(CommentSyntax(block: ("/*", "*/")), "css")
        expectComments(CommentSyntax(line: ";"), "clj cljs edn lisp el scm asm s")
        expectComments(CommentSyntax(line: "%"), "tex erl hrl")
        for name in "makefile gnumakefile dockerfile gemfile rakefile podfile brewfile cmakelists.txt .zshrc .zprofile .zshenv .bashrc .bash_profile .profile .gitignore .dockerignore .gitattributes .env .editorconfig .npmrc .env.local".split(separator: " ") {
            #expect(CommentSyntax.forFile("/a/\(name)") == hash, "\(name)")
        }
        #expect(CommentSyntax.forFile("/a/b.json") == nil)
        #expect(CommentSyntax.forFile("/a/b.txt") == nil)
    }

    @Test func textIsWhatItWas() {
        for ext in """
        txt text log json jsonc json5 yaml yml toml ini cfg conf env xml plist swift m mm h hpp c cc cpp cs java kt kts go rs py rb php lua \
        js jsx mjs cjs ts tsx css scss less vue svelte sh bash zsh fish sql graphql proto r jl dart scala ex exs erl hs ml clj tex bib rst \
        adoc gradle lock gitignore gitattributes editorconfig dockerfile makefile cmake tf code-workspace patch diff strings pbxproj entitlements xcconfig
        """.split(separator: " ") {
            #expect(FileClassifier.classify(path: "/a/b.\(ext)") == .text, "\(ext)")
        }
        for name in "Makefile Dockerfile LICENSE licence README CHANGELOG AUTHORS COPYING Gemfile Rakefile Podfile Procfile Brewfile .gitignore .gitattributes .env .npmrc .zshrc .bashrc .prettierrc .eslintrc .editorconfig .dockerignore CNAME NOTICE".split(separator: " ") {
            #expect(FileClassifier.classify(path: "/a/\(name)") == .text, "\(name)")
        }
    }

    @Test func aFileNobodyDescribedStillHasItsBytesLookedAt() {
        // A generated language's claim isn't proof: `.ts` can be a video, and `.dat` anything.
        #expect(FileClassifier.classify(path: "/a/b.gleam") == .quickLook)
        #expect(FileClassifier.classify(path: "/a/b.gleam") { Data("pub fn main() {}".utf8) } == .text)
        #expect(FileClassifier.classify(path: "/a/b.gleam") { Data([0, 1, 2]) } == .quickLook)
    }

    @Test func viewersStillWinOverLanguages() {
        #expect(FileClassifier.classify(path: "/a/b.md") == .markdown)
        #expect(FileClassifier.classify(path: "/a/b.html") == .html)
        #expect(FileClassifier.classify(path: "/a/b.svg") == .svg)
        #expect(FileClassifier.classify(path: "/a/b.ipynb") == .notebook)
        #expect(FileClassifier.classify(path: "/a/b.csv") == .csv)
    }

    @Test func familiesAreWhatTheyWere() {
        for (family, names) in [("js", "ts tsx js jsx mjs cjs mts cts vue svelte"), ("c", "c h cc cpp cxx hpp hh m mm"), ("jvm", "kt kts java scala groovy")] {
            for name in names.split(separator: " ") {
                #expect(DefinitionSearch.family(of: "/a/b.\(name)") == family, "\(name)")
            }
        }
        #expect(DefinitionSearch.family(of: "/a/b.py") != DefinitionSearch.family(of: "/a/b.rb"))
        #expect(DefinitionSearch.family(of: "/a/b.unknownthing") == "unknownthing")
    }

    @Test func serversAndTheirLanguageNamesAreWhatTheyWere() {
        let expected: [(String, String, String)] = [
            ("ts", "typescript", "typescript"), ("mts", "typescript", "typescript"), ("tsx", "typescript", "typescriptreact"),
            ("js", "typescript", "javascript"), ("cjs", "typescript", "javascript"), ("jsx", "typescript", "javascriptreact"),
            ("py", "python", "python"), ("rs", "rust", "rust"), ("go", "go", "go"), ("swift", "swift", "swift"),
            ("c", "c", "c"), ("h", "c", "c"), ("m", "c", "objective-c"), ("mm", "c", "objective-cpp"),
            ("cc", "c", "cpp"), ("cpp", "c", "cpp"), ("hpp", "c", "cpp"), ("rb", "ruby", "ruby"), ("lua", "lua", "lua"),
        ]
        for (ext, server, id) in expected {
            let definition = LanguageServerCatalog.definition(for: "/a/b.\(ext)")
            #expect(definition?.id == server, "\(ext)")
            #expect(definition?.languageID(for: "/a/b.\(ext)") == id, "\(ext)")
        }
    }

    @Test func symbolsReadTheRightWay() {
        #expect(SimpleSymbols.scan("# One\ntext\n", path: "/a/b.md").map(\.name) == ["One"])
        #expect(SimpleSymbols.scan("run() {\n}\n", path: "/a/b.sh").map(\.name) == ["run"])
        #expect(SimpleSymbols.scan("all: x\n", path: "/a/Makefile").map(\.name) == ["all"])
        #expect(SimpleSymbols.scan("all: x\n", path: "/a/b.mk").map(\.name) == ["all"])
        #expect(SimpleSymbols.scan("name: x\n", path: "/a/b.yml").map(\.name) == ["name"])
        #expect(SimpleSymbols.scan("[tool]\n", path: "/a/b.toml").map(\.name) == ["tool"])
        #expect(SimpleSymbols.scan(".box {\n}\n", path: "/a/b.css").map(\.name) == [".box"])
        #expect(SimpleSymbols.scan("func go() {}\n", path: "/a/b.swift").map(\.name) == ["go"])
    }

    @Test func aFirstLineCanSay() {
        #expect(LanguageCatalog.language(forPath: "/a/tool", firstLine: "#!/usr/bin/env python3")?.id == "python")
        #expect(LanguageCatalog.language(forPath: "/a/tool", firstLine: "#!/usr/bin/env -S python3 -u")?.id == "python")
        #expect(LanguageCatalog.language(forPath: "/a/tool", firstLine: "#!/bin/zsh")?.id == "shellscript")
        #expect(LanguageCatalog.language(forPath: "/a/tool", firstLine: "hello") == nil)
        #expect(LanguageCatalog.language(forPath: "/a/b.rb", firstLine: "#!/usr/bin/env python3")?.id == "ruby")
    }

    @Test func everythingHasNamesAndAGrammarItCanFind() {
        #expect(LanguageCatalog.all.count > 225)
        #expect(Set(LanguageCatalog.all.map(\.id)).count == LanguageCatalog.all.count)
        #expect(LanguageCatalog.language(named: "py")?.id == "python")
        #expect(LanguageCatalog.language(named: "Python")?.id == "python")
        #expect(LanguageCatalog.language(named: "c++")?.id == "cpp")
        #expect(LanguageCatalog.language(forPath: "/a/b.gleam")?.id == "gleam")
        for language in LanguageCatalog.all where language.server != nil {
            #expect(LanguageServerCatalog.all.contains { $0.id == language.server }, "\(language.id)")
        }
    }

    @Test func aServerSetUpForClaudeCodeWorksHereToo() {
        let servers: [String: Any] = [
            "kotlin": ["command": "kotlin-lsp", "args": ["--stdio"], "extensionToLanguage": [".kt": "kotlin"]],
            "odd": ["command": "odd-server", "extensionToLanguage": [".ODD": "odd"]],
            "broken": ["command": "x"],
        ]
        let found = ClaudeLanguagePlugins.parse(servers, plugin: "p", knownCommands: ["kotlin-lsp"])
        #expect(found.map(\.id) == ["claude-odd"])
        #expect(found.first?.commands == [["odd-server"]])
        #expect(found.first?.languageID(for: "/a/b.odd") == "odd")
    }

    @Test func installableServersPointAtALockThatExists() {
        let locks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/language-servers")
        for server in LanguageServerCatalog.all {
            guard let managed = server.managed else { continue }
            switch managed.tool {
            case .uv: #expect(FileManager.default.fileExists(atPath: locks.appendingPathComponent("\(managed.lock)/requirements.txt").path), "\(server.id)")
            case .npm: #expect(FileManager.default.fileExists(atPath: locks.appendingPathComponent("\(managed.lock)/package-lock.json").path), "\(server.id)")
            case .go: #expect(managed.package != nil, "\(server.id)")
            }
        }
    }
}
