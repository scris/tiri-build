import AppKit
import SwiftUI
import TiriCore

// MARK: - In the toolbar

/// ▶ Start, in the window's toolbar: the workspace's list as a menu. A green dot says something in it is running.
struct StartToolbarButton: View {
    let workspace: WorkspaceID
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.starter.isRunning(in: workspace)
        Button { StartMenu.popUp(model: model, workspace: workspace) } label: {
            Label {
                Text("Start")
            } icon: {
                Image(systemName: "play")
                    .overlay(alignment: .topTrailing) {
                        if running {
                            Circle().fill(.green).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .help(running ? String(localized: "What's running, and what else to start (⌃⌥S)") : String(localized: "Start a dev server or script (⌃⌥S)"))
        .accessibilityLabel(running ? String(localized: "Start, something running") : String(localized: "Start"))
        .onAppear { model.starter.adoptAll(in: workspace) }
    }
}

/// The list: each start with its state, then ways to add to it. A menu, as the + beside it is.
@MainActor
enum StartMenu {
    private final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func popUp(model: AppModel, workspace: WorkspaceID) {
        let starter = model.starter
        let menu = NSMenu()
        menu.autoenablesItems = false
        var handlers: [Handler] = []
        func item(_ title: String, symbol: String? = nil, tint: NSColor? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
            let handler = Handler(run)
            handlers.append(handler)
            let item = NSMenuItem(title: title, action: #selector(Handler.fire), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let configured = image.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                if let tint, let colored = configured?.withSymbolConfiguration(.init(paletteColors: [tint])) { item.image = colored } else { item.image = configured }
            }
            return item
        }
        func folderNote(_ entry: StartEntry) -> String {
            let space = model.workspaces.first { $0.id == workspace }
            let root = space?.folder(containing: entry.folder)
            // Only where it says something: in a subfolder, or with several folders.
            if root == entry.folder, (space?.folders.count ?? 0) <= 1 { return entry.command }
            return "\(entry.command)  ·  \((entry.folder as NSString).lastPathComponent)"
        }

        let starts = starter.entries(in: workspace)
        for entry in starts {
            if let server = starter.server(entry.id, in: workspace) {
                let state = server.port.map { "localhost:\($0)" } ?? (server.phase == .stopping ? String(localized: "Stopping") : String(localized: "Starting"))
                let parent = NSMenuItem(title: "\(entry.name)    \(state)", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [server.phase == .running ? .systemGreen : .systemOrange])))
                let sub = NSMenu()
                sub.autoenablesItems = false
                for port in server.ports.isEmpty ? [server.port].compactMap({ $0 }) : server.ports {
                    sub.addItem(item(String(localized: "Open localhost:\(port)"), symbol: "safari") { starter.openPage(entry.id, in: workspace, port: port, focus: true) })
                }
                sub.addItem(item(String(localized: "Show Output"), symbol: "terminal") { starter.showOutput(entry.id, in: workspace) })
                sub.addItem(.separator())
                sub.addItem(item(String(localized: "Restart"), symbol: "arrow.clockwise") { starter.restart(entry.id, in: workspace) })
                sub.addItem(item(String(localized: "Stop"), symbol: "stop.fill") { starter.stop(entry.id, in: workspace) })
                parent.submenu = sub
                menu.addItem(parent)
            } else {
                let start = item(entry.name, symbol: "play.fill") { starter.press(entry.id, in: workspace) }
                start.toolTip = folderNote(entry)
                if #available(macOS 14.4, *) { start.subtitle = folderNote(entry) }
                menu.addItem(start)
            }
        }

        // With nothing in the list yet, what the folders suggest is right here: one click adds it and starts it.
        if starts.isEmpty {
            let found = starter.suggestions(for: workspace)
            if found.isEmpty {
                let none = NSMenuItem(title: String(localized: "Nothing to start here yet"), action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            } else {
                if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: String(localized: "Suggested"))) }
                for guess in found.prefix(8) {
                    let add = item(guess.name, symbol: "plus") { starter.addAndStart(guess, in: workspace) }
                    if #available(macOS 14.4, *) { add.subtitle = guess.command }
                    add.toolTip = String(localized: "\(guess.command), from \(guess.source)")
                    menu.addItem(add)
                }
            }
        }

        menu.addItem(.separator())
        if starts.count > 1, starter.isRunning(in: workspace) {
            menu.addItem(item(String(localized: "Stop All"), symbol: "stop") { starter.stopAll(in: workspace) })
        }
        menu.addItem(item(starts.isEmpty ? String(localized: "Add a Start…") : String(localized: "Edit Starts…"), symbol: "slider.horizontal.3") {
            starter.editing = workspace
        })
        if let agent = model.runnableAgentPresets().first {
            menu.addItem(item(String(localized: "Ask \(agent.name) to Set Up…"), symbol: "sparkles") { starter.askAgentToSetUp(workspace) })
        }

        // Under the button that was pressed, the way a toolbar menu opens.
        guard let event = NSApp.currentEvent, let window = event.window, let content = window.contentView else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let point = content.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: point.x - 12, y: point.y - 22), in: content)
        _ = handlers
    }
}

// MARK: - Editing the list

/// A workspace's starts, to rename, change, reorder or remove, with what its folders suggest below to add in one click.
struct StartListSheet: View {
    let workspace: WorkspaceID
    @Environment(AppModel.self) private var model

    private var starter: FolderStarter { model.starter }
    private var space: Workspace? { model.workspaces.first { $0.id == workspace } }

