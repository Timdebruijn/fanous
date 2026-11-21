# Benchmark: Apple M1 Pro, hapq_3840x2160p60.mov

- Date: 2026-11-19T16:28:14Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 6**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1203 | 0 | 0 | 0 | 0 | 0.12 / 0.38 / 0.69 | 1.61 / 2.39 / 2.44 | 4808 (4.00/tick) | pass |
| 2 | 1234 | 0 | 0 | 0 | 0 | 0.11 / 0.44 / 0.57 | 3.13 / 4.29 / 4.65 | 4939 (4.00/tick) | pass |
| 3 | 1230 | 0 | 0 | 0 | 0 | 0.09 / 0.13 / 0.26 | 6.91 / 6.92 / 6.93 | 4916 (4.00/tick) | pass |
| 4 | 1214 | 0 | 0 | 0 | 0 | 0.09 / 0.12 / 0.14 | 5.93 / 9.18 / 9.19 | 4852 (4.00/tick) | pass |
| 5 | 1201 | 0 | 0 | 0 | 0 | 0.09 / 0.12 / 0.14 | 7.64 / 11.21 / 11.93 | 4804 (4.00/tick) | pass |
| 6 | 1211 | 0 | 0 | 0 | 0 | 0.09 / 0.12 / 0.15 | 8.10 / 12.92 / 13.47 | 4840 (4.00/tick) | pass |
| 7 | 1241 | 0 | 119 | 0 | 0 | 0.09 / 0.12 / 0.37 | 10.92 / 15.47 / 15.66 | 5007 (4.03/tick) | fail |
