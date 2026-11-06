import Foundation

/// A file of Tiri's that's there and can't be read. Its bytes are moved aside, beside it, before
/// anything new is written in its place, and the app is told once, so nothing is lost without a word.
public enum PluginDamagedFiles {
    public struct Notice: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A plugin's settings, now back to their defaults.
            case settings(plugin: String)
            /// Which plugins were approved. Those it couldn't read are off.
            case approvals
        }

        public var kind: Kind
        /// Where its bytes are now. Nil if they couldn't be moved, and so nothing is written over them.
        public var keptAt: String?
    }

    public enum Reading<Value> {
        case missing
        case read(Value)
        case damaged
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [Notice] = []
    nonisolated(unsafe) private static var listener: (@Sendable (Notice) -> Void)?

    /// The app's, from launch. Notices from before then are handed over at once.
    public static func listen(_ handler: @escaping @Sendable (Notice) -> Void) {
        let earlier = lock.withLock {
            listener = handler
            defer { waiting = [] }
            return waiting
        }
        for notice in earlier { handler(notice) }
    }

    static func report(_ notice: Notice) {
        let handler = lock.withLock { () -> (@Sendable (Notice) -> Void)? in
            if listener == nil { waiting.append(notice) }
            return listener
        }
        handler?(notice)
    }

    /// Missing is nothing to say, and a file that's there but won't decode is damaged.
    static func read<Value>(_ url: URL, decode: (Data) -> Value?) -> Reading<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let value = decode(data) else { return .damaged }
        return .read(value)
    }

    /// `name.damaged`, or with the time after it if an older one is already there. Nil if it couldn't be moved.
    static func moveAside(_ url: URL) -> URL? {
        var target = URL(fileURLWithPath: url.path + ".damaged")
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            target = URL(fileURLWithPath: url.path + ".damaged-" + stamp)
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
