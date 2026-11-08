import Foundation
import Testing
@testable import TiriCore

@Suite struct ServerHintsTests {
    @Test(arguments: [
        (["gpu"], "gpu"), (["me@gpu"], "me@gpu"), (["-p", "2222", "me@gpu"], "ssh://me@gpu:2222"),
        (["-p2222", "gpu"], "ssh://gpu:2222"), (["-l", "me", "gpu"], "me@gpu"), (["-lme", "gpu"], "me@gpu"),
        (["-A", "-v", "gpu"], "gpu"), (["-tt", "me@10.0.0.5"], "me@10.0.0.5"), (["ssh://me@gpu:22"], "ssh://me@gpu:22"),
    ])
    func findsWhereSSHWent(arguments: [String], expected: String) {
        #expect(SSHConfigFile.destination(sshArguments: arguments) == expected)
    }

    @Test(arguments: [
        [String](), ["gpu", "uptime"], ["-i", "key.pem", "gpu"], ["-J", "jump", "gpu"], ["-o", "ProxyCommand=x", "gpu"],
        ["-oProxyCommand=x", "gpu"], ["-L", "8080:localhost:80", "gpu"], ["-N", "gpu"], ["-p"], ["-l", "me", "you@gpu"],
        ["-W", "host:22", "gpu"], ["-G", "gpu"],
    ])
    func leavesWhatTiriCouldntRepeat(arguments: [String]) {
        #expect(SSHConfigFile.destination(sshArguments: arguments) == nil)
    }

    @Test func gitHostsArentServers() {
        let text = """
        github.com ssh-ed25519 AAAA
        gitlab.com,172.65.251.78 ecdsa-sha2-nistp256 AAAA
        [ssh.github.com]:443 ssh-ed25519 AAAA
        # a comment
        @cert-authority *.example.com ssh-rsa AAAA
        """
        #expect(!SSHConfigFile.hasServers(knownHosts: text))
    }

    @Test func aServerIsOne() {
        #expect(SSHConfigFile.hasServers(knownHosts: "github.com ssh-ed25519 A\n10.0.0.5 ssh-ed25519 B\n"))
        #expect(SSHConfigFile.hasServers(knownHosts: "[gpu.lab.edu]:2222 ssh-ed25519 B\n"))
        // Hashed names can't be read, so they're taken as servers.
        #expect(SSHConfigFile.hasServers(knownHosts: "|1|abc=|def= ssh-ed25519 B\n"))
        #expect(!SSHConfigFile.hasServers(knownHosts: ""))
    }

    @Test func eitherFileIsEnough() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("config").path
        let known = folder.appendingPathComponent("known_hosts").path
        #expect(!SSHConfigFile.usesServers(configPath: config, knownHostsPath: known))
        try "github.com ssh-ed25519 A\n".write(toFile: known, atomically: true, encoding: .utf8)
        #expect(!SSHConfigFile.usesServers(configPath: config, knownHostsPath: known))
        try "Host gpu\n  HostName 10.0.0.5\n".write(toFile: config, atomically: true, encoding: .utf8)
        #expect(SSHConfigFile.usesServers(configPath: config, knownHostsPath: known))
    }
}
