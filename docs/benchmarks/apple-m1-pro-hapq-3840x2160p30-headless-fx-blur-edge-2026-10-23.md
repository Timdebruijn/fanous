# Benchmark: Apple M1 Pro, hapq_3840x2160p30.mov

- Date: 2026-10-23T13:59:56Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 3840×2160 @ 30.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 8.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: fx-blur-edge

**Max layers without drops: 4**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 244 | 0 | 0 | 0 | 0.21 / 0.51 / 0.63 | 8.55 / 13.69 / 15.92 | -21 / -32 | pass |
| 2 | 251 | 0 | 0 | 0 | 0.21 / 0.42 / 0.52 | 13.89 / 14.55 / 14.96 | -10 / -40 | pass |
| 3 | 243 | 0 | 0 | 0 | 0.25 / 0.42 / 0.93 | 20.80 / 20.92 / 20.94 | -15 / 10 | pass |
| 4 | 255 | 0 | 0 | 0 | 0.30 / 0.46 / 1.56 | 27.72 / 27.90 / 27.92 | 15 / -38 | pass |
