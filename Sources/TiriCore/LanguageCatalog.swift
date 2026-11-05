import Foundation

/// Everything Tiri knows about one language.
///
/// **To support another language, add one entry to `LanguageCatalog.curated`.** Telling files
/// apart, colors, comments, language servers, finding definitions, a file's outline and its icon
/// all read from here. Most languages need no entry: `GeneratedLanguages.swift` already has them.
public struct LanguageDefinition: Sendable, Identifiable {
    /// How the outline reads a file when no server can say what's in it.
    public enum SymbolStyle: Sendable { case code, shell, make, keys, sections, stylesheet, headings }
    public enum IconStyle: Sendable { case code, data, prose }

    public var id: String
    public var name: String
    /// The TextMate grammar's scope. Nil means it gets no colors.
    public var grammar: String?
    public var extensions: Set<String>
    /// Lowercase.
    public var fileNames: Set<String>
    /// What a `#!` line names.
    public var interpreters: Set<String>
    /// What a code fence or a notebook might call it.
    public var aliases: Set<String>
    /// Nil when this kind of file has no comments, like JSON or plain text.
    public var comment: CommentSyntax?
    /// The id in `LanguageServerCatalog`.
    public var server: String?
    /// What language servers call it, when that isn't the id.
    public var lspID: String?
    public var colonOpensBlock = false
    /// Languages that can call each other. A definition in another family is only a last resort.
    public var family: String?
    public var symbols = SymbolStyle.code
    public var icon = IconStyle.code
    /// Whether words here are prose, so a list shouldn't pop up while you write them.
    public var isProse = false
    /// Certainly text, so the file's bytes don't need a look before opening it as text.
    public var isCertainlyText = false

    public var languageServerID: String { lspID ?? id }
    public var familyName: String { family ?? id }
}

public enum LanguageCatalog {
    private static let slashes = CommentSyntax(line: "//", block: ("/*", "*/"))
    private static let hash = CommentSyntax(line: "#")
    private static let dashes = CommentSyntax(line: "--")
    private static let markup = CommentSyntax(block: ("<!--", "-->"))
    private static let cStyleBlock = CommentSyntax(block: ("/*", "*/"))
    private static let semicolon = CommentSyntax(line: ";")
    private static let percent = CommentSyntax(line: "%")

    /// What's said about a generated language, or a whole language of its own.
    struct Entry {
        enum Comment { case fromGrammar, none, given(CommentSyntax) }
        var id: String
        var name: String?
        var grammar: String?
        var noGrammar = false
        var extensions: String = ""
        var fileNames: String = ""
        var interpreters: String = ""
        var aliases: String = ""
        var comment = Comment.fromGrammar
        var server: String?
        var lspID: String?
        var colon = false
        var family: String?
        var symbols = LanguageDefinition.SymbolStyle.code
        var icon = LanguageDefinition.IconStyle.code
        var prose = false
    }

    private static let config = "source.tiri-config"

