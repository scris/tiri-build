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

    /// How much one client may make Tiri hold for it, and for how long.
    struct Limits {
        /// A request line longer than this is refused, and the connection closed.
        var maxRequestBytes = 16 << 20
        /// Past this much unread reply, the client is given up on.
        var maxPendingBytes = 64 << 20
        /// Replies waiting this long without a byte taken mean a client that's stopped reading.
        var stallLimit: TimeInterval = 30
    }

    /// Kept on the queue, where each connection finds them as it starts.
    var limits: Limits {
        get { queue.getSpecific(key: Self.limitsKey) ?? Limits() }
        set { queue.setSpecific(key: Self.limitsKey, value: newValue) }
    }
    private static let limitsKey = DispatchSpecificKey<Limits>()

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Only remove a socket nobody is listening on, as tmux decides it. A live one belongs to another instance,
        // however busy: one that takes a connection and doesn't answer is still running.
        switch ControlClient.socketState(path: path) {
        case .missing: break
        case .stale: unlink(path)
        case .listening: throw ControlSocketError.system("bind (another Tiri is running)", EADDRINUSE)
        case .unknown(let code): throw ControlSocketError.system("connect", code)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        // Not into terminals: a session kept the socket listening long after Tiri had gone.
        CloseOnExec.mark(fd)
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

    /// Never waits long: quitting mustn't hang on the queue, whatever a client is doing.
    public func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for connection in connections.values { connection.drop() }
            connections.removeAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        CloseOnExec.mark(client)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: client, queue: queue, handler: handler) { [weak self] fd in
            self?.connections[fd] = nil
        }
        connections[client] = connection
        connection.start()
    }

    /// One client. Its socket never blocks, so a client that stops reading holds up nobody else:
    /// replies wait in `pending` and go out as the socket takes them, the way tmux does it.
    private final class Connection: @unchecked Sendable {
        var limits = Limits()
        let fd: Int32
        let queue: DispatchQueue
        let handler: Handler
        let onClose: (Int32) -> Void
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var writeSuspended = true
        /// Both sources' cancel handlers have to run before the descriptor can close.
        var sourcesRunning = 0
        var buffer = Data()
        /// How much of `buffer` is known to hold no newline.
        var scanned = 0
        var pending: [Data] = []
        var pendingOffset = 0
        var pendingBytes = 0
        var lastProgress = DispatchTime.now()
        var stallCheckScheduled = false
        var tail: Task<Void, Never>?
        var readingDone = false
        var repliesDone = false
        var finishing = false
        var closed = false

        init(fd: Int32, queue: DispatchQueue, handler: @escaping Handler, onClose: @escaping (Int32) -> Void) {
            self.fd = fd
            self.queue = queue
            self.handler = handler
            self.onClose = onClose
        }

        func start() {
            limits = queue.getSpecific(key: ControlServer.limitsKey) ?? Limits()
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            reader.setCancelHandler { [self] in sourceEnded() }
            // Made suspended, and resumed only while something is waiting to go out.
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writer.setEventHandler { [weak self] in self?.flush() }
            writer.setCancelHandler { [self] in sourceEnded() }
            sourcesRunning = 2
            readSource = reader
            writeSource = writer
            reader.resume()
        }

        /// Gone at once, with whatever hadn't been written.
        func drop() {
            pending.removeAll()
            pendingBytes = 0
            pendingOffset = 0
            repliesDone = true
            finish()
        }

        private func sourceEnded() {
            sourcesRunning -= 1
            guard sourcesRunning == 0, !closed else { return }
            closed = true
            close(fd)
            onClose(fd)
        }

        private func cancelReading() {
            readingDone = true
            readSource?.cancel()
            readSource = nil
        }

        /// Stops both sources. The descriptor closes once dispatch has let go of it.
        private func finish() {
            guard !finishing else { return }
            finishing = true
            cancelReading()
            if let writer = writeSource {
                writer.cancel()
                // A suspended source never runs its cancel handler, and mustn't be released.
                if writeSuspended {
                    writeSuspended = false
                    writer.resume()
                }
            }
            writeSource = nil
        }

        /// Closes once reading's over, every reply has been made, and all of it has gone out.
        private func finishIfDone() {
            guard readingDone, repliesDone, pendingBytes == 0 else { return }
            finish()
        }

        /// After the replies already on their way, and one more if given, nothing else is said.
        private func endAfterReplies(saying last: ControlResponse? = nil) {
            cancelReading()
            let previous = tail
            tail = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                if let last { self.write(last) }
                self.queue.async { [self] in
                    repliesDone = true
                    finishIfDone()
                }
            }
        }

        private func readAvailable() {
            guard !readingDone else { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            if count <= 0 {
                // The client may have half-closed: let in-flight requests finish and reply.
                endAfterReplies()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            // Only what just arrived is searched, so a long line costs once, not once per read.
            while let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                scanned = 0
                if !line.isEmpty { dispatch(line) }
            }
            scanned = buffer.count
            if buffer.count > limits.maxRequestBytes {
                buffer = Data()
                scanned = 0
                endAfterReplies(saying: .failure(id: "", "Request too long: over \(limits.maxRequestBytes >> 20) MB without a newline"))
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
                guard !finishing, !data.isEmpty else { return }
                if pendingBytes == 0 { lastProgress = .now() }
                pending.append(data)
                pendingBytes += data.count
                if pendingBytes > limits.maxPendingBytes {
                    drop()
                    return
                }
                flush()
            }
        }

        /// Writes what the socket takes now, and waits for it to take more only if there's more.
        private func flush() {
            while let first = pending.first, !finishing {
                let written = first.withUnsafeBytes { raw in
                    // MSG_NOSIGNAL as well as SO_NOSIGPIPE: a client that hung up before it was accepted leaves a socket
                    // that refuses SO_NOSIGPIPE (EINVAL), and a plain write to it would end Tiri with SIGPIPE.
                    Darwin.send(fd, raw.baseAddress!.advanced(by: pendingOffset), raw.count - pendingOffset, MSG_NOSIGNAL)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    drop()
                    return
                }
                lastProgress = .now()
                pendingOffset += written
                pendingBytes -= written
                if pendingOffset == first.count {
                    pending.removeFirst()
                    pendingOffset = 0
                }
            }
            guard !finishing else { return }
            if pendingBytes > 0 {
                if writeSuspended {
                    writeSuspended = false
                    writeSource?.resume()
                }
                scheduleStallCheck()
            } else {
                if !writeSuspended {
                    writeSuspended = true
                    writeSource?.suspend()
                }
                finishIfDone()
            }
        }

        private func scheduleStallCheck() {
            guard !stallCheckScheduled else { return }
            stallCheckScheduled = true
            queue.asyncAfter(deadline: lastProgress + limits.stallLimit) { [weak self] in
                guard let self else { return }
                self.stallCheckScheduled = false
                guard !self.finishing, self.pendingBytes > 0 else { return }
                if DispatchTime.now() >= self.lastProgress + self.limits.stallLimit {
                    self.drop()
                } else {
                    self.scheduleStallCheck()
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
        CloseOnExec.mark(fd)
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

    public enum SocketState: Equatable, Sendable {
        case missing
        /// Nobody is listening: connecting was refused.
        case stale
        case listening
        /// Something else went wrong, and nothing should be assumed about who has it.
        case unknown(Int32)
    }

    /// Whether anyone is listening, decided by connecting alone, as tmux does. Waiting for an answer would let a Tiri whose
    /// main thread is busy, behind a permission prompt or a long save, lose its socket to a second launch.
    public static func socketState(path: String) -> SocketState {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno) }
        defer { close(fd) }
        guard var address = try? makeAddress(path) else { return .unknown(ENAMETOOLONG) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return .listening }
        switch errno {
        case ECONNREFUSED: return .stale
        case ENOENT: return .missing
        default: return .unknown(errno)
        }
    }

    public static func isAlive(path: String) -> Bool { socketState(path: path) == .listening }

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

// MARK: - The relay for terminals on a server

/// What `tiri` on a server sends, and what it wants back. See `tiri-remote relay`.
public enum RemoteRelayMessage {
    public struct Request: Decodable, Sendable {
        public var argv: [String]
        public var cwd: String?
        public var item: String?
        public var workspace: String?
        public var entrypoint: String?
        /// The command lines above `tiri` on the server, nearest first, with spaces between words.
        public var ancestors: [String]?
        public var stdin: String?
    }

    public struct Reply: Sendable {
        public var code: Int32
        public var output: String
        public var errors: String
        public init(code: Int32 = 0, output: String = "", errors: String = "") {
            self.code = code
            self.output = output
            self.errors = errors
        }

        /// The exit code on its own line, what to print, and what to complain about after a 0x1E.
        public var encoded: Data {
            var answer = Data("\(code)\n".utf8)
            answer.append(Data(output.utf8))
            if !errors.isEmpty {
                answer.append(0x1E)
                answer.append(Data(errors.utf8))
            }
            return answer
        }
    }
}
