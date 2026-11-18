// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Network
import Synchronization
import Testing

@testable import FanousEngine

/// The request loop of an `HTTPSServer` connection over raw TLS: what arrives in one write is answered one request at a
/// time, each after the previous response has left (B270).
@Suite(.cleansTempFiles) struct HTTPSPipeliningTests {
    /// The body for request `/r/<i>`: 1 MiB, its index in the first bytes so an out-of-order reply shows.
    static func body(_ i: Int) -> [UInt8] {
        let tag = Array("response \(i)\n".utf8)
        return tag + [UInt8](repeating: UInt8(truncatingIfNeeded: i), count: (1 << 20) - tag.count)
    }

    /// The bytes the server sends for a route's `response`: plus the two headers every response gets.
    static func served(_ response: HTTPResponse) -> [UInt8] {
        var response = response
        response.headers += [HTTPHeader("Server", "fanousd/\(FanousVersion.string)"), HTTPHeader("X-Content-Type-Options", "nosniff")]
        return response.serialized()
    }

    static func start(_ server: HTTPSServer) async throws -> NWConnection {
        server.start()
        #expect(await waitUntil { server.boundPort != nil })
        let port = try #require(server.boundPort)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: .init()))
        connection.start(queue: .global())
        return connection
    }

    /// Reads until `enough` holds for what arrived, or the server ends the connection.
    static func read(_ connection: NWConnection, until enough: (Data) -> Bool = { _ in false }) async -> Data {
        var received = Data()
        while !enough(received) {
            // a test's time limit cancels the task; ending the connection is what ends a receive that waits forever
            let (data, done) = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                        continuation.resume(returning: (data, isComplete || error != nil))
                    }
                }
            } onCancel: {
                connection.cancel()
            }
            if let data { received.append(data) }
            if done { break }
        }
        return received
    }

    static func upgrade(port: UInt16) -> Data {
        Data("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }

    static func stateServer(logger: Logger = testLogger) throws -> (HTTPSServer, StateServer) {
        let (store, auth) = testStore()
        let stateServer = StateServer(store: store, auth: auth, caps: ["schema": 1], logger: logger)
        let server = try HTTPSServer(
            port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: testLogger
        ) { _ in nil }
        server.upgradeRoute = { stateServer.upgrade($0) }
        return (server, stateServer)
    }

    /// A client that pipelines GETs and does not read is served one response at a time, as the transport takes them,
    /// not buffered for: the route runs for a few requests, not all of them (B270; before, all 64 MiB were queued in the
    /// connection at once). Once it reads, it gets every response, in order and byte for byte, and the last request's
    /// `Connection: close` ends the connection.
    @Test func aClientThatDoesNotReadIsNotBufferedFor() async throws {
        let count = 64
        let parsed = Mutex(0)
        let server = try HTTPSServer(
            port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: testLogger
        ) { request in
            parsed.withLock { $0 += 1 }
            return HTTPResponse(status: 200, body: Self.body(Int(request.path.dropFirst(3)) ?? -1))
        }
        defer { server.stop() }
        let connection = try await Self.start(server)
        defer { connection.cancel() }
        let requests = (0..<count).map { "GET /r/\($0) HTTP/1.1\r\nHost: x\r\n\($0 == count - 1 ? "Connection: close\r\n" : "")\r\n" }
        connection.send(content: Data(requests.joined().utf8), completion: .idempotent)

        #expect(await waitUntil { parsed.withLock { $0 } > 0 })
        // a negative check needs a fixed window: the old code ran the route for all 64 within milliseconds
        #expect(!(await waitUntil(.seconds(1)) { parsed.withLock { $0 } == count }))
        let whileNotReading = parsed.withLock { $0 }
        #expect(whileNotReading < count / 4, "route ran \(whileNotReading) times for a client that does not read")

        let received = await Self.read(connection)
        let all = (0..<count).flatMap { Self.served(HTTPResponse(status: 200, body: Self.body($0))) }
        #expect(received.count == all.count)
        #expect(received == Data(all))
        #expect(parsed.withLock { $0 } == count)
    }

    /// A streamed upload and the request behind its body, in one write: both are answered, in order. Before B270 the
    /// request waited for more bytes that never came (the loop returned after the upload's response), so this one hung.
    @Test(.timeLimit(.minutes(1))) func theRequestBehindAnUploadIsAnsweredAfterIt() async throws {
        let dir = try tempDir("upload")
        let server = try HTTPSServer(
            port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: testLogger
        ) { .text(200, "after \($0.path)") }
        server.uploadSink = { _ in
            let file = dir.appending(path: "upload.bin")
            return FileManager.default.createFile(atPath: file.path, contents: nil) ? file : nil
        }
        server.uploadRoute = { _, file in
            .text(202, "stored \((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? -1)")
        }
        defer { server.stop() }
        let connection = try await Self.start(server)
        defer { connection.cancel() }
        let size = HTTPSServer.maxInlineBody + 1000
        let upload = Data("PUT /api/upload/1/clip.mov HTTP/1.1\r\nHost: x\r\nContent-Length: \(size)\r\n\r\n".utf8) + Data(count: size)
        connection.send(content: upload + Data("GET /next HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)

        let received = await Self.read(connection)
        // the upload route's response goes out as it is, without the two headers `served` adds (as on main)
        #expect(received == Data(HTTPResponse.text(202, "stored \(size)").serialized() + Self.served(.text(200, "after /next"))))
    }

    /// The upgrade request and the `hello` in one write: the 101, then the welcome.
    @Test func helloInTheUpgradeWriteGetsAWelcome() async throws {
        let (server, _) = try Self.stateServer()
        defer { server.stop() }
        let connection = try await Self.start(server)
        defer { connection.cancel() }
        let port = try #require(server.boundPort)
        connection.send(content: Self.upgrade(port: port) + Data(WebSocketSessionTests.frame(.text, WebSocketSessionTests.hello)), completion: .idempotent)

        let received = await Self.read(connection) { $0.range(of: Data(#""t":"welcome""#.utf8)) != nil }
        #expect(received.starts(with: Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)))
        #expect(received.range(of: Data(#""t":"welcome""#.utf8)) != nil)
    }

    /// Upgrade, a close frame and a hello in one write: the session closes and never sees the hello, also when the 101
    /// was still leaving as the close came in.
    @Test func noFrameReachesTheSessionAfterTheClientsClose() async throws {
        let lines = HTTPSServerLogTests.Lines()
        let (server, _) = try Self.stateServer(logger: Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) })
        defer { server.stop() }
        let connection = try await Self.start(server)
        defer { connection.cancel() }
        let port = try #require(server.boundPort)
        let frames = WebSocketSessionTests.frame(.close, [0x03, 0xE8]) + WebSocketSessionTests.frame(.text, WebSocketSessionTests.hello)
        connection.send(content: Self.upgrade(port: port) + Data(frames), completion: .idempotent)

        // the server sends its close frame after the 101 and ends the connection once that has left: by then the 101's
        // completion, which resumes the request loop, has run
        let received = await Self.read(connection)
        #expect(received.starts(with: Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)))
        let joined = lines.all.withLock { $0 }.filter { $0.contains("client joined") }
        #expect(joined.isEmpty, "\(joined)")
    }
}
