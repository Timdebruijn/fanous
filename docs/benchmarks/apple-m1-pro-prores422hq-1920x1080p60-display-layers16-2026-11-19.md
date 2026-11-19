# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T09:17:25Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 120.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 7227 | 0 | 0 | 0 | 101 | 0.14 / 0.18 / 0.21 | 6.70 / 10.54 / 10.76 | 151762 (21.00/tick) | fail |
