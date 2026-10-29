# ADR-0002: Threading model

Status: Accepted · 2026-10-22

## Context
Frame-exact output and sub-frame DMX latency do not tolerate scheduler
surprises. Swift Concurrency gives no control over which thread runs when,
and actors/async hops allocate and can be delayed by unrelated work.

## Decision
- Render (compositor + one thread per output display), decode (one per
  layer + a HAP chunk pool), DMX receive/resolve, audio and timecode run on
  dedicated `Thread`s or dedicated serial queues at `.userInteractive` /
  real-time priority. Network.framework forces a `DispatchQueue` for DMX; it
  is a dedicated serial queue and nothing else runs on it.
- Hand-off between domains: SPSC rings and triple buffers with
  acquire/release atomics; immutable config snapshots swapped by pointer.
  No locks on the render or DMX path. Control (project model, commands) is
  a single serial queue and the only place that allocates freely.
- Steady state: zero heap allocations on the compositor thread, verified by
  a test (`malloc_zone_statistics` over 1 000 frames). Restated by the
  2026-10-29 amendment below.
- Swift 6 language mode everywhere. The ring/triple-buffer types are the
  only `@unchecked Sendable` and carry a comment naming the invariant.
- Swift Concurrency is allowed on the Control/network side where it does not
  touch render data directly (e.g. ingest job orchestration), but not in
  `FanousCore` protocol parsers (they are called from the DMX queue).

## Consequences
+ Deterministic latency; instrumentation can attribute every microsecond.
− More code than actors; the ring types need careful review and tests.
− If Network.framework's queue delivery proves too jittery for DMX, a BSD
  socket thread replaces it for Art-Net/sACN only (new ADR).

## Amendment 2026-10-28 (B71): one bounded lock for non-render parameter readers

The parameter triple buffer has one reader, the compositor. CITP layer status and
secondary displays read the parameters too. When they called the reader side
themselves, they could hand the writer the slot the compositor was drawing from.
They now read a copy of each published snapshot, kept behind one lock. This is
the only lock a render or DMX thread waits on; the compositor's other `Mutex`es
are try-locks (`withLockIfAvailable`):

- `Mutex` from the `Synchronization` module (`os_unfair_lock`, which donates
  priority to the holder).
- Critical section: a fixed-size copy of the snapshot, with no allocation
  (readers reserve their arrays before taking it). About 0.4 µs for
  32 layers and 8 outputs in a release build.
- Taken by the DMX writer once per published snapshot, by CITP at 4 Hz, and by
  each Output-N thread once per frame.
- The compositor thread never takes it. It reads the triple buffer with
  `read()` once per tick, and the preview tap uses `current()`, both lock-free.

## Amendment 2026-10-29 (B97): what "zero allocations" covers

`malloc_zone_statistics` counts the whole process, not the compositor thread.
Since B89 the count comes from a `malloc_logger` hook (`MallocCounter`) that
counts only the measured thread. Since B97 the benchmark counts the compositor
thread with the same hook, and with GPU work that count is not 0. The rule is
now:

- **The tick's own work allocates 0** in steady state. `scripts/check-mallocs.sh`
  checks it in an optimised build, without GPU encoding.
- **Metal API objects add allocations on every tick**, and the Metal 3 API
  cannot avoid them: 2 per `makeCommandBuffer()`, 2 for the first
  `makeRenderCommandEncoder(descriptor:)` and 3 for each further one, and 1 per
  `addCompletedHandler`.
- **Our completion closure adds 2.** B105 tracks removing it.

The minimum is 7 per tick (headless, one canvas, no output pass, no previews).
DESIGN.md §4.6 lists what each feature adds.

## Amendment 2026-10-29 (B105): completion bookkeeping on the compositor thread

The compositor registers no completion handler any more (it cost 1 for
`addCompletedHandler` and 2 for its closure per tick). It keeps each committed
command buffer in a fixed ring of 8, and later ticks poll their status and book
GPU time, late flags and the counters on the compositor thread, with 0
allocations. The minimum is now 4 per tick (headless, one canvas, no output
pass, no previews).

When the ring is full (the GPU 8 ticks behind), the compositor thread blocks in
`waitUntilCompleted` on the oldest buffer, and `/metrics` counts it as
`completionWaits`. Only headless or offscreen ticking can get there: the
display paths cap at 3 drawables in flight.
