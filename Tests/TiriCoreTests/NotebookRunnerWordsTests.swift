import Foundation
import Testing

/// The kernel's runner, tiri-kernel.py, sends its sentences in English, and the app looks each up. So every one
/// it can send has to be in both tables, the same as a literal in Swift.
@Suite struct NotebookRunnerWordsTests {
    static let script = LocalizationTests.root.appendingPathComponent("Resources/remote/tiri-kernel.py")

    static func sentences() throws -> Set<String> {
        let text = try String(contentsOf: script, encoding: .utf8)
        let patterns = [#"(?:problem|Refused)\(\s*"((?:[^"\\]|\\.)+)""#, #"hint="((?:[^"\\]|\\.)+)""#, #"return "(The kernel[^"]*)", "#]
        var found: Set<String> = []
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.insert(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        return found
    }

    @Test func everySentenceTheRunnerSendsIsInBothTables() throws {
        let sentences = try Self.sentences()
        // So that a change to how they're written can't make this find none and pass.
        #expect(sentences.count >= 15)
        #expect(sentences.contains("The kernel was killed, likely out of memory."))
        for language in LocalizationTests.languages {
            let table = try LocalizationTests.table(language)
            for sentence in sentences.sorted() {
                #expect(table[sentence] != nil, "\(language) has nothing for the runner's \"\(sentence)\"")
            }
        }
    }
}
