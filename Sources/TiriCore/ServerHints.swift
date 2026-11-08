import Foundation

/// Signs that someone works on servers, so connecting to one is offered where it applies,
/// and to nobody else.
extension SSHConfigFile {
    /// `ssh`'s own arguments, as it was started in a terminal: where it went, when Tiri can go there
    /// the same way. A key, a jump host or a command to run there are things Tiri couldn't repeat.
    public static func destination(sshArguments arguments: [String]) -> String? {
        var user: String?
        var port: String?
        var host: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "-l" || word == "-p" {
                guard index + 1 < arguments.count else { return nil }
                if word == "-l" { user = arguments[index + 1] } else { port = arguments[index + 1] }
                index += 2
            } else if word.hasPrefix("-p"), word.count > 2 {
                port = String(word.dropFirst(2))
                index += 1
            } else if word.hasPrefix("-l"), word.count > 2 {
                user = String(word.dropFirst(2))
                index += 1
            } else if word.hasPrefix("-"), word.count > 1 {
                // Flags that don't change where it goes.
                guard word.dropFirst().allSatisfy({ "46AaCgKkqTtvXxY".contains($0) }) else { return nil }
                index += 1
            } else if host == nil {
                host = word
                index += 1
            } else {
                // `ssh host uptime` runs something there and leaves.
                return nil
            }
        }
        guard var host, !host.isEmpty else { return nil }
        if let user {
            guard !user.isEmpty, !user.contains(" "), !host.contains("@") else { return nil }
            host = user + "@" + host
        }
        return destination(from: port.map { "\(host) -p \($0)" } ?? host)
    }

    /// Code hosts that git reaches over SSH. Having pushed to one says nothing about servers.
    static let codeHosts: Set<String> = [
        "github.com", "ssh.github.com", "gitlab.com", "altssh.gitlab.com", "bitbucket.org", "altssh.bitbucket.org",
        "ssh.dev.azure.com", "vs-ssh.visualstudio.com", "codeberg.org", "git.sr.ht", "gitee.com", "heroku.com",
        "source.developers.google.com", "hf.co", "huggingface.co",
    ]

    /// Whether `known_hosts` has a server in it, rather than only the places git pushes to.
    /// A hashed name can't be told apart, so it counts.
    public static func hasServers(knownHosts text: String) -> Bool {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // `@cert-authority` and `@revoked` come before the names.
            if fields.first?.hasPrefix("@") == true { fields.removeFirst() }
            guard let names = fields.first else { continue }
            if names.hasPrefix("|") { return true }
            let hosts = names.split(separator: ",").map { name -> String in
                var host = String(name)
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    host = String(host[host.index(after: host.startIndex)..<close])
                }
                return host.lowercased()
            }.filter { !$0.isEmpty && !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            // A code host's line can carry its address too, which is still the code host.
            if hosts.contains(where: { host in codeHosts.contains(host) || codeHosts.contains { host.hasSuffix("." + $0) } }) { continue }
            if !hosts.isEmpty { return true }
        }
        return false
    }

    public static var defaultKnownHostsPath: String {
        ProcessInfo.processInfo.environment["TIRI_SSH_KNOWN_HOSTS"] ?? NSHomeDirectory() + "/.ssh/known_hosts"
    }

    /// Someone with a host of their own in `~/.ssh/config`, or a server in `known_hosts`.
    public static func usesServers(configPath: String = defaultPath,
                                   knownHostsPath: String = defaultKnownHostsPath) -> Bool {
        if !hosts(at: configPath).isEmpty { return true }
        guard let text = try? String(contentsOfFile: knownHostsPath, encoding: .utf8) else { return false }
        return hasServers(knownHosts: text)
    }
}
