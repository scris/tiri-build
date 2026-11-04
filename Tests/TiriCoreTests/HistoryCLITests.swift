import Foundation
import Testing
@testable import TiriCore

@Suite struct HistoryCLITests {
    private let environment = CLIParser.Environment(cwd: "/work", itemID: nil)

    private func request(_ arguments: String...) throws -> ControlRequest {
        guard case .request(let request, _) = try CLIParser.parse(arguments, environment: environment) else {
            throw CLIParser.UsageError("not a request")
        }
        return request
    }

    @Test func webTools() throws {
        #expect(try request("web", "console", "--errors", "--lines", "5").args["lines"]?.intValue == 5)
        #expect(try request("web", "console", "--errors").args["errors"]?.boolValue == true)
        #expect(try request("web", "network", "--failed", "--item", "i-1").args["item"]?.stringValue == "i-1")
        #expect(try request("web", "shot").cmd == "web.shot")
        #expect(try request("web", "click", "#go").args["selector"]?.stringValue == "#go")
        let typed = try request("web", "type", "#q", "hello")
        #expect(typed.args["text"]?.stringValue == "hello")
        #expect(try request("web", "eval", "1+1").args["script"]?.stringValue == "1+1")
        #expect(throws: CLIParser.UsageError.self) { try request("web", "click") }
        #expect(throws: CLIParser.UsageError.self) { try request("web", "explode") }
        #expect(throws: CLIParser.UsageError.self) { try request("web", "console", "--lines", "0") }
    }

    @Test func notebooks() throws {
        let run = try request("notebook", "run", "a.ipynb")
        #expect(run.cmd == "notebook.run")
        #expect(run.args["path"]?.stringValue == "/work/a.ipynb")
        #expect(run.args["cell"] == nil)
        #expect(try request("notebook", "run", "a.ipynb", "--cell", "3").args["cell"]?.intValue == 3)
        for action in ["status", "interrupt", "restart", "stop"] {
            #expect(try request("notebook", action, "a.ipynb").cmd == "notebook." + action)
        }
        #expect(try request("notebook", "input", "a.ipynb", "hello").args["text"]?.stringValue == "hello")
        #expect(throws: CLIParser.UsageError.self) { try request("notebook", "input", "a.ipynb") }
        #expect(throws: CLIParser.UsageError.self) { try request("notebook", "run") }
        #expect(throws: CLIParser.UsageError.self) { try request("notebook", "explode", "a.ipynb") }
        #expect(throws: CLIParser.UsageError.self) { try request("notebook", "status", "a.ipynb", "--cell", "1") }
        #expect(throws: CLIParser.UsageError.self) { try request("notebook", "run", "a.ipynb", "--cell", "-1") }
    }

    @Test func changesScopes() throws {
        #expect(try request("changes").cmd == "changes")
        #expect(try request("changes", "--branch").cmd == "changes.branch")
        let commit = try request("changes", "--commit", "HEAD~1")
        #expect(commit.cmd == "changes.commit")
        #expect(commit.args["commit"]?.stringValue == "HEAD~1")
        #expect(try request("changes", "--turn", "latest").args["turn"]?.stringValue == "latest")
        #expect(throws: CLIParser.UsageError.self) { try request("changes", "--branch", "--commit", "HEAD") }
        #expect(throws: CLIParser.UsageError.self) { try request("changes", "--commit") }
    }

    @Test func diffScopes() throws {
        let commit = try request("diff", "a.txt", "--commit", "abc", "--tab")
        #expect(commit.cmd == "diff")
        #expect(commit.args["path"]?.stringValue == "/work/a.txt")
        #expect(commit.args["commit"]?.stringValue == "abc")
        #expect(commit.args["mode"]?.stringValue == "tab")
        #expect(try request("diff", "a.txt", "--branch").args["branch"]?.boolValue == true)
        #expect(throws: CLIParser.UsageError.self) { try request("diff", "a.txt", "--branch", "--turn", "x") }
    }

    @Test func log() throws {
        #expect(try request("log").cmd == "log")
        #expect(try request("log", "--limit", "5").args["limit"]?.intValue == 5)
        #expect(throws: CLIParser.UsageError.self) { try request("log", "--limit", "none") }
    }

    @Test func theGuideCoversThem() {
        for phrase in ["tiri log", "tiri changes --branch", "tiri changes --commit", "tiri diff src/app.ts --commit"] {
            #expect(AgentGuide.markdown.contains(phrase))
        }
        #expect(CLIParser.usage.contains("tiri log"))
        #expect(CLIParser.usage.contains("--commit <rev>"))
    }
}
