import Foundation
import Testing
@testable import TiriCore

@Suite struct CSVFileTests {
    private func file(_ text: String, name: String = "a.csv", maximumRows: Int = CSVFile.defaultMaximumRows) throws -> CSVFile {
        try file(Data(text.utf8), name: name, maximumRows: maximumRows)
    }

    private func file(_ data: Data, name: String = "a.csv", maximumRows: Int = CSVFile.defaultMaximumRows) throws -> CSVFile {
        let folder = NSTemporaryDirectory() + "tiri-csv-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        return try #require(CSVFile(path: path, maximumRows: maximumRows))
    }

    private func rows(_ file: CSVFile) -> [[String]] { (0..<file.rowCount).map(file.row) }

    @Test func simple() throws {
        let table = try file("a,b\n1,2\n3,4\n")
        #expect(table.header == ["a", "b"])
        #expect(rows(table) == [["1", "2"], ["3", "4"]])
        #expect(table.columnCount == 2)
    }

    @Test func quotesCommasAndNewlines() throws {
        let table = try file("name,note\n\"Doe, J\",\"said \"\"hi\"\"\nthen left\"\nnext,row\n")
        #expect(rows(table) == [["Doe, J", "said \"hi\"\nthen left"], ["next", "row"]])
    }

    @Test func aQuotedLineBreakIsntARow() throws {
        #expect(try file("a\n\"1\n2\n3\"\n4\n").rowCount == 2)
    }

    @Test func aQuoteInsideAFieldIsJustACharacter() throws {
        #expect(rows(try file("a,b\n5\" disk,x\n")) == [["5\" disk", "x"]])
    }

    @Test func windowsLineEndings() throws {
        let table = try file("a,b\r\n1,2\r\n\r\n3,4")
        #expect(rows(table) == [["1", "2"], ["3", "4"]])
    }

    @Test func oldMacLineEndings() throws {
        #expect(rows(try file("a\r1\r2\r")) == [["1"], ["2"]])
    }

    @Test func noFinalNewline() throws {
        #expect(rows(try file("a,b\n1,2")) == [["1", "2"]])
    }

    @Test func blankLinesAreSkipped() throws {
        #expect(rows(try file("a\n\n1\n\n\n2\n")) == [["1"], ["2"]])
    }

    @Test func detectsDelimiters() throws {
        #expect(try file("a\tb\n1\t2\n").header == ["a", "b"])
        #expect(rows(try file("a;b\n1;2\n")) == [["1", "2"]])
        #expect(try file("a|b|c\n").header == ["a", "b", "c"])
        #expect(try file("\"a,b,c\";d\n").header == ["a,b,c", "d"])
        #expect(try file("a,b\tc\n1,2\t3\n", name: "a.tsv").header == ["a,b", "c"])
    }

    @Test func dropsTheByteOrderMark() throws {
        #expect(try file("\u{FEFF}id,name\n1,x\n").header == ["id", "name"])
    }

    @Test func readsLatin1() throws {
        let table = try file(Data("name\nJos\u{E9}\n".utf8.map { $0 }.isEmpty ? [] : [0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x4A, 0x6F, 0x73, 0xE9, 0x0A]))
        #expect(table.row(0) == ["José"])
    }

    @Test func rowsOfDifferentLengths() throws {
        let table = try file("a,b\n1\n1,2,3,4\n")
        #expect(table.columnCount == 4)
        #expect(table.row(0) == ["1"])
        #expect(table.row(1).count == 4)
    }

    @Test func emptyFiles() throws {
        let table = try file("")
        #expect(table.header.isEmpty)
        #expect(table.rowCount == 0)
        #expect(table.row(0).isEmpty)
        let headerOnly = try file("a,b\n")
        #expect(headerOnly.header == ["a", "b"])
        #expect(headerOnly.rowCount == 0)
    }

    @Test func aRowLimitSaysSo() throws {
        let table = try file("a\n1\n2\n3\n4\n", maximumRows: 2)
        #expect(table.isTruncated)
        #expect(rows(table) == [["1"], ["2"]])
        #expect(try file("a\n1\n2\n", maximumRows: 2).isTruncated == false)
    }

    @Test func aMissingFileIsNil() {
        #expect(CSVFile(path: "/nonexistent/a.csv") == nil)
    }

    @Test func survivesLosingItsFile() throws {
        let folder = NSTemporaryDirectory() + "tiri-csv-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/a.csv"
        try Data("a\n1\n2\n3\n".utf8).write(to: URL(fileURLWithPath: path))
        let table = try #require(CSVFile(path: path))
        // An agent cutting it short in place. Asking for what's gone gives nothing, not a crash.
        truncate(path, 2)
        #expect(table.row(2).filter { !$0.isEmpty }.isEmpty)
    }

    @Test func aBoundaryBetweenChunksDoesntMatter() throws {
        // Rows that straddle the 4 MB read size, with quotes and CRLF around it.
        var text = "id,note\r\n"
        let row = "12345,\"a \"\"quoted\"\" note, with comma\"\r\n"
        let count = 4 * 1024 * 1024 / row.utf8.count + 10
        text += String(repeating: row, count: count)
        let table = try file(text)
        #expect(table.rowCount == count)
        #expect(table.row(count - 1) == ["12345", "a \"quoted\" note, with comma"])
        #expect(table.row(count / 2) == ["12345", "a \"quoted\" note, with comma"])
    }

    @Test(arguments: [
        ("12", true), ("-1.5", true), ("1e5", true), ("1,200.50", true), ("$3.00", true), ("45%", true), (" 7 ", true),
        ("abc", false), ("2026-01-02", false), ("nan", false), ("inf", false), ("12a", false), ("-", false),
    ])
    func numbers(cell: String, numeric: Bool) {
        #expect(CSVFile.looksNumeric(cell) == numeric)
    }

    @Test func picksNumericColumns() throws {
        let table = try file("id,name,score,when\n1,a,1.5,2026-01-01\n2,b,,2026-01-02\n3,c,n/a,2026-01-03\n")
        #expect(table.numericColumns() == [0])
        #expect(try file("x\n1\n2\n3\n4\n5\n6\n7\n8\n9\nnone\n").numericColumns() == [0])
    }

    private let searchable = "id,name\n1,alpha\n2,Beta\n3,gamma\n4,beta\n"

    @Test func findsForwardsAndWraps() throws {
        let table = try file(searchable)
        #expect(table.find("beta", from: nil, backwards: false) == 1)
        #expect(table.find("beta", from: 1, backwards: false) == 3)
        #expect(table.find("beta", from: 3, backwards: false) == 1)
        #expect(table.find("zzz", from: nil, backwards: false) == nil)
        #expect(table.find("", from: nil, backwards: false) == nil)
    }

    @Test func findsBackwardsAndWraps() throws {
        let table = try file(searchable)
        #expect(table.find("beta", from: nil, backwards: true) == 3)
        #expect(table.find("beta", from: 3, backwards: true) == 1)
        #expect(table.find("beta", from: 1, backwards: true) == 3)
    }

    @Test func findLeavesTheHeaderOut() throws {
        #expect(try file(searchable).find("name", from: nil, backwards: false) == nil)
    }

    @Test func findCrossesChunks() throws {
        let filler = String(repeating: "x,y\n", count: 4 * 1024 * 1024 / 4 - 1)
        let table = try file("a,b\n" + filler + "needle,1\n" + filler)
        let row = try #require(table.find("NEEDLE", from: nil, backwards: false))
        #expect(table.row(row) == ["needle", "1"])
        #expect(table.find("needle", from: nil, backwards: true) == row)
    }
}
