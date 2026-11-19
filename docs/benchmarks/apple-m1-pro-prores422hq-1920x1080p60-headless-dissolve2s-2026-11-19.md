# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T08:31:19Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: dissolve2s

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1223 | 0 | 0 | 0 | 0 | 0.05 / 0.09 / 0.99 | 1.25 / 2.56 / 2.95 | 5050 (4.13/tick) | pass |
| 2 | 1221 | 0 | 0 | 0 | 0 | 0.05 / 0.09 / 0.09 | 2.46 / 4.13 / 4.39 | 4882 (4.00/tick) | pass |
| 3 | 1201 | 0 | 0 | 0 | 0 | 0.06 / 0.10 / 3.91 | 2.14 / 4.91 / 5.07 | 5277 (4.39/tick) | pass |
| 4 | 1202 | 0 | 0 | 0 | 0 | 0.07 / 0.10 / 0.11 | 4.12 / 6.55 / 6.79 | 4808 (4.00/tick) | pass |
| 5 | 1230 | 0 | 0 | 0 | 0 | 0.08 / 0.12 / 5.22 | 4.11 / 7.76 / 8.06 | 5703 (4.64/tick) | pass |
| 6 | 1201 | 0 | 0 | 0 | 0 | 0.08 / 0.13 / 1.11 | 5.31 / 9.38 / 9.66 | 4961 (4.13/tick) | pass |
| 7 | 1201 | 0 | 0 | 0 | 0 | 0.09 / 0.14 / 4.39 | 5.50 / 10.61 / 10.75 | 5911 (4.92/tick) | pass |
| 8 | 1212 | 0 | 0 | 0 | 0 | 0.10 / 0.17 / 6.79 | 5.01 / 10.90 / 11.71 | 6393 (5.27/tick) | pass |
