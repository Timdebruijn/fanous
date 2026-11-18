// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Network
import Synchronization
import Testing

@testable import FanousEngine

struct HTTPSPipeliningTests {
    /// The body for request `/r/<i>`: 1 MiB, its index in the first bytes so an out-of-order reply shows.
    static func body(_ i: Int) -> [UInt8] {
        let tag = Array("response \(i)\n".utf8)
        return tag + [UInt8](repeating: UInt8(truncatingIfNeeded: i), count: (1 << 20) - tag.count)
    }

    /// The bytes the server sends for `/r/<i>`: the route's response plus the two headers every response gets.
    static func expected(_ i: Int) -> [UInt8] {
        HTTPResponse(
            status: 200, headers: [HTTPHeader("Server", "fanousd/\(FanousVersion.string)"), HTTPHeader("X-Content-Type-Options", "nosniff")],
            body: body(i)
        ).serialized()
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
        server.start()
        defer { server.stop() }
        #expect(await waitUntil { server.boundPort != nil })
        let port = try #require(server.boundPort)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: .init()))
        connection.start(queue: .global())
        defer { connection.cancel() }
        let requests = (0..<count).map { "GET /r/\($0) HTTP/1.1\r\nHost: x\r\n\($0 == count - 1 ? "Connection: close\r\n" : "")\r\n" }
        connection.send(content: Data(requests.joined().utf8), completion: .idempotent)

        #expect(await waitUntil { parsed.withLock { $0 } > 0 })
        // a negative check needs a fixed window: the old code ran the route for all 64 within milliseconds
        #expect(!(await waitUntil(.seconds(1)) { parsed.withLock { $0 } == count }))
        let whileNotReading = parsed.withLock { $0 }
        #expect(whileNotReading < count / 4, "route ran \(whileNotReading) times for a client that does not read")

        var received = Data()
        while true {
            let (data, done) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data { received.append(data) }
            if done { break }
        }
        let all = (0..<count).flatMap(Self.expected)
        #expect(received.count == all.count)
        #expect(received == Data(all))
        #expect(parsed.withLock { $0 } == count)
    }
}
