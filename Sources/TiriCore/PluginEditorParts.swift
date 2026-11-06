import Foundation

// What plugins add to the editor and the explorer, as Tiri reads it. The drawing is the app's.

/// A color a plugin names: one of the system's, by name, or `#rgb`, `#rrggbb`, `#rrggbbaa`.
public enum PluginColor: Equatable, Sendable {
    case named(String)
    case rgba(Double, Double, Double, Double)

    /// The system's colors, which suit both light and dark.
    public static let names = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "accent"]

    public static func parse(_ text: String) -> PluginColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if names.contains(trimmed) { return .named(trimmed) }
        if trimmed == "grey" { return .named("gray") }
        guard trimmed.hasPrefix("#") else { return nil }
        var digits = Array(trimmed.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.flatMap { [$0, $0] } }
        guard digits.count == 6 || digits.count == 8 else { return nil }
        var values: [Double] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            values.append(Double(byte) / 255)
        }
        return .rgba(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
    }
}

public enum PluginHighlightPattern {
    /// `${settings.tags}` becomes what that setting holds, as plain text: a list becomes
    /// `(?:A|B)`, so a tag like `[ ]` means itself. An empty list matches nothing.
    public static func fill(_ pattern: String, settings: [String: JSONValue]) -> String {
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.range(of: "${settings.") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let key = String(rest[open.upperBound..<close])
            result += text(of: settings[key])
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private static func text(of value: JSONValue?) -> String {
        guard let value else { return "(?!)" }
        if let list = value.arrayValue {
            let words = list.map(PluginTemplate.text).filter { !$0.isEmpty }
            return words.isEmpty ? "(?!)" : "(?:" + words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")"
        }
        return NSRegularExpression.escapedPattern(for: PluginTemplate.text(value))
    }

    /// Lines longer than this aren't colored: a pattern that backtracks can't stall the editor on a
    /// minified file.
    public static let longestLine = 2_000

    /// Where it matches in one line, as ranges in UTF-16, which is what the editor counts in.
    public static func matches(_ expression: NSRegularExpression, group: Int?, in line: String) -> [NSRange] {
        let text = line as NSString
        guard text.length <= longestLine else { return [] }
        var found: [NSRange] = []
        for match in expression.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let range = group.flatMap { $0 < match.numberOfRanges ? match.range(at: $0) : nil } ?? match.range
            if range.location != NSNotFound, range.length > 0 { found.append(range) }
            if found.count >= 200 { break }
        }
        return found
    }
}

/// A mark beside a file in the explorer.
public struct PluginFileMark: Equatable, Sendable {
    /// One or two characters, like a count or a letter.
    public var badge: String?
    public var color: String?
    public var tooltip: String?

    public init(badge: String? = nil, color: String? = nil, tooltip: String? = nil) {
        self.badge = badge
        self.color = color
        self.tooltip = tooltip
    }

    /// `{"files": {"src/a.py": {"badge", "color", "tooltip"}}}` or `{"items": [{"path", ...}]}`. A path
    /// that isn't absolute is inside `folder`. What isn't in a folder of the workspace is dropped.
    public static func list(from value: JSONValue, folder: String?, limit: Int = 20_000) -> [String: PluginFileMark] {
        var marks: [String: PluginFileMark] = [:]
        func add(_ path: String, _ entry: JSONValue) {
            guard marks.count < limit, !path.isEmpty else { return }
            let full = path.hasPrefix("/") ? path : (folder.map { $0 + "/" + path } ?? path)
            guard full.hasPrefix("/") else { return }
            let badge = entry["badge"].map(PluginTemplate.text).map { String($0.prefix(2)) }
            let mark = PluginFileMark(badge: badge?.isEmpty == true ? nil : badge, color: entry["color"]?.stringValue, tooltip: entry["tooltip"]?.stringValue)
            guard mark.badge != nil || mark.color != nil else { return }
            marks[(full as NSString).standardizingPath] = mark
        }
        if let files = value["files"]?.objectValue {
            for (path, entry) in files { add(path, entry) }
        }
        for entry in value["items"]?.arrayValue ?? value.arrayValue ?? [] {
            if let path = entry["path"]?.stringValue { add(path, entry) }
        }
        return marks
    }
}
