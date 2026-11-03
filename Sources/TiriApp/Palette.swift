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
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        var positions: [Int] = []
        var detail: String?
        var shortcut: String?
        var symbol: String?
        var action: (_ alternate: Bool) -> Void
    }

    @ObservationIgnored unowned let model: AppModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var mode: Mode
    var query: String {
        didSet { if oldValue != query { refresh() } }
    }
    var rows: [Row] = []
    var selection = 0
    var isIndexing = false

    init(mode: Mode, model: AppModel, initialQuery: String = "") {
        self.mode = mode
        self.model = model
        self.query = initialQuery
        if case .files = mode {
            model.fileIndex.onUpdate = { [weak self] in self?.refresh() }
            model.fileIndex.refreshIfNeeded(roots: model.active.folders,
                                            excludes: ExcludeMatcher(patterns: model.settings.filesExclude))
        }
        refresh()
    }

    var placeholder: String {
        switch mode {
        case .files: "Search files by name. Add :line to jump, or > for commands."
        case .commands: "Type a command"
        case .prompt(let title, _), .choices(let title, _): title
        }
    }

    var effectiveMode: Mode {
        if case .files = mode, query.hasPrefix(">") { return .commands }
        return mode
    }

    func refresh() {
        searchTask?.cancel()
        switch effectiveMode {
        case .files: refreshFiles()
        case .commands: refreshCommands()
        case .prompt: rows = []
        case .choices(_, let all): refreshChoices(all)
        }
    }

    // MARK: Choices

    private func refreshChoices(_ all: [Row]) {
        let text = query.trimmingCharacters(in: .whitespaces)
        rows = text.isEmpty ? all : all.filter {
            FuzzyMatcher.match(query: text, candidate: ($0.detail ?? "") + "/" + $0.title, nameStart: 0) != nil
        }
        selection = 0
    }

    // MARK: Commands

    private func refreshCommands() {
        let text = query.hasPrefix(">") ? String(query.dropFirst()) : query
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let commands = model.allCommands
        var scored: [(Int, Row)] = []
        for (order, command) in commands.enumerated() {
            let label = "\(command.category): \(command.title)"
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
            }
        }
        scored.sort { $0.0 > $1.0 }
        rows = scored.prefix(60).map(\.1)
        selection = 0
    }

    // MARK: Files

    /// `name:12`, `name:12:3`, `name 12`
    static func splitLocation(_ query: String) -> (query: String, line: Int?, col: Int?) {
        if let match = query.wholeMatch(of: /(.*?):(\d+)(?::(\d+))?/) {
            return (String(match.1), Int(match.2), match.3.flatMap { Int($0) })
        }
        if query.hasSuffix(":") { return (String(query.dropLast()), nil, nil) }
        return (query, nil, nil)
    }

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
            model.open(path: path, line: line, col: col, intent: alternate ? .split(.right) : .pinned)
            model.requestFocus()
        }
    }

    private func refreshFiles() {
        let (text, line, col) = Self.splitLocation(query.trimmingCharacters(in: .whitespaces))
        let files = model.fileIndex.files
        let workspace = model.active
        isIndexing = files.isEmpty && !workspace.folders.isEmpty

        if text.isEmpty {
            // Empty query: where you've just been, then the rest, as in Cursor.
            var seen = Set<String>()
            var list: [Row] = []
            for path in model.recentFilesInActive + workspace.items.compactMap(\.filePath) where !seen.contains(path) {
                seen.insert(path)
                let root = workspace.folder(containing: path)
                list.append(fileRow(path: path, relative: workspace.relativePath(path), root: root ?? "", positions: [], line: line, col: col))
            }
            for file in files.prefix(80) where !seen.contains(file.path) {
                seen.insert(file.path)
                list.append(fileRow(path: file.path, relative: file.relative, root: file.root, positions: [], line: line, col: col))
            }
            rows = list
            selection = 0
            return
        }

        let normalized = FuzzyMatcher.normalize(text)
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
                guard let match = FuzzyMatcher.match(query: normalized, candidate: bytes, nameStart: nameStart) else { continue }
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
            }
        }
    }

    // MARK: Keys

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func submit(alternate: Bool = false) {
        if case .prompt(_, let commit) = mode {
            let value = query
            model.closePalette()
            commit(value)
            return
        }
        guard rows.indices.contains(selection) else { return }
        rows[selection].action(alternate)
    }
}

struct PaletteView: View {
    @Bindable var palette: PaletteModel
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
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

            if !palette.rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                                PaletteRowView(row: row, selected: index == palette.selection)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        palette.selection = index
                                        palette.submit(alternate: NSEvent.modifierFlags.contains(.command))
                                    }
                            }
                        }
                        .padding(6)
                    }
                    // A list that fits its rows: a lone result shouldn't sit in a tall empty panel.
                    .frame(height: min(CGFloat(palette.rows.count) * 29 + 12, 380))
                    .onChange(of: palette.selection) { _, value in
                        if palette.rows.indices.contains(value) {
                            proxy.scrollTo(palette.rows[value].id)
                        }
                    }
                }
            }
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .onAppear { focused = true }
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

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(attributedTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let shortcut = row.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.22))
            }
        }
    }
}
