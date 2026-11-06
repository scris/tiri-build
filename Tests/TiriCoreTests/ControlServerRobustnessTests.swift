import Foundation
import Testing
@testable import TiriCore

/// A client that sends and then stops reading, like a `tiri` stopped with ^Z.
private final class RawClient {
    let fd: Int32

    init(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    deinit { close(fd) }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written <= 0 { return }
            offset += written
        }
    }

    /// Everything until the server closes, or nil if it hasn't closed within the timeout.
    func readToEnd(timeout: Int = 10) -> Data? {
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { return collected }
            if count < 0 { return errno == EAGAIN ? nil : collected }
            collected.append(contentsOf: chunk[0..<count])
        }
    }
}

@Suite(.serialized) struct ControlServerRobustnessTests {
    private func socketPath() -> String {
        "/tmp/tiri-test-\(UUID().uuidString.prefix(8)).sock"
    }

    private static let big = String(repeating: "x", count: 1 << 20)

    private func server(_ path: String, limits: ControlServer.Limits = .init()) throws -> ControlServer {
        let server = ControlServer(path: path) { request in
            switch request.cmd {
            case "big": return .success(id: request.id, .string(Self.big))
            case "slow":
                try? await Task.sleep(for: .milliseconds(200))
                return .success(id: request.id, "slow")
            default: return .success(id: request.id, request.args["n"] ?? .null)
            }
        }
        server.limits = limits
        try server.start()
        return server
    }

    @Test func aClientThatStopsReadingHoldsUpNobody() async throws {
        let path = socketPath()
        let server = try server(path)
        let stalled = RawClient(path: path)
        // Twice the reply, well past what the socket's buffers hold.
        stalled.send(#"{"id":"1","cmd":"big"}"# + "\n" + #"{"id":"2","cmd":"big"}"# + "\n")
        try await Task.sleep(for: .seconds(0.5))
        for index in 0..<5 {
            let client = try ControlClient(path: path, timeout: 3)
            let response = try client.send(ControlRequest(id: "\(index)", cmd: "x", args: ["n": .int(index)]))
            #expect(response.result == .int(index))
        }
        let started = Date()
        server.stop()
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func repliesComeInOrderOfRequests() async throws {
        let path = socketPath()
        let server = try server(path)
        defer { server.stop() }
        let client = RawClient(path: path)
        client.send([#"{"id":"a","cmd":"slow"}"#, #"{"id":"b","cmd":"big"}"#, #"{"id":"c","cmd":"x","args":{"n":3}}"#].joined(separator: "\n") + "\n")
        shutdown(client.fd, SHUT_WR)
        let data = try #require(client.readToEnd())
        let ids = data.split(separator: 0x0A).compactMap { try? ControlCoding.decodeResponse(Data($0)).id }
        #expect(ids == ["a", "b", "c"])
    }

    @Test func aHugeRequestIsRefusedAndClosed() async throws {
        let path = socketPath()
        let server = try server(path, limits: .init(maxRequestBytes: 1 << 20))
        defer { server.stop() }
        let client = RawClient(path: path)
        let writer = Thread { client.send(String(repeating: "y", count: 3 << 20)) }
        writer.start()
        let data = try #require(client.readToEnd())
        let response = try ControlCoding.decodeResponse(Data(data.split(separator: 0x0A).first ?? []))
        #expect(!response.ok)
        #expect(response.error?.contains("too long") == true)
        #expect(ControlClient.isAlive(path: path))
    }

    @Test func tooMuchUnreadReplyDropsTheClient() async throws {
        let path = socketPath()
        let server = try server(path, limits: .init(maxPendingBytes: 256 << 10))
        defer { server.stop() }
        let client = RawClient(path: path)
        client.send(#"{"id":"1","cmd":"big"}"# + "\n")
        // Closed without the reply, rather than held for a client that might never read it.
        let data = try #require(client.readToEnd())
        #expect(data.count < 256 << 10)
        #expect(ControlClient.isAlive(path: path))
    }

    @Test func aStalledClientIsDroppedAfterAWhile() async throws {
        let path = socketPath()
        let server = try server(path, limits: .init(stallLimit: 0.5))
        defer { server.stop() }
        let client = RawClient(path: path)
        client.send(#"{"id":"1","cmd":"big"}"# + "\n")
        // Once the reply has started to arrive, the clock runs from the last byte the socket took.
        var waiting = 0
        var byte: UInt8 = 0
        for _ in 0..<100 where waiting <= 0 {
            try await Task.sleep(for: .seconds(0.05))
            waiting = recv(client.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        }
        #expect(waiting > 0)
        try await Task.sleep(for: .seconds(1.5))
        // Whatever made it into the socket's buffers, then the end, not the rest of the megabyte.
        let data = try #require(client.readToEnd(timeout: 3))
        #expect(data.count < Self.big.utf8.count)
        #expect(ControlClient.isAlive(path: path))
    }

    @Test func aSlowReaderStillGetsEverything() async throws {
        let path = socketPath()
        let server = try server(path)
        defer { server.stop() }
        let client = RawClient(path: path)
        client.send(#"{"id":"1","cmd":"big"}"# + "\n")
        shutdown(client.fd, SHUT_WR)
        try await Task.sleep(for: .seconds(0.5))
        let data = try #require(client.readToEnd())
        let response = try ControlCoding.decodeResponse(Data(data.split(separator: 0x0A).first ?? []))
        #expect(response.result == .string(Self.big))
    }
}
