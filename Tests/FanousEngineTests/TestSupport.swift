// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

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

/// Counts the allocations the calling thread makes while `body` runs, through libmalloc's `malloc_logger` hook
/// (B89). The §4.6 rule is about the compositor thread; `malloc_zone_statistics` is process-wide, so in a parallel run
/// other suites' allocations and frees land in the same window. The hook sees every malloc, calloc, valloc and realloc
/// of every thread and counts those of the thread that called `count` (captured before the hook goes in); frees are
/// not counted. A logger already installed is chained and put back afterwards; windows are serialised.
/// `malloc_logger` is exported by libsystem_malloc but declared only in its private headers, hence `dlsym`.
/// Debug builds allocate where optimised ones do not: unspecialised generics (`Array`'s read accessor,
/// `IndexingIterator`) put their coroutine frames on the heap, so a debug compositor tick makes 137 (Sync off) / 201
/// (masters) allocations that a `-c release` build does not.
enum MallocCounter {
    /// libmalloc's `malloc_logger_t`: type, arg1–3, result, frames to skip.
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    /// The hook runs inside malloc, so it must not allocate: a malloc there recurses. Its state is behind a raw
    /// pointer, not in `static var`s: a debug build checks exclusivity on those, and the runtime allocates its
    /// per-thread access set on a thread's first check. The statics are initialised before the hook goes in, so their
    /// `swift_once` does not run (and allocate) inside it.
    struct State {
        var thread: pthread_t?
        var previous: Logger?
        var count = 0
    }
    nonisolated(unsafe) private static let state: UnsafeMutablePointer<State> = {
        let p = UnsafeMutablePointer<State>.allocate(capacity: 1)
        p.initialize(to: State())
        return p
    }()
    /// `&malloc_logger`; RTLD_DEFAULT is `(void *)-2`. Nil if libsystem_malloc stops exporting it.
    nonisolated(unsafe) private static let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?
        .assumingMemoryBound(to: Logger?.self)
    /// False: no `malloc_logger` to hook; tests that count gate on `availableOrRequired` and `#require(available)`.
    static let available = slot != nil
    /// `FANOUS_REQUIRE_MALLOC_COUNTER=1` (set by `scripts/check-mallocs.sh`): a missing hook fails the tests instead of
    /// skipping them, so the release gate cannot pass without measuring.
    static let availableOrRequired =
        available || ProcessInfo.processInfo.environment["FANOUS_REQUIRE_MALLOC_COUNTER"] == "1"
    private static let lock = NSLock()
    private static let hook: Logger = { type, arg1, arg2, arg3, result, skip in
        let state = MallocCounter.state
        // stack_logging_type_alloc (2): malloc, calloc, valloc and the new block of a realloc; frees carry 4|8 (= 12)
        if type & 2 != 0, let thread = state.pointee.thread, pthread_equal(pthread_self(), thread) != 0 {
            state.pointee.count += 1
        }
        state.pointee.previous?(type, arg1, arg2, arg3, result, skip + 1)
    }

    static func count(_ body: () -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        install()
        body()
        return remove()
    }

    // Opaque and unoptimised: the optimiser knows malloc does not touch a Swift global, so with these inlined next to
    // the body (a closure-specialised copy of `count`, even when `count` was `@_optimize(none)`) an optimised build
    // dropped the install as a dead store and returned the 0 it had just written (0 for 100 mallocs with -c release).
    @inline(never) @_optimize(none)
    private static func install() {
        let slot = slot!
        state.pointee = State(thread: pthread_self(), previous: slot.pointee, count: 0)
        slot.pointee = hook
    }

    @inline(never) @_optimize(none)
    private static func remove() -> Int {
        slot!.pointee = state.pointee.previous
        state.pointee.thread = nil
        return state.pointee.count
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
}
