# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-21T16:06:38Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1212 | 0 | 0 | 0 | 0 | 0.10 / 2.57 / 5.39 | 2.12 / 4.62 / 5.35 | 13321 (10.99/tick) | pass |
| 2 | 1253 | 0 | 0 | 0 | 0 | 0.10 / 0.51 / 1.11 | 4.35 / 5.88 / 6.77 | 20032 (15.99/tick) | pass |
| 3 | 1225 | 0 | 0 | 0 | 0 | 0.13 / 3.61 / 5.52 | 5.56 / 9.40 / 11.07 | 25704 (20.98/tick) | pass |
| 4 | 1259 | 0 | 0 | 0 | 0 | 0.13 / 2.48 / 5.23 | 6.24 / 12.23 / 13.52 | 32708 (25.98/tick) | pass |
| 5 | 1202 | 0 | 0 | 0 | 0 | 0.14 / 2.03 / 3.68 | 6.76 / 9.32 / 11.84 | 37231 (30.97/tick) | pass |
| 6 | 1250 | 0 | 90 | 0 | 0 | 0.14 / 0.51 / 0.83 | 7.44 / 15.29 / 16.14 | 45000 (36.00/tick) | fail |
