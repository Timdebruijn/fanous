# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-11-21T16:21:39Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 394 | 0 | 385 | 0 | 0 | 0.46 / 0.53 / 0.69 | 137.16 / 161.02 / 165.84 | 35002 (88.84/tick) | fail |
