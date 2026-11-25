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

/// Connection caps and deadlines of the HTTPS and CITP servers (B269), over loopback with the limits shortened. A check
/// that a connection is closed uses a deadline of a fraction of a second and waits for the close; a check that one
/// stays uses a deadline with about 2 s of margin (a hosted CI runner starves a test for hundreds of milliseconds).
/// The TLS handshake keeps its 30 s deadline: on that runner a handshake took seconds, and a shortened request
/// deadline that counted it cut connections before their first request (PR #412, CI on 08ba10ce).
@Suite(.cleansTempFiles) struct ConnectionLimitTests {
    static let short = HTTPSServer.Limits(request: 0.3, hello: 0.3, ping: 0.05, silent: 0.3, tick: 0.02)
    /// How long a test waits for an event: long, since it costs time only when the event never comes.
    static let wait = Duration.seconds(30)

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

    /// One receive, blocking (for a test body run through `offPool`); nil once the connection ended.
    static func receiveBlocking(_ connection: NWConnection, maximum: Int) -> Data? {
        let result = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
            result.withLock { $0 = isComplete || error != nil ? nil : data }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }
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

    static func uploadServer(limits: HTTPSServer.Limits, logger: Logger = testLogger, sinkDelay: Double = 0) throws -> (HTTPSServer, URL) {
        let dir = try tempDir("upload")
        let server = try Self.server(limits: limits, logger: logger) { _ in nil }
        let files = Mutex(0)
        server.upload = ({ _ in
            if sinkDelay > 0 { Thread.sleep(forTimeInterval: sinkDelay) }  // on the connection's queue, as a slow disk would be
            let file = dir.appending(path: "upload-\(files.withLock { $0 += 1; return $0 }).bin")
            return FileManager.default.createFile(atPath: file.path, contents: nil) ? file : nil
        }, { _, file in .text(202, "stored \((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? -1)") })
        return (server, dir)
    }

    static let uploadSize = HTTPSServer.maxInlineBody + 1 << 20  // 2 MiB
    static let uploadHead = Data("PUT /api/upload/1/clip.mov HTTP/1.1\r\nHost: x\r\nContent-Length: \(uploadSize)\r\n\r\n".utf8)
    static let stored = Data(HTTPResponse.text(202, "stored \(uploadSize)").serialized())

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

