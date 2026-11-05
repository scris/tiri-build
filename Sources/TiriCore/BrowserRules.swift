import Foundation

/// Sites that open in someone's own browser rather than in Tiri: mostly the ones they're signed in to there,
/// which in Tiri would only show a sign-in page or a 404.
///
/// `github.com` covers the site and everything on it, `www.` or not, and any part of it like `gist.github.com`.
/// `github.com/acme` covers one place on it. A pasted address works too, `https://` and all.
public enum BrowserRules {
    /// The rule an address falls under, if any.
    public static func matching(_ url: URL, in rules: [String]) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        return rules.first { rule in
            guard let (ruleHost, rulePath) = parts(of: rule) else { return false }
            let hostMatches: Bool
            if ruleHost.hasPrefix("*.") {
                let base = String(ruleHost.dropFirst(2))
                hostMatches = host == base || host.hasSuffix("." + base)
            } else {
                hostMatches = host == ruleHost || host.hasSuffix("." + ruleHost)
            }
            guard hostMatches else { return false }
            guard !rulePath.isEmpty else { return true }
            // A place and what's under it, not every name that starts the same way.
            let prefix = "/" + rulePath
            return path.lowercased() == prefix || path.lowercased().hasPrefix(prefix + "/")
        }
    }

    /// The rule to offer for an address: its site, without `www.`.
    public static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// A rule as written, tidied: what's kept in settings.
    public static func tidy(_ rule: String) -> String? {
        guard let (host, path) = parts(of: rule) else { return nil }
        return path.isEmpty ? host : host + "/" + path
    }

    private static func parts(of rule: String) -> (String, String)? {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("*") { text.removeLast() }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        let pieces = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var host = String(pieces[0])
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // A port or a sign-in in front means nothing for which site it is.
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        guard !host.isEmpty, host != "*." else { return nil }
        let path = pieces.count > 1 ? String(pieces[1]) : ""
        return (host, path)
    }
}
