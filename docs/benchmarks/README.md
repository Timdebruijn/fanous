# Benchmarks

Results of `fanous-bench run` per machine, codec and resolution. One
`.md` + `.json` pair per run. Planned, not built (B145): the engine reading the
JSON for a tier display.

```bash
swift build -c release --product fanous-bench
BIN=$(swift build -c release --show-bin-path)
"$BIN/fanous-bench" media --dir ~/Movies/Fanous\ Bench --seconds 3      # once: synthetic test movies
"$BIN/fanous-bench" run --media ~/Movies/Fanous\ Bench --codec prores422hq --res 1920x1080p60 --display 0 --window 60
"$BIN/fanous-bench" run --media ~/Movies/Fanous\ Bench --codec hapq --res 3840x2160p60 --headless --window 60 --soak 600
```

Pass criterion per step: 0 missed display-link ticks, 0 late GPU completions,
0 ticks where a visible layer had no decoded frame ready and, since
2026-11-18, 0 stale frames (a movie picture drawn with a frame other than its
clock's, B371; reported but not judged with `--dmx`), over the whole
window (after a 2 s warm-up). A step with stale frames also reports them per
layer and as runs of consecutive stale ticks (B391): the counts per layer say
which layers, the runs say when and for how long on end. Headless runs use a `mach_wait_until` clock at
the canvas rate and measure CPU/GPU/decode throughput; display runs add the
real `CAMetalDisplayLink` with `preferredFrameLatency = 1`.

## Re-measured 2026-11-18 and 19 (B375)

Until 2026-11-18 a playing layer decoded about 8 of every 11 frames (B364),
picked its picture from three ring entries (B372), and the criterion could not
see a picture drawn with an older frame (B371). Every headless number further
down this page was measured in that state; this section replaces them. The
display runs on the built-in panel were repeated on 2026-11-19 (at the end of
this section); the runs on a 4K display, the ingest runs, the soaks and
DMX→photon have not been.

Same MacBook Pro M1 Pro (32 GB), macOS 27.2.1, release build of main
`e7428db6` with the ring change below, headless, 20 s windows, the installed engine stopped. `fanous-bench`
now runs the engine's own ring (8 frames at every size; it used 6 up to 2000 px
width before). The Mac was not idle: load average about 3 to 6 from other work, so
these are the numbers of a busy Mac. Found on 2026-11-19: a test process started
on 2026-11-18 at 10:18 had used 1684 minutes of CPU in the 1702 minutes it had
run, so about one core was busy during every run of this section; its use
during a single run was not sampled. Pass = 0 missed, 0 late, 0 texture misses,
0 stale frames.

```bash
"$BIN/fanous-bench" run --media DIR --headless --window 20 --codec C --res R --max-layers 16
"$BIN/fanous-bench" run … --max-layers 16 --effects blur,edge     # ramp; --layers N for one step
"$BIN/fanous-bench" run … --max-layers 8 --dissolve 2
```

| Codec | Canvas | Max layers | GPU p99 there | First failure |
|---|---|---|---|---|
| ProRes 422 HQ | 1080p60 | 16 (cap) | 9.9 ms | — |
| ProRes 422 HQ | 4K30 | 16 (cap) | 14.2 ms | — |
| ProRes 422 HQ | 4K60 | 5 | 13.1 ms | 6: one late frame |
| HAP Q | 1080p60 | 16 (cap) | 8.6 ms | — |
| HAP Q | 4K30 | 16 (cap) | 15.4 ms | — |
| HAP Q | 4K60 | 6 | 9.5 ms | 7: five late frames |

No step of these six ramps had a stale frame or a texture miss, and the
compositor allocated 4.0 times per tick in every passing step. The 4K60
limits are late GPU completions. GPU p99 at 16 × 1080p60 was 3.9 ms (ProRes) and
2.9 ms (HAP Q) on 2026-10-23; what part of the difference is the repaired
fill, the load or the newer macOS has not been separated (the display run of
2026-10-26 already showed 10.0 and 9.6 ms).

Blur + edge on every layer (the scratch pass of B2, 2026-11-03, is in):

