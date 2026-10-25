# ADR-0020: Minimum macOS version 15

Status: Accepted · 2026-10-22 (owner approved: minimum macOS 15)

## Context
The brief fixes macOS 14 as the minimum because of `CAMetalDisplayLink`
(14+). Verified 2026-10-22: the current release is macOS 27.0.1; macOS 14
Sonoma's last update was 14.8.9 (Aug 2026) and it is absent from the Sep
2026 security batches, i.e. outside Apple's n-2 support window. The Swift
stdlib `Synchronization` module (`Atomic`, `Mutex`) needs macOS 15 and
replaces `swift-atomics` (per that package's own README). Metal 4 needs
macOS 26 and is not required by this design.

## Decision (proposed)
Set the deployment target to **macOS 15**. Use `Synchronization` for all
atomics and the rare mutex on Control; drop `swift-atomics`. Keep Metal 3
APIs only. Supported matrix: macOS 15, 26, 27 (and later).

## Consequences
+ One dependency fewer in the hottest code; a test matrix of three
  supported, security-patched releases.
− A show machine still on Sonoma would need an update before running
  Fanous. If the owner prefers to keep 14, `swift-atomics` 1.3.1 is used
  and the matrix includes an unpatched OS.
