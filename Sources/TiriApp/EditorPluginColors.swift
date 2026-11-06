import AppKit
import TiriCore

/// Plugins' colors on a file's text. They're worked out as lines are drawn, one line at a time and
/// only for lines on screen, and nothing is stored in the text: the highlighter, find and problems
/// keep their own marks, and a plugin's are laid over them as they're drawn.
final class EditorPluginColors: NSObject, NSLayoutManagerDelegate {
    private weak var textView: NSTextView?
    private let isComment: (Int) -> Bool
    private let hasGrammar: () -> Bool
    private(set) var rules: [EditorHighlightRule] = []
    /// What matched on each line, by where the line starts. Any edit forgets it all: only lines
    /// being drawn are looked at again, which after a keystroke is the one you're on.
    private var found: [Int: [(range: NSRange, rule: Int)]] = [:]
    /// Rules that took too long on a line of this file, by plugin and pattern. They stay off for it,
    /// whatever else changes, since the next line could be as slow.
    private var tooSlow: Set<String> = []
    private var file: String?

    init(textView: NSTextView, isComment: @escaping (Int) -> Bool, hasGrammar: @escaping () -> Bool) {
        self.textView = textView
        self.isComment = isComment
        self.hasGrammar = hasGrammar
    }

    func use(_ rules: [EditorHighlightRule], file: String? = nil) {
        let had = !self.rules.isEmpty
        self.rules = rules
        if let file { self.file = file }
        found = [:]
        guard let layout = textView?.layoutManager else { return }
        // With none, the layout manager doesn't ask, and drawing costs what it always did.
        if rules.isEmpty {
            if layout.delegate === self { layout.delegate = nil }
        } else {
            layout.delegate = self
        }
        if had || !rules.isEmpty { textView?.needsDisplay = true }
    }

    func textChanged() {
        if !found.isEmpty { found = [:] }
    }

    /// For tests and `tiri`: the colored stretches of a line, as offsets in the file.
    func marks(onLineContaining offset: Int) -> [(range: NSRange, rule: Int)] {
        guard let string = textView?.textStorage?.mutableString, offset <= string.length else { return [] }
        let line = string.lineRange(for: NSRange(location: min(offset, string.length), length: 0))
        return marks(in: line, of: string).filter { applies($0) }
    }

    private func marks(in line: NSRange, of string: NSString) -> [(range: NSRange, rule: Int)] {
        if let known = found[line.location] { return known }
        var marks: [(range: NSRange, rule: Int)] = []
        if line.length > 0, line.length <= PluginHighlightPattern.longestLine {
            let text = string.substring(with: line)
            for (index, rule) in rules.enumerated() where !tooSlow.contains(Self.identity(rule)) {
                var matched = PluginHighlightPattern.timedMatches(rule.expression, group: rule.group, in: text)
                // Once more, in case the thread was only kept waiting: a slow pattern is slow every time.
                if matched.tooSlow { matched = PluginHighlightPattern.timedMatches(rule.expression, group: rule.group, in: text) }
                if matched.tooSlow {
                    turnOff(rule)
                    continue
                }
                for range in matched.ranges {
                    marks.append((NSRange(location: line.location + range.location, length: range.length), index))
                }
            }
        }
        found[line.location] = marks
        return marks
    }

    private static func identity(_ rule: EditorHighlightRule) -> String { rule.plugin + "\u{0}" + rule.expression.pattern }

    /// A pattern that runs past its time on one line could on every line, and drawing waits for it.
    private func turnOff(_ rule: EditorHighlightRule) {
        tooSlow.insert(Self.identity(rule))
        // What it found on other lines goes too, so the file doesn't show half of it.
        found = [:]
        let name = file.map { ($0 as NSString).lastPathComponent } ?? "a file"
        PluginProcesses.log(rule.plugin, "highlight \(rule.pattern) took over \(Int(PluginHighlightPattern.budget)) ms on a line of \(name), so it's off for that file. A repeat inside a repeat, like (\\w+\\s?)+, is usually why.\n")
        textView?.needsDisplay = true
    }

    /// Asked as it's drawn, since what's a comment can arrive after the match was found.
    private func applies(_ mark: (range: NSRange, rule: Int)) -> Bool {
        guard rules.indices.contains(mark.rule) else { return false }
        return !rules[mark.rule].onlyInComments || !hasGrammar() || isComment(mark.range.location)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:], forDrawingToScreen toScreen: Bool,
                       atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        guard toScreen, !rules.isEmpty, let string = layoutManager.textStorage?.mutableString, charIndex < string.length else { return attrs }
        let line = string.lineRange(for: NSRange(location: charIndex, length: 0))
        let marks = marks(in: line, of: string)
        guard !marks.isEmpty else { return attrs }
        var limit = NSMaxRange(line)
        if let run = effectiveCharRange?.pointee, run.length > 0, NSLocationInRange(charIndex, run) { limit = min(limit, NSMaxRange(run)) }
        var result = attrs
        var set = Set<NSAttributedString.Key>()
        func put(_ key: NSAttributedString.Key, _ value: Any, overriding: Bool) {
            guard !set.contains(key), overriding || attrs[key] == nil else { return }
            result[key] = value
            set.insert(key)
        }
        for mark in marks {
            if mark.range.location > charIndex {
                limit = min(limit, mark.range.location)
                continue
            }
            guard NSLocationInRange(charIndex, mark.range), applies(mark) else { continue }
            limit = min(limit, NSMaxRange(mark.range))
            let rule = rules[mark.rule]
            // The plugin's color goes over the language's. Find and problems keep theirs.
            if let color = rule.color { put(.foregroundColor, color, overriding: true) }
            if let background = rule.background { put(.backgroundColor, background, overriding: false) }
            if rule.underline {
                put(.underlineStyle, NSUnderlineStyle.single.rawValue, overriding: false)
                put(.underlineColor, rule.color ?? NSColor.labelColor, overriding: false)
            }
            if rule.strikethrough { put(.strikethroughStyle, NSUnderlineStyle.single.rawValue, overriding: true) }
        }
        effectiveCharRange?.pointee = NSRange(location: charIndex, length: max(limit - charIndex, 1))
        return result
    }
}
