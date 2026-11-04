import Foundation
import Testing
@testable import TiriCore

@Suite struct SymbolTextTests {
    private func word(_ text: String, _ index: Int) -> String? {
        let string = text as NSString
        return SymbolText.word(in: string, at: index).map { string.substring(with: $0) }
    }

    @Test func findsTheWholeName() {
        #expect(word("let total_price = 1", 6) == "total_price")
        #expect(word("let total_price = 1", 4) == "total_price")
    }

    @Test func aCursorJustAfterANameStillMeansIt() {
        #expect(word("foo.bar", 3) == "foo")
        #expect(word("foo", 3) == "foo")
    }

    @Test func notEverythingIsAName() {
        #expect(word("a + b", 2) == nil)
        #expect(word("x = 123", 5) == nil)
        #expect(word("", 0) == nil)
        #expect(word("   ", 1) == nil)
    }

    @Test func nonASCIINamesCount() {
        #expect(word("let prix_été = 1", 6) == "prix_été")
    }
}

@Suite struct DefinitionPatternTests {
    private func score(_ line: String, _ symbol: String, column: Int = 1) -> Int {
        DefinitionSearch.Patterns(symbol: symbol)!.score(text: line, column: column)
    }

    @Test(arguments: [
        ("class Cart:", "Cart"), ("def total(self):", "total"), ("func total() -> Int {", "total"),
        ("struct Cart {", "Cart"), ("public struct Cart: Codable {", "Cart"), ("enum Kind {", "Kind"),
        ("protocol Viewing: AnyObject {", "Viewing"), ("interface Cart {", "Cart"), ("export function add(a, b) {", "add"),
        ("export class Cart {", "Cart"), ("async function load() {", "load"), ("fn main() {", "main"),
        ("pub fn main() {", "main"), ("pub struct Cart;", "Cart"), ("trait Viewing {", "Viewing"),
        ("type Cart struct {", "Cart"), ("func (c *Cart) Total() int {", "Total"), ("#define LIMIT 3", "LIMIT"),
        ("typealias ID = String", "ID"), ("final class Cart {", "Cart"), ("export default class Cart {", "Cart"),
    ])
    func declarations(line: String, symbol: String) {
        #expect(score(line, symbol) == 5)
    }

    @Test(arguments: [
        ("const add = (a, b) => a + b", "add"), ("let total: Int = 0", "total"), ("var cart = Cart()", "cart"),
        ("static let shared = Tiri()", "shared"), ("let mut count = 0", "count"), ("add: (a, b) => a,", "add"),
        ("add(a, b) {", "add"), ("async load() {", "load"), ("int add(int a, int b) {", "add"), ("void Cart::add(int a)", "add"),
    ])
    func likelyDefinitions(line: String, symbol: String) {
        #expect(score(line, symbol) == 4)
    }

    @Test func aTopLevelAssignmentCountsMoreThanAnIndentedOne() {
        #expect(score("TAX_RATE = 0.2", "TAX_RATE", column: 1) == 4)
        #expect(score("total = 0", "total", column: 5) == 2)
        #expect(score("self.items = []", "items", column: 9) == 2)
    }

    @Test func anExtensionIsALastResort() {
        #expect(score("extension Cart {", "Cart") == 1)
        #expect(score("impl Cart {", "Cart") == 1)
    }

    @Test(arguments: [
        ("return add(a, b)", "add"), ("x = add(1, 2);", "add"), ("if total == 3:", "total"), ("print(total)", "total"),
        ("// class Cart is great", "Cart"), ("# def total(self):", "total"), ("* class Cart", "Cart"),
        ("import Cart", "Cart"), ("from cart import Cart", "Cart"), ("total == 3", "total"), ("new Cart()", "Cart"),
        ("class Cartful:", "Cart"), ("def subtotal(self):", "total"),
    ])
    func usesAreNotDefinitions(line: String, symbol: String) {
        #expect(score(line, symbol) == 0)
    }
}

