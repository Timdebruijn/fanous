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

## Phase 3 (2026-10-23): effects, dissolves, audio

Same machine and criterion; release build; `scripts/bench-phase3.sh` runs the
matrix (`--effects a,b` puts both effect slots on every layer, `--dissolve 2`
switches every layer between two files every 4 s so there is always a
crossfade running).

GPU cost per effect, one 1080p HAP Q layer (GPU p99, whole frame incl. clear
and output pass; the layer without effects is 0.6 ms):

| Effect(s) | GPU p99 | Per layer |
|---|---|---|
| none | 0.6 ms | — |
| invert, tint, luma key, kaleidoscope, pixelate (per-pixel) | 0.7–0.9 ms | ≈ 0.1–0.3 ms |
| blur (13 taps, radius 2.5 % of height) | 2.5 ms | ≈ 1.9 ms |
| edge (Sobel, 9 taps) | 2.2 ms | ≈ 1.6 ms |
| blur + edge | 5.2 ms | ≈ 4.6 ms |

Before the function-constant specialisation of blur/edge the same shader cost
3.7 / 3.0 / 7.1 ms: inlining the tap loops into the single uber-shader cost
every draw its occupancy (DESIGN.md §4.3).

| Variant | Codec | Canvas | Output | Result |
|---|---|---|---|---|
| invert + tint on all 16 layers | HAP Q | 1080p60 | headless | **pass**, GPU p99 9.3 ms |
| invert + tint on all 16 layers | ProRes 422 HQ | 1080p60 | headless | **pass**, GPU p99 11.2 ms |
| pixelate + kaleidoscope on all 16 layers | HAP Q | 1080p60 | headless | **pass**, GPU p99 11.7 ms |
| invert + tint on all 16 layers | HAP Q | 4K30 | headless | **pass**, GPU p99 13.4 ms |
| blur + edge on every layer, ramp | HAP Q | 1080p60 | headless | **2 layers** (3 fails late, GPU p99 14.5 ms) |
| blur + edge on every layer, ramp | ProRes 422 HQ | 1080p60 | headless | **3 layers** (4 fails late, GPU p99 18.2 ms) |
| blur + edge on every layer, ramp | HAP Q | 4K30 | headless | **≥ 4** (max tested, GPU p99 27.9 ms) |
| blur + edge on all 16 layers | both | 1080p60 / 4K30 | headless | fail (GPU-bound, ≈ 75–150 ms per frame) |
| permanent 2 s dissolves, 8 layers (16 decoders) | HAP Q | 1080p60 | headless | **pass**, 0 texture misses, GPU p99 3.8 ms |
| permanent 2 s dissolves, 8 layers (16 decoders) | ProRes 422 HQ | 1080p60 | headless | **pass**, 0 texture misses, GPU p99 4.1 ms |
| invert + tint on all 16 layers | HAP Q | 1080p60 | display | **pass**, 1201 frames, GPU p99 9.9 ms |
| invert + tint on all 16 layers | ProRes 422 HQ | 1080p60 | display | **pass**, 1221 frames, GPU p99 11.4 ms |
| permanent 2 s dissolves, 8 layers | HAP Q | 1080p60 | display | **pass**, 0 texture misses, GPU p99 4.4 ms |
| blur + edge on both layers | HAP Q | 1080p60 | display | **pass** at 2 layers, GPU p99 10.3 ms |

So the tier numbers hold with both effect slots in use for the per-pixel
effects; the two neighbourhood effects (blur, edge) cost about one extra
1080p layer each per layer they are on, which the Layers screen will show as
a per-layer cost (Phase 5). A cheaper blur (separable or mip-based) is a
v1.x option if shows want blur on many layers at once.

A dissolve costs exactly one extra layer (its decoder and draw) for its
duration: the incoming media is staged until its first frame is decoded, so
switching files never shows a texture miss.

Audio (one HAP Q 1080p60 layer with a 48 kHz LPCM track, headless, the
layer clock is master): 20 s run 0 underruns, 0 drift corrections, max drift
11.8 ms. **One-hour soak** (`scripts/bench-phase3.sh drift`,
`…-layers1-soak3600s-2026-10-23.md`): max drift 15.3 ms, 0 drift corrections,
26 underruns over 360 loop wraps of the 10 s file (a loop wrap is a reseek
with one callback of silence; gapless loop reads are a v1.x item), video
0 missed / 0 late (the frame metrics ring holds the last 16 384 ticks, so
those cover the final 4.5 min; the audio counters cover the whole hour).
Acceptance "drift < 20 ms over 1 h at 1×" met.