| Run | Codec | Canvas | Result |
|---|---|---|---|
| ramp | ProRes 422 HQ | 1080p60 | **5 layers** (GPU p99 11.9 ms); 6 fails with 6 late |
| ramp | HAP Q | 1080p60 | **5 layers** (12.0 ms); 6 fails with 11 late |
| ramp | ProRes 422 HQ | 4K30 | **9 layers** (29.1 ms); 10 fails with 249 late |
| ramp | HAP Q | 4K30 | **8 layers** (26.9 ms); 9 fails with 2 late |
| single steps | ProRes 422 HQ | 1080p60 | 6: fail (75 late, 15.8 ms) and fail (4 late, 14.4 ms) · 8: fail (8 late, 12.3 ms) · 10: fail (2 late, 10.5 ms) · 12: pass (11.9 ms) · 16: pass twice (13.3 ms) |
| single steps | HAP Q | 1080p60 | 6: pass (11.5 ms) · 8: pass (9.7 ms) · 12: fail (66 late, 18.6 ms) · 16: pass twice (13.4 ms) |
| single step, 16 layers | both | 4K30 | fail: 412 of 421 frames late, GPU p99 133 and 139 ms |

At 1080p60 the result is not monotone in the layer count: 16 layers passed in
all four single steps while 6 to 12 failed in five of eight, and the GPU time
of a step does not follow its layer count. The cause is not measured (B388);
until it is, 5 is the number to count on. A step that ran twice under one
name has the file of its last run only. The compositor allocated about 6 per
tick plus 5 for every blurred and edged layer (11.0 at 1 layer, 85.9 at 16);
the 5 per such layer is the figure of DESIGN §4.6.

Permanent 2 s dissolves at 1080p60 (every layer switches file every 4 s: 40
switches in a window of 8 layers, 16 decoders):

| Run | Codec | Result |
|---|---|---|
| ramp to 8 | ProRes 422 HQ | 8 pass (GPU p99 10.9 ms, 0 stale) |
| four single steps at 8 | ProRes 422 HQ | all fail on stale frames alone: 4, 3, 1 and 2 (0 missed, 0 late, 0 texture misses) |
| single step at 8 | HAP Q | pass (9.4 ms, 0 stale) |
| ramp to 8 | HAP Q | 5 pass; 6 fails with 43 stale frames and one late |

Six more single steps at 8 ProRes layers on main `1fb204ba`, with the stale
frames per layer and per run of ticks (B391): five fail on 3, 6, 2, 1 and 2
stale frames, one passes. In each failing step every stale frame sits in one
run of 1 to 3 ticks, 1.7 to 1.9 s into the window, on one layer (on two in the
step with 6). The bench's switch timer first fires 4 s after it is set, just
before the service starts and the 2 s warm-up, so that moment is the first
switch after the start; the four later switches of every window drew none. So
in these six runs it is the first dissolve of a freshly started bench that
draws a picture with an older frame for a few ticks, which also fits the clean
ramp (B389); the four single steps of the table above have no such detail.
The report file of the single step of 2026-11-19 is the one with 6; the one
of 2026-11-21 is a step with the decoder warm-up (below), a pass.

Traced on 2026-11-19: a build of main `4835a6f7` with timestamps in the
decoder, the loader and the compositor (the trace points are not in main), 13
single steps at 8 ProRes layers. 11 fail: on 1 to 6 stale frames at the first
switch, and the thirteenth on 32 more at its last switch (below). In all 13 the
decodes in flight block together at the first switch: 14 to 16 of the 16
decoders (the 8 outgoing and the 8 incoming) each have one frame of 46 to 82 ms
(counted: over 25 ms), where a traced frame typically takes 1 to 5 ms (median
2.7), and all of them are blocked over the same 46 to 59 ms, which begins 40 to
65 ms after the switch. Split in four of the steps, that time is inside the
`VTDecompressionSessionDecodeFrame` call (46 to 81 ms); reading the sample took
at most 3 ms and wrapping the texture at most 1.4 ms. The start of these
8-layer steps has no such frame (no decode over 22 ms), and neither have the 48 later switches of
the first 12 steps, made at a load average of 4 to 6 (at most two decodes over
25 ms at a switch, none over 29 ms, no stale frame). The thirteenth step,
started at a load average of 17, has slow decodes again at its last switch: 34
of 25 to 107 ms on all 16 decoders, spread over 140 ms with no moment at which
all are blocked, at least four fifths of each inside the same call, and 32
stale frames over 7 ticks; its three switches in between are clean. HAP Q,
which does not decode through VideoToolbox, showed no block in three steps (15
switches, 0 stale frames, no decode over 26 ms, at a load average of 21 to 26).