@Suite struct DefinitionRankingTests {
    private func location(_ path: String, _ line: Int = 1) -> SymbolLocation {
        SymbolLocation(path: path, line: line, column: 1, text: "x")
    }

    @Test func nearestComesFirst() {
        let found = DefinitionSearch.ranked([(location("/p/z/a.py"), 5), (location("/p/src/b.py"), 5), (location("/p/src/here.py"), 5)], near: "/p/src/here.py")
        #expect(found.map(\.path) == ["/p/src/here.py", "/p/src/b.py", "/p/z/a.py"])
    }

    @Test func onlyTheSurestAreShown() {
        let found = DefinitionSearch.ranked([(location("/p/a.swift"), 5), (location("/p/b.swift"), 1)], near: "/p/c.swift")
        #expect(found.map(\.path) == ["/p/a.swift"])
    }

    @Test func anotherLanguageIsALastResort() {
        let both = DefinitionSearch.ranked([(location("/p/a.swift"), 5), (location("/p/b.py"), 5)], near: "/p/c.py")
        #expect(both.map(\.path) == ["/p/b.py"])
        let other = DefinitionSearch.ranked([(location("/p/a.swift"), 5)], near: "/p/c.py")
        #expect(other.map(\.path) == ["/p/a.swift"])
    }

    @Test func relatedLanguagesAreOneFamily() {
        let found = DefinitionSearch.ranked([(location("/p/a.js"), 5), (location("/p/b.py"), 5)], near: "/p/c.tsx")
        #expect(found.map(\.path) == ["/p/a.js"])
    }

    @Test func nothingFoundIsEmpty() {
        #expect(DefinitionSearch.ranked([], near: "/p/a.py").isEmpty)
    }
}

@Suite struct DefinitionFilesTests {
    private func folder(_ files: [String: String]) throws -> (String, [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tiri-def-\(UUID().uuidString)").path
        var paths: [String] = []
        for (name, text) in files {
            let path = root + "/" + name
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            paths.append(path)
        }
        return (root, paths)
    }

    @Test func findsTheDefinitionAcrossFiles() throws {
        let (root, paths) = try folder([
            "src/cart.py": "from src.pricing import apply_discount\n\nx = apply_discount(3)\n",
            "src/pricing.py": "# apply_discount is here\ndef apply_discount(amount):\n    return amount\n",
        ])
        let found = DefinitionSearch.run(paths: paths, symbol: "apply_discount", near: root + "/src/cart.py", cancellation: .init())
        #expect(found.map(\.path) == [root + "/src/pricing.py"])
        #expect(found.first?.line == 2)
        #expect(found.first?.text == "def apply_discount(amount):")
    }

    @Test func caseMatters() throws {
        let (root, paths) = try folder(["a.py": "class cart:\n    pass\nclass Cart:\n    pass\n"])
        let found = DefinitionSearch.run(paths: paths, symbol: "Cart", near: root + "/a.py", cancellation: .init())
        #expect(found.map(\.line) == [3])
        let lower = DefinitionSearch.run(paths: paths, symbol: "cart", near: root + "/a.py", cancellation: .init())
        #expect(lower.map(\.line) == [1])
    }

    @Test func aLongerNameDoesNotCount() throws {
        let (root, paths) = try folder(["a.py": "def total_price():\n    pass\n"])
        #expect(DefinitionSearch.run(paths: paths, symbol: "total", near: root + "/a.py", cancellation: .init()).isEmpty)
    }

    @Test func referencesAreWholeWordsInTheSameLanguage() throws {
        let (root, paths) = try folder([
            "a.py": "def total():\n    pass\nsubtotal = total()\n",
            "b.swift": "let total = 1\n",
        ])
        let found = DefinitionSearch.references(paths: paths, symbol: "total", near: root + "/a.py", cancellation: .init())
        #expect(found.map(\.line) == [1, 3])
        #expect(found.allSatisfy { $0.path == root + "/a.py" })
    }
}