    /// The languages Tiri has something particular to say about. Their extensions win over any
    /// generated language's claim, and each counts as text without looking at the file.
    static let curated: [Entry] = [
        Entry(id: "swift", extensions: "swift", comment: .given(slashes), server: "swift"),
        Entry(id: "objective-c", extensions: "m", comment: .given(slashes), server: "c", family: "c"),
        Entry(id: "objective-cpp", extensions: "mm", comment: .given(slashes), server: "c", family: "c"),
        Entry(id: "c", extensions: "c h", comment: .given(slashes), server: "c", family: "c"),
        Entry(id: "cpp", extensions: "cc cpp cxx hpp hh hxx", comment: .given(slashes), server: "c", family: "c"),
        Entry(id: "csharp", extensions: "cs", comment: .given(slashes), server: "csharp"),
        Entry(id: "java", extensions: "java", comment: .given(slashes), server: "java", family: "jvm"),
        Entry(id: "kotlin", extensions: "kt kts", comment: .given(slashes), server: "kotlin", family: "jvm"),
        Entry(id: "scala", extensions: "scala", comment: .given(slashes), server: "scala", family: "jvm"),
        Entry(id: "groovy", extensions: "gradle groovy", comment: .given(slashes), family: "jvm"),
        Entry(id: "go", extensions: "go", comment: .given(slashes), server: "go"),
        Entry(id: "rust", extensions: "rs", comment: .given(slashes), server: "rust"),
        Entry(id: "javascript", extensions: "js mjs cjs", comment: .given(slashes), server: "typescript", family: "js"),
        Entry(id: "jsx", extensions: "jsx", comment: .given(slashes), server: "typescript", lspID: "javascriptreact", family: "js"),
        Entry(id: "typescript", extensions: "ts mts cts", comment: .given(slashes), server: "typescript", family: "js"),
        Entry(id: "tsx", extensions: "tsx", comment: .given(slashes), server: "typescript", lspID: "typescriptreact", family: "js"),
        Entry(id: "vue", extensions: "vue", comment: .given(markup), server: "vue", family: "js"),
        Entry(id: "svelte", extensions: "svelte", comment: .given(markup), server: "svelte", family: "js"),
        Entry(id: "scss", extensions: "scss", comment: .given(slashes), server: "css", symbols: .stylesheet),
        Entry(id: "less", extensions: "less", comment: .given(slashes), server: "css", symbols: .stylesheet),
        Entry(id: "css", extensions: "css", comment: .given(cStyleBlock), server: "css", symbols: .stylesheet),
        Entry(id: "php", extensions: "php", comment: .given(slashes), server: "php"),
        Entry(id: "dart", extensions: "dart", comment: .given(slashes), server: "dart"),
        Entry(id: "proto", extensions: "proto", comment: .given(slashes)),
        Entry(id: "zig", extensions: "zig", comment: .given(slashes), server: "zig"),
        Entry(id: "v", extensions: "v", comment: .given(slashes)),
        Entry(id: "solidity", extensions: "sol", comment: .given(slashes)),
        Entry(id: "glsl", name: "GLSL", grammar: "source.cpp", extensions: "glsl", comment: .given(slashes)),
        Entry(id: "metal", name: "Metal", grammar: "source.cpp", extensions: "metal", comment: .given(slashes)),
        Entry(id: "fsharp", extensions: "fs fsx", comment: .given(slashes)),
        Entry(id: "json", extensions: "json", comment: .none, server: "json", symbols: .keys, icon: .data),
        Entry(id: "jsonc", extensions: "jsonc code-workspace", comment: .given(slashes), server: "json", symbols: .keys, icon: .data),
        Entry(id: "json5", extensions: "json5", comment: .given(slashes), icon: .data),
        Entry(id: "tool-settings", name: "Tool settings", grammar: "source.json.comments", fileNames: ".prettierrc .eslintrc", comment: .none, icon: .data),

        Entry(id: "python", extensions: "py pyi", interpreters: "python python2 python3 pypy pypy3", comment: .given(hash), server: "python", colon: true),
        Entry(id: "ruby", extensions: "rb", fileNames: "gemfile rakefile podfile brewfile", comment: .given(hash), server: "ruby"),
        Entry(id: "shellscript", extensions: "sh bash zsh",
              fileNames: ".zshrc .zprofile .zshenv .bashrc .bash_profile .profile", interpreters: "sh bash zsh dash ksh",
              comment: .given(hash), server: "bash", symbols: .shell),
        Entry(id: "fish", extensions: "fish", interpreters: "fish", comment: .given(hash), symbols: .shell),
        Entry(id: "yaml", extensions: "yaml yml", comment: .given(hash), server: "yaml", colon: true, symbols: .keys, icon: .data),
        Entry(id: "toml", extensions: "toml", comment: .given(hash), server: "toml", symbols: .sections, icon: .data),
        Entry(id: "ini", extensions: "ini cfg", comment: .given(hash), symbols: .sections, icon: .data),
        Entry(id: "conf", name: "Settings file", grammar: config, extensions: "conf properties", comment: .given(hash), symbols: .sections, icon: .data),
        Entry(id: "dotenv", extensions: "env", fileNames: ".env", comment: .given(hash), icon: .data),
        Entry(id: "ignore", name: "Ignore list", grammar: config, extensions: "gitignore dockerignore gitattributes editorconfig",
              fileNames: ".gitignore .dockerignore .gitattributes .editorconfig .npmrc", comment: .given(hash), icon: .data),
        Entry(id: "r", extensions: "r", comment: .given(hash)),
        Entry(id: "perl", extensions: "pl pm", interpreters: "perl", comment: .given(hash)),
        Entry(id: "elixir", extensions: "ex exs", comment: .given(hash), server: "elixir"),
        Entry(id: "terraform", extensions: "tf tfvars", comment: .given(hash), server: "terraform"),
        Entry(id: "make", extensions: "mk makefile", fileNames: "makefile gnumakefile", comment: .given(hash), symbols: .make),
        Entry(id: "docker", extensions: "dockerfile", fileNames: "dockerfile", comment: .given(hash), server: "docker"),
        Entry(id: "cmake", extensions: "cmake", fileNames: "cmakelists.txt", comment: .given(hash)),
        Entry(id: "nim", extensions: "nim", comment: .given(hash), colon: true),
        Entry(id: "julia", extensions: "jl", interpreters: "julia", comment: .given(hash)),
        Entry(id: "powershell", extensions: "ps1", comment: .given(hash)),
        Entry(id: "awk", extensions: "awk", comment: .given(hash)),
        Entry(id: "sed", name: "sed", grammar: config, extensions: "sed", comment: .given(hash)),

        Entry(id: "sql", extensions: "sql", comment: .given(dashes)),
        Entry(id: "lua", extensions: "lua", interpreters: "lua", comment: .given(dashes), server: "lua"),
        Entry(id: "haskell", extensions: "hs", comment: .given(dashes), server: "haskell"),
        Entry(id: "elm", extensions: "elm", comment: .given(dashes)),
        Entry(id: "ada", name: "Ada", noGrammar: true, extensions: "ada", comment: .given(dashes)),

        Entry(id: "html", extensions: "html htm xhtml", comment: .given(markup), server: "html"),
        Entry(id: "xml", extensions: "xml plist svg entitlements", comment: .given(markup), icon: .data),
        Entry(id: "markdown", extensions: "md markdown", comment: .given(markup), symbols: .headings, icon: .prose, prose: true),
        Entry(id: "mdx", extensions: "mdx", comment: .given(markup), symbols: .headings, icon: .prose, prose: true),

        Entry(id: "clojure", extensions: "clj cljs edn", comment: .given(semicolon)),
        Entry(id: "common-lisp", extensions: "lisp", comment: .given(semicolon)),
        Entry(id: "emacs-lisp", extensions: "el", comment: .given(semicolon)),
        Entry(id: "scheme", extensions: "scm", comment: .given(semicolon)),
        Entry(id: "asm", extensions: "asm s", comment: .given(semicolon)),
        Entry(id: "latex", extensions: "tex sty cls ltx dtx", comment: .given(percent), icon: .prose, prose: true),
        Entry(id: "erlang", extensions: "erl hrl", comment: .given(percent)),

        Entry(id: "graphql", extensions: "graphql", comment: .none),
        Entry(id: "ocaml", extensions: "ml", comment: .none, server: "ocaml"),
        Entry(id: "bibtex", extensions: "bib", comment: .none, icon: .prose),
        Entry(id: "rst", extensions: "rst", comment: .none, icon: .prose, prose: true),
        Entry(id: "asciidoc", extensions: "adoc", comment: .none, icon: .prose, prose: true),
        Entry(id: "diff", extensions: "patch diff", comment: .none, icon: .prose),
        Entry(id: "log", extensions: "log", comment: .none, icon: .prose, prose: true),
        Entry(id: "plaintext", name: "Plain text", noGrammar: true, extensions: "txt text",
              fileNames: "license licence readme changelog authors copying procfile cname notice", comment: .none, icon: .prose, prose: true),
        Entry(id: "apple-project", name: "Xcode project file", noGrammar: true, extensions: "strings pbxproj xcconfig lock", comment: .none, icon: .data),
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    public static let all: [LanguageDefinition] = {
        var found: [String: LanguageDefinition] = [:]
        var order: [String] = []
        for row in generatedTable.split(separator: "\n") {
            let cells = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == 10 else { continue }
            var comment: CommentSyntax?
            if !cells[7].isEmpty || !cells[8].isEmpty {
                comment = CommentSyntax(line: cells[7].isEmpty ? nil : cells[7], block: cells[8].isEmpty ? nil : (cells[8], cells[9]))
            }
            found[cells[0]] = LanguageDefinition(
                id: cells[0], name: cells[1], grammar: cells[2], extensions: words(cells[3]), fileNames: words(cells[4]),
                interpreters: words(cells[5]), aliases: words(cells[6]), comment: comment)
            order.append(cells[0])
        }
        for entry in curated {
            var language = found[entry.id] ?? LanguageDefinition(id: entry.id, name: entry.name ?? entry.id, grammar: nil, extensions: [], fileNames: [],
                                                                 interpreters: [], aliases: [], comment: nil)
            if found[entry.id] == nil { order.append(entry.id) }
            if let name = entry.name { language.name = name }
            if let grammar = entry.grammar { language.grammar = grammar }
            if entry.noGrammar { language.grammar = nil }
            language.extensions.formUnion(words(entry.extensions))
            language.fileNames.formUnion(words(entry.fileNames))
            language.interpreters.formUnion(words(entry.interpreters))
            language.aliases.formUnion(words(entry.aliases))
            switch entry.comment {
            case .fromGrammar: break
            case .none: language.comment = nil
            case .given(let syntax): language.comment = syntax
            }
            language.server = entry.server
            language.lspID = entry.lspID
            language.colonOpensBlock = entry.colon
            language.family = entry.family
            language.symbols = entry.symbols
            language.icon = entry.icon
            language.isProse = entry.prose
            language.isCertainlyText = true
            found[entry.id] = language
        }
        return order.compactMap { found[$0] }
    }()

    private struct Lookup: Sendable {
        var byID: [String: Int] = [:]
        var byExtension: [String: Int] = [:]
        var byName: [String: Int] = [:]
        var byInterpreter: [String: Int] = [:]
        var byAlias: [String: Int] = [:]
        var certain = Set<String>()
    }

    private static let lookup: Lookup = {
        var table = Lookup()
        for (index, language) in all.enumerated() {
            table.byID[language.id] = index
            table.byAlias[language.id] = table.byAlias[language.id] ?? index
            for alias in language.aliases { table.byAlias[alias] = table.byAlias[alias] ?? index }
            for ext in language.extensions where table.byExtension[ext] == nil { table.byExtension[ext] = index }
            for name in language.fileNames where table.byName[name] == nil { table.byName[name] = index }
            for interpreter in language.interpreters where table.byInterpreter[interpreter] == nil { table.byInterpreter[interpreter] = index }
        }
        // What's been said on purpose wins over anything that came from the generated table.
        for entry in curated {
            guard let index = table.byID[entry.id] else { continue }
            for ext in words(entry.extensions) {
                table.byExtension[ext] = index
                table.certain.insert("." + ext)
            }
            for name in words(entry.fileNames) {
                table.byName[name] = index
                table.certain.insert(name)
            }
            for interpreter in words(entry.interpreters) { table.byInterpreter[interpreter] = index }
        }
        return table
    }()

    public static func language(id: String) -> LanguageDefinition? {
        lookup.byID[id].map { all[$0] }
    }

    /// As a code fence or a notebook names it: `py`, `Python`, `c++`, or an extension.
    public static func language(named name: String) -> LanguageDefinition? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let index = lookup.byAlias[key] ?? lookup.byExtension[key] { return all[index] }
        return all.first { $0.name.lowercased() == key }
    }

    /// `firstLine` is for a file whose name says nothing, and whose `#!` line might.
    public static func language(forPath path: String, firstLine: String? = nil) -> LanguageDefinition? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let index = lookup.byName[name] { return all[index] }
        if name.hasPrefix(".env.") { return language(id: "dotenv") }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let index = lookup.byExtension[ext] { return all[index] }
        if let firstLine, let interpreter = interpreter(in: firstLine), let index = lookup.byInterpreter[interpreter] { return all[index] }
        return nil
    }

    /// `#!/usr/bin/env -S python3 -u` is `python3`.
    static func interpreter(in line: String) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        var parts = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard var program = parts.first else { return nil }
        if (program as NSString).lastPathComponent == "env" {
            parts.removeFirst()
            program = parts.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? ""
        }
        return (program as NSString).lastPathComponent
    }

    /// Text for sure, going by the name alone. Anything else has its bytes looked at.
    public static func isCertainlyText(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return lookup.certain.contains(name) || lookup.certain.contains("." + (name as NSString).pathExtension)
    }
}
