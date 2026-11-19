# Benchmark: Apple M1 Pro, hapq_3840x2160p60.mov

- Date: 2026-11-19T09:25:28Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 6 | 1224 | 0 | 6 | 0 | 0 | 0.11 / 0.13 / 0.14 | 9.19 / 13.98 / 14.47 | 25679 (20.98/tick) | fail |
