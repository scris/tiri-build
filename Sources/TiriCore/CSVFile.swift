import Foundation

/// A CSV or TSV file of any size. Reading it only notes where each row starts, and a row is read
/// when it's asked for, so a file of millions of rows costs eight bytes a row. It stays on disk
/// rather than mapped into memory, because an agent cutting a mapped file short would crash the app.
public final class CSVFile: @unchecked Sendable {
    public let delimiter: UInt8
    public let header: [String]
    public let columnCount: Int
    /// Where each row starts, and where the last one ends.
    private let offsets: [Int]
    public let isTruncated: Bool
    private let descriptor: Int32

    public var rowCount: Int { max(offsets.count - 1, 0) }

    /// More than a table can scroll through sensibly.
    public static let defaultMaximumRows = 5_000_000
    /// A row this long isn't data anyone reads in a cell. It's usually a quote that never closes.
    private static let maximumRowBytes = 1024 * 1024

    public init?(path: String, delimiter requested: UInt8? = nil, maximumRows: Int = CSVFile.defaultMaximumRows) {
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        let first = Self.read(descriptor, at: 0, count: 64 * 1024)
        let bom = first.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let separator = requested ?? Self.detectDelimiter(first.dropFirst(bom), path: path)
        delimiter = separator
        let scan = Self.scan(descriptor, from: bom, delimiter: separator, maximumRows: maximumRows + 1)
        isTruncated = scan.truncated
        columnCount = scan.columns
        offsets = scan.offsets.isEmpty ? [] : Array(scan.offsets.dropFirst())
        if scan.offsets.count >= 2 {
            header = Self.fields(Self.read(descriptor, at: scan.offsets[0], count: min(scan.offsets[1] - scan.offsets[0], Self.maximumRowBytes)), delimiter: separator)
        } else {
            header = []
        }
    }

    deinit { close(descriptor) }

    public func row(_ index: Int) -> [String] {
        guard index >= 0, index < rowCount else { return [] }
        let count = min(offsets[index + 1] - offsets[index], Self.maximumRowBytes)
        return Self.fields(Self.read(descriptor, at: offsets[index], count: count), delimiter: delimiter)
    }

    // MARK: Scanning

    private struct Scan {
        var offsets: [Int] = []
        var columns = 0
        var truncated = false
    }

