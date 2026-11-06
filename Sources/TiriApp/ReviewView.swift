import AppKit
import SwiftUI
import TiriCore

// MARK: - The model's side

extension AppModel {
    /// Opens the box for a comment on what's selected in front, or the line the cursor is in.
    func beginReviewComment() {
        guard let item = active.peek ?? active.activeItem, let controller = existingController(for: item.id) else { return }
        guard let anchor = controller.reviewAnchor else {
            if case .file(let spec) = item.content {
                presentReviewEditor(title: (spec.path as NSString).lastPathComponent, initial: "", position: controller.reviewPopoverPosition ?? centerPosition(of: controller)) { [weak self] text in
                    self?.addReviewComment(ReviewAnchor(path: spec.path).comment(text: text))
                }
                return
            }
            showToast(title: "There's nothing to comment on here", detail: "Open a file or a diff, then press ⌥⌘L.", symbol: "text.bubble", tint: .secondary)
            return
        }
        presentReviewEditor(title: anchor.description, initial: "", position: controller.reviewPopoverPosition ?? centerPosition(of: controller)) { [weak self] text in
            self?.addReviewComment(anchor.comment(text: text))
        }
    }

    func editReviewComment(_ comment: ReviewComment, from view: NSView, rect: NSRect) {
        let anchor = ReviewAnchor(path: comment.path, firstLine: comment.firstLine, lastLine: comment.lastLine)
        presentReviewEditor(title: anchor.description, initial: comment.text, position: (view, rect), onDelete: { [weak self] in
            self?.removeReviewComment(comment.id)
        }) { [weak self] text in
            self?.updateReviewComment(comment.id, text: text)
        }
    }

    private func centerPosition(of controller: ItemController) -> (view: NSView, rect: NSRect) {
        let view = controller.view
        return (view, NSRect(x: view.bounds.midX, y: view.bounds.height - 40, width: 1, height: 1))
    }

