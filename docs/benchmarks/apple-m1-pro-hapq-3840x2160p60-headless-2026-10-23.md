# Benchmark: Apple M1 Pro, hapq_3840x2160p60.mov

- Date: 2026-10-23T08:37:05Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses

**Max layers without drops: 4**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 1205 | 0 | 0 | 0 | 0.06 / 0.21 / 0.32 | 0.82 / 0.85 / 0.92 | -19 / -18 | pass |
| 2 | 1226 | 0 | 0 | 0 | 0.07 / 0.26 / 0.30 | 1.48 / 1.64 / 1.75 | -19 / -30 | pass |
| 3 | 1230 | 0 | 0 | 0 | 0.06 / 0.17 / 0.22 | 2.17 / 2.23 / 2.27 | -42 / -42 | pass |
| 4 | 1218 | 0 | 0 | 0 | 0.07 / 0.29 / 0.39 | 2.85 / 3.02 / 3.04 | -29 / -74 | pass |
