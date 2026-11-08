import Foundation
import Testing
@testable import TiriCore

/// Every language Tiri ships has every word, in the same shape. See Resources/Localization/README.md.
@Suite struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let languages = ["zh-Hans", "zh-Hant"]

    static func tableURL(_ language: String, _ name: String = "Localizable") -> URL {
        root.appendingPathComponent("Resources/Localization/\(language).lproj/\(name).strings")
    }

    static func table(_ language: String, _ name: String = "Localizable") throws -> [String: String] {
        let data = try Data(contentsOf: tableURL(language, name))
        var table = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        // Work in progress kept beside the tables: every `*.<language>.strings` in TIRI_L10N_PARTS counts too.
        if name == "Localizable", let parts = ProcessInfo.processInfo.environment["TIRI_L10N_PARTS"] {
            let folder = URL(fileURLWithPath: parts)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: parts)) ?? [] where file.hasSuffix(".\(language).strings") {
                let part = try Data(contentsOf: folder.appendingPathComponent(file))
                let words = try #require(try PropertyListSerialization.propertyList(from: part, format: nil) as? [String: String], "\(file) doesn't parse")
                table.merge(words) { old, _ in old }
            }
        }
        return table
    }

    /// `%@`, `%lld`, `%1$@`… in order, with positions taken off, so a translation can reorder them.
    static func formats(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld|llu|ld|lu|lf|d|u|f|%)"#)
        let ns = text as NSString
        var found: [(Int, String)] = []
        for (index, match) in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated() {
            let kind = ns.substring(with: match.range(at: 2))
            if kind == "%" { continue }
            let position = match.range(at: 1).location == NSNotFound ? index + 1 : Int(ns.substring(with: match.range(at: 1)))!
            found.append((position, kind))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test func bothChineseTablesHaveTheSameWordsInTheSameShape() throws {
        for name in ["Localizable", "InfoPlist"] {
            let simplified = try Self.table("zh-Hans", name)
            let traditional = try Self.table("zh-Hant", name)
            let onlySimplified = Set(simplified.keys).subtracting(traditional.keys).sorted()
            let onlyTraditional = Set(traditional.keys).subtracting(simplified.keys).sorted()
            #expect(onlySimplified.isEmpty, "\(name): only in zh-Hans: \(onlySimplified)")
            #expect(onlyTraditional.isEmpty, "\(name): only in zh-Hant: \(onlyTraditional)")
            for (language, table) in [("zh-Hans", simplified), ("zh-Hant", traditional)] {
                for (key, value) in table where name == "Localizable" {
                    #expect(Self.formats(key) == Self.formats(value), "\(language): \"\(key)\" = \"\(value)\" has other formats")
                    #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): \"\(key)\" is empty")
                }
            }
        }
    }

    @Test func noKeyIsListedTwice() throws {
        let regex = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
        for language in Self.languages {
            for name in ["Localizable", "InfoPlist"] {
                let text = try String(contentsOf: Self.tableURL(language, name), encoding: .utf8)
                let ns = text as NSString
                var seen: [String: Int] = [:]
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    seen[ns.substring(with: match.range(at: 1)), default: 0] += 1
                }
                let twice = seen.filter { $0.value > 1 }.keys.sorted()
                #expect(twice.isEmpty, "\(language) \(name) lists these more than once: \(twice)")
            }
        }
    }

    /// A sentence left in English, or one table written in the other's script.
    @Test func eachTableIsInItsOwnScript() throws {
        let simplifiedOnly = Set("们这个时发开关设终显选项删编辑码栏动务换页侧认输进么为应让还无运录对话书载签贴销钮键号线网络帮导览储档类级区库计间处将从")
        let traditionalOnly = Set("們這個時發開關設終顯選項刪編輯碼欄動務換頁側認輸進麼為應讓還無運錄對話書載籤貼銷鈕鍵號線網絡幫導覽儲檔類級區庫計間處將從")
        let simplified = try Self.table("zh-Hans")
        let traditional = try Self.table("zh-Hant")
        func hasChinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        func isSentence(_ key: String) -> Bool { key.split(separator: " ").filter { $0.contains(where: \.isLowercase) }.count >= 3 }
        for (key, value) in simplified {
            let wrong = value.filter(traditionalOnly.contains)
            #expect(wrong.isEmpty, "zh-Hans \"\(key)\" has traditional characters: \(wrong)")
            #expect(!isSentence(key) || hasChinese(value), "zh-Hans \"\(key)\" is still English")
        }
        for (key, value) in traditional {
            let wrong = value.filter(simplifiedOnly.contains)
            #expect(wrong.isEmpty, "zh-Hant \"\(key)\" has simplified characters: \(wrong)")
            #expect(!isSentence(key) || hasChinese(value), "zh-Hant \"\(key)\" is still English")
        }
    }

    @Test func everySettingHasItsWords() throws {
        let tables = try Self.languages.map { try Self.table($0) }
        var words = SettingsPane.allCases.map(\.title)
        let endonyms = Set(AppLanguage.allCases.filter { $0 != .system }.map(\.nativeName))
        for setting in SettingsSchema.all {
            words += [setting.title, setting.explanation, setting.group] + [setting.note].compactMap { $0 }
            switch setting.kind {
            case .choice(let options): words += options.map(\.label).filter { !endonyms.contains($0) }
            case .menu(let groups): words += groups.joined().map(\.label).filter { !endonyms.contains($0) }
            case .list(let placeholder): words.append(placeholder)
            case .text(let placeholder) where !setting.key.hasPrefix("theme."): words.append(placeholder)
            default: break
            }
        }
        for word in Set(words) where !word.isEmpty {
            for (language, table) in zip(Self.languages, tables) {
                #expect(table[word] != nil, "\(language) has nothing for the setting words \"\(word)\"")
            }
        }
    }

    /// A language's name is a name: "Go" must not become the Go menu's 前往. Only the phrases are looked up,
    /// and those, like a server described in words, have their words.
    @Test func languageNamesShowAsTheyAreUnlessThePhrasesHaveWords() throws {
        let tables = try Self.languages.map { try Self.table($0) }
        let names = Set(LanguageServerCatalog.all.map(\.language))
        #expect(LanguageServerDefinition.phrases.isSubset(of: names))
        #expect(LanguageServerCatalog.all.first { $0.id == "go" }?.shownLanguage == "Go")
        let words = LanguageServerDefinition.phrases.union(LanguageServerCatalog.all.compactMap(\.managed?.title).filter { $0.contains(" ") })
        for word in words {
            for (language, table) in zip(Self.languages, tables) {
                #expect(table[word] != nil, "\(language) has nothing for \"\(word)\"")
            }
        }
    }

    @Test func chineseKeepsASpaceBesideLatinAndNoneAfterItsFullStop() {
        #expect(L10n.spaced("JSON和CSS") == "JSON 和 CSS")
        #expect(L10n.spaced("HTML、JSON和CSS") == "HTML、JSON 和 CSS")
        #expect(L10n.sentences(["用于 .go 文件。", "安装方法：go install"]) == "用于 .go 文件。安装方法：go install")
        #expect(L10n.sentences(["For .go files.", "To install it: go install"]) == "For .go files. To install it: go install")
    }

    /// Every literal the app looks up, found the way the compiler makes its key.
    @Test func everyLiteralTheCodeLooksUpIsInBothTables() throws {
        let tables = try Self.languages.map { try Self.table($0) }
        var missing: [String] = []
        for literal in try Self.lookedUpLiterals() {
            for (language, table) in zip(Self.languages, tables) where !literal.isFound(in: table) {
                missing.append("\(language) \(literal.place): \"\(literal.text)\"")
            }
        }
        #expect(missing.isEmpty, "Not translated (\(missing.count)):\n\(missing.sorted().joined(separator: "\n"))")
    }

    struct Literal {
        var text: String
        var place: String
        /// The pieces between interpolations, unescaped.
        var pieces: [String]

        func isFound(in table: [String: String]) -> Bool {
            if pieces.count == 1 { return table[pieces[0]] != nil }
            let specifier = #"%(?:\d+\$)?(?:@|lld|llu|ld|lu|lf|d|u|f)"#
            let pattern = "^" + pieces.map(NSRegularExpression.escapedPattern(for:)).joined(separator: specifier) + "$"
            let regex = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            let (first, last) = (pieces[0], pieces[pieces.count - 1])
            return table.keys.contains {
                $0.hasPrefix(first) && $0.hasSuffix(last) && regex.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
            }
        }

        /// Nothing to translate: symbols, numbers, or only what's interpolated.
        var needsWords: Bool { pieces.joined().contains { $0.isLetter } }
    }

    static let lookups = [
        "String(localized:", "Text(", "Button(", "Label(", ".help(", "Toggle(", "TextField(", "SecureField(", "Menu(",
        "Section(", ".accessibilityLabel(", ".accessibilityHint(", "Picker(", ".navigationTitle(", "ProgressView(",
        "LabeledContent(", "ContentUnavailableView(", ".alert(", ".confirmationDialog(", "L10n.display(",
    ]

    static func lookedUpLiterals() throws -> [Literal] {
        var found: [Literal] = []
        for folder in ["Sources/TiriApp", "Sources/TiriCore"] {
            let url = root.appendingPathComponent(folder)
            // TIRI_L10N_ONLY=A.swift,B.swift looks at those files alone.
            let only = ProcessInfo.processInfo.environment["TIRI_L10N_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") && only.map({ $0.contains(name) }) != false {
                let source = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                found += literals(in: source, file: name)
            }
        }
        return found.filter(\.needsWords)
    }

    static func literals(in source: String, file: String) -> [Literal] {
        // Bytes, not Characters: this runs beside every other test, and slow scanning starves their timeouts.
        let chars = Array(source.utf8)
        var result: [Literal] = []
        var lineStarts: [Int] = [0]
        for (index, byte) in chars.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(index + 1) }
        func line(_ index: Int) -> Int {
            var (low, high) = (0, lineStarts.count - 1)
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
            }
            return low + 1
        }
        func starts(_ word: [UInt8], at index: Int) -> Bool {
            guard index + word.count <= chars.count else { return false }
            for offset in word.indices where chars[index + offset] != word[offset] { return false }
            return true
        }
        func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
        let lookups = Self.lookups.map { Array($0.utf8) }
        let firsts = Set(lookups.compactMap(\.first) + [UInt8(ascii: "/")])
        let comment = Array("//".utf8), quote = UInt8(ascii: "\""), tripleQuote = Array("\"\"\"".utf8)
        var index = 0
        while index < chars.count {
            guard firsts.contains(chars[index]) else { index += 1; continue }
            // Skip comments, so prose about Text("…") doesn't count.
            if starts(comment, at: index) {
                while index < chars.count, chars[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            }
            var matched: [UInt8]?
            for lookup in lookups where starts(lookup, at: index) {
                // Text( but not someText( or verbatim:
                if let first = lookup.first, isWordByte(first), index > 0, isWordByte(chars[index - 1]) { continue }
                matched = lookup
                break
            }
            if let lookup = matched {
                var cursor = index + lookup.count
                while cursor < chars.count, chars[cursor] == UInt8(ascii: " ") { cursor += 1 }
                if cursor < chars.count, chars[cursor] == quote, !starts(tripleQuote, at: cursor), let (pieces, end) = readLiteral(chars, from: cursor) {
                    result.append(Literal(text: String(decoding: chars[cursor + 1..<end - 1], as: UTF8.self), place: "\(file):\(line(index))", pieces: pieces))
                    index = end
                    continue
                }
                index += lookup.count
                continue
            }
            index += 1
        }
        return result
    }

    /// The literal starting at the quote: its pieces between `\(…)`, and the index after its closing quote.
    static func readLiteral(_ chars: [UInt8], from start: Int) -> ([String], Int)? {
        var pieces: [[UInt8]] = [[]]
        var index = start + 1
        let (quote, backslash, open, close) = (UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "("), UInt8(ascii: ")"))
        while index < chars.count {
            let byte = chars[index]
            if byte == quote { return (pieces.map { String(decoding: $0, as: UTF8.self) }, index + 1) }
            if byte == UInt8(ascii: "\n") { return nil }
            if byte == backslash, index + 1 < chars.count {
                let next = chars[index + 1]
                switch next {
                case open:
                    // Skip to the matching parenthesis, past any strings inside it.
                    var depth = 1
                    index += 2
                    var inString = false
                    while index < chars.count, depth > 0 {
                        let c = chars[index]
                        if inString {
                            if c == backslash { index += 1 } else if c == quote { inString = false }
                        } else if c == quote { inString = true }
                        else if c == open { depth += 1 }
                        else if c == close { depth -= 1 }
                        index += 1
                    }
                    pieces.append([])
                    continue
                case UInt8(ascii: "n"): pieces[pieces.count - 1].append(UInt8(ascii: "\n"))
                case UInt8(ascii: "t"): pieces[pieces.count - 1].append(UInt8(ascii: "\t"))
                default: pieces[pieces.count - 1].append(next)
                }
                index += 2
                continue
            }
            pieces[pieces.count - 1].append(byte)
            index += 1
        }
        return nil
    }

    @Test func theScannerReadsKeysAsTheCompilerMakesThem() {
        let found = Self.literals(in: #"""
        Text("Plain") // Text("in a comment")
        Button("Open \(name.isEmpty ? "x" : name)") { }
        let a = String(localized: "Say \"hi\"\n")
        Text(verbatim: "Skipped")
        """#, file: "x")
        #expect(found.map(\.pieces) == [["Plain"], ["Open ", ""], ["Say \"hi\"\n"]])
        #expect(found[1].isFound(in: ["Open %@": "打开 %@"]))
        #expect(!found[1].isFound(in: ["Open": "打开"]))
        #expect(Self.formats("%2$@ in %1$lld") == ["lld", "@"])
    }
}
