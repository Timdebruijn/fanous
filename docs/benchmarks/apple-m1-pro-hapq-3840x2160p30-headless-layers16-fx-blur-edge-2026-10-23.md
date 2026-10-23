# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-10-23T13:56:07Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-blur-edge

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 16 | 207 | 0 | 143 | 0 | 106.54 / 644.26 / 645.89 | 965.74 / 1608.86 / 1716.53 | 1160 / 3376 | fail |
