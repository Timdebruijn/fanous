// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization

/// Counts the allocations one thread makes in a window, through libmalloc's `malloc_logger` hook (B89, B97). The §4.6
/// rule is about the compositor thread; `malloc_zone_statistics` is process-wide, so other threads' (decoders, I/O,
/// other test suites) allocations and frees land in the same window. The hook sees every malloc, calloc, valloc and
/// realloc of every thread and counts those of the measured thread (captured before the hook goes in); frees are not
/// counted. The measured thread and the one that starts and stops the window may differ (the bench counts the
/// compositor thread from the main thread). The count is exact when the caller synchronises with the measured thread
/// around the window (the tests); otherwise allocations racing `start`/`stop` can be missed or counted, ±a few out of
/// thousands in the bench. A logger already installed is chained and put back afterwards; windows are serialised.
/// `malloc_logger` is exported by libsystem_malloc but declared only in its private headers, hence `dlsym`.
/// Debug builds allocate where optimised ones do not: unspecialised generics (`Array`'s read accessor,
/// `IndexingIterator`) put their coroutine frames on the heap, so a debug compositor tick makes 137 (Sync off) / 201
/// (masters) allocations that a `-c release` build does not.
package enum MallocCounter {
    /// libmalloc's `malloc_logger_t`: type, arg1–3, result, frames to skip.
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    /// The hook runs inside malloc, so it must not allocate: a malloc there recurses. Its state is in `static let`
    /// atomics, not `static var`s: a debug build checks exclusivity on those, and the runtime allocates its per-thread
    /// access set on a thread's first check. `install` touches each before the hook goes in, so their `swift_once`
    /// does not run (and allocate) inside it. `thread` (0 = none) and `previous` hold a `pthread_t` and a `Logger`.
    private static let thread = Atomic<UInt>(0)
    private static let previous = Atomic<UInt>(0)
    private static let allocations = Atomic<Int>(0)
    /// `&malloc_logger`; RTLD_DEFAULT is `(void *)-2`. Nil if libsystem_malloc stops exporting it.
    nonisolated(unsafe) private static let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?
        .assumingMemoryBound(to: Logger?.self)
    /// False: no `malloc_logger` to hook; tests that count gate on `availableOrRequired` and `#require(available)`.
    package static let available = slot != nil
    /// `FANOUS_REQUIRE_MALLOC_COUNTER=1` (set by `scripts/check-mallocs.sh`): a missing hook fails the tests instead of
    /// skipping them, so the release gate cannot pass without measuring.
    package static let availableOrRequired =
        available || ProcessInfo.processInfo.environment["FANOUS_REQUIRE_MALLOC_COUNTER"] == "1"
    /// A semaphore, not a lock: `start` and `stop` may run on different threads (an async caller).
    private static let window = DispatchSemaphore(value: 1)
    private static let hook: Logger = { type, arg1, arg2, arg3, result, skip in
        // stack_logging_type_alloc (2): malloc, calloc, valloc and the new block of a realloc; frees carry 4|8 (= 12)
        if type & 2 != 0, let thread = pthread_t(bitPattern: MallocCounter.thread.load(ordering: .acquiring)),
            pthread_equal(pthread_self(), thread) != 0
        {
            MallocCounter.allocations.wrappingAdd(1, ordering: .relaxed)
        }
        let previous = MallocCounter.previous.load(ordering: .acquiring)
        if previous != 0 { unsafeBitCast(previous, to: Logger.self)(type, arg1, arg2, arg3, result, skip + 1) }
    }

    /// The calling thread's allocations while `body` runs.
    package static func count(_ body: () -> Void) -> Int {
        start(thread: pthread_self())
        body()
        return stop()
    }

    /// Starts counting `thread`'s allocations (waits for a window in progress to end); `stop` returns the count.
    /// Requires `available`.
    package static func start(thread: pthread_t) {
        window.wait()
        install(thread)
    }

    package static func stop() -> Int {
        defer { window.signal() }
        return remove()
    }

    // Opaque and unoptimised: the optimiser knows malloc does not touch a Swift global, so with these inlined next to
    // the body (a closure-specialised copy of `count`, even when `count` was `@_optimize(none)`) an optimised build
    // dropped the install as a dead store and returned the 0 it had just written (0 for 100 mallocs with -c release).
    @inline(never) @_optimize(none)
    private static func install(_ thread: pthread_t) {
        let slot = slot!
        allocations.store(0, ordering: .relaxed)
        previous.store(slot.pointee.map { unsafeBitCast($0, to: UInt.self) } ?? 0, ordering: .releasing)
        self.thread.store(UInt(bitPattern: thread), ordering: .releasing)
        slot.pointee = hook
    }

    @inline(never) @_optimize(none)
    private static func remove() -> Int {
        let previous = previous.load(ordering: .relaxed)
        slot!.pointee = previous == 0 ? nil : unsafeBitCast(previous, to: Logger.self)
        thread.store(0, ordering: .releasing)
        return allocations.load(ordering: .relaxed)
    }
}
