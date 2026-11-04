import Foundation
import TiriCore

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
case .request(let value, let json):
    request = value
    rawJSON = json
}

// A hook must never disturb the agent, even when Tiri isn't running.
let isHookCommand = arguments.first == "hook" || arguments.first == "notify"

let response: ControlResponse
do {
    // A person is answering, and a connection can take a while to come up.
    let patient = arguments.first == "askpass" || arguments.first == "remote"
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
