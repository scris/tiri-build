import Foundation
import Testing
@testable import TiriCore

@Suite struct RunFilesTests {
    @Test func eachLanguageRunsItsFileByName() throws {
        let python = try #require(RunCommands.plan(for: "/hw/two_sum.py", commands: [:], off: []))
        #expect(python.command == "python3 two_sum.py")
        #expect(python.directory == "/hw")
        #expect(python.tool == "python3")
        #expect(RunCommands.plan(for: "/hw/a.cpp", commands: [:], off: [])?.command == "clang++ -std=c++20 a.cpp -o /tmp/a && /tmp/a")
        #expect(RunCommands.plan(for: "/hw/Main.JAVA", commands: [:], off: [])?.command == "java Main.JAVA")
        #expect(RunCommands.plan(for: "/hw/App.kt", commands: [:], off: [])?.command == "kotlinc App.kt -include-runtime -d /tmp/App.jar && java -jar /tmp/App.jar")
    }

    @Test func namesThatNeedQuotesGetThem() {
        let plan = RunCommands.plan(for: "/my hw/week 1's.c", commands: [:], off: [])
        #expect(plan?.command == "clang 'week 1'\\''s.c' -o '/tmp/week 1'\\''s' && '/tmp/week 1'\\''s'")
    }

    @Test func unknownAndExtensionlessFilesDontRun() {
        #expect(RunCommands.plan(for: "/hw/notes.md", commands: [:], off: []) == nil)
        #expect(RunCommands.plan(for: "/hw/Makefile", commands: [:], off: []) == nil)
    }

    @Test func yourOwnCommandWinsAndOffMeansNoButton() {
        #expect(RunCommands.plan(for: "/a/x.py", commands: ["python": "uv run $file"], off: [])?.command == "uv run x.py")
        #expect(RunCommands.plan(for: "/a/x.py", commands: [:], off: ["python"]) == nil)
        #expect(RunCommands.plan(for: "/a/x.py", commands: ["python": "  "], off: []) == nil)
    }

    @Test func anAddedKindOfFileRunsAndCanBeTurnedOff() {
        let plan = RunCommands.plan(for: "/a/hello.ml", commands: [".ml": "ocaml ${file}"], off: [])
        #expect(plan?.command == "ocaml hello.ml")
        #expect(plan?.key == ".ml")
        #expect(RunCommands.plan(for: "/a/hello.ml", commands: [".ml": "ocaml $file"], off: [".ml"]) == nil)
        // One extension of a language can go its own way.
        #expect(RunCommands.plan(for: "/a/x.mjs", commands: [".mjs": "bun $file"], off: [])?.command == "bun x.mjs")
        #expect(RunCommands.plan(for: "/a/x.js", commands: [".mjs": "bun $file"], off: [])?.command == "node x.js")
    }

    @Test func onlyWholeWordsAreFilledIn() {
        #expect(RunCommands.expand("echo $files $HOME $dir", path: "/w/a.sh") == "echo $files $HOME /w")
        #expect(RunCommands.expand("cat $path", path: "/w/a.sh") == "cat /w/a.sh")
    }

    @Test func theToolIsTheFirstWordAfterVariables() {
        #expect(RunCommands.tool(of: "PYTHONPATH=. python3 $file") == "python3")
        #expect(RunCommands.tool(of: "./build.sh $file") == nil)
        #expect(RunCommands.tool(of: "$HOME/bin/run $file") == nil)
    }

    @Test func shellWordsAreNeverMissingPrograms() {
        #expect(RunCommands.tool(of: "cd $dir && python3 $file") == nil)
        #expect(RunCommands.tool(of: "time python3 $file") == nil)
        #expect(RunCommands.tool(of: "source .venv/bin/activate && python $file") == nil)
    }

    @Test func oneExtensionOfALanguageCanBeTurnedOff() {
        #expect(RunCommands.plan(for: "/a/x.mjs", commands: [:], off: [".mjs"]) == nil)
        #expect(RunCommands.plan(for: "/a/x.js", commands: [:], off: [".mjs"]) != nil)
        #expect(RunCommands.plan(for: "/a/x.php", commands: [:], off: [".PHP"]) == nil)
        #expect(RunCommands.plan(for: "/a/x.php", commands: [:], off: ["PHP"]) == nil)
    }

    @Test func quotesWrittenOutOfHabitDontBreakNamesWithSpaces() {
        #expect(RunCommands.expand(#"python3 "$file""#, path: "/w/my file.py") == "python3 'my file.py'")
        #expect(RunCommands.expand(#"python3 "${file}" -v"#, path: "/w/a.py") == "python3 a.py -v")
        #expect(RunCommands.expand("python3 $file", path: "/w/-x.py") == "python3 ./-x.py")
    }

    @Test func extensionsAreTidied() {
        #expect(RunCommands.tidyExtension(" .KT ") == ".kt")
        #expect(RunCommands.tidyExtension("kt") == ".kt")
        #expect(RunCommands.tidyExtension(".") == nil)
        #expect(RunCommands.tidyExtension("a b") == nil)
    }

    @Test func theSettingsReadAndKeepAddedKindsTidy() throws {
        let settings = try TiriSettings.parse("""
        { "run.button": false, "run.opensIn": "right", "run.commands": { "python": "pypy3 $file", ".ML": "ocaml $file" }, "run.off": ["php"] }
        """)
        #expect(settings.runButton == false)
        #expect(settings.runOpensIn == .right)
        #expect(settings.runCommands == ["python": "pypy3 $file", ".ml": "ocaml $file"])
        #expect(settings.runOff == ["php"])
        let wrong = try TiriSettings.parseReporting(#"{ "run.opensIn": "left" }"#)
        #expect(wrong.problems.first?.key == "run.opensIn")
        #expect(wrong.settings.runOpensIn == .below)
    }

    @Test func theSettingsNoteNamesEveryLanguage() throws {
        let note = try #require(SettingsSchema.definition(for: "run.commands")?.note)
        for language in RunCommands.languages { #expect(note.contains(" \(language.id)"), "\(language.id)") }
        #expect(Set(RunCommands.languages.map(\.id)).count == RunCommands.languages.count)
        let extensions = RunCommands.languages.flatMap(\.extensions)
        #expect(Set(extensions).count == extensions.count)
    }
}
