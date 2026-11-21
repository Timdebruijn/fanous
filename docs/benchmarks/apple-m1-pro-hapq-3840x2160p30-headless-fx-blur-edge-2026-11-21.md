# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-11-21T16:17:49Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 624 | 0 | 0 | 0 | 0 | 0.24 / 0.86 / 3.62 | 5.06 / 7.63 / 8.01 | 6853 (10.98/tick) | pass |
| 2 | 615 | 0 | 0 | 0 | 0 | 0.16 / 0.85 / 1.54 | 9.23 / 14.03 / 14.99 | 9824 (15.97/tick) | pass |
| 3 | 603 | 0 | 0 | 0 | 0 | 0.13 / 0.58 / 0.77 | 10.40 / 14.91 / 18.38 | 12642 (20.97/tick) | pass |
| 4 | 619 | 0 | 0 | 0 | 0 | 0.14 / 0.24 / 0.45 | 13.35 / 16.59 / 21.19 | 16068 (25.96/tick) | pass |
| 5 | 608 | 0 | 0 | 0 | 0 | 0.15 / 0.29 / 0.93 | 15.26 / 16.94 / 17.19 | 18817 (30.95/tick) | pass |
| 6 | 609 | 0 | 0 | 0 | 0 | 0.16 / 0.24 / 0.39 | 18.56 / 20.71 / 21.44 | 21888 (35.94/tick) | pass |
| 7 | 618 | 0 | 0 | 0 | 0 | 0.20 / 0.24 / 0.26 | 20.84 / 22.72 / 23.18 | 25297 (40.93/tick) | pass |
| 8 | 608 | 0 | 0 | 0 | 0 | 0.19 / 0.24 / 0.26 | 23.98 / 27.42 / 28.26 | 27922 (45.92/tick) | pass |
| 9 | 606 | 0 | 2 | 0 | 0 | 0.19 / 0.25 / 0.27 | 27.02 / 31.57 / 32.35 | 30855 (50.92/tick) | fail |
