# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-21T16:21:15Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 16**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 1237 | 0 | 0 | 0 | 0 | 0.26 / 0.31 / 0.49 | 13.18 / 14.46 / 15.16 | 106296 (85.93/tick) | pass |
