import Foundation

/// Whether what came back for a page is a site asking for a sign-in, not the page.
public enum SignInWall {
    /// Sites that answer "not found" for what a signed-out visitor may not see, like a private repository.
    private static let hidesBehindNotFound = ["github.com", "gitlab.com", "bitbucket.org"]
    private static let signInPaths = ["/login", "/signin", "/sign_in", "/sign-in", "/users/sign_in", "/session/new", "/sso", "/auth/login", "/account/login", "/accounts/login"]
    private static let signInHosts = ["login.", "signin.", "accounts.", "auth.", "sso.", "id."]

    /// `asked` is the address someone wanted, `answered` where the site ended up, with its status.
    public static func stands(asked: URL, answered: URL, status: Int) -> Bool {
        guard let host = asked.host?.lowercased(), !isLocal(host) else { return false }
        if status == 401 { return true }
        if status == 404, hidesBehindNotFound.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        // Sent to a sign-in page they didn't ask for.
        return isSignIn(answered) && !isSignIn(asked)
    }

    public static func isSignIn(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if signInHosts.contains(where: host.hasPrefix) { return true }
        return signInPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "::1" || host.hasPrefix("127.")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }
}