    private static func read(_ descriptor: Int32, at offset: Int, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            let got = pread(descriptor, buffer.baseAddress, count, off_t(offset))
            initialized = max(got, 0)
        }
    }

    private static func scan(_ descriptor: Int32, from start: Int, delimiter: UInt8, maximumRows: Int) -> Scan {
        var result = Scan()
        result.offsets.reserveCapacity(1024)
        let chunkSize = 4 * 1024 * 1024
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { buffer.deallocate() }
        var position = start
        var inQuotes = false
        var justClosed = false
        var fieldHasContent = false
        var rowHasContent = false
        var columns = 1
        var rowStart = start
        var previousWasCR = false
        let quote = UInt8(ascii: "\"")
        scanning: while true {
            let got = pread(descriptor, buffer.baseAddress, chunkSize, off_t(position))
            guard got > 0 else { break }
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[0..<got])
            for index in 0..<got {
                let byte = bytes[index]
                if inQuotes {
                    if byte == quote {
                        inQuotes = false
                        justClosed = true
                    }
                    continue
                }
                if justClosed {
                    justClosed = false
                    // A doubled quote inside a quoted field.
                    if byte == quote {
                        inQuotes = true
                        continue
                    }
                }
                if byte == 10 || byte == 13 {
                    let here = position + index
                    if byte == 10, previousWasCR, here == rowStart {
                        rowStart = here + 1
                        previousWasCR = false
                        continue
                    }
                    if rowHasContent {
                        result.offsets.append(rowStart)
                        result.columns = max(result.columns, columns)
                        // One row past the limit, whose start is where the last one ends.
                        if result.offsets.count > maximumRows {
                            result.truncated = true
                            break scanning
                        }
                    }
                    rowStart = here + 1
                    previousWasCR = byte == 13
                    rowHasContent = false
                    fieldHasContent = false
                    columns = 1
                    continue
                }
                previousWasCR = false
                rowHasContent = true
                if byte == delimiter {
                    columns += 1
                    fieldHasContent = false
                } else {
                    if byte == quote, !fieldHasContent { inQuotes = true }
                    fieldHasContent = true
                }
            }
            position += got
        }
        guard !result.truncated else { return result }
        if rowHasContent {
            result.offsets.append(rowStart)
            result.columns = max(result.columns, columns)
        }
        if !result.offsets.isEmpty { result.offsets.append(position) }
        return result
    }

    /// One row's cells: RFC 4180 quoting, with doubled quotes and newlines inside quotes.
    static func fields(_ bytes: [UInt8], delimiter: UInt8) -> [String] {
        let quote = UInt8(ascii: "\"")
        var cells: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inQuotes {
                if byte == quote {
                    if index < bytes.count, bytes[index] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote, field.isEmpty {
                inQuotes = true
            } else if byte == delimiter {
                cells.append(text(field))
                field.removeAll(keepingCapacity: true)
            } else if byte == 10 || byte == 13 {
                break
            } else {
                field.append(byte)
            }
        }
        cells.append(text(field))
        return cells
    }

    /// UTF-8 where it is, and otherwise what old spreadsheets wrote.
    private static func text(_ bytes: [UInt8]) -> String {
        if let string = String(validating: bytes, as: UTF8.self) { return string }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func detectDelimiter(_ head: ArraySlice<UInt8>, path: String) -> UInt8 {
        let candidates: [UInt8] = [UInt8(ascii: ","), 9, UInt8(ascii: ";"), UInt8(ascii: "|")]
        var counts = [UInt8: Int]()
        var inQuotes = false
        // Commas inside quotes don't count, so a quoted first cell can't mislead it.
        for byte in head {
            if byte == UInt8(ascii: "\"") { inQuotes.toggle() }
            if inQuotes { continue }
            if byte == 10 || byte == 13 { break }
            if candidates.contains(byte) { counts[byte, default: 0] += 1 }
        }
        let tabFirst = (path as NSString).pathExtension.lowercased() == "tsv"
        if tabFirst, counts[9, default: 0] > 0 { return 9 }
        return candidates.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? UInt8(ascii: ",")
    }

    // MARK: Looking at the data

    /// Columns that look like numbers, judged from the first rows, so they can line up on the right.
    public func numericColumns(sampling count: Int = 200) -> Set<Int> {
        var numbers = [Int: Int]()
        var others = [Int: Int]()
        for index in 0..<min(count, rowCount) {
            for (column, cell) in row(index).enumerated() where !cell.isEmpty {
                if Self.looksNumeric(cell) { numbers[column, default: 0] += 1 } else { others[column, default: 0] += 1 }
            }
        }
        return Set(numbers.keys.filter { numbers[$0, default: 0] >= others[$0, default: 0] * 9 })
    }

    static func looksNumeric(_ cell: String) -> Bool {
        var text = Substring(cell.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return false }
        if let first = text.first, "$€£¥".contains(first) { text = text.dropFirst() }
        if text.last == "%" { text = text.dropLast() }
        let plain = text.replacingOccurrences(of: ",", with: "")
        guard plain.first?.isLetter != true else { return false }
        return Double(plain) != nil
    }

    // MARK: Finding

    /// The next row containing the text, ignoring ASCII case, wrapping around. Looks through the
    /// file's bytes rather than its cells, which is quick enough to run through millions of rows.
    public func find(_ query: String, from row: Int?, backwards: Bool, isCancelled: () -> Bool = { false }) -> Int? {
        let needle = Array(query.utf8).map(Self.folded)
        guard !needle.isEmpty, rowCount > 0, let dataStart = offsets.first, let dataEnd = offsets.last else { return nil }
        let origin: Int
        if backwards {
            origin = row.map { offsets[max(min($0, rowCount), 0)] } ?? dataEnd
            return search(needle, in: dataStart..<origin, last: true, isCancelled)
                ?? search(needle, in: origin..<dataEnd, last: true, isCancelled)
        }
        origin = row.map { offsets[min($0 + 1, rowCount)] } ?? dataStart
        return search(needle, in: origin..<dataEnd, last: false, isCancelled)
            ?? search(needle, in: dataStart..<origin, last: false, isCancelled)
    }

    @inline(__always) private static func folded(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private func search(_ needle: [UInt8], in range: Range<Int>, last: Bool, _ isCancelled: () -> Bool) -> Int? {
        let chunk = 4 * 1024 * 1024
        let overlap = needle.count - 1
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            if isCancelled() { return nil }
            let start = last ? max(high - chunk, low) : low
            let end = last ? high : min(low + chunk, high)
            // Overlapping, so a match across two chunks is still found.
            let readStart = last ? start : max(start - overlap, range.lowerBound)
            let readEnd = last ? min(end + overlap, range.upperBound) : end
            let bytes = Self.read(descriptor, at: readStart, count: readEnd - readStart)
            if let hit = Self.match(needle, in: bytes, last: last) { return rowContaining(readStart + hit) }
            if last { high = start } else { low = end }
        }
        return nil
    }

    private static func match(_ needle: [UInt8], in bytes: [UInt8], last: Bool) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        let first = needle[0]
        let limit = bytes.count - needle.count
        func matches(at index: Int) -> Bool {
            guard folded(bytes[index]) == first else { return false }
            for offset in 1..<max(needle.count, 1) where folded(bytes[index + offset]) != needle[offset] { return false }
            return true
        }
        if last {
            var index = limit
            while index >= 0 {
                if matches(at: index) { return index }
                index -= 1
            }
        } else {
            for index in 0...limit where matches(at: index) { return index }
        }
        return nil
    }

    private func rowContaining(_ offset: Int) -> Int {
        var low = 0
        var high = rowCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
