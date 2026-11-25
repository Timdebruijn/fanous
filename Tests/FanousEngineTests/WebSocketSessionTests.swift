// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Network
import Synchronization
import Testing

@testable import FanousCore
@testable import FanousEngine

/// `WebSocketSession.feed` with hand-built client frames (RFC 6455 §5.4 fragments, §7.4 close codes). The session sits on
/// the server end of a plain loopback TCP pair, so what it sends (welcome, close frame) is read back as bytes; TLS and the
/// upgrade are StateServerTests' business.
struct WebSocketSessionTests {
    final class Pair: @unchecked Sendable {
        let session: WebSocketSession
        let queue: DispatchQueue
        let listener: NWListener
        let client: NWConnection
        let received = Mutex<[UInt8]>([])

        init(session: WebSocketSession, queue: DispatchQueue, listener: NWListener, client: NWConnection) {
            self.session = session
            self.queue = queue
            self.listener = listener
            self.client = client
        }

        /// Feeds frames on the connection's queue, as `HTTPSServer` does.
        @discardableResult
        func feed(_ frames: [UInt8]...) -> Bool {
            queue.sync {
                var buffer = frames.flatMap { $0 }
                return session.feed(&buffer)
            }
        }

        /// Server frames (never masked) received so far: (opcode, payload).
        var frames: [(opcode: UInt8, payload: [UInt8])] {
            let bytes = received.withLock { $0 }
            var frames: [(UInt8, [UInt8])] = []
            var at = 0
            while bytes.count - at >= 2 {
                var length = Int(bytes[at + 1] & 0x7F)
                var start = at + 2
                if length == 126, bytes.count - at >= 4 {
                    length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                    start = at + 4
                }
                guard length < 126 || start == at + 4, bytes.count - start >= length else { break }
                frames.append((bytes[at] & 0x0F, Array(bytes[start..<start + length])))
                at = start + length
            }
            return frames
        }

        /// The code of the close frame the session sent, nil when none came within the deadline.
        func closeCode() async -> UInt16? {
            await waitUntil(.seconds(5)) { frames.contains { $0.opcode == 8 } }
            guard let close = frames.first(where: { $0.opcode == 8 }), close.payload.count >= 2 else { return nil }
            return UInt16(close.payload[0]) << 8 | UInt16(close.payload[1])
        }