The stale frames are always the incoming picture's: none of the 104 outgoing
pictures drew one. An outgoing ring holds up to 8 frames, 133 ms at 60 fps (its
depth at the switch was not traced). An incoming picture is swapped in as soon
as its ring holds a frame, and at the first switch the loader had handed it
over 22 to 43 ms before the block began. Split afterwards by how far each
decoder had come: of the 20 incoming pictures whose decoder had finished no
frame beyond the last one the clock asked for until its release, 19 drew stale
frames; the other 84 drew none (the line was drawn after seeing the result). At
the first switch they drew them within 85 ms of the swap, when a 2 s dissolve
in normal blend shows the incoming picture at less than 5 %. Not measured:
whether it shows on a cut or a short dissolve, and whether the installed engine
has it.

What sets it off, measured the same day from 16:01 to 16:10 with the same trace
build on a quieter Mac (22 single steps of 20 s after a 2 s warm-up, headless,
ProRes 422 HQ 1080p60; load average 1.4 to 3.6 at the start of a step, three
steps at 4.8 to 7.4): the number of ProRes decoders in use at once, the first
time it is 14. A decoder is a decompression session, a decode thread and a ring
of 8 frames, one per playing file; the steps cannot tell those three apart, nor
the decode work that comes with them. A step without dissolves starts all its
decoders together. With 9, 12 and 13 layers there is no decode over 23 ms at
the start (4 steps); with 14, 15 and 16 layers the block is there (6 steps: 14
to 18 decodes of over 25 ms on 14 to 16 decoders, up to 78 ms, 90 % or more of
each inside the call). A step with dissolves has two decoders a layer from a
switch until the outgoing one is retired 2 s later. With 4, 5 and 6 layers (8,
10 and 12 decoders) no decode takes over 18 ms at any switch and no frame is
stale (7 steps); with 7 and 8 layers (14 and 16 decoders) the block is at the
first switch and at none of the four later ones (5 steps), where by the code
the count has fallen back to 7 or 8 and returns to 14 or 16. So in these steps
it comes the first time 14 are in use and not again within the 20 s; the steps
without dissolves have only their start to show. The line between 13 and 14
rests on one step of 13 and one of 14 layers without dissolves and on two steps
each of 6 and 7 layers with them. It is not the size of the burst alone: 13
decoders opened together show no block, 7 opened next to 7 running ones do.
Where it falls decides what it costs: the 15 and 16-layer steps drew 1 and 4 to
8 stale frames in the warm-up, outside the window, and pass; the 8-layer steps
with dissolves drew 2 to 5 in the window and fail; the two 7-layer steps had
the block and no stale frame. Eight steps made from 15:07 to 15:11, at a load
average of 6 to 12, are left out: they had slow decodes with 8 decoders too (up
to 90 ms at the start of one 8-layer step, 31 and 32 ms at two switches of a
4-layer step) and at other moments, so load alone does this as well, and "none
below 14" holds for the 22 quiet steps. Not measured: what VideoToolbox does at
that count, which of session, thread and ring it counts, whether the count is
this chip's (M1 Pro), other sizes and ProRes kinds, whether it comes again at a
higher count (16 layers with dissolves are 32 decoders) or after a longer time
below 14, and whether decoders opened and used once at engine start would take
it away from the first switch. The paragraphs below answer the count and the
last.

