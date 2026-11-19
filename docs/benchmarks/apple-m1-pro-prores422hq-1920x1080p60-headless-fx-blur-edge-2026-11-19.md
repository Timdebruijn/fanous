# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T08:25:13Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1204 | 0 | 0 | 0 | 0 | 0.06 / 0.10 / 0.16 | 2.02 / 2.11 / 2.59 | 13233 (10.99/tick) | pass |
| 2 | 1209 | 0 | 0 | 0 | 0 | 0.07 / 0.11 / 0.13 | 2.97 / 4.12 / 5.03 | 19344 (16.00/tick) | pass |
| 3 | 1214 | 0 | 0 | 0 | 0 | 0.09 / 0.13 / 0.17 | 4.74 / 7.63 / 8.94 | 25473 (20.98/tick) | pass |
| 4 | 1245 | 0 | 0 | 0 | 0 | 0.10 / 0.14 / 0.19 | 6.54 / 10.97 / 11.45 | 32344 (25.98/tick) | pass |
| 5 | 1217 | 0 | 0 | 0 | 0 | 0.11 / 0.15 / 0.19 | 7.81 / 11.94 / 12.25 | 37696 (30.97/tick) | pass |
| 6 | 1221 | 0 | 6 | 0 | 0 | 0.12 / 0.16 / 0.23 | 9.03 / 13.91 / 14.88 | 43920 (35.97/tick) | fail |
