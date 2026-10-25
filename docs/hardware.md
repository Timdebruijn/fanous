# Hardware capability table

Source for `FanousCore/Capabilities`. Runtime detection (chip name, cores,
memory, GPU, displays, hardware ProRes) is authoritative; this table only adds
what macOS does not expose: media-engine count and Apple's external-display
limit. Cells marked *unverified* were not confirmed from an Apple page on
2026-10-22 and must be checked before the tier is shown as "Apple spec".

| Chip | Tier | ProRes engines | Max external displays | Memory bandwidth GB/s | Verification |
|---|---|---|---|---|---|
| M1 | unsupported (no ProRes engine) | 0 | — | 68 | Apple (no engine) |
| M1 Pro | 2 Pro | 1 | 2 | ~200 | engines/displays *unverified* (secondary sources) |
| M1 Max | 3 Max | 2 | 4 | ~400 | secondary sources |
| M1 Ultra | 4 Ultra | 4 | 5 | 800 | secondary sources |
| M2 | 1 Base | 1 | 2 (per Mac model) | ~100 | secondary |
| M2 Pro | 2 Pro | 1 | 2–3 (per Mac model) | ~200 | *unverified* |
| M2 Max | 3 Max | 2 | 4 | ~400 | secondary |
| M2 Ultra | 4 Ultra | 4 | up to 6 (Apple, Pro Display XDR) | 800 | Apple (bandwidth, displays) |
| M3 | 1 Base | 1 | 2 (per Mac model) | ~100 | secondary |
| M3 Pro | 2 Pro | 1 | 2 | 150 | *unverified* engines |
| M3 Max | 3 Max | 2 | 4 | 300/400 | Apple (engines) |
| M3 Ultra | 4 Ultra | 4 | 8 | 819 | secondary |
| M4 | 1 Base | 1 | 1–2 (per Mac model) | 120 | Apple (bandwidth) |
| M4 Pro | 2 Pro | 1 | 2–3 | 273 | *unverified* engines |
| M4 Max | 3 Max | 2 | 4 | 410/546 | Apple ("two ProRes accelerators") |
| M5 | 1 Base | 1 | 2 | 153 | Apple (displays, bandwidth) |
| M5 Pro | 2 Pro | 1 | 3 | 307 | Apple (regional spec) |
| M5 Max | 3 Max | 2 | 4 (MBP) / 5 (Studio) | 460/614 | Apple |
| M5 Ultra | 4 Ultra | 4 | 8 | 1200 | Apple (single source) |
| unknown | conservative = Base | 1 | 1 | — | UI shows "unknown chip, run the benchmark" |

Apple publishes display limits per Mac model, not per chip; the engine
therefore reports "Apple spec for this Mac model where known" and always
shows the *currently connected* displays as ground truth.