What it counts, measured the same day from 16:20 to 16:50 (load average 2.7 to
7.5): bytes of decoder output held, not sessions, threads or frames. One
session that decodes one black ProRes 422 frame over and over and keeps every
output buffer has exactly one slow decode, of 61 to 63 ms: the one after 121
buffers at 1080p (three runs; 8.55 MB each, 1.035 GB held), after 30 at 4K (two
runs; 34.1 MB each, 1.023 GB) and after 271 at 720p (two runs; 3.83 MB each,
1.037 GB; sizes as `CVPixelBufferGetDataSize` gives them). No other decode
takes over 15 ms up to 400, 120 and 800 buffers (3.4, 4.1 and 3.1 GB), and none
at all when at most 60 buffers (0.5 GB) are held over 400 decodes. So the mark
is between 1.037 and 1.041 GB of held output, and the 14 decoders above are 112
ring frames of 8.55 MB plus what each holds beside its ring. Passing it before
the service starts takes the block away from the first switch of an 8-layer
step with dissolves: with 16 decoders of the bench file decoding 32 frames each
(three steps), with 16 sessions of the black frame holding 8 buffers each
(two), and with one session holding 140 (two, and one more that waited 61 s
before the service started). It stays at the first switch when the 16 sessions
hold nothing (three steps; in a fourth, which waited 60 s, the bench's switch
timer fired during the wait and the block fell at the start) and when the 16
file decoders decode 2 frames each (two).