    private func presentReviewEditor(title: String, initial: String, position: (view: NSView, rect: NSRect),
                                     onDelete: (() -> Void)? = nil, commit: @escaping (String) -> Void) {
        reviewPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let restore = position.view.window?.firstResponder
        let editor = ReviewCommentEditor(title: title, text: initial, isEditing: onDelete != nil, commit: { [weak popover] text in
            commit(popover.flatMap(Self.typedText(in:)) ?? text)
            popover?.close()
        }, delete: onDelete.map { delete in
            { [weak popover] in
                delete()
                popover?.close()
            }
        }, cancel: { [weak popover] in popover?.close() })
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: position.rect, of: position.view, preferredEdge: .maxY)
        reviewPopover = popover
        // Return finishes, as it does in a chat, and Shift+Return makes a new line. Asked of the
        // keys themselves: a box opened on a selection doesn't always become the key window, so
        // SwiftUI's key handling misses them there and Return quietly becomes a new line.
        nonisolated(unsafe) let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak popover] event in
            guard let popover, popover.isShown else { return event }
            let held = event.modifierFlags.intersection([.shift, .command, .option, .control])
            switch event.keyCode {
            case 36, 76 where held.isEmpty:
                if let typed = Self.typedText(in: popover) {
                    commit(typed)
                    popover.close()
                }
                return nil
            case 53 where held.isEmpty:
                popover.close()
                return nil
            default:
                return event
            }
        }
        reviewPopoverCloser = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self, weak restore, weak window = position.view.window] _ in
            MainActor.assumeIsolated {
                if let keys { NSEvent.removeMonitor(keys) }
                if let restore { window?.makeFirstResponder(restore) }
                self?.reviewPopover = nil
            }
        }
    }

    /// What's in the box itself: its binding can be a few keys behind what's been typed.
    private static func typedText(in popover: NSPopover) -> String? {
        func textView(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            return view as? NSTextView ?? view.subviews.lazy.compactMap(textView(in:)).first
        }
        let typed = textView(in: popover.contentViewController?.view)?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed?.isEmpty == false ? typed : nil
    }

    func addReviewComment(_ comment: ReviewComment, in workspaceID: WorkspaceID? = nil) {
        update(workspace: workspaceID ?? activeID) { $0.review.append(comment) }
        SidebarSection.review.open()
        scheduleSave()
        reviewDidChange()
    }

    func updateReviewComment(_ id: String, text: String) {
        updateActive { workspace in
            guard let index = workspace.review.firstIndex(where: { $0.id == id }) else { return }
            workspace.review[index].text = text
        }
        scheduleSave()
        reviewDidChange()
    }

    func removeReviewComment(_ id: String) {
        updateActive { $0.review.removeAll { $0.id == id } }
        scheduleSave()
        reviewDidChange()
    }

    func discardReview() {
        let old = active.review
        guard !old.isEmpty else { return }
        updateActive { $0.review = [] }
        scheduleSave()
        reviewDidChange()
        showToast(title: Self.commentCount(old.count) + " discarded", detail: nil, symbol: "trash", tint: .secondary, actionTitle: "Undo") { [weak self] in
            self?.restoreReview(old)
        }
    }

    private func restoreReview(_ comments: [ReviewComment]) {
        updateActive { $0.review = comments + $0.review }
        scheduleSave()
        reviewDidChange()
    }

    static func commentCount(_ count: Int) -> String { count == 1 ? "1 comment" : "\(count) comments" }

    /// With one agent running they go straight there. With several, you choose.
    func sendReview() {
        guard !active.review.isEmpty else {
            showToast(title: "There are no comments to send", detail: "Select something in a file or a diff, then press ⌥⌘L.", symbol: "text.bubble", tint: .secondary)
            return
        }
        withAgent(asking: "Which session should get \(Self.commentCount(active.review.count))?") { [weak self] terminal, _ in
            self?.deliverReview(to: terminal)
        }
    }

    @discardableResult
    func sendReview(to item: ItemID) -> Bool {
        guard let session = activeAgentSessions().first(where: { $0.item.id == item }) else { return false }
        deliverReview(to: session.terminal)
        return true
    }

    /// Into the input, unsent, the same as a quote: there may be something to add before pressing Return.
    private func deliverReview(to terminal: TerminalController) {
        let comments = active.review
        guard !comments.isEmpty else { return }
        // A terminal reports real paths, and the workspace may know a folder by a link to it.
        let real = comments.map { comment in
            var comment = comment
            comment.path = Git.real(comment.path)
            return comment
        }
        let message = ReviewMessage.text(comments: real, cwd: Git.real(terminal.currentDirectory))
        focusAgent(terminal)
        terminal.send(text: AgentReference.bracketedPaste(message))
        updateActive { $0.review = [] }
        scheduleSave()
        reviewDidChange()
        showToast(title: Self.commentCount(comments.count) + " sent", detail: "Press Return in the session when you're ready.",
                  symbol: "paperplane", tint: .accentColor, actionTitle: "Bring Back") { [weak self] in
            self?.restoreReview(comments)
        }
    }

    /// An agent moved some lines: the list says where they are now.
    func refreshReviewLines(in id: WorkspaceID? = nil) {
        let workspace = id ?? activeID
        let comments = (workspaces.first { $0.id == workspace }?.review ?? []).filter { $0.excerpt != nil }
        guard !comments.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var moved: [String: ClosedRange<Int>] = [:]
            for comment in comments {
                guard let text = try? String(contentsOfFile: comment.path, encoding: .utf8),
                      case .lines(let range) = ReviewLocator.place(of: comment, in: text),
                      range.lowerBound != comment.firstLine else { continue }
                moved[comment.id] = range
            }
            guard !moved.isEmpty else { return }
            await MainActor.run {
                self?.update(workspace: workspace) { workspace in
                    for index in workspace.review.indices {
                        guard let range = moved[workspace.review[index].id] else { continue }
                        workspace.review[index].firstLine = range.lowerBound
                        workspace.review[index].lastLine = range.upperBound
                    }
                }
                self?.scheduleSave()
            }
        }
    }

    /// Every open viewer of a file with comments redraws its markers.
    private func reviewDidChange() {
        for workspace in workspaces {
            for item in workspace.items + (workspace.peek.map { [$0] } ?? []) {
                existingController(for: item.id)?.reviewChanged()
            }
        }
    }

    func reviewMarkers(for path: String, text: String) -> [Int: [ReviewComment]] {
        var markers: [Int: [ReviewComment]] = [:]
        for comment in reviewComments(on: path) {
            if case .lines(let range) = ReviewLocator.place(of: comment, in: text) {
                markers[range.lowerBound, default: []].append(comment)
            }
        }
        return markers
    }

    /// A diff's rows are found by their line in the file, or for removed rows, by their own text.
    /// A comment on one commit's diff stays there, since another's line 12 is a different line.
    func reviewMarkers(for path: String, rows: [DiffLine], commit: String?) -> [Int: [ReviewComment]] {
        var markers: [Int: [ReviewComment]] = [:]
        for comment in reviewComments(on: path) where comment.commit == commit {
            let row: Int?
            if let first = comment.firstLine {
                row = rows.firstIndex { $0.newLine == first }
            } else if comment.quoteIsDiff, let quote = comment.quote, let line = quote.split(separator: "\n").first {
                let text = line.dropFirst()
                row = rows.firstIndex { $0.kind == .removed && $0.text == text }
            } else {
                row = nil
            }
            if let row { markers[row, default: []].append(comment) }
        }
        return markers
    }

    /// Comments can be in another workspace's list only if that file is open there too.
    private func reviewComments(on path: String) -> [ReviewComment] {
        workspaces.flatMap { $0.reviewComments(on: path) }
    }

    func openReviewComment(_ comment: ReviewComment) {
        let line = (try? String(contentsOfFile: comment.path, encoding: .utf8)).flatMap { text -> Int? in
            if case .lines(let range) = ReviewLocator.place(of: comment, in: text) { return range.lowerBound }
            return nil
        }
        if let commit = comment.commit {
            peekDiff(DiffSpec(path: comment.path, commit: commit), takeFocus: true)
            return
        }
        if comment.quoteIsDiff, hasChanges(comment.path) {
            peekDiff(DiffSpec(path: comment.path), takeFocus: true)
            return
        }
        open(path: comment.path, line: line, intent: .peek(takeFocus: true))
    }
}

