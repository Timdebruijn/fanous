# Benchmark: Apple M1 Pro, prores422hq_3840x2160p30.mov

- Date: 2026-11-19T08:27:30Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 9**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 607 | 0 | 0 | 0 | 0 | 0.07 / 0.11 / 0.17 | 6.78 / 9.86 / 10.21 | 6666 (10.98/tick) | pass |
| 2 | 617 | 0 | 0 | 0 | 0 | 0.08 / 0.11 / 0.13 | 11.08 / 15.93 / 16.23 | 9856 (15.97/tick) | pass |
| 3 | 618 | 0 | 0 | 0 | 0 | 0.09 / 0.13 / 0.13 | 11.37 / 13.08 / 13.33 | 12978 (21.00/tick) | pass |
| 4 | 620 | 0 | 0 | 0 | 0 | 0.11 / 0.15 / 0.21 | 12.76 / 13.45 / 13.70 | 16094 (25.96/tick) | pass |
| 5 | 610 | 0 | 0 | 0 | 0 | 0.11 / 0.15 / 0.16 | 16.19 / 16.69 / 16.91 | 18879 (30.95/tick) | pass |
| 6 | 611 | 0 | 0 | 0 | 0 | 0.12 / 0.17 / 0.19 | 19.39 / 19.85 / 19.96 | 21960 (35.94/tick) | pass |
| 7 | 605 | 0 | 0 | 0 | 0 | 0.14 / 0.19 / 0.26 | 22.27 / 23.03 / 23.39 | 24764 (40.93/tick) | pass |
| 8 | 602 | 0 | 0 | 0 | 0 | 0.15 / 0.20 / 0.23 | 25.32 / 25.94 / 26.17 | 27646 (45.92/tick) | pass |
| 9 | 608 | 0 | 0 | 0 | 0 | 0.17 / 0.21 / 0.23 | 28.25 / 29.06 / 30.86 | 30957 (50.92/tick) | pass |
| 10 | 612 | 0 | 249 | 0 | 0 | 0.19 / 0.28 / 0.33 | 31.19 / 32.36 / 33.08 | 34216 (55.91/tick) | fail |
