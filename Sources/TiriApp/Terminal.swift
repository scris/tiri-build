import AppKit
import Darwin
@preconcurrency import SwiftTerm
import TiriCore
import UniformTypeIdentifiers

/// Anything that can sit in a tab. Terminals, file viewers and web views are all one of these.
@MainActor
enum SaveResult {
    case saved
    /// The file changed on disk since it was opened here. Saving would replace that.
    case changedOnDisk
    case failed(String)
}

protocol ItemController: AnyObject {
    var itemID: ItemID { get }
    var view: NSView { get }
    func focus()
    func didAttach()
    func applySettings()
    func goTo(line: Int?, col: Int?)
    func teardown()
    var supportsFind: Bool { get }
    var selectedTextForFind: String? { get }
    /// What ⌘L adds to an agent, if this item has something more specific than its whole file.
    var agentReference: AgentSelection? { get }
    /// What a review comment made here would be on, and where to show the box for writing it.
    var reviewAnchor: ReviewAnchor? { get }
    var reviewPopoverPosition: (view: NSView, rect: NSRect)? { get }
    /// Review comments on this file were added, changed or removed.
    func reviewChanged()
    /// Selects text, as someone could with the mouse. For agents pointing at something.
    func select(text: String, to end: String?) -> Bool
    var isDirty: Bool { get }
    func save(overwriting: Bool) -> SaveResult
    /// Puts unsaved edits somewhere they outlive Tiri. False if there are some it can't keep.
    func keepUnsavedEdits() -> Bool
    /// Returns false when nothing matches.
    func find(_ query: String, backwards: Bool) -> Bool
    /// While it's being typed, a match already found stays found.
    func findIncrementally(_ query: String, caseSensitive: Bool) -> Bool
    func clearFind()
    /// Which match this is and how many there are, where that's known.
    var findCount: (current: Int, total: Int)? { get }
    var findReturnGoesBackwards: Bool { get }
    var supportsReplace: Bool { get }
    func replaceCurrent(query: String, with replacement: String, caseSensitive: Bool) -> Bool
    func replaceAll(query: String, with replacement: String, caseSensitive: Bool) -> Int
    /// What its editor holds, when that isn't saved yet.
    var unsavedText: String? { get }
}

extension ItemController {
    func keepUnsavedEdits() -> Bool { !isDirty }
    func didAttach() {}
    func applySettings() {}
    func goTo(line: Int?, col: Int?) {}
    func teardown() {}
    var supportsFind: Bool { false }
    var selectedTextForFind: String? { nil }
    var agentReference: AgentSelection? { nil }
    /// Whatever ⌘L would take, as a comment's subject. Viewers with lines of their own say more.
    var reviewAnchor: ReviewAnchor? {
        guard let reference = agentReference else { return nil }
        guard let first = reference.firstLine else {
            return ReviewAnchor(path: reference.path, quote: reference.quote.map(ReviewQuote.body))
        }
        let last = reference.lastLine ?? first
        return ReviewAnchor(path: reference.path, firstLine: first + 1, lastLine: last + 1,
                            excerpt: ReviewQuote.lines(first + 1, last + 1, of: reference.path))
    }
    var reviewPopoverPosition: (view: NSView, rect: NSRect)? { nil }
    func reviewChanged() {}
    func select(text: String, to end: String?) -> Bool { false }
    var isDirty: Bool { false }
    func save(overwriting: Bool) -> SaveResult { .saved }
    func find(_ query: String, backwards: Bool) -> Bool { false }
    func findIncrementally(_ query: String, caseSensitive: Bool) -> Bool { find(query, backwards: false) }
    func clearFind() {}
    var findCount: (current: Int, total: Int)? { nil }
    var findReturnGoesBackwards: Bool { false }
    var unsavedText: String? { nil }
    var supportsReplace: Bool { false }
    func replaceCurrent(query: String, with replacement: String, caseSensitive: Bool) -> Bool { false }
    func replaceAll(query: String, with replacement: String, caseSensitive: Bool) -> Int { 0 }
}

// MARK: - Spawning, behind a protocol so a remote (SSH) backend can be added

struct TerminalLaunch {
    var executable: String
    var args: [String]
    var execName: String?
    var environment: [String]
    var cwd: String
}

protocol TerminalBackend {
    func launch(command: String?, cwd: String, shell: String, itemID: ItemID, workspaceID: WorkspaceID, socket: String) -> TerminalLaunch
}

struct LocalTerminalBackend: TerminalBackend {
    func launch(command: String?, cwd: String, shell: String, itemID: ItemID, workspaceID: WorkspaceID, socket: String) -> TerminalLaunch {
        let shellPath = shell.isEmpty
            ? (ProcessInfo.processInfo.environment["SHELL"] ?? userShell())
            : shell
        var environment = ProcessInfo.processInfo.environment
        let ownPluginFolders = environment["CLAUDE_CODE_PLUGIN_DIRS"]
        // Nothing from whatever launched Tiri should leak in. If Tiri was started from inside an
        // agent session, a terminal's agent would think it's a child of that session.
        for key in environment.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE"
            || key == "TERM_SESSION_ID" || key == "ITERM_SESSION_ID" || key == "__CF_USER_TEXT_ENCODING"
            || key == "TIRI_ITEM_ID" || key == "TIRI_WORKSPACE" {
            environment[key] = nil
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tiri"
        environment["TERM_PROGRAM_VERSION"] = TiriCoreVersion.string
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TIRI_SOCKET"] = socket
        environment["TIRI_WORKSPACE"] = workspaceID
        environment["TIRI_ITEM_ID"] = itemID
        // How Claude Code finds Tiri as its editor. It's asked to connect, and it decides.
        let bridge = AppModel.shared.editorBridge
        if bridge.port != 0 {
            environment["CLAUDE_CODE_SSE_PORT"] = String(bridge.port)
            environment["ENABLE_IDE_INTEGRATION"] = "true"
        }
        // Plugins' parts for Claude Code, in Tiri's terminals only, beside any you'd set yourself. One folder,
        // holding copies of what you approved, so a shell that's already open follows plugins coming and going.
        environment["CLAUDE_CODE_PLUGIN_DIRS"] = ((ownPluginFolders.map { [$0] } ?? []) + [ClaudeParts.folder.path]).joined(separator: ":")
        // `tiri` works in every Tiri terminal, wherever the CLI was installed.
        if let helpers = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            environment["PATH"] = helpers + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        let list = environment.map { "\($0.key)=\($0.value)" }
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()

        let name = (shellPath as NSString).lastPathComponent
        var program: [String]
        var execName: String
        if let command, !command.trimmingCharacters(in: .whitespaces).isEmpty {
            // An interactive login shell, so the user's aliases and PATH apply: the command
            // behaves as it does when they type it in their own terminal.
            program = [shellPath, "-l", "-i", "-c", command]
            execName = name
        } else {
            program = [shellPath, "-l"]
            execName = "-" + name
        }
        // With a session, the program runs under a small server that outlives Tiri.
        if AppModel.shared.settings.terminalKeepRunning, let helper = TerminalSessions.helper {
            TerminalSessions.prepareDirectory()
            let arguments = ["attach", TerminalSessions.socketPath(for: itemID), "--cwd", directory, "--argv0", execName, "--"] + program
            return TerminalLaunch(executable: helper, args: arguments, execName: "tiri-session", environment: list, cwd: directory)
        }
        return TerminalLaunch(executable: program[0], args: Array(program.dropFirst()), execName: execName, environment: list, cwd: directory)
    }

    private func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }
}

// MARK: - The terminal view

final class TiriTerminalView: LocalProcessTerminalView {
    weak var owner: TerminalController?
    private var alreadyAskedServer = false
    private var underlines: [CALayer] = []
    private var hoverKey: String?
    private var hoverTarget: LinkTarget?
    /// The last answer for the cell under the mouse, which asks again with each pixel it moves.
    private var lastResolution: (key: String, time: Date, result: (LinkTarget, LogicalLine, Range<Int>)?)?
    private var swallowNextMouseUp = false

    /// Whether what's running asked for pasted text to be marked as a paste, so that a line break in it
    /// isn't taken as pressing Return. SwiftTerm keeps its terminal to itself on a Mac, and this is only
    /// looked at when something's about to be pasted. Not being able to tell counts as no.
    var holdsPastes: Bool {
        swiftTermTerminal?.bracketedPasteMode ?? false
    }

