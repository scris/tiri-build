import AppKit
import TiriCore

/// App-wide key and mouse handling. Runs before the first responder, so bindings work the
/// same over a terminal, a web view or the tree, and keybindings.json can change them live.
final class EventRouter {
    private weak var model: AppModel?
    private var monitors: [Any] = []
    private var chordTimeout: DispatchWorkItem?
    private var lastCommand: (id: String, time: Double)?
    private var lastHandledKeyTimestamp: TimeInterval = -1
    private var waitingToRun: String?

    func ranRecently(_ id: String) -> Bool {
        guard let lastCommand, lastCommand.id == id else { return false }
        return ProcessClock.now() - lastCommand.time < 600
    }

    func install(model: AppModel) {
        self.model = model
        // Nil means handled, and the event goes no further. It has to stay nil on the way out.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseDown(event)
        } as Any)
        // A SwiftUI drag gesture can be cancelled without calling onEnded. The mouse going up
        // is what really ends a tab drag, so a drop can't be lost and a ghost can't get stuck.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if self?.model?.tabDrag != nil { self?.model?.endTabDrag() }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            self?.model?.terminalHoverEvent(event)
            self?.model?.codeHoverEvent(event)
            return event
        } as Any)
    }

    static func stroke(from event: NSEvent) -> KeyStroke? {
        var modifiers: KeyStroke.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let named: [UInt16: String] = [
            48: "tab", 36: "enter", 76: "enter", 53: "escape", 51: "backspace", 117: "delete", 49: "space",
            123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
            109: "f10", 103: "f11", 111: "f12",
        ]
        if let name = named[event.keyCode] {
            return KeyStroke(modifiers: modifiers, key: name)
        }
        // The key's base character, so ⇧] matches "shift+]" rather than "}".
        guard let base = event.charactersIgnoringModifiers?.lowercased(), !base.isEmpty else { return nil }
        let plain = event.characters(byApplyingModifiers: [])?.lowercased()
        return KeyStroke(modifiers: modifiers, key: plain?.isEmpty == false ? plain! : base)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // While a shortcut is being recorded, every key press is the shortcut.
        if let model, model.recordingShortcutFor != nil {
            if let stroke = Self.stroke(from: event) { model.recordKey(stroke) }
            return nil
        }
        // A tab in its own window keeps its keyboard. Only closing and saving mean something different there.
        if let model, let window = event.window, let item = model.detachedItem(of: window), let stroke = Self.stroke(from: event) {
            if stroke.modifiers == .command, stroke.key == "w" {
                model.bringBack(item)
                return nil
            }
            if stroke.modifiers == .command, stroke.key == "s" {
                model.saveItem(item)
                return nil
            }
            if let terminal = window.firstResponder as? TiriTerminalView {
                terminal.owner?.noteKeyPress(isReturn: stroke.key == "enter")
            }
            // The keys that mean something to what has the keyboard work the same over there.
            if model.runOnFocusedItem(stroke: stroke, in: window) { return nil }
            return event
        }
        guard let model, event.window === model.window, NSApp.modalWindow == nil, event.window?.attachedSheet == nil,
              let stroke = Self.stroke(from: event) else { return event }
        // With a web view focused, WebKit sends one key press through the app several times.
        // A press we've already acted on is simply swallowed.
        if event.timestamp == lastHandledKeyTimestamp { return nil }

        // Escape belongs to the Peek when the keyboard is in it. Never otherwise:
        // in a terminal it would interrupt the agent.
        if stroke.key == "escape", stroke.modifiers.isEmpty {
            if model.handleEscape() {
                lastHandledKeyTimestamp = event.timestamp
                return nil
            }
            return event
        }

        // The palette's field takes a moment to get the keyboard. What's typed until then is for it,
        // not for the terminal or the file underneath.
        if let palette = model.palette, stroke.modifiers.subtracting(.shift).isEmpty,
           (event.window?.firstResponder as? NSTextView)?.isFieldEditor != true {
            switch stroke.key {
            case "enter": palette.submit()
            case "down": palette.move(1)
            case "up": palette.move(-1)
            case "tab", "backspace", "delete": break
            default: palette.query += event.characters ?? ""
            }
            return nil
        }

        switch model.keyResolver.handle(stroke) {
        case .passThrough:
            if let terminal = event.window?.firstResponder as? TiriTerminalView {
                terminal.owner?.noteKeyPress(isReturn: stroke.key == "enter")
            }
            return event
        case .pending:
            // ⌘K in a terminal does something by itself, if no second press comes along.
            if let alone = model.keyResolver.commandsSoFar.first(where: model.isCommandEnabledForKey) {
                waitingToRun = alone
                scheduleChordTimeout(after: 0.3, thenRun: alone)
            } else {
                scheduleChordTimeout()
            }
            return nil
        case .cancelledChord:
            chordTimeout?.cancel()
            if let alone = waitingToRun {
                waitingToRun = nil
                model.run(alone)
                return event
            }
            return nil
        case .command(let first, let otherwise):
            chordTimeout?.cancel()
            waitingToRun = nil
            guard let command = ([first] + otherwise).first(where: model.isCommandEnabledForKey) else { return event }
            lastCommand = (command, ProcessClock.now())
            lastHandledKeyTimestamp = event.timestamp
            model.run(command)
            return nil
        }
    }

    private func scheduleChordTimeout(after delay: TimeInterval = 2.5, thenRun command: String? = nil) {
        chordTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model?.keyResolver.reset()
            self?.waitingToRun = nil
            if let command { self?.model?.run(command) }
        }
        chordTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let model, event.window === model.window else { return event }
        if event.type == .otherMouseDown {
            if event.buttonNumber == 2, let item = model.layoutRegistry.tab(at: model.globalPoint(event)) {
                model.requestClose(item)
                return nil
            }
            return event
        }
        model.handleLeftMouseDown(event)
        if model.codeCommandClick(event) { return nil }
        return event
    }
}

