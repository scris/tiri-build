import Foundation

// MARK: - Where a command's own output starts

/// A login shell's setup can print, and over SSH it does before the command runs: a `.bashrc` that
/// echoes, a `.zshenv` that says hello. That text would land at the top of a fetched file. So each
/// command prints `RemoteShell.outputMarker` first, and everything before it is dropped.
public struct RemoteOutputStart: Sendable {
    public static let marker = Data(RemoteShell.outputMarker.utf8)
    private var held = Data()
    public private(set) var found = false
    /// Something came before the marker.
    public private(set) var noise = false

    public init() {}

    /// What of this chunk is the command's own.
    public mutating func feed(_ chunk: Data) -> Data {
        if found { return chunk }
        held.append(chunk)
        if let range = held.range(of: Self.marker) {
            found = true
            noise = range.lowerBound > held.startIndex
            let rest = Data(held[range.upperBound...])
            held = Data()
            return rest
        }
        // No shell says this much on starting. Whatever it is, it isn't held back for ever.
        if held.count > 1_048_576 {
            found = true
            noise = true
            let all = held
            held = Data()
            return all
        }
        return Data()
    }

    /// It ended without a marker: nothing ran that would print one, so what came is all there is.
    public mutating func finish() -> Data {
        guard !found else { return Data() }
        found = true
        let all = held
        held = Data()
        return all
    }

    public static func strip(_ data: Data) -> (Data, noise: Bool) {
        var start = RemoteOutputStart()
        var out = start.feed(data)
        out.append(start.finish())
        return (out, start.noise)
    }
}

/// The same, for a stream read from a handler.
final class RemoteOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private var start = RemoteOutputStart()
    private var reported = false
    private let onNoise: @Sendable () -> Void

    init(onNoise: @escaping @Sendable () -> Void) { self.onNoise = onNoise }

    func feed(_ data: Data) -> Data {
        let (out, tell): (Data, Bool) = lock.withLock {
            let out = start.feed(data)
            let tell = start.noise && !reported
            if tell { reported = true }
            return (out, tell)
        }
        if tell { onNoise() }
        return out
    }
}

// MARK: - What the server kept while the Mac was away

/// `tiri hook` and `tiri notify` on a server that can't reach the Mac write their request to a
/// spool, one `<ms> <json>` line each, which the next relay sends. Only the newest of each terminal
/// matters, and nothing that something heard live since has already overtaken. Every request says
/// when it was made by the server's clock (`at`), so that's compared with the server's clock alone.
public enum RemoteSpool {
    /// Longer ago than this, it's history, not news.
    static let oldest: Int64 = 24 * 3600 * 1000

    /// The terminal a request is from, if it's one that says how an agent's doing.
    public static func statusItem(_ request: Data) -> String? { status(request)?.item }

    /// The same, and when the server says it was made, if it says.
    public static func status(_ request: Data) -> (item: String, at: Int64?)? {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let argv = object["argv"] as? [String], let first = argv.first, first == "hook" || first == "notify" else { return nil }
        return (object["item"] as? String ?? "", (object["at"] as? NSNumber)?.int64Value)
    }

