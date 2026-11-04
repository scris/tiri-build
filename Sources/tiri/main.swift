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
    let client = try ControlClient(path: TiriPaths.socket)
    response = try client.send(request)
} catch {
    if isHookCommand { exit(0) }
    if case ControlSocketError.timedOut = error {
        fail("Tiri didn't answer in time. If macOS is asking for permission to read a folder, answer that first.")
    }
    fail("Tiri isn't running (\(error)). Open Tiri.app first.")
}

func jsonString(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

func cell(_ value: JSONValue?) -> String { value?.stringValue ?? "" }

if rawJSON {
    if let data = try? ControlCoding.encodeLine(response) {
        FileHandle.standardOutput.write(data)
    }
    exit(response.ok ? 0 : 1)
}

guard response.ok else {
    if isHookCommand { exit(0) }
    fail(response.error ?? "Unknown error")
}

// Plain text for the common listings; JSON for anything structured.
switch request.cmd {
case "items":
    for item in response.result?.arrayValue ?? [] {
        var line = [cell(item["id"]), cell(item["kind"]), cell(item["status"]).isEmpty ? "-" : cell(item["status"]), cell(item["title"])]
        if item["active"]?.boolValue == true { line.append("(active)") }
        if item["peek"]?.boolValue == true { line.append("(peek)") }
        line.append("[\(cell(item["workspace"]))]")
        print(line.joined(separator: "\t"))
    }
case "workspace.list":
    for workspace in response.result?.arrayValue ?? [] {
        let marker = workspace["active"]?.boolValue == true ? "*" : " "
        let folders = workspace["folders"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
        print("\(marker) \(cell(workspace["name"]))\t\(folders)")
    }
case "git":
    for repository in response.result?.arrayValue ?? [] {
        let head = cell(repository["head"]) + (repository["dirty"]?.boolValue == true ? "*" : "")
        let counts = repository["upstream"] == nil ? "no upstream" : "\(repository["behind"]?.intValue ?? 0)↓ \(repository["ahead"]?.intValue ?? 0)↑"
        print([head, counts, cell(repository["root"])].joined(separator: "\t"))
    }
case "read":
    print(cell(response.result?["text"]))
case "tree":
    for row in response.result?.arrayValue ?? [] { print(cell(row)) }
case "commands":
    for command in response.result?.arrayValue ?? [] {
        print([cell(command["id"]), cell(command["title"]), cell(command["key"])].joined(separator: "\t"))
    }
case "ping":
    print("pong")
case "search":
    for entry in response.result?.arrayValue ?? [] {
        print("\(cell(entry["path"])):\(entry["line"]?.intValue ?? 0): \(cell(entry["text"]))")
    }
case "changes":
    for entry in response.result?.arrayValue ?? [] {
        print([cell(entry["status"]), cell(entry["path"])].joined(separator: "\t"))
    }
case "diagnostics":
    for entry in response.result?["problems"]?.arrayValue ?? [] {
        print(cell(entry["text"]))
    }
    let checked = response.result?["checked"]?.intValue ?? 0
    let uncovered = response.result?["uncovered"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let count = response.result?["problems"]?.arrayValue?.count ?? 0
    print("\(count) \(count == 1 ? "problem" : "problems") in \(checked) \(checked == 1 ? "file" : "files").")
    if !uncovered.isEmpty { print("No language server answered for: \(uncovered.joined(separator: ", "))") }
case "languages":
    for entry in response.result?.arrayValue ?? [] {
        print([cell(entry["language"]), cell(entry["state"]), cell(entry["path"])].joined(separator: "\t"))
    }
case "turns":
    for entry in response.result?.arrayValue ?? [] {
        print([cell(entry["id"]), cell(entry["state"]), cell(entry["title"]), cell(entry["prompt"])].joined(separator: "\t"))
    }
case "settings.list":
    for entry in response.result?.arrayValue ?? [] {
        print([cell(entry["key"]), cell(entry["display"])].joined(separator: "\t"))
    }
case "settings.explain":
    for entry in response.result?.arrayValue ?? [] {
        print("\(cell(entry["key"]))  (\(cell(entry["section"])): \(cell(entry["title"])))")
        print("  \(cell(entry["explanation"]))")
        print("  Now: \(cell(entry["display"]))   Default: \(cell(entry["defaultDisplay"]))   Accepts: \(cell(entry["accepts"]))")
    }
case "settings.get", "settings.set", "settings.reset":
    print(cell(response.result?["display"]))
case "hooks.install", "hooks.remove":
    print("Tiri is asking for a yes on screen.")
case "keys.set", "keys.unset", "keys.reset":
    let key = cell(response.result?["key"])
    print(key.isEmpty ? "no shortcut" : key)
case "open", "preview", "term":
    if let item = response.result?["item"]?.stringValue { print(item) }
case "focus", "close", "notify", "theme", "web-dark", "reveal", "run", "send", "workspace.switch",
     "workspace.new", "workspace.add-folder", "workspace.remove-folder", "workspace.import",
     "workspace.rename", "workspace.delete", "quit", "settings.open", "follow", "diff", "select":
    break
default:
    print(jsonString(response.result))
}
