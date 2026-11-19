# Benchmark: Apple M1 Pro, prores422hq_1920x1080p60.mov

- Date: 2026-11-19T09:23:30Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: display 0, frame latency 1, ring 8 frames/layer
- Window per step: 20.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: dissolve2s

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 8 | 1207 | 0 | 0 | 0 | 0 | 0.12 / 0.18 / 8.89 | 5.11 / 10.62 / 10.66 | 26116 (21.64/tick) | pass |
