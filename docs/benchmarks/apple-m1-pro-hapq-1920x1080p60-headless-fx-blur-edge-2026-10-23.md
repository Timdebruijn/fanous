# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-10-23T13:58:41Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 6 frames/layer
- Window per step: 8.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-blur-edge

**Max layers without drops: 2**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 495 | 0 | 0 | 0 | 0.15 / 0.32 / 0.37 | 3.75 / 5.18 / 5.57 | -23 / -37 | pass |
| 2 | 502 | 0 | 0 | 0 | 0.17 / 0.37 / 1.46 | 7.72 / 11.68 / 11.73 | -16 / -42 | pass |
| 3 | 513 | 0 | 13 | 0 | 0.14 / 0.33 / 1.65 | 9.91 / 14.50 / 15.40 | 11 / 113 | fail |