/// Screen geometry of tabs and panes, written by the views and read by mouse handling.
/// Deliberately not observed: a resize shouldn't re-render anything.
final class LayoutRegistry {
    private(set) var tabFrames: [ItemID: CGRect] = [:]
    private(set) var barFrames: [GroupID: CGRect] = [:]
    private(set) var contentFrames: [GroupID: CGRect] = [:]
    var peekFrame: CGRect?
    var paletteFrame: CGRect?

    // When SwiftUI rebuilds a pane, the new view registers before the old one's onDisappear
    // runs. Entries remember who wrote them, so the old view can't erase the new one's.
    private var tabOwners: [ItemID: UUID] = [:]
    private var groupOwners: [GroupID: UUID] = [:]

    func setTab(_ id: ItemID, frame: CGRect, owner: UUID) {
        tabFrames[id] = frame
        tabOwners[id] = owner
    }

    func removeTab(_ id: ItemID, owner: UUID) {
        guard tabOwners[id] == owner else { return }
        tabFrames[id] = nil
        tabOwners[id] = nil
    }

    func setGroup(_ id: GroupID, bar: CGRect?, content: CGRect, owner: UUID) {
        barFrames[id] = bar
        contentFrames[id] = content
        groupOwners[id] = owner
    }

    func removeGroup(_ id: GroupID, owner: UUID) {
        guard groupOwners[id] == owner else { return }
        barFrames[id] = nil
        contentFrames[id] = nil
        groupOwners[id] = nil
    }

    func tab(at point: CGPoint) -> ItemID? {
        tabFrames.first { $0.value.contains(point) }?.key
    }

    func group(at point: CGPoint) -> GroupID? {
        if let hit = contentFrames.first(where: { $0.value.contains(point) }) { return hit.key }
        return barFrames.first { $0.value.contains(point) }?.key
    }

    /// Where a dragged tab would land, using VS Code's zones: the outer tenth of a pane
    /// splits it, the rest adds to the group.
    func dropTarget(at point: CGPoint, validGroups: Set<GroupID>, tabsIn group: (GroupID) -> [ItemID]) -> TabDropTarget? {
        if let bar = barFrames.first(where: { validGroups.contains($0.key) && $0.value.contains(point) }) {
            let tabs = group(bar.key)
            var index = tabs.count
            for (offset, id) in tabs.enumerated() {
                if let frame = tabFrames[id], point.x < frame.midX {
                    index = offset
                    break
                }
            }
            return .tabBar(group: bar.key, index: index)
        }
        guard let content = contentFrames.first(where: { validGroups.contains($0.key) && $0.value.contains(point) }) else { return nil }
        let frame = content.value
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        let band: CGFloat = 0.1
        guard x < band || x > 1 - band || y < band || y > 1 - band else {
            return .center(group: content.key)
        }
        let direction: SplitDirection = x < 1.0 / 3 ? .left : x > 2.0 / 3 ? .right : (y < 0.5 ? .up : .down)
        return .edge(group: content.key, direction: direction)
    }
}

enum TabDropTarget: Equatable {
    case tabBar(group: GroupID, index: Int)
    case center(group: GroupID)
    case edge(group: GroupID, direction: SplitDirection)

    var group: GroupID {
        switch self {
        case .tabBar(let group, _), .center(let group), .edge(let group, _): group
        }
    }
}

struct TabDragState: Equatable {
    var item: ItemID
    var title: String
    var location: CGPoint
    var target: TabDropTarget?
}
