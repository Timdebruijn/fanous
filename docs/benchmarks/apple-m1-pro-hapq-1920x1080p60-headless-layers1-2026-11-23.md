# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-23T13:13:23Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 1**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1201 | 0 | 0 | 0 | 0 | 0.19 / 0.48 / 1.34 | 0.65 / 0.89 / 1.48 | 4800 (4.00/tick) | pass |

Audio (last step): underruns 0, drift corrections 0, max drift 2.5 ms
