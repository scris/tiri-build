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

    init(textView: NSTextView, isComment: @escaping (Int) -> Bool, hasGrammar: @escaping () -> Bool) {
        self.textView = textView
        self.isComment = isComment
        self.hasGrammar = hasGrammar
    }

    func use(_ rules: [EditorHighlightRule]) {
        let had = !self.rules.isEmpty
        self.rules = rules
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
            for (index, rule) in rules.enumerated() {
                for range in PluginHighlightPattern.matches(rule.expression, group: rule.group, in: text) {
                    marks.append((NSRange(location: line.location + range.location, length: range.length), index))
                }
            }
        }
        found[line.location] = marks
        return marks
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
