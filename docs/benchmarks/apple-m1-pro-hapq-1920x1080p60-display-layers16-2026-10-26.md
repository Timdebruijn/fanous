# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-10-26T15:09:28Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: display 1, frame latency 1, ring 6 frames/layer
- Window per step: 120.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses

**Max layers without drops: 16**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 16 | 7267 | 0 | 0 | 0 | 0.12 / 0.18 / 0.41 | 8.65 / 9.61 / 11.10 | -17 / -28 | pass |
