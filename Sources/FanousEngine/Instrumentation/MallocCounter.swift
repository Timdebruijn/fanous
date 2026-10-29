// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Counts the allocations one thread makes in a window, through libmalloc's `malloc_logger` hook (B89, B97). The §4.6
/// rule is about the compositor thread; `malloc_zone_statistics` is process-wide, so other threads' (decoders, I/O,
/// other test suites) allocations and frees land in the same window. The hook sees every malloc, calloc, valloc and
/// realloc of every thread and counts those of the measured thread (captured before the hook goes in); frees are not
/// counted. A logger already installed is chained and put back afterwards; windows are serialised.
/// `malloc_logger` is exported by libsystem_malloc but declared only in its private headers, hence `dlsym`.
/// Debug builds allocate where optimised ones do not: unspecialised generics (`Array`'s read accessor,
/// `IndexingIterator`) put their coroutine frames on the heap, so a debug compositor tick makes 137 (Sync off) / 201
/// (masters) allocations that a `-c release` build does not.
public enum MallocCounter {
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
    public static let available = slot != nil
    /// `FANOUS_REQUIRE_MALLOC_COUNTER=1` (set by `scripts/check-mallocs.sh`): a missing hook fails the tests instead of
    /// skipping them, so the release gate cannot pass without measuring.
    public static let availableOrRequired =
        available || ProcessInfo.processInfo.environment["FANOUS_REQUIRE_MALLOC_COUNTER"] == "1"
    /// A semaphore, not a lock: `start` and `stop` may run on different threads (an async caller).
    private static let window = DispatchSemaphore(value: 1)
    private static let hook: Logger = { type, arg1, arg2, arg3, result, skip in
        let state = MallocCounter.state
        // stack_logging_type_alloc (2): malloc, calloc, valloc and the new block of a realloc; frees carry 4|8 (= 12)
        if type & 2 != 0, let thread = state.pointee.thread, pthread_equal(pthread_self(), thread) != 0 {
            state.pointee.count += 1
        }
        state.pointee.previous?(type, arg1, arg2, arg3, result, skip + 1)
    }

    /// The calling thread's allocations while `body` runs.
    public static func count(_ body: () -> Void) -> Int {
        start(thread: pthread_self())
        body()
        return stop()
    }

    /// Starts counting `thread`'s allocations (waits for a window in progress to end); `stop` returns the count.
    /// Requires `available`.
    public static func start(thread: pthread_t) {
        window.wait()
        install(thread)
    }

    public static func stop() -> Int {
        defer { window.signal() }
        return remove()
    }

    // Opaque and unoptimised: the optimiser knows malloc does not touch a Swift global, so with these inlined next to
    // the body (a closure-specialised copy of `count`, even when `count` was `@_optimize(none)`) an optimised build
    // dropped the install as a dead store and returned the 0 it had just written (0 for 100 mallocs with -c release).
    @inline(never) @_optimize(none)
    private static func install(_ thread: pthread_t) {
        let slot = slot!
        state.pointee = State(thread: thread, previous: slot.pointee, count: 0)
        slot.pointee = hook
    }

    @inline(never) @_optimize(none)
    private static func remove() -> Int {
        slot!.pointee = state.pointee.previous
        state.pointee.thread = nil
        return state.pointee.count
    }
}
