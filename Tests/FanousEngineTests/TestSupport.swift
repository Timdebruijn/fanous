// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousEngine
import Foundation
import Synchronization
import Testing

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

/// One UDP datagram to `host`:`port` from a throwaway socket.
func sendUDP(_ bytes: [UInt8], to port: UInt16, host: String = "127.0.0.1") {
    sendUDP([bytes], to: port, host: host)
}

/// UDP datagrams to `host`:`port`, back-to-back from one throwaway socket (one flow, as a console sends them); `sent`
/// is what `sendto` returned for each. With a `reply` time, `replied` says whether an answer came back to that socket
/// within it.
@discardableResult
func sendUDP(_ datagrams: [[UInt8]], to port: UInt16, host: String = "127.0.0.1", reply: Double = 0) -> (sent: [Int], replied: Bool) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr(host)
    let sent = datagrams.map { bytes in
        withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    guard reply > 0 else { return (sent, false) }
    var wait = timeval(tv_sec: Int(reply), tv_usec: Int32((reply - reply.rounded(.down)) * 1e6))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 1500)
    return (sent, recv(fd, &buffer, buffer.count, 0) > 0)
}

/// A fresh directory `prefix`-<UUID> under the temporary directory.
func tempDir(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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

/// The counter sees allocations of the measured thread, malloc and Swift objects alike, and not those of another thread
/// in the same window. Loops are `while` loops: a `for` over a range allocates in a debug build.
@Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
func mallocCounterCountsOnlyTheMeasuredThread() async throws {
    try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
    final class Other: Sendable { let state = Mutex((stop: false, allocations: 0)) }
    final class Sink { var object: Sink? }
    let other = Other()
    Thread.detachNewThread {
        while !other.state.withLock({ $0.stop }) {
            let block = malloc(16)
            other.state.withLock { $0.allocations += Int(bitPattern: block) & 1 == 0 ? 1 : 0 }  // block used: kept
            free(block)
        }
    }
    defer { other.state.withLock { $0.stop = true } }
    var elsewhere = 0
    let quiet = MallocCounter.count {
        let start = other.state.withLock { $0.allocations }
        let end = ContinuousClock.now + .seconds(5)
        while elsewhere < 1000, ContinuousClock.now < end {
            elsewhere = other.state.withLock { $0.allocations } - start
        }
    }
    #expect(elsewhere >= 1000, "the other thread allocated in the window: \(elsewhere)")
    #expect(quiet == 0, "none of them counted: \(quiet)")

    let blocks = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 100)
    defer { blocks.deallocate() }
    let mallocs = MallocCounter.count {
        var i = 0
        while i < 100 {
            blocks[i] = malloc(16)
            i += 1
        }
    }
    var i = 0
    while i < 100 {
        free(blocks[i])
        i += 1
    }
    #expect(mallocs == 100, "100 mallocs on this thread: \(mallocs)")
    let sink = Sink()
    let objects = MallocCounter.count { sink.object = Sink() }  // swift_allocObject → swift_slowAlloc
    #expect(sink.object != nil)
    #expect(objects == 1, "one Swift object: \(objects)")

    // start(thread:) from another thread (the bench counts the compositor thread from the main thread): the helper's
    // 100 mallocs count, this thread's 50 in the same window do not
    final class Helper: Sendable {
        let thread = Atomic<UInt>(0)
        let ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)  // the window is closed: the helper may free and exit
    }
    let helper = Helper()
    Thread.detachNewThread {
        let blocks = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 100)
        helper.thread.store(UInt(bitPattern: pthread_self()), ordering: .releasing)
        helper.ready.signal()
        helper.go.wait()
        var i = 0
        while i < 100 {
            blocks[i] = malloc(16)
            i += 1
        }
        helper.done.signal()
        helper.closed.wait()
        i = 0
        while i < 100 {
            free(blocks[i])
            i += 1
        }
        blocks.deallocate()
    }
    // The semaphore waits are `noasync` (warned in an async context); the synchronous closure hides that diagnostic,
    // and the waits still block this pool thread. No deadlock: every signal comes from the helper, a `Thread` off the
    // pool.
    let helpers = try { () throws -> Int in
        helper.ready.wait()
        MallocCounter.start(thread: try #require(pthread_t(bitPattern: helper.thread.load(ordering: .acquiring))))
        helper.go.signal()
        var i = 0
        while i < 50 {
            blocks[i] = malloc(16)
            i += 1
        }
        helper.done.wait()
        defer { helper.closed.signal() }
        return MallocCounter.stop()
    }()
    i = 0
    while i < 50 {
        free(blocks[i])
        i += 1
    }
    #expect(helpers == 100, "the helper's 100 mallocs, not this thread's 50: \(helpers)")
}
