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
