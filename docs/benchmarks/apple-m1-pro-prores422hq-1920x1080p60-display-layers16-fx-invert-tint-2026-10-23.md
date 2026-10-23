# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-10-23T14:01:23Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 6 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-invert-tint

**Max layers without drops: 16**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 16 | 1221 | 0 | 0 | 0 | 0.13 / 0.31 / 0.94 | 7.49 / 11.35 / 11.44 | 80 / -40 | pass |
