import AppKit
import SwiftUI
import TiriCore

/// A viewer of code, where a name can be asked about.
protocol SymbolViewing: ItemController {
    var path: String { get }
    var symbolTextView: NSTextView { get }
    /// Where a character is in the file itself, counting from 0, if it's in the file at all.
    /// A row removed in a diff isn't.
    func fileLocation(ofCharacter index: Int) -> (line: Int, character: Int)?
    /// A language server has something new to say about this file.
    func diagnosticsChanged()
}

/// Where lines start, for turning a server's positions into ranges of text.
struct LineIndex {
    private var starts: [Int] = [0]
    private let length: Int

    init(_ string: NSString) {
        length = string.length
        var search = NSRange(location: 0, length: length)
        while true {
            let found = string.range(of: "\n", options: .literal, range: search)
            if found.location == NSNotFound { break }
            starts.append(NSMaxRange(found))
            search = NSRange(location: NSMaxRange(found), length: length - NSMaxRange(found))
        }
    }

    func location(line: Int, character: Int) -> Int? {
        guard line >= 0, line < starts.count else { return nil }
        return min(starts[line] + max(character, 0), length)
    }

    func start(ofLine line: Int) -> Int? { line >= 0 && line < starts.count ? starts[line] : nil }
}

/// Underlines what's wrong. Temporary attributes, so they never reach the file or undo.
enum ProblemMarks {
    static func color(_ severity: LSPDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemOrange
        case .information, .hint: .secondaryLabelColor
        }
    }

    static func clear(_ view: NSTextView) {
        guard let layout = view.layoutManager else { return }
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
    }

    /// A zero-length range would underline nothing. The name there, or a character, stands in.
    static func underline(_ range: NSRange, severity: LSPDiagnostic.Severity, in view: NSTextView) {
        guard let layout = view.layoutManager else { return }
        let string = view.string as NSString
        var range = range
        if range.length == 0 {
            range = SymbolText.word(in: string, at: range.location) ?? NSRange(location: range.location, length: min(1, string.length - range.location))
        }
        guard range.length > 0, NSMaxRange(range) <= string.length else { return }
        layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue, forCharacterRange: range)
        layout.addTemporaryAttribute(.underlineColor, value: color(severity), forCharacterRange: range)
    }

    /// The dot beside a line with something wrong with it.
    static func drawDot(severity: LSPDiagnostic.Severity, x: CGFloat, y: CGFloat, lineHeight: CGFloat) {
        color(severity).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y + (lineHeight - 5) / 2, width: 5, height: 5)).fill()
    }
}

/// Somewhere to come back to.
struct NavigationStop {
    var content: ItemContent
    var inPeek: Bool
}

extension AppModel {
    private var frontSymbolViewer: SymbolViewing? {
        (active.peek ?? active.activeItem).flatMap { existingController(for: $0.id) as? SymbolViewing }
    }

    private func symbolViewer(showing view: NSView?) -> SymbolViewing? {
        guard let view else { return nil }
        for item in active.items + (active.peek.map { [$0] } ?? []) {
            if let viewer = existingController(for: item.id) as? SymbolViewing, view === viewer.symbolTextView || view.isDescendant(of: viewer.symbolTextView) {
                return viewer
            }
        }
        return nil
    }

