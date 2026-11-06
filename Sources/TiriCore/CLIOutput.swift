import Foundation

/// What a `tiri` command prints, given what the app answered. The command itself and the relay for
/// terminals on a server both say the same thing.
public enum CLIOutput {
    private static func jsonString(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cell(_ value: JSONValue?) -> String { value?.stringValue ?? "" }

    /// Plain text for the common listings; JSON for anything structured.
    public static func text(request: ControlRequest, response: ControlResponse) -> String {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line) }
        // A renamed file says where it came from, after a tab, so the first two columns stay the same.
        func sayChanges(_ value: JSONValue?) {
            for entry in value?.arrayValue ?? [] {
                var row = [cell(entry["status"]), cell(entry["path"])]
                if entry["old"] != nil { row.append("from " + cell(entry["old"])) }
                say(row.joined(separator: "\t"))
            }
        }
        switch request.cmd {
        case "items":
            for item in response.result?.arrayValue ?? [] {
                var line = [cell(item["id"]), cell(item["kind"]), cell(item["status"]).isEmpty ? "-" : cell(item["status"]), cell(item["title"])]
                if item["active"]?.boolValue == true { line.append("(active)") }
                if item["peek"]?.boolValue == true { line.append("(peek)") }
                line.append("[\(cell(item["workspace"]))]")
                say(line.joined(separator: "\t"))
            }
        case "askpass":
            say(cell(response.result?["answer"]))
        case "notebook.status", "notebook.run", "notebook.interrupt", "notebook.restart", "notebook.stop", "notebook.input":
            var parts = [cell(response.result?["state"])]
            if let running = response.result?["running"]?.intValue { parts.append("running cell \(running)") }
            if let queued = response.result?["queued"]?.arrayValue, !queued.isEmpty { parts.append("\(queued.count) queued") }
            if let asking = response.result?["asking"]?.stringValue { parts.append("waiting for: " + asking) }
            if let python = response.result?["python"]?.stringValue { parts.append(python) }
            say(parts.joined(separator: "\t"))
        case "web.console", "web.network":
            for line in response.result?.arrayValue ?? [] { say(line.stringValue ?? "") }
        case "web.shot":
            say(cell(response.result?["path"]))
        case "web.text", "web.eval":
            say(response.result?.stringValue ?? "")
        case "web.click", "web.type":
            break
        case "conversations":
            if let path = response.result?["path"]?.stringValue {
                say(path)
            } else {
                for entry in response.result?.arrayValue ?? [] {
                    var line = [cell(entry["session"]), cell(entry["agent"]), cell(entry["when"]), cell(entry["cwd"]), cell(entry["title"])]
                    if let match = entry["match"]?.stringValue, !match.isEmpty { line.append(match) }
                    say(line.joined(separator: "\t"))
                }
            }
        case "work":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["branch"]), cell(entry["summary"]), cell(entry["worktree"])].joined(separator: "\t"))
            }
        case "activity":
            for entry in response.result?.arrayValue ?? [] {
                var line = [cell(entry["item"]), cell(entry["agent"]), cell(entry["status"]), "[\(cell(entry["workspace"]))]"]
                if let prompt = entry["prompt"]?.stringValue { line.append(prompt) }
                if let doing = entry["doing"]?.stringValue { line.append(doing) }
                if let count = entry["files"]?.arrayValue?.count, count > 0 { line.append(count == 1 ? "1 file changed" : "\(count) files changed") }
                say(line.joined(separator: "\t"))
            }
        case "remote.list":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["host"]), cell(entry["state"]), cell(entry["detail"])].joined(separator: "\t"))
            }
        case "remote.ports":
            for entry in response.result?.arrayValue ?? [] {
                say("\(entry["host"]?.stringValue ?? "")\t\(entry["remote"]?.intValue ?? 0) -> localhost:\(entry["local"]?.intValue ?? 0)")
            }
        case "remote.forward":
            say("http://localhost:\(response.result?["local"]?.intValue ?? 0)")
        case "remote.connect", "worktree.add":
            say(cell(response.result?["workspace"]))
        case "remote.disconnect":
            break
        case "workspace.list":
            for workspace in response.result?.arrayValue ?? [] {
                let marker = workspace["active"]?.boolValue == true ? "*" : " "
                let folders = workspace["folders"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
                say("\(marker) \(cell(workspace["name"]))\t\(folders)")
            }
        case "window.list":
            for window in response.result?.arrayValue ?? [] {
                let marker = window["current"]?.boolValue == true ? "*" : " "
                say("\(marker) \(cell(window["id"]))\t\(cell(window["workspace"]))")
            }
        case "window.new", "window.focus":
            say(cell(response.result?["id"]))
        case "window.close":
            break
        case "report":
            say(cell(response.result?["body"]))
            say(cell(response.result?["url"]))
        case "git":
            for repository in response.result?.arrayValue ?? [] {
                let head = cell(repository["head"]) + (repository["dirty"]?.boolValue == true ? "*" : "")
                let counts = repository["upstream"] == nil ? "no upstream" : "\(repository["behind"]?.intValue ?? 0)↓ \(repository["ahead"]?.intValue ?? 0)↑"
                say([head, counts, cell(repository["root"])].joined(separator: "\t"))
            }
        case "read":
            say(cell(response.result?["text"]))
        case "tree":
            for row in response.result?.arrayValue ?? [] { say(cell(row)) }
        case "commands":
            for command in response.result?.arrayValue ?? [] {
                say([cell(command["id"]), cell(command["title"]), cell(command["key"])].joined(separator: "\t"))
            }
        case "ping":
            say("pong")
        case "search":
            for entry in response.result?.arrayValue ?? [] {
                say("\(cell(entry["path"])):\(entry["line"]?.intValue ?? 0): \(cell(entry["text"]))")
            }
        case "changes":
            sayChanges(response.result)
        case "changes.branch":
            for base in response.result?["bases"]?.arrayValue ?? [] {
                say(cell(base["description"]))
            }
            sayChanges(response.result?["changes"])
        case "changes.commit":
            say([cell(response.result?["commit"]?["short"]), cell(response.result?["commit"]?["subject"])].joined(separator: " "))
            sayChanges(response.result?["changes"])
        case "log":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["short"]), cell(entry["when"]), cell(entry["subject"])].joined(separator: "\t"))
            }
        case "diagnostics":
            for entry in response.result?["problems"]?.arrayValue ?? [] {
                say(cell(entry["text"]))
            }
            let checked = response.result?["checked"]?.intValue ?? 0
            let uncovered = response.result?["uncovered"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let count = response.result?["problems"]?.arrayValue?.count ?? 0
            say("\(count) \(count == 1 ? "problem" : "problems") in \(checked) \(checked == 1 ? "file" : "files").")
            if !uncovered.isEmpty { say("No language server answered for: \(uncovered.joined(separator: ", "))") }
        case "agents.list":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["state"]), cell(entry["name"]), cell(entry["command"])].joined(separator: "\t"))
            }
        case "agents.set", "agents.add", "agents.remove":
            break
        case "languages":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["id"]), cell(entry["language"]), cell(entry["state"]), cell(entry["path"])].joined(separator: "\t"))
            }
        case "turns":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["id"]), cell(entry["state"]), cell(entry["title"]), cell(entry["prompt"])].joined(separator: "\t"))
            }
        case "settings.list":
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["key"]), cell(entry["display"])].joined(separator: "\t"))
            }
        case "settings.explain":
            for entry in response.result?.arrayValue ?? [] {
                say("\(cell(entry["key"]))  (\(cell(entry["section"])): \(cell(entry["title"])))")
                say("  \(cell(entry["explanation"]))")
                say("  Now: \(cell(entry["display"]))   Default: \(cell(entry["defaultDisplay"]))   Accepts: \(cell(entry["accepts"]))")
            }
        case "settings.get", "settings.set", "settings.reset":
            say(cell(response.result?["display"]))
        case "hooks.install", "hooks.remove":
            say("Tiri is asking for a yes on screen.")
        case "keys.set", "keys.unset", "keys.reset":
            let key = cell(response.result?["key"])
            say(key.isEmpty ? "no shortcut" : key)
        case "open", "preview", "term":
            if let item = response.result?["item"]?.stringValue { say(item) }
            if let address = response.result?["browser"]?.stringValue {
                say("Opened in the person's own browser, as they asked for this site: \(address). There's no item to drive.")
            }
        case "plugin.list":
            if response.result?.arrayValue?.isEmpty != false {
                say("No plugins yet. Ask your agent for one, or start with tiri plugin new <name>. tiri plugin api explains them.")
            }
            for entry in response.result?.arrayValue ?? [] {
                say([cell(entry["name"]), cell(entry["state"]), cell(entry["version"]), cell(entry["title"]), cell(entry["why"])].joined(separator: "\t"))
            }
        case "plugin.logs":
            say(cell(response.result?["text"]))
        case "plugin.enable", "plugin.remove":
            say("Tiri is asking for a yes on screen. Nothing changes until the person using it presses the button.")
        case "plugin.reload", "plugin.disable", "plugin.update":
            break
        case "plugin.post":
            say("Reached \(response.result?["reached"]?.intValue ?? 0) open panels.")
        case "theme.show", "theme.list", "theme.use", "theme.import", "theme.set", "theme.delete", "theme.new", "theme.rename":
            say(cell(response.result?["text"]))
        case "run":
            if let output = response.result?["output"]?.stringValue, !output.isEmpty { say(output.hasSuffix("\n") ? String(output.dropLast()) : output) }
        case "focus", "close", "notify", "theme", "web-dark", "reveal", "send", "workspace.switch",
             "workspace.new", "workspace.add-folder", "workspace.remove-folder", "workspace.import",
             "workspace.rename", "workspace.delete", "quit", "settings.open", "follow", "diff", "select":
            break
        default:
            say(jsonString(response.result))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
