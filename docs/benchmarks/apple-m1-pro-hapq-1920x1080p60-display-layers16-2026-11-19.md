# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-19T09:19:29Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 120.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 16**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 7224 | 0 | 0 | 0 | 0 | 0.13 / 0.17 / 0.21 | 6.78 / 9.64 / 10.09 | 151683 (21.00/tick) | pass |
