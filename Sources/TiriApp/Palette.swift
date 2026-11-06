import AppKit
import Observation
import SwiftUI
import TiriCore

/// Quick open, the command palette and short prompts all share this one surface.
@Observable
final class PaletteModel {
    enum Mode {
        case files
        case commands
        case prompt(title: String, commit: (String) -> Void)
        case choices(title: String, rows: [Row])
        case search
        /// Rows that depend on what's typed and may take a moment, like folders on a server.
        case dynamic(title: String, provider: (_ query: String, _ deliver: @escaping ([Row]) -> Void) -> Void)
        /// Typed into quick open, as in VS Code: `:` a line, `@` a symbol here, `#` one anywhere.
        case goToLine
        case symbols
        case workspaceSymbols
    }

    struct Row: Identifiable {
        /// Something on the row for the mouse, beside what clicking the row does.
        struct Button {
            let title: String
            let action: () -> Void
        }

        let id: String
        var title: String
        var positions: [Int] = []
        var detail: String?
        /// A second line, with what matched between `ConversationIndex`'s marks.
        var excerpt: String?
        /// Always two lines, so that rows don't move as a second line arrives, and the detail keeps its
        /// place at the end of the first, where a long title can't squeeze it out.
        var twoLines = false
        var shortcut: String?
        var symbol: String?
        var button: Button?
        /// It's scrolled into view, for work worth doing only for what's seen.
        var appeared: (() -> Void)?
        /// Shows it without leaving where you were, for arrowing through a list.
        var preview: (() -> Void)?
        var action: (_ alternate: Bool) -> Void
    }

    @ObservationIgnored unowned let model: AppModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var mode: Mode
    var query: String {
        didSet {
            // A field selects what's in it on the way to getting the keyboard, and the first
            // key typed shouldn't take `:` or `@` with it.
            if let typed = typedPrefix {
                typedPrefix = nil
                if oldValue == typed, !query.isEmpty, !query.hasPrefix(typed) { query = typed + query }
            }
            if oldValue != query { refresh() }
        }
    }
    @ObservationIgnored private var typedPrefix: String?
    var rows: [Row] = []
    var selection = 0
    var isIndexing = false
    /// Something to say instead of results.
    var note: String?
    /// Asking for a change to Tiri: what that is, below the question.
    var showsChangePanel = false
    /// A prompt's rows, which never come from what's typed.
    @ObservationIgnored private var promptRows: [Row] = []
    /// Above the field, for a question whose field already holds an answer.
    var heading: String?
    /// It closed without an answer: Esc, a click elsewhere, or another palette taking its place.
    @ObservationIgnored var onCancel: (() -> Void)?

    init(mode: Mode, model: AppModel, initialQuery: String = "") {
        self.mode = mode
        self.model = model
        self.query = initialQuery
        if case .files = mode, !initialQuery.isEmpty { typedPrefix = initialQuery }
        if case .files = mode {
            model.fileIndex.onUpdate = { [weak self] in self?.refresh() }
            model.fileIndex.refreshIfNeeded(roots: model.active.folders,
                                            excludes: ExcludeMatcher(patterns: model.settings.filesExclude))
        }
        refresh()
    }

    var placeholder: String {
        switch mode {
        case .files: String(localized: "Search files by name. Add :line to jump, or > for commands.")
        case .commands: String(localized: "Type a command")
        case .prompt(let title, _), .choices(let title, _), .dynamic(let title, _): title
        case .search: String(localized: "Search in files")
        case .goToLine, .symbols, .workspaceSymbols: ""
        }
    }

    var effectiveMode: Mode {
        if case .files = mode {
            if query.hasPrefix(">") { return .commands }
            if query.hasPrefix(":") { return .goToLine }
            if query.hasPrefix("@") { return .symbols }
            if query.hasPrefix("#") { return .workspaceSymbols }
        }
        return mode
    }

