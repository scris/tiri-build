import Foundation

/// A remark on an agent's work, waiting to go to it with the others. Reading a change usually
/// raises several, and sending each one as you go interrupts both you and the agent.
public struct ReviewComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    /// Counting from 1, in the file as it was when you commented. Nil for a whole file.
    public var firstLine: Int?
    public var lastLine: Int?
    /// The lines as they were, so the comment can follow them when an agent moves them.
    public var excerpt: String?
    /// What the comment is on when it isn't simply lines of the file, like a diff's rows or a
    /// PDF's text. It's what the agent reads.
    public var quote: String?
    public var quoteIsDiff: Bool
    public var text: String
    public var created: Date

    public init(id: String = TiriID.make("c"), path: String, firstLine: Int? = nil, lastLine: Int? = nil,
                excerpt: String? = nil, quote: String? = nil, quoteIsDiff: Bool = false, text: String, created: Date = Date()) {
        self.id = id
        self.path = path
        self.firstLine = firstLine
        self.lastLine = lastLine ?? firstLine
        self.excerpt = excerpt
        self.quote = quote
        self.quoteIsDiff = quoteIsDiff
        self.text = text
        self.created = created
    }

    public var summary: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// What a comment would be attached to, before anything has been written.
public struct ReviewAnchor: Equatable, Sendable {
    public var path: String
    public var firstLine: Int?
    public var lastLine: Int?
    public var excerpt: String?
    public var quote: String?
    public var quoteIsDiff: Bool

    public init(path: String, firstLine: Int? = nil, lastLine: Int? = nil, excerpt: String? = nil,
                quote: String? = nil, quoteIsDiff: Bool = false) {
        self.path = path
        self.firstLine = firstLine
        self.lastLine = lastLine ?? firstLine
        self.excerpt = excerpt
        self.quote = quote
        self.quoteIsDiff = quoteIsDiff
    }

    public func comment(text: String) -> ReviewComment {
        ReviewComment(path: path, firstLine: firstLine, lastLine: lastLine, excerpt: excerpt, quote: quote,
                      quoteIsDiff: quoteIsDiff, text: text)
    }

    public var description: String {
        let name = (path as NSString).lastPathComponent
        guard let firstLine else { return quote == nil ? name : "the selection in \(name)" }
        let last = lastLine ?? firstLine
        return last == firstLine ? "\(name), line \(firstLine)" : "\(name), lines \(firstLine)–\(last)"
    }
}

public enum ReviewLocator {
    public enum Place: Equatable, Sendable {
        case lines(ClosedRange<Int>)
        /// The lines aren't in the file any more. The comment still stands, and says what it was on.
        case gone
        case wholeFile
    }

    /// Where a comment's lines are now: the copy of them nearest to where they were.
    public static func place(of comment: ReviewComment, in text: String) -> Place {
        guard let first = comment.firstLine else { return .wholeFile }
        let last = comment.lastLine ?? first
        guard let excerpt = comment.excerpt, !excerpt.isEmpty else { return .lines(first...max(first, last)) }
        let wanted = lines(of: excerpt)
        guard !wanted.isEmpty else { return .lines(first...max(first, last)) }
        let all = lines(of: text)
        guard all.count >= wanted.count else { return .gone }
        var best: Int?
        for start in 0...(all.count - wanted.count) where all[start] == wanted[0] {
            guard wanted.indices.allSatisfy({ all[start + $0] == wanted[$0] }) else { continue }
            let line = start + 1
            if best == nil || abs(line - first) < abs(best! - first) { best = line }
        }
        guard let best else { return .gone }
        return .lines(best...(best + wanted.count - 1))
    }

    private static func lines(of text: String) -> [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}

/// The batch, written out as one message for an agent to work through.
public enum ReviewMessage {
    /// A long excerpt would bury the comment. The path and lines are enough for the rest.
    static let maximumExcerptLines = 30

    public static func text(comments: [ReviewComment], cwd: String, fileText: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> String {
        var sections: [String] = []
        for (index, comment) in comments.enumerated() {
            var place = ReviewLocator.Place.wholeFile
            if comment.firstLine != nil {
                if let text = fileText(comment.path) {
                    place = ReviewLocator.place(of: comment, in: text)
                } else {
                    place = .gone
                }
            }
            var header = "\(index + 1). " + relative(comment.path, to: cwd)
            switch place {
            case .lines(let range):
                header += range.count == 1 ? ":\(range.lowerBound)" : ":\(range.lowerBound)-\(range.upperBound)"
            case .gone:
                header += " (this code has changed since the comment)"
            case .wholeFile:
                break
            }
            var section = [header]
            if let quoted = comment.quote ?? comment.excerpt {
                let language = comment.quoteIsDiff ? "diff" : (comment.quote == nil ? (comment.path as NSString).pathExtension : "")
                section.append(fenced(quoted, language: language))
            }
            section.append(comment.text)
            sections.append(section.joined(separator: "\n"))
        }
        let intro = comments.count == 1 ? "A review comment on your work:" : "Review comments on your work. Please go through each one:"
        return intro + "\n\n" + sections.joined(separator: "\n\n") + "\n"
    }

    /// A fence longer than any run of backticks inside it, which code can contain.
    static func fenced(_ text: String, language: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.count > maximumExcerptLines {
            let hidden = lines.count - maximumExcerptLines
            lines = Array(lines.prefix(maximumExcerptLines)) + ["… \(hidden) more line\(hidden == 1 ? "" : "s")"]
        }
        let body = lines.joined(separator: "\n")
        var longest = 0
        var run = 0
        for character in body {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + body + "\n" + fence
    }

    static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

extension Workspace {
    public func reviewComments(on path: String) -> [ReviewComment] {
        review.filter { $0.path == path }
    }
}
