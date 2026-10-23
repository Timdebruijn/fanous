# Benchmarks

Results of `lanthorn-bench run` per machine, codec and resolution. One
`.md` + `.json` pair per run; the engine will read the JSON for its tier
display (Phase 5).

```bash
swift build -c release --product lanthorn-bench
BIN=$(swift build -c release --show-bin-path)
"$BIN/lanthorn-bench" media --dir ~/Movies/Lanthorn\ Bench --seconds 3      # once: synthetic test movies
"$BIN/lanthorn-bench" spike ~/Movies/Lanthorn\ Bench/prores422hq_1920x1080p60.mov   # decode formats and timing
"$BIN/lanthorn-bench" run --media ~/Movies/Lanthorn\ Bench --codec prores422hq --res 1920x1080p60 --display 0 --window 60
"$BIN/lanthorn-bench" run --media ~/Movies/Lanthorn\ Bench --codec hapq --res 3840x2160p60 --headless --window 60 --soak 600
```

Pass criterion per step: 0 missed display-link ticks, 0 late GPU completions,
0 ticks where a visible layer had no decoded frame ready, over the whole
window (after a 2 s warm-up). Headless runs use a `mach_wait_until` clock at
the canvas rate and measure CPU/GPU/decode throughput; display runs add the
real `CAMetalDisplayLink` with `preferredFrameLatency = 1`.

## Results so far (MacBook Pro M1 Pro, 32 GB, macOS 27.0.1, 2026-10-23)

Pass = 0 missed, 0 late, 0 texture misses in a 20 s window after 2 s warm-up.
Headless rows use the mach-clock compositor; display rows use the drawable-loop
driver on the built-in display (ADR-0006 amendment).

| Codec | Canvas | Ring | Output | Max layers | Notes |
|---|---|---|---|---|---|
| ProRes 422 HQ | 1080p60 | 6 | headless | 16 (cap) | GPU p99 3.9 ms at 16 |
| ProRes 422 HQ | 1080p60 | 6 | display | 16, one texture miss in 1212 frames | decode jitter at the cap |
| ProRes 422 HQ | 4K30 | 4 | headless | 16 (cap) | GPU p99 13.3 ms at 16 |
| ProRes 422 HQ | 4K60 | 4 | headless | 6 | 7 fails with one texture miss |
| ProRes 422 HQ | 4K60 | 8 | headless | 3–7 (run-dependent) | single step at 7 passed; the sweep failed at 4 with one miss: decode jitter, not throughput (decode 1.8 ms/frame) — Phase 3 work item |
| HAP Q | 1080p60 | 6 | headless | 16 (cap) | GPU p99 2.9 ms at 16 |
| HAP Q | 1080p60 | 6 | display | 16 (cap) | pass |
| HAP Q | 4K30 | 4 | headless | 2 | 3 fails with one late frame |
| HAP Q | 4K30 | 8 | headless | 16 (cap) | GPU p99 11.1 ms at 16 |
| HAP Q | 4K60 | 4 | headless | 1 | 2 fails with texture misses |
| HAP Q | 4K60 | 8 | headless | ≥ 4 (max tested) | GPU p99 3.0 ms at 4 |

Ring depth (frames decoded ahead per layer) is the decisive tier knob at 4K:
the engine now defaults to 8 for 4K and 6 for 1080p. The remaining 4K60 ProRes
failures are single late decodes in 20 s windows (zero-tolerance criterion),
to be attacked in Phase 3 (decode-thread scheduling, VT asynchronous decode).

DMX→photon (Art-Net receive → target presentation time, display path, 60 fps
canvas, 2 layers, ~35 Hz DMX): p50 25.2 ms, p99 32.1 ms (n = 598), i.e. within
two frames; the display's own scan-out latency is not included.

Decode (one frame, p50, release build): ProRes 422 HQ 1080p 0.8 ms / 4K 1.8 ms;
ProRes 4444 1080p 1.8 ms (`y416`, alpha kept) vs 0.95 ms native; HAP Q 1080p
0.8 ms / 4K 1.6 ms (chunked, parallel); HAP 1080p 0.4 ms.
