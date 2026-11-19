# Benchmark: Apple M1 Pro, hapq_3840x2160p60.mov

- Date: 2026-11-18T22:52:07Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 6**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1210 | 0 | 0 | 0 | 0 | 0.05 / 0.08 / 0.09 | 2.37 / 2.37 / 2.37 | 4836 (4.00/tick) | pass |
| 2 | 1213 | 0 | 0 | 0 | 0 | 0.07 / 0.09 / 0.09 | 4.64 / 4.65 / 4.65 | 4848 (4.00/tick) | pass |
| 3 | 1213 | 0 | 0 | 0 | 0 | 0.07 / 0.09 / 0.14 | 3.93 / 6.57 / 6.92 | 4848 (4.00/tick) | pass |
| 4 | 1209 | 0 | 0 | 0 | 0 | 0.07 / 0.09 / 0.10 | 5.53 / 8.86 / 9.19 | 4832 (4.00/tick) | pass |
| 5 | 1232 | 0 | 0 | 0 | 0 | 0.07 / 0.10 / 0.11 | 9.83 / 11.46 / 11.46 | 4924 (4.00/tick) | pass |
| 6 | 1225 | 0 | 0 | 0 | 0 | 0.08 / 0.10 / 0.11 | 7.75 / 9.47 / 11.16 | 4896 (4.00/tick) | pass |
| 7 | 1266 | 0 | 5 | 0 | 0 | 0.09 / 0.11 / 0.12 | 11.16 / 13.63 / 14.26 | 5060 (4.00/tick) | fail |
