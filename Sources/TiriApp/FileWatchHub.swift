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
        var recursive: Bool
        var handler: () -> Void
    }

    private var stream: FSEventStreamRef?
    private var currentRoots: [String] = []
    private var workspaceRoots: [String] = []
    private var subscriptions: [UUID: Subscription] = [:]
    private var pendingPaths: Set<String> = []
    private var flushScheduled = false
    private var rootsDirty = false

    /// Paths that changed, for the tree and quick-open index. Excluded names are filtered out.
    var onChanges: (([String]) -> Void)?
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
        // A file may not exist yet, so resolve its folder.
        let realPath = recursive ? Self.real(path)
            : (Self.real((path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        subscriptions[token.id] = Subscription(path: realPath, recursive: recursive, handler: handler)
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
            wanted.append(subscription.recursive ? subscription.path : (subscription.path as NSString).deletingLastPathComponent)
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
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let hub = Unmanaged<FileWatchHub>.fromOpaque(info).takeUnretainedValue()
            _ = count
            MainActor.assumeIsolated { hub.received(list) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
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

    private func received(_ paths: [String]) {
        pendingPaths.formUnion(paths)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Agents write in bursts. Settle a little so a viewer reloads once, not ten times.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            flushScheduled = false
            let batch = pendingPaths
            pendingPaths.removeAll()
            deliver(batch)
        }
    }

    private func deliver(_ paths: Set<String>) {
        for subscription in subscriptions.values {
            let hit = paths.contains { path in
                path == subscription.path || (subscription.recursive && path.hasPrefix(subscription.path + "/"))
            }
            if hit { subscription.handler() }
        }
        let relevant = paths.filter { path in
            !path.split(separator: "/").contains { excludedNames.contains(String($0)) }
        }
        guard !relevant.isEmpty else { return }
        onChanges?(relevant.map { path in
            for (real, alias) in rootAliases where real != alias && (path == real || path.hasPrefix(real + "/")) {
                return alias + path.dropFirst(real.count)
            }
            return path
        })
    }
}
