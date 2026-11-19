# Benchmark: Apple M1 Pro, prores422hq_3840x2160p60.mov

- Date: 2026-11-18T22:37:34Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1207 | 0 | 0 | 0 | 0 | 0.04 / 0.08 / 0.10 | 2.47 / 3.40 / 4.50 | 4824 (4.00/tick) | pass |
| 2 | 1233 | 0 | 0 | 0 | 0 | 0.05 / 0.09 / 0.12 | 4.71 / 6.65 / 7.06 | 4928 (4.00/tick) | pass |
| 3 | 1221 | 0 | 0 | 0 | 0 | 0.06 / 0.10 / 0.16 | 7.41 / 9.88 / 11.16 | 4880 (4.00/tick) | pass |
| 4 | 1225 | 0 | 0 | 0 | 0 | 0.07 / 0.11 / 0.13 | 7.39 / 10.70 / 12.71 | 4896 (4.00/tick) | pass |
| 5 | 1223 | 0 | 0 | 0 | 0 | 0.07 / 0.12 / 0.24 | 8.23 / 13.12 / 14.27 | 4888 (4.00/tick) | pass |
| 6 | 1228 | 0 | 1 | 0 | 0 | 0.08 / 0.11 / 0.34 | 8.00 / 13.61 / 17.27 | 4955 (4.04/tick) | fail |
