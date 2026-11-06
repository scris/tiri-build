import CoreServices
import Foundation
import TiriCore

/// One FSEvents stream for everything Tiri watches: workspace folders, plus the parent
/// folder of any open file that lives elsewhere. Subscribers hear about coalesced changes.
final class FileWatchHub {
    static let shared = FileWatchHub()

    final class Token {
        fileprivate let id = UUID()
        deinit {
            let id = id
            DispatchQueue.main.async { FileWatchHub.shared.remove(id) }
        }
    }

    private struct Subscription {
        var path: String
        /// For a file reached through a symlink (CLAUDE.md → AGENTS.md), where it really is: FSEvents names the
        /// target when it changes, never the link.
        var target: String?
        var recursive: Bool
        var handler: () -> Void

        var paths: [String] { target.map { [path, $0] } ?? [path] }
    }

    private var stream: FSEventStreamRef?
    private var currentRoots: [String] = []
    private var workspaceRoots: [String] = []
    private var subscriptions: [UUID: Subscription] = [:]
    private var pendingPaths: Set<String> = []
    /// Folders FSEvents lost track of, whose every file has to be looked at again.
    private var pendingRescans: Set<String> = []
    private var flushScheduled = false
    private var rootsDirty = false

    /// Paths that changed, for the tree and quick-open index. Excluded names are filtered out.
    var onChanges: (([String]) -> Void)?
    /// Folders to read again from scratch: FSEvents dropped events under them, or a root moved.
    var onRescan: (([String]) -> Void)?
    var excludedNames: Set<String> = []

    /// FSEvents reports real paths, and what Tiri holds may go through a symlink (`/tmp`,
    /// a linked project folder). Everything is compared in real paths.
    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Real root → the path the workspace knows it by, to translate events back.
    private var rootAliases: [String: String] = [:]

    func setWorkspaceRoots(_ roots: [String]) {
        var aliases: [String: String] = [:]
        for root in roots { aliases[Self.real(root)] = root }
        let realRoots = roots.map(Self.real)
        guard realRoots != workspaceRoots else { return }
        workspaceRoots = realRoots
        rootAliases = aliases
        scheduleRebuild()
    }

    /// Be told when a file (or, if recursive, anything under a folder) changes.
    func watch(path: String, recursive: Bool = false, handler: @escaping () -> Void) -> Token {
        let token = Token()
        // A file may not exist yet, so resolve its folder, and spell its name as the disk does, as events will.
        let folder = Self.real((path as NSString).deletingLastPathComponent)
        let realPath = recursive ? Self.real(path)
            : PathCase.onDisk((folder as NSString).appendingPathComponent((path as NSString).lastPathComponent), below: folder)
        let resolved = recursive ? realPath : Self.real(realPath)
        subscriptions[token.id] = Subscription(path: realPath, target: resolved == realPath ? nil : resolved,
                                               recursive: recursive, handler: handler)
        scheduleRebuild()
        return token
    }

    fileprivate func remove(_ id: UUID) {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        scheduleRebuild()
    }

    private func scheduleRebuild() {
        guard !rootsDirty else { return }
        rootsDirty = true
        DispatchQueue.main.async { [self] in
            rootsDirty = false
            rebuildStream()
        }
    }

    private func rebuildStream() {
        var wanted = workspaceRoots
        for subscription in subscriptions.values {
            for path in subscription.paths {
                wanted.append(subscription.recursive ? path : (path as NSString).deletingLastPathComponent)
            }
        }
        // Keep only the topmost folders, since FSEvents covers subtrees.
        let sorted = Set(wanted).sorted()
        var roots: [String] = []
        for path in sorted where !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            roots.append(path)
        }
        guard roots != currentRoots else { return }
        stopStream()
        currentRoots = roots
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let hub = Unmanaged<FileWatchHub>.fromOpaque(info).takeUnretainedValue()
            let flags = (0..<min(count, list.count)).map { eventFlags[$0] }
            MainActor.assumeIsolated { hub.received(list, flags: flags) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// What FSEvents says when it couldn't keep up, as Zed's `need_rescan` reads it.
    private static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    private func received(_ paths: [String], flags: [FSEventStreamEventFlags] = []) {
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & Self.rescanFlags != 0 { pendingRescans.insert(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path) }
            // A root that moved or was deleted: the stream has to be made again for where it is now.
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { scheduleRebuildAfterRootChange() }
        }
        pendingPaths.formUnion(paths)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Agents write in bursts. Settle a little so a viewer reloads once, not ten times.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            flushScheduled = false
            let batch = pendingPaths
            let rescans = pendingRescans
            pendingPaths.removeAll()
            pendingRescans.removeAll()
            deliver(batch, rescanning: rescans)
        }
    }

    /// A root that was moved or replaced gets watched again where it now is.
    private func scheduleRebuildAfterRootChange() {
        currentRoots = []
        scheduleRebuild()
    }

    private func deliver(_ paths: Set<String>, rescanning rescans: Set<String> = []) {
        for subscription in subscriptions.values {
            let hit = subscription.paths.contains { watched in
                paths.contains { path in
                    path == watched || (subscription.recursive && path.hasPrefix(watched + "/"))
                } || rescans.contains { folder in
                    // Anything under a folder that has to be scanned again may have changed, and so may a folder
                    // watched whole that has such a folder in it.
                    folder == "/" || watched == folder || watched.hasPrefix(folder + "/")
                        || (subscription.recursive && folder.hasPrefix(watched + "/"))
                }
            }
            if hit { subscription.handler() }
        }
        let rescanned = rescans.filter { path in
            !path.split(separator: "/").contains { excludedNames.contains(String($0)) }
        }
        if !rescanned.isEmpty { onRescan?(rescanned.map(alias)) }
        let relevant = paths.filter { path in
            !path.split(separator: "/").contains { excludedNames.contains(String($0)) }
        }
        guard !relevant.isEmpty else { return }
        onChanges?(relevant.map(alias))
    }

    /// A real path as the workspace knows it.
    private func alias(_ path: String) -> String {
        for (real, alias) in rootAliases where real != alias && (path == real || path.hasPrefix(real + "/")) {
            return alias + path.dropFirst(real.count)
        }
        return path
    }
}
