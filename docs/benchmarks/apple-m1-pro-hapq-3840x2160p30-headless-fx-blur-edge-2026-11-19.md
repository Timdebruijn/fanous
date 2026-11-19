# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-11-19T08:36:39Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 615 | 0 | 0 | 0 | 0 | 0.07 / 0.11 / 0.13 | 6.62 / 10.46 / 10.77 | 6754 (10.98/tick) | pass |
| 2 | 610 | 0 | 0 | 0 | 0 | 0.08 / 0.12 / 0.15 | 10.71 / 15.46 / 16.12 | 9744 (15.97/tick) | pass |
| 3 | 602 | 0 | 0 | 0 | 0 | 0.09 / 0.13 / 0.15 | 12.29 / 15.66 / 17.44 | 12621 (20.97/tick) | pass |
| 4 | 610 | 0 | 0 | 0 | 0 | 0.10 / 0.14 / 0.15 | 13.72 / 14.76 / 18.64 | 15834 (25.96/tick) | pass |
| 5 | 611 | 0 | 0 | 0 | 0 | 0.12 / 0.16 / 0.18 | 16.37 / 17.18 / 17.41 | 18910 (30.95/tick) | pass |
| 6 | 625 | 0 | 0 | 0 | 0 | 0.13 / 0.17 / 0.26 | 20.03 / 20.43 / 20.63 | 22464 (35.94/tick) | pass |
| 7 | 608 | 0 | 0 | 0 | 0 | 0.14 / 0.19 / 0.20 | 23.05 / 23.53 / 23.63 | 24887 (40.93/tick) | pass |
| 8 | 612 | 0 | 0 | 0 | 0 | 0.15 / 0.20 / 0.21 | 25.99 / 26.89 / 27.23 | 28106 (45.92/tick) | pass |
| 9 | 619 | 0 | 2 | 0 | 0 | 0.17 / 0.20 / 0.23 | 28.51 / 30.94 / 31.30 | 31518 (50.92/tick) | fail |