    /// The name at a point in a window, in whichever code viewer is there.
    private func symbol(at point: NSPoint, in window: NSWindow) -> (viewer: SymbolViewing, range: NSRange, index: Int)? {
        guard let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point),
              let viewer = symbolViewer(showing: hit) else { return nil }
        let view = viewer.symbolTextView
        guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
        var inside = view.convert(point, from: nil)
        inside.x -= view.textContainerInset.width
        inside.y -= view.textContainerInset.height
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inside, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inside) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard let range = SymbolText.word(in: view.string as NSString, at: index) else { return nil }
        return (viewer, range, index)
    }

    /// ⌘-click on a name. Handled here so the viewer doesn't also start a second selection.
    func codeCommandClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift),
              let window = event.window, let found = symbol(at: event.locationInWindow, in: window) else { return false }
        clearSymbolHover()
        found.viewer.symbolTextView.setSelectedRange(NSRange(location: found.range.location, length: 0))
        goToDefinition(in: found.viewer, range: found.range)
        return true
    }

    /// What ⌘-click does, without the click: for `tiri follow`.
    func followSymbol(in viewer: SymbolViewing, row: Int, column: Int) -> Bool {
        let string = viewer.symbolTextView.string as NSString
        var start = 0
        for _ in 0..<row {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            guard NSMaxRange(line) < string.length else { return false }
            start = NSMaxRange(line)
        }
        guard let range = SymbolText.word(in: string, at: start + column) else { return false }
        goToDefinition(in: viewer, range: range)
        return true
    }

    /// Holding ⌘ underlines the name under the mouse, as it does a path in a terminal.
    func codeHoverEvent(_ event: NSEvent) {
        // Pressing ⌘ says nothing about where the mouse is, so the window has to be asked.
        let point = event.type == .mouseMoved ? event.locationInWindow : window?.mouseLocationOutsideOfEventStream
        guard event.modifierFlags.contains(.command), event.window === window, let window, let point,
              let found = symbol(at: point, in: window) else {
            clearSymbolHover()
            return
        }
        let view = found.viewer.symbolTextView
        if symbolHover?.view === view, symbolHover?.range == found.range { return }
        clearSymbolHover()
        view.layoutManager?.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: found.range)
        symbolHover = (view, found.range)
        NSCursor.pointingHand.set()
        // Holding it there a moment asks what the name is. Passing over names doesn't.
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.presentHover(in: found.viewer, range: found.range, explicit: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func clearSymbolHover() {
        hoverWork?.cancel()
        hoverWork = nil
        guard let hover = symbolHover else { return }
        symbolHover = nil
        hoverPopover?.close()
        let length = ((hover.view?.string ?? "") as NSString).length
        if NSMaxRange(hover.range) <= length {
            hover.view?.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: hover.range)
        }
        // That can take a problem's own underline with it.
        symbolViewer(showing: hover.view)?.diagnosticsChanged()
        NSCursor.arrow.set()
    }

    private func nameAtCursor(in viewer: SymbolViewing) -> NSRange? {
        let view = viewer.symbolTextView
        return SymbolText.word(in: view.string as NSString, at: view.selectedRange().location)
    }

    /// F12: where the name at the cursor is defined.
    func goToDefinition() {
        guard let viewer = frontSymbolViewer else { return }
        guard let range = nameAtCursor(in: viewer) else {
            showToast(title: "Put the cursor on a name first", detail: nil, symbol: "scope", tint: .secondary)
            return
        }
        goToDefinition(in: viewer, range: range)
    }

    /// ⇧F12: everywhere the name at the cursor is used.
    func findReferences() {
        guard let viewer = frontSymbolViewer else { return }
        guard let range = nameAtCursor(in: viewer) else {
            showToast(title: "Put the cursor on a name first", detail: nil, symbol: "scope", tint: .secondary)
            return
        }
        let symbol = (viewer.symbolTextView.string as NSString).substring(with: range)
        let path = viewer.path
        let place = viewer.fileLocation(ofCharacter: range.location)
        Task {
            if let place, let found = await languageServers.references(path: path, line: place.line, character: place.character) {
                showReferences(found, symbol: symbol)
                return
            }
            searchForReferences(of: symbol, near: path)
        }
    }

    /// ⌘K ⌘I: what the name at the cursor is, and anything wrong with it.
    func showHover() {
        guard let viewer = frontSymbolViewer else { return }
        guard let range = nameAtCursor(in: viewer) else {
            showToast(title: "Put the cursor on a name first", detail: nil, symbol: "scope", tint: .secondary)
            return
        }
        presentHover(in: viewer, range: range, explicit: true)
    }

    private func presentHover(in viewer: SymbolViewing, range: NSRange, explicit: Bool) {
        let view = viewer.symbolTextView
        guard let place = viewer.fileLocation(ofCharacter: range.location), let layout = view.layoutManager, let container = view.textContainer else { return }
        let symbol = (view.string as NSString).substring(with: range)
        let path = viewer.path
        Task {
            let blocks = await languageServers.hover(path: path, line: place.line, character: place.character)
            let known = languageServers.knownDiagnostics(for: path)
            let problems = known.filter { $0.line <= place.line && place.line <= $0.endLine }
            guard !blocks.isEmpty || !problems.isEmpty else {
                if explicit {
                    showToast(title: "Nothing to say about \(symbol)", detail: "A language server has more to say than a search of the files. See Settings.", symbol: "questionmark.circle", tint: .secondary)
                }
                return
            }
            // ⌘ may have been let go by the time the answer comes.
            guard explicit || symbolHover?.range == range else { return }
            hoverPopover?.close()
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerInset.width
            rect.origin.y += view.textContainerInset.height
            let popover = NSPopover()
            popover.behavior = .transient
            let content = SymbolHoverView(blocks: blocks, problems: problems) { [weak self, weak popover] in
                popover?.close()
                self?.quoteDiagnostics(problems, path: path)
            }
            let host = NSHostingController(rootView: content)
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            hoverPopover = popover
        }
    }

    private func goToDefinition(in viewer: SymbolViewing, range: NSRange) {
        let symbol = (viewer.symbolTextView.string as NSString).substring(with: range)
        let path = viewer.path
        let place = viewer.fileLocation(ofCharacter: range.location)
        let here = place.map { $0.line + 1 }
        Task {
            // A server knows. A search makes a good guess, for when there's no server or no answer yet.
            if let place, let found = await languageServers.definition(path: path, line: place.line, character: place.character) {
                if found.count == 1, Git.real(found[0].path) == Git.real(path), found[0].line == here {
                    if let references = await languageServers.references(path: path, line: place.line, character: place.character) {
                        showReferences(references, symbol: symbol)
                    } else {
                        searchForReferences(of: symbol, near: path)
                    }
                    return
                }
                showSymbolResults(found, symbol: symbol, title: { "\($0) definitions of \(symbol). Type to narrow down." },
                                  emptyTitle: "No definition of \(symbol) found")
                return
            }
            let paths = await searchablePaths()
            let cancellation = ContentSearch.Cancellation()
            let found = await Task.detached(priority: .userInitiated) {
                DefinitionSearch.run(paths: paths, symbol: symbol, near: path, cancellation: cancellation)
            }.value
            // Already at the only definition: what's useful now is where it's used.
            if found.count == 1, found[0].path == path, found[0].line == here {
                searchForReferences(of: symbol, near: path)
                return
            }
            showSymbolResults(found, symbol: symbol, title: { "\($0) definitions of \(symbol). Type to narrow down." },
                              emptyTitle: "No definition of \(symbol) found")
        }
    }

    private func showReferences(_ found: [SymbolLocation], symbol: String) {
        showSymbolResults(found, symbol: symbol, title: { "\($0) uses of \(symbol). Type to narrow down." },
                          emptyTitle: "No uses of \(symbol) found")
    }

    private func searchForReferences(of symbol: String, near path: String) {
        Task {
            let paths = await searchablePaths()
            let cancellation = ContentSearch.Cancellation()
            let found = await Task.detached(priority: .userInitiated) {
                DefinitionSearch.references(paths: paths, symbol: symbol, near: path, cancellation: cancellation)
            }.value
            showReferences(found, symbol: symbol)
        }
    }

    /// The same rule as paths: one opens, several offer a choice, and none never stops you.
    func showSymbolResults(_ results: [SymbolLocation], symbol: String, title: (Int) -> String, emptyTitle: String) {
        // Servers answer with real paths. The workspace may know a folder by a link to it.
        let found = results.map { location in
            var location = location
            location.path = aliasedPath(location.path)
            return location
        }
        guard let first = found.first else {
            showToast(title: emptyTitle, detail: "Searched this workspace's files.", symbol: "magnifyingglass", tint: .secondary,
                      actionTitle: "Search in Files") { [weak self] in
                guard let self else { return }
                self.lastSearchQuery = symbol
                self.palette = PaletteModel(mode: .search, model: self, initialQuery: symbol)
            }
            return
        }
        guard found.count > 1 else {
            navigate(to: first)
            return
        }
        let rows = found.map { location in
            let relative = active.folder(containing: location.path) != nil ? active.relativePath(location.path) : (location.path as NSString).abbreviatingWithTildeInPath
            return PaletteModel.Row(id: location.id, title: location.text, detail: "\(relative):\(location.line)",
                                    symbol: FileIcons.symbolName(forName: (location.path as NSString).lastPathComponent, isDirectory: false)) { [weak self] _ in
                self?.closePalette(restoreFocus: false)
                self?.navigate(to: location)
            }
        }
        openPalette(.choices(title: title(found.count), rows: rows))
    }

    /// Goes there, remembering where you were. Another file floats as a Peek.
    func navigate(to location: SymbolLocation) {
        rememberStop()
        let front = active.peek ?? active.activeItem
        if case .file(let spec)? = front?.content, Git.real(spec.path) == Git.real(location.path), let id = front?.id {
            existingController(for: id)?.goTo(line: location.line, col: location.column)
            return
        }
        open(path: location.path, line: location.line, col: location.column, intent: .peek(takeFocus: true))
    }

    private func rememberStop() {
        guard let item = active.peek ?? active.activeItem else { return }
        let inPeek = active.peek?.id == item.id
        var content = item.content
        if case .file(var spec) = content, let viewer = existingController(for: item.id) as? SymbolViewing {
            let view = viewer.symbolTextView
            let place = viewer.fileLocation(ofCharacter: view.selectedRange().location)
            spec.line = place.map { $0.line + 1 }
            spec.col = place.map { $0.character + 1 }
            content = .file(spec)
        }
        navigationStops.append(NavigationStop(content: content, inPeek: inPeek))
        if navigationStops.count > 50 { navigationStops.removeFirst() }
    }

    var canGoBack: Bool { !navigationStops.isEmpty }

    func goBack() {
        guard let stop = navigationStops.popLast() else { return }
        switch stop.content {
        case .file(let spec):
            if !stop.inPeek { dismissPeek(restoreFocus: false, keepStops: true) }
            open(path: spec.path, line: spec.line, col: spec.col, intent: stop.inPeek ? .peek(takeFocus: true) : .pinned)
            requestFocus()
        case .diff(let spec):
            if stop.inPeek {
                peekDiff(path: spec.path, takeFocus: true, turn: spec.turn)
            } else {
                dismissPeek(restoreFocus: false, keepStops: true)
                openDiff(path: spec.path, preview: false, turn: spec.turn)
            }
        default:
            break
        }
    }

    func canAskAboutSymbols() -> Bool { frontSymbolViewer != nil }
}

/// In front of a file you've jumped from.
struct BackButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.canGoBack {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back (\(model.shortcutSymbol(for: "goBack") ?? "⌃-"))")
            .accessibilityLabel("Back")
        }
    }
}