    /// A new title for a row already showing, without looking again or moving anything. What it replaced
    /// goes beneath it, unless that's already showing where a search matched.
    func retitle(_ id: String, _ title: String, below: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].title = title
        if rows[index].excerpt?.isEmpty != false { rows[index].excerpt = below }
    }

    func refresh() {
        searchTask?.cancel()
        note = nil
        var previews = false
        switch effectiveMode {
        case .files: refreshFiles()
        case .commands: refreshCommands()
        case .prompt:
            rows = promptRows
            selection = -1
        case .choices(_, let all): refreshChoices(all)
        case .search: refreshSearch()
        case .dynamic(_, let provider):
            let asked = query
            provider(asked) { [weak self] found in
                // A slower answer to an earlier question doesn't get a say.
                guard let self, self.query == asked else { return }
                // Only a row you've moved to: otherwise the top stays selected as better results arrive.
                let keepsRow = self.selection > 0 && self.rows.indices.contains(self.selection) ? self.rows[self.selection].id : nil
                self.rows = found
                self.selection = keepsRow.flatMap { id in found.firstIndex { $0.id == id } } ?? 0
            }
        case .goToLine:
            previews = true
            refreshGoToLine()
        case .symbols:
            previews = true
            refreshSymbols()
        case .workspaceSymbols: refreshWorkspaceSymbols()
        }
        if !previews { endPreview() }
        // Nothing to show is still an answer.
        if case .commands = effectiveMode, rows.isEmpty, !query.isEmpty {
            note = String(localized: "No command matches.")
            offerToAdd()
        }
    }

    /// The moment someone has shown they want something the app doesn't do, and no sooner.
    private func offerToAdd() {
        let asked = (query.hasPrefix(">") ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty, model.yourTiri.entriesAreOn, let preset = model.runnableAgentPresets().first else { return }
        rows = [Row(id: "ask-to-add", title: String(localized: "Ask \(preset.name) to add this"), positions: [], shortcut: nil) { [model] _ in
            model.closePalette()
            model.yourTiri.beginChange(surface: "the command palette, searching for \u{201C}\(asked)\u{201D}", initial: asked)
        }]
        selection = 0
    }

    /// `otherwise` is what to say when a file is open, but it isn't the kind that has this.
    private func noFileNote(otherwise: String) -> String {
        model.active.activeItem?.filePath == nil ? String(localized: "Open a file first.") : otherwise
    }

    // MARK: Showing what's selected

    @ObservationIgnored private var previewTarget: OutlineViewing?
    @ObservationIgnored private var restoreView: (() -> Void)?
    @ObservationIgnored private var committed = false

    private func outlineTarget() -> OutlineViewing? {
        if let previewTarget { return previewTarget }
        guard let target = model.frontOutlineTarget else { return nil }
        previewTarget = target
        restoreView = target.beginPreview()
        return target
    }

    /// Going back to files or commands: the view goes back too.
    private func endPreview() {
        previewTarget?.clearPreview()
        restoreView?()
        previewTarget = nil
        restoreView = nil
    }

    /// The palette is closing. Only a choice keeps what's been shown.
    var typesAfterQuery: Bool {
        if case .files = mode { return !query.isEmpty }
        return false
    }

    func finish() {
        previewTarget?.clearPreview()
        if !committed { restoreView?() }
        if !committed, let cancelled = onCancel {
            onCancel = nil
            cancelled()
        }
        previewTarget = nil
        restoreView = nil
        searchTask?.cancel()
    }

    // MARK: Go to line

    private func refreshGoToLine() {
        guard let target = outlineTarget() else {
            rows = []
            note = noFileNote(otherwise: String(localized: "This kind of file has no lines to go to."))
            return
        }
        let parts = query.dropFirst().split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        let lineCount = target.outlineLineCount
        guard let wanted = parts.first ?? nil else {
            selection = 0
            let here = target.outlineCurrentLine
            let ask = String(localized: "Type a line number, from 1 to \(lineCount.formatted()). You're on line \(here.formatted()).")
            rows = [Row(id: "line", title: ask) { [model] _ in
                model.closePalette()
            }]
            return
        }
        let line = min(max(wanted, 1), lineCount)
        let col = parts.count > 1 ? parts[1] : nil
        let path = target.path
        let row = Row(id: "line", title: String(localized: "Go to line \(line.formatted())"), preview: { target.previewLine(line) }) { [model] _ in
            model.closePalette(restoreFocus: false)
            model.navigate(to: SymbolLocation(path: path, line: line, column: col ?? 1, text: ""))
            model.requestFocus()
        }
        rows = [row]
        selection = 0
        row.preview?()
    }

    // MARK: Symbols

    @ObservationIgnored private var symbolsPath: String?
    @ObservationIgnored private var fileSymbols: [DocumentSymbol] = []
    @ObservationIgnored private var symbolsFromServer = false

    private func refreshSymbols() {
        guard let target = outlineTarget() else {
            rows = []
            note = noFileNote(otherwise: String(localized: "This kind of file has no symbols to go to."))
            return
        }
        if symbolsPath != target.path {
            symbolsPath = target.path
            loadSymbols(of: target)
        }
        showSymbols(moved: true)
    }

    /// A reading of the text shows right away, and the server's answer replaces it when it comes.
    private func loadSymbols(of target: OutlineViewing) {
        let path = target.path
        let text = target.outlineText
        isIndexing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = SimpleSymbols.scan(text, path: path)
            await MainActor.run { [weak self] in
                guard let self, !self.symbolsFromServer, self.symbolsPath == path else { return }
                self.fileSymbols = found
                self.showSymbols(moved: false)
            }
        }
        Task { [weak self] in
            let answer = await self?.model.languageServers.documentSymbols(path: path)
            guard let self, self.symbolsPath == path else { return }
            self.isIndexing = false
            if let answer {
                self.symbolsFromServer = true
                self.fileSymbols = answer
            }
            self.showSymbols(moved: false)
        }
    }

    private func showSymbols(moved: Bool) {
        guard case .symbols = effectiveMode, let target = previewTarget else { return }
        let previous = rows.indices.contains(selection) ? rows[selection].id : nil
        let text = query.dropFirst().trimmingCharacters(in: .whitespaces)
        var list: [Row]
        if text.isEmpty {
            list = fileSymbols.prefix(2_000).map { symbolRow($0, positions: [], target: target) }
        } else {
            let pieces = FuzzyMatcher.pieces(text)
            var scored: [(score: Int, order: Int, row: Row)] = []
            for (order, symbol) in fileSymbols.enumerated() {
                guard let match = FuzzyMatcher.match(pieces: pieces, candidate: Array(symbol.name.utf8), nameStart: 0) else { continue }
                scored.append((match.score, order, symbolRow(symbol, positions: match.positions, target: target)))
            }
            scored.sort { ($0.score, $1.order) > ($1.score, $0.order) }
            list = scored.prefix(500).map(\.row)
        }
        rows = list
        selection = previous.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        if list.isEmpty, !isIndexing { note = text.isEmpty ? String(localized: "No symbols found in this file.") : String(localized: "No symbol matches.") } else { note = nil }
        // Typing jumps to the best match. Just opening stays where you are.
        if moved, !text.isEmpty, list.indices.contains(selection) { list[selection].preview?() }
    }

    private func symbolRow(_ symbol: DocumentSymbol, positions: [Int], target: OutlineViewing) -> Row {
        let path = target.path
        return Row(id: symbol.id, title: symbol.name, positions: positions, detail: symbol.container, shortcut: ":\(symbol.line)",
                   symbol: Self.icon(for: symbol.kind), preview: { target.previewLine(symbol.line) }) { [model] _ in
            model.closePalette(restoreFocus: false)
            model.navigate(to: SymbolLocation(path: path, line: symbol.line, column: symbol.column, text: symbol.name))
            model.requestFocus()
        }
    }

    private static func icon(for kind: DocumentSymbol.Kind) -> String {
        switch kind {
        case .function: "function"
        case .method: "m.square"
        case .type: "t.square"
        case .property: "p.square"
        case .variable: "v.square"
        case .constant: "c.square"
        case .module: "shippingbox"
        case .heading: "number"
        case .other: "circle.dashed"
        }
    }

    // MARK: Symbols anywhere

    private func refreshWorkspaceSymbols() {
        let text = query.dropFirst().trimmingCharacters(in: .whitespaces)
        let near = model.frontCodePath
        let folders = model.active.folders
        rows = []
        selection = 0
        isIndexing = true
        searchTask = Task { [weak self] in
            // A pause for typing: each letter is a question to a server.
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard let self, !Task.isCancelled else { return }
            let found = await self.model.languageServers.workspaceSymbols(query: text, near: near, folders: folders)
            guard !Task.isCancelled else { return }
            self.isIndexing = false
            guard let found else {
                self.note = String(localized: "No language server running here can search the whole workspace. ⌘⇧O works on one file, and ⌘⇧F searches the text.")
                return
            }
            if found.isEmpty {
                self.note = text.isEmpty ? String(localized: "Type a name to find it anywhere in this workspace.")
                    : String(localized: "No symbol matches. A language server may still be reading the project.")
            }
            self.rows = found.prefix(200).map { self.workspaceSymbolRow($0) }
            self.selection = 0
        }
    }

    private func workspaceSymbolRow(_ symbol: DocumentSymbol) -> Row {
        let path = model.aliasedPath(symbol.path ?? "")
        let relative = model.active.folder(containing: path) != nil ? model.active.relativePath(path) : (path as NSString).abbreviatingWithTildeInPath
        return Row(id: symbol.id, title: symbol.name, detail: "\(relative):\(symbol.line)", symbol: Self.icon(for: symbol.kind)) { [model] alternate in
            model.closePalette(restoreFocus: false)
            model.open(path: path, line: symbol.line, col: symbol.column, intent: alternate ? .split(.right) : .pinned)
            model.requestFocus()
        }
    }

    // MARK: Search

    private var searchCancellation: ContentSearch.Cancellation?
    var searchFoundNothing = false

    private func refreshSearch() {
        searchCancellation?.cancel()
        searchFoundNothing = false
        let text = query
        model.lastSearchQuery = text
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            rows = []
            isIndexing = false
            return
        }
        let cancellation = ContentSearch.Cancellation()
        searchCancellation = cancellation
        isIndexing = true
        searchTask = Task { [weak self] in
            // A pause for typing, so each letter doesn't set off a search of the whole project.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, !cancellation.isCancelled else { return }
            let paths = await self.model.searchablePaths()
            let connection = self.model.activeConnection
            let folders = self.model.active.folders
            let excludes = self.model.settings.filesExclude
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            let collector = SearchCollector()
            Task.detached(priority: .userInitiated) {
                AppModel.runSearch(query: text, on: connection, folders: folders, paths: paths, excludes: excludes, cancellation: cancellation) { batch in
                    collector.add(batch)
                }
                collector.finish()
            }
            // Results show as they arrive. Waiting for the whole search would feel slow on big projects.
            while !Task.isCancelled, !collector.isFinished {
                try? await Task.sleep(for: .milliseconds(60))
                self.showSearchResults(collector.sorted(), final: false)
            }
            guard !Task.isCancelled else { return }
            self.showSearchResults(collector.sorted(), final: true)
        }
    }

    private func showSearchResults(_ matches: [ContentMatch], final: Bool) {
        guard rows.count != matches.count || final else { return }
        let previous = rows.indices.contains(selection) ? rows[selection].id : nil
        rows = matches.map { match in
            let relative = model.active.folder(containing: match.path) != nil ? model.active.relativePath(match.path)
                : (match.path as NSString).abbreviatingWithTildeInPath
            let name = (match.path as NSString).lastPathComponent
            return Row(id: match.id, title: match.text,
                       positions: Array(match.matchOffset..<(match.matchOffset + match.matchLength)),
                       detail: "\(relative):\(match.line)",
                       symbol: FileIcons.symbolName(forName: name, isDirectory: false)) { [model] alternate in
                model.closePalette(restoreFocus: false)
                model.open(path: match.path, line: match.line, intent: alternate ? .pinned : .peek(takeFocus: true))
                model.requestFocus()
            }
        }
        selection = previous.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        if final {
            isIndexing = false
            searchFoundNothing = rows.isEmpty
        }
    }

    // MARK: Choices

    private func refreshChoices(_ all: [Row]) {
        let text = query.trimmingCharacters(in: .whitespaces)
        let matching = text.isEmpty ? all : all.filter {
            FuzzyMatcher.match(query: text, candidate: ($0.detail ?? "") + "/" + $0.title, nameStart: 0) != nil
        }
        // What you typed, word for word, comes before what merely has those letters in order.
        func contains(_ row: Row) -> Bool {
            !text.isEmpty && (row.title + " " + (row.detail ?? "")).localizedCaseInsensitiveContains(text)
        }
        rows = matching.filter(contains) + matching.filter { !contains($0) }
        selection = 0
    }

    // MARK: Commands

    private func refreshCommands() {
        let text = query.hasPrefix(">") ? String(query.dropFirst()) : query
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let commands = model.allCommands
        var scored: [(Int, Row)] = []
        for (order, command) in commands.enumerated() {
            let (label, english) = command.paletteLabel
            let row = { [model] (positions: [Int]) in
                Row(id: command.id, title: label, positions: positions,
                    shortcut: model.shortcutSymbol(for: command.id)) { _ in
                    model.closePalette()
                    command.action(model)
                }
            }
            if trimmed.isEmpty {
                scored.append((-order, row([])))
            } else if let match = FuzzyMatcher.match(query: trimmed, candidate: label, nameStart: 0) {
                scored.append((match.score, row(match.positions)))
            } else if english != label, let match = FuzzyMatcher.match(query: trimmed, candidate: english, nameStart: 0) {
                // Typed in English, as in a guide or by habit. What matched isn't on the row to mark.
                scored.append((match.score, row([])))
            }
        }
        scored.sort { $0.0 > $1.0 }
        rows = scored.prefix(60).map(\.1)
        selection = 0
    }

    // MARK: Files

    private func fileRow(path: String, relative: String, root: String, positions: [Int], line: Int?, col: Int?) -> Row {
        let name = (relative as NSString).lastPathComponent
        let directory = (relative as NSString).deletingLastPathComponent
        let multiRoot = model.active.folders.count > 1
        let rootName = (root as NSString).lastPathComponent
        let detail = multiRoot ? (directory.isEmpty ? rootName : rootName + " • " + directory) : directory
        let nameOffset = relative.utf8.count - name.utf8.count
        let namePositions = positions.filter { $0 >= nameOffset }.map { $0 - nameOffset }
        return Row(id: path, title: name, positions: namePositions, detail: detail,
                   symbol: FileIcons.symbolName(forName: name, isDirectory: false)) { [model] alternate in
            model.closePalette(restoreFocus: false)
            // The cursor goes to the start of the line, as in Cursor, with nothing selected to type over.
            model.open(path: path, line: line, col: line == nil ? col : (col ?? 1), intent: alternate ? .split(.right) : .pinned)
            model.requestFocus()
        }
    }

    private func refreshFiles() {
        let (text, line, col) = PaletteQuery.location(query.trimmingCharacters(in: .whitespaces))
        let files = model.fileIndex.files
        let workspace = model.active
        isIndexing = files.isEmpty && !workspace.folders.isEmpty

        if text.isEmpty {
            // Empty query: where you've just been, then the rest, as in Cursor.
            var seen = Set<String>()
            var list: [Row] = []
            for path in model.recentFilesInActive + workspace.items.compactMap(\.filePath) where !seen.contains(path) {
                seen.insert(path)
                // These can outlive their files.
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let root = workspace.folder(containing: path)
                list.append(fileRow(path: path, relative: workspace.relativePath(path), root: root ?? "", positions: [], line: line, col: col))
            }
            for file in files.prefix(80) where !seen.contains(file.path) {
                seen.insert(file.path)
                list.append(fileRow(path: file.path, relative: file.relative, root: file.root, positions: [], line: line, col: col))
            }
            rows = list
            // The file you're already in comes first, but ⌘P then Return means the one before it.
            selection = list.count > 1 && list[0].id == workspace.activeItem?.filePath ? 1 : 0
            return
        }

        let pieces = FuzzyMatcher.pieces(text)
        let recents = Dictionary(model.recentFilesInActive.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Scoring tens of thousands of paths runs off the main thread, newest query wins.
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            struct Hit { let file: IndexedFile; let score: Int; let positions: [Int] }
            var hits: [Hit] = []
            hits.reserveCapacity(256)
            var index = 0
            for file in files {
                index += 1
                if index % 4096 == 0, Task.isCancelled { return }
                let bytes = Array(file.relative.utf8)
                let nameStart = bytes.count - file.name.utf8.count
                guard let match = FuzzyMatcher.match(pieces: pieces, candidate: bytes, nameStart: nameStart) else { continue }
                let recency = recents[file.path].map { 40 - min($0, 30) } ?? 0
                hits.append(Hit(file: file, score: match.score + recency, positions: match.positions))
            }
            hits.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.file.relative.count < rhs.file.relative.count
            }
            let top = Array(hits.prefix(60))
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rows = top.map {
                    self.fileRow(path: $0.file.path, relative: $0.file.relative, root: $0.file.root,
                                 positions: $0.positions, line: line, col: col)
                }
                self.selection = 0
                self.isIndexing = false
                self.note = top.isEmpty && !files.isEmpty ? String(localized: "No file matches.") : nil
            }
        }
    }

    // MARK: Keys

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
        rows[selection].preview?()
    }

    func setPromptRows(_ found: [Row]) {
        promptRows = found
        rows = found
        selection = -1
    }

    /// A click. In a prompt, a row is a thing of its own, and doesn't send what's been typed.
    func activate(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selection = index
        if case .prompt = mode {
            rows[index].action(false)
        } else {
            submit(alternate: NSEvent.modifierFlags.contains(.command))
        }
    }

    func submit(alternate: Bool = false) {
        if case .prompt(_, let commit) = mode {
            // Nothing typed, and arrowed down to a row.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rows.indices.contains(selection) {
                rows[selection].action(alternate)
                return
            }
            let value = query
            committed = true
            model.closePalette()
            commit(value)
            return
        }
        guard rows.indices.contains(selection) else { return }
        committed = true
        rows[selection].action(alternate)
    }
}