    /// The requests worth applying, oldest first. `serverNow` is the server's clock when it sent
    /// them, and `lastLive` when each terminal's newest live report was made, by that same clock.
    public static func choose(_ body: Data, serverNow: Int64, lastLive: [String: Int64]) -> [Data] {
        var newest: [String: (Int64, Data)] = [:]
        for line in body.split(separator: 10) {
            guard let space = line.firstIndex(of: 32),
                  let stamp = Int64(String(decoding: line[line.startIndex..<space], as: UTF8.self)) else { continue }
            let request = Data(line[line.index(after: space)...])
            guard let item = statusItem(request) else { continue }
            if let held = newest[item], held.0 > stamp { continue }
            newest[item] = (stamp, request)
        }
        return newest.compactMap { item, entry -> (Int64, Data)? in
            guard serverNow - entry.0 <= oldest else { return nil }
            // Heard live already, or overtaken by something that was. A report the server gave up
            // waiting on can have got here too, and it's the same moment, so the same stamp.
            if let live = lastLive[item], entry.0 <= live { return nil }
            return entry
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

// MARK: - The helper's place on a server

/// Each version of the helper lives in a folder of its own, `<bin>/<version>-<kind>/`, and runs by
/// its full path, so two Tiris of different versions on one server never pull each other's out from
/// under them. `<bin>/tiri` and `<bin>/tiri-remote` stay for terminals an older Tiri started.
public enum RemoteHelperScripts {
    /// Only a folder that's really this user's. Under /tmp, someone else could have made it first.
    static func ours(_ folder: String) -> String {
        let quoted = ShellQuote.quote(folder)
        return "mkdir -p \(quoted) && [ -O \(quoted) ] && [ ! -L \(quoted) ] && chmod 700 \(quoted)"
    }

    /// Makes the folders, and says the version if this one's already there.
    public static func check(base: String, versioned: String, run: String) -> String {
        var steps = [ours(base)]
        let runParent = (run as NSString).deletingLastPathComponent
        if runParent != base { steps.append(ours(runParent)) }
        let quotedRun = ShellQuote.quote(run)
        steps.append("mkdir -p \(ShellQuote.quote(versioned)) \(quotedRun) \(ShellQuote.quote(base + "/tmp"))")
        steps.append("chmod 700 \(quotedRun) && [ -O \(quotedRun) ] && [ ! -L \(quotedRun) ]")
        steps.append("\(ShellQuote.quote(versioned + "/tiri-remote")) version")
        // When it was last used, for knowing when nobody uses it any more.
        steps.append("touch \(ShellQuote.quote(versioned))")
        return steps.joined(separator: " && ")
    }

    /// Sends the helper on stdin, and only puts it in place once all of it has arrived intact.
    public static func upload(base: String, versioned: String, size: Int, sha256: String) -> String {
        let bin = (versioned as NSString).deletingLastPathComponent
        let target = ShellQuote.quote(versioned + "/tiri-remote")
        return """
        \(ours(base)) && mkdir -p \(ShellQuote.quote(bin)) || exit 1
        t=\(ShellQuote.quote(bin + "/.upload-" + UUID().uuidString.prefix(8)))
        trap 'rm -f "$t"' EXIT
        trap 'exit 1' HUP INT TERM
        cat > "$t" || exit 1
        [ "$(wc -c < "$t" | tr -d ' ')" = \(size) ] || exit 1
        if command -v sha256sum >/dev/null 2>&1; then s="$(sha256sum < "$t")"
        elif command -v shasum >/dev/null 2>&1; then s="$(shasum -a 256 < "$t")"
        else s=\(sha256); fi
        [ "${s%% *}" = \(sha256) ] || exit 1
        chmod 755 "$t" && mkdir -p \(ShellQuote.quote(versioned)) && mv -f "$t" \(target) || exit 1
        \(target) version
        """
    }

    /// Once it works: `tiri` beside it, the old names kept pointing at something that runs, and
    /// versions nobody has used for two weeks, and that nothing is running, taken away.
    public static func tidy(versioned: String, days: Int = 14) -> String {
        let bin = (versioned as NSString).deletingLastPathComponent
        let folder = ShellQuote.quote((versioned as NSString).lastPathComponent)
        let quotedBin = ShellQuote.quote(bin)
        return """
        cd \(quotedBin) || exit 0
        [ -e \(folder)/tiri ] || ln -sf tiri-remote \(folder)/tiri
        here="$(pwd -P)"
        # Whether a process runs a program from there. The path goes in the environment, so the check's
        # own command line never matches.
        in_use() {
          if [ -d /proc/self ]; then
            ls -l /proc/[0-9]*/exe 2>/dev/null | N=" -> $here/$1" awk 'index($0, ENVIRON["N"]) { f = 1 } END { exit !f }'
          else
            ps -A -o command= 2>/dev/null | N=\(quotedBin)/"$2" awk 'index($0, ENVIRON["N"]) { f = 1 } END { exit !f }'
          fi
        }
        old() { [ -n "$(find "$1" -prune -mtime +\(days) 2>/dev/null)" ]; }
        for d in */; do
          d="${d%/}"
          [ "$d" = \(folder) ] && continue
          [ -f "$d/tiri-remote" ] && [ ! -L "$d" ] || continue
          old "$d" || continue
          in_use "$d/" "$d/" && continue
          rm -rf "./$d"
        done
        # From before versions had folders. Started through the plain name, so without /proc any of them counts.
        for f in tiri-remote-*; do
          [ -f "$f" ] && [ ! -L "$f" ] || continue
          old "$f" || continue
          in_use "$f" tiri-remote && continue
          rm -f "./$f"
        done
        for name in tiri tiri-remote; do [ -x "$name" ] || ln -sf \(folder)/tiri-remote "$name"; done
        true
        """
    }
}
