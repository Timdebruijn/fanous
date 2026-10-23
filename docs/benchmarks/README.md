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