/// Collects a search's matches as they come in from many threads.
nonisolated final class SearchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var matches: [ContentMatch] = []
    private var finished = false

    func finish() { lock.withLock { finished = true } }
    var isFinished: Bool { lock.withLock { finished } }

    func add(_ batch: [ContentMatch]) { lock.withLock { matches.append(contentsOf: batch) } }
    var count: Int { lock.withLock { matches.count } }

    func sorted() -> [ContentMatch] {
        lock.withLock { matches }.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }
}

struct PaletteView: View {
    @Bindable var palette: PaletteModel
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let heading = palette.heading {
                Text(heading)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            HStack(spacing: 8) {
                TextField(palette.placeholder, text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { palette.submit(alternate: NSEvent.modifierFlags.contains(.command)) }
                    .onKeyPress(.upArrow) {
                        palette.move(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        palette.move(1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        model.closePalette()
                        return .handled
                    }
                if palette.isIndexing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            if palette.showsChangePanel {
                Divider()
                ChangePanel(palette: palette)
            }

            if palette.searchFoundNothing || palette.note != nil {
                Divider()
                Text(palette.note ?? String(localized: "Nothing in this workspace matches."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
            }

            if !palette.rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                                PaletteRowView(row: row, selected: index == palette.selection)
                                    .id(row.id)
                                    .onAppear { row.appeared?() }
                                    .contentShape(Rectangle())
                                    .onTapGesture { palette.activate(index) }
                                    .accessibleRow(row.title, value: row.spokenDetail, selected: index == palette.selection) { palette.activate(index) }
                                    .accessibilityActions {
                                        if let button = row.button { Button(button.title, action: button.action) }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    // A list that fits its rows: a lone result shouldn't sit in a tall empty panel.
                    .frame(height: min(palette.rows.reduce(CGFloat(12)) { $0 + ($1.isTall ? 45 : 29) }, 380))
                    .onChange(of: palette.selection) { _, value in
                        if palette.rows.indices.contains(value) {
                            proxy.scrollTo(palette.rows[value].id)
                            // The keyboard stays in the field, so VoiceOver hears where the arrows went.
                            AccessibilityDisplay.shared.announce(palette.rows[value].spoken, interrupting: false)
                        }
                    }
                }
            }
        }
        .frame(width: 620)
        .tiriGlass(in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .reportingFrame { model.layoutRegistry.paletteFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(palette.placeholder)
        .onAppear {
            focused = true
            // In a window where it's the first thing to appear in a while, once isn't always enough.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            guard isFocused, palette.typesAfterQuery else { return }
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
            }
        }
    }
}

struct PaletteRowView: View {
    let row: PaletteModel.Row
    let selected: Bool

    private var attributedTitle: AttributedString {
        var text = AttributedString(row.title)
        let utf8 = Array(row.title.utf8)
        for position in row.positions where position < utf8.count {
            let start = row.title.utf8.index(row.title.utf8.startIndex, offsetBy: position)
            guard let lower = AttributedString.Index(start, within: text) else { continue }
            let upper = text.index(lower, offsetByCharacters: 1)
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            text[lower..<upper].foregroundColor = .accentColor
        }
        return text
    }

    /// What matched stands out, and starts the line if it would otherwise be cut off.
    private static func marked(_ excerpt: String) -> AttributedString {
        var text = AttributedString()
        var rest = Substring(excerpt)
        while let open = rest.range(of: ConversationIndex.markOpen) {
            text += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: ConversationIndex.markClose) else { break }
            var match = AttributedString(String(rest[..<close.lowerBound]))
            match.foregroundColor = .accentColor
            match.inlinePresentationIntent = .stronglyEmphasized
            text += match
            rest = rest[close.upperBound...]
        }
        text += AttributedString(String(rest))
        return text
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(attributedTitle)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if row.twoLines { Spacer(minLength: 8) }
                    if let detail = row.detail, !detail.isEmpty {
                        if row.twoLines {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let excerpt = row.excerpt, !excerpt.isEmpty {
                    Text(Self.marked(excerpt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = row.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let button = row.button, selected || hovering {
                Button(button.title, action: button.action)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: row.isTall ? 44 : 28)
        .onHover { hovering = $0 }
        .background {
            if selected {
                let contrast = AccessibilityDisplay.shared.increaseContrast
                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(contrast ? 0.4 : 0.22))
                    .overlay { if contrast { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1) } }
            }
        }
    }
}

extension PaletteModel.Row {
    fileprivate var isTall: Bool { twoLines || excerpt?.isEmpty == false }

    /// The rest of the row, in words, without the marks around what matched.
    fileprivate var spokenDetail: String {
        let excerpt = excerpt.map { $0.replacingOccurrences(of: ConversationIndex.markOpen, with: "").replacingOccurrences(of: ConversationIndex.markClose, with: "") }
        return [detail, excerpt, shortcut].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    fileprivate var spoken: String { spokenDetail.isEmpty ? title : title + ", " + spokenDetail }
}
