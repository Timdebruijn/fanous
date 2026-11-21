# Benchmark: Apple M1 Pro, hapq_1920x1080p60.mov

- Date: 2026-11-21T16:29:25Z
- Machine: Apple M1 Pro, Apple M1 Pro, 32 GB, Version 27.2.1 (Build 26B131)
- Canvas 1920×1080 @ 60.0 fps, output: headless, frame latency 1, ring 8 frames/layer
- Window per step: 40.0 s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses, 0 stale frames
- Variant: ingest

**Max layers without drops: 8**

| Layers | Frames | Missed | Late | Texture misses | Stale frames | CPU p50/p99/max ms | GPU p50/p99/max ms | Compositor mallocs | Result |
|---|---|---|---|---|---|---|---|---|---|
| 8 | 2435 | 0 | 0 | 0 | 0 | 0.08 / 0.12 / 0.15 | 4.64 / 6.36 / 6.67 | 9736 (4.00/tick) | pass |
