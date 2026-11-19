# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-19T08:34:21Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1229 | 0 | 0 | 0 | 0 | 0.06 / 0.10 / 0.17 | 2.05 / 3.58 / 3.88 | 13508 (10.99/tick) | pass |
| 2 | 1235 | 0 | 0 | 0 | 0 | 0.07 / 0.11 / 0.18 | 4.81 / 5.75 / 5.90 | 19744 (15.99/tick) | pass |
| 3 | 1232 | 0 | 0 | 0 | 0 | 0.09 / 0.14 / 0.20 | 5.85 / 7.93 / 9.15 | 25851 (20.98/tick) | pass |
| 4 | 1232 | 0 | 0 | 0 | 0 | 0.10 / 0.14 / 0.15 | 8.86 / 11.19 / 11.32 | 32006 (25.98/tick) | pass |
| 5 | 1216 | 0 | 0 | 0 | 0 | 0.11 / 0.16 / 0.23 | 7.71 / 11.97 / 13.08 | 37665 (30.97/tick) | pass |
| 6 | 1227 | 0 | 11 | 0 | 0 | 0.12 / 0.16 / 0.19 | 8.64 / 14.20 / 14.45 | 44136 (35.97/tick) | fail |
