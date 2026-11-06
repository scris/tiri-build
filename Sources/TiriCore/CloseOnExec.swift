import Foundation

/// Tiri's own files stay Tiri's. A terminal is started with fork and exec, and anything not marked
/// close-on-exec goes along into the shell and every agent under it: a language server's input
/// would never see its end after Tiri quits, and a git call racing a new terminal would wait out
/// its timeout for an end of output that some shell is holding.
public enum CloseOnExec {
    public static func mark(_ descriptors: Int32...) {
        for descriptor in descriptors where descriptor >= 0 {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
    }

    /// Everything open past 0-2, just before a terminal starts. Not all of it is Tiri's to mark when it's
    /// opened: Foundation's readability handlers read through a copy of the pipe that isn't marked, and
    /// AppKit and Metal leave their own files open. A program started any other way gets only 0-2 anyway.
    public static func markAllOpen() {
        let room = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard room > 0 else { return }
        let size = MemoryLayout<proc_fdinfo>.stride
        // Room for a few opened in the meantime.
        var found = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(room) / size + 32)
        let used = found.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return }
        for entry in found.prefix(Int(used) / size) where entry.proc_fd > 2 { mark(entry.proc_fd) }
    }

    public static func isMarked(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }
}

extension Pipe {
    /// A pipe for one child. Process puts its ends where the child wants them, and that copy is the
    /// child's to keep. Nothing else started later gets them.
    public static func notInherited() -> Pipe {
        let pipe = Pipe()
        CloseOnExec.mark(pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor)
        return pipe
    }
}
