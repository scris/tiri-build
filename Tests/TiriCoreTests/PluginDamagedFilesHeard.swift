import Foundation
@testable import TiriCore

/// What `PluginDamagedFiles` said, from whatever thread it said it on.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [PluginDamagedFiles.Notice] = []

    func add(_ notice: PluginDamagedFiles.Notice) { lock.withLock { said.append(notice) } }
    var notices: [PluginDamagedFiles.Notice] { lock.withLock { said } }
}