The engine passes the mark itself since PR #427 (`DecoderWarmUp`): one black
1080p ProRes frame is encoded and decoded through one hardware session, every
buffer kept, until 1.5 GB is held, and all of it is let go. The engine runs it
at its start, right after the library's first scan when that shows a ProRes
movie that plays, and goes on only when it is done; `fanous-bench` does the
same before its first ProRes step. Not on a Mac with less than 16 GB of memory.
In 19 runs it took 0.46 to 0.52 s (release bench) or 0.36 to 0.48 s (test
engine), and its longest decode, 57 to 60 ms, began every time with 1034 MB
held: the mark. With it, nine steps of 8 ProRes layers in permanent dissolves
(seven of the branch's bench, two of the trace build) pass with 0 stale frames,
where most failed on the first switch before (1 to 6 stale frames, 26 in one
step); traced, no decode at the start or at a switch takes over 19 ms. Six
steps of 16 layers without dissolves pass too, but their start lies 2 s before
the measured window, so a pass does not see it. Traced (two steps), that start
has 3 and 2 decodes of 25 to 44 ms inside VideoToolbox and 0 and 2 stale
frames, against 4 to 8 stale frames in the four steps of 16:00 on 2026-11-19,
without the warm-up; why those few decodes are slow is not measured (B392). On
a test engine with a ProRes clip in its library, started twice on one home, the
second start (the index cached) logs `library scanned`, then `decoder warm-up
heldMB=1505 longestAtMB=1034 longestDecodeMs=60 ms=481`, then its start steps
and the listener; the clip then plays on a layer. The memory is the system's
wired memory, not the process's footprint (`footprint` showed a peak of 43 MB):
2.61 GB before an engine started, 3.38 GB in the last sample taken during the
warm-up (its peak was not caught), 2.68 GB two seconds later.

A library that shows its first ProRes movie later (files the first scan could
not read from the cache and that are still being probed: the first start on a
home, a file that changed, a release that probes everything again; an upload;
another root) starts the same warm-up from the index on a thread of its own,
and the loader does for a ProRes movie the library had not shown (a scene's
file). Pictures may play then. Measured with the loader as the only trigger, in
nine steps of 8 layers in dissolves (six of the bench, three traced): all pass
with 0 stale frames, and the block falls 0.14 to 0.16 s after the first
hand-over on the 8 decoders that play (58 to 62 ms each), whose rings are full
by then. A picture swapped in during those 0.2 s would meet the block, and 16
layers started together pass the mark by themselves 70 ms after their start,
before the warm-up gets there (7 and 8 stale frames in two steps); both are
B392. Not measured: the mark on another Mac or macOS (the log line gives the
longest decode and where it began; at 0 MB it is the session's first decode and
there was no block), what VideoToolbox does there, 4K layers in the engine (4
of them hold 1 GB), an engine start that restores ProRes layers, and a cut.

Display runs, 2026-11-19: main `cc1c002b`, `--display 0` (the built-in 120 Hz
panel, the only display attached), the same criterion, load about 3 to 6.
Single steps, no ramps:

| Variant | Codec | Canvas | Window | Result |
|---|---|---|---|---|
| 16 layers | ProRes 422 HQ | 1080p60 | 120 s | first run **fail on 101 stale frames** (7227 frames, 0 missed, 0 late, 0 texture misses, GPU p99 10.5 ms); second run **pass** (7224 frames, 0 stale, 10.1 ms) |
| 16 layers | HAP Q | 1080p60 | 120 s | **pass**, 7224 frames, GPU p99 9.6 ms |
| invert + tint on all 16 layers | HAP Q | 1080p60 | 20 s | **pass**, GPU p99 12.4 ms |
| invert + tint on all 16 layers | ProRes 422 HQ | 1080p60 | 20 s | **pass**, GPU p99 12.7 ms |
| permanent 2 s dissolves, 8 layers | HAP Q | 1080p60 | 20 s | **pass**, 0 stale, GPU p99 10.1 ms |
| permanent 2 s dissolves, 8 layers | ProRes 422 HQ | 1080p60 | 20 s | **pass**, 0 stale, GPU p99 10.6 ms |
| blur + edge on every layer, 2 layers | both | 1080p60 | 20 s | **pass**, GPU p99 4.8 ms (HAP Q was 10.3 ms on 2026-10-23, before the scratch pass of B2) |
| blur + edge on every layer, 5 layers | both | 1080p60 | 20 s | **pass**, GPU p99 9.8 ms (HAP Q) and 10.5 ms (ProRes) |
| 4 layers | ProRes 422 HQ | 4K60 canvas | 20 s | **pass**, GPU p99 10.4 ms |
| 5 layers | ProRes 422 HQ | 4K60 canvas | 20 s | **pass**, GPU p99 12.5 ms |
| 6 layers | HAP Q | 4K60 canvas | 20 s | **fail**, 6 late (GPU p99 14.0 ms); the headless ramp passed 6 |

The 101 stale frames of the first ProRes run did not come back in the second,
nor in four more 2-minute runs on main `1fb204ba` (7212 to 7228 frames each,
0 stale): one run in six. That first report does not say which layers drew
them or in how many ticks in a row (B391). That run has the
report file; the passing reruns have none (same name). The compositor allocated 21.0 times per tick in the plain
runs, 32.0 and 47.0 with blur + edge on 2 and 5 layers.

Traced on 2026-11-19 (the trace build of B389, which timestamps every decode
and splits it into reading the sample, the VideoToolbox call and wrapping the
texture): two more 2-minute runs of the 16 ProRes layers on the built-in
display. The first drew no stale frame and has no decode over 12 ms in its
window. The second drew 69 (7206 frames, 0 missed, 0 late): 1 on layer 12 and
20, 25 and 23 on layers 14, 15 and 16, one or two frames behind, in eight runs
of consecutive ticks (the longest 7) within two spells at 94.45 to 94.71 s and
95.06 to 95.78 s. Of the 692 decodes that take over 12 ms in the window (119
over 25 ms), 686 fall between 94.3 and 95.9 s and the other six, of 12 to 19
ms, at 82.1 s. They are on all 16 decoders but unevenly: 1 to 7 on layers 1 to
4, 29 to 70 on the others. In every one over four fifths of the time is inside
the call that reads the sample (`sampleBuffer(at:)`, which steps the cursor and
asks `AVSampleBufferGenerator` for the sample; wall-clock, up to 62 ms where it
takes about half a millisecond, median 0.46 to 0.53 ms in these runs), and the
VideoToolbox call takes at most 0.9 ms. So the time behind those stale frames
is in the read call, not in the VideoToolbox decode, the texture wrap or the
compositor. The rings did not run empty: the decoders of layers 12, 14, 15 and
16 spent 1.35 to 1.43 s of those 1.6 s in slow decodes, their rings fell to 2
or 3 frames, and the frames in them lagged the clock (layer 13, with 1.34 s,
kept 5 and drew none). The same came once more in a headless step of 16 layers:
98 of its 103 decodes over 12 ms within 0.25 s at the end of the window (up to
54 ms in the read, no stale frame; the window may have cut the spell short).
One more headless step of 16 layers that day drew 45 stale frames in six runs
of ticks (the longest 8, at 16.8 s) with 72 decodes over 25 ms outside its
start; its trace was overwritten, so where their time went is not known. The
run with 101 has no trace: that it was the same is possible, not shown. Not
measured: what holds the call up (the disk, the file cache, a lock in
AVFoundation shared by the generators of one file, the decode thread not being
scheduled, another process), and whether layers that read different files meet
it together: here all 16 read one file.

## Measured again, 2026-11-19 and 21 (B390)

The rows the section above had not repeated, and its ramps once more. Same
machine and macOS, headless, 20 s windows, the installed engine stopped, kept
awake. The ramps are of 2026-11-19, 17:03 to 17:46, on the branch of PR #427 at
`0c0f5e04` (the rerun of one ramp with later changes of that branch); the rest
is of 2026-11-21, 17:06 to 18:33, on its final code (`b6115fb7`, the soak
`2a86eaff`). In all of them the decoder warm-up of B389 is done before the
first measured window. The load average over one minute at the start of a step
was 1.4 to 6.1 (the HAP Q dissolve steps 7.4, 9.7 and 12.3, the hour's soak
7.6), over 15 minutes 2.9 to 6.0. The two 4K60 ramps and the HAP Q ramps of
2026-11-19 ran at 1.4 to 2.6, quieter than the 3 to 6 of the section above, the
ProRes 1080p60 and 4K30 ramps at 4.4 to 6.0; the series of 2026-11-21 was not
clearly quieter: the system's photo analysis and Spotlight ran during parts of
both days, and the desktop app this was run from used several cores when the
second series started. Pass = 0 missed, 0 late, 0 texture misses, 0 stale
frames.

| Codec | Canvas | Max layers | GPU p99 there | First failure |
|---|---|---|---|---|
| ProRes 422 HQ | 1080p60 | 16 (cap) | 8.7 ms | — |
| ProRes 422 HQ | 4K30 | 16 (cap) | 13.1 ms | — |
| ProRes 422 HQ | 4K60 | 6 | 13.2 ms | 7: 98 late frames |
| HAP Q | 1080p60 | 16 (cap) | 8.7 ms | — |
| HAP Q | 4K30 | 16 (cap) | 15.2 ms | — |
| HAP Q | 4K60 | 6 | 12.9 ms | 7: 119 late frames |

No step had a stale frame or a texture miss, and the compositor allocated 4.0
times per tick in every passing step. The ProRes 1080p60 row and its report are
the second ramp's: the first, about 35 minutes earlier with the photo analysis
at about half a core, stopped at 9 layers on 2 late frames. ProRes 4K60 holds 6
layers here and 5 in the section above.

Blur + edge on every layer:

| Run | Codec | Canvas | Result |
|---|---|---|---|
| ramp | ProRes 422 HQ | 1080p60 | **5 layers** (GPU p99 9.3 ms); 6 fails with 90 late |
| ramp | HAP Q | 1080p60 | **8 layers** (8.5 ms); 9 fails with 107 late |
| ramp | ProRes 422 HQ | 4K30 | **8 layers** (26.9 ms); 9 fails with 6 late |
| ramp | HAP Q | 4K30 | **8 layers** (27.4 ms); 9 fails with 2 late |
| single step, 16 layers | ProRes 422 HQ | 1080p60 | pass (13.7 ms) |
| single step, 16 layers | HAP Q | 1080p60 | pass (14.5 ms) |
| single step, 16 layers | both | 4K30 | fail: 412 and 385 frames late, GPU p99 135 and 161 ms |

At 1080p60 it is again not monotone: the ProRes ramp fails on late frames at 6
layers and the HAP Q ramp at 9, and 16 layers pass for both (B388). The
compositor allocated 31 to 46 times per tick in the last passing step of a ramp
and 86 at 16 layers.

GPU cost per effect:

| Effect | GPU p50 | GPU p99 | p50 over no effect |
|---|---|---|---|
| none | 0.64 ms | 0.67 ms | — |
| pixelate, invert, luma key, mirror, tint, threshold, chroma key | 0.65–0.77 ms | 1.1–2.4 ms | ≈ 0.0–0.1 ms |
| edge (Sobel, 9 taps) | 1.00 ms | 1.5 ms | ≈ 0.4 ms |
| kaleidoscope | 1.37 ms | 2.9 ms | ≈ 0.7 ms |
| blur (radius 2.5 % of height) | 1.88 ms | 3.3 ms | ≈ 1.2 ms |
| blur + edge | 3.67 ms | 4.8 ms | ≈ 3.0 ms |

One 1080p HAP Q layer, the whole frame with clear and output pass. With one
light layer the p99 moves much more than the p50, so both are given; the table
of 2026-10-23 quotes p99 only (blur 2.5, edge 2.2, both 5.2 ms, before the
scratch pass of B2). Blur and edge allocate 11 and 7 times per tick on the
compositor thread, the others 4. The differences are those of one layer and do
not add up or scale: the first step of the HAP Q blur + edge ramp, the same one
layer, has a p50 of 2.42 ms where the single step has 3.67, and 16 layers with
blur + edge have a p50 of 13.2 ms against 6.3 without, about 0.4 ms a layer.

Both effect slots on every layer, dissolves, ingest:

| Variant | Codec | Canvas | Result |
|---|---|---|---|
| invert + tint on all 16 layers | HAP Q | 1080p60 | **pass**, GPU p99 13.7 ms |
| invert + tint on all 16 layers | ProRes 422 HQ | 1080p60 | **pass**, GPU p99 9.4 ms |
| pixelate + kaleidoscope on all 16 layers | HAP Q | 1080p60 | **pass**, GPU p99 11.5 ms |
| invert + tint on all 16 layers | HAP Q | 4K30 | **pass**, GPU p99 17.8 ms |
| permanent 2 s dissolves, 8 layers, three steps | ProRes 422 HQ | 1080p60 | **pass** three times, 0 stale, GPU p99 9.0 to 9.7 ms |
| permanent 2 s dissolves, 8 layers, three steps | HAP Q | 1080p60 | **pass** three times, 0 stale, GPU p99 8.8 to 8.9 ms |
| 8 layers + ingest ProRes 4444 → HAP Q, 40 s | HAP Q | 1080p60 | **pass**, GPU p99 6.4 ms; the job was done when the window ended (log line) |
| 8 layers + ingest ProRes 4444 → HAP Q, 40 s | ProRes 422 HQ | 1080p60 | **pass**, GPU p99 6.7 ms; job done |

Audio, one HAP Q 1080p60 layer with a 48 kHz LPCM track (a 10 s file, headless,
the layer clock is master): the 20 s run had 0 underruns, 5 drift corrections
and a largest drift of 18.3 ms, where 2026-10-23 had 0 corrections and 11.8 ms.
The one-hour soak: 0 underruns (26 on 2026-10-23, at the loop wraps), 6 drift
corrections (0 then) and a largest drift of 20.1 ms (15.3 then); video 0
missed, 0 late and 0 stale in the last 16 384 ticks. Four more runs of 20 and
60 s had 4 to 6 corrections and 18.2 to 19.9 ms: the count does not grow with
the window (5, 5, 5 and 6 in 20 s, 4 in 60 s, 6 in an hour), which suggests
they come early; when they fall is not measured. The acceptance "drift < 20 ms
over 1 h at 1×" is missed by 0.1 ms. The playback fixes of 2026-11-18 are not
needed for it: the bench of rc.14 (2026-11-17), which predates them, gave 0
corrections and 13.2 ms once and 6 and 4 corrections with 19.2 and 19.9 ms
twice on the same file. So 10 of these 11 runs have a largest drift of 18.2 to
20.1 ms and corrections, and one has neither; what decides it is not measured
(B393). The soak's report shows 52.7 allocations per tick: an hour's count over
the ticks the metrics ring still holds; over the hour it is 4.0.

Not repeated: the runs on a 4K display and DMX→photon (B390), and the 8-hour
soak (B333). The report files of this section are the `…-2026-11-19` ramps and
the `…-2026-11-21` steps; a step that ran three times has the last one's, and
the one-layer step without an effect shares its name with the 20 s audio run,
whose report it is; the other audio runs have no report file. The dissolve
steps have no stale frame because the bench runs the decoder warm-up of PR #427
first.

## Results of 2026-10-23 (MacBook Pro M1 Pro, 32 GB, macOS 27.0.1)

The headless rows are superseded by the section above, the display rows by its
display runs of 2026-11-19.

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
the engine defaults to 8 at every resolution (`RenderService.ringCapacity`);
`fanous-bench` used 6 up to 2000 px width and 8 above for these runs and takes
the engine's value since 2026-11-18. The remaining 4K60 ProRes
failures are single late decodes in 20 s windows (zero-tolerance criterion),
to be attacked in Phase 3 (decode-thread scheduling, VT asynchronous decode).

DMX→photon (Art-Net receive → target presentation time, display path, 60 fps
canvas, 2 layers, ~35 Hz DMX): p50 25.2 ms, p99 32.1 ms (n = 598), i.e. within
two frames; the display's own scan-out latency is not included.

Decode (one frame, p50, release build): ProRes 422 HQ 1080p 0.8 ms / 4K 1.8 ms;
ProRes 4444 1080p 1.8 ms (`y416`, alpha kept) vs 0.95 ms native; HAP Q 1080p
0.8 ms / 4K 1.6 ms (chunked, parallel); HAP 1080p 0.4 ms.

## Phase 3 (2026-10-23): effects, dissolves, audio

The blur + edge and dissolve rows below are superseded by the section
"Re-measured 2026-11-18 and 19", and so are the display rows of this table
(invert + tint on 16 layers, dissolves on 8, blur + edge on 2); the headless
per-pixel effect rows, the cost per effect and the audio runs were repeated on
2026-11-21 ("Measured again, 2026-11-19 and 21").

Same machine and criterion; release build; `scripts/bench.sh phase3` runs the
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
1080p layer each per layer they are on; the Layers screen does not show that
cost yet. A cheaper blur (separable or mip-based) is a
v1.x option if shows want blur on many layers at once.

A dissolve costs exactly one extra layer (its decoder and draw) for its
duration: the incoming media is staged until its first frame is decoded, so
switching files never shows a texture miss.

Audio (one HAP Q 1080p60 layer with a 48 kHz LPCM track, headless, the
layer clock is master): 20 s run 0 underruns, 0 drift corrections, max drift
11.8 ms. **One-hour soak** (`scripts/bench.sh drift`,
`…-layers1-soak3600s-2026-10-23.md`): max drift 15.3 ms, 0 drift corrections,
26 underruns over 360 loop wraps of the 10 s file (a loop wrap is a reseek
with one callback of silence; gapless loop reads are a v1.x item), video
0 missed / 0 late (the frame metrics ring holds the last 16 384 ticks, so
those cover the final 4.5 min; the audio counters cover the whole hour).
Acceptance "drift < 20 ms over 1 h at 1×" met (2026-10-23; missed by 0.1 ms
on 2026-11-21, B393).

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

## Display output drops (2026-10-26)

With an output on the built-in 120 Hz ProMotion panel the engine missed 15–25
frames in a 2–3 s burst every 15–20 s, while CPU (0.15 ms) and GPU (≤ 4 ms)
were idle. Same scene (motion test, colour sweep, clock, ProRes 4444 1080p60),
2 min each, release builds:

| Build | No viewer | Preview viewer |
|---|---|---|
| before the review round (`7513cf1`), 2 drawables | 48 missed / 77 late | 40 / 58 |
| after the review round, 2 drawables | 0 / 0 | 73 / 93 |
| after the review round, **3 drawables**, 3 min each | **0 / 0** | **0 / 0** |

Cause: the drawable loop runs on its own 60 Hz clock, the display on its own;
with two drawables both were periodically still in flight when the phases met
badly, so `nextDrawable()` blocked. Not a regression of the review round (the
older build shows it too). The 8 h soak ran headless and did not see it.

16 layers on the 120 Hz built-in panel with three drawables (release, 2 min
each, `fanous-bench run --layers 16 --window 120 --display 1`; repeated on
2026-11-19 with the stale-frame criterion, see "Re-measured 2026-11-18 and 19"):

| Codec | Frames | Missed | Late | Texture misses | GPU p99 |
|---|---|---|---|---|---|
| ProRes 422 HQ 1080p60 | 7203 | 0 | 0 | 0 | 10.0 ms |
| HAP Q 1080p60 | 7267 | 0 | 0 | 0 | 9.6 ms |

The drawable count does not scale with layers or outputs: layers are
composited into the canvas first (their own frame rings sit at the decoders),
and every output window has its own three drawables. More layers raise the
GPU time per frame; while that stays under the frame period three drawables
suffice, and when it does not, more drawables would only add latency.

