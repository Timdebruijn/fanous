# Benchmark: Apple M1 Pro, prores422hq_3840x2160p30.mov

- Date: 2026-11-21T16:12:48Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-blur-edge

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 421 | 0 | 412 | 0 | 0 | 0.55 / 0.69 / 0.72 | 131.88 / 134.62 / 139.97 | 37152 (88.25/tick) | fail |
