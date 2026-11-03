import AppKit
import SwiftUI
import TiriCore

/// What an agent changed in one file. An item like any other: a tab, a split or a Peek.
final class DiffController: NSObject, ItemController {
    let itemID: ItemID
    let path: String
    private unowned let model: AppModel
    private let scrollView = NSTextView.scrollableTextView()
    private let textView: DiffTextView
    private let gutter = DiffGutter()
    private let container = DiffContainer()
    private var token: FileWatchHub.Token?
    private var generation = 0
    private var firstLoad = true
    private let message = NSTextField(labelWithString: "")
    private(set) var diff = FileDiff()

    var view: NSView { container }

    init(itemID: ItemID, path: String, model: AppModel) {
        self.itemID = itemID
        self.path = path
        self.model = model
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView = DiffTextView(frame: frame)
        super.init()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000_000, height: 10_000_000)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        gutter.attach(to: scrollView, textView: textView)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        container.install(gutter: gutter, scrollView: scrollView, message: message)
        applySettings()
        token = FileWatchHub.shared.watch(path: path) { [weak self] in self?.load() }
        load()
    }

    /// Other things change the answer too, like a commit. The app asks after any change it sees.
    func load() {
        generation += 1
        let current = generation
        let path = path
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Git.diff(path: path)
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.display(result)
            }
        }
    }

    private func display(_ result: FileDiff) {
        let keepPlace = !firstLoad
        let origin = scrollView.contentView.bounds.origin
        diff = result
        model.controllerRevision += 1
        container.showMessage(result.isBinary ? "This is a binary file. Git can't show its changes line by line."
                              : (result.isEmpty ? "No changes in this file." : nil))
        let text = result.lines.map(\.text).joined(separator: "\n")
        if text != textView.string || firstLoad {
            textView.lines = result.lines
            textView.string = text
            gutter.lines = result.lines
            scheduleHighlight(text)
            if keepPlace {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        gutter.needsDisplay = true
        textView.needsDisplay = true
        firstLoad = false
        AppModel.shared.viewerReady(itemID)
    }

    private func scheduleHighlight(_ text: String) {
        let language = FileClassifier.language(path: path)
        guard (text as NSString).length < 500_000 else { return }
        let current = generation
        Task.detached(priority: .utility) { [weak self] in
            let spans = SyntaxHighlighter.spans(text: text, language: language)
            await MainActor.run {
                guard let self, self.generation == current, let layout = self.textView.layoutManager else { return }
                let full = NSRange(location: 0, length: (self.textView.string as NSString).length)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                for span in spans where NSMaxRange(span.range) <= full.length {
                    layout.addTemporaryAttribute(.foregroundColor, value: span.kind.color, forCharacterRange: span.range)
                }
            }
        }
    }

    func applySettings() {
        let settings = model.settings
        textView.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSize))
        gutter.font = TerminalTheme.font(family: settings.codeFontFamily, size: CGFloat(settings.codeFontSize) - 1)
        textView.needsDisplay = true
    }

    func focus() { textView.window?.makeFirstResponder(textView) }
    func teardown() { token = nil }

    /// The selected rows, by their line numbers in the file as it is now.
    var agentReference: AgentSelection? {
        let string = textView.string as NSString
        let range = textView.selectedRange()
        guard range.length > 0 else { return AgentSelection(path: path) }
        var first = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: range.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in first += 1 }
        if range.location > 0, string.character(at: range.location - 1) != 10 { first = max(first - 1, 0) }
        var count = 0
        string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
        let rows = diff.lines[min(first, diff.lines.count)..<min(first + max(count, 1), diff.lines.count)]
        let numbers = rows.compactMap(\.newLine)
        return AgentSelection(path: path, firstLine: numbers.first.map { $0 - 1 }, lastLine: numbers.last.map { $0 - 1 })
    }

    var supportsFind: Bool { true }

    func find(_ query: String, backwards: Bool) -> Bool {
        let string = textView.string as NSString
        let current = textView.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let start = backwards ? current.location : NSMaxRange(current)
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: string.length - start)
        var found = string.range(of: query, options: options, range: range)
        if found.location == NSNotFound { found = string.range(of: query, options: options) }
        guard found.location != NSNotFound else { return false }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }
}

/// A row's color runs the full width of the pane, past the end of the text.
final class DiffTextView: NSTextView {
    var lines: [DiffLine] = []