    /// SwiftTerm's own terminal, which a Mac view doesn't hand out.
    private var swiftTermTerminal: Terminal? {
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
            for child in current.children where child.label == "terminal" {
                if let terminal = child.value as? Terminal { return terminal }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    /// Where a hyperlink a program printed (OSC 8) really goes, if there's one at this screen cell.
    /// Read here so that SwiftTerm never gets the click: its own handling puts up a "Link blocked"
    /// alert for targets it can't open itself, such as a path with no scheme or `file://host/…`.
    func hyperlinkTarget(row: Int, column: Int) -> String? {
        guard row >= 0, column >= 0, let terminal = swiftTermTerminal else { return nil }
        return terminal.terminalLock.withLock {
            terminal.link(at: .screen(Position(col: column, row: row)), mode: .explicitOnly)
        }
    }

    enum LinkTarget {
        case choice([ResolvedPath])
        case path(ResolvedPath)
        case web(URL)
    }

    // MARK: VoiceOver

    /// SwiftTerm draws text without telling VoiceOver any of it on a Mac. This is the screen and
    /// recent history as a text area, the way Terminal shows it: lines to read, and the cursor,
    /// with new output arriving as SwiftTerm's value-changed notices.
    private struct SpokenText {
        var text: NSString
        var lineStarts: [Int]
        var rows: [Int]
        var cursor: Int
        var liveTopRow: Int
        var taken: CFTimeInterval
    }
    private var spokenText: SpokenText?

    private var spoken: SpokenText {
        let now = CACurrentMediaTime()
        // VoiceOver asks a burst of questions at once; one copy of the screen answers them all.
        if let spokenText, now - spokenText.taken < 0.25 { return spokenText }
        var lines: [String] = []
        var rows: [Int] = []
        var cursorRow = 0, cursorColumn = 0, liveTopRow = 0
        if let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: 500)) {
            lines = snapshot.rows.map(\.text)
            rows = snapshot.rows.map(\.absoluteRow)
            cursorRow = snapshot.cursorRow
            cursorColumn = snapshot.cursorColumn
            liveTopRow = snapshot.liveTopRow
            // Blank rows under the cursor are empty screen, not lines.
            while lines.count > 1, let last = rows.last, last > cursorRow, lines.last?.allSatisfy(\.isWhitespace) == true {
                lines.removeLast()
                rows.removeLast()
            }
        }
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        let text = lines.joined(separator: "\n") as NSString
        var cursor = text.length
        if let index = rows.firstIndex(of: cursorRow) {
            cursor = min(starts[index] + cursorColumn, starts[index] + (lines[index] as NSString).length)
        }
        let result = SpokenText(text: text, lineStarts: starts.isEmpty ? [0] : starts, rows: rows, cursor: cursor, liveTopRow: liveTopRow, taken: now)
        spokenText = result
        return result
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { String(localized: "terminal") }
    override func accessibilityLabel() -> String? {
        guard let owner, let item = owner.model.anyItem(owner.itemID) else { return String(localized: "Terminal") }
        return owner.model.title(for: item)
    }
    override func accessibilityValue() -> Any? { spoken.text as String }
    override func accessibilityNumberOfCharacters() -> Int { spoken.text.length }
    override func accessibilitySelectedText() -> String? { getSelection() ?? "" }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: spoken.cursor, length: 0) }
    override func accessibilityInsertionPointLineNumber() -> Int { accessibilityLine(for: spoken.cursor) }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: spoken.text.length) }

    override func accessibilityLine(for index: Int) -> Int {
        let starts = spoken.lineStarts
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let current = spoken
        guard current.lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let start = current.lineStarts[line]
        let end = line + 1 < current.lineStarts.count ? current.lineStarts[line + 1] : current.text.length
        return NSRange(location: start, length: max(end - start, 0))
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = spoken.text
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        return text.substring(with: clamped)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    /// Where a line is on screen, so VoiceOver's cursor sits on it. Lines scrolled out of the live screen get the top row.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let current = spoken
        let line = accessibilityLine(for: range.location)
        let size = cellSize
        guard let window, size.height > 0, current.rows.indices.contains(line) else { return accessibilityFrame() }
        let screenRow = max(current.rows[line] - current.liveTopRow, 0)
        let column = range.location - current.lineStarts[line]
        let local = NSRect(x: CGFloat(column) * size.width, y: bounds.height - CGFloat(screenRow + 1) * size.height,
                           width: max(CGFloat(max(range.length, 1)) * size.width, size.width), height: size.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: Bell

    nonisolated override func bell(source: Terminal) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.owner?.bellRang() }
        }
    }

    // MARK: Cmd-click

    override func mouseDown(with event: NSEvent) {
        dissolvePeekTip()
        // Every ⌘-click is Tiri's: a hyperlink goes where it points, and anything that looks like a
        // path is found. SwiftTerm only sees one that's neither, so it never puts up "Link blocked";
        // should it still, `BlockedLinks` takes the alert over.
        if event.modifierFlags.contains(.command) {
            BlockedLinks.clicked = (self, Date(), event.modifierFlags.contains(.shift))
            let forceTab = event.modifierFlags.contains(.shift)
            let local = convert(event.locationInWindow, from: nil)
            let size = cellSize
            let cell: (row: Int, column: Int)? = size.width > 0 && size.height > 0
                ? (Int((bounds.height - local.y) / size.height), Int(local.x / size.width)) : nil
            var followed = false
            if let cell, let target = hyperlinkTarget(row: cell.row, column: cell.column) {
                openHyperlink(target, forceTab: forceTab)
                followed = true
            }
            if !followed {
                followed = followLink(in: logicalLines(atWindowPoint: event.locationInWindow), forceTab: forceTab)
            }
            if !followed, let cell {
                followed = followLocationUnderPath(row: cell.row, column: cell.column, forceTab: forceTab)
            }
            if followed {
                swallowNextMouseUp = true
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowNextMouseUp {
            swallowNextMouseUp = false
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if swallowNextMouseUp { return }
        super.mouseDragged(with: event)
    }

    private func open(_ target: LinkTarget, forceTab: Bool) {
        guard let model = owner?.model else { return }
        switch target {
        case .path(let resolved):
            model.openFromTerminal(resolved, forceTab: forceTab)
        case .choice(let matches):
            model.chooseFromTerminal(matches, forceTab: forceTab)
        case .web(let url):
            if let destination = owner?.remoteDestination {
                model.openWebFromTerminal(url, forceTab: forceTab, from: destination)
            } else {
                model.openWebFromTerminal(url, forceTab: forceTab)
            }
        }
    }

    func openHyperlink(_ link: String, forceTab: Bool) {
        guard let model = owner?.model else { return }
        let url = URL(string: link)
        if let url, url.isFileURL {
            model.openFromTerminal(ResolvedPath(path: url.path, isDirectory: false), forceTab: forceTab)
        } else if let url, url.scheme == "http" || url.scheme == "https" {
            if let destination = owner?.remoteDestination {
                model.openWebFromTerminal(url, forceTab: forceTab, from: destination)
            } else {
                model.openWebFromTerminal(url, forceTab: forceTab)
            }
        } else if url?.scheme == nil {
            // A target like `/resume/index.html` is a path that needs finding.
            let candidate = PathCandidate(path: link, range: 0..<0)
            let found = pathResolver()?.resolveAll(candidate) ?? []
            if found.isEmpty {
                searchAgain(for: link, forceTab: forceTab) { [weak self] in self?.pathResolver()?.resolveAll(candidate) ?? [] }
            } else {
                model.chooseFromTerminal(found, forceTab: forceTab)
            }
        } else {
            let title = url?.scheme.map { String(localized: "Tiri doesn't open \($0) links") } ?? String(localized: "Tiri doesn't open these links")
            model.showToast(title: title, detail: link, symbol: "link", tint: .secondary)
        }
    }

    /// Nothing matched yet. The file may be newer than the index, so look again before saying so.
    /// What a ⌘-click does, and what `tiri follow` does.
    /// Returns false when the text there isn't a link and doesn't look like a path at all.
    func followLink(row: Int, column: Int, forceTab: Bool) -> Bool {
        if let target = hyperlinkTarget(row: row, column: column) {
            openHyperlink(target, forceTab: forceTab)
            return true
        }
        if followLink(in: logicalLines(row: row, column: column), forceTab: forceTab) { return true }
        return followLocationUnderPath(row: row, column: column, forceTab: forceTab)
    }

    private func followLocationUnderPath(row: Int, column: Int, forceTab: Bool) -> Bool {
        guard let found = locationUnderPath(row: row, column: column) else { return false }
        open(found.target, forceTab: forceTab)
        return true
    }

    private func followLink(in variants: [(line: LogicalLine, column: Int)], forceTab: Bool) -> Bool {
        for variant in variants {
            if let (target, _) = resolveLink(in: variant.line, column: variant.column) {
                open(target, forceTab: forceTab)
                return true
            }
        }
        let candidates = variants.flatMap { PathLinkDetector.candidates(atColumn: $0.column, in: $0.line.text) }
        // A bare word isn't a path, and nor is a sentence with a path in it, like an error message.
        // It may be the label of a real hyperlink.
        guard let shown = candidates.first(where: { !$0.path.contains(" ") && ($0.path.contains("/") || $0.path.contains(".")) })?.path else { return false }
        searchAgain(for: shown, forceTab: forceTab) { [weak self] in
            guard let resolver = self?.pathResolver() else { return [] }
            for variant in variants {
                let matches = resolver.resolveAll(atColumn: variant.column, in: variant.line.text)
                if !matches.isEmpty { return matches }
            }
            return []
        }
        return true
    }

    private func searchAgain(for shown: String, forceTab: Bool, find: @escaping () -> [ResolvedPath]) {
        guard let owner else { return }
        // On a server the copy only holds the workspace's folders. It may be anywhere else there.
        if !alreadyAskedServer, let destination = owner.remoteDestination, let connection = owner.model.remote.existingConnection(destination),
           let resolver = pathResolver() {
            let candidates = resolver.candidatePaths(of: shown).compactMap { connection.map.remote($0) }
            Task { [weak self] in
                let known = await Task.detached(priority: .userInitiated) { () -> Bool in
                    candidates.contains { connection.learn(remote: $0) != nil }
                }.value
                guard let self else { return }
                if known {
                    let matches = find()
                    if !matches.isEmpty {
                        owner.model.chooseFromTerminal(matches, forceTab: forceTab)
                        return
                    }
                }
                self.alreadyAskedServer = true
                self.searchAgain(for: shown, forceTab: forceTab, find: find)
                self.alreadyAskedServer = false
            }
            return
        }
        owner.model.rebuildLinkIndexes(for: owner.itemID) { [weak self] in
            guard let model = self?.owner?.model else { return }
            let matches = find()
            if !matches.isEmpty {
                model.chooseFromTerminal(matches, forceTab: forceTab)
                return
            }
            model.showToast(title: String(localized: "No file matches \(shown)"),
                            detail: String(localized: "Searched this workspace's folders, terminals and open files."),
                            symbol: "magnifyingglass", tint: .secondary)
        }
    }

    func hoverEvent(_ event: NSEvent) {
        guard window != nil, event.window === window else {
            clearHover()
            return
        }
        guard event.modifierFlags.contains(.command) else {
            clearHover()
            return
        }
        if let owner { owner.model.warmLinkIndexes(for: owner.itemID) }
        let point = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        let local = convert(point, from: nil)
        guard bounds.contains(local), !pointIsCoveredByPeek(point) else {
            clearHover()
            return
        }
        guard let (target, logical, range) = resolveAt(windowPoint: point) else {
            clearHover()
            return
        }
        hoverTarget = target
        drawUnderline(logical: logical, range: range)
        NSCursor.pointingHand.set()
    }

    private func pointIsCoveredByPeek(_ windowPoint: NSPoint) -> Bool {
        guard let model = owner?.model, let frame = model.layoutRegistry.peekFrame,
              let height = window?.contentView?.bounds.height else { return false }
        return frame.contains(CGPoint(x: windowPoint.x, y: height - windowPoint.y))
    }

    private func clearHover() {
        guard hoverTarget != nil || !underlines.isEmpty else { return }
        hoverTarget = nil
        underlines.forEach { $0.removeFromSuperlayer() }
        underlines.removeAll()
        NSCursor.iBeam.set()
    }

    private func linkTarget(forWindowPoint point: NSPoint) -> LinkTarget? {
        resolveAt(windowPoint: point)?.0
    }

    private func resolveAt(windowPoint point: NSPoint) -> (LinkTarget, LogicalLine, Range<Int>)? {
        let local = convert(point, from: nil)
        let size = cellSize
        guard size.width > 0, size.height > 0 else { return nil }
        return resolveAt(row: Int((bounds.height - local.y) / size.height), column: Int(local.x / size.width))
    }

    /// What `tiri dev-hover` asks: the hover's answer for a cell, as a path or a URL.
    func hoverForTest(row: Int, column: Int) -> String? {
        switch resolveAt(row: row, column: column)?.0 {
        case .path(let found): found.path
        case .choice(let found): found.first?.path
        case .web(let url): url.absoluteString
        case nil: nil
        }
    }

    private func resolveAt(row: Int, column: Int) -> (LinkTarget, LogicalLine, Range<Int>)? {
        let variants = logicalLines(row: row, column: column)
        let key = ([String(row), String(column), owner?.currentDirectory ?? ""] + variants.map(\.line.text)).joined(separator: "\n")
        if let last = lastResolution, last.key == key, Date().timeIntervalSince(last.time) < 2 { return last.result }
        let result = resolveAt(row: row, column: column, variants: variants)
        lastResolution = (key, Date(), result)
        return result
    }

    private func resolveAt(row: Int, column: Int, variants: [(line: LogicalLine, column: Int)]) -> (LinkTarget, LogicalLine, Range<Int>)? {
        for variant in variants {
            if let (target, range) = resolveLink(in: variant.line, column: variant.column) {
                return (target, variant.line, range)
            }
        }
        if let found = locationUnderPath(row: row, column: column), let line = logicalLines(row: row, column: column).first?.line {
            return (found.target, line, found.range)
        }
        return nil
    }

    /// `16:5` with its path on a line above, the way ripgrep's headings and eslint print them.
    private func locationUnderPath(row: Int, column: Int) -> (target: LinkTarget, range: Range<Int>)? {
        let rows = terminalStateSnapshot().visibleRows
        guard let found = PathLinkDetector.locationUnderPath(atColumn: column, row: row, in: rows.map(\.text)),
              let resolver = pathResolver() else { return nil }
        for candidate in found.candidates {
            let matches = resolver.resolveAll(candidate)
            if let first = matches.first {
                return (matches.count == 1 ? .path(first) : .choice(matches), found.range)
            }
        }
        return nil
    }

    // MARK: Grid geometry

    /// A logical line: soft-wrapped rows joined, with a map from characters back to cells.
    struct LogicalLine {
        var text: String
        var cells: [(row: Int, col: Int, width: Int)]
    }

    private var cellSize: CGSize {
        let snapshot = terminalStateSnapshot()
        let frame = getOptimalFrameSize()
        return CGSize(width: frame.width / CGFloat(max(snapshot.dimensions.cols, 1)),
                      height: frame.height / CGFloat(max(snapshot.dimensions.rows, 1)))
    }

    /// What's under a point, as text to try: the soft-wrapped line first. Then, because agents
    /// print long paths with real newlines at the screen edge, the row joined to its neighbours.
    private func logicalLines(atWindowPoint point: NSPoint) -> [(line: LogicalLine, column: Int)] {
        let local = convert(point, from: nil)
        let size = cellSize
        guard size.width > 0, size.height > 0 else { return [] }
        return logicalLines(row: Int((bounds.height - local.y) / size.height), column: Int(local.x / size.width))
    }

    private func logicalLines(row rowIndex: Int, column: Int) -> [(line: LogicalLine, column: Int)] {
        let snapshot = terminalStateSnapshot()
        let rows = snapshot.visibleRows
        let cols = snapshot.dimensions.cols
        guard rowIndex >= 0, rowIndex < rows.count, column >= 0 else { return [] }

        var start = rowIndex
        while start > 0, rows[start].isWrapped { start -= 1 }
        var end = rowIndex
        while end + 1 < rows.count, rows[end + 1].isWrapped { end += 1 }

        var variants: [(LogicalLine, Int)] = []
        if let soft = Self.build(rows: rows, indexes: Array(start...end), hitRow: rowIndex, hitColumn: column) {
            variants.append(soft)
        }
        // A row that reaches the right margin may continue on the next one.
        func nearlyFull(_ index: Int) -> Bool {
            let trimmed = rows[index].text.reversed().drop { $0 == " " }.count
            return trimmed >= cols - 8
        }
        if end + 1 < rows.count, nearlyFull(end),
           let joined = Self.build(rows: rows, indexes: Array(start...(end + 1)), hitRow: rowIndex, hitColumn: column, trimIndentOf: end + 1) {
            variants.append(joined)
        }
        if start > 0, nearlyFull(start - 1),
           let joined = Self.build(rows: rows, indexes: Array((start - 1)...end), hitRow: rowIndex, hitColumn: column, trimIndentOf: start) {
            variants.append(joined)
        }
        return variants.map { (line: $0.0, column: $0.1) }
    }

    private static func build(rows: [TerminalVisibleRowSnapshot], indexes: [Int], hitRow: Int, hitColumn: Int,
                              trimIndentOf: Int? = nil) -> (LogicalLine, Int)? {
        var text = ""
        var cells: [(row: Int, col: Int, width: Int)] = []
        var hitCharacter = -1
        for index in indexes {
            let row = rows[index]
            var cursor = 0
            var characters = Array(row.text)
            if index == trimIndentOf {
                while characters.first == " " {
                    characters.removeFirst()
                    cursor += 1
                }
            }
            // A hard-wrapped row's trailing spaces aren't part of the path.
            if trimIndentOf != nil, index != indexes.last {
                while characters.last == " " { characters.removeLast() }
            }
            for character in characters {
                let width = cursor < row.cellWidths.count ? max(row.cellWidths[cursor], 1) : 1
                if index == hitRow, hitColumn >= cursor, hitColumn < cursor + width {
                    hitCharacter = cells.count
                }
                text.append(character)
                cells.append((index, cursor, width))
                cursor += width
            }
        }
        guard hitCharacter >= 0 else { return nil }
        return (LogicalLine(text: text, cells: cells), hitCharacter)
    }

    private func resolveLink(in line: LogicalLine, column: Int) -> (LinkTarget, Range<Int>)? {
        if let (url, range) = Self.webLink(in: line.text, column: column) {
            return (.web(url), range)
        }
        guard let matches = pathResolver()?.resolveAll(atColumn: column, in: line.text), let first = matches.first else { return nil }
        return (matches.count == 1 ? .path(first) : .choice(matches), first.range)
    }

    private func pathResolver() -> PathResolver? {
        guard let owner else { return nil }
        let model = owner.model
        let itemID = owner.itemID
        var resolver = PathResolver(cwd: owner.currentDirectory, workspaceFolders: model.workspace(containing: itemID)?.folders ?? [], search: { path in
            MainActor.assumeIsolated { model.linkMatches(for: path, from: itemID) }
        })
        // An absolute path printed on a server is a path on that server.
        if let destination = owner.remoteDestination, let connection = model.remote.existingConnection(destination) {
            let map = connection.map
            resolver.absolute = { map.local($0) }
            if let home = connection.home { resolver.home = map.local(home) }
        }
        return resolver
    }

    private static let webLinkPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'`<>│]+"#)

    static func webLink(in text: String, column: Int) -> (URL, Range<Int>)? {
        // A long line is only looked at around the column, as paths are.
        let characters = Array(text)
        guard column >= 0, column < characters.count else { return nil }
        let window = max(0, column - 2000)..<min(characters.count, column + 2000)
        guard let match = webLinkPattern else { return nil }
        let string = String(characters[window])
        for result in match.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let range = Range(result.range, in: string) else { continue }
            var raw = String(string[range])
            while let last = raw.last, ".,;:!?)]}".contains(last) {
                if last == ")", raw.filter({ $0 == "(" }).count >= raw.filter({ $0 == ")" }).count { break }
                raw.removeLast()
            }
            let lower = window.lowerBound + string.distance(from: string.startIndex, to: range.lowerBound)
            let span = lower..<(lower + raw.count)
            if span.contains(column), let url = URL(string: raw) { return (url, span) }
        }
        return nil
    }

    private func drawUnderline(logical: LogicalLine, range: Range<Int>) {
        underlines.forEach { $0.removeFromSuperlayer() }
        underlines.removeAll()
        guard let layer else { return }
        let size = cellSize
        var runs: [Int: (first: Int, last: Int)] = [:]
        for index in range where index < logical.cells.count {
            let cell = logical.cells[index]
            let run = runs[cell.row] ?? (cell.col, cell.col + cell.width)
            runs[cell.row] = (min(run.first, cell.col), max(run.last, cell.col + cell.width))
        }
        for (row, run) in runs {
            let line = CALayer()
            line.backgroundColor = NSColor.controlAccentColor.cgColor
            let y = bounds.height - CGFloat(row + 1) * size.height + 1
            line.frame = CGRect(x: CGFloat(run.first) * size.width, y: y,
                                width: CGFloat(run.last - run.first) * size.width, height: 1.5)
            line.zPosition = 100
            line.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull()]
            layer.addSublayer(line)
            underlines.append(line)
        }
    }

    // MARK: Peek tip

    private var peekTip: (chip: NSView, underline: [CALayer], row: Int, text: String)?
    private var peekTipTimer: Timer?
    private var fadedTips: [(NSView, [CALayer])] = []

    /// The last path on screen, underlined as ⌘ shows it, with how to open it beneath. False if there's none.
    func showPeekTip() -> Bool {
        guard peekTip == nil, let layer, let (line, range, row) = lastPathOnScreen() else { return false }
        let size = cellSize
        let cells = range.compactMap { $0 < line.cells.count ? line.cells[$0] : nil }
        guard let first = cells.first, let lastRow = cells.map(\.row).max(), size.height > 0 else { return false }
        var runs: [Int: (first: Int, last: Int)] = [:]
        for cell in cells {
            let run = runs[cell.row] ?? (cell.col, cell.col + cell.width)
            runs[cell.row] = (min(run.first, cell.col), max(run.last, cell.col + cell.width))
        }
        var underline: [CALayer] = []
        for (row, run) in runs {
            let mark = CALayer()
            mark.backgroundColor = NSColor.controlAccentColor.cgColor
            mark.frame = CGRect(x: CGFloat(run.first) * size.width, y: bounds.height - CGFloat(row + 1) * size.height + 1,
                                width: CGFloat(run.last - run.first) * size.width, height: 1.5)
            mark.zPosition = 100
            layer.addSublayer(mark)
            underline.append(mark)
        }
        let chip = Tips.peekChip()
        let fit = chip.fittingSize
        // Under the path, or over it when it's on the last line.
        var y = bounds.height - CGFloat(lastRow + 1) * size.height - fit.height - 3
        if y < 2 { y = bounds.height - CGFloat(first.row) * size.height + 3 }
        let x = min(CGFloat(first.col) * size.width, max(bounds.width - fit.width - 6, 0))
        chip.frame = CGRect(x: x, y: y, width: fit.width, height: fit.height)
        chip.alphaValue = 0
        addSubview(chip)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AccessibilityDisplay.shared.reduceMotion ? 0 : 0.2
            chip.animator().alphaValue = 1
        }
        let rows = terminalStateSnapshot().visibleRows
        peekTip = (chip, underline, row, row < rows.count ? rows[row].text : "")
        peekTipTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dissolvePeekTip() }
        }
        NSAccessibility.post(element: chip, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Command-click a path to Peek at it"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return true
    }

    /// It never waits to be closed: it goes after a few seconds, at a key or a click, or when what it points at moves.
    func dissolvePeekTip() {
        guard let tip = peekTip else { return }
        peekTip = nil
        peekTipTimer?.invalidate()
        peekTipTimer = nil
        let quick = AccessibilityDisplay.shared.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = quick ? 0 : 0.4
            tip.chip.animator().alphaValue = 0
            tip.underline.forEach { $0.opacity = 0 }
        }
        fadedTips.append((tip.chip, tip.underline))
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 0 : 0.45)) { [weak self] in
            guard let self else { return }
            for (chip, underline) in self.fadedTips {
                chip.removeFromSuperview()
                underline.forEach { $0.removeFromSuperlayer() }
            }
            self.fadedTips.removeAll()
        }
    }

    /// Output and scrolling move the path out from under the tip.
    func checkPeekTip() {
        guard let tip = peekTip else { return }
        let rows = terminalStateSnapshot().visibleRows
        if tip.row >= rows.count || rows[tip.row].text != tip.text { dissolvePeekTip() }
    }

    /// From the bottom up, the first word that's a file Tiri can find.
    private func lastPathOnScreen() -> (LogicalLine, Range<Int>, Int)? {
        let rows = terminalStateSnapshot().visibleRows
        for index in rows.indices.reversed().prefix(60) {
            let row = rows[index]
            var cursor = 0
            var words: [(column: Int, text: String)] = []
            for character in row.text {
                let width = cursor < row.cellWidths.count ? max(row.cellWidths[cursor], 1) : 1
                if character == " " {
                    if let last = words.last, last.text.last != " " { words[words.count - 1].text.append(" ") }
                } else if words.isEmpty || words[words.count - 1].text.last == " " {
                    words.append((cursor, String(character)))
                } else {
                    words[words.count - 1].text.append(character)
                }
                cursor += width
            }
            for word in words.reversed() {
                let text = word.text.trimmingCharacters(in: .whitespaces)
                guard text.count > 2, text.contains("/") || text.contains("."), !text.contains("://") else { continue }
                for variant in logicalLines(row: index, column: word.column) {
                    if let (target, range) = resolveLink(in: variant.line, column: variant.column), case .path = target {
                        return (variant.line, range, index)
                    }
                }
            }
        }
        return nil
    }

    // MARK: Find marks

    private var findMarks: [CALayer] = []
    private var findTimer: Timer?
    private var findSeen = ""
    private(set) var findQuery: String?

    /// Marks every match on screen. The terminal itself selects the current one. Output and
    /// scrolling move things, so this looks again while find is open.
    func markFindMatches(of query: String?) {
        findQuery = query?.isEmpty == true ? nil : query
        findSeen = ""
        guard findQuery != nil else {
            findTimer?.invalidate()
            findTimer = nil
            findMarks.forEach { $0.removeFromSuperlayer() }
            findMarks = []
            return
        }
        redrawFindMarks()
        if findTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.redrawFindMarks() }
            }
            RunLoop.main.add(timer, forMode: .common)
            findTimer = timer
        }
    }

    private func redrawFindMarks() {
        guard let query = findQuery, let layer, window != nil else { return }
        let snapshot = terminalStateSnapshot()
        let rows = snapshot.visibleRows
        let seen = query + "\u{0}" + rows.map(\.text).joined(separator: "\n")
        guard seen != findSeen else { return }
        findSeen = seen
        findMarks.forEach { $0.removeFromSuperlayer() }
        findMarks = []
        let size = cellSize
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return }
        var index = 0
        while index < rows.count {
            var last = index
            while last + 1 < rows.count, rows[last + 1].isWrapped { last += 1 }
            var characters: [Character] = []
            var cells: [(row: Int, col: Int, width: Int)] = []
            for rowIndex in index...last {
                var cursor = 0
                for character in rows[rowIndex].text {
                    let width = cursor < rows[rowIndex].cellWidths.count ? max(rows[rowIndex].cellWidths[cursor], 1) : 1
                    characters.append(character)
                    cells.append((rowIndex, cursor, width))
                    cursor += width
                }
            }
            let folded = characters.map { $0.lowercased().first ?? $0 }
            var start = 0
            while start + needle.count <= folded.count {
                guard folded[start] == needle[0], Array(folded[start..<(start + needle.count)]) == needle else {
                    start += 1
                    continue
                }
                for run in Self.runs(of: cells[start..<(start + needle.count)]) {
                    let mark = CALayer()
                    mark.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
                    mark.frame = CGRect(x: CGFloat(run.first) * size.width, y: bounds.height - CGFloat(run.row + 1) * size.height,
                                        width: CGFloat(run.last - run.first) * size.width, height: size.height)
                    mark.zPosition = 90
                    mark.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull()]
                    layer.addSublayer(mark)
                    findMarks.append(mark)
                }
                start += needle.count
            }
            index = last + 1
        }
    }

    private static func runs(of cells: ArraySlice<(row: Int, col: Int, width: Int)>) -> [(row: Int, first: Int, last: Int)] {
        var runs: [(row: Int, first: Int, last: Int)] = []
        for cell in cells {
            if let last = runs.last, last.row == cell.row {
                runs[runs.count - 1].last = max(last.last, cell.col + cell.width)
            } else {
                runs.append((cell.row, cell.col, cell.col + cell.width))
            }
        }
        return runs
    }

    // MARK: Clearing

    /// Scrolls the cursor's line to the top and forgets what was above it. False in a full-screen program.
    func clearKeepingCursorLine() -> Bool {
        guard let state = terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)), !state.inputState.isAlternateBuffer else { return false }
        let row = state.cursorRow - state.liveTopRow
        // Scroll Up moves the screen without moving the cursor, then the cursor follows its line.
        if row > 0 { feed(text: "\u{1B}[\(row)S\u{1B}[\(row)A") }
        clearScrollback()
        return true
    }

    // MARK: Drop a file from the tree or Finder

    func registerDrops() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        insertFiles(urls.map(\.path))
        window?.makeFirstResponder(self)
        return true
    }

    /// An agent gets mentions and images. A shell gets quoted paths.
    private func insertFiles(_ paths: [String]) {
        if let owner, owner.runningAgent == nil, let destination = owner.remoteDestination {
            owner.model.remote.serverPaths(for: paths, on: destination) { [weak self] mapped in
                self?.send(txt: ShellQuote.join(mapped) + " ")
            }
            return
        }
        if let owner, let agent = owner.runningAgent {
            owner.model.insert(paths, into: owner, agent: agent)
        } else {
            send(txt: ShellQuote.join(paths) + " ")
        }
    }

    /// A picture on the clipboard reaches an agent as a picture, and a copied file as that file.
    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertFiles(urls.map(\.path))
            return
        }
        let hasText = board.string(forType: .string)?.isEmpty == false
        if !hasText, let owner, owner.runningAgent != nil,
           let image = NSImage(pasteboard: board), let path = owner.model.savePastedImage(image) {
            insertFiles([path])
            return
        }
        super.paste(sender)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openHyperlink(link, forceTab: false)
    }
}

