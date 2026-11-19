# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T09:24:17Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 5**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 5 | 1224 | 0 | 0 | 0 | 0 | 0.11 / 0.18 / 0.19 | 7.09 / 10.54 / 10.61 | 57482 (46.96/tick) | pass |
