import Foundation

/// Files that aren't UTF-8: found when opened, saved back the same way, and reopened in another by choice.
public enum TextEncodings {
    public struct Choice: Equatable, Sendable {
        public let name: String
        public let encoding: String.Encoding
    }

    private static func cf(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    /// What Reopen with Encoding offers, most used first.
    public static let choices: [Choice] = [
        Choice(name: "UTF-8", encoding: .utf8),
        Choice(name: "UTF-16 Little Endian", encoding: .utf16LittleEndian),
        Choice(name: "UTF-16 Big Endian", encoding: .utf16BigEndian),
        Choice(name: "Western (Windows 1252)", encoding: .windowsCP1252),
        Choice(name: "Western (ISO Latin 1)", encoding: .isoLatin1),
        Choice(name: "Central European (Windows 1250)", encoding: .windowsCP1250),
        Choice(name: "Cyrillic (Windows 1251)", encoding: .windowsCP1251),
        Choice(name: "Cyrillic (KOI8-R)", encoding: cf(.KOI8_R)),
        Choice(name: "Greek (Windows 1253)", encoding: .windowsCP1253),
        Choice(name: "Turkish (Windows 1254)", encoding: .windowsCP1254),
        Choice(name: "Simplified Chinese (GB 18030)", encoding: cf(.GB_18030_2000)),
        Choice(name: "Traditional Chinese (Big 5)", encoding: cf(.big5)),
        Choice(name: "Japanese (Shift JIS)", encoding: .shiftJIS),
        Choice(name: "Japanese (EUC)", encoding: .japaneseEUC),
        Choice(name: "Korean (EUC)", encoding: cf(.EUC_KR)),
        Choice(name: "Mac OS Roman", encoding: .macOSRoman),
    ]

    public static func name(of encoding: String.Encoding) -> String {
        if let choice = choices.first(where: { $0.encoding == encoding }) { return choice.name }
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return (CFStringGetNameOfEncoding(cfEncoding) as String?) ?? String(localized: "Encoding \(encoding.rawValue)")
    }

    public struct Decoded: Sendable {
        public var text: String
        public var encoding: String.Encoding
        /// Saving the text this way gives back exactly these bytes, so it can be edited without damage.
        public var roundTrips: Bool
    }

    /// In the encoding asked for, or else found: UTF-8, then a byte order mark, then what macOS makes of it, then
    /// Windows 1252, which reads any bytes at all. Nil only when the one asked for can't read it.
    public static func decode(_ data: Data, as wanted: String.Encoding? = nil) -> Decoded? {
        func result(_ text: String, _ encoding: String.Encoding) -> Decoded {
            Decoded(text: text, encoding: encoding, roundTrips: encode(text, as: encoding, bom: data) == data)
        }
        if let wanted {
            return String(data: data, encoding: wanted).map { result($0, wanted) }
        }
        if let text = String(data: data, encoding: .utf8) { return result(text, .utf8) }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16) { return result(text, .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return result(text, .utf16BigEndian) }
        var converted: NSString?
        var lossy = ObjCBool(false)
        // No hint: one toward Windows 1252 reads Russian as accented Latin.
        let found = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: &lossy)
        if found != 0, let converted, !lossy.boolValue { return result(converted as String, String.Encoding(rawValue: found)) }
        if let text = String(data: data, encoding: .windowsCP1252) { return result(text, .windowsCP1252) }
        return String(data: data, encoding: .isoLatin1).map { result($0, .isoLatin1) }
    }

    /// The bytes to save. A file that began with a byte order mark keeps one.
    public static func encode(_ text: String, as encoding: String.Encoding, bom original: Data) -> Data? {
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian:
            guard var body = text.data(using: encoding) else { return nil }
            let mark: [UInt8] = encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            // `String(data:encoding: .utf16)` drops the mark from the text, so it goes back on here.
            if original.starts(with: mark), !text.hasPrefix("\u{FEFF}") { body = Data(mark) + body }
            return body
        default:
            return text.data(using: encoding)
        }
    }
}
