# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-21T16:14:24Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1207 | 0 | 0 | 0 | 0 | 0.14 / 0.65 / 1.34 | 2.42 / 2.66 / 3.10 | 13266 (10.99/tick) | pass |
| 2 | 1211 | 0 | 0 | 0 | 0 | 0.17 / 0.70 / 1.24 | 3.68 / 4.70 / 4.83 | 19360 (15.99/tick) | pass |
| 3 | 1207 | 0 | 0 | 0 | 0 | 0.15 / 0.69 / 0.91 | 4.26 / 6.15 / 7.34 | 25326 (20.98/tick) | pass |
| 4 | 1215 | 0 | 0 | 0 | 0 | 0.18 / 0.62 / 0.86 | 4.99 / 7.73 / 8.55 | 31564 (25.98/tick) | pass |
| 5 | 1221 | 0 | 0 | 0 | 0 | 0.18 / 0.56 / 0.78 | 6.65 / 9.34 / 10.10 | 37820 (30.97/tick) | pass |
| 6 | 1245 | 0 | 0 | 0 | 0 | 0.20 / 0.59 / 0.87 | 7.81 / 11.44 / 11.77 | 44784 (35.97/tick) | pass |
| 7 | 1234 | 0 | 0 | 0 | 0 | 0.20 / 0.60 / 0.81 | 9.63 / 12.89 / 13.52 | 50553 (40.97/tick) | pass |
| 8 | 1215 | 0 | 0 | 0 | 0 | 0.19 / 0.26 / 0.27 | 7.55 / 8.54 / 9.34 | 55844 (45.96/tick) | pass |
| 9 | 1211 | 0 | 107 | 0 | 0 | 0.21 / 0.26 / 0.48 | 9.37 / 15.86 / 16.54 | 61728 (50.97/tick) | fail |
