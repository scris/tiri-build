import Darwin
import Foundation

/// A Mac's disk usually ignores case, so `readme.md` opens `README.md`. Tiri matches tabs and file events by
/// the exact path, so a path is spelled the way the disk spells it before it's used for either.
public enum PathCase {
    /// Each part below `folder` as the disk names it, without following symlinks, so a link keeps its own
    /// name. `folder` keeps the spelling given. Parts that don't exist yet stay as typed.
    public static func onDisk(_ path: String, below folder: String) -> String {
        let base = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        guard path.hasPrefix(base == "/" ? "/" : base + "/") else { return path }
        let parts = path.dropFirst(base == "/" ? 1 : base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func joined(_ head: String, _ name: String) -> String { (head == "/" ? "/" : head + "/") + name }
        var built = base
        var found = true
        for part in parts {
            let typed = joined(built, part)
            guard found, !part.isEmpty, part != ".", part != ".." else {
                built = typed
                continue
            }
            guard let name = diskName(of: typed) else {
                // Nothing below a missing part can be on disk.
                found = false
                built = typed
                continue
            }
            // Only a different spelling of the same name: a hard link can report another of its names.
            built = name != part && name.compare(part, options: .caseInsensitive) == .orderedSame ? joined(built, name) : typed
        }
        return built
    }

    /// The whole path as the disk spells it, symlinks left alone.
    public static func onDisk(_ path: String) -> String {
        onDisk(path, below: "/")
    }

    /// The name the file system holds for the last part of the path, which needn't be the one used to reach it.
    static func diskName(of path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        let size = 8 + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 3 + 1
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { raw -> String? in
            guard getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0, let base = raw.baseAddress else { return nil }
            let reference = base.advanced(by: 4)
            let field = reference.load(as: attrreference_t.self)
            let start = reference.advanced(by: Int(field.attr_dataoffset))
            let length = Int(field.attr_length)
            guard length > 0, start + length <= base + raw.count else { return nil }
            // The length counts the terminating zero.
            let bytes = UnsafeRawBufferPointer(start: start, count: length).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return result
    }
}
