// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// B123: the raw UDP senders never block. A full send buffer cannot be produced reliably on loopback (the kernel
/// delivers there at once), so the socket's `O_NONBLOCK` flag is checked and EAGAIN/ENOBUFS are injected.
struct UDPSendTests {
    static func loopback(port: UInt16) -> sockaddr_in {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr.s_addr = inet_addr("127.0.0.1")
        return sin
    }

    static func failing(_ error: Int32) -> UDPSend.Function {
        { _, _, _, _, _, _ in
            errno = error
            return -1
        }
    }

    @Test func socketIsNonBlocking() {
        let fd = UDPSend.socket()
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
    }

    @Test func aFullBufferDropsAndOtherErrorsFail() {
        let fd = UDPSend.socket()
        defer { close(fd) }
        let to = Self.loopback(port: 9)  // discard; nothing listens
        #expect(UDPSend.send(fd, [1, 2, 3], to: to) == .sent)
        #expect(UDPSend.send(fd, [1, 2, 3], to: to, using: Self.failing(EAGAIN)) == .dropped)
        #expect(UDPSend.send(fd, [1, 2, 3], to: to, using: Self.failing(ENOBUFS)) == .dropped)
        #expect(UDPSend.send(fd, [1, 2, 3], to: to, using: Self.failing(EHOSTUNREACH)) == .failed(EHOSTUNREACH))
    }

    /// The live check's hang: the PLoc beacon on a socket that cannot take a datagram. The beacon is dropped and
    /// counted, and `stop()` (a sync join on the CITP queue) returns at once.
    @Test func citpStopReturnsWhileTheBeaconCannotBeSent() async throws {
        let nonBlocking = Mutex<Bool?>(nil)
        let server = CITPServer(
            name: "full-buffer", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(layers: { [] }, library: CITPServerTests.library, thumbnail: { _ in nil }, frame: { _ in nil }),
            logger: Logger(label: "test"))
        server.sendDatagram = { fd, _, _, _, _, _ in
            nonBlocking.withLock { $0 = fcntl(fd, F_GETFL) & O_NONBLOCK != 0 }
            errno = EAGAIN
            return -1
        }
        try server.start()
        // first beacon 0.5 s after the listener is ready, one datagram per group
        #expect(await waitUntil { server.status.withLock { $0.beaconsDropped } >= 2 })
        #expect(nonBlocking.withLock { $0 } == true)
        let start = Date()
        server.stop()
        #expect(Date().timeIntervalSince(start) < 2)  // a blocked send hangs here for good
    }
}