/// The small mark beside a commented line.
enum ReviewMarker {
    @discardableResult
    static func draw(atY y: CGFloat, lineHeight: CGFloat) -> NSRect {
        let size: CGFloat = 11
        let rect = NSRect(x: 2, y: y + (lineHeight - size) / 2, width: size, height: size)
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
        NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Comment")?
            .withSymbolConfiguration(configuration)?
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return rect
    }
}

/// Lines of a file, for what a comment is on.
enum ReviewQuote {
    nonisolated static func lines(_ first: Int, _ last: Int, of path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let all = text.components(separatedBy: "\n")
        guard first >= 1, first <= all.count else { return nil }
        return all[(first - 1)..<min(max(last, first), all.count)].joined(separator: "\n")
    }

    /// A quotation made for ⌘L says where it's from in its first line. A comment's list says that already.
    nonisolated static func body(_ quote: String) -> String {
        quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Writing one

struct ReviewCommentEditor: View {
    let title: String
    @State var text: String
    let isEditing: Bool
    let commit: (String) -> Void
    let delete: (() -> Void)?
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(width: 320, height: 76)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            HStack(spacing: 8) {
                if let delete {
                    Button("Delete", role: .destructive, action: delete)
                }
                Spacer()
                Text("⇧↩ for a new line")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Button(isEditing ? "Save" : "Add Comment") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func finish() {
        guard !trimmed.isEmpty else { return }
        commit(trimmed)
    }
}

// MARK: - The sidebar section

struct ReviewHeaderActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        Text("\(here.active.review.count)")
            .foregroundStyle(.tertiary)
            .font(.caption)
        Button {
            model.sendReview()
        } label: {
            Image(systemName: "paperplane")
        }
        .help("Send to Agent (\(model.shortcutSymbol(for: "sendReview") ?? "⌥⇧⌘L"))")
        .accessibilityLabel("Send Comments to Agent")
        Menu {
            Button("Discard All Comments") { model.discardReview() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

struct ReviewList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(here.active.review) { comment in
                    ReviewRow(comment: comment)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

struct ReviewRow: View {
    let comment: ReviewComment
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var location: String {
        let name = (comment.path as NSString).lastPathComponent
        guard let first = comment.firstLine else { return name }
        return "\(name):\(first)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(comment.summary)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(location)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    model.removeReviewComment(comment.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete Comment")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openReviewComment(comment) }
        .help(comment.text)
        .contextMenu {
            Button("Go to Comment") { model.openReviewComment(comment) }
            Button("Delete Comment") { model.removeReviewComment(comment.id) }
        }
    }
}
