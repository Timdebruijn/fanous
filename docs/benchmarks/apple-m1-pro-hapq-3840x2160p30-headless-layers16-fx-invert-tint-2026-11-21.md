# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-11-21T16:29:01Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: fx-invert-tint

**Max layers without drops: 16**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 610 | 0 | 0 | 0 | 0 | 0.12 / 0.15 / 0.18 | 15.00 / 17.80 / 18.61 | 2436 (3.99/tick) | pass |
