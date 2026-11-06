import Foundation
import Testing
@testable import TiriCore

@Suite struct TextEncodingsTests {
    @Test func foundAndGivenBackByteForByte() throws {
        let gb = TextEncodings.choices.first { $0.name.contains("GB 18030") }!.encoding
        let samples: [(String, String.Encoding)] = [
            ("Café résumé naïve, déjà vu\n", .windowsCP1252),
            ("中文测试：这是一个文件，包含简体中文。\n", gb),
            ("日本語のテキストファイルです。\n", .shiftJIS),
            ("Привет, мир! Это тест.\n", .windowsCP1251),
        ]
        for (text, encoding) in samples {
            let data = try #require(text.data(using: encoding))
            let decoded = try #require(TextEncodings.decode(data))
            #expect(decoded.text == text)
            #expect(decoded.roundTrips)
            #expect(TextEncodings.encode(decoded.text, as: decoded.encoding, bom: data) == data)
        }
    }

    @Test func utf8StaysUTF8AndAByteOrderMarkStays() throws {
        #expect(TextEncodings.decode(Data("plain ascii\n".utf8))?.encoding == .utf8)
        let marked = Data([0xFF, 0xFE]) + "hi\n".data(using: .utf16LittleEndian)!
        let decoded = try #require(TextEncodings.decode(marked))
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.text == "hi\n")
        #expect(decoded.roundTrips)
    }

    @Test func utf8WithAByteOrderMarkCanBeEditedAndKeepsIt() throws {
        let mark = Data([0xEF, 0xBB, 0xBF])
        let marked = mark + Data("hi\r\n".utf8)
        let decoded = try #require(TextEncodings.decode(marked))
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == "hi\r\n")
        #expect(decoded.roundTrips)
        #expect(TextEncodings.encode("edited", as: .utf8, bom: marked.prefix(4)) == mark + Data("edited".utf8))
        // One without a mark doesn't get one.
        #expect(TextEncodings.encode("edited", as: .utf8, bom: Data("hi".utf8)) == Data("edited".utf8))
    }

    @Test func aChoiceThatCantReadItSaysSo() {
        let latin = "été".data(using: .isoLatin1)!
        #expect(TextEncodings.decode(latin, as: .utf8) == nil)
        #expect(TextEncodings.decode(latin, as: .isoLatin1)?.text == "été")
    }
}
