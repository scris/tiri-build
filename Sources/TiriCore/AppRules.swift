import Foundation

/// Kinds of file that open in their own app rather than in Tiri: a `.psd` in Photoshop, a `.key` in Keynote.
///
/// A rule is the end of a file's name, from a dot: `.psd`, or `.tar.gz` for the longer kind.
/// Written as `psd`, `*.psd` or `PSD` it means the same.
public enum AppRules {
    /// The rule a file falls under, if any.
    public static func matching(path: String, in rules: [String]) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !name.isEmpty else { return nil }
        return rules.first { rule in
            guard let kind = tidy(rule) else { return false }
            return name.hasSuffix(kind)
        }
    }

    /// The rule to offer for a file: its extension. Nothing for a name without one.
    public static func kind(of path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : "." + ext
    }

    /// A rule as written, tidied: what's kept in settings.
    public static func tidy(_ rule: String) -> String? {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix("*") { text.removeFirst() }
        while text.hasPrefix(".") { text.removeFirst() }
        // A kind of file, not a place: nothing with a folder or a pattern in it.
        guard !text.isEmpty, !text.contains("/"), !text.contains("*"), !text.contains(" ") else { return nil }
        return "." + text
    }
}
