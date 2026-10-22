# ADR-0013: Snapshot + revisioned JSON patches, commands with acks, global undo

Status: Proposed · 2026-10-22

## Context
Several clients must always show the same state; the server is the only
source of truth; UI traffic must never slow rendering.

## Decision
- Two documents, `project` (persisted) and `live` (runtime). Clients get a
  snapshot on connect and RFC 6902 patches with a monotonically increasing
  revision afterwards; a gap triggers a re-snapshot.
- Every mutation is a named command executed on Control with validation,
  inverse (undo), patch generation and auto-save. One global undo history.
- `live` patches are coalesced per path and sent at 20 Hz; per-client queues
  are bounded; overflow drops `live` patches (client re-snapshots `live`)
  but never `project` patches (client is disconnected instead).
- Bandwidth-heavy data (DMX monitor, previews, thumbnails, metrics pages)
  is subscription-based binary framing on the same socket.
- Show lock rejects config commands with a typed error.

## Consequences
+ Simple mental model, trivially testable in Core (pure functions on
  documents).
− JSON text for `project` is verbose; acceptable (projects are small). A
  binary encoding can be added behind the same revision scheme later.
