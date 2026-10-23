# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-10-23T08:26:17Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 6 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses

**Max layers without drops: 2**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 2 | 1207 | 0 | 0 | 0 | 0.16 / 0.38 / 0.59 | 0.43 / 0.46 / 1.51 | 156 / 4 | pass |

DMX→photon estimate (Art-Net receive → target presentation time): p50 25.2 ms, p99 32.1 ms over 598 DMX frames
