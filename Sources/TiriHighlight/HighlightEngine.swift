import Foundation
import JavaScriptCore
import TiriCore

/// What a piece of code is, as far as its color goes.
public enum TokenKind: UInt8, Sendable, CaseIterable {
    case plain = 0, comment, string, number, keyword, function, type, attribute

    public var className: String {
        switch self {
        case .plain: ""
        case .comment: "tk-comment"
        case .string: "tk-string"
        case .number: "tk-number"
        case .keyword: "tk-keyword"
        case .function: "tk-function"
        case .type: "tk-type"
        case .attribute: "tk-attribute"
        }
    }
}

/// One line's colors. Each entry is start * 8 + kind, and runs until the next entry or the line's end.
public typealias LineTokens = [UInt32]

extension TokenKind {
    public static func of(_ entry: UInt32) -> TokenKind { TokenKind(rawValue: UInt8(entry & 7)) ?? .plain }
    public static func start(of entry: UInt32) -> Int { Int(entry >> 3) }
}

/// TextMate grammars, run in JavaScriptCore on a queue of their own. Everything here stays on that
/// queue, so nothing it does can hold up typing, scrolling or a terminal.
public final class HighlightEngine: @unchecked Sendable {
    /// Inside the app, its Resources folder.
    public static let shared = HighlightEngine(resources: Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))

    let queue = DispatchQueue(label: "tiri.highlight", qos: .userInitiated)
    private let resources: URL
    private var context: JSContext?
    private var api: JSValue?
    private var loadAttempted = false
    private var scopes: [String: String] = [:]
    /// Kept for as long as the engine, since JavaScript's view of it doesn't copy.
    private var wasm: UnsafeMutableRawPointer?
    private var nextID = 1

    private var documents: [HighlightDocument] = []
    private var isPumping = false
    private var turn = 0

    public init(resources: URL) {
        self.resources = resources
    }

    // MARK: Starting

    /// Reads the engine ahead of the first file, so that one's colors aren't late.
    public func prepare() {
        queue.async { _ = self.load() }
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
    }

    @discardableResult
    func load() -> Bool {
        if loadAttempted { return api != nil }
        loadAttempted = true
        guard let context = JSContext(),
              let textmate = read("textmate/vscode-textmate.js"), let oniguruma = read("textmate/vscode-oniguruma.js"), let engine = read("textmate/tiri-engine.js"),
              let wasmData = try? Data(contentsOf: resources.appendingPathComponent("textmate/onig.wasm")),
              let indexData = try? Data(contentsOf: resources.appendingPathComponent("grammars/index.json")),
              let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any] else { return false }
        scopes = index["scopes"] as? [String: String] ?? [:]
        context.exceptionHandler = { _, exception in
            FileHandle.standardError.write(Data("highlight: \(exception?.toString() ?? "unknown")\n".utf8))
        }
        // The libraries were built for places that have these.
        context.evaluateScript("var self = globalThis; var console = { log() {}, warn() {}, error() {} };")
        context.evaluateScript(textmate)
        context.evaluateScript(oniguruma)
        context.evaluateScript(engine)
        guard let api = context.objectForKeyedSubscript("tiri"), api.isObject,
              let buffer = makeBuffer(wasmData, in: context) else { return false }
        let reader: @convention(block) (String) -> Any? = { [weak self] scope in
            self?.grammarJSON(scope: scope) ?? NSNull()
        }
        api.invokeMethod("start", withArguments: [index, buffer, reader])
        self.context = context
        self.api = api
        // The promises above finish as this call returns to the top of JavaScript's stack.
        context.evaluateScript("0")
        guard api.forProperty("engineReady")?.toInt32() == 1 else {
            self.api = nil
            return false
        }
        return true
    }

    private func makeBuffer(_ data: Data, in context: JSContext) -> JSValue? {
        guard let copy = malloc(data.count) else { return nil }
        data.copyBytes(to: copy.assumingMemoryBound(to: UInt8.self), count: data.count)
        wasm = copy
        var exception: JSValueRef?
        let object = JSObjectMakeArrayBufferWithBytesNoCopy(context.jsGlobalContextRef, copy, data.count, nil, nil, &exception)
        return object.flatMap { JSValue(jsValueRef: $0, in: context) }
    }

    private func grammarJSON(scope: String) -> String? {
        guard let name = scopes[scope] else { return nil }
        let file = resources.appendingPathComponent("grammars/\(name).json.z")
        guard let packed = try? Data(contentsOf: file), let plain = try? (packed as NSData).decompressed(using: .zlib) else { return nil }
        return String(data: plain as Data, encoding: .utf8)
    }

    // MARK: Calls into JavaScript. All on the queue.

    func newID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func open(id: Int, scope: String) -> Bool {
        guard load(), let api else { return false }
        api.invokeMethod("open", withArguments: [id, scope])
        context?.evaluateScript("0")
        return api.invokeMethod("status", withArguments: [id])?.toInt32() == 1
    }

    func close(id: Int) { api?.invokeMethod("close", withArguments: [id]) }
    func reset(id: Int) { api?.invokeMethod("reset", withArguments: [id]) }

    func edit(id: Int, _ edit: LineEdit) {
        api?.invokeMethod("edit", withArguments: [id, edit.start, edit.removed, edit.inserted])
    }

    struct Tokenized {
        var lines: [LineTokens]
        var converged: Bool
    }

    func tokenize(id: Int, start: Int, text: String, count: Int, budget: Double, dirtyUntil: Int, peek: Bool) -> Tokenized {
        guard let api, let context else { return Tokenized(lines: [], converged: false) }
        api.invokeMethod("tokenize", withArguments: [id, start, text, count, budget, dirtyUntil, peek])
        let lineCount = Int(api.forProperty("resultLines")?.toInt32() ?? 0)
        let length = Int(api.forProperty("resultLength")?.toInt32() ?? 0)
        let converged = api.forProperty("resultConverged")?.toInt32() == 1
        guard lineCount > 0, let out = api.forProperty("out") else { return Tokenized(lines: [], converged: converged) }
        let contextRef = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSValueToObject(contextRef, out.jsValueRef, &exception),
              let bytes = JSObjectGetTypedArrayBytesPtr(contextRef, object, &exception) else { return Tokenized(lines: [], converged: converged) }
        let values = bytes.assumingMemoryBound(to: Int32.self)
        var lines: [LineTokens] = []
        lines.reserveCapacity(lineCount)
        var at = 0
        while at < length, lines.count < lineCount {
            let written = Int(values[at])
            at += 1
            lines.append(LineTokens(unsafeUninitializedCapacity: written) { buffer, initialized in
                for offset in 0..<written { buffer[offset] = UInt32(bitPattern: values[at + offset]) }
                initialized = written
            })
            at += written
        }
        return Tokenized(lines: lines, converged: converged)
    }

    // MARK: Taking turns

    func add(_ document: HighlightDocument) {
        documents.append(document)
    }

    func remove(_ document: HighlightDocument) {
        documents.removeAll { $0 === document }
    }

    /// Lines get colored a few milliseconds at a time, so an edit never waits long behind a big file.
    func schedule() {
        guard !isPumping else { return }
        isPumping = true
        queue.async { self.pump() }
    }

    private func pump() {
        // What someone's looking at or typing in comes first. Otherwise each gets a turn.
        let waiting = documents.filter(\.hasWork)
        guard !waiting.isEmpty else {
            isPumping = false
            return
        }
        turn &+= 1
        let chosen = waiting.first(where: \.isUrgent) ?? waiting[turn % waiting.count]
        chosen.runSlice()
        queue.async { self.pump() }
    }

    // MARK: A whole piece of text, for a page

    /// Marked-up code for rendered documents. Waits, so it's never for the main thread.
    public func html(code: String, language: String) -> String? {
        guard let scope = LanguageCatalog.language(named: language)?.grammar else { return nil }
        return queue.sync {
            let id = newID()
            guard open(id: id, scope: scope) else { return nil }
            defer { close(id: id) }
            let table = LineTable(code as NSString)
            let tokenized = tokenize(id: id, start: 0, text: code, count: table.count, budget: 0, dirtyUntil: 0, peek: false)
            let text = code as NSString
            var html = ""
            for (index, tokens) in tokenized.lines.enumerated() {
                let start = table.starts[index]
                let end = index + 1 < table.count ? table.starts[index + 1] : text.length
                let line = text.substring(with: NSRange(location: start, length: end - start))
                html += Self.mark(line, tokens: tokens)
            }
            return html
        }
    }

    static func mark(_ line: String, tokens: LineTokens) -> String {
        let text = line as NSString
        var html = ""
        var position = 0
        for (index, entry) in tokens.enumerated() {
            let start = min(TokenKind.start(of: entry), text.length)
            if start > position { html += MarkdownRenderer.escapeText(text.substring(with: NSRange(location: position, length: start - position))) }
            position = start
            let end = index + 1 < tokens.count ? min(TokenKind.start(of: tokens[index + 1]), text.length) : contentEnd(of: text)
            guard end > position else { continue }
            let piece = MarkdownRenderer.escapeText(text.substring(with: NSRange(location: position, length: end - position)))
            let kind = TokenKind.of(entry)
            html += kind == .plain ? piece : "<span class=\"\(kind.className)\">\(piece)</span>"
            position = end
        }
        if position < text.length { html += MarkdownRenderer.escapeText(text.substring(from: position)) }
        return html
    }

    private static func contentEnd(of text: NSString) -> Int {
        var end = text.length
        while end > 0, text.character(at: end - 1) == 10 || text.character(at: end - 1) == 13 { end -= 1 }
        return end
    }

    // MARK: Measuring

    /// The numbers behind the speed budgets, for `tiri perf highlight`. Off the main thread. A new
    /// engine each time, so that first use really is the first use.
    public func measure() -> JSONValue {
        let engine = HighlightEngine(resources: resources)
        let unit = "use std::fmt;\n// note\nstruct P { x: i32 }\nimpl fmt::Display for P {\n    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, \"{}\", self.x) }\n}\n"
        let text = String(repeating: unit, count: 1_666)
        let screenful = String(repeating: unit, count: 10)
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        return engine.queue.sync {
            var result: [String: JSONValue] = ["engine": "textmate", "lines": 10_000]
            result["engineLoadMs"] = .double(milliseconds { _ = engine.load() })
            // From nothing to colors on a screenful, for the smallest common case and for the largest
            // grammar that pulls in many others.
            func firstUse(_ scope: String) -> Double {
                let id = engine.newID()
                defer { engine.close(id: id) }
                return milliseconds {
                    guard engine.open(id: id, scope: scope) else { return }
                    _ = engine.tokenize(id: id, start: 0, text: screenful, count: 60, budget: 0, dirtyUntil: 0, peek: false)
                }
            }
            result["firstUseRustMs"] = .double(firstUse("source.rust"))
            result["firstUseMarkdownMs"] = .double(firstUse("text.html.markdown"))
            let id = engine.newID()
            defer { engine.close(id: id) }
            guard engine.open(id: id, scope: "source.rust") else { return .object(["engine": "textmate", "error": "the grammar didn't load"]) }
            let count = LineTable(text as NSString).count
            var times: [Double] = []
            for _ in 0..<3 {
                engine.reset(id: id)
                times.append(milliseconds { _ = engine.tokenize(id: id, start: 0, text: text, count: count, budget: 0, dirtyUntil: 0, peek: false) })
            }
            result["firstPassMs"] = .double(times[0])
            result["bestPassMs"] = .double(times.min() ?? 0)
            result["visibleLinesMs"] = .double(milliseconds { _ = engine.tokenize(id: id, start: 0, text: screenful, count: 60, budget: 0, dirtyUntil: 60, peek: false) })
            return .object(result)
        }
    }
}
