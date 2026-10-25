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
  a test (`malloc_zone_statistics` over 1 000 frames).
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