        #expect(await waitUntil(Self.wait) { watches.allSatisfy(\.hasEnded) }, "ended: \(watches.map(\.hasEnded))")
        #expect(watches.allSatisfy { $0.received.withLock { $0.isEmpty } }, "closed without an answer")
    }

    /// A TCP connection that never starts TLS is closed by the handshake deadline (here shortened; 30 s by default).
    @Test func aConnectionThatNeverStartsTLSIsClosed() async throws {
        var limits = Self.short
        limits.handshake = 0.3
        let server = try Self.server(limits: limits)
        server.start()
        defer { server.stop() }
        let port = try await listeningPort { server.boundPort }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        let (connected, read) = try await offPool { () -> (Int32, Int) in
            setReceiveTimeout(fd, 30)
            let connected = withSockaddr(port: port, host: "127.0.0.1") { Darwin.connect(fd, $0, $1) }
            var byte: UInt8 = 0
            return (connected, recv(fd, &byte, 1, 0))  // 0: the server closed it; -1: the 30 s ran out
        }
        #expect(connected == 0)
        #expect(read == 0, "recv returned \(read), errno \(errno)")
    }

    /// An upload that stops halfway is closed, its partial file removed, and the log says the deadline cut it (a
    /// warning), not that the client abandoned it.
    @Test func aStalledUploadIsCutAndSaysSo() async throws {
        let lines = HTTPSServerLogTests.Lines()
        let (server, dir) = try Self.uploadServer(limits: Self.short, logger: Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) })
        defer { server.stop() }
        let stalled = try await HTTPSPipeliningTests.start(server)
        defer { stalled.cancel() }
        stalled.send(content: Self.uploadHead + Data(count: Self.uploadSize / 2), completion: .idempotent)
        let watch = Self.watch(stalled)
        #expect(await waitUntil(Self.wait) { watch.hasEnded })
        #expect(await waitUntil(Self.wait) { (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true }, "partial upload removed")
        #expect(await waitUntil(Self.wait) { lines.all.withLock { $0 }.contains { $0.hasPrefix("upload cut: no data from the client; partial file removed") } })
        #expect(!lines.all.withLock { $0 }.contains { $0.contains("abandoned") })
    }

    /// An upload that keeps sending, for longer than the deadline in all, is not cut: the deadline is per chunk.
    /// Deadline 2 s; the body is paced from a thread of its own at 64 KiB every 80 ms (about 2.6 s): a 2 s stall of
    /// the sender or the server would be needed to cut it.
    @Test(.timeLimit(.minutes(1))) func anUploadThatKeepsSendingIsNotCut() async throws {
        var limits = Self.short
        limits.request = 2
        let (server, _) = try Self.uploadServer(limits: limits)
        defer { server.stop() }
        let steady = try await HTTPSPipeliningTests.start(server)
        defer { steady.cancel() }
        let watch = Self.watch(steady)
        steady.send(content: Self.uploadHead, completion: .idempotent)
        try await offPool {
            for _ in 0..<(Self.uploadSize / 65_536) {
                Thread.sleep(forTimeInterval: 0.08)
                steady.send(content: Data(count: 65_536), completion: .idempotent)
            }
        }
        #expect(await waitUntil(Self.wait) { watch.received.withLock { $0 } == Self.stored })
    }

    /// Time the server spends on its own work (here the upload sink, as a slow disk would) is not the client's silence:
    /// the deadline counts from the moment the server is ready to read again. Before the fix the receive's arrival time
    /// was the mark, and a 2 s stall in the server cut a healthy upload at a 1 s deadline. Margin: the rest of the
    /// body is already in the kernel when the server reads again, 1 s before the deadline.
    @Test(.timeLimit(.minutes(1))) func timeTheServerIsBusyIsNotTheClientsSilence() async throws {
        var limits = Self.short
        limits.request = 1
        let (server, _) = try Self.uploadServer(limits: limits, sinkDelay: 2)
        defer { server.stop() }
        let client = try await HTTPSPipeliningTests.start(server)
        defer { client.cancel() }
        let watch = Self.watch(client)
        client.send(content: Self.uploadHead + Data(count: Self.uploadSize), completion: .idempotent)
        #expect(await waitUntil(Self.wait) { watch.received.withLock { $0 } == Self.stored || watch.hasEnded })
        #expect(watch.received.withLock { $0 } == Self.stored, "cut while the server was busy")
    }

    /// A client that reads a large response slowly, for longer than the deadline in all, gets all of it. Deadline 2 s;
    /// the reader takes 1 MiB every 100 ms on a thread of its own (about 3.2 s), so a slice must wait 2 s to cut it.
    @Test(.timeLimit(.minutes(1))) func aSlowReaderGetsTheWholeResponse() async throws {
        let size = 32 << 20
        var limits = Self.short
        limits.request = 2
        let server = try Self.server(limits: limits) { _ in HTTPResponse(status: 200, body: [UInt8](repeating: 7, count: size)) }
        defer { server.stop() }
        let reader = try await HTTPSPipeliningTests.start(server)
        defer { reader.cancel() }
        reader.send(content: Data("GET /big HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        let received = try await offPool {
            var received = 0
            while received < size, let data = Self.receiveBlocking(reader, maximum: 1 << 20) {
                received += data.count
                Thread.sleep(forTimeInterval: 0.1)
            }
            return received
        }
        #expect(received >= size, "a slow reader got \(received) of \(size) bytes")
    }

    /// A client that asks for a large response and does not read is closed once the transport stops taking slices
    /// (before B269 the rest stayed queued for ever, PR #397): the test waits for the server's own close, then reads.
    @Test(.timeLimit(.minutes(1))) func aClientThatStopsTakingAResponseIsClosed() async throws {
        let size = 32 << 20
        let answered = Mutex(false)
        let server = try Self.server { _ in
            answered.withLock { $0 = true }
            return HTTPResponse(status: 200, body: [UInt8](repeating: 7, count: size))
        }
        defer { server.stop() }
        let stuck = try await HTTPSPipeliningTests.start(server)
        defer { stuck.cancel() }
        stuck.send(content: Data("GET /big HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        #expect(await waitUntil(Self.wait) { answered.withLock { $0 } })
        #expect(await waitUntil(Self.wait) { server.openConnections == 0 }, "the server closed the connection")
        let watch = Self.watch(stuck, maximum: 8 << 20)
        #expect(await waitUntil(Self.wait) { watch.hasEnded })
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
        #expect(await waitUntil(Self.wait) { watch.hasEnded })
        #expect(watch.received.withLock { $0.starts(with: Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)) })
        #expect(stateServer.store.clientCount == 0)
    }

    /// A client that says nothing after its hello but answers pings (a browser does, by itself) stays for longer than
    /// the silence limit; one that answers none is closed and its session, with its subscriptions, is gone. Silence
    /// limit 2 s, a ping every 100 ms: the quiet client survives a 1.9 s delay of its pongs.
    @Test func aQuietClientStaysAndADeadOneIsClosed() async throws {
        let (server, stateServer) = try HTTPSPipeliningTests.stateServer()
        server.limits = HTTPSServer.Limits(hello: 2, ping: 0.1, silent: 2, tick: 0.05)
        defer { server.stop() }
        let quiet = try await HTTPSPipeliningTests.start(server)
        let dead = try Self.connect(server)
        defer { [quiet, dead].forEach { $0.cancel() } }
        let hello = HTTPSPipeliningTests.upgrade(port: try #require(server.boundPort)) + Data(WebSocketSessionTests.frame(.text, WebSocketSessionTests.hello))
        let quietWatch = Self.watch(quiet, pong: true)
        let deadWatch = Self.watch(dead)
        quiet.send(content: hello, completion: .idempotent)
        dead.send(content: hello, completion: .idempotent)
        #expect(await waitUntil(Self.wait) { stateServer.store.clientCount == 2 })

        #expect(await waitUntil(Self.wait) { deadWatch.hasEnded }, "a client that answers no ping is closed")
        #expect(await waitUntil(Self.wait) { stateServer.store.clientCount == 1 })
        // 30 pings at one per 100 ms: the quiet client has been silent but for its pongs for 3 s, past the limit
        #expect(await waitUntil(Self.wait) { quietWatch.pings.withLock { $0 } >= 30 })
        #expect(!quietWatch.hasEnded)
        #expect(stateServer.store.clientCount == 1)
    }

    // MARK: HTTPS cap

    /// Past the cap an address's next connections are closed at accept, with one log line for all of them and a
    /// count in `refusedConnections`; the ones it holds keep working, and a closed one frees its place.
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
        #expect(await waitUntil(Self.wait) { first.state == .ready && second.state == .ready })

        let refused = try (0..<3).map { _ in try Self.connect(server) }
        defer { refused.forEach { $0.cancel() } }
        let refusedWatches = refused.map { Self.watch($0) }
        #expect(await waitUntil(Self.wait) { refusedWatches.allSatisfy(\.hasEnded) })
        let logged = lines.all.withLock { $0 }.filter { $0.contains("refused") }
        #expect(
            logged == ["HTTPS connection refused: too many open from one address (one line a minute, refused counts every address) limit=2 peer=127.0.0.1 refused=1"],
            "\(logged)")
        #expect(server.refusedConnections == 3)

        first.send(content: Data("GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)
        #expect(await waitUntil(Self.wait) { firstWatch.hasEnded })
        #expect(firstWatch.received.withLock { $0.starts(with: Data("HTTP/1.1 200".utf8)) })
        // the client sees the close before the server's `.cancelled` has released the place
        #expect(await waitUntil(Self.wait) { server.openConnections == 1 })
        let next = try Self.connect(server)
        defer { next.cancel() }
        let nextWatch = Self.watch(next)
        next.send(content: Data("GET /b HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .idempotent)
        #expect(await waitUntil(Self.wait) { nextWatch.received.withLock { $0.starts(with: Data("HTTP/1.1 200".utf8)) } }, "the freed place is taken")
    }

    /// The default path: loopback is not counted, so with an address's table full the shell's `/healthz` from this Mac
    /// is answered.
    @Test func healthzFromThisMacIsAnsweredPastTheCap() async throws {
        let server = try Self.server(limits: HTTPSServer.Limits(perAddress: 1)) { $0.path == "/healthz" ? .text(200, "ok") : nil }
        defer { server.stop() }
        let held = try await HTTPSPipeliningTests.start(server)
        defer { held.cancel() }
        #expect(await waitUntil(Self.wait) { held.state == .ready })
        let session = URLSession(configuration: .ephemeral, delegate: StateServerTests.TrustAll(), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(try #require(server.boundPort))/healthz")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.refusedConnections == 0)
    }

    // MARK: CITP

    static func citp(
        perAddress: Int = 8, stallLimit: Double = 0.3, frame: [UInt8] = CITPServerTests.jpeg, thumbnail: @escaping @Sendable (String) -> [UInt8]? = { _ in nil },
        logger: Logger = testLogger
    ) async throws -> (CITPServer, UInt16) {
        let server = CITPServer(
            name: "test", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(
                layers: { [] }, library: CITPServerTests.library, thumbnail: thumbnail, frame: { _ in (frame, 320, 180) },
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
        #expect(await waitUntil(Self.wait) { server.status.withLock { $0.clients.count } == 2 })
        let refused = (0..<3).map { _ in CITPServerTests.Client(port: port) }
        defer { refused.forEach { $0.connection.cancel() } }
        #expect(await waitUntil(Self.wait) { server.status.withLock { $0.refused } == 3 })
        let logged = lines.all.withLock { $0 }.filter { $0.contains("refused") }
        #expect(
            logged == ["CITP connection refused: too many open from one address (one line a minute, refused counts every address) limit=2 peer=127.0.0.1 refused=1"],
            "\(logged)")
        #expect(server.status.withLock { $0.clients.count } == 2)
        consoles[0].send(Self.clientInformation)
        #expect(await waitUntil(Self.wait) { consoles[0].received.withLock { !$0.isEmpty } }, "a console within the cap is served")
    }

    /// A console that sends half a message and stops is closed.
    @Test func aCITPSessionHoldingHalfAMessageIsClosed() async throws {
        let (server, port) = try await Self.citp()
        defer { server.stop() }
        let stalled = CITPServerTests.Client(port: port)
        defer { stalled.connection.cancel() }
        let half = Self.clientInformation + CITPServerTests.msex("GELI", [1, 0, 0, 0, 0, 0, 0])
        stalled.send(Array(half.dropLast(4)))
        #expect(await waitUntil(Self.wait) { stalled.received.withLock { !$0.isEmpty } }, "negotiated: the stall check runs")
        #expect(await waitUntil(Self.wait) { server.status.withLock { $0.clients.isEmpty } }, "the stalled session is closed")
    }

    /// A console that only listens stays. Limit 2 s; the 14 layer status messages it waits for span 3.5 s at 4 Hz, and
    /// it takes each as it comes, so a 2 s stall in taking them would be needed to close it.
    @Test func aQuietCITPConsoleStays() async throws {
        let (server, port) = try await Self.citp(stallLimit: 2)
        defer { server.stop() }
        let quiet = CITPServerTests.Client(port: port)
        defer { quiet.connection.cancel() }
        quiet.send(Self.clientInformation)
        #expect(await waitUntil(Self.wait) { quiet.received.withLock { $0.count } >= 15 })  // SInf + 14 layer status
        #expect(server.status.withLock { $0.clients.count } == 1)
    }

    /// Time the server spends on a request (a slow thumbnail) is not the console's silence: a session that holds half
    /// of the next message while the server is busy, and sends the rest once answered, stays. Before, the stall clock
    /// was the arrival of the bytes, and the first status tick after a 4 s stall closed the session at a 2 s limit.
    /// Margin: the rest is sent from a thread of its own as soon as the thumbnail arrives, 2 s before the limit.
    @Test(.timeLimit(.minutes(1))) func timeTheCITPServerIsBusyIsNotTheConsolesSilence() async throws {
        let (server, port) = try await Self.citp(stallLimit: 2, thumbnail: { name in
            Thread.sleep(forTimeInterval: 4)  // on the CITP queue, as a slow disk would be
            return name == "intro.jpg" ? CITPServerTests.jpeg : nil
        })
        defer { server.stop() }
        let console = CITPServerTests.Client(port: port)
        defer { console.connection.cancel() }
        console.send(Self.clientInformation)
        #expect(await waitUntil(Self.wait) { !console.received.withLock { $0.isEmpty } })  // SInf: negotiated
        let thumbnail = CITPServerTests.msex("GETh", Array("JPEG".utf8) + [0x40, 0x01, 0xB4, 0x00, 0, 1, 1, 0, 0, 0, 1, 0, 0])
        let next = CITPServerTests.msex("GELI", [1, 0, 0, 0, 0, 0, 0])
        console.send(thumbnail + next.prefix(10))
        let eThn = Array("EThn".utf8)
        let answered = try await offPool { () -> Bool in
            let end = Date().addingTimeInterval(30)
            while Date() < end {
                if console.received.withLock({ $0.contains { $0.count > 26 && Array($0[22..<26]) == eThn } }) {
                    console.send(Array(next.dropFirst(10)))
                    return true
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return false
        }
        #expect(answered, "the thumbnail came")
        let eLIn = Array("ELIn".utf8)
        #expect(await waitUntil(Self.wait) { console.received.withLock { $0.contains { $0.count > 26 && Array($0[22..<26]) == eLIn } } }, "the rest was read")
        #expect(server.status.withLock { $0.clients.count } == 1)
    }

    /// A console that streams and stops reading (or died: its kernel stops taking data) is closed once the server's sends
    /// stop being taken. Before B269 it was never closed and the frames queued in the connection without bound.
    @Test func aCITPConsoleThatStopsReadingIsClosed() async throws {
        let (server, port) = try await Self.citp(frame: [UInt8](repeating: 0xAB, count: 60_000))
        defer { server.stop() }
        // a BSD socket that never reads, with a small receive buffer
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        let request = Self.clientInformation + CITPServerTests.requestStream(0, width: 320, height: 180, fps: 10)
        let (connected, sent) = try await offPool {
            var small: Int32 = 8192
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
            let connected = withSockaddr(port: port, host: "127.0.0.1") { Darwin.connect(fd, $0, $1) }
            return (connected, request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) })
        }
        #expect(connected == 0, "connect: errno \(errno)")
        #expect(sent == request.count)
        #expect(await waitUntil(Self.wait) { server.status.withLock { $0.streams } == 1 })
        #expect(await waitUntil(Self.wait) { server.status.withLock { $0.clients.isEmpty } }, "the session that stopped reading is closed")
    }
}
