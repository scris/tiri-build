import Foundation

/// The TCP ports a program and everything it started are listening on, read from the kernel the way `lsof` does,
/// without running it. A dev server's page is one of them, whatever port it chose.
public enum ListeningPorts {
    public static func under(_ root: pid_t) -> [Int] {
        var ports = Set<Int>()
        for pid in [root] + descendants(of: root) { ports.formUnion(listening(pid)) }
        return ports.sorted()
    }

    /// Children, their children and so on. A shell's server is usually two or three levels down.
    public static func descendants(of root: pid_t) -> [pid_t] {
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for a few started in the meantime.
        size += MemoryLayout<kinfo_proc>.stride * 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard processes.withUnsafeMutableBytes({ sysctl(&request, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        processes = Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
        var children: [pid_t: [pid_t]] = [:]
        for process in processes {
            children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid)
        }
        var found: [pid_t] = []
        var waiting = children[root] ?? []
        while let next = waiting.popLast(), found.count < 2_000 {
            found.append(next)
            waiting += children[next] ?? []
        }
        return found
    }

    static func listening(_ pid: pid_t) -> [Int] {
        let room = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard room > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(room) / stride + 16)
        let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var ports: [Int] = []
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP),
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let raw = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            let port = Int(UInt16(bigEndian: raw))
            if port > 0 { ports.append(port) }
        }
        return ports
    }
}
