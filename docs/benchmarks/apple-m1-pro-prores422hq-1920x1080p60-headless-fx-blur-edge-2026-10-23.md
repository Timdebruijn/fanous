# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-10-23T13:59:13Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 6 frames/layer
- Window per step: 8.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-blur-edge

**Max layers without drops: 3**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 486 | 0 | 0 | 0 | 0.16 / 0.38 / 0.49 | 3.25 / 5.39 / 5.42 | -41 / -48 | pass |
| 2 | 502 | 0 | 0 | 0 | 0.16 / 0.37 / 0.84 | 7.44 / 10.34 / 10.51 | -57 / -33 | pass |
| 3 | 486 | 0 | 0 | 0 | 0.17 / 0.35 / 0.52 | 8.19 / 12.73 / 13.81 | -36 / -24 | pass |
| 4 | 509 | 0 | 38 | 0 | 0.19 / 0.48 / 1.21 | 11.08 / 18.16 / 18.54 | -59 / -44 | fail |
