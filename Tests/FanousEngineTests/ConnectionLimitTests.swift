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

/// Connection caps and deadlines of the HTTPS and CITP servers (B269), over loopback with the limits shortened to
/// fractions of a second.
@Suite(.cleansTempFiles) struct ConnectionLimitTests {
    static let short = HTTPSServer.Limits(request: 0.3, hello: 0.3, ping: 0.05, silent: 0.3, tick: 0.02)

    /// Set once the server ends a connection (or a client's connection fails).
    final class Watch: Sendable {
        let ended = Mutex(false)
        let received = Mutex(Data())
        let pings = Mutex(0)
        var hasEnded: Bool { ended.withLock { $0 } }
    }

    /// Reads everything that arrives until the connection ends; with `pong`, answers each empty ping as a browser does.
    static func watch(_ connection: NWConnection, pong: Bool = false, maximum: Int = 1 << 20) -> Watch {
        let watch = Watch()
        receive(connection, watch, pong: pong, maximum: maximum)
        return watch
    }

    private static func receive(_ connection: NWConnection, _ watch: Watch, pong: Bool, maximum: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, done, error in
            if let data {
                watch.received.withLock { $0.append(data) }
                // a server frame is unmasked: an empty ping is 0x89 0x00 (a JSON text frame cannot contain 0x89)
                let pings = data.indices.dropLast().count { data[$0] == 0x89 && data[$0 + 1] == 0 }
                watch.pings.withLock { $0 += pings }
                if pong { for _ in 0..<pings { connection.send(content: Data(WebSocketSessionTests.frame(.pong, [])), completion: .idempotent) } }
            }
            if done || error != nil { return watch.ended.withLock { $0 = true } }
            receive(connection, watch, pong: pong, maximum: maximum)
        }
    }

    static func server(limits: HTTPSServer.Limits = short, logger: Logger = testLogger, route: @escaping HTTPSServer.Route = { _ in .text(200, "ok") }) throws -> HTTPSServer {
        let server = try HTTPSServer(port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: logger, route: route)
        server.limits = limits
        return server
    }

    /// A second TLS connection to a started server.
    static func connect(_ server: HTTPSServer) throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try #require(server.boundPort))!, using: NWParameters(tls: tls, tcp: .init()))
        connection.start(queue: .global())
        return connection
    }

    // MARK: HTTPS deadlines

    /// A connection that sends nothing, one with half a request head and one with half a body are each closed once the
    /// request deadline passes. Before B269 all three stayed open for ever (measured: 1,000 for 105 s on a test instance).
    @Test func connectionsThatStopSendingAreClosed() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let idle = try await HTTPSPipeliningTests.start(server)
        let head = try Self.connect(server)
        let body = try Self.connect(server)
        defer { [idle, head, body].forEach { $0.cancel() } }
        head.send(content: Data("GET /healthz HTTP/1.1\r\nHost: x\r\n".utf8), completion: .idempotent)
        body.send(content: Data("POST /api/login HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n".utf8) + Data(count: 500), completion: .idempotent)
        let watches = [idle, head, body].map { Self.watch($0) }

        #expect(await waitUntil(.seconds(5)) { watches.allSatisfy(\.hasEnded) }, "ended: \(watches.map(\.hasEnded))")
        #expect(watches.allSatisfy { $0.received.withLock { $0.isEmpty } }, "closed without an answer")
    }

    /// An upload that stops halfway is closed, and its partial file removed; one that keeps sending, slower than the whole
    /// deadline allows for the body, is not cut: the deadline is per chunk.
    @Test(.timeLimit(.minutes(1))) func anUploadIsCutOnlyWhenItStops() async throws {
        let dir = try tempDir("upload")
        let server = try Self.server { _ in nil }
        let files = Mutex(0)
        server.uploadSink = { _ in
            let file = dir.appending(path: "upload-\(files.withLock { $0 += 1; return $0 }).bin")
            return FileManager.default.createFile(atPath: file.path, contents: nil) ? file : nil
        }
        server.uploadRoute = { _, file in .text(202, "stored \((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? -1)") }
        defer { server.stop() }
        let size = HTTPSServer.maxInlineBody + 1 << 20  // 2 MiB
        let head = Data("PUT /api/upload/1/clip.mov HTTP/1.1\r\nHost: x\r\nContent-Length: \(size)\r\n\r\n".utf8)

        let stalled = try await HTTPSPipeliningTests.start(server)
        defer { stalled.cancel() }
        stalled.send(content: head + Data(count: size / 2), completion: .idempotent)
        let stalledWatch = Self.watch(stalled)
        #expect(await waitUntil(.seconds(5)) { stalledWatch.hasEnded })
        #expect(await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true }, "partial upload removed")

        // 32 chunks of 64 KiB, one every 50 ms: about 1.6 s for the body, five times the 0.3 s deadline
        let steady = try Self.connect(server)
        defer { steady.cancel() }
        let steadyWatch = Self.watch(steady)
        steady.send(content: head, completion: .idempotent)
        for _ in 0..<(size / 65_536) {
            try await Task.sleep(for: .milliseconds(50))
            steady.send(content: Data(count: 65_536), completion: .idempotent)
        }
        #expect(await waitUntil(.seconds(5)) { steadyWatch.received.withLock { $0 } == Data(HTTPResponse.text(202, "stored \(size)").serialized()) })
    }

    /// A client that asks for a large response and does not read is closed once the transport stops taking slices (before
    /// B269 the rest of the response stayed queued for ever, PR #397); one that reads slowly gets all of it.
    @Test(.timeLimit(.minutes(1))) func aResponseIsCutOnlyWhenTheClientStopsTakingIt() async throws {
        let size = 32 << 20
        var limits = Self.short
        limits.request = 1  // the slices a reader takes in bursts come up to 0.2 s apart here (measured)
        let server = try Self.server(limits: limits) { _ in HTTPResponse(status: 200, body: [UInt8](repeating: 7, count: size)) }
        defer { server.stop() }

        let reader = try await HTTPSPipeliningTests.start(server)
        defer { reader.cancel() }
        reader.send(content: Data("GET /big HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        // at most 1 MiB every 50 ms: at least 1.6 s for the response, longer than the deadline
        var received = 0
        while received < size {
            let data: Data? = await withCheckedContinuation { c in
                reader.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in c.resume(returning: done || error != nil ? nil : data) }
            }
            guard let data else { break }
            received += data.count
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(received >= size, "a slow reader got \(received) of \(size) bytes")

        let stuck = try Self.connect(server)
        defer { stuck.cancel() }
        stuck.send(content: Data("GET /big HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        try await Task.sleep(for: .seconds(2))  // not reading: the transport fills, then the deadline passes
        let watch = Self.watch(stuck, maximum: 8 << 20)
        #expect(await waitUntil(.seconds(10)) { watch.hasEnded })
        let got = watch.received.withLock { $0.count }
        #expect(got < size, "a client that did not read got all \(got) bytes: nothing closed it")
    }

    // MARK: WebSocket

    /// An upgrade without a `hello` is closed after the hello deadline.
    @Test func anUpgradeWithoutHelloIsClosed() async throws {
        let (server, stateServer) = try HTTPSPipeliningTests.stateServer()
        server.limits = Self.short
        defer { server.stop() }
        let connection = try await HTTPSPipeliningTests.start(server)
        defer { connection.cancel() }
        connection.send(content: HTTPSPipeliningTests.upgrade(port: try #require(server.boundPort)), completion: .idempotent)
        let watch = Self.watch(connection, pong: true)  // answering pings does not stand in for a hello
        #expect(await waitUntil(.seconds(5)) { watch.hasEnded })
        #expect(watch.received.withLock { $0.starts(with: Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)) })
        #expect(stateServer.store.clientCount == 0)
    }

    /// A client that says nothing after its hello but answers pings (every browser does, by itself) stays, for many
    /// times the silence limit; one that stops answering is closed and its session, with its subscriptions, is gone.
    @Test func aQuietClientStaysAndADeadOneIsClosed() async throws {
        let (server, stateServer) = try HTTPSPipeliningTests.stateServer()
        server.limits = Self.short
        defer { server.stop() }
        let quiet = try await HTTPSPipeliningTests.start(server)
        let dead = try Self.connect(server)
        defer { [quiet, dead].forEach { $0.cancel() } }
        let hello = HTTPSPipeliningTests.upgrade(port: try #require(server.boundPort)) + Data(WebSocketSessionTests.frame(.text, WebSocketSessionTests.hello))
        let quietWatch = Self.watch(quiet, pong: true)
        let deadWatch = Self.watch(dead)
        quiet.send(content: hello, completion: .idempotent)
        dead.send(content: hello, completion: .idempotent)
        #expect(await waitUntil { stateServer.store.clientCount == 2 })

        #expect(await waitUntil(.seconds(5)) { deadWatch.hasEnded }, "a client that answers no ping is closed")
        #expect(await waitUntil { stateServer.store.clientCount == 1 })
        // a negative check needs a fixed window: five times the silence limit
        try await Task.sleep(for: .seconds(1.5))
        #expect(!quietWatch.hasEnded)
        #expect(stateServer.store.clientCount == 1)
        #expect(quietWatch.pings.withLock { $0 } >= 10, "pinged \(quietWatch.pings.withLock { $0 }) times in 1.5 s")
    }

    // MARK: HTTPS cap

    /// Past the cap an address's next connections are closed at accept, with one log line for all of them; the ones it
    /// holds keep working, and a closed one frees its place.
    @Test func theCapRefusesTheNextConnectionAndLogsOnce() async throws {
        let lines = HTTPSServerLogTests.Lines()
        var limits = HTTPSServer.Limits(perAddress: 2, countsLoopback: true)
        limits.tick = 0.02
        let server = try Self.server(limits: limits, logger: Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) })
        defer { server.stop() }
        let first = try await HTTPSPipeliningTests.start(server)
        let second = try Self.connect(server)
        defer { [first, second].forEach { $0.cancel() } }
        let firstWatch = Self.watch(first)
        #expect(await waitUntil { first.state == .ready && second.state == .ready })

        let refused = try (0..<3).map { _ in try Self.connect(server) }
        defer { refused.forEach { $0.cancel() } }
        let refusedWatches = refused.map { Self.watch($0) }
        #expect(await waitUntil(.seconds(5)) { refusedWatches.allSatisfy(\.hasEnded) })
        let logged = lines.all.withLock { $0 }.filter { $0.contains("refused") }
        #expect(logged == ["HTTPS connection refused: too many open from one address limit=2 peer=127.0.0.1 refused=1"], "\(logged)")

        first.send(content: Data("GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)
        #expect(await waitUntil { firstWatch.hasEnded })
        #expect(firstWatch.received.withLock { $0.starts(with: Data("HTTP/1.1 200".utf8)) })
        let next = try Self.connect(server)
        defer { next.cancel() }
        let nextWatch = Self.watch(next)
        next.send(content: Data("GET /b HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        #expect(await waitUntil { nextWatch.received.withLock { $0.starts(with: Data("HTTP/1.1 200".utf8)) } }, "the freed place is taken")
    }

    /// Loopback is not counted: with an address's table full, the shell's `/healthz` from this Mac is answered.
    @Test func healthzFromThisMacIsAnsweredPastTheCap() async throws {
        let server = try Self.server(limits: HTTPSServer.Limits(perAddress: 1)) { $0.path == "/healthz" ? .text(200, "ok") : nil }
        defer { server.stop() }
        let held = try await HTTPSPipeliningTests.start(server)
        defer { held.cancel() }
        #expect(await waitUntil { held.state == .ready })
        let session = URLSession(configuration: .ephemeral, delegate: StateServerTests.TrustAll(), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(try #require(server.boundPort))/healthz")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    // MARK: CITP

    static func citp(perAddress: Int = 8, stallLimit: Double = 0.3, frame: [UInt8] = CITPServerTests.jpeg, logger: Logger = testLogger) async throws -> (CITPServer, UInt16) {
        let server = CITPServer(
            name: "test", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(
                layers: { [] }, library: CITPServerTests.library, thumbnail: { _ in nil }, frame: { _ in (frame, 320, 180) },
                sources: { [VideoSource(sourceIdentifier: 0, name: "Canvas", width: 320, height: 180)] }),
            logger: logger)
        server.perAddress = perAddress
        server.stallLimit = stallLimit
        try server.start()
        return (server, try await listeningPort { server.status.withLock { $0.port } })
    }

    static let clientInformation = CITPServerTests.msex("CInf", [1, 2, 1])  // MSEX 1.2

    /// Past the cap an address's next CITP connections are closed at accept, with one log line for all of them.
    @Test func theCITPCapRefusesTheNextConnectionAndLogsOnce() async throws {
        let lines = HTTPSServerLogTests.Lines()
        let (server, port) = try await Self.citp(perAddress: 2, logger: Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) })
        defer { server.stop() }
        let consoles = (0..<2).map { _ in CITPServerTests.Client(port: port) }
        defer { consoles.forEach { $0.connection.cancel() } }
        #expect(await waitUntil { server.status.withLock { $0.clients.count } == 2 })
        let refused = (0..<3).map { _ in CITPServerTests.Client(port: port) }
        defer { refused.forEach { $0.connection.cancel() } }
        #expect(await waitUntil { lines.all.withLock { $0 }.contains { $0.contains("refused") } })
        try await Task.sleep(for: .milliseconds(300))  // a negative check: no more lines for the other two
        let logged = lines.all.withLock { $0 }.filter { $0.contains("refused") }
        #expect(logged == ["CITP connection refused: too many open from one address limit=2 peer=127.0.0.1 refused=1"], "\(logged)")
        #expect(server.status.withLock { $0.clients.count } == 2)
        consoles[0].send(Self.clientInformation)
        #expect(await waitUntil { consoles[0].received.withLock { !$0.isEmpty } }, "a console within the cap is served")
    }

    /// A console that sends half a message and stops is closed; one that only listens stays.
    @Test func aCITPSessionHoldingHalfAMessageIsClosed() async throws {
        let (server, port) = try await Self.citp()
        defer { server.stop() }
        let quiet = CITPServerTests.Client(port: port)
        let stalled = CITPServerTests.Client(port: port)
        defer { [quiet, stalled].forEach { $0.connection.cancel() } }
        quiet.send(Self.clientInformation)
        let half = Self.clientInformation + CITPServerTests.msex("GELI", [1, 0, 0, 0, 0, 0, 0])
        stalled.send(Array(half.dropLast(4)))
        #expect(await waitUntil { server.status.withLock { $0.clients.count } == 2 })
        #expect(await waitUntil(.seconds(5)) { server.status.withLock { $0.clients.count } == 1 }, "the stalled session is closed")
        // a negative check needs a fixed window: five times the limit, the quiet console taking the 4 Hz layer status
        try await Task.sleep(for: .seconds(1.5))
        #expect(server.status.withLock { $0.clients.count } == 1)
        #expect(quiet.received.withLock { $0.count } >= 4)
    }

    /// A console that streams and stops reading (or died: its kernel stops taking data) is closed once the server's sends
    /// stop being taken. Before B269 it was never closed and the frames queued in the connection without bound.
    @Test func aCITPConsoleThatStopsReadingIsClosed() async throws {
        let (server, port) = try await Self.citp(frame: [UInt8](repeating: 0xAB, count: 60_000))
        defer { server.stop() }
        // a BSD socket that never reads, with a small receive buffer
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var small: Int32 = 8192
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        #expect(withSockaddr(port: port, host: "127.0.0.1") { Darwin.connect(fd, $0, $1) } == 0, "connect: errno \(errno)")
        let request = Self.clientInformation + CITPServerTests.requestStream(0, width: 320, height: 180, fps: 10)
        #expect(request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } == request.count)
        #expect(await waitUntil { server.status.withLock { $0.streams } == 1 })
        #expect(await waitUntil(.seconds(20)) { server.status.withLock { $0.clients.isEmpty } }, "the session that stopped reading is closed")
    }
}