// MARK: - The controller

final class TerminalController: ItemController, LocalProcessTerminalViewDelegate {
    /// The server this terminal is on, if it's on one.
    let remoteDestination: String?
    /// Back to what's already there rather than starting anything. After a dropped connection.
    private var reattaching = false
    private var waitingForConnection = false
    private var remoteCwd: String?
    private var remoteForeground: Int32 = 0
    private var remoteShell: Int32 = 0
    private var remoteCommand: [String] = []
    private var remoteRetries = 0
    let itemID: ItemID
    let terminalView: TiriTerminalView
    unowned let model: AppModel
    var view: NSView { container }

    private let container = TerminalContainer()
    /// A line over the terminal, for something about what runs in it rather than its connection.
    func showNotice(_ text: String?, busy: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        container.showNotice(text, busy: busy, actionTitle: actionTitle, action: action)
    }
    var noticeText: String? { container.noticeText }
    func pressNotice() { container.pressNotice() }
    private let spec: TerminalSpec
    private var launchCommand: String?
    /// The command a session that outlived the last quit was started with. Reattached, nothing is
    /// launched, but that's still what's running: without it an agent looks like a quiet shell.
    private var attachedTo: String?
    private var runningCommand: String? { launchCommand ?? attachedTo }
    /// Typed at the prompt after a relaunch, for a command that shouldn't just run again.
    private var prefill: String?
    private let workspaceID: WorkspaceID
    private var started = false
    private var exited = false
    private var trackedCwd: String
    private var persistedCwd: String
    private var monitor: Timer?
    private var oscObservation: TerminalOscObservation?
    private let activity = OutputActivity()
    private var lastInputAt: Double = 0

