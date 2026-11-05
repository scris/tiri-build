import Foundation
import TiriCore

// In a terminal on a server that's also a Mac with Tiri installed, this is the wrong `tiri`: the one that
// reaches the Mac at the other end of the connection is the helper.
if let helper = ProcessInfo.processInfo.environment["TIRI_SERVER_HELPER"], !helper.isEmpty, FileManager.default.isExecutableFile(atPath: helper) {
    var arguments = CommandLine.arguments
    arguments[0] = helper
    let argv = arguments.map { strdup($0) } + [nil]
    execv(helper, argv)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// The command lines of the processes above this one, nearest first.
@Sendable func processAncestors() -> [[String]] {
    var result: [[String]] = []
    var pid = getppid()
    for _ in 0..<16 where pid > 1 {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&request, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size {
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctl(&request, 3, &buffer, &size, nil, 0) == 0 {
                // An argument count, then the executable's path, then NULs, then the arguments.
                let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
                let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
                result.append(parts.dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) })
            }
        }
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var lookup = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&lookup, 4, &info, &length, nil, 0) == 0, length > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return result
}

let environment = ProcessInfo.processInfo.environment
let cliEnvironment = CLIParser.Environment(
    cwd: FileManager.default.currentDirectoryPath,
    itemID: environment["TIRI_ITEM_ID"],
    workspace: environment["TIRI_WORKSPACE"],
    claudeEntrypoint: environment["CLAUDE_CODE_ENTRYPOINT"],
    ancestors: { processAncestors() }
)

let arguments = Array(CommandLine.arguments.dropFirst())
let parsed: CLIParser.Parsed
do {
    parsed = try CLIParser.parse(arguments, environment: cliEnvironment)
} catch {
    fail("\(error)", code: 2)
}

let request: ControlRequest
let rawJSON: Bool
switch parsed {
case .printText(let text):
    print(text)
    exit(0)
case .quietSuccess:
    exit(0)
case .local(let action):
    let outcome = PluginTools.run(action, cwd: cliEnvironment.cwd)
    fputs(outcome.output, stdout)
    fputs(outcome.errors, stderr)
    exit(outcome.code)
case .change(let action):
    // Whatever reads this may have gone, and a build shouldn't stop halfway because of that.
    signal(SIGPIPE, SIG_IGN)
    let outcome = ChangeTools.run(action, context: ChangeTools.Context(item: environment["TIRI_ITEM_ID"]))
    fputs(outcome.output, stdout)
    fputs(outcome.errors, stderr)
    exit(outcome.code)
case .update(let action):
    signal(SIGPIPE, SIG_IGN)
    let outcome = UpdateTools.run(action, context: ChangeTools.Context(item: environment["TIRI_ITEM_ID"]))
    fputs(outcome.output, stdout)
    fputs(outcome.errors, stderr)
    exit(outcome.code)
case .request(let value, let json):
    request = value
    rawJSON = json
}

// A hook must never disturb the agent, even when Tiri isn't running.
let isHookCommand = arguments.first == "hook" || arguments.first == "notify"

let response: ControlResponse
do {
    // A person is answering, a connection can take a while to come up, and the first look at years
    // of conversations takes a while too.
    let patient = request.cmd == "languages.add" || ["askpass", "remote", "conversations", "work"].contains(arguments.first ?? "")
    let client = try ControlClient(path: TiriPaths.socket, timeout: patient ? 300 : 10)
    response = try client.send(request)
} catch {
    if isHookCommand { exit(0) }
    if case ControlSocketError.timedOut = error {
        fail("Tiri didn't answer in time. If macOS is asking for permission to read a folder, answer that first.")
    }
    fail("Tiri isn't running (\(error)). Open Tiri.app first.")
}

if rawJSON {
    if let data = try? ControlCoding.encodeLine(response) {
        fputs(String(decoding: data, as: UTF8.self), stdout)
    }
    exit(response.ok ? 0 : 1)
}

guard response.ok else {
    if isHookCommand { exit(0) }
    fail(response.error ?? "Unknown error")
}

// Not FileHandle: it raises an exception if whatever's reading has gone, like `tiri items | head -1`.
fputs(CLIOutput.text(request: request, response: response), stdout)
