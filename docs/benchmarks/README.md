# Benchmarks

Results of `fanous-bench run` per machine, codec and resolution. One
`.md` + `.json` pair per run; the engine will read the JSON for its tier
display (Phase 5).

```bash
swift build -c release --product fanous-bench
BIN=$(swift build -c release --show-bin-path)
"$BIN/fanous-bench" media --dir ~/Movies/Fanous\ Bench --seconds 3      # once: synthetic test movies
"$BIN/fanous-bench" spike ~/Movies/Fanous\ Bench/prores422hq_1920x1080p60.mov   # decode formats and timing
"$BIN/fanous-bench" run --media ~/Movies/Fanous\ Bench --codec prores422hq --res 1920x1080p60 --display 0 --window 60
"$BIN/fanous-bench" run --media ~/Movies/Fanous\ Bench --codec hapq --res 3840x2160p60 --headless --window 60 --soak 600
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

## Phase 4 (2026-10-23): ingest during a show

`fanous-bench run --ingest FILE` runs the real `IngestQueue` in the
benchmark process: one `.utility` thread transcodes FILE to HAP Q while the
compositor runs, yielding 20 ms whenever a frame in the last 250 ms exceeded
70 % of the frame budget (DESIGN.md §8.3). Source: the 3 s 1080p60 ProRes
4444 benchmark file (180 frames).

| Variant | Codec | Canvas | Output | Result |
|---|---|---|---|---|
| 8 layers + ingest ProRes 4444 → HAP Q | HAP Q | 1080p60 | display | **pass**, 2422 frames, 0 missed / late / misses, GPU p99 4.3 ms; the job finished inside the 40 s window |
| 8 layers + ingest ProRes 4444 → HAP Q | ProRes 422 HQ | 1080p60 | headless | **pass**, 2416 frames, 0 missed / late / misses, GPU p99 4.5 ms; job finished |

Library index: a 10 000-file root (40 folders × 250 files) scans in under the
test's 5 s bound on the M1 Pro (directory listings only; metadata probes run
afterwards on the library thread and are cached per path + mtime + size).
Transcode throughput (release, 320×176 2 s source): ProRes 422 HQ ≈ 350–600
fps, HAP Q ≈ 210–280 fps, HAP ≈ 350–590 fps; at 1080p HAP Q encodes at
≈ 11 fps (CPU DXT, `HAPEncoder`).

## Phase 5 (2026-10-23): service restart, state sync with many clients

Debug build of `fanousd` running headless with a 4-layer 1080p60 scene,
driven from a user LaunchAgent with `KeepAlive` (the same plist shape
`scripts/bundle.sh` writes for `SMAppService`), probed every 50 ms over
HTTPS (`scripts` in the session scratchpad; numbers from one run):

| Event | Time after `kill -9` |
|---|---|
| `/healthz` answers 200 | 0.15 s |
| `/api/metrics` reports rendered frames again | 0.26 s |

launchd relaunches at once because the engine had run longer than its
10 s throttle interval; the TLS identity, library index and media open from
cache. Acceptance "outputs back < 3 s" holds with margin; a display-bound
start adds the window creation only.

State sync (DESIGN.md §11.2), same scene, 25 s window: four WebSocket
clients as programmer, each subscribed to the 640×360 H.264 preview, plus one
client that completes hello and the preview subscription and then stops
reading its socket.

| Measure | Result |
|---|---|
| Revision after a command from client 1, seen by all four | identical (342 at the end of the window) |
| Preview frames per client | 750 (30 fps × 25 s), 2.1 MB each |
| Stalled client | reported as `live.clients.lagging = 1` after 12 s; live patches dropped for it, project patches never |
| Compositor during the window | 600 frames / 10 s, 0 missed, 0 late, GPU p99 2.4 ms with 4 layers playing |

The engine's own cost for five clients is one H.264 encoder (VideoToolbox,
Baseline, 1.5 Mbit/s) on the preview queue and the 10 Hz live diff; the
render thread only encodes the extra 640×360 output pass into its command
buffer every second tick.

## Phase 6 (2026-10-23): blend, warp, output binding

Readback tests (`OutputPassTests`, 320×180 canvas, flat grey still):

| Arrangement | Gamma | Max light error across the overlaps |
|---|---|---|
| 2×1, 80 px overlap | 1.0 | < 0.02 (8-bit quantization + dither) |
| 2×1, 80 px overlap | 2.2 | < 0.03 |
| 2×2, 80 × 20 px overlaps | 2.2 | < 0.035 |

Light = Σ (value/255)^γ over the outputs covering a canvas pixel, compared
with the input's (value/255)^γ.

Warp edit → apply: `OutputCompiler.compile` of an output with a 33×33 mesh
and a feathered mask at 1920×1080 (field 480×270, mask grid 480×270, 64×64
slice mesh, texture uploads): **3.7 ms** release, 145 ms debug (M1 Pro). The
swap into the render thread is one reference store.

Binding/unbinding the built-in display at runtime (`output.add` / `remove`
over the protocol, debug build, 4-layer 1080p60 scene): one missed frame at
the headless → display driver switch, 0 late frames, GPU p99 0.8 ms.

## Phase 7 (2026-10-24): timecode chase, CITP loopback

LTC chase (`ShowControlTests.ltcFileChasesWithinOneFrame`): 3 s of generated
25 fps LTC at 48 kHz, fed to the decoder in 512-sample buffers as the audio
thread would, host time from the sample index. 70+ of 75 frames decoded
(the first frames are sync), chase error at frame 61 and half a frame later
**≤ 1 frame** (acceptance). MTC: eight quarter frames lock the clock two
frames behind the quarter-frame time, a full-frame SysEx sets it directly.

CITP/MSEX loopback (`CITPServerTests`, debug build): `CInf` → `SInf`,
`GELI`, `GEIn`, `GETh`, first `LSta`, `RqSt` → first `StFr`, `Nack`, stream
stop — the whole session in 0.34 s including the listener start. `LSta` is
sent at 4 Hz, frames at the requested rate up to 10 fps, and the preview
encoder only produces JPEGs while a stream is open.

Not measured: cue fade end-to-end (B43), readiness probe cost (shell-outs,
B38), real LTC/MTC hardware (B44).

## Phase 8 (2026-10-24): soak and restart

`scripts/soak.sh HOURS LAYERS` drives the running engine with `fanous-bench
dmx` (Art-Net at the standard patch, 40 Hz, random file / play mode / dissolve /
intensity per layer every 3–8 s, slow position and scale drift), samples
`/metrics` and the engine's RSS every second, `kill -9`s the engine at the
kill interval and times `/healthz` coming back. Pass = no missed (dropped)
frames outside the first 5 s after a (re)start, RSS growth under 100 MB after
a 5-minute warm-up, every restart under 3 s; late presents are warnings.

30-minute run on the M1 Pro (debug build, 4 layers 1080p60 HAP Q / ProRes from
the demo library, scene file, `soak-2026-10-24-0814.md`): **35 828 frames per
engine instance, 0 missed, 2 × kill → healthz 0.19 s, RSS 138 → 143 MB after
warm-up, GPU p99 2.1 ms, DMX→photon p99 30 ms**; 3 late presents (one vsync
late) in the whole run (B52). The sampler spawned ten processes per second
during this run; it now spawns one.

15-minute run on the production path (no scene file: canvas, patch and
library from `project.json`, 8 layers, `soak-2026-10-24-0849.md`): **0 missed,
0 late, 2 × kill → healthz 0.18 s, RSS 223 → 203 MB after warm-up, average
60.6 fps over 837 samples, GPU p99 ≤ 6.9 ms, DMX→photon p99 30 ms — PASS.**

8-hour run (DESIGN §18 acceptance, production path, 8 layers, kill -9 every
2 h, system kept awake with `caffeinate`, `soak-2026-10-24-0928.md`): **PASS
with warnings: 0 missed frames in 26 797 one-second samples (≈ 1.7 million
frames over four engine instances), 3 × kill → healthz 0.26 s, RSS 218 → 230 MB
after warm-up (max 278 MB), average 60.7 fps, GPU p99 ≤ 8.0 ms, DMX→photon p99
30 ms, thermal state nominal throughout; 5 late presents (one vsync late) in
8 h (B52).** The 8 h criterion of §19 is met on the reference machine; other
machines remain owner runs (`docs/RELEASE.md` §3, B49).
