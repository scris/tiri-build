import Foundation
import TiriCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let environment = ProcessInfo.processInfo.environment
let cliEnvironment = CLIParser.Environment(
    cwd: FileManager.default.currentDirectoryPath,
    itemID: environment["TIRI_ITEM_ID"],
    workspace: environment["TIRI_WORKSPACE"],
    claudeEntrypoint: environment["CLAUDE_CODE_ENTRYPOINT"]
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
