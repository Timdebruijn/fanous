# Fanous — Design

Status: **Approved 2026-10-22** (defaults of §22 accepted) · Owner: Tim de Bruijn

Fanous is an open-source media server for live events, programmed from a
lighting console as if it were a fixture (Catalyst-style). This document is the
single design reference for v1. Key decisions are recorded as ADRs in
`docs/adr/`; where this document and an ADR disagree, the ADR wins. Open
questions are tagged `[OPEN-n]` inline and collected in §22.

Conventions: "engine" = the headless render process `fanousd`; "shell" = the
native WKWebView host app; "client" = any UI (shell or browser); "console" =
the lighting desk sending DMX.

---

## 1. Goals, non-goals, priorities

**Priorities, in order:** 1) never drop a frame or lose an output during a
show, 2) predictable DMX behaviour, 3) a UI that shows at a glance what the
server is doing and why, 4) feature count.

**v1 scope** is the owner's kickoff brief "Scope v1" list plus its
clarifications (audio, stills, image sequences, Syphon input, 3D layer
rotation, Output fixture); the brief itself is internal and not in the
repository. Everything under "Later" is designed for (an
extension point exists) but not built.

**Non-goals:** SMPTE ST 2110, generative/real-time 3D engines, XR, Windows,
Linux, Intel, base M1, a timeline editor.

**Platform floor:** Apple Silicon with a hardware ProRes engine. Minimum macOS
15 (ADR-0020; the brief said 14, raised with the owner's approval of `[OPEN-1]`).
Shaders are compiled at engine start from source (`MTLDevice.makeLibrary(source:)`),
so no offline Metal toolchain is needed to build or run.

---

## 2. Process architecture

```
┌──────────────────────────── Fanous.app ─────────────────────────────┐
│  Contents/MacOS/Fanous          shell: AppKit + WKWebView, no logic  │
│  Contents/MacOS/fanousd         engine: headless, owns everything   │
│  Contents/Library/LaunchAgents/org.fanous.engine.plist              │
│  Contents/Resources/web/          built UI (static files)             │
└───────────────────────────────────────────────────────────────────────┘

   console ──Art-Net/sACN──▶ ┌──────────┐ ──Metal──▶ displays (outputs)
   OSC / MTC / LTC ────────▶ │ fanousd│ ──Syphon─▶ other apps
   shell / browsers ◀─HTTPS─▶│          │ ──CoreAudio▶ audio device
   console ◀───CITP/MSEX───▶ └──────────┘ ──logs/metrics
```

### 2.1 Engine as a LaunchAgent in one bundle (ADR-0001)

- `fanousd` is registered as a **LaunchAgent** via `SMAppService.agent(plistName:)`
  from the shell's first launch. It runs in the logged-in user's session (a
  LaunchDaemon cannot reach the WindowServer, so it cannot drive displays).
  `KeepAlive` restarts it within ~1 s after a crash; `RunAtLoad` starts it at
  login. Auto-login is a deployment choice for unattended machines, not a
  requirement: the user starts `Fanous.app` like any app, the app starts the
  agent if it is not running. macOS asks once to allow the agent under
  System Settings › Login Items; the shell detects "not approved" and shows a
  banner with the exact step.
- The shell is disposable: it only hosts the UI. Quitting it does not stop the
  engine. It also offers Start/Stop/Restart engine, "Open logs", "Install /
  remove service" and the About screen (attribution, see §17).
- The engine can also run in the foreground for development
  (`swift run fanousd --foreground --project X`). Same binary, no agent.
- The engine creates its output windows itself. It runs an `NSApplication`
  with activation policy `.accessory` (no Dock icon, no menu bar), so it can
  create borderless fullscreen windows at shielding window level on any
  display without ever becoming the frontmost app.
- One instance per user: a lock file in `~/Library/Application Support/Fanous/`.
  A second start exits with a clear message.

### 2.2 Threading model (ADR-0002)

No Swift Concurrency (async/await, actors) in the render, decode, DMX, audio or
timecode paths. Those run on dedicated threads or dedicated serial queues at
`.userInteractive` QoS, communicate via lock-free SPSC rings and atomically
swapped immutable snapshots, and allocate nothing in steady state. Swift 6
language mode is used everywhere; the lock-free boundaries are the only places
with `@unchecked Sendable` / `nonisolated(unsafe)`, each with a comment that
names the invariant.

| Thread / queue | Kind | QoS | Owns | Hot-path rule |
|---|---|---|---|---|
| **Compositor** | `Thread` with its own RunLoop hosting the master `CAMetalDisplayLink` | `.userInteractive` | layer clocks, canvas render passes, output pass for outputs on the master display, preview downscale | zero allocations, no locks, no Swift Concurrency |
| **Output-N** (one per non-master display) | `Thread` + RunLoop + `CAMetalDisplayLink` | `.userInteractive` | output pass + present for that display | reads latest completed canvas texture via atomic index; parameters from the DMX side's copy under its lock (one fixed-size copy per frame, ADR-0002 amendment) |
| **Decode-L** (one per layer) | `Thread` | `.userInitiated` | demux + decode for layer L, frame ring producer | preallocated pixel-buffer/texture pool, no allocations after warm-up |
| **HAP chunk pool** | fixed pool of P-core-count threads | `.userInitiated` | Snappy/DXT chunk decode for all HAP layers | work items are preallocated slots |
| **DMX** | serial `DispatchQueue` (Network.framework requires a queue) | `.userInteractive` | Art-Net/sACN receive, parse, universe buffers, parameter resolution | packet → parameters in one pass, no allocations; measured latency, see §13; one bounded lock per published snapshot, for the non-render copy (ADR-0002 amendment) |
| **Control** | serial `DispatchQueue` | `.userInitiated` | project model, commands, undo, cue engine, OSC, publishes scene config + parameter snapshots to render side | may allocate; never touched by render threads |
| **Audio out** | CoreAudio real-time render callback (`AVAudioSourceNode`) | RT | mixes per-layer PCM rings | RT-safe, no allocations/locks |
| **Audio in / LTC** | CoreAudio real-time input callback (`AVAudioSinkNode`) | RT | LTC bit decoding | RT-safe |
| **MIDI / MTC** | CoreMIDI callback thread, then one serial `DispatchQueue` per input (as built, B36/B64) | `.userInteractive` | the callback copies the words (MTC: with the packet's host time) and hops; the queue parses, assembles MTC quarter frames and follows hot-plug | one small array per packet; never touched by render threads |
| **Network/UI** | Network.framework queues (one per listener + per connection), `.utility`/`.userInitiated` | — | HTTPS, WebSocket, state diffs, thumbnails | bounded per-client queues; drop, never block |
| **Preview encoder** | VideoToolbox callback + serial queue | `.utility` | H.264 preview, JPEG thumbnails, CITP frames | bounded; skips frames when behind |
| **Ingest** | serial `DispatchQueue`, one job at a time | `.utility` | transcodes | paused while show-locked (configurable) |
| **Housekeeping** | timer on Control | `.background` | metrics aggregation, project snapshots, library rescans | — |

**Data flow between domains**

- *Control → Render:* an immutable `SceneConfig` struct (canvases, outputs,
  slices, blend/warp maps, layer→canvas assignment, patch) is published by
  atomic pointer swap (`Unmanaged`, retained by the publisher until the render
  side has acknowledged two frames; the old config is released on Control).
  Render threads never hold a reference across frames.
- *DMX/Control → Render:* a triple-buffered `ParameterSnapshot` (plain
  `Float`/`UInt8` fields, one struct per layer plus master/outputs). Writer
  (resolution step on the DMX queue) publishes a slot index atomically; the
  compositor reads the latest at the start of each tick. The compositor is the
  only reader: other threads (CITP layer status, secondary displays) read a
  copy the writer makes of each published slot behind a lock (`withLatest`,
  B71). Values from internal
  sources (cues, OSC, UI) are merged into the same snapshot by the resolver
  (§7).
- *Decode → Render:* per-layer SPSC ring of `FrameSlot`s (preallocated;
  texture(s), pts, flags). Compositor consumes, decoder produces; both sides
  use acquire/release atomics from the stdlib `Synchronization` module if
  macOS 15 becomes the floor (`[OPEN-1]`, recommended), otherwise
  `swift-atomics`.
- *Render → UI:* metrics ring (struct per frame), preview textures (triple
  buffer), DMX monitor snapshots; readers are on UI threads and only ever
  read "latest completed".
- *UI → Control:* commands over WebSocket, serialized onto Control.

**Frame budget at 60 Hz (16.7 ms):** compositor CPU ≤ 2 ms, GPU ≤ 10 ms at the
tier's declared layer count, decode lead ≥ 2 frames, `preferredFrameLatency = 1`
on every display link. Budgets are measured, not assumed (§13).

### 2.3 Failure isolation

- UI, network and ingest cannot block render: all queues are bounded with
  drop-oldest semantics, and render threads never wait on anything except the
  display link and GPU completion of their own previous frame.
- A decoder failure (corrupt file, unsupported stream) marks the layer
  "error" (red in UI, last frame held or black per setting) and is retried on
  the next file change. It never aborts the engine.
- A network listener failure (port in use, interface gone) is reported and
  retried with backoff; DMX continues on other interfaces.
- Engine crash → launchd restart → auto-load last project (+ its last
  mapping/output state) → outputs back within the boot time of the engine
  (target < 3 s on the reference machine; measured in Phase 8 soak tests).
  Playback positions are not restored; DMX re-establishes state immediately.

### 2.4 Phase 8 as built (2026-10-24)

- One engine per user: `fanousd` holds an `flock` on
  `~/Library/Application Support/Fanous/engine.lock` (pid inside) for its
  whole run; a second start prints "already running (pid n)" and exits 75.
  Under launchd that means the KeepAlive retry every 10 s is refused as long
  as a foreground engine owns the ports, which is the intended outcome.
- Soak test (`scripts/soak.sh HOURS LAYERS`): `fanous-bench dmx` sends
  Art-Net at the standard patch at 40 Hz with a random file, play mode,
  dissolve and intensity per layer every 3–8 s and slow position/scale drift;
  the script samples `/metrics` (now with `totalFrames`, `totalMissed`,
  `totalLate` and `pid`) and the engine's RSS every second, `kill -9`s the
  engine at the kill interval and times `/healthz` coming back, and writes
  `docs/benchmarks/soak-<date>.{csv,md}` with PASS/FAIL: no missed (dropped)
  frames outside the first 5 s after a (re)start, RSS growth under 100 MB
  after a 5-minute warm-up, every restart under 3 s (§2.3); late presents
  (one vsync late, §18 counts dropped frames) are listed as warnings.
- Found by the user-docs pass and fixed: the engine now renders without a
  scene file (the bundled agent): canvas, layer count, patch, source policy
  and library root come from the project document, media from the library
  (`Engine.defaultScene`). The project's `policy` is applied to every patched
  fixture at start and on change (it was only read from scene files). sACN
  joins the multicast groups of the universes in the patch and re-joins on
  patch changes (it was universes 1–3). `timecode.enable {on}` is the
  operator's switch (also under show lock; OSC `/fanous/timecode/enable`
  uses it) and `TimecodeSettings.enabled` the stored flag; the source stays a
  programmer setting. The Patch toolbar has the source-policy selector and the
  Show screen warns while the policy is DMX only. A changed library root
  applies at once (B51): `project.set /library/root` checks the folder and
  refuses in show mode or while ingest jobs are unfinished. On a queue of its
  own (never the feed or control queue), with show-mode entry and ingest
  enqueues held, the engine starts a `LibraryIndex` on the new root (the
  probe cache is keyed by path, so a known root needs no probes), checks
  again, swaps it in, has the media loader re-resolve every library layer and
  then stops the old index (FSEvents released, probe thread joined; a probe
  that outlives the join no longer writes the cache). Every library change
  makes the loader retry layers showing "missing" whose key now resolves. An
  undo or redo that cannot apply is put back to the root that runs.
- Show mode hides the cursor on every bound output display
  (`CGDisplayHideCursor`) and shows it again on leaving; output windows were
  already at `CGShieldingWindowLevel`. The other §14 side effects stay B42.
- Shell: the Engine menu shows "Engine <version> running · service installed"
  (or the approval/not-installed state) when opened, and offers Start,
  Restart and Stop Engine (stop = `SMAppService.unregister`, since a KeepAlive
  agent only stays down when its registration goes).
- Bundle: `scripts/bundle.sh` signs with the hardened runtime and
  `scripts/entitlements.plist` (microphone for LTC), writes the microphone and
  local-network usage strings and `NSBonjourServices`, timestamps when a
  Developer ID is given; `scripts/notarize.sh` submits with `notarytool`,
  staples the app and a UDZO dmg. Version `1.0.0-rc.1` from
  `FanousVersion.string`, also in CITP `SInf`.
- `docs/RELEASE.md` is the release checklist (code green, version,
  measurements per machine, console interop, build/notarize, clean-account
  install, legal, docs, publish); `CHANGELOG.md` started; user documentation
  in `docs/user/`.
- Measured: the 8 h soak on the reference machine passed (0 dropped frames,
  restarts 0.26 s, memory flat, 5 late presents as warnings;
  `docs/benchmarks/soak-2026-10-24-0928.md`). Not done here (owner steps in the
  checklist): benchmarks and soaks on other machines, the notarized build and
  the clean-account install, the legal and trademark items.

---

## 3. Module / package layout (ADR-0003)

One SwiftPM package, `Package.swift` at repo root, plus the `web/` frontend.

```
Fanous/
├── Package.swift
├── Sources/
│   ├── FanousCore/        pure Swift, Foundation only. Unit-testable on any Mac.
│   │   ├── Parameters/      ParameterSpec, fixture types, channel map, units
│   │   ├── DMX/             Art-Net + sACN parsers/builders, universe model, merge
│   │   ├── OSC/             OSC 1.0 parser/builder, address map from ParameterSpec
│   │   ├── CITP/            CITP/MSEX packet model
│   │   ├── GDTF/            GDTF XML generation from ParameterSpec
│   │   ├── Timecode/        LTC bit decoder, MTC assembler, timecode math
│   │   ├── Cues/            cue list model + fade engine (pure)
│   │   ├── Mapping/         blend curve/LUT math, warp mesh + displacement field, slice geometry, mask rasterization (pure)
│   │   ├── Project/         project document (Codable), commands, undo, versioning, JSON patch
│   │   ├── Protocol/        WebSocket message types, HTTP/1.1 + RFC 6455 framing (pure)
│   │   └── Capabilities/    chip table, tier model, readiness rules
│   ├── FanousEngine/      Metal, AVFoundation, VideoToolbox, CoreAudio, CoreMIDI, Network.framework
│   │   ├── Render/          compositor, output pass, shaders (.metal), texture pools, display links
│   │   ├── Media/           sources: ProRes, HAP, still, Syphon-in; frame rings; layer clocks
│   │   ├── Audio/           per-layer PCM rings, mixer source node, device selection
│   │   ├── Outputs/         windows, display identity, hot-plug, modes
│   │   ├── Net/             Art-Net/sACN/OSC/CITP transports; HTTPS+WSS server; TLS identity
│   │   ├── Preview/         H.264 (VT) + JPEG encoders, CITP streaming
│   │   ├── Library/         scanning, FSEvents, metadata, thumbnails
│   │   ├── Ingest/          transcode jobs (ProRes via AVAssetWriter, HAP via hap.c)
│   │   ├── ShowMode/        assertions, readiness checks
│   │   └── Instrumentation/ metrics ring, exporters
│   ├── FanousPluginAPI/   C header + Swift shim: the plugin ABI (design only in v1)
│   ├── CHap/                vendored Vidvox hap.c/.h (BSD) — C target
│   ├── CSnappy/             vendored google/snappy (BSD-3) — C++ target
│   ├── Syphon/              vendored Syphon-Framework sources (BSD) — ObjC target
│   ├── fanousd/           executable: wiring, CLI flags; serves web/dist (located at runtime, see below)
│   ├── FanousShell/       executable: AppKit app, WKWebView, SMAppService, About
│   └── fanous-bench/      executable: benchmark harness
├── Tests/
│   ├── FanousCoreTests/   protocol fixtures (captures), parameter/channel map, GDTF, cues, mapping math
│   ├── FanousEngineTests/ golden images, decode spikes — Apple Silicon only
│   └── Fixtures/            captures/*.bin + .pcapng, golden/*.png, media/ (generated)
├── web/                     Svelte 5 + Vite + TypeScript; builds to web/dist (copied into the .app by bundle.sh)
├── scripts/                 bundle.sh (assemble .app), sign.sh, license-headers.sh, fixtures.sh
└── docs/
```

Rules enforced by CI (Phase 0): `FanousCore` imports only `Foundation`
(a test greps for other imports); every source file starts with the SPDX
header; no new package dependencies without an entry in
`docs/licensing/DEPENDENCIES.md`.

The `.app` bundle is assembled by `scripts/bundle.sh` from SPM products
(no Xcode project): Info.plist, LaunchAgent plist, embedded `fanousd`,
`web/dist` as `Contents/Resources/web`, entitlements, then `codesign` +
`notarytool`. The engine locates its web root at runtime (`--web-root`,
`$FANOUS_WEB_ROOT`, `Contents/Resources/web`, or `web/dist` relative to a
development build) instead of using SPM resources, so one binary serves both
the bundle and `swift run`. Bundle identifiers: `org.fanous.app` (shell),
`org.fanous.engine` (agent) (`[OPEN-2]`, decided: `org.fanous`).

---

## 4. Decode → render pipeline (ADR-0004, ADR-0005, ADR-0006)

### 4.1 Sources

Every layer plays a `Source`. All sources deliver `Frame`s to the same ring
contract; the compositor does not care where a texture came from.

| Source | Demux | Decode | Texture path | Notes |
|---|---|---|---|---|
| ProRes 422 (Proxy/LT/422/HQ) | `AVSampleCursor` + `AVSampleBufferGenerator` (random access, all-intra) | `VTDecompressionSession`, hardware required (`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`) | **Measured on macOS 27 / M1 Pro (Phase 2 spike):** the decoder's native output is Apple's lossless-compressed bi-planar 16-bit 4:2:2 (`&sv2`), IOSurface-backed; `CVMetalTextureCache` wraps the planes as `r16Unorm` + `rg16Unorm` without a copy | 0.8 ms per 1080p frame (p50). YCbCr→RGB (Rec.709 video range) in the layer shader. The `v216`/`y416` paths from WWDC20 are kept as fallbacks. |
| ProRes 4444 / 4444 XQ (with alpha) | same | same | native `&sv4` (bi-planar 4:4:4) **drops alpha**, so the session requests `y416` (packed A Y Cb Cr 16-bit); IOSurface → `rgba16Unorm` texture, swizzled in-shader | 1.8 ms per 1080p frame vs 0.95 ms native: the conversion costs ≈0.8 ms on the decode thread. Alpha-less 4444 files could use the native path later (`[OPEN-3]` resolved for v1: alpha wins). |
| HAP / HAP Alpha / HAP Q / HAP Q Alpha / HAP Alpha-only | same (compressed samples only) | `hap.c` `HapDecode` with a chunk callback (`DispatchQueue.concurrentPerform` over the frame's chunks) → Snappy; DXT bytes land in a per-layer staging buffer | `MTLTexture.replace(region:)` into a per-ring-slot pooled texture (`bc1_rgba`, `bc3_rgba`, `bc4_rUnorm`; HAP Q = `bc3` read as scaled YCoCg in the shader; HAP Q Alpha = two textures) | **Measured:** HAP Q 0.8 ms, HAP 0.4 ms per 1080p frame (p50) incl. the copy. CPU-bound (Snappy). HAP R (`bc7`) is the same path later. |
| Still (PNG/JPEG/TIFF/HEIF) | ImageIO | ImageIO → `MTLTexture` once (`rgba8`/`rgba16`) | resident | premultiplied alpha normalized on load |
| Image sequence | not played directly: ingest converts to ProRes 4444 / HAP (§8) | — | — | keeps the engine to two movie codecs |
| Syphon input | `SyphonMetalClient` | — | the server's `MTLTexture` is sampled directly | library folder 0 (§8.2) |
| Camera / capture card (design, §8.2.1) | `AVCaptureSession` | — | the frame's IOSurface as Metal textures, sampled directly: `2vuy`/`yuvs` packed 4:2:2 (`.v216`/`.yuy2`), `420v` planes 0 and 1 as `r8Unorm` + `rg8Unorm` (`.planarYCbCr`), `BGRA` (`.rgba`) | folder 0 files 1–20 |
| Display / window capture (design, §8.2.1) | `SCStream` | — | `BGRA` as `bgra8Unorm` on the frame's IOSurface, sampled directly | folder 0 files 21–32 |
| NDI / DeckLink (later) | plugin | plugin | plugin hands over an IOSurface | ADR-0016 |

Why `AVSampleCursor` instead of `AVAssetReader`: the reader is forward-only
and must be re-created to seek, which breaks reverse play, bounce, scrub and
timecode chasing. ProRes and HAP are all-intra, so random access per sample is
cheap. One sample-buffer generator per layer, one decode session per layer,
re-created only on file change.

Audio tracks are read with a second cursor on the audio track and decoded to
48 kHz float PCM (`AudioConverter`) into a per-layer PCM ring (§10).

### 4.2 Layer clock and read-ahead

Each layer has a `LayerClock` advanced by the compositor every tick from the
display link's `targetTimestamp`:

- `position` (in media frames, fractional), `speed`, `direction`, `in`, `out`,
  `mode` (§6.2). Timecode mode sets `position = (tc − offset) × fps` each tick.
- The compositor writes the clock's *predicted* positions for the next N ticks
  into the layer's `DecodeRequest` slot (atomic); the decoder thread reads it
  and fills the frame ring ahead in play direction. Ring depth per tier (4 by
  default, 8 for ≤1080p). Reverse play reads samples backwards; bounce flips
  direction at in/out.
- On file change / retrigger / large seek (> ring depth), the decoder flushes
  and restarts; the compositor shows the previous frame (or black, per layer
  setting) until the first new frame is ready, then starts the dissolve if
  dissolve > 0.
- Frame selection: the compositor picks the ring frame whose pts is the
  closest at-or-before `position`; frames older than that are released to the
  pool. There is **no frame blending** in v1 (nearest frame), which keeps
  25/30/50/60 fps content on any output rate deterministic. `[OPEN-4]`
  optional frame blending later.
- Media of any frame rate is supported; the clock is in media frames so
  speed 100 % always means native rate.

### 4.3 Compositing pass (per canvas)

One `MTLRenderCommandEncoder` per canvas per tick, rendering into a
triple-buffered `rgba16Float` canvas texture (ADR-0007):

1. Clear to the canvas background (black by default).
2. For each layer assigned to this canvas, in fixed layer order, if
   intensity > 0 and a frame is available: draw one quad (or two during a
   dissolve) with a per-layer uniform block from the parameter snapshot.
   - Vertex: 3D transform (position XYZ, scale XY, rotation XYZ, fit mode,
     crop) with a fixed perspective camera per canvas; the canvas is the
     z = 0 plane.
   - Fragment: source conversion (YCbCr / YCoCg / BC4 alpha / RGBA) →
     colour adjust (RGB multiply, brightness, contrast, saturation, hue) →
     effect slot 1 → effect slot 2 → intensity → **blend mode via
     programmable blending** (Apple GPUs expose the destination pixel as
     `[[color(0)]]` in the fragment shader, so Add/Screen/Multiply/… need no
     extra passes or copies).
   - Effects are branches of one uber-shader selected by per-draw uniforms
     (**Phase 3 decision**: a uniform branch is free on Apple GPUs, one
     pipeline means nothing is ever compiled during a show, and the
     benchmark with blur + edge on every layer is the proof; function-constant
     specialisation stays the fallback if a later effect needs it).
     Neighbourhood effects (blur, pixelate, kaleidoscope, edge) sample the
     *source* texture multiple times; no intermediate textures. The meaning of
     the two parameter channels per effect is the `EffectSpec` table in Core,
     rendered into `docs/channel-map.md`.
   - Dissolve: the outgoing media keeps playing and is drawn first; with
     Normal blending it stays at full intensity under the incoming quad (so
     a crossfade never dips to the background), with the other modes both
     quads are weighted (1 − t) and t. A dissolve therefore costs exactly one
     extra layer (decode and draw) for its duration.
3. Done. The canvas texture index is published right after the command
   buffer is committed, making it visible to output threads (their own work
   on the same queue runs after it). GPU time and errors are booked on a
   later tick from the ring of committed buffers (§4.6, B105).

A canvas with no visible layers still clears (cheap) so outputs always have a
valid frame.

### 4.4 Output pass (per output) — ADR-0011

Runs on the thread owning that display's `CAMetalDisplayLink`. For each
output region on the display: one render encoder into the drawable; for each
slice of the output: draw the slice mesh (ADR-0011) — details in §9. The
output pass reads the canvas texture and writes the drawable: no intermediate
copies anywhere between decode and photons.

Dithering to the drawable's 8-bit format uses a 64×64 blue-noise texture
(`[OPEN-5]` 10-bit output when the display supports it).

### 4.5 Present and clocks

- The **master** display link (the display chosen as "clock master" in the
  project, default: the first output's display) drives the compositor. Its
  `preferredFrameRateRange` is pinned to the display's refresh rate.
- Other displays present from their own link. They always show the latest
  *completed* canvas; with mixed refresh rates (allowed, warned) they will
  repeat or skip canvas frames; that is the documented behaviour.
- `preferredFrameLatency = 1` on every link (lowest DMX→photon latency; the
  benchmark checks that this does not cost frames at the tier's layer count).
- **Phase 2 finding:** on macOS 27.0.1 `CAMetalDisplayLink` stops after three
  presented frames in every configuration tried (ADR-0006 amendment). The
  shipping driver is therefore a mach-clock-paced thread using
  `nextDrawable()` on a `displaySyncEnabled` layer with two drawables; the
  display-link driver is kept behind a switch for re-testing.
- No output displays (preview-only / headless bench): the compositor runs on a
  `mach_wait_until` loop at the project's canvas rate.
- Display sleep, mode change or hot-unplug: the output thread stops its link;
  the compositor continues; reattach by display identity (§9.6).

### 4.6 Memory and allocation rules

- Texture/buffer pools are sized at layer activation from the file's
  dimensions and the tier's ring depth; a layer that switches to a larger file
  reallocates on Control, not on the compositor.
- Uniforms live in a per-frame ring of `MTLBuffer`s (3 × max layers); argument
  tables are filled by offset, never by creating objects.
- Allocation rule on the compositor thread (Phase 2 acceptance, restated by
  B97; ADR-0002 amendment 2026-10-29). Both parts are counted on that thread
  only, with a `malloc_logger` hook (`MallocCounter`, B89), never process-wide.
  The tests' counts are exact, because they synchronise with the counted
  thread around the window. The bench's count is within a few out of
  thousands. The parts:
  - The tick's own work allocates **0** in steady state.
    `scripts/check-mallocs.sh` checks it in an optimised build, on a
    compositor that encodes no GPU work (`skipsIdleWork`). A debug build
    allocates for unspecialised generics.
  - Metal API objects add allocations on every tick: 2 per
    `makeCommandBuffer()`, 2 for the first
    `makeRenderCommandEncoder(descriptor:)` and 3 for each further one.
    Completion bookkeeping uses no completion handler (B105): the tick keeps
    its committed buffer in a fixed ring of 8 and the next ticks poll the
    status, then book GPU time, late flag, `completed` and `gpuErrors` on the
    compositor thread, 0 allocations. GPU numbers arrive a few ticks late; the
    last buffers before ticks stop stay unbooked. A handler with its capturing
    closure cost 3 per tick. With the ring full (the GPU 8 ticks behind) the
    compositor thread blocks in `waitUntilCompleted` on the oldest buffer,
    counted as `completionWaits` in `/metrics`; only headless or offscreen
    ticking can get there, the display paths cap at 3 drawables in flight.
  - `fanous-bench` reports the thread's count per step (`compositorMallocs`,
    B97). The minimum is 4.00 per tick (2 + 2), measured headless with one
    canvas, no output pass and no preview or thumbnails (M1 Pro, 4 ProRes
    layers, 2026-10-29; 7.00 before B105). Additions:

    | Feature | Extra allocations per tick |
    |---|---|
    | Output pass | +3 (one more encoder) |
    | Each extra canvas | +3 |
    | Generators that draw this tick | +2 for the first, about +3 each further (derived): its encoder, the descriptor and label made once per generator (B112). The test card (110), colour sweep and motion test draw every tick, the clock (112) once a second, 100–107 only when made. Was +8 per tick for the test card and +9 for the clock's draw (measured `-c release`, M1 Pro, 2026-10-29) |
    | Each preview or thumbnail streamer | about +6 (derived: an encoder and a capturing handler) |
    | `present` | not measured |
    | Syphon publish (while a client is attached) | +4: the flip draw's encoder (2) and Syphon's `addCompletedHandler` block (2); its render pass descriptor is made once (`VENDORED.md` local change 6), 8 when it was made per frame (B109; measured `-c release`, M1 Pro, 2026-10-29) |
- Unified memory budget: engine warns at 60 % of physical memory, refuses to
  activate a layer that would exceed 75 %. Read-ahead depth is the first knob
  reduced when a 16 GB machine is detected.

---

## 5. Hardware capability detection and performance tiers

### 5.1 Detection at start (and on display changes)

| Fact | How |
|---|---|
| Chip name, P/E core counts, memory | `sysctl machdep.cpu.brand_string`, `hw.perflevel0.physicalcpu`, `hw.memsize` |
| GPU family, core count, unified memory, working-set hint | `MTLDevice.supportsFamily(.apple7/8/9…)`, IORegistry `AGXAccelerator/gpu-core-count`, `recommendedMaxWorkingSetSize` |
| Hardware ProRes decode / encode | `VTIsHardwareDecodeSupported(kCMVideoCodecType_AppleProRes422)`; encoder list (`VTCopyVideoEncoderList`) filtered on `kVTVideoEncoderList_IsHardwareAccelerated` |
| H.264 hardware encode (preview) | encoder list, same |
| Displays, modes, identity | `CGGetOnlineDisplayList`, `CGDisplayCopyAllDisplayModes`, `CGDisplayCreateUUIDFromDisplayID`, EDID name via IOKit |
| Media-engine count, max external displays | **static table** keyed by chip name (`FanousCore/Capabilities`), marked "Apple spec" in the UI, with `unknown` fallback → conservative tier and a yellow "unknown chip, benchmark recommended" status |
| Thermal / power | `ProcessInfo.thermalState`, `IOPSCopyPowerSourcesInfo` (on battery = yellow) |

Unsupported machine (no hardware ProRes, i.e. base M1 / Intel): the engine
starts, shows a red "unsupported hardware" status, and refuses to enter show
mode. Development on such a machine still works for the UI.

### 5.2 Tiers

Tiers group chips by media-engine count and GPU/bandwidth class. Layer counts
below are **initial expectations** derived from Apple's published ProRes stream
counts and bandwidth; they are replaced by measured numbers from
`fanous-bench` (Phase 2) and stored per machine. The UI shows the measured
numbers for *this* machine when available, otherwise the tier expectation
labelled "not yet benchmarked".

| Tier | Chips | Media engines (Apple spec) | Expected max layers, canvas 1080p60 | Expected max layers, canvas 4K60 | Notes |
|---|---|---|---|---|---|
| **1 Base** | M2, M3, M4, M5 | 1 | 6 × 1080p60 ProRes 422 HQ · 8 × 1080p60 HAP Q | 2 × 4K60 ProRes HQ · 3 × 4K60 HAP Q | 8 GB/16 GB memory limits ring depth; 2 external displays |
| **2 Pro** (reference: M1 Pro) | M1 Pro, M2 Pro, M3 Pro, M4 Pro, (M5 Pro) | 1 | **Measured 2026-10-23 (M1 Pro, 32 GB):** 16 × 1080p60 ProRes 422 HQ (cap) · 16 × 1080p60 HAP Q (cap) | **Measured:** 16 × 4K30 ProRes HQ (cap) · 16 × 4K30 HAP Q (cap, ring 8) · 3–7 × 4K60 ProRes HQ (decode jitter, Phase 3) · ≥ 4 × 4K60 HAP Q (ring 8) | all v1 acceptance criteria are defined on this tier first; details in `docs/benchmarks/README.md`. **Phase 3:** the caps hold with both effect slots on every layer for the per-pixel effects; blur and edge cost ≈ 1.6–1.9 ms per 1080p layer each (2–3 layers with both at 1080p60), a dissolve costs one extra layer |
| **3 Max** | M1 Max, M2 Max, M3 Max, M4 Max, (M5 Max) | 2 | 16 (cap) | 8 × 4K60 ProRes HQ · 8 × 4K60 HAP Q | 4 external displays |
| **4 Ultra** | M1 Ultra, M2 Ultra, M3 Ultra | 4 | 16 (cap) | 16 (cap) | 5+ displays |

Tier knobs the engine sets automatically (overridable in System settings):
frame-ring depth (8 frames per layer at 4K, 6 at 1080p: measured to be the
decisive knob at 4K), HAP chunk-pool size, canvas precision (`rgba16Float`
default, `rgba8Unorm` as "performance" mode), preview resolution/fps, number
of simultaneous dissolves allowed (a dissolve costs a second decoder), ingest
concurrency.

The chip table (media engines, external displays, bandwidth) lives in
`docs/hardware.md` with its verification status per cell (several cells are
still unverified as of 2026-10-22) and is re-checked per chip generation
`[OPEN-6]`.

---

## 6. DMX fixture model and channel map (ADR-0008)

### 6.1 Fixture types

The server exposes **one GDTF fixture type, "Fanous", with three DMX modes**
in v1, and a fourth (Keystone) from M2; every mode is patched independently as its own fixture on the console:

| Mode | Footprint | Patched per | Purpose |
|---|---|---|---|
| **Layer** | 64 ch | layer (16 in v1, extensible) | everything about one layer |
| **Master** | 8 ch | machine | master intensity, blackout, global test pattern, master speed |
| **Output** | 8 ch | output | per-output intensity, blackout/freeze, test pattern, blend on/off, mapping preset and its fade |
| **Keystone** (M2) | 16 ch | output | four corner offsets on top of the output's mapping (§6.4a, §9.10) |
| Serial (later) | 8 ch | serial device | selects pre-configured RS-232/RS-422 strings (projector control) — `[OPEN-7]` v1.x |

64 channels per layer = 8 layers per universe exactly. Channels 52–64 of the
Layer mode are **reserved** so that additions never change the footprint
(51 is the Sync channel of §23).
16-bit parameters are coarse/fine pairs on adjacent channels (MSB first), the
convention consoles and GDTF expect.

The patch (universe, address, mode) plus per-layer settings (canvas, source
policy §7.2) is part of the project. Patching a fixture type is also how
"extensible beyond 16 layers" works: the layer count is a project setting,
bounded by the tier's measured maximum (hard engine cap 32, `[OPEN-8]`).
An Output fixture follows its output (2026-10-30): `output.add` patches Output n
on the Master's universe at the Master's address + 8 n when those channels are
free, `output.remove` unpatches it in the same undo step, and a new project's
standard patch holds the layers and the Master only. `patch.set` refuses an
Output fixture without its output and loading a project unpatches one, so an
Output fixture exists exactly when its output does. A Keystone fixture (§6.4a)
is patched by hand but follows the same rule: `output.remove` unpatches it, and
`patch.set` and loading refuse or drop one without its output.

### 6.2 Layer mode (64 channels)

Defaults are the values the GDTF file declares, i.e. what a console sends when
the fixture is patched and "at default". A freshly patched layer is black
(intensity 0), empty (file 0) and at speed 100 %.

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Intensity | 16 | 0 | 0–100 % |
| 3 | Folder | 8 | 0 | 0 = reserved folder (live inputs/generators, §8.2); 1–255 = library folder |
| 4 | File | 8 | 0 | 0 = none (layer shows nothing); 1–255 = file in folder |
| 5 | Play mode | 8 | 0 | 0–15 Loop fwd · 16–31 Loop rev · 32–47 Once, hold last · 48–63 Once rev, hold · 64–79 Once, then black · 80–95 Once rev, then black · 96–111 Bounce · 112–127 Freeze (hold current frame) · 128–143 Timecode chase · 144–159 Scrub (position = In point) · 160–255 reserved (= Loop fwd) |
| 6–7 | Speed | 16 | 32768 | 0–32767 → 0–100 % linear · 32768–65535 → 100–400 % linear (fader at 50 % = native speed) |
| 8–9 | In point | 16 | 0 | 0–100 % of duration, frame-quantized |
| 10–11 | Out point | 16 | 65535 | 0–100 % of duration; if ≤ In, the layer plays the single frame at In |
| 12 | Dissolve | 8 | 0 | 0 = cut · 1–255 = 0.1–25.5 s crossfade on file change |
| 13–14 | Position X | 16 | 32768 | −100 … +100 % of canvas width; 32768 = centre |
| 15–16 | Position Y | 16 | 32768 | −100 … +100 % of canvas height |
| 17–18 | Position Z | 16 | 32768 | depth −100 … +100 % (towards / away from the camera; perspective) |
| 19–20 | Scale X | 16 | 32768 | 0–32767 → 0–100 % · 32768–65535 → 100–800 % |
| 21–22 | Scale Y | 16 | 32768 | same |
| 23 | Fit mode | 8 | 0 | 0–63 Fit (letterbox) · 64–127 Fill (crop) · 128–191 Stretch · 192–255 Native (1:1 pixels) |
| 24–25 | Rotation X | 16 | 32768 | −180 … +180° |
| 26–27 | Rotation Y | 16 | 32768 | −180 … +180° |
| 28–29 | Rotation Z | 16 | 32768 | −180 … +180° |
| 30 | Red | 8 | 255 | multiply |
| 31 | Green | 8 | 255 | multiply |
| 32 | Blue | 8 | 255 | multiply |
| 33 | Brightness | 8 | 128 | −100 … +100 (offset) |
| 34 | Contrast | 8 | 128 | 0–200 % |
| 35 | Saturation | 8 | 128 | 0–200 % |
| 36 | Hue | 8 | 0 | 0–360° rotation |
| 37 | Blend mode | 8 | 0 | 0–15 Normal · 16–31 Add · 32–47 Screen · 48–63 Multiply · 64–79 Subtract · 80–95 Difference · 96–111 Lighten · 112–127 Darken · 128–255 reserved (= Normal) |
| 38 | Effect 1 | 8 | 0 | 0–15 None · 16–31 Blur · 32–47 Pixelate · 48–63 Mirror · 64–79 Kaleidoscope · 80–95 Invert · 96–111 Strobe · 112–127 Luma key · 128–143 Chroma key · 144–159 Edge · 160–175 Threshold · 176–191 Tint · 192–255 reserved |
| 39 | Effect 1 param A | 8 | 0 | effect-specific (amount / size / rate / key level) |
| 40 | Effect 1 param B | 8 | 0 | effect-specific (angle / softness / hue / segments) |
| 41 | Effect 2 | 8 | 0 | as ch 38 |
| 42 | Effect 2 param A | 8 | 0 | |
| 43 | Effect 2 param B | 8 | 0 | |
| 44 | Crop left | 8 | 0 | 0–100 % |
| 45 | Crop right | 8 | 0 | |
| 46 | Crop top | 8 | 0 | |
| 47 | Crop bottom | 8 | 0 | |
| 48 | Audio volume | 8 | 0 | 0–100 % (default silent) |
| 49 | Audio pan | 8 | 128 | L … R |
| 50 | Control | 8 | 0 | 0–7 idle · 8–15 **Retrigger** (jump to In point on rising edge) · 16–23 Resync audio · 24–31 Clear error · 32–255 reserved |
| 51 | Sync | 8 | 0 | 0–9 off · 10–89 master group 1–8 · 90–169 slave group 1–8 · 170–255 reserved (§23, B60) |
| 52–64 | Reserved | — | 0 | ignored |

Effect parameter semantics per effect are listed in `docs/channel-map.md`
(generated from `ParameterSpec` in Phase 1 so docs, GDTF, OSC and UI labels
can never disagree). `[OPEN-9]` exact bands and the speed/scale upper limits.

### 6.3 Master mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Master intensity | 16 | 65535 | multiplies all canvases (each layer's colour, not its opacity, §9.5); outputs take it once, from the canvas |
| 3 | Control | 8 | 0 | 0–63 normal · 64–127 Freeze all · 128–191 Blackout · 192–255 reserved |
| 4 | Test pattern | 8 | 0 | 0–15 off · 16–31 Grid · 32–47 Colour bars · 48–63 Blend zones · 64–79 Output ID · 80–95 Crosshair/alignment · 96–111 Grey steps · 112–127 Checkerboard · 128–143 Grey 0 % · 144–159 Grey 25 % · 160–175 Grey 75 % · 176–191 White (seam check, §9.9) · 192–255 reserved — overrides every output |
| 5–6 | Master speed | 16 | 32768 | multiplies layer speed (same mapping as layer speed) |
| 7–8 | Reserved | — | 0 | |

### 6.4 Output mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Intensity | 16 | 65535 | output master |
| 3 | Control | 8 | 0 | 0–63 normal · 64–127 Blackout · 128–191 Freeze (hold frame) · 192–255 reserved |
| 4 | Test pattern | 8 | 0 | as Master ch 4, this output only |
| 5 | Blend | 8 | 0 | 0–127 blend/warp on (default) · 128–255 raw (bypass blend, warp, mask and, from M2, keystone — for alignment) |
| 6 | Mapping preset | 8 | 0 | 0 = as edited · 1–255 = the output's stored mapping preset with that number; an index, so it cuts (M2.4, §9.10) |
| 7 | Mapping fade | 8 | 0 | 0 = cut · 1–255 = 0.1–25.5 s morph when ch 6 changes, as Layer Dissolve (M2, §9.10); not built yet (M2.5): reserved |
| 8 | Reserved | — | 0 | |

### 6.4a Keystone mode (16 channels, M2)

Patched per output, next to that output's Output fixture (same output number); "Keystone n" in the patch, OSC
`/fanous/keystone/{n}/{key}` (as built in M2.3, §9.10).
The offsets move the output's four corners on top of whatever mapping it shows,
so a console never changes the hand alignment (§9.10). A new mode leaves the
three existing modes and their footprints alone.

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Top-left X | 16 | 32768 | −50 … +50 % of the output's width; 32768 = no change; + is right |
| 3–4 | Top-left Y | 16 | 32768 | −50 … +50 % of the output's height; + is down |
| 5–6 | Top-right X | 16 | 32768 | as ch 1–2 |
| 7–8 | Top-right Y | 16 | 32768 | as ch 3–4 |
| 9–10 | Bottom-right X | 16 | 32768 | as ch 1–2 |
| 11–12 | Bottom-right Y | 16 | 32768 | as ch 3–4 |
| 13–14 | Bottom-left X | 16 | 32768 | as ch 1–2 |
| 15–16 | Bottom-left Y | 16 | 32768 | as ch 3–4 |

### 6.5 Universe addressing and merge

- Art-Net 4 (protocol version 14) Net/Sub-Net/Universe (15-bit
  port-address) and sACN (ANSI E1.31-2025, which supersedes E1.31-2018)
  universe (1–63999) are both mapped to an internal
  `UniverseID(protocol, number)`. Fixtures are patched to one `UniverseID`
  + start address.
- Art-Net is royalty-free subject to Artistic Licence's conditions: the
  `ArtPollReply` carries an OEM code (0xFFFF "unknown" until the project
  registers one, `[OPEN-25]`) and the product must show the credit
  "Art-Net™ Designed by and Copyright Artistic Licence Engineering Ltd"
  (About screen, docs); see `docs/licensing/DEPENDENCIES.md`.
- **One source protocol per universe** (project setting). Within sACN,
  priority and sequence numbers are honoured (highest priority wins; equal
  priorities → LTP by arrival; per-address priority (0xDD) is `[OPEN-10]`).
  Within Art-Net, the latest `ArtDmx` for the port-address wins; sequence
  wrap is handled.
- Loss of signal: after 2.5 s without packets on a universe, its fixtures
  **hold last values** (Catalyst behaviour) and the universe turns red in the
  status bar. Hold-vs-release is a project setting (per universe, §6.5a).
- The server answers `ArtPoll` with `ArtPollReply` (name, IP, port
  addresses; unicast back to the poller, one reply per Net/Sub-Net group of
  four ports) and sACN discovery (E1.31 universe discovery packets are
  received; the server advertises nothing in v1 as it only receives).
- sACN multicast groups are joined on the default-route interface, or per
  universe on its interface (§6.5a); unicast sACN on port 5568 is accepted
  on every interface.
- `ArtSync` and E1.31 synchronization packets: when received, a universe
  update is applied at the sync packet, otherwise immediately.

### 6.5a Per-universe settings as built (2026-10-26, B28)

- The project's `/universes` list holds one entry per changed universe,
  keyed by the patch's universe id: `protocol` (`artnet | sacn | both`),
  `interface` (`any`, a BSD name or an IPv4 address of the Mac),
  `holdOnLoss` (`hold | zero | internal`), `lossTimeout` (1–60 s; consoles
  that send only on change repeat every 0.8–1 s), `sacnPriorityMode`
  (`highest | htp`) and `pair`. A universe without an entry runs the
  defaults (own protocol, any interface, hold, 2.5 s, highest), which are the
  behaviour before B28; an entry set back to the defaults is removed.
  `universe.set {id, path, value}` (programmer, refused under show lock,
  undoable) starts from the settings the engine runs for that universe,
  validates the whole entry and leaves exactly one entry for it; an interface
  that is not present is accepted. The engine runs the first entry per
  universe: an invalid one runs the defaults, a later duplicate is ignored,
  and each is logged once (with id and field) when the set of skipped
  entries changes.
- Ids stay transport-specific, so "one source protocol per universe" is
  expressed with `pair`: the other transport's wire universe (default sACN
  n ↔ Art-Net port-address n − 1). `UniverseTable` (Core) routes each wire
  packet to its own universe (unless that one listens only to the other
  transport) and to every universe whose pair it is; state (sequence gates,
  sACN sources) is per universe and reset when its routing changes. With
  `both`, Art-Net competes as an sACN source at priority 100; `htp` merges
  the sources at the top priority per slot.
- Two timeouts. The **source timeout** is fixed at 2.5 s (E1.31): an sACN
  source (and, with `both`, Art-Net) silent that long leaves the merge, so a
  lower-priority backup takes over on time. `lossTimeout` only decides when
  the universe counts as lost (status, readiness, hold on loss).
- `interface` filters by sender: a packet is accepted when its source address
  is in a subnet of that interface (getifaddrs, re-read on the 0.5 s tick
  while a universe names one, so adapters may come and go). sACN is one BSD
  UDP socket bound to INADDR_ANY:5568 (SO_RCVBUF 4 MB; unicast always works)
  that joins each universe's group with `IP_ADD_MEMBERSHIP` on the interface's
  address; `any` joins on every up, IFF_MULTICAST, non-loopback IPv4
  interface, so a console on a NIC without a gateway works with the default.
  EADDRINUSE on a join means "already a member" (a second address of the
  interface, or two specs wanting it). Without any sACN universe, universe 1
  is joined on `any` (as before B28). This replaces the `NWConnectionGroup`s:
  a second group on the same port fails with EADDRINUSE, so Network.framework
  cannot join per interface. Settings changes add or drop only the affected
  memberships; the socket and the Art-Net listener never rebind. Memberships
  are re-asserted (idempotent) on every `NWPathMonitor` update and every
  5 s, which re-joins an adapter the kernel dropped them for (replug). A
  read event drains at most 256 packets. Everything runs on the DMX queue.
- The socket sets SO_REUSEPORT: a later process on the port (sACNView
  receiving, a second Fanous) also gets multicast, but unicast is delivered
  to one socket only, the one bound last. A port held exclusively
  (`nc -u -l 5568`) fails the bind: the engine logs it, runs without sACN,
  and readiness warns (`sacnport`).
- Readiness warns (`interfaces`) for a patched universe whose interface is
  missing or whose sACN membership could not be joined, including `any`
  (no multicast interface at all, or a failed join on one of them, e.g.
  EADDRNOTAVAIL on an isolated LAN).
- Hold on loss applies on the transition to lost, and at once when the
  setting changes while a universe that was received is lost: `hold` keeps
  the values (as before); `zero` feeds a frame of zeros stamped now, so under
  `ltp`/`htp` it wins over older UI and cue values; `internal` makes the
  fixtures resolve as policy `internal` until packets return
  (`FixtureResolver.internalWithoutDMX`; also while a universe has never
  been received).
- An unpatch is not a loss (2026-10-30): a layer or Master without a patch
  entry (Unpatch, a lower layer count, `effectivePatch` beyond `layerCount`)
  has no resolver, so no source reaches it; `DMXStore.publish` writes its
  defaults (layer: intensity 0, no file; Master: 100 %, Normal, speed
  100 %, no test pattern) into every snapshot instead of leaving the last
  values in the triple-buffer slots.
- Not built: per-packet receive interface (a routed console on another subnet
  is rejected by the subnet filter), Art-Net output/ArtAddress, per-address
  sACN priority (`[OPEN-10]`). Multicast delivery is not covered by the
  tests (it needs the Local Network permission); memberships are checked
  against the kernel, and the manual sACNView checklist in
  `docs/user/console-setup.md` covers delivery.

### 6.6 What a patch means, and the Patch screen (design 2026-10-30, B120)

**Status:** designed 2026-10-30; the owner approved the four decisions below
the same day. Not built. Builds on PR #109 (merged: an Output fixture exists
exactly when its output does), PR #110 (merged: a fixture patched later takes
the project policy) and PR #112 (open: an unpatched layer or Master falls back
to its defaults).

