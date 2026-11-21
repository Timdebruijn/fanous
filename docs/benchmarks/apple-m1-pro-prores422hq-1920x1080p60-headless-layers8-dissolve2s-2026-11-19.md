# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T10:10:41Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: dissolve2s

**Max layers without drops: 0**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 8 | 1239 | 0 | 0 | 0 | 6 | 0.10 / 0.15 / 4.70 | 4.87 / 8.70 / 9.44 | 6197 (5.00/tick) | fail |

Stale frames at 8 layers: by layer [0, 0, 0, 3, 3, 0, 0, 0], 1 runs, longest 3 ticks at 1.8 s. Runs (start in the window × ticks (frames)): 1.8 s × 3 ticks (6)
