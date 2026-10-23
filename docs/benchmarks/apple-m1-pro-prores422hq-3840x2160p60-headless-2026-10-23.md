# Benchmark: Apple M1 Pro, prores422hq_3840x2160p60.mov

- Date: 2026-10-23T08:29:25Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 3840×2160 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses

**Max layers without drops: 3**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 1207 | 0 | 0 | 0 | 0.09 / 0.38 / 0.44 | 0.81 / 1.08 / 1.19 | -2 / -27 | pass |
| 2 | 1226 | 0 | 0 | 0 | 0.09 / 0.34 / 0.47 | 1.84 / 1.99 / 2.06 | -76 / -48 | pass |
| 3 | 1230 | 0 | 0 | 0 | 0.09 / 0.33 / 0.56 | 2.71 / 2.88 / 2.97 | -46 / -50 | pass |
| 4 | 1242 | 0 | 0 | 1 | 0.09 / 0.36 / 0.57 | 3.52 / 3.67 / 3.78 | -73 / -73 | fail |
