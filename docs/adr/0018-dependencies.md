# ADR-0018: Dependency and vendoring policy

Status: Proposed · 2026-10-22

## Context
The brief allows only hap + Snappy, Syphon, and Apple's swift-collections,
swift-atomics, swift-log in the server; protocols are implemented in-house;
NDI/DeckLink only via plugins; no FFmpeg, no web frameworks. Verified
2026-10-22 (details in `docs/licensing/DEPENDENCIES.md`): hap is BSD-2 with
no commits since 2024-07; Snappy 1.3.1 BSD-3; Syphon has no tagged release
since 2019 but an active `main` with Metal support; swift-atomics' README
says it is superseded by the stdlib `Synchronization` module (macOS 15+).

## Decision
- C/ObjC code is vendored as SPM targets pinned to commit SHAs recorded in
  `DEPENDENCIES.md` with their license files; updates are deliberate PRs.
- Swift packages: `swift-log` (logging). `swift-collections` only if a
  concrete need appears (Deque/Heap); not added speculatively.
  `swift-atomics` only if the minimum macOS stays at 14 (see ADR-0020).
- Everything else (Art-Net, sACN, OSC, CITP, GDTF, LTC, MTC, HTTP/1.1,
  WebSocket, X.509 writer, QuickTime demux fallback) is in-house, in Core,
  unit-tested with captures.
- Web: exact-pinned build-time dependencies (Svelte, Vite, Vitest,
  TypeScript); the shipped bundle contains only the Svelte runtime (MIT).
- Adding any dependency requires a `DEPENDENCIES.md` row (CI checks the
  lockfiles against it).

## Consequences
+ Small, auditable surface; GPL compatibility documented per item.
− We own fixes in vendored code (hap especially); fuzz tests on its inputs.
