// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Network
import Synchronization
import Testing

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

        static func make() async throws -> Pair {
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
                connection: try #require(accepted.withLock { $0 }), remoteAddress: "test", handler: handler)
            session.opened()
            let pair = Pair(session: session, queue: queue, listener: listener, client: client)
            pair.receive()
            return pair
        }

        func stop() {
            session.close()  // idempotent; cancels the accepted connection, which the listener's cancel does not
            client.cancel()
            listener.cancel()
        }
    }

    /// A masked client frame (RFC 6455 §5.3), built by `WebSocketFrame`'s own client encoder.
    static func frame(_ opcode: WebSocketFrame.Opcode, fin: Bool = true, _ payload: [UInt8]) -> [UInt8] {
        WebSocketFrame(fin: fin, opcode: opcode, payload: payload).serializedMasked(key: (0x37, 0xFA, 0x21, 0x3D))
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

    /// Each frame is within `maxMessageBytes` (the parser's limit), the reassembled message is one byte over it.
    @Test func fragmentsAboveTheMessageLimitAreRefusedWith1009() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }
        // 8 MB frames by hand with a zero mask key: `serializedMasked` would mask 16 MB in a debug build
        let half = WebSocketSession.maxMessageBytes / 2
        func large(_ first: UInt8) -> [UInt8] {
            [first, 0xFF] + withUnsafeBytes(of: UInt64(half).bigEndian, Array.init) + [0, 0, 0, 0]
                + [UInt8](repeating: 0x61, count: half)
        }
        let start = ContinuousClock.now
        #expect(!pair.feed(large(0x01), large(0x00), Self.frame(.continuation, [0x61])))
        #expect(await pair.closeCode() == 1009)
    }
}
