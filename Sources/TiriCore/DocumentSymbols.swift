import Foundation

/// A named thing in a file: a function, a type, a heading.
public struct DocumentSymbol: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case function, method, type, property, variable, constant, module, heading, other

        /// The numbers the language server protocol gives them.
        init(lsp: Int?) {
            switch lsp {
            case 2, 3, 4: self = .module
            case 5, 10, 11, 23, 26: self = .type
            case 6, 9: self = .method
            case 7, 8, 22: self = .property
            case 12: self = .function
            case 13: self = .variable
            case 14: self = .constant
            default: self = .other
            }
        }
    }

    public var name: String
    public var kind: Kind
    /// What it's inside, if anything.
    public var container: String?
    /// Counting from 1, where the name is.
    public var line: Int
    public var column: Int
    /// Only set for a symbol in another file.
    public var path: String?

    public var id: String { "\(path ?? ""):\(line):\(column):\(name)" }

    public init(name: String, kind: Kind, container: String? = nil, line: Int, column: Int, path: String? = nil) {
        self.name = name
        self.kind = kind
        self.container = container
        self.line = line
        self.column = column
        self.path = path
    }
}

extension LSP {
    /// `textDocument/documentSymbol` answers either as a tree, or as a flat list with locations.
    public static func documentSymbols(from result: JSONValue?) -> [DocumentSymbol] {
        var found: [DocumentSymbol] = []
        func add(_ entry: JSONValue, container: String?) {
            guard let name = entry["name"]?.stringValue else { return }
            let range = entry["selectionRange"] ?? entry["range"] ?? entry["location"]?["range"]
            guard let start = range?["start"], let line = start["line"]?.intValue, let character = start["character"]?.intValue else { return }
            found.append(DocumentSymbol(name: name, kind: .init(lsp: entry["kind"]?.intValue), container: container ?? entry["containerName"]?.stringValue,
                                        line: line + 1, column: character + 1))
            for child in entry["children"]?.arrayValue ?? [] { add(child, container: name) }
        }
        for entry in result?.arrayValue ?? [] { add(entry, container: nil) }
        return found.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// `workspace/symbol`. Newer servers can leave a location's range out, and then it's the file's top.
    public static func workspaceSymbols(from result: JSONValue?) -> [DocumentSymbol] {
        (result?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, let location = entry["location"],
                  let uri = location["uri"]?.stringValue, let path = path(from: uri) else { return nil }
            let start = location["range"]?["start"]
            return DocumentSymbol(name: name, kind: .init(lsp: entry["kind"]?.intValue), container: entry["containerName"]?.stringValue,
                                  line: (start?["line"]?.intValue ?? 0) + 1, column: (start?["character"]?.intValue ?? 0) + 1, path: path)
        }
    }
}

/// Finds what's defined in a file by reading its lines, for when there's no language server.
/// Good for finding your way around, and it doesn't pretend to be a parser.
public enum SimpleSymbols {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let kind: DocumentSymbol.Kind
        init(_ pattern: String, _ kind: DocumentSymbol.Kind) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.kind = kind
        }
    }

    private static let access = "(?:(?:public|private|internal|fileprivate|open|protected|static|final|override|abstract|export|default|async|pub(?:\\([^)]*\\))?|unsafe|nonisolated|mutating|class|@\\w+(?:\\([^)]*\\))?)\\s+)*"

    private static let code: [Rule] = [
        Rule("^\\s*\(access)(?:func|fn|def|function\\*?|fun|sub)\\s+([A-Za-z_$][\\w$!?]*)", .function),
        Rule("^\\s*func\\s*\\([^)]*\\)\\s*([A-Za-z_][\\w]*)\\s*\\(", .method),
        Rule("^\\s*\(access)(?:class|struct|enum|actor|protocol|interface|trait|impl|extension|type|typealias|union|record|object|module|mod|namespace)\\s+(?:<[^>]*>\\s*)?([A-Za-z_$][\\w$.]*)", .type),
        Rule("^\\s*\(access)(?:const|let|var|val)\\s+([A-Za-z_$][\\w$]*)\\s*(?:[:=]\\s*(?:async\\s*)?(?:function|\\([^)]*\\)\\s*(?:=>|:)|[A-Za-z_$][\\w$]*\\s*=>))", .function),
        Rule("^#\\s*define\\s+([A-Za-z_][\\w]*)", .constant),
        // `int main(int argc) {`, in C and its relatives.
        Rule("^(?!\\s*(?:return|else|new|throw|await|yield|delete|case|goto|if|for|while|switch|do|using|typedef)\\b)[A-Za-z_][\\w:<>,*&\\[\\]\\s]*?[\\s*&]([A-Za-z_~][\\w:~]*)\\s*\\([^;]*$", .function),
    ]

    private static let shell = Rule("^\\s*(?:function\\s+)?([A-Za-z_][\\w-]*)\\s*\\(\\)", .function)
    private static let make = Rule("^([A-Za-z_][\\w.-]*)\\s*:(?!=)", .function)
    private static let keys = Rule("^(\\s{0,2})([A-Za-z_\"'][\\w\"'.-]*)\\s*[:=]", .property)
    private static let section = Rule("^\\s*\\[+([^\\]]+)\\]+\\s*$", .module)
    private static let css = Rule("^([.#@]?[A-Za-z_][^{;]*?)\\s*\\{\\s*$", .type)

    public static func scan(_ text: String, path: String, limit: Int = 5_000) -> [DocumentSymbol] {
        let rules: [Rule]
        var nameGroup = 1
        switch LanguageCatalog.language(forPath: path)?.symbols ?? .code {
        case .headings: return headings(text, limit: limit)
        case .shell: rules = [shell]
        case .make: rules = [make]
        case .keys:
            rules = [keys]
            nameGroup = 2
        case .sections: rules = [section]
        case .stylesheet: rules = [css]
        case .code: rules = code
        }
        var found: [DocumentSymbol] = []
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            if line.utf16.count > 1_000 { return }
            let range = NSRange(location: 0, length: line.utf16.count)
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: line, range: range), match.numberOfRanges > nameGroup,
                      let name = Range(match.range(at: nameGroup), in: line), !name.isEmpty else { continue }
                found.append(DocumentSymbol(name: String(line[name]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
                                            kind: rule.kind, line: lineNumber, column: match.range(at: nameGroup).location + 1))
                if found.count >= limit { stop = true }
                break
            }
        }
        return found
    }

    private static func headings(_ text: String, limit: Int) -> [DocumentSymbol] {
        var found: [DocumentSymbol] = []
        var lineNumber = 0
        var inFence = false
        var parents: [(level: Int, name: String)] = []
        text.enumerateLines { line, stop in
            lineNumber += 1
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            guard !inFence, line.hasPrefix("#") else { return }
            let level = line.prefix { $0 == "#" }.count
            guard level <= 6 else { return }
            let rest = line.dropFirst(level)
            guard rest.first == " " else { return }
            let name = rest.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
            guard !name.isEmpty else { return }
            while let last = parents.last, last.level >= level { parents.removeLast() }
            found.append(DocumentSymbol(name: name, kind: .heading, container: parents.last?.name, line: lineNumber, column: 1))
            parents.append((level, name))
            if found.count >= limit { stop = true }
        }
        return found
    }
}
