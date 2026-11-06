import Foundation
import TiriCore
import WebKit

/// A running cell's outputs, as the kernel's runner sends them: each message says what changed, from an
/// output on. Kept per run, so that a cell that moves takes its outputs with it.
struct NotebookLiveOutputs {
    private var runs: [Int: [Notebook.Output]] = [:]
    private var order: [Int] = []

    mutating func received(_ message: [String: Any]) -> (outputs: [Notebook.Output], from: Int, run: Int?) {
        // Every one counts, even one that can't be shown, or the places after it would be out by one.
        let new = (message["outputs"] as? [Any] ?? []).map { raw in
            (raw as? [String: Any]).flatMap(Notebook.output) ?? .display(data: [:], width: nil, height: nil)
        }
        // A runner from before this sent everything every time.
        guard let run = (message["run"] as? NSNumber)?.intValue else { return (new, 0, nil) }
        let from = max((message["from"] as? NSNumber)?.intValue ?? 0, 0)
        let outputs = Array((runs[run] ?? []).prefix(from)) + new
        if runs[run] == nil { order.append(run) }
        runs[run] = outputs
        while order.count > 4 { runs[order.removeFirst()] = nil }
        return (outputs, min(from, outputs.count), run)
    }
}

/// What the page shows of each running cell's outputs, in pieces: what came before stays, and only what's new
/// is drawn. One drawing at a time per cell, and only the latest of what arrived meanwhile.
@MainActor
final class NotebookOutputPieces {
    typealias Call = @MainActor (_ code: String, _ arguments: [String: Any], _ done: @escaping @MainActor (Bool) -> Void) -> Void

    private struct Latest {
        var outputs: [Notebook.Output]
        var from: Int
        var run: Int?
        var count: Int?
    }

    private struct Cell {
        var run: Int?
        /// The outputs each piece on the page holds.
        var pieces: [Range<Int>] = []
        var drawing = false
        var latest: Latest?
    }

    private var cells: [Int: Cell] = [:]
    private var page = 0

    /// A new page has none of them.
    func reset() {
        page += 1
        cells = [:]
    }

    func show(index: Int, outputs: [Notebook.Output], from: Int, run: Int?, count: Int?, call: @escaping Call) {
        var cell = cells[index] ?? Cell()
        let earliest = cell.latest.map { $0.run == run ? min($0.from, from) : 0 } ?? from
        cell.latest = Latest(outputs: outputs, from: earliest, run: run, count: count)
        cells[index] = cell
        if !cell.drawing { draw(index, call) }
    }

    private func draw(_ index: Int, _ call: @escaping Call) {
        guard var cell = cells[index], let latest = cell.latest else { return }
        cell.latest = nil
        var keep = 0
        if latest.run != nil, cell.run == latest.run {
            keep = cell.pieces.prefix { $0.upperBound <= latest.from }.count
            // Streams run together on the page, so a piece can't end inside one.
            while keep > 0, Self.joins(latest.outputs, at: cell.pieces[keep - 1].upperBound) { keep -= 1 }
        }
        let start = keep > 0 ? cell.pieces[keep - 1].upperBound : 0
        let shown = start <= latest.outputs.count ? Array(latest.outputs[start...]) : []
        cell.drawing = true
        cells[index] = cell
        let page = page
        Task { [weak self] in
            let html = await Task.detached(priority: .userInitiated) { () -> String in
                guard !shown.isEmpty else { return "" }
                let extras = DocumentExtras(renderMath: { MathEngine.shared.markup(tex: $0, display: $1, document: UUID()) }, mathStylesheet: { MathEngine.stylesheet })
                return NotebookRenderer.outputsHTML(shown, extras: extras)
            }.value
            self?.drawn(index, html: html, latest: latest, keep: keep, start: start, page: page, call: call)
        }
    }

    private func drawn(_ index: Int, html: String, latest: Latest, keep: Int, start: Int, page: Int, call: @escaping Call) {
        guard self.page == page else {
            // The page was drawn again meanwhile, so all of it goes on the new one.
            var fresh = cells[index] ?? Cell()
            if fresh.latest == nil { fresh.latest = Latest(outputs: latest.outputs, from: 0, run: nil, count: latest.count) }
            cells[index] = fresh
            if !fresh.drawing { draw(index, call) }
            return
        }
        call("return tiriNB.outputs(cell, html, count, keep)",
             ["cell": index, "html": html, "count": latest.count as Any? ?? NSNull(), "keep": keep]) { [weak self] placed in
            guard let self, self.page == page, var cell = self.cells[index] else { return }
            cell.drawing = false
            if placed {
                cell.run = latest.run
                cell.pieces = Array(cell.pieces.prefix(keep)) + (html.isEmpty ? [] : [start..<latest.outputs.count])
            } else {
                // The page didn't have what was kept, so it gets everything.
                cell.run = nil
                cell.pieces = []
                if cell.latest == nil { cell.latest = Latest(outputs: latest.outputs, from: 0, run: latest.run, count: latest.count) }
            }
            self.cells[index] = cell
            if cell.latest != nil { self.draw(index, call) }
        }
    }

    private static func joins(_ outputs: [Notebook.Output], at boundary: Int) -> Bool {
        guard boundary > 0, boundary < outputs.count,
              case .stream(let before, _) = outputs[boundary - 1], case .stream(let after, _) = outputs[boundary] else { return false }
        return before == after
    }
}

extension WKWebView {
    /// For NotebookOutputPieces: what the page's function said.
    func callNotebookPage(_ code: String, _ arguments: [String: Any], done: @escaping @MainActor (Bool) -> Void) {
        callAsyncJavaScript(code, arguments: arguments, in: nil, in: .defaultClient) { result in
            let placed = (try? result.get()) as? Bool ?? true
            MainActor.assumeIsolated { done(placed) }
        }
    }
}

/// A problem the runner reports: English with `%@` for each argument, looked up in Tiri's own words.
struct NotebookRunnerWords {
    var title: String?
    var detail: String?

    init(_ message: [String: Any]) {
        let arguments = (message["args"] as? [Any] ?? []).map { "\($0)" }
        if let text = message["text"] as? String {
            title = Self.localized(text, arguments)
        } else {
            title = (message["message"] as? String).map(L10n.display)
        }
        let detail = (message["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail?.isEmpty == false ? detail : (message["hint"] as? String).map { Self.localized($0, []) }
    }

    /// Filled in by hand: a format with too few arguments would read past them.
    static func localized(_ text: String, _ arguments: [String]) -> String {
        var result = L10n.display(text)
        for (position, argument) in arguments.enumerated() {
            let numbered = "%\(position + 1)$@"
            if result.contains(numbered) {
                result = result.replacingOccurrences(of: numbered, with: argument)
            } else if let range = result.range(of: "%@") {
                result.replaceSubrange(range, with: argument)
            }
        }
        return result
    }
}
