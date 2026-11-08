import Foundation

/// A kind of file Tiri can run with one press: ▶ above it, or ⌃⌥N. The command is what a person
/// would type for a single file, with `$file` and the rest filled in when it runs.
public struct RunLanguage: Sendable, Hashable, Identifiable {
    public var id: String
    /// A name, never translated.
    public var name: String
    /// Without the dot, lowercase.
    public var extensions: [String]
    public var command: String

    public init(id: String, name: String, extensions: [String], command: String) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.command = command
    }

    public var shownExtensions: String { extensions.map { "." + $0 }.joined(separator: " ") }
}

/// Where the Run terminal goes the first time.
public enum RunPlacement: String, CaseIterable, Sendable {
    case below, right, tab
}

/// What one press runs: the command as typed into the Run terminal, in the file's folder.
public struct RunPlan: Equatable, Sendable {
    /// A language's id, or `.ext` for a kind of file someone added.
    public var key: String
    public var name: String
    public var template: String
    public var command: String
    public var directory: String
    /// The program the command starts, when it's a plain name that can be looked for.
    public var tool: String?
}

public enum RunCommands {
    /// Single files, no project. Compiled programs go to /tmp, so homework folders don't fill with binaries.
    public static let languages: [RunLanguage] = [
        .init(id: "python", name: "Python", extensions: ["py"], command: "python3 $file"),
        .init(id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs"], command: "node $file"),
        // Node 23.6 and later run TypeScript as it is.
        .init(id: "typescript", name: "TypeScript", extensions: ["ts", "mts", "cts"], command: "node $file"),
        .init(id: "c", name: "C", extensions: ["c"], command: "clang $file -o $out && $out"),
        .init(id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "c++"], command: "clang++ -std=c++20 $file -o $out && $out"),
        // Java 11 and later run a single source file without compiling it first.
        .init(id: "java", name: "Java", extensions: ["java"], command: "java $file"),
        .init(id: "go", name: "Go", extensions: ["go"], command: "go run $file"),
        .init(id: "rust", name: "Rust", extensions: ["rs"], command: "rustc $file -o $out && $out"),
        .init(id: "swift", name: "Swift", extensions: ["swift"], command: "swift $file"),
        .init(id: "kotlin", name: "Kotlin", extensions: ["kt"], command: "kotlinc $file -include-runtime -d $out.jar && java -jar $out.jar"),
        // .NET 10 and later run a single .cs file.
        .init(id: "csharp", name: "C#", extensions: ["cs"], command: "dotnet run $file"),
        .init(id: "ruby", name: "Ruby", extensions: ["rb"], command: "ruby $file"),
        .init(id: "php", name: "PHP", extensions: ["php"], command: "php $file"),
        .init(id: "lua", name: "Lua", extensions: ["lua"], command: "lua $file"),
        .init(id: "perl", name: "Perl", extensions: ["pl"], command: "perl $file"),
        .init(id: "r", name: "R", extensions: ["r"], command: "Rscript $file"),
        .init(id: "haskell", name: "Haskell", extensions: ["hs"], command: "runghc $file"),
        .init(id: "dart", name: "Dart", extensions: ["dart"], command: "dart run $file"),
        .init(id: "shell", name: "Shell", extensions: ["sh", "bash"], command: "bash $file"),
        .init(id: "zsh", name: "Zsh", extensions: ["zsh"], command: "zsh $file"),
    ]

    public static func language(_ id: String) -> RunLanguage? { languages.first { $0.id == id } }

    /// The extension of a path as `run.commands` keys an added one: `.kt`.
    public static func extensionKey(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : "." + ext
    }

    /// `.Kt`, `kt` and ` .kt ` all mean `.kt`. Nil for something that isn't one.
    public static func tidyExtension(_ text: String) -> String? {
        var ext = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber || "+-_".contains($0) }) else { return nil }
        return "." + ext
    }

    /// What runs a file, given what's been changed: `commands` by language id or `.ext`, and what's turned off.
    public static func plan(for path: String, commands: [String: String], off: [String]) -> RunPlan? {
        guard let key = extensionKey(path) else { return nil }
        let ext = String(key.dropFirst())
        let name: String
        let id: String
        let template: String
        if let added = commands[key] {
            (id, name, template) = (key, key, added)
        } else if let language = languages.first(where: { $0.extensions.contains(ext) }) {
            (id, name, template) = (language.id, language.name, commands[language.id] ?? language.command)
        } else {
            return nil
        }
        // Off by language or by one of its extensions, written however.
        let isOff = off.contains { entry in
            let word = entry.trimmingCharacters(in: .whitespaces)
            return word.lowercased() == id || word.hasPrefix(".") && RunCommands.tidyExtension(word) == key
        }
        if isOff || template.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let command = expand(template, path: path)
        return RunPlan(key: id, name: name, template: template, command: command,
                       directory: (path as NSString).deletingLastPathComponent, tool: tool(of: template))
    }

    /// `$file` is the file's name, `$name` the same without its extension, `$dir` its folder, `$path` all of it,
    /// and `$out` a place in /tmp for a compiled program. Each is quoted for the shell when it needs to be.
    /// The command runs in the file's folder, so `$file` is all most need.
    public static func expand(_ template: String, path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let name = (file as NSString).deletingPathExtension
        let values = [
            // A name starting with - would be read as an option.
            "file": file.hasPrefix("-") ? "./" + file : file, "name": name, "dir": (path as NSString).deletingLastPathComponent,
            "path": path, "out": "/tmp/" + name,
        ]
        // `"$file"`, as people write it from habit, is the same as `$file`: the value is quoted either way.
        let pattern = #"\"\$\{?(file|name|dir|path|out)\}?\"|\$\{(file|name|dir|path|out)\}|\$(file|name|dir|path|out)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        var result = ""
        var last = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let whole = Range(match.range, in: template) else { continue }
            guard let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }),
                  let word = Range(match.range(at: group), in: template), let value = values[String(template[word])] else { continue }
            result += template[last..<whole.lowerBound]
            result += ShellQuote.quote(value)
            last = whole.upperBound
        }
        result += template[last...]
        return result
    }

    /// The program a command starts: its first word after any `NAME=value`. Nil when that's a path or a variable,
    /// which can't be looked for by name.
    public static func tool(of template: String) -> String? {
        for word in template.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.contains("="), !word.hasPrefix("=") { continue }
            // Part of the shell, not a program: nothing to look for.
            if shellWords.contains(word) { return nil }
            return ShellLookup.isPlainName(word) ? word : nil
        }
        return nil
    }

    private static let shellWords: Set<String> = [
        "cd", "time", "source", ".", "exec", "eval", "export", "builtin", "command", "set", "ulimit", "umask",
        "if", "for", "while", "until", "case", "{", "(", "!", "noglob", "nocorrect",
    ]

    /// The tools of every language, to look for all at once.
    public static func tools(commands: [String: String]) -> [String] {
        let all = languages.map { commands[$0.id] ?? $0.command } + commands.filter { $0.key.hasPrefix(".") }.map(\.value)
        return Array(Set(all.compactMap(tool(of:)))).sorted()
    }
}
