# Benchmark: Apple M1 Pro, prores422hq_3840x2160p60.mov

- Date: 2026-11-19T16:13:20Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 6**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1204 | 0 | 0 | 0 | 0 | 0.14 / 0.45 / 1.03 | 1.99 / 2.52 / 2.57 | 4812 (4.00/tick) | pass |
| 2 | 1210 | 0 | 0 | 0 | 0 | 0.12 / 0.51 / 1.20 | 3.19 / 4.51 / 4.89 | 4836 (4.00/tick) | pass |
| 3 | 1236 | 0 | 0 | 0 | 0 | 0.14 / 0.51 / 0.64 | 4.37 / 5.94 / 7.25 | 4940 (4.00/tick) | pass |
| 4 | 1218 | 0 | 0 | 0 | 0 | 0.16 / 0.25 / 0.55 | 6.56 / 8.81 / 8.87 | 4868 (4.00/tick) | pass |
| 5 | 1217 | 0 | 0 | 0 | 0 | 0.19 / 0.27 / 0.53 | 7.79 / 11.48 / 11.98 | 4864 (4.00/tick) | pass |
| 6 | 1211 | 0 | 0 | 0 | 0 | 0.19 / 0.27 / 0.55 | 8.63 / 13.25 / 13.77 | 4844 (4.00/tick) | pass |
| 7 | 1254 | 0 | 98 | 0 | 0 | 0.20 / 0.26 / 0.37 | 8.91 / 15.84 / 15.99 | 5012 (4.00/tick) | fail |
