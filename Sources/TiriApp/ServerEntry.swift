import AppKit
import Darwin
import SwiftUI
import TiriCore

/// Ways into Connect to Server beyond the + menu, shown only to people who work on servers.
@MainActor
enum ServerEntry {
    private static var checked: (at: Date, answer: Bool)?

    /// Someone who's connected from Tiri before, or has servers in their SSH files. Read again at most
    /// every half minute: it's asked whenever an empty tab draws.
    static func usesServers(_ remote: RemoteManager) -> Bool {
        if let checked, Date().timeIntervalSince(checked.at) < 30 { return checked.answer }
        let answer = !remote.recents().hosts.isEmpty || SSHConfigFile.usesServers()
        checked = (Date(), answer)
        return answer
    }

    /// Asked once a launch per server, and never again once the answer's no.
    static var offeredThisLaunch: Set<String> = []

    static func declined(_ destination: String) -> Bool {
        UserDefaults.standard.bool(forKey: "serverOffer.declined.\(destination)")
    }

    static func decline(_ destination: String) {
        UserDefaults.standard.set(true, forKey: "serverOffer.declined.\(destination)")
    }
}

/// A program's whole command line, not just the first few words.
enum ProcessArguments {
    static func of(_ pid: pid_t) -> [String] {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&request, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        // The executable's path, the padding after it, then the arguments, each ended by a NUL.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

extension AppModel {
    /// `ssh gpu` typed in a terminal here: the same server, with its files beside you, is one press away.
    func offerServerWorkspace(_ destination: String) {
        guard !workspaces.contains(where: { $0.remote == destination }), !ServerEntry.declined(destination),
              ServerEntry.offeredThisLaunch.insert(destination).inserted else { return }
        let name = SSHConfigFile.displayName(of: destination)
        showToast(title: String(localized: "Open \(name) as a workspace?"),
                  detail: String(localized: "Its files in the sidebar, and agents that run there."),
                  symbol: "server.rack", tint: .accentColor, actionTitle: String(localized: "Open"), duration: nil,
                  other: (String(localized: "Not Now"), { ServerEntry.decline(destination) })) { [weak self] in
            self?.connect(to: destination)
        }
    }
}

extension RemoteManager {
    /// Folders opened on servers before, straight back in, with the server they're on.
    func recentFolderRows(query: String) -> [PaletteModel.Row] {
        let stored = recents()
        var rows: [PaletteModel.Row] = []
        for destination in stored.hosts {
            let host = SSHConfigFile.displayName(of: destination)
            for folder in (stored.folders[destination] ?? []).prefix(3) {
                var shown = folder
                if let home = stored.homes[destination] {
                    if folder == home { shown = "~" } else if folder.hasPrefix(home + "/") { shown = "~" + folder.dropFirst(home.count) }
                }
                let name = folder == "/" ? "/" : (folder as NSString).lastPathComponent
                let detail = "\(host) · \(shown)"
                guard query.isEmpty || name.localizedCaseInsensitiveContains(query) || detail.localizedCaseInsensitiveContains(query) else { continue }
                rows.append(PaletteModel.Row(id: "recent:\(destination):\(folder)", title: name, detail: detail, symbol: "folder") { [weak self] _ in
                    self?.model.closePalette()
                    self?.model.openRemoteFolder(folder, on: destination)
                })
            }
            if rows.count >= 6 { break }
        }
        return Array(rows.prefix(6))
    }
}
