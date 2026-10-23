# Backlog: deferred items

Everything we decided not to do yet, with where it came from and what would
trigger picking it up. Phase summaries add to this file; items leave it when
they land or when `docs/DESIGN.md` §21/§22 absorbs them. Owner column: who
has to act (engine = this codebase, owner = Tim).

| # | Item | Origin | Trigger / plan | Owner |
|---|---|---|---|---|
| B1 | ProRes 4K60 decode jitter: single texture misses per 20 s window at 4–7 layers (throughput is fine, 1.8 ms/frame) | Phase 2 benchmarks | decode-thread scheduling (QoS/affinity), asynchronous VT decode with a deeper request queue; re-measure with `lanthorn-bench run --codec prores422hq --res 3840x2160p60` | engine |
| B2 | Cheaper blur (separable two-pass or mip-based) — the 13-tap single-pass blur costs ≈ 1.9 ms per 1080p layer | Phase 3 benchmarks | when a show wants blur on more than 2–3 layers at 1080p60; needs an intermediate texture per layer (DESIGN §4.3 rule) | engine |
| B3 | Gapless audio loop (a loop wrap is a reseek with one silent callback; 26 underruns per 360 wraps) | Phase 3 audio soak | read across the loop point in `AudioTrackReader`; also pre-roll the ring after a long pause | engine |
| B4 | Audio output-device latency compensation and device selection by UID (`AudioMixer.deviceUID` is ignored) | Phase 3 audio | machine setting in Phase 5 System screen; measure with a loopback | engine |
| B5 | Hardware ProRes decode fails on very small frames (64×48 gave VideoToolbox −12910; 320×176 works) | Phase 3 ingest test | find the minimum size, reject/upscale in ingest, document | engine |
| B6 | Syphon output visible in a third-party app (acceptance item): `xcodebuild` on this Mac needs `sudo xcodebuild -runFirstLaunch` before the Syphon Simple Client can be built; cross-process transport is verified with `lanthorn-bench syphon` | Phase 3 | owner runs the first-launch step, then build `scratchpad/syphon/Simple` and look | owner |
| B7 | GDTF import check in grandMA3 onPC and Eos Nomad (acceptance item of Phase 1) | Phase 1 | owner installs the consoles (admin password), then `lanthornd gdtf` and import | owner |
| B8 | Apple Feedback for the CAMetalDisplayLink stall (three updates after presenting, macOS 27.0.1, also with an activated key window) | Phase 2, re-tested Phase 3 | `docs/benchmarks/cametaldisplaylink-repro.swift`; text can be drafted on request; re-test the `useDisplayLink` switch on every macOS release | owner |
| B9 | 3D-model layers: a layer renders a mesh (Model I/O / USDZ) with the media as texture instead of a quad; needs a depth attachment on the canvas pass and a "Geometry" channel in the reserved Layer block (51–64) | owner question, Phase 3 | v1.x after Phase 6 (output mapping covers 2D needs); DESIGN §21 row | engine |
| B10 | 16-bit stills (`StillSource` decodes to 8-bit sRGB) | Phase 3 | when HDR/16-bit content shows banding; `rgba16Unorm` path in `StillSource` | engine |
| B11 | Strobe phase jump once per hour (`texel.w` wraps at 3600 s) | Phase 3 | per-layer Double phase if anyone notices | engine |
| B12 | Syphon relies on `kIOSurfaceIsGlobal` (deprecated since 10.11, upstream behaviour) | Phase 3 vendoring | watch upstream; nothing to do unless Apple removes it | engine |
| B13 | Art-Net OEM code registration (0xFFFF until then), trademark search, MDM profile, CA profile for iPads | DESIGN OPEN-17/20/21/25 | before 1.0 | owner |
| B14 | DMX band review (OPEN-9) and serial fixture timing (OPEN-7) | DESIGN | OPEN-9 is locked by the shipped GDTF unless changed before 1.0; OPEN-7 is v1.x | owner |
| B15 | UI design artifact: at the start of Phase 5, before the first screen, make a Design artifact (design system tokens + Layers, Media, Patch/DMX, Outputs & Mapping screens per DESIGN §12: dark stage-safe theme, red/yellow/green status semantics, ≥ 44 px touch targets, monospace DMX/timecode values, the four roles visible); owner reviews, tokens become CSS variables in `web/` | owner decision 2026-10-23 | first task of Phase 5 | engine |
| B16 | HAP Q Alpha (`HapM`) cannot be written: `HAPEncoder` has no YCoCg+alpha variant, so alpha sources go to HAP Alpha (`Hap5`, lower quality) or ProRes 4444 | Phase 4 ingest | add the two-texture HapM encode to HAPEncoder when a show needs HAP-speed alpha at HAP Q quality | engine |
| B17 | Ingested HAP files verified only in the engine; the acceptance item "plays in VLC/QuickTime with the HAP plugin" needs VLC (not installed) | Phase 4 | owner installs VLC (or allows the download), then open an ingested `.mov` | owner |
| B18 | Ingest rejects rotated/flipped sources (`preferredTransform`, phone footage) instead of baking the rotation in | Phase 4 ingest | `AVAssetReaderVideoCompositionOutput` with the track transform | engine |
| B19 | Ingest writes one output frame per source frame: variable-frame-rate sources drift against their audio; pixel aspect ratio is not carried over; audio is stored as 16-bit LPCM | Phase 4 ingest | PTS-based hold/drop resampler, PAR in the format description, 24/32-bit option | engine |
| B20 | HAP sources cannot be re-ingested (AVFoundation has no HAP decoder); ingest reports "cannot decode" | Phase 4 ingest | decode through `MovieSource` + read-back when HAP→ProRes conversion is wanted | engine |
| B21 | Colour tagging of ingested files follows the reader's pixel buffers; Rec.601 vs Rec.709 handling unverified | Phase 4 ingest | check with a tagged 601 source and the layer shader's 709 matrix | engine |
| B22 | Tests run serially (`scripts/test.sh --no-parallel`): Swift Testing runs tests as tasks on the cooperative pool, and AVAssetWriter needs that pool too, so many media-writing tests at once deadlock | Phase 4 | move media writing in tests to plain threads (as IngestQueueTests does) and re-enable parallel runs | engine |