**Terms used here:**
- A **fixture** is one patchable thing of a mode: "Layer 3", "Master",
  "Output 2", "Keystone 2".
- The fixtures that **exist** are:
  - Layer 1…min(`layerCount`, 32): the layers the parameter snapshot holds.
    `layers.setCount` accepts up to 64, but layers above 32 never render;
  - the Master;
  - Output n and Keystone n for every output n of the project (n ≤
    `ParameterSnapshotSlot.maxOutputs`, PR #109).

  Every use below means this set: the resolvers, the existence check of
  `patch.set`, and the UI's groups.
- A mode's **kind** (`per` in the channel map) is what it is patched per:
  `layer`, `machine` (one per Mac: the Master) or `output`.
- A mode is **optional** when a show runs fine without patching it (Keystone);
  the other modes are **required**.
- A **block** is a group's fixtures on fixed slots counted from one start
  address (item 2).
- The **source policy** is the project's `/policy` (§7.2). The screen calls it
  **Who controls**.

**Why.** The owner found the Patch screen hard to understand, and more fixture
modes are coming (Keystone now, Serial and others later). Checked against the
code on 2026-10-30:
- One screen does four jobs in one flat table: what exists (Add layer, Remove
  layer, Add output), where it sits on DMX (universe and address per fixture),
  how a universe is received (protocol, interface, hold on loss) and who
  controls (the source policy in the toolbar).
- "Unpatched" says "no console control" but means "no control at all".
  `patch.set` with address 0 removes the entry, `DMXStore` makes resolvers for
  patch entries only, and UI, OSC, MIDI and cues reach only fixtures with a
  resolver. A show without a console still has to patch every layer.
- A universe's settings show under the selected fixture, so changing Hold on
  loss while Layer 3 is selected also changes Layers 1–8, without saying so.
- Every fixture is a row. 32 layers and 8 outputs with their Keystones are 49
  rows. A new mode adds a row per instance and edits in seven places of
  `patch-screen.ts` (`FixtureType`, `FALLBACK_FOOTPRINTS`, `TYPES`,
  `TYPE_LABEL`, the `FixtureRow.typeLabel` union, the `parseFixture` regex and
  `buildFixtures`).
- Fixtures are patched one at a time with a stepper; a console patches a block
  ("8 fixtures from address 1").
- An optional fixture (Keystone) looks like a forgotten one: both say
  "unpatched".
- What to patch on the console is in `docs/user/console-setup.md`, not on the
  screen.

**Owner decisions (2026-10-30):**
1. A fixture exists without a patch; the patch is only its console address.
2. The screen groups fixtures by kind and patches a group as a block.
3. The groups come from the channel map, so a new fixture mode appears
   without UI code. (Refined in the design review: this holds for a new mode
   of an existing kind; a new kind needs one UI entry, item 3.)
4. Universes and Who controls get their own blocks, and a Patch sheet says
   what to patch on the console.

**1. A fixture exists without a patch (engine).**
- `DMXStore` keeps a resolver for every fixture that exists, with the project
  policy (PR #110). The patch only decides which universe slots feed it.
  - `DMXStore(patch:fixtures:)` and `setPatch(_:fixtures:)` take the fixture
    set with the patch (tests keep a default: the patched fixtures).
  - `Engine.projectChanged` calls it when the patch **or** the fixture set
    changed. Today it compares the patch only, so a new layer that stays
    unpatched, or Add output without a free range, would create no resolver.
- **Unpatching resets the DMX side.** A resolver that loses its patch entry or
  moves to another universe gets `FixtureResolver.clearDMX()`: DMX values back
  to the spec defaults, change times 0, `hasDMX`, `dmxReceived` (below) and
  `internalWithoutDMX` false; the internal (UI, cue, OSC, MIDI) values stay. Without this, a layer
  unpatched while the console drives it would keep the console's last look,
  which undoes PR #112 ("defaults, not hold").
- **DMX competes only once received.** Under `htp`, the resolver compares the
  internal value with the DMX value even when no DMX ever arrived, so the spec
  default wins whenever it is higher: an unpatched Master (default 65535) could
  not be dimmed from the UI, nor layer colour, scale or speed. The resolver
  gets a stored `dmxReceived` flag, set by `updateDMX` and cleared only by
  `clearDMX`; the DMX side takes part in `ltp` and `htp` only while it is set.
  The value's source is not enough: it is `.none` again for a channel the
  console holds at its default after a loss (`dmxChangedAt` moves only on a
  change), and then a UI value would beat a held full Master.
- Unpatched then follows the source policy, with no new rule:
  - under `dmx` the resolver has no DMX and resolves to its defaults: a layer
    black and empty, the Master at full, an output normal, a Keystone the
    identity. That is PR #112's result, now from the resolver itself;
  - under `internal`, `ltp` and `htp`, the UI, cues, OSC and MIDI control it.
- A fixture that stops existing (a layer above the count, a removed output)
  loses its resolver and falls back to its defaults, so PR #112's reset loops
  in `publish` stay.
- **Cue values reach new resolvers.** The cue engine pushes values only while a
  fade runs. `DMXStore` keeps the last cue outputs and applies them to a
  resolver it creates (a layer added, an undo), so a held cue covers it at
  once.
- Hold on loss and its `internal` switch belong to a universe, so they do not
  touch an unpatched fixture. The UI expiry counts only while UI values mask a
  received console (§7.2), so on an unpatched fixture UI values stay until
  released.
- Other readers: OSC feedback and `live.dmx.fixtures` now list unpatched
  fixtures too, so the Layers screen's Master and Output strips follow the
  outputs that exist, patched or not, without a change. CITP reads the
  snapshot and does not change. OSC input to an unpatched fixture is recorded
  and, under `dmx`, ignored like on a patched one. The comments "nil when the
  fixture is not patched" in `DMXStore.swift` and `MIDIControl.swift` (MIDI
  pickup) become "nil when the fixture does not exist".
- **Cost.** `publish` already walks the resolver dictionary; it gets one entry
  per existing fixture. The Keystone recompute in `publish` builds two arrays
  per output with a Keystone resolver on every publish; with a resolver for
  every output it skips a Keystone whose resolver has `dmxReceived` false and
  holds no internal value (the identity), so a typical project allocates
  nothing more on the DMX queue. Both are stored flags: `internalValues()`
  builds an array, and `hasDMX` is false after a loss while held values still
  apply.

**2. Groups and blocks.**
- **Groups**, in channel-map order:
  - **Layers** (kind `layer`). The header holds the layer count with − and +
    (the tier limit and the undo toast of today's Add layer and Remove layer).
  - **Master** (kind `machine`).
  - **Outputs** (kind `output`). One row per output holds its Output and its
    Keystone fixture, names the display it is on and links to Outputs &
    Mapping. The header keeps PR #109's **Add output**.
- **Slots.** A block has a start (universe and address). Fixture number k of
  the group (Layer k, Output k) sits on slot k − 1. Slot i is the start address
  + i × footprint; when a slot would run past channel 512 it moves to address 1
  of the next universe, and so does every slot after it. The next universe is
  Art-Net port-address + 1 (A 0.0.15 → A 0.1.0) or sACN n + 1. Numbering by
  fixture number keeps gaps: after Output 2 of 3 is removed, Output 3 keeps its
  slot. This is how the standard patch lays out layers (8 per universe) and how
  PR #109 places Output n (the Master's address + 8 n).
- The block is **derived, not stored.** The project gets no new field.
  - The **anchor** is the group's lowest-numbered patched required fixture,
    number k. The start is the anchor's address − (k − 1) × footprint, in the
    anchor's universe; the start is never rolled back across a universe.
  - **Block** when every patched required fixture sits on its slot from that
    start: "Block · A 0.0.0 from 1". An unpatched fixture does not break the
    block; the group says "1 unplaced".
  - **Custom** when a patched required fixture is off its slot, or the start
    falls below address 1: "Custom · 2 of 8 off the block", with **Re-lay as
    block** (from the anchor's start).
  - A group with nothing patched shows **Patch as block**, which starts at the
    standard patch's position (layers at A 0.0.0 address 1, the Master on the
    next universe at 1, outputs after the Master).
  - Known corner, accepted: an anchor that sits on a universe reached by a
    carry (Layers 1–8 unplaced, Layer 9 at A 0.0.1 1) gives a start below 1, so
    the group shows Custom, although a block from A 0.0.0 1 would fit. Rolling
    the start back across a universe is ambiguous in general (Layer 3 at
    A 0.0.1 1 fits 64 starts), and placement then follows "after n − 1".
    Placing relative to the anchor would avoid it; that is a later refinement.
- **Moving a block.** Changing the start universe or address (address 1 to
  513 − footprint) re-lays every required fixture of the group in one command,
  and the patched optional fixtures with it (Keystones keep their slot, below).
  A note says how many hand-placed fixtures moved; undo puts them back.
- **One fixture.** Tapping a chip or row opens an inline editor in its group
  (universe, address stepper, Unpatch): the controls of today's Selected
  fixture panel, which goes. The universe settings move to the Universes panel
  (item 4) first.
- **Keystone slots.** The Keystone block starts where a ninth output would
  sit: `slot(9)` of the Outputs block (footprint 8), so the 512 carry applies
  exactly as for outputs (outputs from A 0.0.1 457 put Output 8 at A 0.0.2 1 and
  the Keystone block at A 0.0.2 9). Keystone n sits on slot n of that block
  (footprint 16). With the Master at 1 and outputs
  from 9, the Keystones sit at 73, 89 … 185. **Patch** on a Keystone puts it on
  its slot when that range is free, else on the first 16 free channels after it
  in that universe, else it opens the inline editor. With no Outputs block, it
  opens the inline editor.
- **Automatic placement never collides; a placement the user makes may.**
  `layers.setCount`, `output.add` and a Keystone's Patch leave a fixture
  unpatched rather than overlap another one. Patch as block, Re-lay as block,
  moving a block and editing one fixture may overlap; the overlap shows in
  red, as today.
- **A new fixture that found no room** says why: "no address · A 0.0.1 1–64 is
  taken by Master". In the common case (an 8-layer project adding Layer 9,
  whose slot is the Master's) the Layers group offers **Move Master and
  outputs after the layers**: one `patch.setMany` that moves the Master,
  Outputs and Keystone blocks to the universe after the last layer slot and
  puts the unplaced layers on their slots, as one undo step. It changes the
  console patch too, so it is never done automatically.
- **Engine:**
  - `patch.setMany {entries: [{fixture, universe, address}]}`: one command and
    one undo step. Each entry is checked as `patch.set` checks it, and one bad
    entry, or the same fixture twice, refuses all. `patch.set` stays.
  - `patch.set` and `patch.setMany` refuse an address > 0 for a fixture that
    does not exist: a Layer above the layers that exist (new; today
    `patch.set` accepts it and `effectivePatch` drops it) and, as since PR
    #109, an Output or Keystone without its output. Address 0 is accepted for
    any fixture, so a stale entry can still be removed.
  - `layers.setCount` puts a new Layer n on its slot while the Layers group is
    a Block; when it is Custom, right after Layer n − 1 when that one is
    patched, else at its standard address. When that range is taken, Layer n
    stays unpatched (item 1 keeps it usable from the UI). On a standard patch
    this is today's standard address.
  - `output.add` keeps PR #109's rule, which is its slot of an Outputs block
    that starts right after the Master.
- **Who computes slots.** The engine places automatically (`layers.setCount`,
  `output.add`) with a Core helper on `Patch`. The UI detects blocks and builds
  the entries for Patch as block, Re-lay, moving a block, a Keystone's Patch and
  Move Master and outputs, and sends them as one `patch.setMany`. The slot rule
  thus lives in Swift and in `patch-screen.ts`; one vector file
  (`Tests/Fixtures/patch-slots.json`: start, footprint, numbers → expected
  addresses, including the carry, the 512 boundary and gaps) is read by both
  test suites, so the two cannot drift.

**3. Groups from the channel map.**
- `/api/channel-map.json` gets `fixtures`, in display order, generated from
  `FixtureMode`; `footprints` and `modes` do not change:
  ```json
  "fixtures": [
    { "mode": "layer",    "name": "Layer",    "per": "layer",   "optional": false },
    { "mode": "master",   "name": "Master",   "per": "machine", "optional": false },
    { "mode": "output",   "name": "Output",   "per": "output",  "optional": false },
    { "mode": "keystone", "name": "Keystone", "per": "output",  "optional": true }
  ]
  ```
  `name` is what the patch calls a fixture of that mode
  (`FixtureMode.displayName`): "Name n", or just "Name" for a `machine` mode.
  `machine` is the word the user guide's table already uses for the Master
  ("one per machine"); it avoids "server", which also names Syphon servers.
- `FixtureMode` gets `per` and `optional` next to `footprint`. The GDTF file
  and `docs/channel-map.md` do not change.
- The UI groups by `per` and takes the instances from the project: `layer` →
  the layers that exist, `machine` → one, `output` → the project's outputs.
  - A new mode of an existing kind (another per-output mode) appears without
    UI code.
  - A new kind (Serial devices, §6.1) needs one entry in the UI's table of kind
    → instances.
  - `patch-screen.ts` becomes string-keyed: `FixtureType` is the mode string,
    `ChannelMap.footprints` and `modes` are `Record<string, …>`, and
    `parseChannelMap` checks that `fixtures` lists every key of `footprints`
    instead of a fixed `TYPES` list. `parseFixture` reads the names from the
    list instead of a regex; the labels come from `name`.
  - Until the map arrives, the four entries above are the fallback, as
    `FALLBACK_FOOTPRINTS` is today.

**4. Universes, Who controls, status words and the Patch sheet (UI).**
- **Universes** panel (right column, above the DMX monitor): one row per
  universe that the patch uses, the engine hears, or the project stores
  settings for.
  - Each row shows the name, protocol, interface, hold on loss, the health
    pill of today, and the fixtures on it ("Layers 1–8, Master").
  - A heard universe with nothing patched says "heard, nothing patched", which
    shows a console sending to the wrong universe. A universe with stored
    settings and no fixture says "not used"; its settings stay until reset.
  - Settings belong to the universe, not to the fixtures: moving a block to
    another universe does not take them along.
  - Tapping a row opens its settings (today's fields, moved out of Selected
    fixture) and shows it in the DMX monitor.
- **Who controls**: the toolbar select becomes a card above the groups, with a
  line explaining the current choice. The stored values do not change. Long
  labels for the card, short ones for the Layers screen's per-layer Source
  badge:

  | Value | Label | Short | Line under it |
  |---|---|---|---|
  | `dmx` | Console only | Console | Fanous follows the console. A fixture without an address stays at its defaults; cues and OSC are recorded but do nothing. |
  | `internal` | Fanous only (UI, cues, OSC, MIDI) | Fanous | The console is shown but ignored. |
  | `ltp` | Console and Fanous, latest change wins | Both · latest | Per parameter, the latest change wins. |
  | `htp` | Console and Fanous, highest value wins | Both · highest | Intensity and other numbers take the highest value; folder, file and modes the latest change. |

  The labels live in `layers.ts` (and from there the Source badge), the Patch
  toolbar, `PolicyHint.svelte` (its "Use Console + UI (latest wins)" button)
  and the Show screen's warning, which also says where to change it
  ("Patch › Who controls"). `web/e2e/ui.spec.ts`,
  `docs/user/show-control.md` and `docs/user/console-setup.md` change with
  them.
- **Status words** per fixture. "Unpatch" stays the verb (console language);
  the result is shown as "no address":
  - "ok"; "collides with X · a–b" and "exceeds universe" in red, as today;
  - a layer without an address: "no address · stays dark" in yellow under
    Console only (nothing plays), "no address · Fanous only" in grey under the
    other policies;
  - the Master or an Output without an address: "no address · Fanous only" or,
    under Console only, "no address · at defaults", in grey: full and normal
    are the working state;
  - a Keystone without an address: "not used", in grey, because it is
    optional;
  - a new fixture that found no room names the blocker (item 2).
  `layers.ts` `patchText` says "no address" instead of "unpatched", and the
  DMX monitor calls a channel without a fixture "free".
- **Patch sheet** (toolbar, next to Channel map and Export GDTF): what to patch
  on the console.
  - One line per block or fixture: mode, count, footprint, universe and
    addresses ("Fanous · Layer · 64 ch · 8× · A 0.0.0 · 1, 65, 129, …, 449").
  - An Art-Net universe shows as net.sub.uni and as a flat port-address
    ("A 0.0.1 = universe 1"). A switch "Count Art-Net universes from 1" adds 1
    to the flat number for consoles that count that way, and is remembered in
    the browser. The sheet's header states the convention in use, so a printed
    sheet says it too. sACN numbers do not change.
  - **Print** (a print stylesheet) and **Copy** (tab-separated, for a
    spreadsheet). Read-only, for every role.

**Layout.** Wide (Mac, iPad landscape): left column Who controls and the
groups, right column Universes and the DMX monitor. Narrow: stacked in that
order. 32 layers are one block line and 32 chips that wrap, not 32 rows.

**Not in this design:**
- Serial devices and other future kinds: they get their `per` when §6.1's
  Serial mode is designed.
- A stored block: the block is derived.
- Console-specific universe notations beyond the "+1" switch.
- Patching from the Layers or Outputs screens: they link here.

**Tests:**
- Engine:
  - an unpatched layer under `internal` plays from a UI value; under `dmx` it
    resolves to its defaults;
  - a layer unpatched while a console drives it goes to its defaults
    (`clearDMX`), and its UI values survive;
  - under `htp` with no DMX ever received, a UI value below the default (the
    Master at 50 %) wins (also in `ResolverTests`);
  - a fresh resolver's snapshot equals PR #112's reset values
    (`LayerParameters()`, `OutputParameters()`, `resetMaster()`), so "defaults
    from the resolver" and "defaults from the reset" cannot drift;
  - a layer above the count has no resolver, and `patch.set` and
    `patch.setMany` refuse it;
  - a layer added while a cue holds values takes them at once;
  - `patch.setMany` is one undo step, and one bad entry or a duplicate fixture
    refuses all;
  - `layers.setCount` puts a new layer on its slot, and leaves it unpatched
    with the Master on that slot;
  - a `MallocCounter` test around `DMXStore.publish` (on the DMX queue) with
    eight outputs and no Keystone patched counts no allocation from the
    Keystone recompute;
  - after a loss with hold on a channel held at its default, a UI value does
    not beat the held value under `htp` (`dmxReceived`, not the source);
  - the shared slot vectors pass in Swift.
- Core: `ChannelMapDocument.json()` lists every `FixtureMode` once, with `per`
  and `optional`.
- Web (vitest):
  - the shared slot vectors, block detection (anchor, unplaced, Custom when
    the start falls below 1) and re-lay, including the Art-Net carry
    (A 0.0.15 → A 0.1.0), sACN, the channel-512 boundary and an output gap;
  - Keystone slots and their fallback;
  - grouping from a channel map with an extra made-up mode, which appears
    without code;
  - the status words per policy and per kind;
  - the sheet lines and the "+1" switch.
- e2e: patch Layers as a block from A 0.0.2, then undo restores the patch.

**Build order** (one PR each, after this design):
1. Engine: a fixture exists without a patch (item 1); after PR #112.
2. Engine: `patch.setMany`, the existence check, and slot placement in
   `layers.setCount` (item 2); merged after 1, which makes an unplaced layer
   usable.
3. Core: `fixtures` in the channel map (item 3).
4. Web: Universes panel and Who controls (item 4); the universe settings leave
   Selected fixture here.
5. Web: groups, blocks, the inline editor and the status words (items 2–4);
   needs 1–4.
6. Web: Patch sheet (item 4); after 5.

Steps 3 and 4 are independent of 1 and 2 and can be built alongside them; 1
and 2 share the engine's state tests, so they go one after the other. The user
guide changes with the step that changes what it describes (4–6).

---

## 7. Parameter model (ADR-0009)

### 7.1 One spec, many views

`FanousCore/Parameters/ParameterSpec.swift` is the single source of truth:

```swift
struct ParameterSpec {
  let id: ParameterID            // .layer(.intensity), .master(.control), .output(.testPattern)
  let name: String               // "Intensity"
  let kind: Kind                 // .continuous(range, unit) | .enumerated([Band]) | .discrete(0...255)
  let dmx: DMXEncoding           // .u8(channel) | .u16(coarse, fine)
  let defaultRaw: UInt16
  let osc: String                // "intensity" → /fanous/layer/{n}/intensity
  let smoothing: Smoothing       // .none | .optional(defaultOff)
  let group: Group               // for UI layout and GDTF channel groups
}
```

From this one table the following are **generated**, never hand-written:
the DMX decode tables, the GDTF modes/channel functions, the OSC address map,
the UI labels and value formatters, `docs/channel-map.md`, and the test that
asserts footprints (64/8/8) never change.

### 7.2 Sources and the resolver

Per layer (and for master/outputs) the resolver combines values from sources
into the `ParameterSnapshot` the compositor reads. Designed, not built
(§6.6, 2026-10-30): every fixture that exists will have a resolver, patched or
not, and the patch will only feed it DMX:

| Source | Produces | Cadence |
|---|---|---|
| DMX | raw channel values for the patched fixture | per universe packet (≈ 44 Hz) |
| Internal: cue engine | target values + fade progress for parameters the cue touches | per Control tick (100 Hz) |
| Internal: OSC | last received value per address | on receipt |
| Internal: UI override | programmer-set values (only while "override" is on in the UI; auto-expires after masking a received console for 10 min since the last UI change, to avoid show-time surprises; the count pauses while there is no console traffic or the console wins, so without a console they stay until released) | on command |

Per-layer **source policy** (project setting, default `dmx`):

- `dmx`: DMX only. Internal sources are shown greyed ("not in control").
- `internal`: cues/OSC/UI only. DMX for this fixture is displayed but ignored.
- `ltp`: all sources merged latest-takes-precedence per parameter (timestamp
  of last change).
- `htp`: as `ltp`, but numeric scalar parameters (intensity, volume, RGB…)
  take the highest value. Enumerated parameters (folder/file/mode/blend) fall
  back to LTP.

The resolver runs on the DMX queue when a DMX packet arrives and on the
Control tick for internal changes; both write the same triple buffer. A
"change source" tag per parameter is kept so the UI can show *which source
set this value* ("Layer 3 · Intensity · 255 (DMX U1.5) → 100 %").

### 7.3 Units and smoothing

Snapshot fields are already in render units (floats in canvas-relative units,
radians, 0–1). DMX→unit conversion is in Core and unit-tested against the
channel map tables. Smoothing is off by default (DMX values apply at the next
compositor tick). Per parameter it can be set to linear interpolation over one
DMX frame interval (adds ≈ 1 DMX frame of latency, removes stepping on slow
position fades). `[OPEN-11]` ship with per-parameter smoothing or only a
global switch.

### 7.4 Resolved media

Folder/File → `MediaRef` resolved against the library index (§8); a miss
(folder/file not present) resolves to "none" and surfaces as a yellow marker
on the layer ("Folder 12 / File 4: not found") rather than silently showing
nothing.

---

## 8. Media library and ingest (ADR-0010)

### 8.1 Library layout

One **library root** per machine (machine setting, not project; default
`~/Movies/Fanous Library`), local volumes only (network volumes are rejected
with an explanation). Catalyst-style numeric prefixes:

```
Fanous Library/
├── 001_Opening/
│   ├── 001_intro_loop.mov          HAP Q
│   ├── 002_title.png               still
│   └── _originals/002_title.psd    kept source (ignored by the index)
├── 012_Show/
│   └── 004_intro_loop.mov
└── _incoming/                      uploads from remote clients before ingest
```

- Folder number = first 1–3 digits of the folder name (1–255); file number =
  first 1–3 digits of the file name (1–255). Separator after the digits is
  anything non-digit. Names without a numeric prefix, duplicates, and numbers
  outside range are indexed as **invalid** and shown in red in the Media
  screen; they are never addressable from DMX.
- The index is built at start and kept current with FSEvents (debounced
  500 ms). Metadata (codec, size, fps, duration, alpha, audio channels,
  colour primaries, file hash) and thumbnails are cached in
  `~/Library/Application Support/Fanous/cache/` keyed by path + mtime + size.
- **Playable** = ProRes/HAP in `.mov`, stills. Anything else (H.264/HEVC,
  `.mp4`, `.avi`, image sequences) is indexed as "needs transcode" with a
  one-click ingest action. Long-GOP codecs are deliberately not playable:
  they cannot scrub, reverse or chase timecode deterministically.
- Projects reference media **by (folder, file) number only**, never by path,
  so the same project on another machine (backup, v2) resolves against that
  machine's library.

### 8.2 Reserved folder 0 (inputs and generators)

| File | Source |
|---|---|
| 0 | none |
| 1–20 | cameras and capture cards, numbered as they appear and kept in the project (`/capture`); built 2026-10-30 (B73 step 2b), see §8.2.1 |
| 21–32 | displays (21–28), windows (29–32): design, not built, see §8.2.1; NDI later |
| 100 | solid colour (RGB channels define the colour) |
| 101–120 | test patterns (same set as the Output test patterns), usable as layer content |

`[OPEN-12]` final numbering of folder 0. **As built (2026-10-25):** 100 solid
colour, 101–107 the test patterns, 110 test card (running time or incoming
timecode, frame number, a sweep bar per second, two squares that swap every
frame), 111 colour sweep, 112 clock. A generator is a `LiveTextureSource`
(`Render/Generators.swift`) redrawn by the compositor on its own command buffer
before the canvas pass, so it costs one small full-screen pass per layer and no
file I/O; it then goes through the layer pipeline like media.

**As built (2026-10-27, B61):** files 150–169 are the Syphon servers of other
apps. Files 1–32 are designed in §8.2.1 and not built;
the fixed path is a scene `media` entry (`{folder: 0, file, syphon:
"App/Server"}`) on any folder 0 number, which also beats 150–169.
`Syphon/SyphonCatalog.swift` follows Syphon's directory (an unconnected
`SyphonInput` for its announce/update/retire notifications, which need the
main run loop) and gives each new server the lowest free number; a server that goes keeps
its number (`running` false), one that returns with
the same app and server name takes it again, a rename keeps it, past 20 a new
server gets none (`live.syphon.unnumbered`). Identity while running is the directory's UUID, so two
servers with one name (two engines' canvases) get a number each and connect
to the right one (`SyphonInput.connect(uuid:)`); the engine's own canvas
server is left out. The catalog lives in `RenderService` (as long as the
engine) and is published as `live.syphon.servers` `[{file, app, server,
running, gone?}]`. `MediaLoader` resolves 0/150–169 through it with `liveFactory(name,
uuid)` (status name "Syphon: App/Server", codec `syphon`); a scene `media`
entry on the same number wins. On a catalog change the loader marks a layer
whose server went "not running" and keeps its playback (the last frame stays),
and opens a layer whose server (re)appeared again, so the picture returns
without a new selection; the new input replaces the old one on its first frame
like any media change; a rename updates the status name in place. A layer that
selects a server that is not running stays black until it starts; a running
server that refuses the client reads "could not connect". A process that exits
normally retires its servers through Syphon's unload destructor; one that
crashes or is killed stays listed until an announce request goes unanswered for
6 s (the catalog posts Syphon's `ServerAnnounceRequest` every 5 s while a
server is listed as running), so it reads "not running" within about 11 s. A
server's frame age is not used: servers publish only when their picture
changes.

**As built (2026-10-28, B69):** the numbering is kept in the project,
`syphon: {"151": {app, server}}`, keyed by file like `layerCanvas`, so a forget is
`remove /syphon/151`, its undo `add /syphon/151`, and numbers recorded in between
stay. The catalog starts from it (`SyphonCatalog(numbers:)`)
with every entry gone (`gone: true` until it announces), so a returning server
takes its number back by name with a new UUID whatever the order of the startup
announce; the engine writes the catalog back with `StateStore.correct` (no role,
no history, also under show lock) from the 10 Hz live feed, before its
connected-client check (a headless show records numbers too), the value made on the
store's queue so it is never older than a `syphon.forget`. `syphon.forget {file?}`
(programmer, undoable, refused under show lock) removes one entry, or every
entry not running, and refuses a running one; a project change to `/syphon`
(forget, undo, redo, a loaded version) is adopted by the catalog: a not-running
number the value lacks is dropped (so undo, redo and a loaded version free numbers
too), a running server always keeps its number, an entry on it is dropped and
written back, a new entry with a running server's name on another number is
dropped (it would take that server to the lower number at the next restart), and
a freed number goes at once to a server waiting past the 20.

Since B73 step 1b: `Media/LiveCatalog.swift`, `LiveCatalog(.syphon, …)`; the B61/B69 notes above keep the old names as history.

#### 8.2.1 Cameras, capture cards and screens: files 1–32 (design 2026-10-29, B73)

**Status:** design; steps 1a–2b built (capture devices 1–20, as-built notes
below), displays and windows not yet. The feature-gap survey (`docs/feature-gaps.md`
G1, G3; P1) found that every compared product takes a camera or capture card
and that Millumin, VDMX, Isadora and Mitti take slides and lyrics apps by
screen capture. Both are system frameworks: AVFoundation capture and
ScreenCaptureKit (macOS 12.3+), no vendor SDK. Capture cards are the point
of files 1–20 (a camera on a desk is the demo, an HDMI or SDI feed from a
switcher, a second Mac or a camera is the show); the open build takes every
card the OS presents as an `AVCaptureDevice`, and the cards whose only path
is a vendor SDK come later, in-tree or through the plugin boundary (ADR-0016,
§21), after a licence check (below).

**Capture cards.** Three classes, by how the card reaches AVFoundation:

| Class | How it appears | Cards (to be verified per model at step 2, listed in the user guide) | Fanous |
|---|---|---|---|
| UVC class-compliant, no driver | an `AVCaptureDevice` like a webcam; HDMI in, USB out; 1080p60 or 4K30 typical | Elgato Cam Link 4K, Magewell USB Capture (HDMI/SDI, Plus, Gen 2), AJA U-TAP (HDMI/SDI), Blackmagic ATEM Mini's webcam output and Web Presenter | in-tree, step 2 |
| Vendor driver that registers a CoreMediaIO device | an `AVCaptureDevice` once the driver is installed; PCIe, Thunderbolt chassis, multi-input cards (one device per input) | Magewell Pro Capture family (its Mac driver carries AVFoundation support; its SDK is only for private extras) | in-tree, step 2; the driver is the user's install |
| SDK only, no AVFoundation device | the card is invisible to AVFoundation; Desktop Video does not register a CoreMediaIO camera (to verify) | Blackmagic DeckLink and UltraStudio (Desktop Video SDK); AJA KONA, Io and T-TAP (NTV2: libajantv2 is published MIT on GitHub, to verify, no application needed as far as known) | in-tree source or plugin, see the licence note; the NDI question of B74 is the same shape |

**Licence of the SDK cards: TO VERIFY at step 2, not asserted.** OBS Studio
ships DeckLink input and output in its GPL builds by compiling against the
SDK headers (which carry a permissive licence of their own) and loading
`DeckLinkAPI` at runtime from the user's Desktop Video install; FFmpeg's
`--enable-nonfree` reflects the full SDK EULA, not the headers. If the
headers' licence holds, DeckLink and UltraStudio can be an in-tree Core
source (`dlopen`, like OBS) without the plugin boundary (ADR-0016, §21); the
owner decides after the check. AJA has no AVFoundation path either; the same
in-tree-by-SDK question applies to libajantv2. Cards that come through a
plugin or an SDK number in 1–20 like the others.

A capture card differs from a webcam in what it sends, and the design takes
that in: a card offers 4:2:2 at the source's frame rate (50, 59.94, 60), may
offer 10-bit (`v210`) and interlaced modes (1080i50 from a broadcast camera),
has several inputs (one `AVCaptureDevice` each), loses its signal (the device
stays, frames stop or a "no signal" picture comes) and changes format when the
source does (the texture size follows the frame, as a live layer's size
already does). v1 reads 8-bit progressive or interlaced-as-progressive (an
interlaced frame is shown woven, combing on motion; a deinterlace pass is a
later generator-style step), 10-bit later with B10's 16-bit path; "no frames
for 2 s" reads "no signal" in the layer status and keeps the last frame.

**Numbering.** Files 1–32 of folder 0, reserved since the first design, split
by kind so a console operator can tell them apart:

| Files | Source | Identity kept in the project |
|---|---|---|
| 1–20 | capture devices: UVC cameras and capture cards, Continuity Camera (an iPhone), CoreMediaIO camera extensions | `capture: {"3": {uid, name, model}}` |
| 21–28 | whole displays (the Mac's own, a second Mac's HDMI into a capture card is a capture device) | `screens: {"21": {uuid, name}}` |
| 29–32 | windows of other apps (slides in a window, a lyrics app): later, see below | `windows: {"29": {app, title}}` |

Numbers are given the way Syphon servers get theirs (B61, B69): the lowest
free number of the range when the engine first sees the device, kept in the
project, back by identity (`AVCaptureDevice.uniqueID`, `CGDisplay` UUID)
after a restart, freed by `capture.forget {file?}` (programmer, undoable,
refused for a running device and under show lock), `gone` until seen again.
One catalog class serves all three ranges and Syphon: `SyphonCatalog`
becomes `LiveCatalog(_ kind:)`, whose `Kind` carries the range, the project key
and the identity fields, with the same state machine, project
adoption and `correct` write-back; `/syphon` keeps its name and shape,
`/capture`, `/screens` and `/windows` follow it. `StateStore`'s whole-entry
folding (§11.5, B104) applies to every one of the four keys, and so do the
twin and replay rules of §11.5 (B92, `checkSyphonReplay`), each with the
identity fields of its kind. The scene entry keys are `capture: uid`,
`screen: uuid` and `window: {app, title}` on any folder 0 number; the entry
wins over the catalog, as `syphon:` does.

`AVCaptureDevice.uniqueID` is port-dependent for UVC (USB location plus
vid/pid), so a card moved to another port loses its number. Fallback: an
unnumbered device whose `modelID` and `localizedName` match exactly one gone
entry takes that entry's number, and the entry records the new uid.

**Source path.** Both inputs are a `LiveTextureSource` like Syphon and the
generators: the compositor samples the newest texture on the tick, nothing is
copied and the tick allocates nothing (§4.6). The protocol gets one accessor,
`latestFrame: LiveFrame?` `{texture0, texture1?, kind, bottomUp}`, read once
per tick under the source's lock, so planes and kind never tear (`kind` is
`SourcePixelKind`, default `.rgba`). For packed 4:2:2 the live path takes
`texture0.width × 2` as the media width (step 1a).

**As built (2026-10-30, step 1a, PR #107):** the protocol is `latestFrame`
and `stop()`; `latestTexture` and `bottomUp` are gone. `LayerPlayback.frame`
reads `latestFrame` once per tick and copies it into the reused `liveFrame`
(a `DecodedFrame`), so `texture1` and `kind` reach the layer uniforms by the
movie path; `hasFrame` only tests presence. Syphon builds the frame from one
`FrameSlot` `Mutex` read (`.rgba`, `bottomUp: true`), the generators return
their one texture. A `.v216` live frame's width is `texture0.width × 2` for
the geometry and for `u.texel`, from which the v216 shader case derives pair
positions. The shader is unchanged; its matrix uses 8-bit ratios (16/255,
255/219), exact for 8-bit live frames, while 16- and 10-bit sources read
about one code low at white and about one code off in neutral chroma (B119).
Readback through the compositor (`LiveSourceTests`), `2vuy` and `420v` alike:
white 255, black 0, Rec.709 red 255,1,0, 50 % grey 128; the `420v` Y0/Y1
pair reads 252/3 from linear sampling half a canvas pixel off centre (`2vuy`
picks with the nearest sampler: 255/0). 100 frame reads allocate nothing in
release. `LiveCatalog` is step 1b.

**As built (2026-10-30, step 1b, PR #106):** `Media/LiveCatalog.swift`.
`LiveCatalog(_ kind:excluding:numbers:)` with `Kind` `.syphon` (150–169,
`{app, server}`), `.capture` (1–20, `{uid, name}`), `.screens` (21–28,
`{uuid, name}`) and `.windows` (29–32, `{app, title}`). The project key is
the case name. A capture device or a display is kept by its uid or uuid alone,
and a new name is taken when it is seen again. A Syphon server and a window
are kept by both fields. `LiveCatalog.Entry` has `source`, `name`,
`runtimeID`, `gone` and `label`. The instance methods ignore entries of
another kind. Only Syphon has a source (`start` follows its directory).
`ProjectDocument.liveNumbers(kind, from:)`/`liveValue`, `wholeLiveEntries`
and `checkLiveReplay` (was `checkSyphonReplay`) cover the four keys in one
path; the Syphon texts are unchanged. Not yet: the catalogs and sources for
the other kinds. Also not yet: one `applied` value and one running set per
kind (`recordLiveNumbers` and `checkLiveReplay` take Syphon's). The keys
`/capture`, `/screens` and `/windows` in `initial` and the load migration
come with their first writer (step 2).

**As built (2026-10-30, step 2a, PR #116):** `Capture/CaptureInput.swift`.
*Spike:* `makeTexture(descriptor:iosurface:plane: 0)` accepts `.bgrg422` on
an IOSurface-backed `2vuy` buffer and `.gbgr422` on a `yuvs` one, at full
width. Sampled (nearest or linear) or read, both return (r, g, b) = (Cr, Y,
Cb) with alpha 1: the luma of each full-width pixel, and chroma the hardware
reconstructs as centre-sited (each pixel ¾ its own pair, ¼ the neighbouring
pair on its side; only the two edge pixels read their pair exactly). The
crossed pairing (`2vuy` as `.gbgr422`) mixes luma into the chroma channels.
The hardware does not convert YCbCr to RGB, so these formats still need a
shader case (a kind reading (Cr, Y, Cb)), and their chroma differs from the
movie path's co-sited pick. Built instead: the step-1a path. Packed 4:2:2 is
an `rgba8Unorm` view at half width; `2vuy` reads as `.v216` unchanged, and
`yuvs` reads as the new `.yuy2` (8). That kind shares the v216 case in
`Shaders.swift` after `p = p.grab`, and the compositor doubles the width for
both. `420v` is planes 0/1 as `r8Unorm`/`rg8Unorm` (`.planarYCbCr`), `BGRA`
`bgra8Unorm` (`.rgba`). Views are made once per IOSurface and cached (8
entries, cleared when full, as after a format change). In the spike, a
`CVPixelBufferPool` handed back the same buffer 20 times while a Metal view
on its surface stayed alive, so the cache does not starve the pool.
Readback through the compositor (`CaptureInputTests`, synthetic
IOSurface-backed buffers): all four formats read white 255, black 0, red
255,0,0, grey 128 (±1). The Y0/Y1 pair reads 255/0 for `2vuy` and `yuvs`
(nearest) and 252/3 for `420v` and `BGRA` (linear). Packed frames keep their
full-width aspect.
*Session:* configured, started and stopped on the capture queue
(`org.fanous.capture.<uid>`, `.userInteractive`), never on the loader
thread; the input reads `.starting` meanwhile, and `.failed(reason)` when
the session cannot start (the layer shows the reason). Among the device's
formats of the active format's size, a frame-rate range that holds the
canvas rate wins (1000/1001 apart is the same rate, as
`DisplayModeMatching.sameRate`), the one whose top is closest above it
first. Its min and max frame durations are both set to the canvas rate,
clamped to the range, so a camera does not slow down in low light. Without
such a range, the fastest range below the canvas rate runs at its top. Equal
rates prefer `2vuy`/`yuvs`/`420v` over MJPEG. With no fitting range the
active format is left alone. The canvas rate is the scene's at service
start; `canvas.set` does not reopen a device. The output is asked for
`2vuy`, `yuvs`, `420v` (from `420v`/`420f`) or `BGRA` by the native subtype,
and for `BGRA` when the output does not list the wanted type (setting an
unlisted one raises). The device's configuration lock is held across
`startRunning`, so the session preset cannot put its own format back. After
the start, the engine logs what runs: "capture <name>: <subtype> <w>x<h> @
<fps>", plus the preset and the min rate. A warning follows if the running
format differs from the chosen one. Not observed here (no camera can be
opened in this environment): whether macOS resets the format without the
lock. That is part of the owner's live check.
*Retention:* one `Mutex` slot (ADR-0002, amendment 2026-10-30). The capture
queue stores the newest frame, and an untaken frame it replaces is released.
`latestFrame` returns the newest and moves it, once, into a ring of the last
three taken. 100 reads through `LayerPlayback.frame` allocate nothing in
release. Neither do 100 takes of 1080p `2vuy` pool buffers, each of which
evicts a buffer whose last release returns it to the pool on the reading
thread.
*Counters:* `frames`, `dropped` (`didDrop`), `outOfBuffers` (`didDrop`
with reason `OutOfBuffers`) and `unusable` (a delivered frame without an
IOSurface or a texture view, with its reason logged once). They are logged
at `info` every 60 s while frames arrive and on `stop()`, and published per
layer as `layers[].capture` beside the size, which follows the newest frame.
Whether 60 fps runs short is the owner's live check.
*Status:* `.starting`, `.running(fps)`, `.noSignal` (no frame for 2 s, or a
runtime error, interruption or disconnect until the next frame; the last
frame stays), `.stopped` and `.failed`. The loader polls every open capture
layer on its 100 ms loop and writes the status text, fps, subtype, size and
counters to the layer status.
*Scene entry:* `MediaEntry.capture` (a `uniqueID`) on any folder 0 number,
"Camera: <localizedName>". `MediaLoader.captureFactory`
throws its refusal as the layer's text and returns the `CaptureInput` itself
(not `any LiveTextureSource`) so the loader can read its status.
*Permission:* `CaptureInput.open` asks only when `allowed`.
`RenderService.captureAllowed` is set by the engine to "not in show mode".
While the dialog is open the layer reads "waiting for camera permission";
the answer reopens the layer (`MediaLoader.capturePermissionChanged`). In
show mode the layer reads the "not asked" text, and after a refusal the
"denied" text above. `com.apple.security.device.camera` is in
`scripts/entitlements.plist`; `NSCameraUsageDescription` and
`NSCameraUseContinuityCameraDeviceType` are in both Info.plists.
Not yet: files 1–20 by the catalog (step 2b). Two layers on one uid also
open two sessions today; step 2b shares one input per uid. Also not yet:
`v210` and the card list. The subtype shown is the one at start; the size
follows the frames.

**As built (2026-10-30, step 2b, PR #120):** files 1–20 by the catalog.
*Catalog:* `LiveCatalog.startCapture()` (`RenderService`, beside Syphon's)
reads `AVCaptureDevice.DiscoverySession` (`.external`, `.continuityCamera`,
`.builtInWideAngleCamera`, video) on the main queue at start, on
`wasConnected`/`wasDisconnected`, and every 2 s for
`isInUseByAnotherApplication` (no notification says another app opened a
device). Listing asks no permission. An entry is `source` = `uniqueID`,
`name` = `localizedName`, `runtimeID` = `uniqueID` while connected, plus two
`Entry` fields only capture fills: `model` (`modelID`) and `inUse`. `/capture`
is `{"3": {uid, name, model}}` (`Kind.fields` gained the model name, nil for
the other kinds). *Fallback:* `assign` first matches every running source by
runtime id or identity. Then a device with a model takes the number of the
entry not running with the same `model` and `name`, and that entry records the
new uid. This needs exactly one candidate on both sides: two such entries, or
two newcomers with that model and name, match nothing. The rest get numbers in
order. Matching by uid first means a returning device never loses its number
to a newcomer of its model. In use is still running (`live.capture` `running:
true, inUse: true`).
*Project:* `initial` and the load migration add `/capture` `{}`. The engine
keeps the applied value per kind (`liveInProject`); the 10 Hz feed writes
both catalogs back through `correct`, and a project change (`capture.forget`,
undo, a revert, a loaded version) is adopted by the catalog of its key.
`capture.forget {file?}` is `syphon.forget` on `/capture` (one registration
loop). The forget commands' replay check gets the running files of both
catalogs (the ranges do not overlap). `project.revert`'s replay check still
passes none, as before. A known edge: an undo (or a loaded version) can put a
uid back on its old number while that device runs under a new number after
the fallback. The catalog keeps the running number, and the device moves back
to the old one at its next replug.
*Commands:* `capture.authorize {kind}` (programmer, refused under show lock
and in show mode, not undoable): `camera` calls
`CaptureInput.requestAccess(allowed: true)` and then
`MediaLoader.capturePermissionChanged()`. `screen` is refused with
`unavailable` until step 3.
*Permissions cache:* `authorizationStatus` (about 25 ms, a TCC round trip
that is not cached) and `CGPreflightScreenCaptureAccess()` (about 12 ms) are
read by the capture catalog: once at `startCapture`, then on a utility queue
with every 2 s poll and after each `requestAccess` answer (from
`capture.authorize` or from the loader's own prompt). The feed and readiness
read `LiveCatalog.permissions`, never TCC: the feed shares its serial queue
with the 20 Hz DMX monitor stream.
*Loader:* a folder 0 file 1–20 without a scene entry resolves through the
catalog: "Camera: <name>", "not running" without a runtime id, else
`captureFactory(uid)`. While the device is `inUse`, the layer reads "in use by
another app" and is not opened, unless one of our layers already holds a live
session on it: that session is shared first, because the flag may come from
another app that opened the device after us. A scene entry still wins.
`captureDevicesChanged` (the catalog's `onChange`) works like
`syphonServersChanged`, and the loader remembers the uid each layer opened (as
`syphonOpen` holds the runtime id):
- A layer whose device went reads "not running" and keeps its input (the last
  frame).
- A layer is opened again when its device is running but not open, or open
  under another uid. The second case is one update carrying an unplug and a
  replug on another port (the 2 s poll, or merged changes).
- A layer whose session failed or stopped is opened again too.

One input per uid: the loader keeps uid → weak `CaptureInput`, and a second
layer calls `share()` (a user count in the input's slot) instead of the
factory. `share()` refuses a stopped or failed input. `stop()` stops the
session when the last user lets go. A session that goes (device gone, uid
changed, failed) is dropped from the table, so the next open makes a new one
for every layer on the device. Two layers on one device mark the same frame
taken once, so the ring of three still covers both.
*Feed:* `live.capture` `{devices: [{file, name, running, gone?, inUse?}],
screens: [], permissions: {camera, screen}}`: camera from the cached
`authorizationStatus` (`restricted` reads `denied`), screen from the cached
`CGPreflightScreenCaptureAccess()` until step 3 asks for it. Whether
`isInUseByAnotherApplication` counts our own session is not known. If it
does, the feed would have to drop `inUse` for the uids the loader holds open
(its `captureShared` keys). That is the owner's live check.
*Readiness:* item `capture` "Capture permissions granted" fails while the
catalog has an entry (running or not) and the camera is not `granted`. The
built-in camera counts as an entry, so a laptop without the grant fails
until the item is acknowledged. Detail "camera: <word>", fix "System
Settings › Privacy & Security › Camera, then Engine › Restart". It blocks
show mode until acknowledged.
*Tests* (fake device lists): numbering; the fallback (one twin, two twins, two
newcomers, another model, uid first); `inUse`; `live.capture`; the forget and
authorize rules; `/capture` through a revert and its undo; the migration; the
readiness item. The loader tests cover:
- two layers on file 3 with one factory call
- unplug and replug in separate updates, and in one update under a new uid
  (one new shared session, the old one stops)
- in use: a new layer is refused, but our own session is shared first
- a failed session: not shared, and opened again
Not verified here (no camera in this environment): discovery of real
devices, Continuity Camera, the permission prompt's name, and a replug
on another port. They are the owner's live check.

| Input | Framework | Pixel path | Kind |
|---|---|---|---|
| Capture device | `AVCaptureSession` with one `AVCaptureVideoDataOutput` on its own serial queue; the active format is the device's format whose size matches its current input and whose frame rate is the highest at or below the canvas rate (a card follows its source anyway) | the native format is `AVCaptureDevice.Format.formatDescription.mediaSubType`, not `availableVideoPixelFormatTypes` (that lists what the output can convert to). The output is asked for the native subtype when it is `2vuy` (Cb Y0 Cr Y1) or `yuvs` (YUY2: Y0 Cb Y1 Cr, what Cam Link-class UVC devices send), for `420v` when native is `420v` or `420f`, else for `BGRA` (MJPEG-only webcams: AVFoundation decodes, there is no 4:2:2 to keep) | `2vuy` → `.v216` (same byte order), as `rgba8Unorm` at half width; `yuvs` → new `.yuy2`, the same texture with the pairs swapped (one more shader case, no new matrix); `420v` → `.planarYCbCr`, planes 0 and 1 as `r8Unorm` + `rg8Unorm`; `BGRA` → `.rgba`. The layer shader's Rec.709 video-range matrix (§4.1) reads 8-bit textures unchanged |
| Display | `SCStream` with `SCContentFilter(display:excludingApplications:exceptingWindows:)`, the engine's `SCRunningApplication` excluded and `exceptingWindows` `[]` (an output on a captured display would feed back) | `BGRA`, ScreenCaptureKit's native output; `SCDisplay.width/height` are points, so the pixel size comes from `CGDisplayPixelsWide/High` (or the frame × scale), scaled down to fit the canvas when larger (aspect kept); `SCStreamConfiguration.colorSpaceName` set to sRGB explicitly (the default follows the display, P3 on most Macs); `minimumFrameInterval` = the canvas rate; cursor off; no audio; `queueDepth` 4 | `.rgba` as `bgra8Unorm`; a sample whose status is not `.complete` (an idle display) keeps the last texture |

Displays bound as Fanous outputs are left out of 21–28: they would show only
the excluded engine windows, black. `SCContentSharingPicker` is rejected: it
needs a human pick per session.

The textures are views on the frame's IOSurface, not `CVMetalTextureCache`
textures: `makeTexture(descriptor:iosurface:plane:)`, planes 0 and 1 for
`420v`. Step 2 spikes this first: Metal's `bgrg422`/`gbgr422` formats if that
call accepts them for the packed 4:2:2 buffers, else an `rgba8Unorm` view at
half width, as `MovieSource` does for `v216`.

**Buffer retention.** The source keeps only the frames the compositor has
taken (the tick marks the frame it samples): the last three taken (three
command buffers in flight on the display paths, §4.6) plus the latest,
independent of the capture rate. AVFoundation's pool may then run short
(`didDrop` with reason `OutOfBuffers`); step 2 measures that with a 60 fps
card. If it drops, the fallback is a blit of the taken frame into the
source's own pool of three textures on the tick's command buffer: one more
encoder and three allocations per live layer per tick, no retention.
Headless ticking can be eight deep and can still sample a refilled buffer: a
torn frame, never a crash. The capture queues allocate, the compositor
thread does not. Latency, engine-side and before the card's own, is one
capture frame plus one tick: about 33 ms from a 30 fps camera, 16 ms from a
60 fps one, one or two frames for a display.

Colour: a camera's frame is read as Rec.709 video range (the shader's only
matrix); SD sources tagged Rec.601 and HDR cameras are read wrong until the
shader takes the frame's tag (with B21). A display's BGRA is sRGB. Audio of
a capture device is not taken (G13, separate). Rotation and mirroring of an
iPhone or a front camera: later.

**Hot-plug.** The capture catalog follows
`AVCaptureDevice.DiscoverySession` (`.external`, `.continuityCamera`,
`.builtInWideAngleCamera`) and the connected/disconnected notifications on
the main run loop, like the Syphon catalog follows Syphon's directory; the
screen catalog follows `DisplayManager`'s list (§9.6). A layer whose device
goes keeps its last frame and reads "not running"; the device returning
reopens it, as for Syphon (B61). A device opened by another app (Continuity
Camera in FaceTime) reads "in use".

**Permissions (TCC).** The engine is the LaunchAgent helper bundle
`org.fanous.engine` with its own Info.plist (§2.4), so prompts name "Fanous
Engine" and carry its usage strings. `scripts/bundle.sh` adds
`NSCameraUsageDescription` and `NSCameraUseContinuityCameraDeviceType` to
both Info.plists, and the hardened runtime needs
`com.apple.security.device.camera` in `scripts/entitlements.plist` (today it
has only `audio-input`). Screen capture needs no entitlement. The two
permissions behave differently, and the design keeps them apart:

- *Camera* (`AVCaptureDevice.requestAccess(for: .video)`): asked once, when a
  layer first selects a capture file or on `capture.authorize {kind:
  "camera"}` from the System screen, and only outside show mode. In show mode
  a layer on a capture file with permission `notDetermined` reads "camera
  permission not asked: authorize on the System screen" and stays black.
  Denied → "camera permission denied: allow Fanous Engine under Privacy &
  Security › Camera", as B37 does for the microphone. Granted stays granted.
- *Screen* (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`):
  macOS applies a grant only to a new process. `capture.authorize {kind:
  "screen"}` calls `CGRequestScreenCaptureAccess()`, which returns at once
  (the grant happens in System Settings); the engine then polls
  `CGPreflightScreenCaptureAccess()` once a second for two minutes and exits
  cleanly when it turns true, which `KeepAlive` restarts (a foreground
  `fanousd` only logs "restart the engine"). Whether preflight flips in the
  granting process is verified at step 3; the System screen shows Restart
  engine either way. Refused in show mode and under show lock, like
  `canvas.set`.
  Every supported macOS (ADR-0020) re-asks a screen-capturing app about
  monthly ("Allow For One Month"), a dialog on the main display that an
  unattended show machine cannot answer and that may sit on an output.
  Mitigations, in order: the readiness check (below), an MDM profile
  (OPEN-20; a PPPC profile cannot pre-approve screen capture, so the dialog
  stays unless Apple's `persistent-content-capture` entitlement is granted to
  the Developer ID build, B50, to be verified), and the user guide's advice
  to prefer a capture card for a show-critical slides feed.

**Readiness (§14).** A new item "Capture permissions granted", reading the
permission state: camera fails when the capture catalog has an entry and the
permission is not granted; screen fails when the screens catalog has an entry
and it is not granted. The fix line is "System Settings › Privacy & Security
› Camera / Screen & System Audio Recording, then Engine › Restart". It blocks
show mode until acknowledged, so no permission prompt appears during a show.
The screen item also warns when the screens catalog has an entry (the monthly
re-confirmation).

**Live feed and UI.** `live.capture: {devices: [{file, name, running,
gone?, inUse?}], screens: [{file, name, running}], permissions: {camera:
"granted" | "denied" | "notDetermined", screen: "granted" | "denied"}}`. The
Media screen's folder 0 list gets the groups "Cameras and capture cards
(1–20)" and "Displays (21–28)" with the green dot and Forget of the Syphon
group; the layer panel's folder 0 picker lists them the same way; the
System screen shows the two permissions with an Authorize button. The console
side needs nothing: File 1–32 in folder 0 already dials them (§6).

**Windows (29–32), later.** A window is named by its app's bundle id and title
(`capture.window {file, app, title}` from a list the engine publishes as
`live.capture.windows`, read through `SCShareableContent`); matched by app and
title prefix, falling back to the app's frontmost window; captured with
`SCContentFilter(desktopIndependentWindow:)`. Not in the first two steps: a
display covers Keynote and PowerPoint in presenter mode, and a window's title
changes with its document.

**Tests.** The pixel path (a synthetic IOSurface-backed `CVPixelBuffer`
through the texture views into the layer shader, read back) and the catalogs
(fake device lists, like `SyphonCatalogTests`) run on CI; a real device and a
display need the permission, so the dev Mac's built-in camera, an iPhone over
Continuity Camera and a display capture are the owner's live check per step.
Which capture cards appear as AVFoundation devices (UVC ones do, Magewell's
driver does, DeckLink does not) is checked per model at step 2 and listed in
the user guide with the formats each one offered.

**Order (one PR each, after approval):** 1. `latestFrame` and `LiveFrame`
(step 1a; `MovieSource.swift:21`'s enum comment on `planarYCbCr`, "Y plane
r16", becomes "r16 or r8"), 8-bit planar readback test, `LiveCatalog` from
`SyphonCatalog` (no behaviour change). 2. Capture devices 1–20: texture-path
spike, input with the four pixel formats (`.yuy2` added), catalog, permission,
readiness, Media and layer UI, user guide with the verified card list (owner:
one UVC card and a Magewell Pro Capture on the dev Mac, if available). 3.
Displays 21–28: input, catalog, permission with restart, readiness, UI, the
risk note (§20 R18), user guide. 4. Windows 29–32 when a show asks for them.

### 8.3 Ingest flow

```
source file(s) ──▶ _incoming/ (remote upload) or in-place (local path)
   │
   ▼ probe (AVAsset): codec, alpha, fps, audio
   ▼ job: target folder/file number, target codec (project default, per-job override)
   ▼ transcode (one job at a time; paused while show-locked unless "allow ingest in show mode")
   │     ProRes:  AVAssetReader (any AVFoundation-decodable source) → AVAssetWriter ProRes (hardware encoder) + LPCM audio
   │     HAP:     AVAssetReader → RGBA frames → hap.c HapEncode (+ Snappy) → AVAssetWriter passthrough samples with a 'HapY'/'Hap5'/'Hap1'/'HapM'/'HapA' format description
   │     stills:  copy (PNG/JPEG/TIFF/HEIF) ; image sequence → ProRes 4444 or HAP Alpha movie at the chosen fps
   ▼ write to NNN_name.mov in the target folder, original moved to _originals/ (configurable: keep in place / delete)
   ▼ index update → thumbnail → available to DMX
```

- Progress, ETA, and errors are part of the live state (Media screen and a
  global ingest indicator). Jobs survive an engine restart (queue persisted).
- Target codec defaults: ProRes 422 HQ; sources with alpha → ProRes 4444;
  per job: HAP, HAP Alpha, HAP Q, HAP Q Alpha, HAP Alpha-only, ProRes 422
  (Proxy/LT/422/HQ), ProRes 4444 (XQ).
- Audio is transcoded to 48 kHz LPCM so playback never needs a compressed
  audio decoder.
- HAP muxing through `AVAssetWriter` passthrough works (`MovieWriter`,
  Phases 2–4); the own-muxer fallback was not needed (`[OPEN-13]` resolved).
- **Phase 4 as built:** `LibraryIndex` (scan + FSEvents, 500 ms debounce,
  code-point order decides duplicate numbers), metadata/thumbnail cache in
  `cache/library-index.json` + `cache/thumbnails/`, `Thumbnailer` renders the
  mid-file frame through the layer pipeline; `IngestQueue` (one `.utility`
  thread, JSON-persisted, yields while the last 250 ms of frames exceeded 70 %
  of the frame budget), `Transcoder` (AVAssetReader → `MovieWriter`, audio to
  48 kHz LPCM, alpha sources promoted to ProRes 4444 / HAP Alpha),
  `IngestAPI` (`/api/ingest`, `PUT /api/upload/<folder>/<name>` streamed to
  `_incoming/`). Role checks come with Phase 5.
- Transcode never runs on the compositor's P-cores exclusively: ingest threads
  are `.utility` QoS and the job yields when the compositor's measured frame
  time exceeds 70 % of budget (instrumentation feeds back into scheduling).

### 8.4 Thumbnails

Generated by the engine (it has the decoders): one mid-file frame per movie,
downscaled on the GPU to 320 px wide, encoded JPEG (hardware JPEG via
VideoToolbox when available, ImageIO otherwise). The same JPEGs serve the
Media screen, the Layers screen (media thumbnail) and CITP/MSEX element
thumbnails. Live layer thumbnails (§11.4) are separate.

---

## 9. Canvas, output, blending and mapping model (ADR-0011)

### 9.1 Entities

```
Project
├── Canvas[]          id, name, size (px), background, clock-master output (≤ 4 canvases, one rate; layer → canvas: project `layerCanvas`, §9.5b)
├── Display[]         runtime: identity (UUID + EDID name), current/available modes — matched to project outputs by identity
├── Output[]          id, name, display identity, region on display (origin, size in display px), desired display mode,
│   │                 intensity, blend edges {left,right,top,bottom: overlap px, curve (power γ), black lift},
│   │                 warp {cornerPin: 4 points, mesh: N×M control points (bezier), density}, test pattern,
│   │                 colour {gain r, g, b; black offset} (§9.9)
│   └── Slice[]       canvas id, source rect on canvas, destination: quad (4 points) or mesh (N×M) on the output,
│                     mask: polygon/bezier path + feather px, opacity, order
└── Serial device[]   (later)
```

Defaults make the simple case zero-config: a new output gets one slice
mapping the full canvas to the full output, no blend, identity warp.

A **display can carry several outputs** (regions), so a 4K HDMI port into a
Datapath/Matrox splitter is four outputs with their own blend/warp; the
engine renders them in one drawable pass per display.

### 9.2 Blending

Per edge, for the overlap zone of width `w` px, with `t ∈ [0,1]` across the
zone:

```
s(t) = t < 0.5 ? 0.5·(2t)^p : 1 − 0.5·(2(1−t))^p        // S-curve, p = "power"
factor(t) = s(t)^(1/γ)                                  // γ matches the projector's gamma so that
                                                        // A(t) + B(1−t) is perceptually flat
```

Black-level compensation: outside the overlap zones a `lift` is added so the
single-projector area matches the doubled black floor of the overlap:

```
out = in · factor + lift · (1 − inOverlap)              // lift and inOverlap feathered over `liftFeather` px
```

An output with overlaps on both axes (a grid wall) takes the lift by coverage
instead, since M2.1: `lift · ((4 − n) / n)^(1/γ)` (γ the fixed projector gamma
2.2, not the edge's) with n = (1 + zx)·(1 + zy) projectors on the pixel (zx,
zy the feathered `inOverlap` per axis), so every point reaches the black of
the four-projector corner (§9.10 item 1).

The lift is stored as the code value it gives on black. Since M1.7 the
output pass adds it in linear light (γ 2.2), so the `+` above is exact at
Grey 0 % and a brighter picture gets only the light the lift adds (§9.9,
"As built (M1.7)").

Both the per-pixel `factor` and the lift term are precomputed into one
`rgba16Float` **blend map** texture per output on Control whenever the blend
settings change (edit-time cost only): a factor per channel (R, G, B) and the
lift. Each channel's factor uses its own γ when the edge has per-channel (RGB)
gamma (OPEN-14, since M1.6; §9.9), else the edge's γ for all three. Grid
arrangements fall out naturally: corner pixels multiply the horizontal and
vertical factors, per channel.

### 9.3 Warping

The warp of an output is stored as control points (corner pin = 4 points;
mesh = N×M bezier control points, density adjustable 2×2 … 33×33) and
compiled on Control into a **displacement field** texture (`rg32Float`,
output-resolution/4) that maps undistorted output coordinates to warped
output coordinates. The output pass's vertex shader samples this field per
vertex; slices are tessellated to at least 64×64 quads so curved warps stay
smooth. Changing warp = regenerating one small texture; the render loop
never sees control points.

### 9.4 Slices and masks

A slice's destination quad/mesh is in output coordinates (pre-warp). The
vertex shader: slice vertex → output coordinate → displacement field →
clip space; UV = canvas rect. From M2 a Keystone homography follows the
displacement (§9.10). The mask path is rasterized on Control into an `r8`
mask texture at output resolution, with the feather applied as a linear ramp
over the signed distance, so feathering is exact and free at render time.

### 9.5 Output pass, summarized

```
for each slice (ordered):
  vertex:   mesh vertex → warp displacement → keystone → clip   (M2, §9.10: a preset morph mixes two such positions;
                                                                 raw bypasses warp and keystone)
  fragment: canvas.sample(uv) × scale                           (scale 1 live; frozen: master now / master at Freeze;
                                                                 a test pattern replaces this, whole output)
            → × blendMap.factor r, g, b                         (per channel, §9.9 M1.6; skipped when Output "raw" is set)
            → × colour gain r, g, b                             (raw too)
            → + blendMap.lift + colour black offset in linear light, γ 2.2 (lift skipped in raw; §9.9 M1.7)
            → × mask(uv) × slice.opacity                        (the slice's alpha, after the lift: lift and black offset
                                                                 fade with the slice; no mask in raw; none on a pattern)
            → × output intensity                                (0 at Output or Master Blackout, and at Master 0; patterns too)
            → × master intensity on a test pattern only         (content: the canvas carries it)
            → blue-noise dither → drawable (bgra8 / bgr10 later) (not on a test pattern)
```

The Master intensity is applied once, per layer into the canvas, so the
canvas preview, Syphon, CITP and every output show the same level (B100: the
output pass multiplied it in a second time, 50 % gave 25 %). A layer takes it
as a colour scale, not an opacity (its alpha is its own intensity × crossfade):
each blend mode is the Master × that mode at dst / Master, clamped to
[0, Master], so the canvas is exactly the Master × the canvas at 100 % and a
lower layer never shows through an opaque one (B108). A held (Freeze)
canvas carries the Master it was drawn with, which `holdFrozen` keeps with it
(`OutputPlan.heldMaster`: the compositor tick's own or, on a secondary display,
the one stored with its last completed canvas in one atomic with the ring
index), so a frozen output follows later Grand Master moves; the ratio scales
the canvas sample, before the blend map. Freeze engaged at Master 0 holds
nothing (a black canvas carries no picture): the output stays live, black, and
holds the first canvas drawn above 0. An edit while frozen recompiles the plans: the new
`OutputSet` carries the last set that rendered (`previous`, behind a mutex; a set
that never rendered drops out, so the chain is one set long), and the thread that
renders it takes each frozen plan's hold from the replaced plan with its id, once,
if the copies cover the plan's canvases at their sizes (`OutputPass.adopt`; not on
MainActor, which would read `held` while the render thread writes it), so the
output keeps its frame (B111).

The output preview (§11.3) of a frozen output holds with it (B107). For an
output on the clock-master display its plan takes the master set's plan's
`held` and `heldMaster` each preview frame (both written on the compositor
thread the tap runs on). The tick reads its output set once, holds, then taps
with that set (B110), so on the engage tick the preview takes the copy blitted
earlier on the same command buffer. It is the frame the projector holds, no
copy, also for a viewer that subscribes after Freeze engaged. An output on a
secondary display (its plans are written on that display's thread) or one
bound to no display holds a copy of its own with `holdFrozen` in the tap, from
the first preview frame after Freeze engaged: it can be a few ticks later than
the projector's and hold a later frame, and a viewer that arrives later holds
what was live then. Either way it follows the Master through `contentScale`
and goes live on release.

The black lift, like the colour's black offset, is the projector's black
floor, so it does not follow the Master: on content it stays at the output's
level while the Grand Master moves (it used to go down with it; on a test
pattern it still does) and is 0 at Master 0 and at an Output or Master
Blackout. Master 0 or Blackout is black at once also on a secondary display,
which draws the last completed canvas.

One pass, no intermediate textures; "all output/mapping configuration is
applied entirely on the GPU in the final output pass" is satisfied.

### 9.5a Phase 6 as built (2026-10-23)

- Model (`FanousCore/Mapping/OutputModel.swift`) and edit-time math
  (`MappingMath.swift`, Foundation only, tested): blend map (two floats per
  pixel: factor and lift term; four since M1.6, a factor per channel), warp
  displacement field (homography for the corner pin, Catmull-Rom surface
  through the mesh points, evaluated separably), mask raster (signed distance with the feather, on a 4× coarser
  grid for feathers ≥ 2 px; CoreGraphics fill for hard edges), 64×64 slice
  meshes.
- Output pass (`OutputRenderer.swift`, `mapped_vertex/fragment`): per output
  region a viewport/scissor, per slice one indexed draw; slices alpha-blend
  over each other in order; the Output fixture's intensity, blackout, test
  pattern and raw switch and the Master's intensity/pattern are applied from
  the parameter snapshot. Dither is an interleaved-gradient-noise function
  (B34).
- `OutputCoordinator` binds project outputs to displays by UUID, owns one
  window per display, drives the compositor from the clock-master display and
  presents the other displays from the latest completed canvas on their own
  threads; drivers join on stop so the compositor never ticks twice. Without
  a bound output the compositor runs headless. `DisplayManager` enumerates
  displays with `CGDisplayCreateUUIDFromDisplayID` and debounces
  reconfiguration callbacks (300 ms).
- Commands `output.add/remove/set` (JSON-pointer edits validated as a whole),
  `canvas.set`; `live.displays` and `live.outputs` (bound / lost /
  unassigned, master). A scene `display` index becomes a bound output on first
  start. The preview stream takes `target: output:<id>`.
- Measured: 2×1 and 2×2 blends of a flat field are flat in linear light
  within 2 % (readback test, γ 1 and 2.2); a 33×33 mesh with a feathered mask
  compiles at 1080p in 3.7 ms (release) / 145 ms (debug); binding an output
  to the built-in display costs one missed frame at the driver switch.

### 9.5b Multiple canvases as built (2026-10-26)

- Project: `canvases` holds up to 4 (`ProjectDocument.maxCanvases`) with at most
  4 × 3840 × 2160 pixels together (`maxCanvasPixels`, ≈ 800 MB of rgba16Float
  triple buffers), checked by `canvas.add`/`canvas.set`; canvas 1
  cannot be removed (the clock master, Syphon and CITP follow it). One compositor
  clock, so one rate: `canvas.set` on canvas 1 sets it on every canvas,
  `canvas.add`/`canvas.set` on another canvas refuse a differing rate.
  `canvas.add {width,height,fps?,name?}` and `canvas.remove {id}` are refused
  in show mode (they re-create the canvases); `canvas.remove` moves the
  canvas's layers and slices to canvas 1 in the same undo step.
- Layer → canvas is a project setting, not a DMX channel: sparse
  `layerCanvas: {"5": 2}` (unset = canvas 1), set by `layer.set {layer, canvas}`
  (programmer, refused under show lock); `layers.setCount` drops entries of
  removed layers. `output.set` refuses a slice on a canvas that does not exist.
- Compositor: one `CanvasTarget` per canvas (three textures, one triple-buffer
  index for all), one render pass per canvas per tick drawing only its layers;
  static-picture reuse covers all canvases at once (a draw item carries its
  canvas). `reconfigure(CanvasLayout)` keeps the textures of canvases whose
  size did not change; `OutputCoordinator.setCanvases` stops and restarts the
  drivers around it like B31. `CanvasSwitch` tracks the whole layout; the
  compositor gets every project canvas before its first tick (so a restart in
  show mode, which defers switches, still renders them all).
  Generators take the size of their layer's canvas (made at canvas 1's size,
  resized on the first tick). Layer capacity is unchanged: a layer costs the
  same on any canvas.
- Assignment against what renders: Control records the project's layer and
  slice canvases; the main actor applies them (`Engine.applyCanvasUse`, after
  every project change and canvas switch) with layers and slices on a canvas
  that does not render yet (switch deferred in show mode, or failed) mapped to
  canvas 1. A failed switch also moves what used the missing canvas to canvas 1
  in the project. `Compositor.layerCanvas` is a mutex-guarded swap read once per
  tick. Previews are never rebuilt on Control (they read the project). A canvas
  with no layers is cleared three times (all textures) and then skipped.
  Secondary displays read one tick's canvases per present.
- Output pass: each slice samples its own canvas (`SlicePlan.canvas`); Freeze
  holds a copy per canvas a plan uses and the Master they were drawn with
  (§9.5). A slice whose canvas does not render is skipped (black) and the
  coordinator logs it once per change.
- Preview: `canvas:<id>` targets ("canvas" = "canvas:1"), sized to their canvas;
  `layer:<n>` is made at its layer's canvas aspect and rebuilt when the layer
  changes canvas; output previews sample every canvas of the tick.
- Not built: Syphon for canvases other than canvas 1, a CITP stream of a canvas
  other than canvas 1 (layers on any canvas stream since B29), a rate per canvas.

### 9.6 Display identity, modes, hot-plug

- Outputs bind to a display by `CGDisplayCreateUUIDFromDisplayID` + EDID
  vendor/product/serial. On a new machine (or a replaced projector) unbound
  outputs are listed with a "assign to display…" action.
- In show mode the engine applies the output's desired mode
  (`CGDisplaySetDisplayMode` in a `CGBeginDisplayConfiguration` transaction)
  and restores it on exit. Outside show mode it uses the current mode and
  warns if it differs.
- Hot-unplug: output marked red, window torn down, other outputs unaffected.
  Re-plug: re-bound by identity, mode re-applied, window recreated; the event
  is logged with timestamps for the post-show report.
- The internal display is an ordinary display; using it as an output shows a
  yellow note in the Outputs screen ("the local UI shell will be hidden").

### 9.7 Test patterns

Grid (with pixel-pitch labels), colour bars (SMPTE-style + full-field
R/G/B/W/black), blend-zone visualization (each edge's zone tinted, factor
curve drawn), output ID (big number + name + resolution + refresh), crosshair
with concentric circles for lens centring, grey steps (for black-lift
matching), checkerboard (pixel-exact). Selectable per output and globally
(Master fixture / UI), and usable as layer content (§8.2).

Patterns go through the output's intensity chain like the content (fixed
2026-10-29): output intensity × Output fixture intensity × Master intensity, 0
at an Output or Master Blackout, Raw included, so a console's Grand Master or
DBO takes them down. Freeze holds the canvases, not the pattern: a pattern
draws live over a frozen output and the held frame returns when it is off.

### 9.8 Syphon

**As built (2026-10-26, Syphon orientation):** Syphon surfaces hold the picture in OpenGL order (row 0 at the bottom). `SyphonOutput` publishes the canvas with `flipped: true` so OpenGL clients (checked with the Syphon Simple Client) and Metal clients that follow Syphon's GL-order convention see it upright; `SyphonInput` reports it via `LiveFrame.bottomUp`, and the compositor samples such frames with v0/v1 swapped (`Compositor.uvRect`), so crops keep their meaning. Before this the own round trip looked right while every other app saw the canvas upside down.

`SyphonMetalServer` per canvas, named `Fanous – <canvas name>`, published
from the compositor after the canvas pass with the same completed texture
(no copy; Syphon shares the IOSurface). Per-output Syphon (post-warp) later.

**As built (2026-10-28, B69):** Syphon input numbers (§8.2, folder 0 files
150–169) are kept in the project and survive an engine restart; the engine's
own canvas servers are never numbered.

### 9.9 Projector walls and the M1 mapping tools (design 2026-10-28, `docs/mapping-ux.md`)

**Status:** approved 2026-10-28; M1 complete: steps 1, 3, 4, 5 in PRs #55,
#47, #54, #59, step 2 in PR #63, step 7 in PR #92, step 6 in PR #97 (as built
below). M2 is designed in §9.10.

**Scope:** M1 is the first block. M2 and M3 are listed at the end of this
section.

**Projector wall.** A wizard creates a wall, and the project keeps it. The
wall separates two kinds of work (owner, 2026-10-28: no default blend ever
fits; projector age, ambient light and the surface always need tuning by eye):

| Kind of work | What it covers | Who does it |
|---|---|---|
| **Geometry** | Which part of the canvas each projector shows, and the overlap in pixels, equal on both sides of a seam | The wall computes it from the grid and the overlap %. Always correct for a rig hung as that grid. |
| **Tuning** | Gamma and curve per seam; black floor and colour per projector | Always set by eye. Start values are only a starting point; the seam check (below) is the route. |

```
WallConfig { id, name, canvas: Int, rect: MapRect (on the canvas, default full),
             cols, rows (1…4 each; cols × rows ≥ 2),
             outputs: [Int]  (row-major, cols × rows, an output belongs to at most one wall),
             overlap: { x, y }  (fraction of one projector's width / height, 0…0.5),
             seams: [SeamConfig],          // one per neighbouring pair, made by the wizard
             manual: [{ output, field }] } // geometry only: "source" | "overlap.left|right|top|bottom"
SeamConfig { a, b (output ids; b is right of or below a), power, gamma, gammaRGB: [r, g, b]? }
```

- **Per projector:** the black floor is the output's existing `blend.lift`,
  and the colour is `OutputConfig.color` (below). The wizard sets start
  values; the wall never overwrites them afterwards.
- **Compile** (Core, `WallLayout.apply`, pure and tested):
  - Each projector's share of the wall is
    `p = 1 / (cols − (cols − 1) · overlap.x)` (the same for rows).
  - Output (c, r) gets slice 1's source rectangle:
    `x = rect.x + rect.w · c · p · (1 − overlap.x)` and `w = rect.w · p`.
  - Inner edges get `overlap.x × output width` in px. Outer edges get 0.
  - Each seam's power, gamma and gammaRGB go to both facing edges, so the two
    sides of a seam never disagree.
  - Geometry fields listed in `manual`, and slices other than slice 1, are
    left alone.
  - The output's pixel size comes from its region, else its desired mode, else
    the bound display's current mode.
  - A wall whose outputs differ in pixel size is refused with a message (v1).
- **Commands.** All are programmer-only, refused under show lock, and one undo
  step each:
  - `wall.add {cols, rows, outputs, overlap, canvas?, fit}` makes the seams
    with start values power 2 and gamma 2.2.
    - `fit: "canvas"` uses the whole canvas.
    - `fit: "makeCanvas"` first sets the canvas to
      `cols · w − (cols − 1) · overlap.x · w` (and likewise in height),
      rounded to even, within the `canvas.set` limits and refused in show mode
      like `canvas.set`.
  - `wall.set {id, …}` changes geometry and re-compiles; `resetManual: true`
    empties `manual`.
  - `wall.seam {id, a, b, power?, gamma?, gammaRGB?}` tunes one seam.
    `wall.seams {id, …}` applies the same values to every seam of the wall.
  - `wall.remove {id}` leaves the outputs as they are.
  - `output.set` on a wall output:
    - A change to slice 1's source or an inner edge's overlap adds that field
      to `manual`; the reply says so.
    - A change to an inner edge's power or gamma updates that seam, so both
      sides follow.
    - Removing a wall output is refused while it belongs to a wall.
- **UI, wizard.** **New projector wall** on the Outputs tab.
  1. Every bound output shows its Output ID. The user taps the tiles in the
     order the projectors hang and picks a grid of 1×2 … 4×4 that matches the
     count.
  2. Overlap is a slider in %: default 15, yellow below 10 or above 25. Then
     choose: use canvas N, or make a canvas that fits.
  3. Apply. Blend check and Grid appear on every wall output, and the wall
     panel opens on the seam check.
- **UI, wall panel** (above the output list), built around a **mini-map of
  the wall**: one tile per projector, with the seams drawn as lines between
  them.
  - **Tap a seam:** gamma (RGB linked; unlink for per-channel), curve, and
    **Apply to all seams**.
  - **Tap a projector:** black floor, colour gain R/G/B, black offset.
  - **Geometry:** overlap X/Y, Edit layout… (re-opens the wizard pre-filled),
    Remove wall.
  - **Badges:** a wall output carries a "Wall 1 · r1 c2" badge. A manual
    geometry field shows a "manual" chip with **Back to wall**.

**Seam check: the tuning route.**
- New bands on test-pattern channel 4 (Master and Output) in the reserved
  range: 128–143 Grey 0 %, 144–159 Grey 25 %, 160–175 Grey 75 %, 176–191
  White. Blend check is the 50 % field.
- The footprint stays the same; the GDTF and `docs/channel-map.md` are
  regenerated.
- The wall panel steps through the patterns on every wall output. At each step
  a card says what to look for and which control to turn:

  | Step | You see | Turn |
  |---|---|---|
  | Grid | lines that do not meet across a seam | the warp, not the blend (opens Warp & Slices) |
  | Blend check (50 %) | a bright band in a seam | that seam's gamma, down |
  | | a dark band | that seam's gamma, up |
  | | a visible edge at the start of the overlap | that seam's curve |
  | Grey 0 % | seams lighter than the rest | black floor of the projectors next to it, up, one by one until even |
  | Grey 25 / 75 %, White | one projector darker, or tinted | that projector's colour gain |
  | | a colour shift only inside a seam | unlink RGB on that seam and tune the channel that is off |

- The user taps the seam or projector on the mini-map; the card's control
  opens for it. Without a camera, Fanous cannot know which seam is off, so the
  user's eye picks it. The M3 camera can measure it later; a final pass by eye
  stays.

**As built (M1.2, PR #63):**
- The wizard has two screens; Make wall is step 3 and opens the seam check on
  Blend check (the 50 % field carries each output's grid lines, so it is
  "Blend check and Grid" in one pattern).
- Only bound free outputs show their Output ID; unassigned ones are tiles
  without a pattern.
- Make wall sets the patterns before `wall.add`, so one Undo takes the wall
  back.
- The wall panel sits on the Outputs tab, full width above the output list and
  preview. Leaving the Outputs screen ends the wizard and the seam check.
- Every pattern the wizard or the check sets is an `output.set` (one undo step
  per output, B102). Each output's own pattern is kept until the engine has
  taken it back, also in sessionStorage, so a reloaded page offers to give it
  back.
- Unlinked RGB kept the single gamma ("in effect"), with R, G, B below it,
  until M1.6 (below); linking again drops them.
- The colour hints said colour gain was not built yet, and the projector tile
  had the black floor only (0–20 %), until M1.7 (below). Geometry sliders send
  on release (`wall.set` has no coalesce key); seam and floor sliders send at
  most every 50 ms.

**RGB gamma (OPEN-14).**
- `BlendEdge.gammaRGB: [Double]?`; nil means `gamma` for all three channels.
- The blend map becomes `rgba16Float`: factor R, G, B, plus the lift.
- The output fragment shader multiplies each channel by its own factor.

**As built (M1.6, PR #97):**
- `BlendMath.map` gives four floats per pixel: factor R, G, B and the lift
  term. `BlendMath.factor(_:edge:channel:)` takes that channel's gamma from
  `gammaRGB`; nil, or a `gammaRGB` that is not three values (project files are
  not clamped on load), means `gamma`. A corner multiplies the two axes per
  channel.
- The output pass multiplies content and test patterns alike by the map's
  `rgb` and takes its `a` as the lift; raw or without a map it is
  `(1, 1, 1, 0)`. Without `gammaRGB` the three factors equal the single
  factor, so a project without RGB gamma renders as before (the golden images
  are unchanged).
- The blend map costs 8 bytes per pixel, was 4: ≈ 66 MB per 3840×2160 output
  with a blend, was 33 MB. An output without a blend has no map.
- UI: unlinked, the seam's Gamma R, G and B sliders replace its single Gamma
  slider (a seam-check gamma hint highlights them); linking again drops them.
  The wall map labels such a seam "RGB" (its title and label give the three
  values). On the Outputs tab an edge with `gammaRGB` shows the three values in
  place of its Gamma field, with **One gamma for R, G, B** (`output.set
  …/gammaRGB null`, which a wall's inner edge passes on to its seam). **Apply
  to all seams** copies the seam's R, G and B, or clears them on every seam
  when the seam is linked.

**Per-output colour.**
- `OutputConfig.color {gain: [r, g, b] (0…2, default 1), black (0…0.2,
  default 0)}`.
- The output pass applies `out · gain + black` next to the lift. That is still
  before the output and master intensity, so blackout stays black.
- It is set on the Outputs tab next to the Colour bars and Grey steps buttons,
  and for a wall output from the wall panel's projector tile.

**As built (M1.7, PR #92):**
- `OutputConfig.color` decodes as the default when absent, so older projects
  load unchanged; `output.set` clamps gain to 0…2 per channel and black to
  0…0.2, and refuses a gain that is not three values.
- Output pass, on the un-premultiplied colour `c` of content and test patterns
  alike, with γ fixed at 2.2 (the edges' default; a per-output gamma only if a
  projector measurably differs):
  ```
  c = sample × scale × blend factor × gain
  c = (max(c, 0)^γ + lift^γ + black^γ)^(1/γ)       // the lift and the black offset add light
  out = c × slice alpha × intensity + dither          // dither on content only
  ```
  The black lift and the black offset are stored as the code value they give
  on black, so Grey 0 % reads them exactly as before and projects tuned on it
  keep their look; at a mid grey they now add only the light they give (a lift
  of 0.08 on 25 % grey: 64 → 66, where it was 64 → 84). Without a lift or black
  offset the pass skips the powers and is unchanged. The black offset is a
  uniform: it applies also without a blend map.
- Raw (Output Blend channel 128+) bypasses blend factor, lift, warp and mask,
  but keeps the gain and the black offset: they describe the projector, not
  the mapping, like the output's intensity, so switching raw on for alignment
  does not change its colour.
- `MappedUniforms` carries `float4 color` (gain r, g, b; black); outputs,
  output previews and secondary displays all draw through `OutputPass.draw`.
- UI: gain R, G, B (0–200 %) and black offset (0–20 %) sliders under the test
  pattern buttons on the Outputs tab, and on the wall panel's projector tile
  under the black floor (`OutputColour.svelte`). They send at most every 50 ms;
  `output.set` merges a drag on one value into one undo step. The seam check's
  "One projector darker, or tinted" hint on Grey 25/75 % and White opens the
  tapped projector's colour.
- The lift and the black offset reach only the pixels a slice covers (as the
  lift did before); an output whose slices leave part of the raster empty has
  true black there.

**Mesh resample.**
- A density change samples the current surface (`warp.ts meshPoint`) at the
  new grid's points.
- **Reset mesh** still flattens.
- This change is UI only.

**iPad remote mode** (UI only).
- **Turning it on:** a **Remote** toggle on Warp & Slices, on by default on
  touch screens narrower than 900 CSS px.
- **Point selection:**
  - previous / next point (row-major, wraps)
  - select row, select column, select edge (every point on one border side)
  - the selected points move together
- **Nudge steps:** fine 1 px, coarse 10 px, and a long press for 0.25 px.
- **Trackpad area:** a relative drag at 1 output px per 4 CSS px, ×4 above
  600 px/s.
- **Label:** the point label in large type ("r3 c5").
- **Point types:** corner pin, mesh, slice and mask points.
- **Undo:** each nudge is an `output.set`; the existing 1 s undo window merges
  a burst into one step.

**M1 build order** (one PR each, Opus coding agents, review before merge):
1. Wall model, compile and commands (Core and engine)
2. Wizard and wall panel (UI)
3. Mesh resample
4. iPad remote mode
5. Seam-check patterns
6. RGB gamma
7. Per-output colour

**Decided for later blocks** (designed when their block starts):
- **M2:** designed in §9.10 (2026-10-29).
- **M3:**
  - camera calibration, with an iPhone as the camera: Continuity Camera on
    the Mac first, then the iPad/iPhone browser camera once a trusted
    certificate exists (OPEN-17); both feed the same Mac-side solver
  - MPCDI 2D import

---

### 9.10 M2: black lift by coverage, Keystone, mapping presets, edit overlay, masks v2 (design 2026-10-29)

**Status:** designed 2026-10-29, owner decisions the same day (below), and
reviewed against the code. Built: the compile cache of item 0 (M2.2), item 1 (M2.1), the Keystone mode of item 2 (M2.3) and the presets of item 3 without the morph (M2.4), below. Research and frictions F3–F6 are in
`docs/mapping-ux.md` §1 and §4.2–§4.5.

**Owner decisions (2026-10-29):**
- A console preset change **morphs** over Output channel 7 (Mapping fade). Not
  a cut, and not a dissolve, which would show a double picture.
- The edit overlay is **on while Warp & Slices is open**, with a visible
  **Show on output** switch.
- Masks v2 **includes freehand** drawing.
- **Round and triangular slices are presets, not a slice type** (2026-10-30):
  a slice stays four corners, and a circle is a quad with an ellipse mask
  (item 5, Slice shapes).
- Settled in the design, not asked:
  - the Keystone range (±50 % of the output);
  - presets hold the mapping (warp and slices). Blend, colour and black floor
    are per-projector tuning (§9.9 owner decision) and stay live.

**0. Output plans and the compile cache (groundwork).**
- **Compile cache.** Today `OutputCoordinator.rebind` recompiles every output
  on every output edit, on the main actor, and the preview compiles again at
  its own size. Presets and freehand masks would make that cost grow with every
  drag.
  - `OutputCompiler` keeps a content-keyed cache that survives rebinds. Each
    of these gives a texture or buffer:
    - (warp, w, h) → warp field;
    - (slice with its masks, w, h) → mesh and mask texture;
    - (blend, w, h) → blend map.
  - Entries nobody references are evicted after a swap.
  - A changed region, display mode or drawable size simply gives new keys.
  - A changed image-mask file invalidates the entries that use it; the library
    triggers this.
- **One plan per output** keeps the edited mapping and its presets' geometry
  (`presets: [Int: PresetGeometry]`). Freeze's `held` stays on the plan.
- **Per-frame state stays out of the plan.**
  - The morph (3) lives on the DMX queue and travels in `OutputParameters`.
  - The overlay (4) lives in a per-output box. The coordinator owns the box and
    hands it to every plan it compiles.
  - So a recompile mid-morph or mid-freeze changes nothing on screen.
  - The projector, a secondary display and the preview all draw the same
    frame.

**As built (M2.2, PR #105):**
- `OutputCompiler` (now a class) caches by content: (blend, w, h) → blend
  map, (warp, field cols, rows) → warp field, (mask, w, h) → mask texture.
  The model types in the keys are `Hashable`, synthesized.
- **A mask is keyed by itself**, not by its slice: moving a slice keeps its
  raster.
- **Slice meshes are not cached.** An output whose textures all hit compiles
  in 0.14 ms at 1080p, meshes and buffers included.
- **Eviction is ARC.** The cache holds its textures weakly, so a texture
  lives exactly as long as a plan holds it:
  - every display's set;
  - the replaced set a frozen output still takes its hold from
    (`OutputSet.previous`, B111);
  - a preview's set.

  Nothing in use can be freed, and a texture no plan holds goes with the set
  swapped out. Its dead entry is dropped at the next compile.
- **Threads.** The coordinator compiles on the main actor with its own
  compiler. The output previews share one long-lived compiler (the engine's
  `preview.configure`); `applyCanvasUse` no longer makes one per call.
  - Preview compiles come from the main actor, a network thread (`sub`) and
    a utility queue (rebalance), so the cache is behind a `Mutex`.
  - The lock is held for the lookup and the insert, not over a build. Two
    threads missing one key both build it (a `ponytail:`).
  - The render thread never touches the cache.
- **Measured** (`compileCacheBench`, `FANOUS_BENCH=1`, release, CPU time per
  rebind, median of 20 overlap edits on one output): a 2 × 2 wall of
  1920×1080 outputs blended on both axes, on one 3840×2160 drawable, compiles
  in 51.4 ms before and 13.3 ms after (the edited output's blend map).
- **Not built here:** the image-mask invalidation (image masks come with
  item 5), the presets on the plan (3) and the overlay box (4).

**1. Black lift by coverage (fixes F3).**
- **Before M2.1** the lift was binary per edge: full outside every overlap, none
  inside. In a wall of 2 × 2 or larger, the point where four projectors overlap
  stayed lighter in black than the two-projector seams.
- **Coverage, no new field.** `BlendMath.map` takes the coverage from the
  output's own edges: 4 when it has an overlap on both axes. A one-axis output
  keeps today's per-edge lift.
  - Every output of a grid wall with overlap on both axes has edges on both
    axes, so all of them agree.
  - A wall with overlap 0 on one axis, or a removed wall, follows its edges.
- **The lift term** for coverage 4:
  - The pixel's coverage is n = (1 + zx) · (1 + zy). zx and zy are each axis's
    "in an overlap" value: 1 inside, falling linearly to 0 over the lift
    feather. Away from the feathers n is 1, 2 or 4.
  - The formula:
    ```
    lift light = (4 − n) / n × floor light        // each covering projector adds its share
    lift term  = floor × ((4 − n) / n)^(1/γ)      // as a code value: the output pass adds it in linear light
    ```
  - Every point then reaches the black of the four-projector point.
  - γ is `BlendMath.projectorGamma` (2.2), one constant in Core that the
    shader source uses too.
- **The floor** (`blend.lift`) stays the black light of one projector.
  - A one-axis wall uses it as today.
  - On a 2 × 2 wall a single-covered point gets 3 floors, a two-projector seam
    1, and the four-projector point 0.
  - The Grey 0 % route is unchanged: raise the floor per projector until even.
- **Existing 2D blends change, on purpose.** Their black rises to the level of
  the four-projector point, so re-check Grey 0 %. One-axis outputs render
  bit-identically. The output pass is unchanged.

**As built (M2.1, PR #103):**
- `BlendMath.map` takes coverage 4 when the output has an overlap on both
  axes (left or right > 0, and top or bottom > 0). zx and zy are the per-axis
  "in an overlap" values it already computed for the lift feather; the lift
  term is `lift × ((4 − n) / n)^(1/γ)`. Otherwise it is `lift × (1 − max(zx,
  zy))` as before, the same floats: the golden images are unchanged (none has
  overlaps on both axes).
- `BlendMath.projectorGamma` (2.2) is the one constant; the shader source
  interpolates it (as a `Float`, so the Metal literal reads `2.2`).
- Rendered on Grey 0 % with a lift of 0.08, left and top overlaps: one
  projector reads 0.08 × 3^(1/2.2) ≈ 34 of 255, the left overlap 20, the
  corner 0.
- As designed, coverage counts at most two projectors per axis: a pixel that
  three projectors on one axis light still counts as two (a `ponytail:` in
  `BlendMath.map`).

**2. Keystone mode (§6.4a).**
- **The mode.** A fourth fixture mode, 16 channels, patched per output next to
  its Output fixture. It is `FixtureRef.keystone(n)`, and the mode follows
  from the ref, like the others.
  - Four corners × X/Y, 16-bit; centre means no change.
  - Full range is ±50 % of the output's width or height, about 0.03 px per
    step at 1920.
- **Per frame, on the DMX queue.** When the values change they become one
  3 × 3 homography, from the output's unit square to the moved corners.
  - It goes in a separate `keystones` array of the snapshot slot. The Output
    fixture's resolver builds `OutputParameters` fresh on each publish and
    would wipe it.
  - **Guard.** The matrix is accepted only when the moved quad is strictly
    convex (the four corner cross products have one sign) and w > 0 at the
    corners. Otherwise the last valid matrix stays, and `live.outputs` says
    "keystone invalid". A crossed quad would turn the picture inside out.
  - It is the identity while the fixture is unpatched or centred.
- **Where it applies.** The vertex shader applies it after the warp field, to
  every slice, test pattern and the edit overlay. The whole mapping moves; the
  hand alignment stays as edited.
  - The blend map stays in projector space: it is sampled at the final
    position.
  - Masks move with their slices, because they are sampled before the warp.
  - Raw (Output ch 5 ≥ 128) bypasses the keystone together with the warp.
- **Mapping shown.** It sits on top of whatever mapping the output shows: the
  edited one or a preset (3).
- **Generated files.** OSC addresses, `docs/channel-map.md` and the GDTF follow
  from the parameter specs, like the other modes.
- **Use.** Moving scenery (B53) and quick fixes from FOH.

**As built (M2.3, PR #108):**
- **The mode.** `FixtureMode.keystone` (16 channels) with `KeystoneParameter` in the §6.4a order, eight 16-bit offsets
  on one curve (0 → −50 %, 32768 → 0, 65535 → +50 %), default 32768. No reserved channels: `ChannelMap.reserved(for:)`
  is nil for it, and the channel map, GDTF and the existing modes' tests go through that one lookup.
  - `FixtureRef.keystone(n)`, named and parsed as "Keystone n"; `patch.set` takes it like any fixture. The standard
    patch does not include it: a console patches it per output when it wants one.
  - OSC `/fanous/keystone/{n}/{key}`, feedback included. GDTF: a fourth DMX mode "Keystone (16ch)" with attributes
    `KeystoneTopLeftX` … `KeystoneBottomLeftY` (feature `Position.Keystone`).
  - The three existing modes and their footprints are unchanged. Output ch 6 and 7 (Mapping preset and fade) are not in
    the specs yet; they stay reserved until M2.4 and M2.5 (ch 6 since M2.4).
- **DMX queue.** `DMXStore.publish` reads each output's Keystone resolver (outputs 1–8, like `outputs`). Only when its
  raw values change, `WarpMath.keystone(raw:)` gives the homography, stored as a `simd_float3x3` in the slot's
  `keystones`, with `keystoneInvalid` beside it; both copy with the slot. Unpatched is the identity, centred values give
  it exactly.
  - **Guard** (`WarpMath.keystone(to:)`): all four corner cross products above 1e-12 or all below −1e-12, and
    w > 0 at the corners. A refused quad keeps the last valid matrix and sets `keystoneInvalid`.
  - Within ±50 % two edges cannot cross (opposite edges only touch at 50 %), so on stage a refusal is a concave or
    degenerate quad (a corner pulled onto or past a diagonal). The test feeds the guard a bow-tie directly.
- **Render.** `MappedUniforms.keystone` (a `float3x3` after `color`; the uniforms are 96 bytes of their 256).
  - `mapped_vertex`: k = H · (p, 1) after the warp, and the clip position is homogeneous, (2k.x − k.z, k.z − 2k.y, 0,
    k.z). The rasteriser divides, so `uv` and `pre` (masks, patterns) interpolate perspective-correct across a
    keystoned triangle.
  - `post` is k.xy / k.z, interpolated `[[center_no_perspective]]` (linear on screen, as the pixel position is), so
    the blend map is sampled at the final position and stays in projector space.
  - `OutputPass.draw` takes `keystones` by output index like `outputs`. Raw passes the identity. The clock-master
    display passes the tick's slot, a secondary display copies them in `withLatest` beside `outputs`, and the output
    preview passes none: it shows the edited mapping.
  - With the identity the vertex output is the same floats as before; the golden images are unchanged.
  - **Clip before the keystone** (review): `mapped_vertex` writes four `[[clip_distance]]` values, p.x, 1 − p.x, p.y,
    1 − p.y, in a vertex-only output struct (a fragment's `stage_in` may not carry them). They are linear in clip space
    (p = H⁻¹·k), so the clip is exact: a bleed the mapping puts outside the output stays outside when the keystone
    shrinks the picture, and nothing beyond the vanishing line is drawn.
- **DMX loss** (review). Hold "zero" feeds a Keystone fixture its defaults (32768), not raw 0: zero for a geometry
  offset is no offset, so a keystone universe that drops alone does not move a lit picture half an output.
- **Status.** `publishLive` copies the eight matrices and flags from the DMX side (`withLatest`, storage reserved
  first) and adds `keystone` (not the identity, and not in Raw, which bypasses it) and `keystoneInvalid` to each
  `live.outputs` entry. The live document
  is diffed, so they go out only when they change.
- **UI.** "Keystone active" and, in yellow, "Keystone invalid" on the output row and under the preview on Warp &
  Slices. The Patch screen lists "Keystone n" after each "Output n" it lists; the cue editor lists patched Keystone
  fixtures after the outputs.
- **Not built here:** the edit overlay (item 4) and the preset geometry (item 3), which the keystone will sit on top
  of. The Layers screen does not offer the Keystone fixture.

**3. Mapping presets (Output ch 6 and 7).**
- **Model.**
  ```
  OutputConfig.presets: [MappingPreset]
  MappingPreset { number: 1…255, name, warp, slices }
  ```
  - A preset is a snapshot of what Warp & Slices edits, masks included.
  - It holds no blend, black floor, colour, intensity, region or display: those
    are the projector's tuning and stay live.
  - A custom `encode(to:)` writes the field only when it is not empty, so older
    projects load unchanged.
  - `output.set` refuses paths under `/presets`.
  - A later wall change does not touch stored presets; store again after one.
- **Commands.** All are programmer-only, refused under show lock, and one undo
  step each:
  - `output.preset.store {ids, number, name?}` snapshots each output in `ids`.
    For a wall the UI sends all its outputs at once. An existing number is
    replaced, and the reply says so.
  - `output.preset.recall {ids, number}` copies the preset into the edited
    mapping. That is an edit, and Undo takes it back. On a wall output a slice
    1 source that differs from the wall's becomes manual, as with `output.set`.
  - `output.preset.remove {ids, number}` and
    `output.preset.rename {ids, number, name}`.
- **UI.**
  - A **Presets** strip on Warp & Slices, and on the wall panel for the whole
    wall: **Store as N**, **Recall**, **Rename**, **Remove**.
  - **Hold Compare** shows the preset on the output while held, through the
    lease `output.show {ids, preset}` (4, "Leases").
  - While held it wins over ch 6.
  - Like the overlay lease, it is refused under show lock.
- **Console.**
  - Output ch 6 = N shows preset N on that output for as long as the channel
    holds it; 0 shows the edited mapping again.
  - Nothing in the project changes.
  - A number the output does not have keeps the current mapping.
  - `live.outputs` gets the shown preset, "preset N missing" and the morph.
    `publishLive` fills them from the snapshot; today `live.outputs` is built
    only on rebind.
- **Preview and editor.**
  - The output's preview and the Warp & Slices editor show the edited mapping,
    without preset or keystone, so the handles stay where the drag lands.
  - Badges say what the output shows instead: "Preset N (console)" and
    "Keystone active".
  - Freeze still shows in the preview (B107).
- **Compile.** Presets go through the cache (0), so storing or loading compiles
  a preset once, and a recall never waits.
  - A preset costs its warp field (about 4 MB at 4K) plus its masked slices'
    mask textures (about 8 MB each at 4K).
  - The blend map is the output's own, shared by every preset.
- **Morph (owner decision).** Output ch 7, **Mapping fade**: 0 = cut,
  1–255 = 0.1–25.5 s, the Layer Dissolve mapping.
  - **State.** When ch 6 changes, the DMX queue (`DMXStore.publish`, the
    single writer) records `from`, `to`, the start (host time) and the fade.
    `OutputParameters` carries them.
  - **Each frame**, every drawer computes s = smoothstep((now − start) / fade)
    and draws both geometries in one pass. Nothing per output is kept between
    frames.
  - **Shader.** The vertex shader gets each side's vertex buffer and warp
    field, with a "has warp field" flag per side (an identity warp has no
    field).
    - It mixes the two final positions by s, so the warp, the slice corners,
      the source rectangle (UV) and the slice opacity glide.
    - `pre`, the coordinate the masks and patterns use, is the new side's
      vertex, so the new masks ride with the gliding slice.
  - **Switched at the start:** the masks and the slices that exist on one side
    only. A slice whose canvas differs counts as one-sided.
  - **Topology.** Every slice mesh has the same tessellation
    (`sliceSubdivisions`), and both warp fields have the output's size. Vertex
    i is the same point in both, even across mesh densities.
  - `ponytail:` a change during a morph finishes the running morph at once
    and morphs on from its target. That is a visible jump; a third side in the
    mix would avoid it.
  - Recall and Compare from the UI cut.
  - Keystone applies on top.

**As built (M2.4, PR #123):**
- **Model.** `OutputConfig.presets: [MappingPreset]`, kept in number order. `encode(to:)` is written out (with its
  `CodingKeys`) and writes `presets` only when there are any: an output without presets encodes byte for byte as before,
  which a Core test checks against that release's literal. `storePreset` and `recallPreset` are pure, in Core.
  - A replaced number keeps its name unless one is given; a new one is "Preset N". Names are trimmed, 1–64 characters.
  - `canvas.remove` moves preset slices on the removed canvas to canvas 1 as well, and a canvas that does not render
    maps them to canvas 1 like the edited slices (`Engine.effectiveCanvasUse`): a preset never samples a canvas that is gone.
  - **A hand-edited or foreign file** (review): `ProjectDocument.load` (also for a version revert) keeps the presets
    numbered 1–255 and the first of a repeated number, next to the other backfills, so the UI offers the list the engine
    draws from. A preset that does not validate as an edited mapping would (`ProjectDocument.validated`, the rules of
    `output.set`) stays in the file: the compile skips it (logged once per output and number) and never fails the
    output, `live.outputs` calls it missing, and recall refuses it.
- **Commands** (`ProjectDocument+Presets.swift`). `ids` lists existing outputs, none twice; recall, remove and rename are
  all or nothing (every output must have the number). Replies: store `{ replaced: ids }`, recall
  `{ manual: [{ wall, output, field }] }` from `WallLayout.follow`, the same code path as `output.set`; recall then runs
  `validate` as `output.set` does. `output.set` refuses `/presets…`.
- **Output ch 6.** `OutputParameter.preset`, `.index(max: 255)` in group Mapping, so it snaps (LTP, no fade). Reserved is
  7–8; GDTF attribute `MappingPreset`; OSC `/fanous/output/{n}/preset`. The generated channel map says
  "0 = as edited · 1–255": `ChannelMapDocument` gives this index its own zero wording (folder and file keep "0 = none").
- **DMX queue.** The slot carries `presets: [UInt8]` and `presetCompare: [Bool]` beside `keystones`, written for outputs
  1–8 on every publish (the Output fixture's resolver rebuilds `outputs` and would wipe a lease): the lease's preset while
  it runs, else the Output fixture's ch 6 (0 while unpatched). Both copy with the slot.
- **Compare lease.** `DMXStore.show(ids, preset, at:)`: one per output, the latest call wins, ending `showLease` (5 s)
  after it. A renewal only moves the end (no publish); preset 0 ends it; the 0.5 s tick clears an expired lease and
  publishes, so a lease ends 5–5.5 s after its last renewal and the output goes back to ch 6. Show mode
  (`ShowModeController.onChange`) and show lock (`projectChanged`) end every lease at once; `output.show` is refused in
  show mode except to end, and reaches outputs 1–8 only (the snapshot's slots, a `ponytail:`).
- **Render.** `OutputPlan.presets: [Int: PresetGeometry]` (warp field and slices), compiled through the same cache keys
  as the edited mapping, so a preset equal to it shares its textures and slice plans.
  - **Slice plans are cached** now (review): `Key.slice(SliceConfig, w, h)` gives the mesh buffers with the mask texture
    (the mask keeps its own key, so a moved slice keeps its raster), held weakly like the textures, and the pattern mesh
    is one too. A rebind (each drag step) builds only the slices that changed, instead of every preset × slice mesh.
  - Each frame `OutputPass.draw(presets:)` takes
  `plan.geometry(n)`: a dictionary lookup and a struct of references, no allocation; 0 or a number the plan lacks gives
  the edited mapping. The blend map, colour, region, intensity and pattern mesh are the plan's; test patterns follow the
  preset's warp; the keystone applies after it. The clock-master display passes the tick's slot, a secondary display
  copies `presets` in `withLatest` beside `outputs` and `keystones`, the output preview passes none, and the engine's
  preview compile drops the presets (nothing to build for it).
  - A secondary display copies into `PresentParameters` its driver owns, arrays of a fixed size (review): no
    allocation per frame for the copy, checked by `mallocCounterSecondaryCopyAllocatesNothing` in
    `scripts/check-mallocs.sh`. Before, each frame reserved new arrays.
  - Raw bypasses the preset's warp and masks like the edited ones; its slices still draw, as edited slices do in Raw.
- **Freeze.** `OutputPlan.canvases` is every canvas the edited mapping or a preset samples. `holdFrozen` holds those and
  `adopt` (B111) checks those, and `held` stays on the plan, so a ch 6 change while frozen draws the held frame through
  the new geometry, and a recompile keeps the hold.
- **Status.** `publishLive` reads `presets` and `presetCompare` from the DMX side's copy and the output's preset numbers
  from the project as last seen (`canvasUse`), and adds `preset` (the number shown, or null), `presetSource` (`console`
  or `compare`) and `presetMissing` (a number the output lacks) to each `live.outputs` entry; the live document is diffed.
- **UI.** `PresetStrip` on Warp & Slices (`ids` = the output) and on the wall panel (`ids` = the wall's outputs, the
  presets they all have): Preset, Name (renames on change), Recall, Hold to compare, Remove, and Store as N (the lowest
  free number, "Replace N" when taken). Compare: pointer down or Space/Enter starts the lease and renews it every 2 s
  (`compareLease`). The button captures the pointer, so the page moving under it does not end the hold; pointer up,
  pointer cancel, lost capture, key up or blur ends it with preset 0 (not sent under show lock, which ends the lease in
  the engine). Badges "Preset N (console)" / "Preset N (compare)" and, in yellow, "Preset N missing" on the output row
  and under the preview, and a note there while the output shows a preset; the space for both is kept, so the page does
  not jump when they appear. A wall recall's toast names the outputs it made manual.
- **Not built here:** the morph on ch 7 (M2.5) and the edit overlay with its lease (M2.6). `scripts/check-mallocs.sh`
  measures the compositor tick without an output pass (its render encoder allocates in Metal), so the per-frame preset
  choice is kept allocation-free by construction, not by that check.

**4. On-output edit overlay (fixes F4).**
- **What it draws.** While a programmer has Warp & Slices open on an output,
  the engine draws these on that output:
  - the warp: the corner pin's edges, or the mesh's grid lines sampled at the
    slice tessellation (64 per line);
  - each slice's outline and its mask outlines, curves flattened;
  - the selected point as a crosshair, with a digits-only label ("3·5", or the
    point number). The iPad's large label names the kind.
  - The line buffer is sized by content and capped.
- **Not drawn:**
  - on previews, which show the editor's own handles;
  - in raw, where the warp is bypassed;
  - while the output shows a preset (console or Compare), because the lines
    belong to the edited mapping. The badge says why.
- **Look.**
  - Lines are 2 px white with a 1 px black edge, visible on any content. Metal
    has no wide lines, so each segment becomes a quad, extruded in pixels after
    the warp and the keystone.
  - The selected point is yellow and larger.
  - The overlay follows the output's Blackout and the Master, so black stays
    black. It takes no blend, colour or lift.
- **Leases.** `output.overlay {id, on, selected?}` and
  `output.show {ids, preset}` (3) are leases.
  - Programmer-only, refused under show lock, never saved or undone.
  - Each lasts 5 s. The UI renews it every 2 s while the tab is open or
    Compare is held, and the engine lets it expire, so no client tracking is
    needed. An iPad that sleeps lets it run out; its next renewal brings it
    back.
  - The most recent renewal decides what is shown (its selection).
  - The overlay is **on** when the tab opens (owner decision), with a **Show on
    output** switch that stays visible.
  - The UI stops renewing after 10 minutes without an edit.
  - Show mode and show lock end both at once.
  - `selected` is `{slice, kind: corner | mesh | slice | mask, mask?, point}`.
- **Implementation.**
  - Control builds the line quads from the edited mapping and the selection
    into the output's overlay box (0).
  - The box is swapped atomically, so a selection change rebuilds only it.
  - The output pass gets one extra draw.
  - The label uses the test patterns' seven-segment digits.

**5. Masks v2 (fixes F5), with freehand (owner decision).**
- **Model.**
  ```
  SliceConfig.masks: [MaskShape]
  MaskShape { mode: add | subtract, feather, path: [MaskPoint] | image: { folder, file } }
  MaskPoint { x, y, in: MapPoint?, out: MapPoint? }   // handles as offsets from the point
  ```
  - Points are in normalized output coordinates, as today.
  - Handles are offsets from their point, so a nudge, or a mesh resample's
    neighbour, moves a point together with its handles.
  - A point without handles is a corner; with handles its segments are cubic
    Bézier curves.
  - A path needs at least 3 points, curved or not; an image has none.
  - `masks` is decoded with `decodeIfPresent`.
- **Older projects.**
  - `ProjectDocument.load` turns `mask` into `masks` (one add mask), next to
    the existing key backfills, and does the same on a version revert.
  - The UI reads the document, and one failed slice decode blanks every
    output, so this happens in the document and not only in Swift.
  - Presets (3) are built first and store slices with the old `mask`, so the
    same conversion runs on every `OutputConfig.presets[].slices[]`.
    Otherwise `decodeIfPresent` skips the old key, and recalling a stored
    preset silently drops its mask. A test loads a project with a masked
    preset and recalls it.
- **Visible area.** The union of the add masks (everything when there is none)
  minus the union of the subtract masks.
  - Feathered, that is `max(adds) × (1 − max(subtracts))`.
  - Holes for doors and windows are subtract masks. **Invert** in the UI flips a
    mask's mode.
  - Fills use the nonzero rule, so a freehand loop that crosses itself does not
    punch a hole.
- **Missing image.** An image mask whose file is missing covers nothing: an
  add mask adds no area, and a subtract mask cuts no hole. Readiness warns. If
  it was the only add mask the slice is black, which is safer on stage than
  content spilling onto the wall.
- **Tools.** Every tool makes a path, so there is one kind of path to store,
  rasterise and edit:
  - **Polygon:** tap the points.
  - **Rectangle:** drag a box; it gives 4 corners.
  - **Ellipse:** drag a box; it gives 4 points with handles (κ ≈ 0.5523).
  - **Freehand:** drag along the outline.
    - The stroke is simplified (Ramer–Douglas–Peucker, tolerance 2 output px)
      and turned into a smooth path (Catmull-Rom to Bézier handles).
    - Points and handles stay draggable; a double-tap toggles corner or
      smooth.
  - **Image:** a greyscale file from the library, where luminance is
    visibility, stretched over the output. The library reloads it when the
    file changes (0). The mode applies; the feather does not, because the image
    carries its own softness.
- **Rasterising.**
  - CoreGraphics fills each path, curves included, with the nonzero rule into
    the existing `r8` mask texture at output resolution. The fill gives the
    sign.
  - The feather's linear ramp needs the distance only within ±feather/2 of
    the flattened outline. It is computed per segment over that segment's
    widened bounding box, keeping the minimum. Today's brute force over every
    segment for every sample would take seconds for a freehand path at 4K.
  - Budget, checked in a test: at most 20 ms for 2,000 segments with a 2 px
    feather at 3840 × 2160, release build.
  - The preview scales every mask's feather, as today's preview scales its
    one.
  - The output pass is unchanged. The edit overlay (4) draws the outlines.
- **UI.**
  - Each slice gets a mask list (mode, feather, remove); order does not matter,
    because union and subtraction commute.
  - The tools are in the mask mode of Warp & Slices.
  - They work on the iPad too: freehand with a finger on the preview.
  - Remote mode steps through mask points and their handles.
- **Slice shapes (owner decision 2026-10-30).** A slice stays a quad of four
  corners. Resolume's regular slices and Millumin's slices are rectangles,
  quads or triangles, and both make round shapes with masks; only MadMapper
  has a circle surface (`docs/mapping-ux.md` §2).
  - Two buttons in the slice mode of Warp & Slices act on the selected slice.
    Each is one edit, so one undo step:
    - **Triangle:** the top-left and top-right corners move to the middle of
      their edge. The bilinear slice mesh squeezes the source's top edge into
      that point. `output.set` already accepts two equal corners; dragging
      one away makes a quad again.
    - **Circle:** adds an ellipse add mask (the Ellipse tool's path) that
      fills the bounding box of the slice's corners. With other add masks on
      the slice the visible area is their union, as for any mask.
  - The mask stays in output coordinates, as every mask does: moving a slice
    corner afterwards changes how the content stretches, not the circle. A
    round object seen at an angle is an ellipse on the output anyway, and it
    is drawn there.
  - Not built: radial mapping (content wrapped around a ring), until a show
    asks for it.

**M2 build order** (one PR each, Opus coding agents, review before merge; the
groundwork and small engine pieces first):
1. Black lift by coverage (Core)
2. Compile cache and per-output plan state (0)
3. Keystone mode (fixture, DMX queue, vertex shader)
4. Mapping presets: model, commands, Output ch 6, preview badges, UI
5. Preset morph on Output ch 7
6. Edit overlay with leases (Compare's lease arrives with 4)
7. Masks v2: model, loading older projects, banded rasteriser
8. Masks v2: UI and tools, freehand included, and the slice shape buttons

## 10. Audio

- One **output device** for the engine (machine setting; aggregate devices
  supported), run by `AVAudioEngine` with a single `AVAudioSourceNode` whose
  real-time render callback mixes all layers' PCM rings: `out += ring.pull()
  × volume × pan`. Per-layer output pair selection (channels 1-2, 3-4, …) is
  a project setting.
- Each layer's decoder fills its PCM ring (48 kHz float, 250 ms) from the
  movie's audio track, positioned by the layer clock. Audio plays only when
  `speed == 100 %` and direction is forward; otherwise the ring is muted
  (`[OPEN-15]` varispeed/pitch later). Freeze/scrub mute instantly, dissolve
  crossfades audio with the video.
- Sync: the layer clock is master. The render callback compares the ring's
  head pts with the clock; drift beyond ±20 ms is corrected by dropping or
  repeating up to 2 ms per callback (inaudible for programme material), and
  logged if it recurs. "Resync audio" on the Control channel forces a
  re-seek.
- Stills and live inputs have no audio in v1. Audio metering per layer and
  master is part of the live state (Layers screen).
- LTC input shares none of this: it has its own input device and sink node
  (§15.1).

---

## 11. UI architecture (ADR-0012, ADR-0013, ADR-0014, ADR-0015)

### 11.1 Transport and security

- One listener: **HTTPS + WSS on TCP 8443** (configurable), all interfaces
  by default, per-interface selectable. Static UI files, REST for uploads /
  downloads (thumbnails, GDTF, logs, project export), WebSocket for state,
  commands and binary streams. HTTP/1.1 and RFC 6455 framing are implemented
  in `FanousCore/Protocol` (small, unit-tested) on top of Network.framework
  TLS connections; no web framework. `[OPEN-16]` resolved in Phase 5: the
  framing stays hand-written (`WebSocketFrame`, `WebSocketHandshake`) because
  `NWProtocolWebSocket` needs its own listener and cannot share the port.
- **TLS everywhere, including the local shell.** WebCodecs is only exposed
  in secure contexts, and WebKit's treatment of `http://localhost` as secure
  is inconsistent, so even the local preview needs HTTPS. The engine
  generates a self-signed ECDSA P-256 certificate on first run (own minimal
  X.509/DER writer over `SecKey`, no dependency; SANs: hostname, `.local`
  name, current IPs; 10-year validity) and stores the identity in the login
  keychain. Its SHA-256 fingerprint is shown in System › Network and in the
  shell's About screen. The shell pins that fingerprint in
  `webView(_:didReceive:)`. Browsers show a warning once; users can replace
  the identity with their own PEM/PKCS#12 (System › Network). A downloadable
  CA profile for iPads is `[OPEN-17]` (later).
- Bonjour: `_fanous._tcp` and `_https._tcp` advertised so a browser on the
  iPad finds `https://<host>.local:8443`. As built (B39): `_fanous._tcp` is
  the listener's own service; `_https._tcp` (TXT `path=/`, `port`) is a
  dns_sd registration for the same port while the listener is ready, because
  an NWListener carries one service and a second NWListener on the port
  fails with EADDRINUSE on macOS 27 despite `allowLocalEndpointReuse`.
  Neither with `--no-network`.
- **Auth = roles with optional passwords**, no user accounts. Three roles
  (monitor, operator, programmer), each with an optional password stored as
  PBKDF2-HMAC-SHA256 (CommonCrypto, 600 000 iterations, per-role salt) in the
  machine settings. Login returns an HttpOnly session cookie (also used for
  the WebSocket upgrade). A role without a password is open. The default
  install has **no** passwords; the status bar shows a yellow "web UI open"
  indicator until the programmer password is set. The local shell
  authenticates as programmer with a per-install random token from a
  mode-0600 file in Application Support (never typed, never shown).
  `[OPEN-18]` decided in Phase 5: roles are open or protected independently,
  and a client is granted the highest role up to the one it requested that it
  is entitled to (cookie, shell token or open role).
- Rate limiting on login (5/min per IP), CSRF not needed (cookie SameSite
  Strict + same-origin WebSocket check), all REST mutations go through
  WebSocket commands anyway.

### 11.2 State model and sync protocol (ADR-0013)

The engine holds two documents:

- `project` — everything persisted: canvases, outputs, slices, patch, layer
  settings, cue list, show-control config, library root reference (by id),
  UI layout prefs. Versioned (§11.5).
- `live` — runtime only: per-layer resolved parameters and their source
  tags, playback positions, media resolution results, DMX reception per
  universe, timecode, metrics, ingest jobs, audio meters, connected clients,
  readiness check results, errors.

Protocol (JSON text frames unless noted):

```
client → server   {"t":"hello","clientId":"…","schema":1,"token"?:"…"}
server → client   {"t":"welcome","role":"programmer","rev":1234,"project":{…},"live":{…},"caps":{…}}
server → clients  {"t":"patch","rev":1235,"doc":"project","ops":[{"op":"replace","path":"/outputs/2/blend/left/overlap","value":120}]}
server → clients  {"t":"patch","rev":1236,"doc":"live","ops":[…]}            // batched every 50 ms, coalesced per path
client → server   {"t":"cmd","id":"c-77","name":"output.setBlend","args":{…}}
server → client   {"t":"ack","id":"c-77","ok":true,"rev":1237}  |  {"t":"ack","id":"c-77","ok":false,"error":{"code":"showLocked","message":"…"}}
client → server   {"t":"sub","stream":"dmx","universe":"artnet:0:0:1"} / {"t":"sub","stream":"preview","target":"canvas:1","w":640}   // h and fps are ignored
server → client   {"t":"sub","id":7,"stream":"preview",…}  |  {"t":"error","id":7,"stream":"preview","code":"badTarget","message":"…"}   // refused; an error with an id and no stream ends that stream
client → server   {"t":"sub","stream":"thumbs"}   // live layer thumbnails (B29, §11.3)
server → client   {"t":"sub","id":8,"stream":"thumbs","w":160,"fps":4}  |  {"t":"error","id":8,"stream":"thumbs","code":"noPreview","message":"…"}
server → client   binary frames: [u8 kind][u32 streamId][payload]   kind 1 = H.264 AU (AVCC) , 2 = JPEG , 3 = DMX universe (512 B) , 4 = metrics ring page
```

- A preview `sub` reply carries `codec` (`"avc"`, or `"jpeg"` when refused
  at the encoder limit), `w`, `h`, `fps`, `target` and `fallback`; on H.264
  each `stream` description (`codec`, base64 avcC `description`, `w`, `h`,
  `fps`, `fallback`) comes with the first frame of a session and after a
  move. `fallback: true`: the stream is the target's canvas's, not the
  target's (an output's region or one layer at the encoder limit, B70/B96).
- The engine answers a connection's preview `sub` requests in the order they
  were sent (one at a time, on that connection's receive queue), each with a
  `sub` or a refusal (`error` with `stream`): the client matches replies to its
  requests by that order.
- Patches are RFC 6902 ops on a revision counter; a client that misses a
  revision (gap) re-requests a snapshot. Every change to `project` is a
  **command** on Control: validated, applied, inverse recorded for undo,
  diffed into a patch, snapshot-scheduled.
- `live` updates are coalesced per path (latest value wins) and sent every
  50 ms (20 Hz) per client; per-client send queues are bounded (256 KB);
  overflow drops *live* patches and marks the client "lagging" (it then
  re-snapshots `live`). `project` patches are never dropped: a client that
  cannot keep up is disconnected and reconnects.
- Subscriptions bound bandwidth: a client only receives DMX monitor data for
  the universe it is looking at, and preview streams it asked for. Max 4
  clients with a video preview (tier setting); the fifth gets a JPEG preview
  at 5 fps and a note.
- Multiple clients see the same `rev`; last command wins; a client that
  issued a command sees its own ack and the same patch everyone else gets.
- Show lock is a `project` flag: while set, every command tagged
  `mutatesConfig` fails with `showLocked` except `show.unlock` (programmer
  only). Operators keep: cue go/back/goto, transport (retrigger), timecode
  source on/off, blackout, test patterns, preview selection. Monitors: none.

### 11.3 Preview streaming (ADR-0014)

- Target: canvas, output (post-blend/warp, what the projector shows, a frozen
  output's held frame included: §9.5, B107) or a
  single layer. Compositor downscales the chosen texture into a small
  `CVPixelBuffer` (from a Metal-compatible `CVPixelBufferPool`; rendered
  into directly via `CVMetalTextureCache`, no readback) each N-th tick;
  `VTCompressionSession` (H.264 Baseline/Main, real-time, no B-frames,
  1 s GOP, 1.5 Mbit/s at 640×360@30 default) encodes on its own queue;
  AVCC access units go out as binary frames with the `avcC` record in the
  stream's first message. The browser decodes with WebCodecs `VideoDecoder`
  (`avc` with `description`) into a `<canvas>`. One decoder per preview,
  closed when its stream stops (target change, disconnect, hidden tab; B85).
- Fallback when WebCodecs is unavailable or fails a real decode test at
  connect time: JPEG at 5 fps on the same stream id.
- Encoding cost is bounded: one encoder per distinct (target, size) pair,
  fan-out to all subscribers; at most 4 encoders total on tiers 1–2.
- Per-layer live thumbnails: the compositor downscales each visible layer's
  current frame to 160 px wide every 250 ms; JPEG on the preview queue;
  broadcast on stream kind 2 to subscribed clients. The same frames feed
  CITP/MSEX streaming (§16.1).
- **As built (layer target, 2026-10-26):** `sub` with `target: "layer:<n>"`
  (1-based, 1…project `layerCount`, otherwise `badTarget`) gets its own
  streamer from `PreviewHub` like `output:<id>`. Each preview frame (the
  streamer's N-th tick, only while it has subscribers) `Compositor.drawLayer`
  re-draws that layer's draw items of the canvas pass just completed (same
  layer shader and uniforms, one quad, two during a dissolve, blend forced to
  Normal) over black into a preview-sized `rgba16Float` texture owned by the
  streamer, on the tick's command buffer; that texture then takes the canvas
  path (downscale into the pooled pixel buffer, H.264/JPEG). Extra cost per
  subscribed layer target: one 640×360 render pass with one or two quads
  every second tick at 60 fps, plus its own encoder. A layer with nothing on
  the canvas (no media, intensity 0, index beyond the render layers after the
  layer count shrank) is black; a canvas change (B31) rebuilds the streamer
  at the new size through `configure`, and until then a streamer whose
  aspect no longer matches the canvas sends no frames (the last one stays).
  The draw items are always this tick's selection (`drawItems` on a
  canvas-reuse tick), so their ring frames are protected exactly as for the
  canvas pass. The browser stops a subscription that resolves after the
  target changed again (`latestOnly`). The Layers screen toggles Canvas /
  This layer (per browser, `localStorage`). B29 thumbnails reuse its layer
  draw in an atlas (below).
- **As built (sizes, B32, 2026-10-27):** `sub` takes an optional `w`
  (wanted width in pixels, clamped 160–1280); the engine picks the smallest
  size class ≥ `w` out of 320, 640, 960 and 1280 wide (640 without `w`),
  height in the target's shape: canvas 1 or `canvas:<id>` its canvas,
  `layer:<n>` its layer's canvas, `output:<id>` the output's region (else
  its display, else 1920×1080), so an output preview is no longer a 16:9
  frame stretched back. A stream has at most the pixels of its class's
  16:9 frame (a 4:3 output in the 640 class is 554×414; H.264 level ≤ 3.1),
  at most 2160 lines; the `stream` codec string is built from the avcC
  (profile, level). Pure functions in `FanousCore.PreviewSize`.
  `PreviewHub` keys streamers on (target, class); the canvas 1 streamer at
  640 always exists (CITP). With 4 encoders in total (the canvas one
  counted, `/metrics` `preview.encoders`), a new class of a target that
  already has one attaches to its nearest class (the larger on a tie) and
  the `sub` reply says that size; across targets since B70 (below). Bit rate
  scales with the pixels (1.5 Mbit/s at 640×360, 0.5–4 Mbit/s). A changed
  output region, layer canvas or display size rebuilds the previews
  (`shapeChanged`; existing subscribers get the new size in a `stream`
  description). `attach` makes a streamer outside the hub's lock and makes
  it again when its target changed shape meanwhile or the size it would
  fall back to lost its last subscriber. The browser asks for its element's
  width × `devicePixelRatio` (rounded up), also after a pixel-ratio change,
  and re-subscribes 300 ms after a resize that crosses into another class
  by more than 5 % (`latestOnly`).
- **As built (live layer thumbnails, B29, 2026-10-28):** `sub {stream:"thumbs"}`
  (no target) is answered like the other subs, `{"t":"sub","id":n,"stream":
  "thumbs","w":160,"fps":4}` (refused without a renderer: `error` with
  `stream: "thumbs"`, code `noPreview`); `unsub` ends it. One producer
  (`Preview/ThumbnailStreamer`, owned by `PreviewHub` like the streamers) for
  every subscriber and CITP layer stream; it draws only while one of them
  exists (`/metrics` `preview.thumbnailPasses` stands still otherwise). Every
  `ThumbnailAtlas.everyNth` compositor tick (250 ms: every 15th at 60 fps; it
  asks for pixels on those ticks only, so with nothing else watching the canvas
  is drawn 4 times a second), on the tick's command buffer after the canvas
  pass, `Compositor.drawThumbnails` draws every render layer that shows
  something this tick (an item with intensity > 0 on a canvas that renders; the
  same draw items, frame lifetime and Normal blend as `drawLayer`) alone into
  its cell of one canvas-format atlas, one render pass, viewport and scissor per
  cell, cleared to black; cost ≤ 32 quads (64 during dissolves) per pass,
  uniforms in three rotating thirds of one buffer. Cells are 160 wide in the
  layer's canvas aspect (2–480 lines, even); layer i sits in slot i of a
  4-column grid whose slots are as tall as the tallest visible cell (32 layers
  of 16:9: 640×720). With no visible layer there is no pass at all. The atlas is
  copied 1:1 through the output pipeline into a pooled BGRA pixel buffer
  (`CVMetalTextureCache`, no readback; the pool only grows); on the streamer's
  own utility queue (`org.fanous.preview.thumbnails`) the buffer becomes one
  `CGImage` (one copy of its bytes; the GPU is done with it) and ImageIO
  encodes each visible cell, cropped, as a JPEG (quality 0.7, 2–4 KB): about
  1.6 ms per set of 8 layers on an M1 Pro (Core Image per cell, tried first,
  took 18 ms). While a set is still being encoded the next pass is skipped (GPU
  pass included), so a slow encode never piles up pixel buffers (`/metrics`
  `preview.thumbnailEncodeMs`: the last set). Binary
  frames are kind 2 on the `thumbs` stream id, one per layer: `[u8 layer
  number, 1-based][u16 width][u16 height][JPEG]`, big-endian like the stream
  header; width and height 0 without JPEG bytes = the layer shows nothing. A
  frame is sent only when that layer's JPEG changed (a still layer costs one
  frame); a new subscriber, and one whose frame was dropped under
  backpressure, gets the whole current set with the next pass; the set is
  forgotten once nobody wants thumbnails. The Layers screen subscribes while it
  is shown, the tab is visible and the engine renders (`latestOnly` against
  late replies), shows each frame as an object URL in its layer row
  (`img[data-live]`) and falls back to the library thumbnail for an empty frame
  or without a stream. Pure functions in `FanousCore.ThumbnailAtlas`. CITP
  layer streams (§16.1) send the same JPEGs (black at the layer's cell size
  while it shows nothing).
- **As built (lazy encoder, B66, 2026-10-28):** a streamer's
  `VTCompressionSession` is not made with the streamer (engine start makes
  the canvas one) but by its first H.264 consumer: the subscription (or a
  tapped frame that wants H.264) starts `VTCompressionSessionCreate` on a
  global queue, never on the preview queue, so a slow or stuck VideoToolbox
  holds neither engine start nor the streamer's JPEG/CITP frames; the
  session is installed on the preview queue and H.264 frames are skipped
  until then. The `stream` description (avcC) still comes after `sub` and
  before the first access unit (with the first frame of a new session). The
  last H.264 subscriber leaving releases the session (also on the canvas
  streamer, which lives as long as the engine). The log says "preview
  encoder ready" (size, ms), "preview encoder not ready after 5 s",
  "preview encoder failed" (no retry until the next H.264 subscriber) and
  "preview encoder released". The browser falls back to JPEG (a new JPEG
  subscription) when no `stream` description arrives within 5 s of an
  H.264 `sub` reply; a reply refused to JPEG at the encoder limit (B70/B86)
  is watched instead until its decoder is configured (after the
  description's `isConfigSupported`): 5 s without a drawn frame (the engine
  moved it to a new streamer whose session is slow or fails) and it
  re-subscribes as JPEG (B95); moved back to JPEG by the engine (B88), it is
  watched again. Both are one way: the JPEG stream stays JPEG until the next
  re-subscribe (target, size class, reconnect, tab hidden and shown). A
  healthy H.264 stream is never demoted after its decoder is configured, so
  a tick stall (display asleep, a long project load) does not demote it. While it asks for JPEG the caption says
  "connecting…", never "H.264" over a closed decoder (B98). The pixel
  buffer pool, texture cache and `CIContext` stay in `init` (no
  VideoToolbox). `/metrics` `preview.jpegOut` counts the JPEG frames made,
  `preview.jpegFailed` the encodes that returned nil (logged once per
  streamer, "preview JPEG encode failed") and `preview.jpegDropped` the
  JPEG sends a subscriber's connection refused (queue above 256 KB or a
  closed session); all three are sums over the live streamers only (B99).
- **As built (encoder limit across targets, B70, 2026-10-28):** the 4 count
  H.264 encoders: the canvas 1 streamer always, every other streamer while
  it has an H.264 subscriber (`/metrics` `preview.encoders`; a JPEG-only
  streamer has no session and does not count). Past 4, `PreviewHub.choose`
  gives a new H.264 (target, class) an encoder that runs already: its
  target's nearest class, else the nearest class of its canvas's stream
  (`canvas:<id>`; a layer's canvas, an output's first slice's), else it is
  refused to JPEG on its own streamer: the `sub` reply says `codec: "jpeg"`,
  fps 5, and the browser shows its JPEG frames at once ("JPEG 5 fps · … ·
  H.264 encoders busy") on that subscription (an `error` reply would leave
  it on "no preview"). The hub remembers these subscribers; when an
  unsubscribe or a closed connection releases an encoder it moves them,
  oldest first and up to the limit, to their own (target, class) on a global
  queue (the streamer is made outside the lock, like `attach`'s), in one
  step under the lock: off the fallback, onto the new streamer, whose
  `stream` description and first key frame come with its first frame (as
  after a rebuild). Measured: description 53 ms after the close, longest gap
  between frames 63 ms. The browser keeps a refused subscription (no JPEG
  re-subscribe while its frames come) and switches to its H.264 decoder when
  that description comes (B86), or re-subscribes as JPEG after 5 s without
  a frame before that decoder is configured (B95); JPEG frames arriving on an H.264 subscription
  later (the engine moved it back to JPEG, B88) close the decoder and are
  drawn until the next description. A canvas-stream fallback shows other
  content than asked (the whole canvas, not the output's region or the layer
  alone), often in another aspect: when the served size (`sub` reply, then
  each `stream` description) is another shape than the preview's box, the
  browser letterboxes it (`object-fit: contain`) and the caption says
  "canvas fallback" (B87). The engine says so too (B96): `fallback: true`
  in the `sub` reply and in each `stream` description while the viewer is
  on its canvas's stream (a size fallback of its own target is not one; the
  re-balance move to its own stream sends `fallback: false`), so a fallback
  in the box's shape (a layer, or a region crop of the same ratio, 960×540
  of a 1920×1080 canvas) is flagged as well and letterboxed, which draws it
  as `fill` would. After a change of the box's shape (a canvas format or
  output region change) the label also shows for a moment, until the rebuilt
  stream's description arrives. A fallback streamer whose own viewer left
  stays as it is: only fallback viewers keep it encoding, so no release is
  seen and nothing starts a re-balance. The canvas 1 streamer's own viewers
  are never on a fallback (it is always counted).
  fps 5, and the browser, seeing no `stream` description, subscribes to JPEG
  after 5 s (an `error` reply would leave it on "no preview"). The hub
  remembers these subscribers; when an unsubscribe or a closed connection
  releases an encoder it moves them, oldest first and up to the limit, to
  their own (target, class) on a global queue (the streamer is made outside
  the lock, like `attach`'s), in one step under the lock: off the fallback,
  onto the new streamer, whose `stream` description and first key frame come
  with its first frame (as after a rebuild). Measured: description 53 ms
  after the close, longest gap between frames 63 ms. In the browser this
  holds for size and canvas fallbacks only: `Preview.svelte` ignores
  `codec: "jpeg"` and after 5 s re-subscribes as JPEG (`fallbackToJPEG`),
  which ends the refused subscription, so a refused viewer stays on JPEG
  until it subscribes again (B86). A canvas-stream fallback shows other
  content than asked (the whole canvas, not the output's region or the
  layer alone), often in another aspect (B87). A fallback streamer whose own
  viewer left stays as it is: only fallback viewers keep it encoding, so no
  release is seen and nothing starts a re-balance. The canvas 1 streamer's
  own viewers are never on a fallback (it is always counted). A rebuild that
  removes a canvas tells only that canvas's own viewers `badTarget`; another
  target's viewer on its stream as a fallback is chosen again for its own
  target (one refused to JPEG is told `badTarget` too: the browser cannot
  take JPEG frames on a stream that was H.264, B86), and every rebuild ends
  with a re-balance, synchronously after the rebuild (B88).

### 11.4 Frontend (ADR-0012)

Svelte 5 (runes) + Vite + TypeScript strict, Vitest for unit tests; no UI
component library, no router library (six screens, hash routing in 30
lines), no runtime CDN loads. Chosen over Preact because fine-grained compiled
reactivity updates exactly the DOM nodes that changed when 1 000+ live values
tick at 20 Hz, with no virtual DOM diff and a smaller runtime; the UI must
stay smooth on an iPad while the mapping editor renders an SVG overlay over a
live preview.

Structure: `web/src/{lib/protocol,lib/state,screens/*,components/*}`; the
protocol types are generated from `FanousCore/Protocol` (a small Swift
script emits `protocol.d.ts` in Phase 5) so client and server cannot drift.

Touch: Pointer Events everywhere; the mapping editor's handles are ≥ 44 px
hit targets, two-finger pan/zoom, numeric fields with a stepper and keyboard
arrows (±1 fine, ±10 coarse with Shift, ±0.1 with Alt).

### 11.5 Undo, redo, versioning

- One **global** undo history on the server (commands with inverses),
  shared by all programmer clients, 500 entries, cleared on project load.
  Show-lock/unlock and cue *go* are not undoable (they are not config).
- Project format: a directory bundle `Name.fanous/` with `project.json`
  (schema-versioned, migrated on load), `versions/` (one JSON snapshot per
  change burst, debounced 2 s; keep last 200 + one per day for 90 days +
  all named versions), `thumbs/` (cache). Snapshots are full documents
  (they are small); diffs between any two versions are shown in the UI.
- Auto-save after every command burst; "named version" and "revert to…" are
  commands themselves (and therefore undoable).
- Machine settings (library root, interfaces, audio devices, TLS identity
  reference, role passwords, last project) live outside the project in
  `~/Library/Application Support/Fanous/settings.json`.
- **As built (versions, B23/B35, 2026-10-26):** still one project per machine
  (`project.json`, autosaved 2 s after the last command); no bundle, no
  `thumbs/`, no diff view. `ProjectVersions` (`State/ProjectVersions.swift`)
  keeps full documents in `versions/` next to it, one file per version,
  `<UTC yyyyMMddTHHmmss.SSSZ>-<slug>.json`: the project document plus a
  `snapshot` member `{name, at, automatic}`, so a version file still loads as a
  project (`ProjectDocument.load`), and the id is the file name. Automatic
  versions: the loaded file at engine start, every show-mode enter, every
  10 minutes (all version file work on its own utility queue), each skipped
  when the project equals the newest version apart from `showLock` (compared
  by a SHA-256 of the sorted-keys document, kept for the newest version, so no
  file is re-read); the newest 50 automatic ones are kept, named ones never
  expire (retention instead of 200 + one per day). Version metadata is parsed
  once per file name (files are never rewritten); the directory listing still
  picks up files added or removed by hand. Times are strictly increasing, also
  when the clock went back (the first listing raises the floor to the newest
  version), the version just written is never pruned, and two saves in one
  millisecond get a counter in the id. Writes are atomic; a file that does not
  load as a project or has no `snapshot` member is skipped and logged once.
  Commands: `project.snapshot {name?}` (programmer, allowed under show lock;
  without a name it is an automatic "Manual" version), `project.versions`
  (monitor; id, at, name, automatic, layer/output/canvas/cue counts, newest
  first), `project.revert {id}` (programmer, `mutatesConfig`, refused in show
  mode with `showMode`), `project.deleteVersion {id}` (named only). A revert is
  an ordinary undoable command. It refuses a version a live command could not
  have made (layer count 1–64, a patch that parses, 1–4 valid canvases within
  the pixel cap) with `invalidArgs`; it is a no-op (`unchanged: true`, one log
  line) when the version equals the project apart from `showLock`; otherwise it
  saves the current project as an automatic "Before revert to …" version
  unless the newest version already equals it (refused if that save fails),
  keeps the current `showLock`, and replaces the document, so the diff goes out
  as one patch and `projectChanged` applies it like any other change (canvas
  switch, patch, cues, timecode). Undo and redo of a
  revert entry are refused in show mode (`CommandSpec.replayCheck`, checked by
  `StateStore.step` before it pops). The check sees the patch the step would
  apply, the patch that made the state it undoes (`HistoryEntry.forward`) and
  the current project. `syphon.forget` and `project.revert` both run
  `ProjectDocument.checkLiveReplay` (was `checkSyphonReplay`; B90, B91; it
  covers `/syphon`, `/capture`, `/screens` and `/windows`): every op on `/syphon/N`
  needs the whole entry the undone step left there
  (nothing, where it removed) or already the value it writes; otherwise the
  number changed meanwhile and the step is refused with `historyConflict`
  ("Syphon number 151 is now held by App/Server", or "is now free"), so an
  undo or redo never overwrites, renames or frees a server that took the
  number. Nor may it leave a name it writes on a second number ("Syphon
  server N/Server is now on number 150", B92): the server took another
  number meanwhile, and the catalog drops such a twin only while it runs.
  `syphon.forget` passes the running numbers and lets a twin of a running
  server through (the catalog drops it); `project.revert` has no running set
  and refuses those too. Two stopped servers that legitimately share a name
  (two engines' canvases) count as twins: the undo of a forget of one of
  them, and the undo or redo of a revert that held both, are refused.
  The history holds whole entries: `StateStore` folds a revert's diff of
  one field (`/syphon/151/app`) into a `replace` of `/syphon/151`, so `app`
  and `server` are compared together (B104). The conflict
  drops the entry, as does a step that no longer applies; for a revert either
  drops the whole stack, whose entries were recorded against the project the
  revert replaced. A step skips a `remove` whose key is already gone (the
  engine dropped a running server's twin), so that undo still applies and no
  client gets the remove. The undo of a forget
  without file is refused as a whole when any of its numbers conflicts. `live.versions` `{lastAutomatic, serial}`
  feeds the status bar and tells the System screen to re-list. OSC
  `/fanous/project/load s` resolves the newest named version with that name
  (case-insensitive), else a version id, on the versions queue, ignores a
  repeat of the same version within 2 s, and runs `project.revert` as
  programmer; refusals are logged.

### 11.6 Phase 5 as built (2026-10-23)

- Transport: hand-written RFC 6455 framing on the HTTPS listener
  (`FanousCore/Protocol/WebSocket.swift`; the accept key is CryptoKit SHA-1 in
  the engine's `HTTPSServer.swift` since the 2026-10-29 audit), `/ws` handled by
  `StateServer`; binary frames `[u8 kind][u32 stream][payload]` with kind 1 =
  `[u8 key][u64 µs][AVCC AU]`, 2 = JPEG, 3 = 512 DMX slots. The H.264 decoder
  configuration travels as a `stream` text message (base64 avcC) whenever the
  parameter sets change.
- Documents: `project` (schema, name, showLock, layerCount, patch, policy,
  library.root, ui) autosaved to `project.json` 2 s after the last command;
  `live` (engine, metrics, dmx, layers, ingest, library, clients, security)
  rebuilt at 10 Hz and diffed, so one patch per 100 ms carries only changes.
  Commands are diffed into forward/inverse patches (`StateStore`), which gives
  undo/redo for free; show lock refuses `mutatesConfig` commands.
- Roles: independent per role (OPEN-18); PBKDF2-HMAC-SHA256 600 000 rounds;
  `/api/login` cookie, shell token as `?token=` on first load and as a bearer
  for mutating REST calls; `/api/ingest`, `/api/upload` need programmer.
- Preview: `PreviewStreamer` draws the canvas through the output pass into a
  pooled BGRA pixel buffer on the compositor's command buffer every N-th tick,
  VideoToolbox H.264 Baseline (1 s GOP, 1.5 Mbit/s, 640×360@30) on a utility
  queue, JPEG at 5 fps for clients without WebCodecs; one encoder shared by
  all subscribers. Per-layer live thumbnails were deferred (B29, built 2026-10-28, §11.3).
- UI: Svelte 5 runes, hash router, one deep `$state` tree patched in place,
  `protocol.d.ts` generated from the command registry; status bar, Layers,
  Media and Patch/DMX screens follow the approved design canvas; system fonts
  until Inter/JetBrains Mono are bundled (B26).
- Measured (docs/benchmarks/README.md): kill -9 → HTTPS 0.15 s, frames
  0.26 s; four preview clients + one stalled client: identical revisions, the
  stalled one flagged lagging, 0 missed / late frames.

---

## 12. Main screens

Global chrome (all screens): a fixed **status bar** (top) and the screen
switcher (left rail, icons + labels, collapses on iPad portrait).

**Status bar**, left to right: engine state (show mode / show lock badge),
fps & frame time (per output, worst-case highlighted), dropped frames (last
60 s, red when > 0 in show mode), DMX per universe (green pulse per packet,
yellow > 1 s silence, red > 2.5 s), timecode (source, value, lock/freewheel),
outputs (count ok / red names of missing displays), audio device, ingest
(progress when active), clients (count, lagging ones), thermal/power (yellow
on battery or thermal pressure), backup (v2; hidden in v1). Red means "look
now" and is reserved for: dropped frames in show mode, lost DMX on a patched
universe, lost output display, decoder error on a visible layer, readiness
failure while entering show mode.

1. **Layers / Mixer** — one row (or tile on narrow screens) per layer: live
   thumbnail, layer name + canvas, resolved media ("12 / 4 · intro_loop.mov ·
   HAP Q · 1080p60"), position scrubber with in/out markers, intensity,
   play mode, speed, audio meter, source policy badge, error/warning. A
   "DMX" column shows the incoming raw values of the fixture's channels,
   labelled with their meaning and resolved units; clicking a parameter opens
   the override panel (programmer, auto-expiring). Master and Output
   fixtures are shown as compact strips above the layer list.
2. **Media** — folder column (numbered, with counts and invalid markers) and
   file grid with thumbnails, codec badges, duration/fps/alpha/audio,
   "needs transcode" state and ingest progress. Drag-and-drop or "Import…"
   (native file dialog in the shell; path browser or HTTP upload in
   browsers). Ingest queue panel with per-job codec choice, target number,
   progress, ETA, errors. Rename/renumber with conflict detection.
3. **Outputs & Mapping** — three tabs sharing a live preview that can show
   the canvas, the selected output (post-warp) or the physical display
   arrangement: *Canvases* (size, layers assigned, clock master), *Outputs*
   (display assignment with identity, region, mode, intensity, blend edges
   with curve plot, black lift; test pattern buttons), *Warp & Slices* (corner
   pin and mesh editor over the live output preview, slice quads/meshes, mask
   path editor with feather, numeric fields for every point, nudge keys,
   point density selector, "raw" bypass). Designed for iPad: large handles,
   two-finger pan/zoom, a "send test pattern to this output" toggle that
   stays visible.
4. **Patch / DMX** — fixture list (type, universe, address, footprint,
   collisions in red), add/remove layers (bounded by the tier's measured
   limit, shown next to the count), per-universe source protocol and
   interface, sACN priority, hold-on-loss setting; **DMX monitor**: a 512-cell
   grid for the selected universe with patched ranges coloured per fixture
   and live values, hover shows "Layer 3 · ch 5 · Play mode · 17 → Loop rev";
   GDTF export button and a channel-map viewer (generated from the spec).
   Redesign designed in §6.6 (2026-10-30, not built): fixtures grouped by kind
   and patched as blocks, a Universes panel, a Who controls card and a Patch
   sheet for the console.
5. **Show control** — timecode (source select: LTC device / MTC port, frame
   rate, offset, lock state, big readout), cue list (add/edit/reorder cues,
   per-cue parameters + fade, TC trigger time, go/back/goto, current/next
   highlighting, follow-timecode toggle), OSC (ports, address map viewer,
   last 50 received messages), MIDI (ports; MTC only in v1).
6. **System / Health** — machine capabilities and tier (chip, memory
   engines, GPU, memory, displays supported, measured benchmark numbers or
   "not benchmarked"), live metrics (frame time histogram per output,
   dropped frames, decode latency per layer, ring occupancy, DMX→photon
   estimate, encoder queue, thermal state, memory), readiness checklist with
   fix hints, network (interfaces, listener state, TLS fingerprint, Bonjour
   name, clients), logs (filterable tail, download), service (engine
   version, uptime, restart, install/remove agent — shell only), roles and
   passwords, library root, audio device, backup (v2).

Keyboard: `1–6` switch screens, `Space` cue go (operator+), `Esc` closes
panels, `Cmd/Ctrl+Z / Shift+Z` undo/redo, `L` toggles show lock (programmer,
with confirmation).

---

## 13. Instrumentation

Counters and timings are written by the owning thread into preallocated
ring buffers (one struct per event; no strings) and aggregated on
Housekeeping into 1-second summaries that feed `live.metrics`, the logs and
the benchmark.

| Metric | Source | Exposed as |
|---|---|---|
| Frame time: CPU encode, GPU time (`GPUStartTime/GPUEndTime`), present deadline miss | compositor / output threads | per-output histogram, p50/p99, status bar fps |
| Dropped / late frames | `CAMetalDisplayLinkUpdate.targetTimestamp` vs actual present, drawable timeouts | counters per output, red in show mode |
| Decode latency per layer | sample request → texture ready | p50/p99 per layer, ring occupancy graph |
| HAP chunk-pool utilisation, Snappy MB/s | chunk pool | System screen |
| DMX | packets/s, sequence gaps, last-seen per universe, parse errors | status bar + Patch screen |
| **DMX→photon estimate** | `t_rx` (packet receive on DMX queue) → `t_apply` (snapshot published) → `t_tick` (compositor picked it) → `targetPresentationTimestamp` of that frame; reported as `present − t_rx`, plus a note that display scan-out latency is not included | p50/p99 in System; logged once per minute |
| Audio | ring underruns, drift corrections | per layer |
| Network | per-client queue depth, drops, lagging | System → clients |
| Preview encoders | frames in/out, skipped | System |
| Ingest | job throughput, yields | Media |
| System | thermal state, memory footprint, on battery, CPU per thread (from `thread_info`) | System + status bar |

Logging: `swift-log` with two handlers: `os_log` (Console.app) and a rotating
file in `~/Library/Logs/Fanous/` (10 × 10 MB). Log lines in hot paths are
pre-formatted off-thread from ring events; the compositor itself never calls
the logger. Anomalies (first dropped frame in show mode, DMX loss, display
loss, decoder error) are logged at `warning` with the metric context, and a
post-show report (`System › Logs › Report`) summarizes them per run.

`/metrics` (REST, JSON) exposes the current 1-second summary for external
monitoring; a Prometheus text format is `[OPEN-19]`.

---

## 14. Show mode and readiness

**Show mode** (toggle, programmer/operator) makes the machine deterministic
with public APIs:

- `IOPMAssertionCreateWithName` for `PreventUserIdleDisplaySleep` and
  `PreventUserIdleSystemSleep`; `ProcessInfo.beginActivity(.latencyCritical,
  .userInitiated, .idleDisplaySleepDisabled)` (also disables App Nap for the
  engine); the shell adds the same assertions while visible.
- Output windows at `CGShieldingWindowLevel`, cursor hidden over outputs,
  desired display modes applied (§9.6), mirroring disabled check.
- Ingest paused (default), library rescans reduced to manual, log level
  `warning`, thumbnails at 1 fps, preview encoders capped.
- Dropped-frame and DMX-loss events become red.
- Survives an engine crash and Engine › Restart Engine: the state is persisted
  (`show-state.json`), a clean stop clears it, and the next start resumes show
  mode without the readiness refusal and without restoring the display modes
  (§16.3 as built).

**Readiness check** (runs on entering show mode, re-checked every 30 s, each
item with a one-line fix): on AC power; thermal state nominal; free disk > 10
%; memory headroom; all patched universes receiving; capture permissions
granted (`capture`: the camera when the capture catalog has an entry, built
2026-10-30, B73 step 2b; the screen when the screens catalog has one, step 3;
§8.2.1); all outputs bound and in the desired mode;
no decoder errors; library on a local volume; Spotlight indexing of the
library volume (`mdutil -s` state read via `MDQuery`/`mdutil` output) off or
acknowledged; automatic macOS updates state (read from
`com.apple.SoftwareUpdate` defaults) acknowledged; Time Machine not currently
backing up; Focus/Do Not Disturb cannot be read reliably → shown as a manual
checklist item; display sleep settings; unsupported hardware (hard fail).
Failed items block show mode until acknowledged (programmer) — except hard
fails.

An MDM configuration profile that enforces the non-programmable items is a
later deliverable (`[OPEN-20]`).

---

## 15. Show control: timecode, cues, OSC, MIDI

### 15.1 Timecode

- **LTC**: any CoreAudio input device/channel (machine setting). An
  `AVAudioSinkNode` on an `AVAudioEngine` input graph delivers buffers on the
  real-time thread; the biphase-mark decoder in `FanousCore/Timecode` is
  fed samples and emits frames (24/25/29.97 DF/NDF/30 auto-detected), with
  sub-frame phase for jitter-free chasing. Lock / freewheel (configurable,
  default 2 s) / lost states. Requires the microphone permission (TCC); the
  engine prompts once with an explanation.
- **MTC**: CoreMIDI input (quarter-frame + full-frame), any port; same
  `TimecodeSource` interface. **As built (B64, 2026-10-27):** `MTCInput`
  follows hot-plug like `MIDIInput` (§15.4): its client is made on the main
  thread (a runtime `timecode.set` arrives on the control queue and hops
  there), reconnects on `msgSetupChanged`, and handles everything on its own
  serial queue with one assembly state per source unique id; the packet's host
  time travels with each word. A source that goes away takes its assembly state
  with it; for the clock that is signal loss like a stopped sender (freewheel,
  then lost after the freewheel time). `live.timecode.device` lists the
  connected sources and drops a gone one at once, and `error` says "MTC source
  … is not connected" (or "no MIDI source connected") while none matches.
  The clock counts as locked within 1.5 times the update interval the
  source promises: one frame for LTC, two for MTC (a quarter-frame sequence assembles
  one time every 2 frames, 80 ms at 25 fps), so MTC no longer flickers to
  Freewheel between its updates (B65).
- One active source per project; offset per project and per layer (Layer
  timecode chase = `tc − projectOffset − layerOffset` at the file's fps,
  looped within in/out if the layer's loop flag is set).
- Timecode is published in `live` at 10 Hz for the UI and sampled at every
  compositor tick for chasing (the compositor reads an atomic (tc, hostTime)
  pair and extrapolates).

### 15.2 Cue list (v1 scope: simple)

A cue = name, number, set of (parameter, value) for any fixtures, fade time
(per cue; per-parameter override), optional timecode trigger, optional
follow (auto-go after n s). Go/Back/Goto from UI, OSC, Space key; timecode
triggers fire when the active timecode crosses the cue's time (with a
"re-arm on jump back" rule). The fade engine lives in Core (pure, tested):
linear fades for continuous parameters, snap at start for enumerated ones
(configurable snap-at-end). Cue values enter the resolver as the *Internal*
source (§7.2), so they only affect layers whose source policy allows it.
A timeline editor and MIDI/OSC-triggered cue *recording* are later.

### 15.3 OSC

UDP and TCP (SLIP, RFC 1055) servers on configurable ports (default 8000),
interface selectable. Address space generated from `ParameterSpec`:

```
/fanous/layer/{1..n}/{param}  f (normalized 0–1 or unit value; both accepted via type tag)   e.g. /fanous/layer/3/intensity 0.75
/fanous/layer/{n}/media       ii (folder, file)
/fanous/layer/{n}/retrigger
/fanous/master/{param}        /fanous/output/{n}/{param}        /fanous/keystone/{n}/{param} (M2.3)
/fanous/cue/go  /cue/back  /cue/goto i  /cue/{number}/go
/fanous/show/lock i  /fanous/show/mode i  /fanous/timecode/enable i
/fanous/project/load s (programmer; refused while show-locked)
```

Bundles with timetags are honoured (scheduled on Control). OSC feedback
(query/notify) is later; the design keeps every OSC-settable value in `live`
so a feedback sender is a subscriber like any client.

**OSC feedback as built (B36, 2026-10-26).** Not through the `live` document
after all: `OSCFeedbackServer` (Engine/Net) builds a flat map address →
arguments on its own queue, at most once per half tick (25 ms); notifications
and every `get` in between share it. Under the DMX lock only the resolved raw
values are copied (`DMXStore.resolvedRaw()`); addresses are built once per
fixture and cached, values are float 0–1 of the raw range plus `media ii` (a
reply sent back sets the same raw value). Cue, show, readiness, timecode,
output and engine values come from `Engine.oscFeedbackState()`, which reads
only cached copies: show lock and timecode enable from `oscProjectFacts`
(updated on project changes, not the project document on Control), fps and
missed frames from the metric totals sampled once a second (no percentiles).
No paths. Requests (`OSCFeedback.request`, Core) are handled before the
command map, after a token bucket per source host (10/s, burst 20) and one over
all hosts (200/s, burst 400) (`OSCRateLimiter`):
`/fanous/<path>/get [port]` answers every address at or below the path (sorted,
at most 256) to the sender, or to `port` on its host only if that host:port is
a confirmed subscriber; `/fanous/get` the summary. Subscribing is a cookie
handshake: `/fanous/subscribe host port [prefix]` (host must be the sender) is
answered with `/fanous/subscribe/confirm <cookie>` to host:port and streams only
after `/fanous/subscribe/ack <cookie>` from that host; pending entries take no
slot, expire after 5 s and are capped at 64. `OSCSubscriptions` (Core, pure)
keys confirmed subscribers by host:port with up to 8 prefixes, 16 subscribers
(the fixed target not counted), 60 s lifetime renewed by subscribe or ping, and
diffs the map against what each was last sent on a 50 ms tick: per address at
most 20 messages/s, latest wins, at most 200 messages per subscriber per tick
(rotating). The tick runs only while a confirmed subscriber or a fixed target
with a prefix under `/fanous` exists, and only after `Engine.start` finished.
Every cue go invalidates `/fanous/cue` so it is re-sent unchanged. Output is OSC
bundles with timetag 1 (a real timestamp would be delayed by a receiver whose
clock runs behind) packed under 1 200 bytes. A subscriber whose port is its
source port, and the fixed target once it sends from that port, are answered on
their inbound flow (from port 8000): an outbound `NWConnection` to a host:port
that has a flow into the listener fails with EADDRINUSE. Others get one
outbound UDP `NWConnection` each (a confirm to another port: one connection,
cancelled after the send). Source hosts keep their IPv6 scope for these
connections; named hosts are compared without it. The fixed target is
`oscFeedback {host, port, prefix?}` in `settings.json` (`MachineSettings`, decoded
field by field so a bad value never drops the role passwords; problems are
logged), read at start; there is no UI for it. Like the OSC receiver it does not exist under
`--no-network`.

### 15.4 MIDI

MTC only in v1 (§15.1). The CoreMIDI client, port enumeration and the
Show-control screen's MIDI section are built so that notes/CC → parameters,
MSC and MIDI-triggered cues are additions, not rewrites.

**As built (B36, 2026-10-26):** MIDI input for control, next to MTC.

- Core (`MIDI/MIDI.swift`): `MIDIParser` turns a MIDI 1.0 byte stream into
  note on/off (velocity 0 = off), CC, program change and MSC messages, with
  running status, real-time bytes anywhere, system common cancelling running
  status and SysEx up to 256 bytes; `MIDIParser.bytes(ump:)` turns the Universal
  MIDI Packets CoreMIDI delivers with the 1.0 protocol (types 1, 2, 3; others
  skipped by size) back into bytes. `MSCMessage` parses `F0 7F dev 02 fmt cmd
  Q_number 00 Q_list 00 Q_path F7`; fields keep what was sent, and `cueNumber`
  is nil for a cue that is present but not digits with one "." at most.
- Engine (`ShowControl/MIDIControl.swift`): `project.midi = {source?,
  mscDevice, mscFormat?, map[]}`, read entry by entry (an unreadable or unusable
  entry is reported in `live.midi.error` and skipped; `midi.map.set/remove` edit
  the raw array, so they never rewrite entries they could not read; entries
  without an id get one on load); a map entry is `{id, source?, channel (0 = any), kind:
  note|cc|cc14|pc, number?, target, cue?, curve: linear|toggle, pickup, low,
  high}` with targets `cue.go`, `cue.back`, `cue.goto` (+ `cue`; a program
  change without one goes to cue program + 1), `fixture:<Layer n|Master|Output
  n>/<key>` and `master/<key>`. `MIDIMapper` (pure): cue targets fire on a press
  (note on, a CC rising past 64, a program change); 14-bit pairs (CC n / n+32,
  n < 32) follow MIDI 1.0: the MSB resets the LSB (value msb << 7), the LSB
  refines it, the MSB kept per (source unique id, channel, controller) and
  dropped when the source disconnects; toggles start from the shown value;
  per-entry state is keyed by entry id; pickup holds a control until it is within one 7-bit
  step of, or moves across, the resolved value, and releases it when another
  source changes that value. MSC GO to our device id or the all-call, in the
  configured command format (default video 0x30–0x3F) or all-types 0x7F →
  `cue.go`, or `cue.goto` with a cue; a cue that does not parse does nothing; STOP/RESUME are parsed, not acted on (the
  cue engine has no pause). `MIDILearner` takes the next note on, CC or program
  change; CC 0–31 waits one message for its LSB to tell a 14-bit pair.
- `MIDIInput` opens its own CoreMIDI client and a UMP 1.0 input port on every
  source or the named one, reconnects on `msgSetupChanged`. CoreMIDI delivers
  setup notifications on the run loop current at the process's first CoreMIDI
  call, so `Engine.start` makes the client on the main thread (NSApplication run
  loop) before the host-facts lookup or MTC touch CoreMIDI; made on a dispatch
  queue, hot-plugged sources were never seen (`MTCInput` makes its own client on
  main too, B64; since the 2026-10-29 audit both do it through one
  `MIDISourceListener`, which also connects, tracks sources by unique id and
  stops). It handles
  everything on one serial queue (one parser per source unique id, so two
  identical controllers do not share running status). Parameter values go to
  `DMXStore.setMIDI` as the internal `midi` source (`ValueSource.midi`), so the
  source policy decides, exactly as for OSC. A controller can be left holding a
  value, so `.midi` counts as a controller like `.ui` in the B27 expiry (masking a
  received console for 10 min releases it, `fixture.keep` restarts the count,
  `fixture.release` clears it), and a source's values are released when it
  disconnects and an entry's when it is removed or retargeted; cue actions run `cue.go/back/goto`
  through the state store as the operator. Commands `midi.set`,
  `midi.map.set` (upsert by id, or by same control and target), `midi.map.remove`
  and `midi.learn {target?, cue?}` (arms; the learned entry is stored with
  `midi.map.set` when the message arrives, so learn answers through
  `live.midi.learning/learned`) are programmer commands refused under show lock;
  MIDI values keep flowing while locked. `live.midi`: connected sources, last
  message, learn state, error.
- UI: the Show screen's MIDI panel (`ShowMIDI.svelte`): source picker, MSC
  device id and format, last message and map errors, Learn with target choice, map table with mode and
  pickup, Remove.
- Not built: MIDI output (feedback LEDs, MSC replies), MSC group ids, a
  CoreMIDI virtual-source test (kept out of CI; tests inject bytes).

---

## 16. CITP/MSEX and GDTF

### 16.1 CITP/MSEX

- Peer location: UDP multicast `224.0.0.180` (port 4809 per the spec PDF,
  re-checked when the fixtures are captured), `PLoc` sent every 5 s
  with the engine's name, type "MediaServer" and its TCP listening port
  (ephemeral, advertised).
- MSEX over TCP, negotiating the highest version both sides support
  (1.0/1.1/1.2): `CInf`/`SInf` (server info, layer count), `LSta` (layer
  status: media, position, playing state at 4 Hz), `ELIn`/`MEIn` (element
  libraries = folders, elements = files with names/dimensions/fps/length),
  `EThn` (JPEG/RGB8 thumbnails from the library cache), `StFr` (streaming
  frames of a layer or canvas, JPEG, ≤ 320 px, rate as requested up to
  10 fps, from the live-thumbnail path).
- Implementation in Core (packets) + Engine (transport). Fixtures: packet
  captures from free console software (grandMA3 onPC, ETC Eos Nomad,
  ChamSys MagicQ PC, Vista) since no hardware console is available yet;
  interop with those is the Phase 7 acceptance test.

### 16.2 GDTF export

`Patch › Export GDTF` writes `Fanous.gdtf` (zip: `description.xml` +
thumbnail PNG) describing fixture type "Fanous" with its DMX modes (four since M2.3),
channel functions with physical ranges, channel sets for every band (play
modes, blend modes, effects, test patterns), 16-bit coarse/fine links and
defaults — all generated from `ParameterSpec`. Fixture type GUID is stable
across versions; the `FixtureTypeID` changes only when a footprint changes
(never, by design). GDTF 1.2 (DIN SPEC 15800:2022) is the target; the
`mvrdevelopment/spec` `next` branch is checked before Phase 1 freezes the
export. There is no official validator, so a unit test checks the XML
against a schema derived from the spec text, and the file is imported into
grandMA3 onPC, Eos Nomad and MagicQ during Phase 7.

---

### 16.3 Phase 7 as built (2026-10-24)

- **Timecode** (`ShowControl/TimecodeInput.swift`): `TimecodeClock` keeps one
  (timecode, host time) sample under a mutex with locked / freewheel / lost
  states; `frames(at:)` extrapolates for the chase and returns nil once lost.
  `LTCInput` runs an `AVAudioEngine` input graph with an `AVAudioSinkNode`
  (device picked by name through CoreAudio, microphone permission requested
  once) and feeds the Core `LTCDecoder`; `MTCInput` opens a CoreMIDI UMP
  (MIDI 1.0 protocol) input port, assembles quarter frames (+2 frames) and
  reads full-frame SysEx (hot-plug since B64, §15.1). The compositor chases in the `timecode` play mode:
  `(tc − projectOffset − layerOffset) / rate × fileFps`, looped inside
  in/out (`Render/TimecodeOffsets.swift`). Settings live in `project.timecode`
  (`timecode.set`); `live.timecode` carries state, value, rate, device, error.
- **Cues** (`ShowControl/CueRunner.swift`, `ShowCommands.swift`): `project.cues[]`
  stores cues UI-friendly (`{number, name, fade, values:[{fixture:"Layer 3",
  parameter:"intensity", raw, fade?}], trigger:"hh:mm:ss:ff@25", follow}`),
  validated against the channel map by `cue.add/set/remove`; `cue.go/back/goto`
  drive the Core `CueEngine` through `CueRunner` (fades ticked at 50 Hz while
  anything fades or a follow is pending, timecode triggers from the clock).
  Cue values enter `DMXStore.setCue` as the internal `.cue` source, so the
  source policy decides per layer. `live.cue`: current, next, fading, count.
- **OSC**: the full §15.3 address map is routed through `DMXStore.onCommand`
  into the state store (cue, show lock/mode, timecode enable); bundles with
  timetags are scheduled on Control; `live.osc.recent` is the log the Show
  screen shows. `/fanous/project/load` restores a named project version
  (B35, §11.5 as built).
- **Show mode and readiness** (`ShowControl/ShowMode.swift`): IOPM assertions
  (`PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`),
  `beginActivity` (latency critical, no App Nap), ingest paused. Readiness
  runs the §14 items (15 with display modes) on entering and every 30 s while on
  (`readiness.run`, `readiness.acknowledge`); `show.mode` is refused with the
  blocking ids (`notReady`). Desired display modes are applied on entering
  and restored on leaving (B33, `DisplayModeSwitcher`, matching in
  `DisplayModeMatching`; one `.forSession` transaction, re-applied on
  re-plug; previous modes persisted in `display-modes.json` and restored on
  the next start after a crash outside show mode; unavailable modes are a non-blocking `warn` readiness item).
  **Show mode survives a crash (as built 2026-10-26):** `show-state.json`
  (`{on, since, boot, written, restart?}`, `boot` = `kern.boottime`) is written
  on entering (inside the controller's state lock, refreshed every 30 s) and
  removed on leaving. `Engine.stop` leaves show mode, so SIGTERM (launchd stop,
  Stop Engine, Stop Engine and Quit, logout, bootout) clears it; once the stop
  has begun, entering is refused. Engine › Restart Engine (and the shell's
  re-register of a hung ad-hoc agent) first writes `restart-pending`; a stop
  that finds it fresh (< 60 s, always removed) keeps the file marked `restart`
  and skips the display-mode restore, leaving the ledger. An unclean end (crash,
  kill -9, power loss, launchd's SIGKILL after a hung stop) leaves the file too.
  At start the file resumes show mode when its boot time matches (engine died,
  not the Mac) or it is younger than 2 h (Mac went down mid-show); otherwise
  "stale show state ignored" and it is removed. Resuming pauses ingest before
  it starts and re-enters show mode before the outputs and display modes come
  up, with every normal side effect and without the readiness refusal; readiness
  runs at the first display sync. The log says "show mode resumed after an
  unclean stop" or "show mode kept across a restart", and live `show.resumedAt`
  drives the status-bar and System notice until show mode is left. The first
  display sync is then an apply, not a restore: displays already in their show
  mode are not switched and the ledger is kept for the restore on leaving (no
  flip-flop). The show lock lives in the project document; a lock change is
  saved at once on the autosave's serial queue (no older write can land after
  it), so a crash cannot unlock a locked show. The
  remaining §14 side effects (shielding level, log level, thumbnail/preview
  throttling) are B42.
- **System**: `/metrics` (JSON: frames, GPU/CPU timing, DMX age, audio,
  preview, clients), `/api/logs` (ring tail), Bonjour `_fanous._tcp` and
  `_https._tcp` (B39), `live.system` (thermal, power, memory, OS, host, addresses, TLS fingerprint).
- **CITP/MSEX**: codec in Core (`CITP/CITP.swift`, `CITP/CITPMSEX.swift`, MSEX 1.0–1.2,
  little-endian, byte-exact tests), one way as Fanous is only a server: it decodes what a
  console sends (`PNam`, `CInf`/`GELI`/`GEIn`/`GETh`/`GVSr`/`RqSt`) and encodes what the server
  sends (`PLoc`, `SInf`/`Nack`/`LSta`/`ELIn`/`MEIn`/`EThn`/`VSrc`/`StFr`);
  transport in Engine (`Net/CITPServer.swift`): one `NWListener` on an
  ephemeral TCP port, `PLoc` every 5 s to `224.0.0.180` and `239.224.0.180`
  (both groups, port 4809, a BSD socket: `NWConnection` does not deliver to
  multicast groups), per session the highest common version ≤ 1.2,
  `SInf` with one DMX source string per layer, `LSta` at 4 Hz from the layer
  status, libraries = numbered folders, elements = numbered files with their
  probed metadata, thumbnails from the library cache, `GVSr` answered with
  `VSrc` (source 0 = canvas 1 at its preview size, source n = layer n with its
  0-based layer number and thumbnail size), streaming frames = the canvas JPEG
  from the preview path for source 0 (and any id that is no layer, for consoles
  that never ask for the sources) or layer n's live thumbnail (B29; black while
  it shows nothing) (≤ 10 fps, only encoded while a console streams that kind of
  source: `wantsFrames` / `wantsLayerFrames`), `Nack` for MSEX types we do not
  model. `VSrc` follows the spec text's layout; no console capture yet (B40). The server UUID is a
  per-install file in Application Support. `live.citp` lists port, consoles
  and open streams. Verified in loopback only (B40).
- **UI**: Show screen (Go / Back / Go to, Space = go, timecode panel with
  source and offsets, cue list and editor, OSC log, MIDI sources) and
  System / Health screen (show-mode switch with the readiness panel, machine
  and network facts, metric tiles and a sparkline polled from `/metrics`
  every 2 s, roles and passwords, log tail with filter and download).

## 17. Licensing setup (ADR-0015)

| File | Content |
|---|---|
| `LICENSE` | Verbatim GNU GPL v3 text, unmodified so license scanners recognise it; the notice "GPL-3.0-only with additional terms under section 7, see `LICENSE-ADDITIONAL-TERMS.md`" is in `README.md` and in every source header. |
| `LICENSE-ADDITIONAL-TERMS.md` | The two §7 additions: (b) attribution preservation (text in `docs/licensing/ATTRIBUTION.md`), and the additional *permission* for plugins (`docs/licensing/PLUGIN-EXCEPTION.md`, DRAFT until lawyer-reviewed; shipped only after review). |
| `docs/licensing/ATTRIBUTION.md` | exact wording of the attribution term and the exact strings the About screen and web footer must show |
| `docs/licensing/PLUGIN-EXCEPTION.md` | DRAFT additional permission for linking plugins against proprietary SDKs via `FanousPluginAPI` |
| `docs/licensing/CLA.md` | Individual + Entity CLA text granting copyright and patent licenses with the right to sublicense and relicense (enables the commercial license) — DRAFT for lawyer review |
| `docs/licensing/DEPENDENCIES.md` | every dependency (server, vendored C/ObjC, web build-time and runtime), version, license, GPLv3 compatibility, how it is pinned |
| `CONTRIBUTING.md` | CLA requirement (DCO is not enough), how signing works, coding rules (SPDX header, Core purity, no new dependencies, tests), review process |
| `TRADEMARKS.md` | name and logo policy: code under GPL, name/logo not |
| Source headers | `// SPDX-License-Identifier: GPL-3.0-only` + `// Copyright (c) 2026 Tim de Bruijn` + `// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md` — the pointer line is what GPLv3 §7 requires when additional terms exist. A LicenseRef expression would be more SPDX-pure but makes license scanners stop recognising GPL; the ADR records the trade-off. `scripts/license-headers.sh` checks every `.swift`, `.metal`, `.c/.h`, `.ts`, `.svelte`, `.css`, `.sh` file in CI. |
| CLA tool | **cla-assistant (SAP)**, hosted at cla-assistant.io (or self-hosted) as a GitHub App: blocks merge until the PR author has signed the CLA stored in the repo; `contributor-assistant/github-action` is archived and EasyCLA is LF-only. Enabled when the repository goes public; until then the CLA text already lives in the repo. |
| About / footer | shell About window and web footer render the attribution string from one constant in `FanousCore` (`Attribution.text`), with the repository link; a UI test asserts both render it. The About screen also carries the third-party notices, including the Art-Net credit Artistic Licence requires. |

Dual licensing: the author is the sole copyright holder; every external
contribution is covered by the CLA, so the whole can also be offered under a
commercial license. Vendored BSD code (hap, snappy, Syphon) keeps its own
notices in `THIRD-PARTY-NOTICES.md` and is compatible with both licenses.

Release checklist items that come from this section (the internal brief was
removed from the repository and its history on 2026-10-26): lawyer review of `PLUGIN-EXCEPTION.md`, `CLA.md` and `ATTRIBUTION.md`;
trademark search for "Fanous" (`[OPEN-21]`).

---

## 18. Testing strategy

| Level | What | Where it runs |
|---|---|---|
| **Unit (Core)** | every parser/builder (Art-Net, sACN, OSC, CITP, LTC, MTC, HTTP/WS framing), channel map ↔ units, GDTF XML against the XSD, cue fades, blend/warp math, project migrations, JSON patch/undo | GitHub Actions `macos-26` (no GPU needed) and locally via `scripts/test.sh`; Swift Testing |
| **Protocol fixtures** | real packet captures: `Tests/Fixtures/captures/<protocol>/<source>-<desc>.bin` (raw UDP/TCP payloads extracted from `.pcapng` kept next to them with provenance in `README.md`). Sources in v1: grandMA3 onPC, Eos Nomad, MagicQ PC, QLC+, sACNView, plus hand-built edge cases (sequence wrap, priorities, sync packets, malformed lengths). Fuzz-style tests mutate fixtures and assert no crash | same |
| **Golden images** | deterministic scenes (synthetic textures, fixed parameters) rendered through the real compositor and output pass, read back, compared to PNGs with per-channel tolerance (±2/255) and a diff image on failure: blend modes, effects, transforms, dissolve, blend maps, warp, masks, test patterns, YCbCr/YCoCg conversion | Apple Silicon only: locally and on a self-hosted runner when available; skipped (not failed) on hosted CI |
| **Decode conformance** | one sample file per codec variant (generated by the ingest encoder from a synthetic source, checked against known pixel values) | Apple Silicon |
| **Allocation / latency** | 0 mallocs on the compositor thread over 1 000 frames; DMX→photon p99 under the tier's limit | Apple Silicon |
| **Benchmark** | `fanous-bench`: generates media (codec × resolution × fps), ramps layer count until any frame drops within 60 s, confirms with a 10-minute soak at the found count, with 0 and 4 preview clients; writes `docs/benchmarks/<chip>-<date>.json/.md` and the tier record the UI shows | Apple Silicon; first on the M1 Pro reference machine |
| **Soak** | 8 h run with a scripted DMX generator (random play modes, file changes, dissolves), hot-plug of one display, engine kill/restart; pass = 0 dropped frames outside the restart window, memory flat | before each release |
| **Protocol interop** | manual checklist with free console software (CITP thumbnails visible, GDTF imports, DMX control end-to-end) | Phase 7 |
| **UI** | Vitest unit tests for the protocol client, state store and mapping-editor geometry; Playwright browser tests against a real `fanousd --no-network` per test (`[OPEN-22]`, B47) | GitHub Actions |

CI (Phase 0): build all targets, Core tests, license-header check, Core
purity check, `web` lint/typecheck/test/build. Hardware tests are a separate
workflow triggered manually or by a self-hosted runner label.

---

## 19. Phased roadmap with acceptance criteria

Each phase ends with: a written summary (built / measured / open), a demo on
the reference machine, and a stop for review. Phases are sequential; the
listed spikes are the first task of their phase because they retire the
biggest risks early.

| Phase | Deliverable | Acceptance criteria |
|---|---|---|
| **0 — Skeleton** | Package layout, CI, license files, SPDX headers, `web` scaffold, `scripts/bundle.sh`, empty `fanousd` that starts, serves the UI shell page over HTTPS with the generated certificate, and logs | `swift build` + `swift test` green on hosted CI; `.app` assembles, signs ad-hoc and launches; TLS identity generated and pinned by the shell; license-header and Core-purity checks pass; `DEPENDENCIES.md` complete |
| **1 — Core protocols & parameter model** | Art-Net/sACN receive + merge, universe model, `ParameterSpec`, channel map, resolver with source policies, OSC server, LTC/MTC decoders, GDTF export, cue fade engine, `docs/channel-map.md` generated | all fixture captures pass; footprint test locks 64/8/8; GDTF validates against the XSD and imports into grandMA3 onPC and Eos Nomad; OSC and DMX drive the same resolver in tests; LTC decoder locks on a generated 25/29.97DF file within 2 frames |
| **2 — Render spike & benchmark** | ProRes and HAP decode via sample cursor + VT / hap.c, zero-copy textures, compositor with intensity/position/scale, one canvas, one output, display link, instrumentation, `fanous-bench` v1, DMX→photon estimate | **spike results written down**: native ProRes pixel formats confirmed IOSurface-backed and used without conversion; HAP chunk decode parallelism measured; benchmark on the M1 Pro: tier-2 numbers recorded for 1080p60/4K30/4K60 × ProRes HQ/HAP Q; 0 mallocs per frame; `preferredFrameLatency 1` holds at the measured layer count; DMX→photon p99 ≤ 2 frames + display |
| **3 — Full layer feature set** | all Layer-mode parameters (3D transform, fit, crop, colour, 8 blend modes, 11 effects, dissolve, all play modes, retrigger), stills, image sequences via ingest stub, Syphon in/out, audio playback, Master fixture | golden images for every blend mode/effect/transform; dissolve measured cost documented; audio drift < 20 ms over 1 h at 1×; Syphon output visible in another app; benchmark re-run shows the tier numbers still hold with effects on 2 slots |
| **4 — Media library & ingest** | library index + FSEvents, thumbnails, ingest queue (ProRes via AVAssetWriter, HAP via hap.c + muxing spike), image sequences, originals handling, remote upload | HAP files written by ingest play back in the engine and in VLC/QuickTime with the HAP plugin; ingest does not drop a frame of a running 8-layer show (measured); index survives 10 000 files; invalid names reported |
| **5 — Service, UI foundation** | LaunchAgent via SMAppService, crash restart, role auth, state sync protocol, undo/versioning, show lock, preview streaming (H.264 + JPEG fallback), status bar, Layers, Media, Patch/DMX screens, DMX monitor, generated `protocol.d.ts` | kill -9 of the engine → outputs back < 3 s; 4 browser clients + shell show identical state, lagging-client test passes without affecting frame time (measured); WebCodecs preview works on iPad Safari over HTTPS; show lock refuses config commands; undo across clients; channel-map labels in the UI match `docs/channel-map.md` byte-for-byte |
| **6 — Outputs & mapping** | multi-output, regions per display, blend maps, black lift, warp (corner pin + bezier mesh), slices, masks, test patterns, display identity/hot-plug/modes, Output fixture, Outputs & Mapping screen on iPad | golden images for blend/warp/mask; 2×1 and 2×2 blend of a flat grey field measures flat across the overlap in a readback test; hot-unplug/replug of a display recovers without affecting other outputs; a 33×33 warp edit applies within 100 ms; iPad usability check by the owner |
| **7 — Show control & console interop** | LTC/MTC sources, layer timecode chase, cue list, OSC complete, CITP/MSEX (thumbnails + streaming), show mode + readiness, System/Health screen | chase accuracy ±1 frame against a generated LTC file; cue fades match the fade engine's unit tests end-to-end; thumbnails appear in grandMA3 onPC and MagicQ PC via CITP; readiness check catches each simulated failure; metrics exported |
| **8 — Hardening & release** | soak tests, benchmark on every available machine, notarized build, user docs (EN), release checklist (brief removed, legal review done), v1.0 | 8 h soak passes on the M1 Pro; benchmark docs committed per machine; notarized `.app` installs and registers the agent on a clean user account; all `[OPEN]` items either resolved or moved to the v1.x list |

Scope guard: a feature not in the table is not in v1. Serial fixture, OSC
feedback, per-output Syphon, 10-bit output, frame blending, varispeed audio
and the MDM profile are the v1.x candidates.

---

## 20. Risks

| # | Risk | Impact | Mitigation / when retired |
|---|---|---|---|
| R1 | Hardware ProRes path does not yield IOSurface-backed frames in a format the shader can sample directly (hidden conversion, extra copy) | performance, zero-copy claim | Phase 2 spike is the first task; fallback is requesting the decoder's native format and converting in-shader; worst case a `VTPixelTransferSession` on the decode thread (measured cost) |
| R2 | HAP decode is CPU-bound (Snappy); 4K60 × many layers saturates P-cores and starves the compositor thread | tier numbers lower than hoped for HAP | chunk pool sized to P-cores − 1, compositor at higher QoS, benchmark decides tiers; HAP R (BC7) later does not change this |
| R3 | Network.framework's queue-based delivery adds jitter/latency to DMX | DMX→photon latency | measured in Phase 2; fallback: BSD socket + dedicated thread for Art-Net/sACN only (the brief's Network.framework rule would then be relaxed for this path, recorded in an ADR) |
| R4 | `AVSampleBufferGenerator` behaviour with HAP tracks (custom fourcc) or odd files | playback of some files | Phase 2 spike with files from several encoders (AfterCodecs, ffmpeg-made HAP, Vidvox tools); fallback: own minimal QuickTime demuxer for all-intra `.mov` (bounded scope) |
| R5 | Multi-display presentation drift with mixed refresh rates | visible judder on secondary outputs | documented behaviour + warning; recommend identical modes; measured in Phase 6 |
| R6 | TLS identity in the keychain (prompts, ACLs) | first-run friction; **seen in Phase 2**: the login keychain prompts "fanousd wants to use key" whenever an ad-hoc signed build changes, and the TLS handshake blocks until the dialog is answered | **Resolved in Phase 3** (ADR-0015 amendment): signed builds use the data-protection keychain; builds without a team identifier keep the key in a 0600 file and build the identity in memory with `SecIdentityCreate`. The login keychain is never used. A permissive "any application" ACL was rejected as a security weakening. |
| R7 | WebCodecs H.264 decode gaps on older iPad Safari | preview quality | real-decode test at connect; JPEG fallback; document "iPadOS 26+ recommended" |
| R8 | Writing HAP into `.mov` via `AVAssetWriter` passthrough fails for custom fourccs | ingest to HAP | Phase 4 spike; fallback own all-intra muxer |
| R9 | Audio/video drift and device changes at show time | audible glitches | layer-clock-master design, drift correction, device-change handler that re-creates the graph and logs; measured in Phase 3 |
| R10 | Console interop without a hardware console | CITP/GDTF surprises in the field | free console software for all three protocols; ask early adopters with hardware consoles to run the interop checklist before 1.0 |
| R11 | NotchLC is not royalty-free / has no public spec (verified 2026-10-22: proprietary SDK, terms unconfirmed) | "later" feature may never be possible under GPL | no design dependency on it; plugin boundary would be the only route |
| R12 | hap reference implementation unmaintained (last commit 2024-07) | security/compat fixes are ours | vendored with a pinned commit; small C surface; fuzz tests on the decoder input |
| R13 | macOS updates change Metal/VT behaviour | regressions | golden-image + benchmark suite runs on every macOS beta on the reference machine; minimum-OS decision `[OPEN-1]` |
| R14 | Single maintainer | bus factor, schedule | design and ADRs are the knowledge base; phases are independently shippable; CLA in place for future contributors |
| R15 | Memory pressure on 16 GB machines with 4K layers | stalls | budget rules (§4.6), tier knobs, red warning before activation |
| R16 | Thermal throttling on MacBook Pro during long shows | dropped frames late in a show | thermal state in status bar and readiness; benchmark includes a 10-min soak; recommend AC + stand/airflow in docs |
| R17 | `CAMetalDisplayLink` stalls after three presented frames on macOS 27.0.1 (measured, ADR-0006 amendment) | the brief's render clock cannot be used as-is | drawable-loop driver with the same compositor and metrics; display-link driver kept behind a switch; re-test on each macOS release; Apple Feedback with the standalone reproduction |
| R18 | every supported macOS (ADR-0020) re-asks a screen-capturing engine about monthly ("Allow For One Month"), on the main display, which an unattended show machine cannot answer (§8.2.1) | a dialog over an output, or display capture stopping mid-show | readiness item before show mode; capture card for a show-critical slides feed; MDM profile (OPEN-20) and the persistent-content-capture entitlement with the Developer ID build (B50) to be verified |

---

## 21. Designed-for-later features (not built in v1)

| Feature | Extension point already in the design |
|---|---|
| NotchLC decode in Metal | `Source` protocol + compute-shader decode stage before the ring; **blocked on licence** (R11) |
| HAP R | `bc7_rgbaUnorm` in the HAP texture path; ingest encoder flag |
| NDI in/out, DeckLink in/out | `FanousPluginAPI` (ADR-0016): C ABI, `dlopen`ed from `~/Library/Application Support/Fanous/Plugins/`, sources hand over IOSurfaces into the same frame rings; sinks subscribe to completed canvas textures like Syphon |
| Pixel mapping to DMX fixtures | Art-Net/sACN *builders* already exist in Core (needed for tests); a GPU sampling pass reads canvas regions into a small buffer per universe on the preview thread |
| Multi-server sync, main/backup failover | the Sync channel and clock packet are designed in §23 (B60, ADR-0021); a hot backup and control from one place build on the same packet plus the WSS project patches, §23.6 / OPEN-27 |
| 3D projection mapping | the output pass already renders arbitrary meshes through a displacement field; a projected OBJ with a calibrated camera matrix replaces the slice mesh |
| 3D-model layers (media as texture on a mesh) | the layer pass is one quad in a perspective camera (§4.3); a mesh from Model I/O (USDZ/OBJ) with its own UVs replaces the quad, the fragment shader is unchanged; needs a depth attachment on the canvas pass and a "Geometry" parameter in the reserved Layer channels 52–64 (0 = flat, 1–255 = model from the library); `docs/BACKLOG.md` B9 |
| Motion: tracking in, movement out (B53) | **Tracking as a source:** a PosiStageNet receiver in Core (UDP multicast, position/speed/orientation per tracker) and OSC trackers become an extra *internal source* in the resolver (§7.2), mapped per project ("tracker 3 → Layer 2 position X/Y, scale") through a stage-to-canvas calibration (metres → canvas) set on the Outputs screen; on-device person tracking through the Vision framework on a capture input (folder 0); depth/lidar SDKs only through the plugin boundary (ADR-0016). **Movement out:** DMX-controlled motion (mirror heads, pan/tilt yokes, winches, rotators) via the Art-Net/sACN builders of the pixel-mapping pass; small motors (ESP32 steppers/servos) via OSC output (B36) or an MQTT bridge. **Moving screens:** encoder positions in over PSN/OSC update an output's corner-pin homography per frame. **Hard rule:** Fanous sends cues and target positions only; it is never the safety layer of stage automation (e-stops, SIL-rated controllers stay in charge). Camera tracking of people is processed on the device and never stored (GDPR). Expected tracker → photon ≈ 35–40 ms, enough to follow a performer, not for locked-on AR. |
| Serial device fixture | fixture type in `ParameterSpec`; POSIX termios on `/dev/cu.*`, no dependency |
| OSC feedback, MIDI notes/CC, MSC, timeline, varispeed audio, 10-bit output, frame blending, MDM profile, CA profile for iPads | noted in their sections |

---

## 22. Open questions

| ID | Question | Proposed default |
|---|---|---|
| OPEN-1 | Raise the minimum macOS from 14 to **15**? Gains: stdlib `Synchronization` (`Atomic`, `Mutex`, macOS 15+) instead of swift-atomics (whose own README says it is superseded), one dependency fewer; macOS 14 Sonoma received its last update in Aug 2026 and is absent from the Sep 2026 security batches (verified 2026-10-22), i.e. outside Apple's n-2 window now that macOS 27 is out. CAMetalDisplayLink needs 14+, so 15 keeps everything in the brief. Metal 4 (macOS 26+) is not needed. | **Decided 2026-10-22: 15** |
| OPEN-2 | Bundle identifier / reverse-DNS prefix | **Decided: `org.fanous`** (`org.fanous.app`, `org.fanous.engine`) |
| OPEN-3 | Native pixel formats of the hardware ProRes decoder | **Measured (Phase 2):** 422 → `&sv2` lossless-compressed bi-planar 16-bit (zero copy); 4444 → `y416` requested to keep alpha (≈0.8 ms/1080p frame conversion) |
| OPEN-4 | Optional frame blending for rate-mismatched content | v1.x |
| OPEN-5 | 10-bit output drawables (`bgr10a2`/`rgba16Float` with EDR off) | v1.x; blue-noise dither in v1 |
| OPEN-6 | Keep the chip capability table in `docs/hardware.md` and in Core; who verifies new chips | owner verifies per generation |
| OPEN-7 | Serial fixture in v1 or v1.x | v1.x |
| OPEN-8 | Engine hard cap on layer count | **Decided 2026-10-25: 32** for v1; raise later per measured tier |
| OPEN-9 | Exact DMX bands (play modes, effects), speed max 400 %, scale max 800 % | **Resolved (Phase 1):** as in §6.2, locked in `docs/channel-map.md` and the GDTF |
| OPEN-10 | sACN per-address priority (0xDD start code) | not in v1 |
| OPEN-11 | Per-parameter smoothing vs a global switch | per parameter, default off |
| OPEN-12 | Folder 0 numbering for inputs/generators | **Decided 2026-10-25:** as in §8.2, plus 110 test card, 111 colour sweep, 112 clock (`Generators.names`); 150–169 other apps' Syphon servers (B61, 2026-10-27); 1–20 capture devices, 21–28 displays, 29–32 windows designed 2026-10-29 (§8.2.1, B73) |
| OPEN-13 | HAP muxing via AVAssetWriter passthrough vs own muxer | **Resolved (Phases 2–4):** `AVAssetWriterInput` with a `sourceFormatHint` format description and passthrough sample buffers writes HAP `.mov` files the engine plays; no own muxer |
| OPEN-14 | Per-channel (RGB) blend gamma | **Resolved (M1.6, 2026-10-29):** `rgba16Float` blend map with a factor per channel from `BlendEdge.gammaRGB`; unlinked R, G, B on the wall panel's seam (§9.2, §9.9) |
| OPEN-15 | Audio varispeed / pitch at speed ≠ 100 % | v1.x; mute in v1 |
| OPEN-16 | `NWProtocolWebSocket` in server role vs hand-written framing | **Resolved in Phase 5**: hand-written RFC 6455 framing in `FanousCore/Protocol/WebSocket.swift` (the accept key and 101 response moved to `HTTPSServer.swift` with CryptoKit SHA-1 in the 2026-10-29 audit). `NWProtocolWebSocket` owns a whole listener, so it could not share port 8443 with the HTTP/1.1 routes and static files; the upgrade is handled by the existing HTTPS connection handler. |
| OPEN-17 | Downloadable CA profile for iPads | v1.x |
| OPEN-18 | Monitor role open by default when other roles have passwords | **Decided in Phase 5**: each role is open or protected independently; a client gets the highest role ≤ the one it asked for that its session cookie or shell token entitles it to, or that is open. Monitor stays open unless it has its own password. |
| OPEN-19 | Prometheus metrics endpoint | v1.x |
| OPEN-20 | MDM profile for show machines | later (owner's choice) |
| OPEN-21 | Trademark search for "Fanous" before public release | owner; `docs/RELEASE.md` §7 |
| OPEN-22 | Browser smoke tests (Playwright) | **Done** (B47, 2026-10-27): Playwright tests against a real engine per test, in CI; Vitest covers the client, store and screen helpers |
| OPEN-23 | Library default location `~/Movies/Fanous Library` | yes |
| OPEN-24 | Default ports: HTTPS 8443, OSC 8000/8001; configurable | yes |
| OPEN-26 | Keychain strategy for unsigned development builds (prompt on every rebuild vs. ephemeral per-process identity) | **Decided 2026-10-23:** file-backed in-memory identity (`SecIdentityCreate`), no login keychain; ADR-0015 amendment |
| OPEN-27 | Hot backup and control from one place (a machine mirroring another's whole state over WSS, one project with every machine's outputs) | later, on the sync packet of §23 plus the WSS project patches (§23.6) |
| OPEN-28 | Hash-based library sync between machines | later; a copy by hand keeps the numbering equal (§23.1) |
| OPEN-25 | Register an Art-Net OEM code with Artistic Licence (free, needed for a proper `ArtPollReply`) | owner, `docs/RELEASE.md` §4; 0xFFFF until then |

---

## 23. Multi-server sync: the Sync channel (B60, ADR-0021)

Two or more Macs show one picture: each drives its own projector with its
own slice of the canvas and its own blend and warp, and a layer on one
machine plays frame-locked with a layer on another. Catalyst (play mode
"Synchronize to master unit") and High End's Axon/DL.3 ("Sync Mode" + "Sync
To" per layer, over Ethernet) solved this on the console; Fanous does the
same with one channel. Designed 2026-10-28 (owner review of the first draft,
which mirrored whole machines over WSS; see ADR-0021); step 2 (the channel and
the packet codec) is built (PR #31), and so are step 3 (the engine, §23.8) and step 4 (the UI, PR #35).

### 23.1 One channel: Sync, layer channel 51

| Channel | Parameter | Bands |
|---|---|---|
| 51 | Sync | 0–9 off · 10–89 **master**, group 1–8 (10 values per group) · 90–169 **slave**, group 1–8 · 170–255 reserved (off) |

- A **master** layer plays as it always did and publishes its clock under
  its group number. A **slave** layer takes the clock of its group and
  keeps everything else of its own: folder/file, intensity, position, scale,
  crop, effects, blend, audio, and the output's warp and blend. So the left
  mini shows the left half (a slice, or a pre-split file) and the right mini
  the right half, from the same console, in step.
- Groups are what Axon's "Sync To" + "Sync Mode" pair expresses with
  fixture ids: a slave on any machine and any layer number follows the
  master of its group, on any machine. The machines never need to know each
  other. A group also works inside one machine (layer 3 slaves layer 1 for
  two halves on one Mac) at zero latency.
- Two masters in one group: the lowest machine id (install UUID) wins,
  the others are ignored, `live` and the readiness list say so. A group
  without a master: the slave plays on its own clock, marked.
- The slave's own play mode, speed, in/out and timecode chase are ignored
  while it has a master; retrigger on a slave is ignored too (the master's
  retrigger arrives as a position jump). Different frame rates are fine:
  positions travel in media frames with the master's fps and are scaled
  (`position × slaveFps / masterFps`). Files of different length drift apart
  at the loop point, which is the user's call, not an error.
- Channel 51 enters `ParameterSpec` like any layer parameter (so the channel
  map document, the GDTF and the resolver carry it); channels 52–64 stay
  reserved. Consoles already patched with the 64-channel fixture are
  unaffected.

### 23.2 The clock packet

The master machine sends one UDP packet per compositor tick (only while at
least one of its layers is a master; a 1 Hz keepalive otherwise), 22 B per
master layer plus a 34 B header (738 B for 32 layers), little-endian:

```
FanousSync v1
  u8[4] "FSYN", u8 version=1
  u8[16] machine id (install UUID)
  u32 tick, f64 sendTime (sender's host time; informational)
  u8 count, per master layer:
      u8 group, u8 layer (source, informational)
      u16 mediaKey (packed folder/file), f32 fps
      f64 position (media frames), i8 direction, u8 finished
      f32 rate (media frames per second as the clock really advances: speed × master speed × fps × direction; 0 when frozen, finished or paused)
```

- **Where it goes:** the subnet broadcast address of the sync interface
  (default: the interface of universe 1, or the first non-loopback one), UDP
  port 8002 by default (OSC has 8000/8001), both in `settings.json` and on
  the System screen. The target may be a unicast address (two engines on one
  Mac send to 127.0.0.1). Broadcast like Art-Net, not multicast: it needs no
  group join per interface and reaches every machine on the cable; the
  multicast question of B28 does not apply.
- **Sender:** the compositor writes the master layers' clocks into a
  triple-buffered packet slot at the end of its CPU work (no allocation, no
  socket on the compositor thread); a sender thread wakes on a semaphore
  and sends the newest slot. Same pattern as the parameter triple buffer.
- **Receiver:** one socket bound to `0.0.0.0:port` with `SO_REUSEPORT`
  (like the sACN receiver, so two engines on one Mac both receive), on its
  own queue. Packets from the machine's own id are dropped (local groups use
  the table directly, below). The newest packet per group goes into a
  table `{group: (machine, mediaKey, fps, position, direction, finished,
  rate, receivedAt)}` behind a mutex; the compositor reads it with
  `withLockIfAvailable` once per tick (a busy lock means last tick's entry
  once more, as `layerCanvasBox` does).
- Local master layers write their clock into the same table at the end of
  the tick, so a local slave sees the same tick's position.

### 23.3 How a slave ticks, and why there is no drift

In `prepare` (the per-layer part of `Compositor.tick`), a slave layer does
not call `LayerClock.advance`. With a fresh table entry for its group
(younger than the freewheel time) it **sets** its clock:

```
age      = now − receivedAt                         (local clock only; no clock sync between machines)
position = (entry.position + entry.rate × age) × slaveFps / entry.fps, clamped to the slave file's range
direction, finished = entry's
```

The position is copied every tick, never integrated, so no error can
accumulate: the difference between master and slave is bounded by packet
jitter (well under 1 ms on a wired LAN) plus the one tick in which the
packet was sampled, and it stays that size after an hour as after a second.
Two residuals remain and are the floor:

- **One frame of display phase.** The two Macs' vsyncs are never aligned
  (no genlock on a Mac), so the moment a frame reaches the glass differs by
  up to one output period. The frame *content* is the same frame.
- **The frame boundary.** Both machines show `Int(position)`; when the
  master's position is a hair before a boundary and the slave's a hair after
  (extrapolation error), they show neighbouring frames for that tick. With
  the extrapolation the error is the jitter, so this is rare and never more
  than one frame.

Loss: no packet for the group within 1.5 ticks → the slave **freewheels**:
`LayerClock.advance` with the entry's last rate (not its own speed), so a
late packet never stutters and the next one snaps the position back
(normally < 1 frame). No packet for the freewheel time (2 s, as timecode)
→ **lost**: it keeps freewheeling, `live` marks the layer, readiness goes
yellow; the first packet relocks. Drift while freewheeling is 50 ppm × 2 s
= 0.1 ms. A master retrigger is a position jump larger than the ring on the
slave: the ring flushes and the previous frame holds until the new one is
decoded, exactly like a local retrigger (HAP and ProRes are all-intra, so
that is one frame of decode; the all-I-frame rule Axon had to impose is the
only kind of file Fanous plays anyway).

Dissolves: the master's file change (a new folder/file on its own channels)
and the slave's are two console changes; they land within one tick of each
other because the console sends both. The slave's dissolve runs on its own
`dissolveStart` as today; only the clock is shared.

### 23.4 What the UI shows

- Layers screen: a badge per layer, `M3` / `S3` (group), green locked,
  yellow freewheel, red lost or conflict, grey "no master"; the live
  offset (ms) in the layer detail.
- `live.layers[n].sync = {role, group, state, offsetMs, master: {machine, name, layer}}`
  and `live.sync = {interface, port, target, packetsPerSecond, masters: {group: {machine, name, layer}}, conflicts: [group]}`.
- Readiness (§14): "Sync groups have one master" (conflict or no master
  for a slave in use → yellow), "Sync packets arriving" (a slave in use and
  no packet for 2 s → yellow). Neither blocks show mode: a slave without a
  master plays on its own.
- System screen, section **Sync**: interface, port, target (broadcast or an
  address), packet totals in and out, machine id and name.
- `docs/user/multi-server.md`: two minis, one console, left/right halves
  with a blend, the three ways to split (slices on one full-canvas file,
  pre-split files, one canvas per machine), and the camera check.

### 23.5 Tests and the acceptance measurement

- Core: packet encode/decode round-trip and size; the band table of channel
  51 (`ParameterSpec`), the channel-map document and the GDTF include it.
- Engine, one Mac: two headless engines (own `FANOUS_HOME` and ports, as the
  test engines run today) with the same library, sync target 127.0.0.1.
  A's layer 1 master group 1, B's layer 1 slave group 1, same file, both
  playing: positions read from `/metrics` differ by < 1 frame for 60 s and
  do not trend; A retrigger → B's position follows within one tick; stop A's
  sender → B freewheel within 1.5 ticks, lost after 2 s, relocked on the
  next packet; a 25 fps file on B against a 50 fps file on A keeps the same
  time; a local group (layer 3 slaves layer 1 on one engine) has zero
  offset; two masters in one group → the lower id wins and `live.sync.
  conflicts` names it.
- Bench: writing the packet slot ≤ 10 µs at 32 master layers; the
  compositor's malloc count stays 0 (§4.6).
- Owner, two Mac minis and a camera (B60's acceptance): layer 1 on both
  shows the clock generator (0/112) or a frame-numbered test file, master on
  A, slave on B, a phone filming both projections at 240 fps. Pass: ≤ 1
  frame apart over 10 minutes with no trend, no visible stutter on the slave,
  a blend seam that does not breathe.

### 23.6 Later, on the same packet

A **hot backup** or **control from one place** (one project holding every
machine's outputs, followers reporting their displays and readiness, a
machine that mirrors the master's whole resolved state over the WSS
connection and takes the outputs over on a swap) was the first draft of this
section and stays designed for later (OPEN-27): the sync packet gives such a
follower its clocks, the WSS project patches give it the configuration. It is
not needed for the two-projector show, which is what B60 asked for.

### 23.7 Build order (one PR each)

1. **Docs**: this section, ADR-0021, backlog (this design).
2. **Core**: channel 51 in `ParameterSpec` (bands, resolver, channel-map
   document, GDTF) and the packet codec with its tests.
3. **Engine**: sender (compositor slot + thread), receiver (socket, table),
   the slave clock in `prepare`, freewheel/lost, `live.sync`, readiness
   items, settings and `project.set` for interface/port/target; the one-Mac
   two-engine test and the bench numbers. Engine-critical: Opus for agent and
   review, live check with two engines before the merge.
4. **UI and user doc**: badges, layer detail, System screen Sync section,
   `docs/user/multi-server.md`.
5. **Owner**: the two-mini camera test; then the B28 sACN network test on
   the same rig.

### 23.8 As built (step 3, 2026-10-28)

`Sources/FanousEngine/Sync/`: `SyncSender` (slot + thread), `SyncReceiver`
(socket, `SyncTable`), `SlaveClock` (the arithmetic of §23.3). Where it
differs from the text above:

- **`target` may carry a port** (`127.0.0.1:48812`): a unicast datagram to a
  port that two `SO_REUSEPORT` sockets share reaches only one of them
  (measured on macOS 27), so two engines on one Mac listen on different ports
  and each sends to the other's. `--no-network`: the receiver binds 127.0.0.1,
  only a 127.0.0.1 target is sent to, a broadcast target is ignored and
  logged. A target that does not parse sends nothing and is logged.
- **`interface: any`** is the first up, non-loopback IPv4 interface with the
  multicast and broadcast flags, not "the interface of universe 1"; resolved
  every 5 s on the sender thread.
- **`direction`** in the packet is the movement direction (reverse play mode
  × bounce direction), so a slave in any play mode asks its decoder for the
  right side.
- **Locked** means an entry younger than 1.5 ticks *or 50 ms*, so a 30 fps
  master against a 60 fps slave (a packet every other tick) stays locked.
- **Only the current file follows**: a dissolve's outgoing picture keeps its
  own clock. A layer that stops following gets direction forward and
  "not finished" back (the master's were never its own).
- **Freewheel wraps like a loop, lock clamps**: a shorter slave file holds its
  last frame while locked and loops while freewheeling.
- The slave's black end (`finished` with a once-black mode) comes from its
  own play mode; the packet has no such flag.
- **Local masters** go into the compositor's copy of the table right after
  their layer is prepared (a slave on a higher layer number sees the same tick,
  offset 0; a lower one sees the previous tick, extrapolated) and into the
  shared table at the end of the tick.
- **`offsetMs`** is the correction a locked tick applies: the entry's
  position against the slave's previous position advanced by the entry's
  rate (a whole-file jump, the master looping, does not count). "Implied minus
  shown" would be 0 by construction while locked.
- **Two masters**: the slave shows `conflict` while a second machine was seen
  in its group within the freewheel time, and follows the winner. Machine ids
  compare by their bytes, which is the order of their `uuidString`. Readiness
  "Sync groups have one master" also counts two masters in one group on this
  machine and a group in which another machine outranks this one, with or
  without a slave.
- A master in the Timecode play mode, or with in = out, sends rate 0: a
  remote slave is not extrapolated (it lags up to one tick plus the latency),
  stands still while freewheeling and plays no audio. A slave's audio plays
  when its master moves at 1× forward, without a loop region (its own in/out
  do not apply). Freeze-all on the slave machine holds a slave like any other
  layer; the first tick after it relocks.
- `live.sync` carries packet totals (`packetsIn`, `packetsOut`,
  `decodeErrors`) and the machine id instead of `packetsPerSecond`; the UI
  shows the totals. A master's `name` is shown for masters on this machine only.
- The two-engine check of §23.5 is manual (`docs/DEVELOPMENT.md`); the bench
  numbers are printed by `SyncCompositorTests`, which asserts no allocation.
- Step 4: **`sync.set {interface?, port?, target?}`** (programmer, refused in show mode) writes `settings.json` ›
  `sync` through `RoleAuth` and applies live (the receiver rebinds, the sender resolves its new target before the
  next packet), so the settings are no longer file-only. Folder 0 content (generators, Syphon) is a live source and
  neither sends nor follows, so the camera check of §23.5 uses a frame-numbered movie, not the clock generator.
