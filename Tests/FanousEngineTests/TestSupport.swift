// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Runs blocking AVFoundation work (`AVAssetWriter.finishWriting` + semaphore, `LibraryIndex.probeMovie`) on a thread of its
/// own. Swift Testing runs a test per core on the cooperative pool; with every pool thread parked in such a wait the
/// completion never arrives and the run hangs (B63). Likely mechanism: the completion is queued on the default-QoS global
/// queue (`com.apple.root.default-qos`), which gets no worker thread while all pool threads at that QoS are blocked.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// Polls `condition` every `every` until it holds or `deadline` has passed; true = it held. For "eventually" checks: a
/// fixed sleep before an assertion encodes how fast this Mac is, and a loaded one (other builds, a parallel run) is
/// slower (B67). Negative checks ("nothing happened") still need a fixed window: there is nothing to poll for.
func waitUntil(_ deadline: Duration = .seconds(10), every: Duration = .milliseconds(10), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + deadline
    while !condition() {
        guard ContinuousClock.now < end, (try? await Task.sleep(for: every)) != nil else { return condition() }
    }
    return true
}

/// A UDP port that is free right now: bind port 0 exclusively (no SO_REUSEADDR/SO_REUSEPORT), read back the port the
/// kernel assigned, release it. Unlike a random pick, it never lands on a port another socket holds; Network.framework
/// listeners share ports, so such a port would cross-talk silently. Still check-then-release: the window is short.
func freeUDPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    guard ok else { throw POSIXError(.EADDRINUSE) }
    return UInt16(bigEndian: address.sin_port)
}

/// One UDP datagram to 127.0.0.1:`port` from a throwaway socket.
func sendUDP(_ bytes: [UInt8], to port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// A socket on 127.0.0.1:`port` whose `receive` waits at most `timeout` seconds; nil = nothing came.
final class UDPCatcher {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    init(port: UInt16, timeout: Double) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    }
    deinit { close(fd) }
    func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 1500)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : nil
    }
}