    static func color(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.16)
        case .removed: NSColor.systemRed.withAlphaComponent(0.16)
        case .hunk: NSColor.secondaryLabelColor.withAlphaComponent(0.1)
        case .context: nil
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, !lines.isEmpty else { return }
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let string = self.string as NSString
        var lineIndex: Int?
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            if lineIndex == nil {
                // Only the first needs counting. After that they go one at a time.
                var count = 0
                string.enumerateSubstrings(in: NSRange(location: 0, length: character), options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
                lineIndex = count
            }
            if let index = lineIndex, index < self.lines.count, let color = Self.color(for: self.lines[index].kind) {
                color.setFill()
                NSRect(x: 0, y: fragment.minY + self.textContainerInset.height, width: max(self.bounds.width, rect.maxX), height: fragment.height)
                    .fill(using: .sourceOver)
            }
            lineIndex = (lineIndex ?? 0) + 1
        }
    }
}

/// Old and new line numbers, side by side.
final class DiffGutter: NSView {
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    var lines: [DiffLine] = [] { didSet { needsDisplay = true } }
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private let columnWidth: CGFloat = 40
    var thickness: CGFloat { columnWidth * 2 + 8 }

    override var isFlipped: Bool { true }

    func attach(to scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        let string = text.string as NSString
        var index: Int?
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            if index == nil {
                var count = 0
                string.enumerateSubstrings(in: NSRange(location: 0, length: layout.characterIndexForGlyph(at: range.location)),
                                           options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
                index = count
            }
            guard let current = index, current < self.lines.count else { return }
            let line = self.lines[current]
            let y = text.convert(NSPoint(x: 0, y: fragment.minY + text.textContainerInset.height), to: self).y
            if let color = DiffTextView.color(for: line.kind) {
                color.setFill()
                NSRect(x: 0, y: y, width: self.thickness, height: fragment.height).fill(using: .sourceOver)
            }
            for (number, column) in [(line.oldLine, CGFloat(0)), (line.newLine, self.columnWidth)] {
                guard let number else { continue }
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: column + self.columnWidth - size.width - 2, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            }
            index = current + 1
        }
    }
}

final class DiffContainer: NSView {
    private var gutter: DiffGutter?
    private var scrollView: NSScrollView?
    private var message: NSTextField?

    func install(gutter: DiffGutter, scrollView: NSScrollView, message: NSTextField) {
        self.gutter = gutter
        self.scrollView = scrollView
        self.message = message
        addSubview(gutter)
        addSubview(scrollView)
        addSubview(message)
        message.isHidden = true
    }

    func showMessage(_ text: String?) {
        message?.stringValue = text ?? ""
        message?.isHidden = text == nil
        gutter?.isHidden = text != nil
        scrollView?.isHidden = text != nil
    }

    override func layout() {
        super.layout()
        let width = gutter?.thickness ?? 0
        gutter?.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView?.frame = CGRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
        message?.frame = CGRect(x: 20, y: bounds.midY - 12, width: max(bounds.width - 40, 0), height: 24)
        gutter?.needsDisplay = true
    }
}

// MARK: - The sidebar section

struct ChangesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.changes) { change in
                    ChangeRow(change: change)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

struct ChangeRow: View {
    let change: ChangedFile
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var isActive: Bool {
        guard case .diff(let spec)? = model.active.activeItem?.content else { return false }
        return spec.path == change.path
    }

    private var statusColor: Color {
        switch change.status {
        case .modified: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .renamed: .blue
        }
    }

    private var name: String { (change.path as NSString).lastPathComponent }

    private var detail: String {
        let folder = model.active.folder(containing: change.path)
        let relative = folder != nil ? model.active.relativePath(change.path) : change.relative
        let directory = (relative as NSString).deletingLastPathComponent
        guard model.active.folders.count > 1, let folder else { return directory }
        let folderName = (folder as NSString).lastPathComponent
        return directory.isEmpty ? folderName : folderName + " • " + directory
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcons.symbolName(forName: name, isDirectory: false))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            // Dated file names differ at the end, so the middle is what goes.
            Text(name)
                .font(.system(size: 12.5))
                .strikethrough(change.status == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            // Long names give way to this, never the other way round.
            Text(change.status.letter)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .fixedSize()
                .layoutPriority(2)
                .help(change.status.rawValue.capitalized)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click previews, like the explorer. A second keeps it.
        .onTapGesture { model.openDiff(path: change.path, preview: true) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openDiff(path: change.path, preview: false) })
        .contextMenu {
            Button("Open Changes") { model.openDiff(path: change.path, preview: false) }
            if change.status != .deleted {
                Button("Open File") { model.open(path: change.path, intent: .pinned); model.requestFocus() }
            }
            Button("Add to Agent") { model.addFilesToAgent([change.path]) }
            Divider()
            Button("Copy Path") { Clipboard.copy(change.path) }
        }
    }
}