        func texts() -> [JSONValue] {
            frames.filter { $0.opcode == 1 }.compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0.payload))
            }
        }

        private func receive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
                if let data { received.withLock { $0.append(contentsOf: data) } }
                if !complete, error == nil { receive() }
            }
        }

        static func make(
            messageLimit: Int = WebSocketSession.maxMessageBytes, budget: WebSocketSession.ReceiveBudget = .init(limit: 1 << 30)
        ) async throws -> Pair {
            let (store, auth) = testStore()
            let server = StateServer(store: store, auth: auth, caps: ["schema": 1], logger: testLogger)
            let request = try #require(try HTTPRequest.parse(Array("GET /ws HTTP/1.1\r\nHost: x\r\n\r\n".utf8))).request
            let handler = try #require(server.upgrade(request))
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "websocket-session-test")
            let accepted = Mutex<NWConnection?>(nil)
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                accepted.withLock { $0 = connection }
            }
            listener.start(queue: queue)
            try #require(await waitUntil { listener.state == .ready })
            let client = NWConnection(host: "127.0.0.1", port: try #require(listener.port), using: .tcp)
            client.start(queue: queue)
            try #require(await waitUntil { accepted.withLock { $0?.state == .ready } && client.state == .ready })
            let session = WebSocketSession(
                connection: try #require(accepted.withLock { $0 }), remoteAddress: "test", handler: handler, messageLimit: messageLimit, budget: budget)
            session.opened()
            let pair = Pair(session: session, queue: queue, listener: listener, client: client)
            pair.receive()
            return pair
        }

        /// Sends `hello` for `role` and waits for the welcome: the session is past the pre-hello limit (B368). No password
        /// is set here, so every role is granted.
        func greet(_ role: String = "monitor") async throws {
            feed(WebSocketSessionTests.frame(.text, Array(#"{"t":"hello","clientId":"a","schema":1,"role":"\#(role)"}"#.utf8)))
            try #require(await waitUntil { texts().contains { $0["t"]?.string == "welcome" } })
        }

        func stop() {
            session.close()  // idempotent; cancels the accepted connection, which the listener's cancel does not
            client.cancel()
            listener.cancel()
        }
    }

    /// A masked client frame (RFC 6455 §5.3): the server's unmasked encoding with the mask bit and a key added.
    static func frame(_ opcode: WebSocketFrame.Opcode, fin: Bool = true, _ payload: [UInt8]) -> [UInt8] {
        var out = WebSocketFrame(fin: fin, opcode: opcode, payload: payload).serialized()
        out[1] |= 0x80
        out.replaceSubrange((out.count - payload.count)..., with: [0x37, 0xFA, 0x21, 0x3D] + WebSocketFrame.mask(payload, key: (0x37, 0xFA, 0x21, 0x3D)))
        return out
    }

    static let hello = Array(#"{"t":"hello","clientId":"a","schema":1}"#.utf8)

    /// One hello in two frames gets one welcome: delivering each fragment alone would be two bad messages.
    @Test func fragmentedTextIsOneMessage() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        #expect(
            pair.feed(
                Self.frame(.text, fin: false, Array(Self.hello[..<10])),
                Self.frame(.continuation, Array(Self.hello[10...]))))
        await waitUntil { !pair.texts().isEmpty }
        #expect(pair.texts().map { $0["t"]?.string } == ["welcome"])
    }

    @Test func continuationWithoutStartIsAProtocolError() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        #expect(!pair.feed(Self.frame(.continuation, Self.hello)))
        #expect(await pair.closeCode() == 1002)
        #expect(pair.session.isClosed)
    }

    /// RFC 6455 §5.4: a new data frame while a fragmented message is open is a protocol error, not a restart.
    @Test func newMessageInsideAFragmentedOneIsAProtocolError() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        #expect(!pair.feed(Self.frame(.text, fin: false, Array("ignored".utf8)), Self.frame(.text, Self.hello)))
        #expect(await pair.closeCode() == 1002)
        #expect(pair.texts().isEmpty)
    }

    @Test func invalidUTF8IsRefusedWith1007() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        pair.feed(Self.frame(.text, [0x7B, 0xFF, 0xFE, 0x7D]))
        #expect(await pair.closeCode() == 1007)
    }

    /// Each frame is within the message limit (the parser's limit too), the reassembled message is one byte over it. The
    /// session gets a 64 KB limit: the rule is the same as at 16 MB, without building 16 MB in a debug build (B353). Off
    /// the pool all the same: on a one-thread pool this test held the thread for about 3.7 s (measured, cause not traced).
    @Test(.offPool) func fragmentsAboveTheMessageLimitAreRefusedWith1009() async throws {
        #expect(WebSocketSession.maxMessageBytes == 4 * 1024 * 1024)  // the engine's limit (B368); the rule is tested below at 64 KB
        let limit = 64 * 1024
        let pair = try await Pair.make(messageLimit: limit)
        defer { pair.stop() }
        try await pair.greet("operator")  // before hello the limit is 4 KiB, for the monitor 64 KiB (B368)
        let half = [UInt8](repeating: 0x61, count: limit / 2)
        #expect(!pair.feed(Self.frame(.text, fin: false, half), Self.frame(.continuation, fin: false, half), Self.frame(.continuation, [0x61])))
        #expect(await pair.closeCode() == 1009)
    }

    // MARK: B368: receive limits

    /// Before `hello` (the open monitor role costs nothing) a frame of more than 4 KiB closes the connection (1002, the
    /// code of every frame over the limit); after it the same frame is a message like any other. On the old code the
    /// first frame was within the 16 MiB limit.
    @Test func aLargeFrameBeforeHelloIsRefused() async throws {
        let big = Self.frame(.text, [UInt8](repeating: 0x61, count: 5 * 1024))
        let early = try await Pair.make()
        defer { early.stop() }
        #expect(!early.feed(big))
        #expect(await early.closeCode() == 1002)
        let greeted = try await Pair.make()
        defer { greeted.stop() }
        try await greeted.greet()
        #expect(greeted.feed(big))
        #expect(!greeted.session.isClosed)
    }

    /// A fragmented message before `hello` is held to the same 4 KiB.
    @Test func fragmentsBeforeHelloAreHeldToTheSmallLimit() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        let piece = [UInt8](repeating: 0x61, count: 3 * 1024)
        #expect(!pair.feed(Self.frame(.text, fin: false, piece), Self.frame(.continuation, fin: false, piece)))
        #expect(await pair.closeCode() == 1009)
    }

    /// After `hello` a frame over the message limit is refused as its header arrives (64 KB here; 4 MiB in the engine).
    @Test(.offPool) func aFrameAboveTheMessageLimitAfterHelloIsRefused() async throws {
        let limit = 64 * 1024
        let pair = try await Pair.make(messageLimit: limit)
        defer { pair.stop() }
        try await pair.greet("operator")
        let header = Array(Self.frame(.text, [UInt8](repeating: 0x61, count: limit + 1)).prefix(14))  // 127, 8-byte length, key
        #expect(!pair.feed(header))
        #expect(await pair.closeCode() == 1002)
    }

    /// The receive budget: three sessions each trickle a large message, 100 KiB of it so far, against a 250 KiB budget.
    /// The third goes past it and is closed (1009); a small command on a fourth still passes; once the first has gone, a
    /// new partial message fits again. On the old code nothing was counted.
    @Test(.offPool) func theReceiveBudgetRefusesTheSessionThatGoesPastIt() async throws {
        let budget = WebSocketSession.ReceiveBudget(limit: 250 * 1024)
        let partial = Array(Self.frame(.text, [UInt8](repeating: 0x61, count: 1 << 20)).prefix(100 * 1024))
        var pairs: [Pair] = []
        defer { for p in pairs { p.stop() } }
        for _ in 0..<5 {
            let pair = try await Pair.make(budget: budget)
            try await pair.greet("programmer")
            pairs.append(pair)
        }
        #expect(pairs[0].feed(partial))
        #expect(pairs[1].feed(partial))
        #expect(!pairs[2].feed(partial), "the third partial message went past the budget")
        #expect(await pairs[2].closeCode() == 1009)
        #expect(pairs[3].feed(Self.frame(.text, Array(#"{"t":"ping"}"#.utf8))), "a small message passes")
        #expect(!pairs[3].session.isClosed)
        pairs[0].stop()
        #expect(await waitUntil { budget.held.load(ordering: .relaxed) <= 100 * 1024 + 16 })
        #expect(pairs[4].feed(partial), "room again after the first session went")
    }

    /// B368 review: the monitor role needs no password, so its messages are held to 64 KiB and it cannot fill the shared
    /// receive budget with trickled 4 MiB frames; a role behind a password keeps the 4 MiB. On the previous head a monitor
    /// could send 4 MiB.
    @Test func aMonitorMessageAbove64KiBIsRefusedAndAnOperatorsIsNot() async throws {
        let big = Self.frame(.text, [UInt8](repeating: 0x61, count: 65 * 1024))
        let monitor = try await Pair.make()
        defer { monitor.stop() }
        try await monitor.greet("monitor")
        #expect(!monitor.feed(big))
        #expect(await monitor.closeCode() == 1002)
        let op = try await Pair.make()
        defer { op.stop() }
        try await op.greet("operator")
        #expect(op.feed(big))
        #expect(!op.session.isClosed)
    }
}
