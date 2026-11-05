import Foundation
import TiriCore

/// One text being colored. Its owner tells it about edits as they happen, and hears back with
/// finished lines. Most of its life is on the engine's queue.
public final class HighlightDocument: @unchecked Sendable {
    public struct Update: Sendable {
        /// How many edits it had heard about when it wrote these, so they can be moved if there are more now.
        public var sequence: Int
        public var lineCount: Int
        public var first: Int
        public var lines: [LineTokens]
    }

    private let engine: HighlightEngine
    private let scope: String
    private let deliver: @Sendable (Update) -> Void

    private var id = 0
    private var isOpen = false
    private var failed = false
    private let mirror = TextMirror("")
    private var sequence = 0

    /// The next line to do. Everything from `tokenizedEnd` on has never been done.
    private var next = 0
    private var tokenizedEnd = 0
    /// Lines up to here have to be done before finding the same state as last time means stopping.
    private var dirtyUntil = -1
    private var visible = 0..<0
    private var peekedAt: Int?
    private var batch = 32

    private var pending: [(first: Int, lines: [LineTokens])] = []
    private var lastDelivery: UInt64 = 0

    public init(engine: HighlightEngine = .shared, scope: String, deliver: @escaping @Sendable (Update) -> Void) {
        self.engine = engine
        self.scope = scope
        self.deliver = deliver
        engine.queue.async {
            self.id = self.engine.newID()
            self.engine.add(self)
        }
    }

    public func close() {
        engine.queue.async {
            self.engine.remove(self)
            self.failed = true
            if self.isOpen { self.engine.close(id: self.id) }
        }
    }

    /// All new text.
    public func replaceAll(_ text: String, sequence: Int) {
        engine.queue.async {
            self.sequence = sequence
            self.mirror.replaceAll(text)
            self.pending = []
            self.next = 0
            self.tokenizedEnd = 0
            self.dirtyUntil = -1
            self.peekedAt = nil
            if self.isOpen { self.engine.reset(id: self.id) }
            self.engine.schedule()
        }
    }

    /// `range` is in the text before this edit.
    public func edit(range: NSRange, replacement: String, sequence: Int) {
        engine.queue.async {
            // What's waiting to go out was about the text before this.
            self.flush()
            self.sequence = sequence
            let edit = self.mirror.apply(range: range, replacement: replacement)
            if self.isOpen { self.engine.edit(id: self.id, edit) }
            let difference = edit.inserted - edit.removed
            // A change still making its way down the file. Past where it got to, what's known is from
            // before it, so finding the same state there doesn't yet mean anything has settled.
            let reached = self.dirtyUntil >= 0 ? (self.next > edit.start + edit.removed ? self.next + difference : edit.start + edit.inserted) : -1
            if edit.start + edit.removed < self.tokenizedEnd {
                self.tokenizedEnd += difference
            } else {
                self.tokenizedEnd = min(self.tokenizedEnd, edit.start)
            }
            if self.dirtyUntil > edit.start { self.dirtyUntil += difference }
            self.dirtyUntil = max(self.dirtyUntil, edit.start + edit.inserted, reached)
            self.next = min(self.next, edit.start)
            self.engine.schedule()
        }
    }

    public func show(lines: Range<Int>) {
        engine.queue.async {
            self.visible = lines
            self.engine.schedule()
        }
    }

    // MARK: On the queue

    private var needsPeek: Bool {
        guard !visible.isEmpty, peekedAt != visible.lowerBound else { return false }
        return visible.lowerBound > tokenizedEnd + 2_000
    }

    var hasWork: Bool {
        !failed && (next < mirror.lines.count || needsPeek)
    }

    /// Being typed in, or being looked at with lines yet to color.
    var isUrgent: Bool {
        !failed && (dirtyUntil >= 0 || needsPeek || (!visible.isEmpty && next < visible.upperBound))
    }

    func runSlice() {
        if !isOpen {
            isOpen = engine.open(id: id, scope: scope)
            guard isOpen else {
                failed = true
                return
            }
        }
        if needsPeek {
            peek()
            return
        }
        let table = mirror.lines
        let count = min(batch, table.count - next)
        guard count > 0 else { return }
        let start = table.starts[next]
        let end = next + count < table.count ? table.starts[next + count] : mirror.length
        let text = mirror.text.substring(with: NSRange(location: start, length: end - start))
        let result = engine.tokenize(id: id, start: next, text: text, count: count, budget: 4, dirtyUntil: dirtyUntil, peek: false)
        guard !result.lines.isEmpty else {
            // Nothing can be done with this, and trying again won't change that.
            failed = true
            return
        }
        pending.append((next, result.lines))
        batch = result.lines.count == count ? min(count * 2, 1_024) : max(result.lines.count + 8, 16)
        next += result.lines.count
        tokenizedEnd = max(tokenizedEnd, next)
        var finishedEdit = false
        if result.converged {
            next = tokenizedEnd
            dirtyUntil = -1
            finishedEdit = true
        } else if next >= table.count {
            dirtyUntil = -1
            finishedEdit = true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if finishedEdit || next >= table.count || now - lastDelivery > 16_000_000 {
            flush()
            lastDelivery = now
        }
    }

    /// Lines far ahead of the real pass get a guess: from a nearby line that starts at the margin,
    /// as if nothing were open. VS Code does the same, and the real pass replaces it on arrival.
    private func peek() {
        let table = mirror.lines
        let wanted = visible.clamped(to: 0..<table.count)
        peekedAt = visible.lowerBound
        guard !wanted.isEmpty else { return }
        var first = wanted.lowerBound
        for _ in 0..<100 where first > 0 {
            let start = table.starts[first]
            if start < mirror.length, ![32, 9, 10, 13].contains(mirror.text.character(at: start)) { break }
            first -= 1
        }
        let start = table.starts[first]
        let end = wanted.upperBound < table.count ? table.starts[wanted.upperBound] : mirror.length
        let text = mirror.text.substring(with: NSRange(location: start, length: end - start))
        let result = engine.tokenize(id: id, start: first, text: text, count: wanted.upperBound - first, budget: 0, dirtyUntil: 0, peek: true)
        pending.append((first, result.lines))
        flush()
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let updates = pending
        pending = []
        let sequence = self.sequence
        let lineCount = mirror.lines.count
        for update in updates {
            deliver(Update(sequence: sequence, lineCount: lineCount, first: update.first, lines: update.lines))
        }
    }
}
