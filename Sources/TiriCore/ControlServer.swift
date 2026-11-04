import Foundation

public enum ControlSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case timedOut
    case closed

    public var description: String {
        switch self {
        case .pathTooLong(let path): "Socket path is too long: \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .timedOut: "Timed out waiting for Tiri to respond"
        case .closed: "Tiri closed the connection"
        }
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw ControlSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return address
}

/// Serves the control protocol on a Unix socket. Requests from one connection are
/// answered in order. The handler decides which actor the work runs on.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "tiri.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Only remove a socket nobody is answering on. A live one belongs to another instance.
        if FileManager.default.fileExists(atPath: path) {
            if ControlClient.isAlive(path: path) {
                throw ControlSocketError.system("bind (another Tiri is running)", EADDRINUSE)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var address = try makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.system("listen", code)
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        // Dispatch requires the descriptor to stay open until cancellation has finished.
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for connection in connections.values { connection.shutdown() }
            connections.removeAll()
        }
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: client, queue: queue, handler: handler) { [weak self] fd in
            self?.connections[fd] = nil
        }
        connections[client] = connection
        connection.start()
    }

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let queue: DispatchQueue
        let handler: Handler
        let onClose: (Int32) -> Void
        var source: DispatchSourceRead?
        var buffer = Data()
        var tail: Task<Void, Never>?
        var writesFinished = false
        var sourceCancelled = false
        var closed = false

        init(fd: Int32, queue: DispatchQueue, handler: @escaping Handler, onClose: @escaping (Int32) -> Void) {
            self.fd = fd
            self.queue = queue
            self.handler = handler
            self.onClose = onClose
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [self] in
                sourceCancelled = true
                closeIfFinished()
            }
            source.resume()
            self.source = source
        }

        func shutdown() {
            writesFinished = true
            cancelSource()
            closeIfFinished()
        }

        private func cancelSource() {
            source?.cancel()
            source = nil
        }

        /// The descriptor closes once reading has been cancelled and all replies are written.
        private func closeIfFinished() {
            guard sourceCancelled, writesFinished, !closed else { return }
            closed = true
            close(fd)
            onClose(fd)
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                cancelSource()
                // The client may have half-closed: let in-flight requests finish and reply.
                let last = tail
                Task { [self] in
                    await last?.value
                    queue.async { [self] in
                        writesFinished = true
                        closeIfFinished()
                    }
                }
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { dispatch(line) }
            }
        }

        private func dispatch(_ line: Data) {
            let previous = tail
            let handler = handler
            tail = Task { [weak self] in
                await previous?.value
                let response: ControlResponse
                do {
                    let request = try ControlCoding.decodeRequest(line)
                    response = await handler(request)
                } catch {
                    response = .failure(id: "", "Malformed request: \(error)")
                }
                self?.write(response)
            }
        }

        private func write(_ response: ControlResponse) {
            guard let data = try? ControlCoding.encodeLine(response) else { return }
            queue.async { [self] in
                guard !closed, !writesFinished else { return }
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = Foundation.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
            }
        }
    }
}

/// A blocking client, used by the CLI and by tests.
public final class ControlClient {
    private let fd: Int32
    private var buffer = Data()

    public init(path: String, timeout: TimeInterval = 10) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // No close here: deinit runs for a class whose init throws after all properties are set.
        guard connected == 0 else { throw ControlSocketError.system("connect", errno) }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    /// A socket nobody's listening on fails at once. The wait is only for an app that's there but
    /// busy, such as behind a permission prompt, which shouldn't lose its socket to a second launch.
    public static func isAlive(path: String) -> Bool {
        guard let client = try? ControlClient(path: path, timeout: 3) else { return false }
        return (try? client.send(ControlRequest(cmd: "ping")))?.ok == true
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let data = try ControlCoding.encodeLine(request)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw ControlSocketError.system("write", errno) }
                offset += written
            }
        }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return try ControlCoding.decodeResponse(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { throw ControlSocketError.closed }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw ControlSocketError.timedOut }
                throw ControlSocketError.system("read", errno)
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
