# ADR-0021: Multi-server sync over the state connection

Status: Proposed · 2026-10-28 (design only, B60)

## Context
A show can need two Macs for one wide picture (each renders its half with a
blend) or a hot backup. Catalyst-style servers solve this with a master that
publishes its clock over the LAN. The brief for B60 asked for a master
publishing its compositor clock and per-layer media positions over multicast
UDP, every machine resolving the console on its own, and a pushed project
version to keep the machines equal.

## Decision
- A **follower renders what the master resolved**: the master's compositor
  publishes its per-tick `ParameterSnapshotSlot` plus the derived layer
  clocks, loaded media and dissolve state as one binary `SyncFrame`; the
  follower draws that frame on its own displays and does not resolve DMX,
  OSC, MIDI, timecode, cues or UI edits of its own while following.
- The frames travel on the **existing WSS state connection** as a binary
  stream (kind 5), next to the `project` patches that keep the follower's
  mirrored project current. Followers hold a `follower` role token; the
  master's certificate is pinned on first connect; discovery is the existing
  Bonjour record.
- The follower's compositor **ticks on frame arrival** (a semaphore with a
  1.5-period timeout instead of the mach wait), then presents on its own next
  vsync. That bounds the offset to one frame without clock discipline; a
  missing frame is freewheeled with the local `LayerClock`.
- One shared project holds the outputs of all machines, bound by display
  identity and tagged with the owning machine's install UUID; followers
  report their displays and readiness up so a follower's outputs are mapped
  from the master's UI.
- Loss: freewheel, "lost" after the freewheel time, reconnect; **promote** is
  an operator decision (or `onLoss: standalone`), never automatic re-follow.
  A hot backup is a follower whose outputs are disabled until the swap.

## Consequences
+ One source for everything that can diverge; the same mechanism is the
  backup server; no second protocol, no second auth, no multicast on a LAN
  that was never measured for it (B28).
+ Frame cost is a copy into a triple-buffered byte slot on the compositor
  thread and a sender thread per master; ≈ 2.5 Mbit/s per follower at 32
  layers and 60 fps.
− One frame of offset is the floor (no genlock on Macs); a show that needs
  sub-frame alignment across machines needs hardware genlock, which no Mac
  has.
− TCP: a lost packet on a bad cable delays a frame by a retransmit (tens of
  ms); the follower freewheels those ticks. If a measurement on real
  hardware shows this matters, a UDP sender with the same frame format is
  the escape hatch (DESIGN.md OPEN-27).
− The follower's own console input is ignored while following; a show that
  wants per-machine differences (different content on each machine driven
  separately) runs two standalone machines, which is today's behaviour.