    var body: some View {
        let starts = starter.entries(in: workspace)
        let found = starter.suggestions(for: workspace)
        VStack(alignment: .leading, spacing: 14) {
            Text("Start in \(space?.name ?? "")").font(.headline)
            if starts.isEmpty {
                Text("Nothing yet. Add a suggestion, your own command, or ask your agent.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(starts.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 10) }
                        StartEntryRow(entry: entry, workspace: workspace)
                    }
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 9))
            }
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(found) { guess in StartSuggestionRow(guess: guess, workspace: workspace) }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            HStack {
                Button {
                    let folder = space?.folders.first ?? NSHomeDirectory()
                    starter.add(StartEntry(name: String(localized: "New start"), command: "", folder: folder), to: workspace)
                } label: { Label("Add Your Own", systemImage: "plus") }
                if let agent = model.runnableAgentPresets().first {
                    Button { starter.askAgentToSetUp(workspace) } label: { Label("Ask \(agent.name) to Set Up", systemImage: "sparkles") }
                }
                Spacer()
                Button("Done") { starter.editing = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

private struct StartEntryRow: View {
    let entry: StartEntry
    let workspace: WorkspaceID
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var command = ""
    @FocusState private var editingName: Bool
    @FocusState private var editingCommand: Bool

    private var starter: FolderStarter { model.starter }
    private var server: FolderStarter.Server? { starter.server(entry.id, in: workspace) }
    private var folders: [String] {
        guard let space = model.workspaces.first(where: { $0.id == workspace }) else { return [] }
        var all: [String] = []
        for folder in space.folders {
            all.append(folder)
            all += StartFolders.listSubfolders(folder).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if !all.contains(entry.folder) { all.insert(entry.folder, at: 0) }
        return all
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server == nil ? Color.clear : server?.phase == .running ? Color.green : Color.orange)
                .overlay { Circle().strokeBorder(Color.secondary.opacity(server == nil ? 0.4 : 0), lineWidth: 1) }
                .frame(width: 7, height: 7)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .focused($editingName)
                .frame(width: 120)
                .onAppear { name = entry.name }
                .onChange(of: editingName) { _, now in if !now { save() } }
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Command, like npm run dev", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($editingCommand)
                    .onAppear { command = entry.command }
                    .onChange(of: editingCommand) { _, now in if !now { save() } }
                    .onSubmit(save)
                Menu {
                    ForEach(folders, id: \.self) { folder in
                        Button(relative(folder)) {
                            var changed = entry
                            changed.folder = folder
                            starter.update(changed, in: workspace)
                        }
                    }
                } label: {
                    Label(relative(entry.folder), systemImage: "folder").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Where it runs")
            }
            Spacer(minLength: 4)
            if let server {
                if server.port != nil {
                    Button { starter.openPage(entry.id, in: workspace, focus: true) } label: {
                        Text(verbatim: "localhost:\(server.port ?? 0)").font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                iconButton("stop.fill", String(localized: "Stop")) { starter.stop(entry.id, in: workspace) }
            } else {
                iconButton("play.fill", String(localized: "Start")) { save(); starter.press(entry.id, in: workspace) }
                    .disabled(entry.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            iconButton("minus.circle", String(localized: "Remove \(entry.name)")) { starter.remove(entry.id, from: workspace) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Within the workspace: `PTTS-Frontend`, or the folder's own name.
    private func relative(_ folder: String) -> String {
        guard let root = model.workspaces.first(where: { $0.id == workspace })?.folder(containing: folder) else { return (folder as NSString).lastPathComponent }
        if root == folder { return (folder as NSString).lastPathComponent }
        return (root as NSString).lastPathComponent + "/" + String(folder.dropFirst(root.count + 1))
    }

    private func save() {
        var changed = entry
        changed.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? entry.name : name.trimmingCharacters(in: .whitespaces)
        changed.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if changed != entry { starter.update(changed, in: workspace) }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StartSuggestionRow: View {
    let guess: StartGuess
    let workspace: WorkspaceID
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var where_: String {
        guard let root = model.workspaces.first(where: { $0.id == workspace })?.folder(containing: guess.folder) else {
            return (guess.folder as NSString).lastPathComponent
        }
        if root == guess.folder { return (root as NSString).lastPathComponent }
        return (root as NSString).lastPathComponent + "/" + String(guess.folder.dropFirst(root.count + 1))
    }

    var body: some View {
        Button {
            model.starter.add(guess.entry, to: workspace)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "plus.circle").foregroundStyle(hovering ? Color.accentColor : .secondary)
                Text(verbatim: guess.name).frame(width: 120, alignment: .leading).lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: guess.command).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    // Where it runs, and where it came from when the command doesn't already say.
                    HStack(spacing: 6) {
                        Label(where_, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                        if guess.source != guess.command {
                            Text(verbatim: guess.source).font(.caption).foregroundStyle(.secondary)
                        }
                        if let detail = guess.detail {
                            Text(verbatim: detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add it to the list")
    }
}

// MARK: - Settings → Run

/// Starts belong to each workspace, so Settings only says where they are, and opens this one's.
struct StartCommandsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(String(localized: "Start")) {
            HStack(spacing: 10) {
                Image(systemName: "play").foregroundStyle(.secondary)
                Text("Each workspace keeps its own list of dev servers and scripts, in Start at the top right of the window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Edit This Workspace's…") { model.starter.editing = model.activeID }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }
}
