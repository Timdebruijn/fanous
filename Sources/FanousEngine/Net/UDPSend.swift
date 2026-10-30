// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Darwin

/// The engine's raw UDP senders (CITP PLoc, sync) never block (B123): the socket is `O_NONBLOCK`, and a datagram the
/// kernel cannot take at once (a full send buffer, a stalled interface) is dropped and counted by the caller, so a
/// stuck network path cannot hold a queue or thread that a `stop()` waits on.
enum UDPSend {
    /// `sendto`'s shape, so tests can inject a full buffer.
    typealias Function = (Int32, UnsafeRawPointer?, Int, Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int

    enum Outcome: Equatable {
        case sent
        /// EAGAIN (= EWOULDBLOCK) or ENOBUFS: no room right now, the datagram is gone.
        case dropped
        case failed(Int32)
    }

    /// An IPv4 datagram socket with `O_NONBLOCK`; -1 (errno set) when either step fails.
    static func socket() -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let error = errno
            close(fd)
            errno = error
            return -1
        }
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8], to address: sockaddr_in, using sendto: Function = Darwin.sendto) -> Outcome {
        var address = address
        let sent = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if sent >= 0 { return .sent }
        let error = errno
        return error == EAGAIN || error == ENOBUFS ? .dropped : .failed(error)
    }
}