    // Status heuristics. Agent hooks, when installed, are authoritative.
    private var hookActive = false
    private var lastTypedAgent: String?
    private var lastHookWorkingAt: Double = 0
    private var foregroundBusySince: Double?
    private var sawAgentOutputBurst = false
    private var agentHasWork = false

    init(itemID: ItemID, spec: TerminalSpec, launchCommand: String?, attachedTo: String? = nil, prefill: String? = nil,
         workspaceID: WorkspaceID, model: AppModel) {
        self.itemID = itemID
        self.spec = spec
        self.launchCommand = launchCommand
        self.attachedTo = attachedTo
        self.prefill = prefill
        self.workspaceID = workspaceID
        self.model = model
        self.trackedCwd = spec.cwd
        self.persistedCwd = spec.cwd
        self.remoteDestination = model.workspaces.first { $0.id == workspaceID }?.remote
        var options = TerminalOptions.default
        options.scrollback = model.settings.terminalScrollback
        terminalView = TiriTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), font: nil, options: options)
        terminalView.owner = self
        terminalView.processDelegate = self
        // Tiri does its own link detection: SwiftTerm's rejects relative paths and drops :line.
        terminalView.linkReporting = .none
        // SwiftTerm underlines what it thinks is a link, dashed, over two paths at once, and leaves
        // it there after a click. This keeps that to real hyperlinks a program marked as such.
        terminalView.linkHighlightMode = .alwaysWithModifier
        terminalView.bellStyle = .none
        terminalView.registerDrops()
        container.host(terminalView)
        container.onAttach = { [weak self] in self?.didAttach() }
        container.onAppearanceChange = { [weak self] in self?.applySettings() }
        applySettings()
        let activity = activity
        terminalView.setProcessOutputHandler { activity.noteOutput() }
        oscObservation = terminalView.observeOscEvents { [weak self] event in
            if event.code == 6973 {
                let report = String(decoding: event.payload, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.remoteReport(report) } }
                return
            }
            let notification = Self.notificationText(from: event)
            guard let notification else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.oscNotification(notification) }
            }
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        monitor?.tolerance = 0.3
    }

    nonisolated private static func notificationText(from event: TerminalOscEvent) -> String? {
        let code = event.code
        guard code == 9 || code == 777 || code == 99 else { return nil }
        return String(decoding: event.payload, as: UTF8.self)
    }

    private func oscNotification(_ text: String) {
        // A progress report (OSC 9;4) isn't a request for attention.
        if text.hasPrefix("4;") { return }
        if hookActive || isReplaying { return }
        model.setStatus(itemID, .needsInput, message: text.replacingOccurrences(of: "notify;", with: ""))
    }

    // MARK: Lifecycle

    /// A window's first layouts pass through sizes it won't keep. A session started at one of those
    /// would be told its real size straight after, and a shell redrawing for that wipes lines above it.
    func didAttach() {
        guard !started, !waitingToSettle else { return }
        waitingToSettle = true
        settle(lastWidth: terminalView.bounds.width, tries: 8)
    }

    private var waitingToSettle = false

    private func settle(lastWidth: CGFloat, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let width = self.terminalView.bounds.width
            if width != lastWidth, tries > 0 {
                self.settle(lastWidth: width, tries: tries - 1)
                return
            }
            self.waitingToSettle = false
            self.startIfNeeded(fallbackSize: false)
        }
    }

    func startIfNeeded(fallbackSize: Bool) {
        guard !started else { return }
        if !fallbackSize, terminalView.bounds.width < 40 { return }
        if fallbackSize { takeSizeOfItsPane() }
        started = true
        spawn()
    }

    /// In a tab that isn't showing it has no size yet, and what a running program printed replays
    /// at whatever it has. Replayed narrower than it was printed, a shell's prompts leave marks.
    private func takeSizeOfItsPane() {
        let frames = model.layoutRegistry.contentFrames
        let group = model.workspaces.first { $0.id == workspaceID }?.group(containing: itemID)?.id
        guard terminalView.window == nil || container.superview == nil,
              let frame = group.flatMap({ frames[$0] }) ?? frames.values.max(by: { $0.width < $1.width }) else { return }
        let inset = TerminalContainer.padding
        terminalView.setFrameSize(NSSize(width: max(frame.width - inset.left - inset.right, 40),
                                         height: max(frame.height - inset.top - inset.bottom, 40)))
    }

    /// Coming back to a running session replays what it printed. A bell or a notification in there
    /// happened long ago, and isn't asking for anything now.
    private var replayEndsAt: Double = 0
    private var isReplaying: Bool { ProcessClock.now() < replayEndsAt }
    private var spawnedAt: Double = 0

    private func spawn() {
        spawnedAt = ProcessClock.now()
        knownSessionShell = nil
        if remoteDestination != nil {
            spawnOnServer()
            return
        }
        if TerminalSessions.isAlive(itemID) { replayEndsAt = ProcessClock.now() + 2000 }
        let backend: TerminalBackend = LocalTerminalBackend()
        let launch = backend.launch(command: launchCommand, cwd: currentDirectory, shell: model.settings.terminalShell,
                                    itemID: itemID, workspaceID: workspaceID, socket: model.socketPath)
        // Nothing of the app's goes into the shell: SwiftTerm's fork keeps whatever isn't close-on-exec.
        CloseOnExec.markAllOpen()
        terminalView.startProcess(executable: launch.executable, args: launch.args, environment: launch.environment,
                                  execName: launch.execName, currentDirectory: launch.cwd)
        // This terminal's side of the pty stays out of the next one's shell.
        CloseOnExec.mark(terminalView.process.childfd)
        throughSession = launch.execName == "tiri-session"
        exited = false
        container.hideExitBar()
        if let prefill {
            // The terminal holds typed-ahead input until the shell is ready for it.
            self.prefill = nil
            terminalView.send(txt: prefill)
        }
    }

    // MARK: On a server

    private var isRemote: Bool { remoteDestination != nil }
    /// Running under this Mac's session helper, which understands what ⌘K asks of it.
    private var throughSession = false

    /// The program runs on the server, and what's here is `ssh` showing it. Comes up when the
    /// connection does, and comes back whenever the connection does.
    private func spawnOnServer() {
        guard let destination = remoteDestination else { return }
        let connection = model.remote.connection(destination)
        guard connection.state.isReady, model.remote.isSetUp(destination) else {
            waitingForConnection = true
            showConnectionNotice(connection.state.isReady ? .connecting : connection.state)
            model.remote.connect(destination)
            return
        }
        waitingForConnection = false
        Task { [weak self] in
            guard let self else { return }
            let alive = await self.model.remote.sessionIsAlive(self.itemID, on: connection)
            let slot = self.model.remote.terminalSlot(self.itemID, on: destination)
            if slot > 0 {
                guard await Task.detached(priority: .userInitiated, operation: { connection.ensureTerminalConnection(slot: slot) }).value else {
                    self.waitingForConnection = true
                    self.container.showNotice(String(localized: "Couldn't open another connection to \(SSHConfigFile.displayName(of: destination))."), busy: false,
                                              actionTitle: String(localized: "Try Again")) { [weak self] in
                        self?.beginReattach()
                    }
                    return
                }
            }
            guard !self.exited || self.startingAgain else { return }
            self.startingAgain = false
            // Still running, so what's there now is what counts, and nothing is typed or replayed.
            let attach = self.reattaching || alive
            let script = self.model.remote.terminalScript(connection: connection, itemID: self.itemID, workspaceID: self.workspaceID,
                                                          command: attach ? nil : self.launchCommand, cwd: self.trackedCwd, attachOnly: self.reattaching)
            let launch = self.model.remote.terminalLaunch(connection: connection, script: script, slot: slot)
            self.exited = false
            self.container.hideExitBar()
            self.container.showNotice(nil)
            CloseOnExec.markAllOpen()
            self.terminalView.startProcess(executable: launch.executable, args: launch.args, environment: launch.environment,
                                           execName: launch.execName, currentDirectory: launch.cwd)
            CloseOnExec.mark(self.terminalView.process.childfd)
            self.sessionUp = true
            if !attach, let prefill = self.prefill {
                self.prefill = nil
                self.terminalView.send(txt: prefill)
            }
            // With the helper, what's waiting goes once the session says it's really there.
            if !connection.hasHelper { self.flushHeldBack() }
        }
    }

    private var startingAgain = false
    /// Whether `ssh` to this terminal's session is up right now.
    private var sessionUp = false
    private var heldBack: [String] = []

    private func flushHeldBack() {
        guard sessionUp, !heldBack.isEmpty else { return }
        // A moment for the replay to finish, because input during a replay is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.sessionUp else { return }
            let held = self.heldBack
            self.heldBack = []
            for text in held { self.terminalView.send(txt: self.onServer(text)) }
        }
    }

    func remoteStateChanged(_ state: RemoteState) {
        switch state {
        case .ready:
            container.showNotice(nil)
            if waitingForConnection, started {
                beginReattach()
            }
        default:
            // Only something that's running or waiting to has anything to say about it.
            if started, !exited || waitingForConnection { showConnectionNotice(state) }
        }
    }

    /// What's on screen is replaced by what the server replays, or it would all appear twice.
    private func beginReattach(keepingRetries: Bool = false) {
        waitingForConnection = false
        if !keepingRetries { remoteRetries = 0 }
        reattaching = hasEverAttached && !restartRequested
        restartRequested = false
        startingAgain = true
        if hasEverAttached { terminalView.feed(text: "\u{1B}c\u{1B}[3J") }
        spawnOnServer()
    }

    private var hasEverAttached = false
    /// Restart was pressed while the connection was down, so what comes back is a fresh run.
    private var restartRequested = false

    private func showConnectionNotice(_ state: RemoteState) {
        guard let destination = remoteDestination else { return }
        let name = SSHConfigFile.displayName(of: destination)
        switch state {
        case .ready:
            container.showNotice(nil)
        case .reconnecting:
            container.showNotice(String(localized: "Reconnecting to \(name). What's running there keeps running."))
        case .connecting:
            container.showNotice(String(localized: "Connecting to \(name)…"))
        case .idle:
            container.showNotice(String(localized: "Not connected to \(name). What's running there keeps running."), busy: false, actionTitle: String(localized: "Connect")) { [weak self] in
                self?.model.remote.connect(destination)
            }
        case .failed(let message):
            container.showNotice(message, busy: false, actionTitle: String(localized: "Try Again")) { [weak self] in
                self?.model.remote.connect(destination)
            }
        }
    }

    /// What the session on the server says about itself, since it can't be looked up from here.
    private func remoteReport(_ report: String) {
        guard let destination = remoteDestination, let connection = model.remote.existingConnection(destination) else { return }
        // Anything can print an escape sequence, like `cat` on a file. Only the session knows this.
        guard report.hasPrefix("n=" + model.remote.reportTag(for: itemID) + ";") else { return }
        hasEverAttached = true
        // It's really there. From here on an exit is the program's own.
        reattaching = false
        remoteRetries = 0
        flushHeldBack()
        for field in report.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "cwd":
                let remote = parts[1].removingPercentEncoding ?? String(parts[1])
                let directory = connection.map.local(remote)
                if !remote.isEmpty, directory != trackedCwd {
                    trackedCwd = directory
                    persistedCwd = directory
                    model.terminalCwdChanged(item: itemID, cwd: directory)
                }
            case "fg":
                remoteForeground = Int32(parts[1]) ?? 0
            case "shell":
                remoteShell = Int32(parts[1]) ?? 0
            case "cmd":
                remoteCommand = parts[1].components(separatedBy: "%00").filter { !$0.isEmpty }.map { $0.removingPercentEncoding ?? $0 }
            default:
                break
            }
        }
    }

    /// Text from Tiri, on its way to a program on a server: paths in it are paths on that server.
    private func onServer(_ text: String) -> String {
        guard let destination = remoteDestination, let connection = model.remote.existingConnection(destination) else { return text }
        return connection.map.remoteText(text)
    }

    /// `resuming` tries the same conversation again, for when what stopped it may have passed.
    func restart(resuming: Bool = false) {
        guard exited else { return }
        if let plugin = spec.plugin, model.plugins.enabledPlugin(named: plugin) == nil {
            model.showToast(title: String(localized: "\(plugin) is off"), detail: String(localized: "Turn it on to run this again."), symbol: "puzzlepiece.extension", tint: .secondary)
            return
        }
        model.updateRuntime(itemID) { runtime in
            runtime.status = .idle
            runtime.exitCode = nil
            runtime.unseen = false
        }
        hookActive = false
        // Otherwise it's a fresh run: a resume that failed shouldn't simply fail again.
        if !resuming { launchCommand = spec.command }
        reattaching = false
        restartRequested = true
        startingAgain = true
        spawn()
        focus()
    }

    /// The tab was closed on purpose, so what's running in it stops too.
    func endSession() {
        if let remoteDestination {
            if started, !exited || waitingForConnection { model.remote.endSession(itemID, on: remoteDestination) }
            return
        }
        if started, !exited { TerminalSessions.end(itemID) }
    }

    func teardown() {
        monitor?.invalidate()
        monitor = nil
        oscObservation = nil
        terminalView.setProcessOutputHandler(nil)
        terminalView.processDelegate = nil
        if started, !exited { terminalView.terminate() }
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func applySettings() {
        let settings = model.settings
        let family = settings.terminalFontFamily
        let size = CGFloat(settings.terminalFontSizeZoomed)
        terminalView.font = TerminalTheme.font(family: family, size: size)
        terminalView.changeScrollback(settings.terminalScrollback)
        // Reduce Transparency, or Increase Contrast, which turns it on too, makes it solid whatever the setting says.
        let translucent = settings.terminalTranslucent && !AccessibilityDisplay.shared.reduceTransparency
        TerminalTheme.apply(to: terminalView, dark: model.effectiveDark, translucent: translucent)
        let color = TerminalTheme.background(dark: model.effectiveDark)
        container.setBackground(translucent ? .clear : color)
        container.setTranslucent(translucent ? color.withAlphaComponent(TerminalTheme.translucentOpacity) : nil)
        container.setSolidOverlays(AccessibilityDisplay.shared.reduceTransparency)
    }

    // MARK: Cwd and processes

    /// OSC 7 when the shell reports it, otherwise whatever the process is actually in.
    var currentDirectory: String {
        if isRemote { return trackedCwd }
        if started, !exited, let fallback = processDirectory() {
            if fallback != trackedCwd { trackedCwd = fallback }
        }
        return trackedCwd
    }

    private var shellPID: pid_t {
        if isRemote { return remoteShell }
        if let session = sessionShellPID { return session }
        return started && !exited ? terminalView.process.shellPid : 0
    }

    /// The program the session server runs, from its pid file. The status tick asks for it several
    /// times a second in every terminal, and reading the file each time was most of the tick's cost.
    /// Read again once that process is gone, and forgotten whenever the terminal starts again.
    private var sessionShellPID: pid_t? {
        if let known = knownSessionShell, kill(known, 0) == 0 { return known }
        knownSessionShell = TerminalSessions.shellPID(for: itemID)
        return knownSessionShell
    }
    private var knownSessionShell: pid_t?

    private var foregroundPID: pid_t? {
        guard started, !exited else { return nil }
        if isRemote { return remoteForeground > 0 ? remoteForeground : nil }
        // In a session, the view's own terminal only ever has the relay in it.
        if let session = sessionShellPID {
            return TerminalSessions.foregroundGroup(of: session)
        }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    private func processDirectory() -> String? {
        if isRemote { return nil }
        for pid in [foregroundPID, shellPID > 0 ? shellPID : nil].compactMap({ $0 }) {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
                let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// The program in the foreground, if it isn't just the shell at its prompt.
    var foregroundProcessName: String? {
        guard let foreground = foregroundPID, shellPID > 0 else { return nil }
        // `shell -c cmd` runs the agent inside the shell's own process group.
        if let runningCommand {
            return runningCommand.split(separator: " ").first.map(String.init)
        }
        guard foreground != shellPID else { return nil }
        if isRemote { return remoteCommand.first.map { ($0 as NSString).lastPathComponent } ?? String(localized: "a process") }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(foreground, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : String(localized: "a process")
    }

    /// The executable and arguments of what's in the foreground. Nothing if it's just the shell.
    var foregroundCommandLine: [String] {
        guard let foreground = foregroundPID, foreground != shellPID else { return [] }
        if isRemote { return remoteCommand }
        var request = [CTL_KERN, KERN_PROCARGS2, foreground]
        var size = 0
        guard sysctl(&request, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // An argument count, then the executable's path, then the arguments, split by NULs.
        let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, maxSplits: 6, omittingEmptySubsequences: true)
        return parts.prefix(4).map { String(decoding: $0, as: UTF8.self) }
    }

    private var isShellBusy: Bool {
        guard let foreground = foregroundPID, shellPID > 0 else { return false }
        return foreground != shellPID
    }

    // MARK: Status

    func noteHookReport(status: TerminalStatus) {
        hookActive = true
        if status == .working { lastHookWorkingAt = ProcessClock.now() }
    }

    private func tick() {
        guard started, !exited, !waitingForConnection else { return }
        // Plain shells don't report their folder unless they're set up to, and a relaunch
        // should come back where the terminal was.
        if let directory = processDirectory(), directory != persistedCwd {
            persistedCwd = directory
            trackedCwd = directory
            model.terminalCwdChanged(item: itemID, cwd: directory)
        }
        // Two system calls each time, so asked once a tick.
        let commandLine = foregroundCommandLine
        let typed = commandLine.isEmpty ? nil : AgentReference.agent(commandLine: commandLine, command: nil)?.rawValue
        if typed != lastTypedAgent {
            lastTypedAgent = typed
            model.terminalTypedAgentChanged(item: itemID, agent: typed)
        }
        let now = ProcessClock.now()
        let quietFor = now - activity.lastOutput
        let current = model.runtimes[itemID]?.status ?? .idle
        considerPeekTip(current: current, quietFor: quietFor)

        if hookActive {
            // `Stop` doesn't fire when a turn is interrupted, so "working" can go stale.
            // A working agent keeps redrawing its spinner; long silence means it isn't.
            if current == .working, quietFor > 12_000, now - lastHookWorkingAt > 12_000 {
                model.setStatus(itemID, .idle, notify: false)
            }
            return
        }

        // An agent typed at a shell's prompt is judged as an agent. Sitting at its own prompt isn't
        // work, though the shell behind it is waiting, and after a relaunch no hook has spoken yet.
        if runningCommand == nil, typed == nil {
            // Plain shells: busy means something other than the shell is in the foreground.
            if isShellBusy {
                if foregroundBusySince == nil { foregroundBusySince = now }
                if current != .working { model.setStatus(itemID, .working, notify: false) }
            } else if current == .working {
                let ranFor = now - (foregroundBusySince ?? now)
                foregroundBusySince = nil
                // Only something that ran a while is worth a "done".
                model.setStatus(itemID, ranFor > 10_000 ? .done : .idle, notify: false)
            }
            return
        }

        // An agent with no hooks installed: judge by output, ignoring echo from the user's typing.
        // Nothing counts until the user has given it something to do: drawing a welcome
        // screen isn't work, and going quiet afterwards isn't "done".
        guard agentHasWork else { return }
        let typing = now - lastInputAt < 1_500
        if quietFor < 1_500, !typing {
            if current != .working, current != .needsInput {
                model.setStatus(itemID, .working, notify: false)
            }
            sawAgentOutputBurst = true
        } else if current == .working, quietFor > 6_000 {
            let finishedTurn = sawAgentOutputBurst
            model.setStatus(itemID, finishedTurn ? .done : .idle)
            sawAgentOutputBurst = false
            agentHasWork = false
            // The first turn that ends on an estimate is when exact status is worth offering.
            if finishedTurn, let agent = runningAgent(commandLine: commandLine) {
                if let remoteDestination {
                    model.remote.offerHooksIfNeeded(agent, on: remoteDestination)
                } else {
                    model.offerHooksIfNeeded(agent)
                }
            }
        }
    }

    // MARK: Delegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = Self.cleanTitle(title)
        model.updateRuntime(itemID) { $0.title = clean }
    }

    /// Terminal titles often arrive with a spinner glyph in front.
    static func cleanTitle(_ title: String) -> String {
        var scalars = Substring(title).unicodeScalars
        while let first = scalars.first, !first.properties.isAlphabetic, first != "~", first != "/", first != "." {
            scalars.removeFirst()
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        var path = URL(string: directory)?.path ?? directory
        if let remoteDestination, let connection = model.remote.existingConnection(remoteDestination) {
            path = connection.map.local(path)
        }
        guard !path.isEmpty, path != trackedCwd else { return }
        trackedCwd = path
        model.terminalCwdChanged(item: itemID, cwd: path)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        sessionUp = false
        knownSessionShell = nil
        if handleEndOverSSH(exitCode: exitCode) { return }
        exited = true
        // A resume that stops at once either has no conversation to find, or met something that may
        // pass, like the network or a login. A fresh start would replace the stored session with a new
        // one, so that's only automatic when the agent itself says there's nothing to lose.
        if let resume = launchCommand, resume != spec.command, exitCode != 0, ProcessClock.now() - spawnedAt < 15_000 {
            // Its last words are still on their way through the terminal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.exited else { return }
                if AgentCatalog.hasNothingToResume(command: resume, output: self.readText(lines: 30)) {
                    self.restart()
                } else {
                    self.showExit(code: exitCode, resumeFailed: true)
                }
            }
            return
        }
        showExit(code: exitCode, resumeFailed: false)
    }

    private func showExit(code: Int32?, resumeFailed: Bool) {
        model.updateRuntime(itemID) { runtime in
            runtime.status = .exited
            runtime.exitCode = code
        }
        container.showExitBar(code: code, resumeFailed: resumeFailed, onRestart: { [weak self] in self?.restart() },
                              onResume: { [weak self] in self?.restart(resuming: true) }, onClose: { [weak self] in
            guard let self else { return }
            self.model.closeNow(self.itemID)
        })
    }

    /// Whether `ssh` ending means the program did. It reports its own failures as 255, and a
    /// connection that's gone takes every terminal with it. Returns true if it's only the connection.
    private func handleEndOverSSH(exitCode: Int32?) -> Bool {
        guard let destination = remoteDestination else { return false }
        let connection = model.remote.connection(destination)
        // `session attach` with nothing there to attach to: it ended while the connection was down.
        if reattaching, exitCode == 3 {
            reattaching = false
            heldBack = []
            return false
        }
        guard exitCode == 255 || exitCode == nil || !connection.state.isReady else { return false }
        waitingForConnection = true
        if !connection.state.isReady {
            showConnectionNotice(connection.state)
            return true
        }
        // It says it's up, but a dropped connection takes a moment to notice, and ending every
        // terminal at once beats it to it. Ask, before believing this is about anything else.
        connection.tryNow()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            let healthy = await Task.detached(priority: .userInitiated) { connection.run("true", timeout: 6)?.succeeded == true }.value
            guard let self, self.waitingForConnection else { return }
            // Down after all: it'll come back through remoteStateChanged.
            guard healthy, connection.state.isReady else { return }
            // Up, and it still ended, so the server probably has a low limit on sessions. The next
            // connection along may have room. Only so many times, or it would go on for ever.
            self.remoteRetries += 1
            guard self.remoteRetries <= 3 else {
                self.remoteRetries = 0
                self.waitingForConnection = false
                self.exited = true
                self.showExit(code: exitCode, resumeFailed: false)
                return
            }
            // Unless this terminal's own connection is the one that died: then the same slot gets a new one.
            let slot = self.model.remote.terminalSlot(self.itemID, on: destination)
            let ownAnswers = await Task.detached(priority: .userInitiated) { connection.terminalConnectionAnswers(slot: slot) }.value
            if ownAnswers { self.model.remote.moveToNextSlot(self.itemID, on: destination) }
            self.beginReattach(keepingRetries: true)
        }
        return true
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        processTerminated(source: source, exitCode: nil)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}

    func bellRang() {
        if hookActive || isReplaying { return }
        if runningCommand != nil {
            model.setStatus(itemID, .needsInput)
        } else if !model.isLookingAt(itemID) {
            model.updateRuntime(itemID) { $0.unseen = true }
        }
    }

    /// A real key press, seen by the router. Bytes to the process wouldn't do: terminals answer
    /// focus and capability queries by themselves, and agents using the enhanced keyboard
    /// protocol don't get Return as CR. Pressing Return is what hands an agent some work.
    private var hooksReportStarts = false
    func heardTurnStart() { hooksReportStarts = true }

    /// The Peek is the one thing nobody finds by looking. Once, after an agent's turn and while you're
    /// looking at it, the last path it printed shows how. Looked for once a turn, so a turn with no path costs one look.
    private var peekTipLooksAfterTurn = false
    /// A hidden test copy is never in front, so it's told to act as if someone were looking.
    private static let testCopyLooks = ProcessInfo.processInfo.environment["TIRI_DEV_LOOKING"] != nil
    private func considerPeekTip(current: TerminalStatus, quietFor: Double) {
        terminalView.checkPeekTip()
        guard peekTipLooksAfterTurn, !Tips.peekShown, current != .working, quietFor > 2_000, runningAgent != nil,
              model.isLookingAt(itemID) || Self.testCopyLooks && model.active.focused.active == itemID,
              !model.toasts.contains(where: { $0.actionTitle != nil }) else { return }
        peekTipLooksAfterTurn = false
        if terminalView.showPeekTip() { Tips.peekShown = true }
    }

    func noteKeyPress(isReturn: Bool) {
        terminalView.dissolvePeekTip()
        if isReturn { peekTipLooksAfterTurn = true }
        lastInputAt = ProcessClock.now()
        if runningAgent != nil { model.lastAgentTerminal = itemID }
        guard isReturn else { return }
        agentHasWork = true
        // An agent that only reports when it's finished would look finished the whole time it works.
        if hookActive, !hooksReportStarts, runningAgent != nil, let status = model.runtimes[itemID]?.status, status == .done || status == .idle {
            model.setStatus(itemID, .working, notify: false)
        }
        // The user answered, and that's the end of the question. Not every answer brings a report: a
        // rejected tool can end a turn through an event some setups don't hear. If it did end the turn,
        // the long silence below clears this.
        if model.runtimes[itemID]?.status == .needsInput {
            if hookActive { noteHookReport(status: .working) }
            model.setStatus(itemID, .working, notify: false)
        }
    }

    // MARK: Find

    var supportsFind: Bool { true }

    var selectedTextForFind: String? {
        terminalView.getSelection().flatMap { $0.contains("\n") ? nil : $0 }
    }

    func find(_ query: String, backwards: Bool) -> Bool {
        let found = backwards ? terminalView.findPrevious(query) : terminalView.findNext(query)
        terminalView.markFindMatches(of: query)
        return found
    }

    /// From the newest output, as in Cursor. Each letter starts again from there.
    func findIncrementally(_ query: String, caseSensitive: Bool) -> Bool {
        terminalView.clearSearch()
        let found = terminalView.findPrevious(query)
        terminalView.markFindMatches(of: query)
        return found
    }

    /// Output reads from the bottom up, so Return goes further back. ⇧Return comes forward.
    var findReturnGoesBackwards: Bool { true }

    func clearFind() {
        terminalView.clearSearch()
        terminalView.markFindMatches(of: nil)
    }

    var findCount: (current: Int, total: Int)? {
        guard let query = terminalView.findQuery else { return nil }
        let summary = terminalView.searchMatchSummary(query, limit: 10_000)
        return (summary.index, summary.total)
    }

    // MARK: Keys a shell expects

    /// ⌘← and ⌘→ go to the ends of the line, and ⌘⌫ deletes back to its start, as in Cursor.
    func sendLineStart() { send(text: "\u{01}") }
    func sendLineEnd() { send(text: "\u{05}") }
    func sendDeleteToLineStart() { send(text: "\u{15}") }

    /// ⌘K, as in Cursor: everything above the cursor's line goes. A full-screen program keeps its screen.
    func clearScreen() {
        guard terminalView.clearKeepingCursorLine() else { return }
        // The session keeps output to replay when Tiri comes back. What was cleared shouldn't come back with it.
        if throughSession { terminalView.send(txt: "\u{1B}_tiri:forget\u{1B}\\") }
        // At a prompt, or in an agent's input, a redraw puts back whatever spans several lines.
        if !isShellBusy || runningAgent != nil { terminalView.send(txt: "\u{0C}") }
    }

    // MARK: Control API

    var isRunning: Bool { started && !exited }

    var runningAgent: AgentReference.Agent? { runningAgent(commandLine: foregroundCommandLine) }

    private func runningAgent(commandLine: [String]) -> AgentReference.Agent? {
        var command: String?
        if case .terminal(let spec)? = model.anyItem(itemID)?.content { command = spec.command }
        return AgentReference.agent(commandLine: commandLine, command: command)
    }

    /// Whether a process is this terminal's shell or something running under it.
    func ownsProcess(_ pid: Int32) -> Bool {
        // A process on a server has nothing to do with this Mac's process table.
        if isRemote { return pid == remoteForeground || remoteCommand.isEmpty == false && pid == remoteShell }
        var current = pid
        for _ in 0..<32 {
            if current == shellPID { return true }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var request = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&request, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { return false }
            current = parent
        }
        return false
    }

    func send(text: String) {
        noteKeyPress(isReturn: text.contains("\r"))
        // Between connections, what's sent waits, so a quote made just then isn't lost.
        if isRemote, waitingForConnection || !sessionUp {
            heldBack.append(text)
            return
        }
        terminalView.send(txt: onServer(text))
    }

    func readText(lines: Int?) -> String {
        // Always the whole live screen plus history: the requested last lines are cut below,
        // after blank rows are gone.
        let region: TerminalContentRegion = .history(maximumScrollbackRows: max(lines ?? 2000, 2000))
        guard let snapshot = terminalView.terminalContentSnapshot(region: region) else { return "" }
        var rows = snapshot.rows.map(\.text)
        // Blank rows below a full-screen program's content aren't what anyone wants to read.
        while let last = rows.last, last.allSatisfy(\.isWhitespace) { rows.removeLast() }
        if let lines { rows = Array(rows.suffix(max(lines, 1))) }
        return rows.joined(separator: "\n")
    }
}

/// Timestamp of the last output, written from the terminal's parse thread.
final class OutputActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = 0

    func noteOutput() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
        lock.lock()
        last = now
        lock.unlock()
    }

    var lastOutput: Double {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Holds the terminal, tells it when it has a real size, and shows the "exited" bar.
final class TerminalContainer: NSView {
    private var terminal: NSView?
    private var exitBar: NSView?
    private var notice: NSView?
    var onAttach: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    func host(_ view: NSView) {
        terminal = view
        wantsLayer = true
        addSubview(view)
    }

    func setBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    /// The exit bar and the connection notice float over the terminal on a material. With Reduce
    /// Transparency they're solid, which the system does for real and Tiri's own switch has to.
    private var solidOverlays = false

    func setSolidOverlays(_ solid: Bool) {
        solidOverlays = solid
        for case let effect as NSVisualEffectView in [exitBar, notice].compactMap({ $0 }) { effect.setSolid(solid) }
    }

    /// What's behind the window, blurred, with the terminal's own color over it so text stays easy to
    /// read. The system's material, so it goes solid by itself with Reduce Transparency on.
    private var blur: NSVisualEffectView?
    private var tint: NSView?

    func setTranslucent(_ color: NSColor?) {
        guard let color else {
            blur?.removeFromSuperview()
            blur = nil
            tint = nil
            return
        }
        if blur == nil {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.material = .underWindowBackground
            effect.state = .active
            let cover = NSView()
            cover.wantsLayer = true
            effect.addSubview(cover)
            addSubview(effect, positioned: .below, relativeTo: terminal)
            blur = effect
            tint = cover
            needsLayout = true
        }
        tint?.layer?.backgroundColor = color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    static let padding = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 4)

    override func layout() {
        super.layout()
        let inset = Self.padding
        blur?.frame = bounds
        tint?.frame = bounds
        terminal?.frame = CGRect(x: inset.left, y: inset.bottom,
                                 width: max(bounds.width - inset.left - inset.right, 0),
                                 height: max(bounds.height - inset.top - inset.bottom, 0))
        if let exitBar {
            let height: CGFloat = 40
            exitBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
        if let notice {
            let size = notice.fittingSize
            let width = min(size.width, bounds.width - 24)
            // On the left, because a Peek floats on the right.
            notice.frame = CGRect(x: 12, y: bounds.height - size.height - 10, width: width, height: size.height)
        }
        if window != nil, bounds.width > 40 { onAttach?() }
    }

    private var noticeAction: (() -> Void)?
    @objc private func noticePressed() { noticeAction?() }
    /// For a test copy, which takes no clicks: what the notice says, and its button pressed.
    private(set) var noticeText: String?
    func pressNotice() { noticeAction?() }

    /// A quiet line over the terminal about its connection. Never in the way of reading it.
    func showNotice(_ text: String?, busy: Bool = true, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        notice?.removeFromSuperview()
        notice = nil
        noticeAction = action
        noticeText = text
        guard let text else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 520
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        var parts: [NSView] = busy ? [spinner, label] : [label]
        if let actionTitle {
            let button = NSButton(title: actionTitle, target: self, action: #selector(noticePressed))
            button.controlSize = .small
            parts.append(button)
        }
        let stack = NSStackView(views: parts)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        let holder = NSVisualEffectView()
        holder.material = .hudWindow
        holder.blendingMode = .withinWindow
        holder.state = .active
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 10
        holder.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            stack.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        holder.setSolid(solidOverlays)
        addSubview(holder)
        notice = holder
        needsLayout = true
        if text != lastNotice { AccessibilityDisplay.shared.announce(text, interrupting: false) }
        lastNotice = text
    }

    private var lastNotice: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    func showExitBar(code: Int32?, resumeFailed: Bool, onRestart: @escaping () -> Void, onResume: @escaping () -> Void, onClose: @escaping () -> Void) {
        hideExitBar()
        let bar = TerminalExitBar(code: code, resumeFailed: resumeFailed, onRestart: onRestart, onResume: onResume, onClose: onClose)
        bar.setSolid(solidOverlays)
        addSubview(bar)
        exitBar = bar
        needsLayout = true
        AccessibilityDisplay.shared.announce(bar.message)
    }

    func hideExitBar() {
        exitBar?.removeFromSuperview()
        exitBar = nil
    }
}

final class TerminalExitBar: NSVisualEffectView {
    private(set) var message = ""
    private let onRestart: () -> Void
    private let onResume: () -> Void
    private let onClose: () -> Void

    init(code: Int32?, resumeFailed: Bool, onRestart: @escaping () -> Void, onResume: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onRestart = onRestart
        self.onResume = onResume
        self.onClose = onClose
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        let text = resumeFailed ? String(localized: "Couldn't resume this conversation")
            : code.map { String(localized: "Process exited with code \(Int($0))") } ?? String(localized: "Process exited")
        message = text
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        let restart = NSButton(title: resumeFailed ? String(localized: "Start Fresh") : String(localized: "Restart"), target: self, action: #selector(restartClicked))
        let close = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeClicked))
        restart.bezelStyle = .accessoryBarAction
        close.bezelStyle = .accessoryBarAction
        var buttons: [NSView] = [restart, close]
        if resumeFailed {
            let retry = NSButton(title: String(localized: "Try Again"), target: self, action: #selector(resumeClicked))
            retry.bezelStyle = .accessoryBarAction
            buttons.insert(retry, at: 0)
        }
        let stack = NSStackView(views: [label, NSView()] + buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func restartClicked() { onRestart() }
    @objc private func resumeClicked() { onResume() }
    @objc private func closeClicked() { onClose() }
}

extension NSVisualEffectView {
    /// An opaque plate under its content, for Reduce Transparency when only Tiri's switch is on.
    func setSolid(_ solid: Bool) {
        let existing = subviews.first { $0.identifier == SolidPlate.identifier }
        if solid, existing == nil {
            let plate = SolidPlate(frame: bounds)
            plate.autoresizingMask = [.width, .height]
            addSubview(plate, positioned: .below, relativeTo: subviews.first)
        } else if !solid {
            existing?.removeFromSuperview()
        }
    }
}

private final class SolidPlate: NSBox {
    static let identifier = NSUserInterfaceItemIdentifier("tiri.solidPlate")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        boxType = .custom
        borderWidth = 0
        titlePosition = .noTitle
        fillColor = .windowBackgroundColor
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Theme

enum TerminalTheme {
    static func font(family: String, size: CGFloat) -> NSFont {
        if family != "SF Mono", let named = NSFont(name: family, size: size) { return named }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// `dark` comes from the app, not the view: right after a theme change a view's
    /// effectiveAppearance is still the old one.
    static let translucentOpacity: CGFloat = 0.72

    static func apply(to view: TerminalView, dark: Bool, translucent: Bool) {
        if let theme = ThemePalette.current {
            view.nativeBackgroundColor = ThemePalette.color(theme.terminal.background)
            view.nativeForegroundColor = ThemePalette.color(theme.terminal.foreground)
            view.caretColor = ThemePalette.color(theme.terminal.cursor)
            view.selectedTextBackgroundColor = ThemePalette.color(theme.terminal.selection)
            view.backgroundOpacity = translucent ? 0 : 1
            view.installColors(theme.terminal.ansi.map(ThemePalette.terminalColor))
            return
        }
        view.nativeBackgroundColor = dark ? background(dark: true) : background(dark: false)
        view.nativeForegroundColor = dark ? NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
                                          : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        view.caretColor = .controlAccentColor
        view.selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.45 : 0.3)
        // The container paints it. Colors a program asks for itself stay solid, so a TUI stays readable.
        view.backgroundOpacity = translucent ? 0 : 1
        view.installColors(dark ? darkPalette : lightPalette)
    }

    static func background(dark: Bool) -> NSColor {
        if let theme = ThemePalette.current { return ThemePalette.color(theme.terminal.background) }
        return dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : .white
    }

    private static func color(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xFF), green8: UInt16((hex >> 8) & 0xFF), blue8: UInt16(hex & 0xFF))
    }

    private static let darkPalette: [SwiftTerm.Color] = ([
        0x1C1C1E, 0xFF6B6B, 0x5FD38D, 0xE5C07B, 0x5AA5FF, 0xC792EA, 0x56C8D8, 0xD8D8DC,
        0x6E6E73, 0xFF8585, 0x7BE3A5, 0xF2D08F, 0x7DBBFF, 0xD7A9F2, 0x7ADBE8, 0xFFFFFF,
    ] as [UInt32]).map { color($0) }

    private static let lightPalette: [SwiftTerm.Color] = ([
        0x1D1D1F, 0xC4262E, 0x1A7F37, 0x8F6500, 0x0A66D6, 0x8E44AD, 0x0B7C8C, 0x6E6E73,
        0x55555A, 0xD93A42, 0x22963F, 0xA67800, 0x2B7DE9, 0xA056C5, 0x1293A6, 0x1D1D1F,
    ] as [UInt32]).map { color($0) }
}

/// SwiftTerm refuses a labelled hyperlink whose target has no scheme, or names a file that isn't there as
/// written, with a "Link blocked" alert, and gives no way to see the target first. Those are what Tiri finds for
/// itself, so that alert never shows: its target, which the alert carries, goes to Tiri's path search instead.
/// A target with invisible characters keeps its alert, and so does SwiftTerm's question before another app opens a link.
@MainActor
enum BlockedLinks {
    /// The terminal ⌘-clicked last. The alert comes a moment after, with no word of where from.
    static var clicked: (view: TiriTerminalView, at: Date, forceTab: Bool)?
    static let title = "Link blocked"
    static let keepsAlert = "The target contains invisible characters or line breaks."

    static func install() {
        guard let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:))),
              let replacement = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.tiri_beginSheetModal(for:completionHandler:))) else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// The target, if this is the alert to take over, from a click on one of Tiri's terminals just now.
    static func take(_ alert: NSAlert) -> (TiriTerminalView, String, Bool)? {
        guard alert.messageText == title, alert.informativeText != keepsAlert,
              let text = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView,
              let clicked, Date().timeIntervalSince(clicked.at) < 2 else { return nil }
        let target = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        Self.clicked = nil
        return (clicked.view, target, clicked.forceTab)
    }
}

extension NSAlert {
    /// In place of `beginSheetModal(for:completionHandler:)` once `BlockedLinks.install()` has run; calling it calls the original.
    @objc func tiri_beginSheetModal(for window: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?) {
        if let (view, target, forceTab) = MainActor.assumeIsolated({ BlockedLinks.take(self) }) {
            handler?(.alertFirstButtonReturn)
            MainActor.assumeIsolated { view.openHyperlink(target, forceTab: forceTab) }
            return
        }
        tiri_beginSheetModal(for: window, completionHandler: handler)
    }
}
