# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-10-23T13:55:21Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 6 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: dissolve2s

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 8 | 1204 | 0 | 0 | 0 | 0.12 / 0.51 / 0.88 | 0.04 / 4.11 / 4.41 | -7406 / -1177 | pass |
