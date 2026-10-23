# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-10-23T14:04:48Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.0.1 (Build 26A434)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 6 frames/layer
- Window per step: 3600.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses
- Variant: soak3600s

**Max layers without drops: 1**

| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |
|---|---|---|---|---|---|---|---|---|
| 1 | 16384 | 0 | 0 | 0 | 0.15 / 0.33 / 1.89 | 0.60 / 0.62 / 0.81 | 1478 / 361 | pass |

Audio (last step): underruns 26, drift corrections 0, max drift 15.3 ms
