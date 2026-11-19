# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-19T08:40:05Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: dissolve2s

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1201 | 0 | 0 | 0 | 0 | 0.05 / 0.07 / 0.24 | 1.22 / 2.91 / 3.15 | 5075 (4.23/tick) | pass |
| 2 | 1244 | 0 | 0 | 0 | 0 | 0.06 / 0.09 / 0.34 | 1.80 / 3.86 / 4.01 | 5105 (4.10/tick) | pass |
| 3 | 1201 | 0 | 0 | 0 | 0 | 0.06 / 0.10 / 0.51 | 1.90 / 4.88 / 5.24 | 4991 (4.16/tick) | pass |
| 4 | 1217 | 0 | 0 | 0 | 0 | 0.07 / 0.14 / 0.60 | 4.05 / 6.59 / 6.87 | 5107 (4.20/tick) | pass |
| 5 | 1214 | 0 | 0 | 0 | 0 | 0.08 / 0.12 / 0.86 | 4.56 / 7.96 / 8.11 | 5130 (4.23/tick) | pass |
| 6 | 1210 | 0 | 1 | 0 | 43 | 0.08 / 0.17 / 0.30 | 6.06 / 9.55 / 22.46 | 4889 (4.04/tick) | fail |
