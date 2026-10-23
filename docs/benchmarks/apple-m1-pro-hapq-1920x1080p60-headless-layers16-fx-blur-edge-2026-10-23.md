# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-10-23T13:55:44Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 6 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-blur-edge

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 16 | 746 | 0 | 682 | 0 | 27.37 / 166.14 / 166.40 | 910.44 / 1049.27 / 1054.43 | 348 / 1148 | fail |
