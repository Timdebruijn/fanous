# Benchmark: Apple M1 Pro, prores422hq_3840x2160p60.mov

- Date: 2026-11-19T09:24:41Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 3840×2160 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames

**Max layers without drops: 4**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 4 | 1225 | 0 | 0 | 0 | 0 | 0.09 / 0.12 / 0.13 | 6.71 / 10.44 / 10.56 | 25710 (20.99/tick) | pass |
