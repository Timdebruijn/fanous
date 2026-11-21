# Benchmark: Apple M1 Pro, prores422hq_3840x2160p30.mov

- Date: 2026-11-21T16:08:57Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 616 | 0 | 0 | 0 | 0 | 0.10 / 0.43 / 0.78 | 8.76 / 10.23 / 10.97 | 6765 (10.98/tick) | pass |
| 2 | 622 | 0 | 0 | 0 | 0 | 0.12 / 2.89 / 4.92 | 10.51 / 14.54 / 15.91 | 9936 (15.97/tick) | pass |
| 3 | 611 | 0 | 0 | 0 | 0 | 0.12 / 0.65 / 0.84 | 13.36 / 17.82 / 19.38 | 12810 (20.97/tick) | pass |
| 4 | 619 | 0 | 0 | 0 | 0 | 0.17 / 0.66 / 1.09 | 13.92 / 14.86 / 16.10 | 16094 (26.00/tick) | pass |
| 5 | 608 | 0 | 0 | 0 | 0 | 0.19 / 0.70 / 0.87 | 16.68 / 17.36 / 17.96 | 18817 (30.95/tick) | pass |
| 6 | 615 | 0 | 0 | 0 | 0 | 0.15 / 0.37 / 0.99 | 19.86 / 20.81 / 21.33 | 22104 (35.94/tick) | pass |
| 7 | 607 | 0 | 0 | 0 | 0 | 0.20 / 0.39 / 0.46 | 22.95 / 23.91 / 24.54 | 24846 (40.93/tick) | pass |
| 8 | 623 | 0 | 0 | 0 | 0 | 0.19 / 0.32 / 0.43 | 25.84 / 26.86 / 27.24 | 28612 (45.93/tick) | pass |
| 9 | 616 | 0 | 6 | 0 | 0 | 0.20 / 0.43 / 0.52 | 27.20 / 31.82 / 35.66 | 31365 (50.92/tick) | fail |
