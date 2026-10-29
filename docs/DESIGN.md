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
    | Generators | +2–3 (derived) |
    | Each preview or thumbnail streamer | about +6 (derived: an encoder and a capturing handler) |
    | `present` | not measured |
    | Syphon publish | a capturing `addCompletedHandler` block per tick (`SyphonMetalServer.m`, B109); count not measured |
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
in v1; every mode is patched independently as its own fixture on the console:

| Mode | Footprint | Patched per | Purpose |
|---|---|---|---|
| **Layer** | 64 ch | layer (16 in v1, extensible) | everything about one layer |
| **Master** | 8 ch | server | master intensity, blackout, global test pattern, master speed |
| **Output** | 8 ch | output | per-output intensity, blackout/freeze, test pattern, blend on/off |
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
| 5 | Blend | 8 | 0 | 0–127 blend/warp on (default) · 128–255 raw (bypass blend, warp, mask — for alignment) |
| 6 | Mapping preset | 8 | 0 | 0 = as edited · 1–N = stored mapping preset N (decided 2026-10-28, built in M2, §9.9) |
| 7–8 | Reserved | — | 0 | |

A separate **Keystone** mode (16 ch, per output: four corners × X/Y, 16-bit
offsets on top of the edited mapping, centre = no change) is decided for M2
(§9.9); a new mode leaves the three existing modes and their footprints alone.

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
- Not built: per-packet receive interface (a routed console on another subnet
  is rejected by the subnet filter), Art-Net output/ArtAddress, per-address
  sACN priority (`[OPEN-10]`). Multicast delivery is not covered by the
  tests (it needs the Local Network permission); memberships are checked
  against the kernel, and the manual sACNView checklist in
  `docs/user/console-setup.md` covers delivery.

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
into the `ParameterSnapshot` the compositor reads:

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
| 1–32 | live inputs as configured in the project: Syphon servers in v1 (matched by app + server name), NDI/DeckLink later |
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
apps. The project-configured 1–32 above was only a plan and was never built;
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
│   │                 warp {cornerPin: 4 points, mesh: N×M control points (bezier), density}, test pattern
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

Both the per-pixel `factor` and `lift·(1−inOverlap)` are precomputed into one
`rg16Float` **blend map** texture per output on Control whenever the blend
settings change (edit-time cost only). Grid arrangements fall out naturally:
corner pixels multiply the horizontal and vertical factors. Per-channel
(RGB) gamma is `[OPEN-14]` (common projector need, cheap to add: `rgba16Float`
map).

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
clip space; UV = canvas rect. The mask path is rasterized on Control into an
`r8` mask texture at output resolution with the feather applied as a signed
distance → smoothstep, so feathering is exact and free at render time.

### 9.5 Output pass, summarized

```
for each slice (ordered):
  vertex:   mesh vertex → warp displacement → clip
  fragment: canvas.sample(uv) × scale × mask(uv) × slice.opacity (scale 1 live; frozen: master now / master at Freeze;
                                                                 a test pattern replaces this, whole output, no mask)
            → × blendMap.factor + blendMap.lift                 (skipped when Output "raw" is set)
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
holds the first canvas drawn above 0.

The black lift is the projector's black floor, so it does not follow the
Master: on content it stays at the output's level while the Grand Master moves
(it used to go down with it; on a test pattern it still does) and is 0 at
Master 0 and at an Output or Master Blackout. Master 0 or Blackout is black at
once also on a secondary display, which draws the last completed canvas.

One pass, no intermediate textures; "all output/mapping configuration is
applied entirely on the GPU in the final output pass" is satisfied.

### 9.5a Phase 6 as built (2026-10-23)

- Model (`FanousCore/Mapping/OutputModel.swift`) and edit-time math
  (`MappingMath.swift`, Foundation only, tested): blend map (two floats per
  pixel: factor and lift term), warp displacement field (homography for the
  corner pin, Catmull-Rom surface through the mesh points, evaluated
  separably), mask raster (signed distance with the feather, on a 4× coarser
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

**As built (2026-10-26, Syphon orientation):** Syphon surfaces hold the picture in OpenGL order (row 0 at the bottom). `SyphonOutput` publishes the canvas with `flipped: true` so OpenGL clients (checked with the Syphon Simple Client) and Metal clients that follow Syphon's GL-order convention see it upright; `SyphonInput` reports `bottomUp`, and the compositor samples such frames with v0/v1 swapped (`Compositor.uvRect`), so crops keep their meaning. Before this the own round trip looked right while every other app saw the canvas upside down.

`SyphonMetalServer` per canvas, named `Fanous – <canvas name>`, published
from the compositor after the canvas pass with the same completed texture
(no copy; Syphon shares the IOSurface). Per-output Syphon (post-warp) later.

**As built (2026-10-28, B69):** Syphon input numbers (§8.2, folder 0 files
150–169) are kept in the project and survive an engine restart; the engine's
own canvas servers are never numbered.

### 9.9 Projector walls and the M1 mapping tools (design 2026-10-28, `docs/mapping-ux.md`)

**Status:** approved 2026-10-28; M1 steps 1, 3, 4, 5 built (PRs #55, #47,
#54, #59), step 2 in PR #63 (as built below).

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
- Unlinked RGB keeps the single gamma ("in effect" until RGB gamma renders),
  with R, G, B below it; linking again drops them.
- The colour hints say colour gain is not built yet; the projector tile has the
  black floor only (0–20 %). Geometry sliders send on release (`wall.set` has
  no coalesce key); seam and floor sliders send at most every 50 ms.

**RGB gamma (OPEN-14).**
- `BlendEdge.gammaRGB: [Double]?`; nil means `gamma` for all three channels.
- The blend map becomes `rgba16Float`: factor R, G, B, plus the lift.
- The output fragment shader multiplies each channel by its own factor.

**Per-output colour.**
- `OutputConfig.color {gain: [r, g, b] (0…2, default 1), black (0…0.2,
  default 0)}`.
- The output pass applies `out · gain + black` next to the lift. That is still
  before the output and master intensity, so blackout stays black.
- It is set on the Outputs tab next to the Colour bars and Grey steps buttons,
  and for a wall output from the wall panel's projector tile.

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
- **M2:**
  - coverage-aware black lift
  - an on-output edit overlay
  - mapping presets on Output channel 6 (§6.4)
  - the Keystone mode (§6.4)
  - masks v2
- **M3:**
  - camera calibration, with an iPhone as the camera: Continuity Camera on
    the Mac first, then the iPad/iPhone browser camera once a trusted
    certificate exists (OPEN-17); both feed the same Mac-side solver
  - MPCDI 2D import

---

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

- Target: canvas, output (post-blend/warp, what the projector shows) or a
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
  `ProjectDocument.checkSyphonReplay` (B90, B91): every op on `/syphon/N`
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
item with a one-line fix): on AC power; thermal state nominal; free disk >
10 %; memory headroom; all patched universes receiving; all outputs bound
and in the desired mode; no decoder errors; library on a local volume;
Spotlight indexing of the library volume (`mdutil -s` state read via
`MDQuery`/`mdutil` output) off or acknowledged; automatic macOS updates
state (read from `com.apple.SoftwareUpdate` defaults) acknowledged; Time
Machine not currently backing up; Focus/Do Not Disturb cannot be read
reliably → shown as a manual checklist item; display sleep settings;
unsupported hardware (hard fail). Failed items block show mode until
acknowledged (programmer) — except hard fails.

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
/fanous/master/{param}        /fanous/output/{n}/{param}
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
thumbnail PNG) describing fixture type "Fanous" with the three DMX modes,
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
feedback, per-output Syphon, 10-bit output, per-channel blend gamma, frame
blending, varispeed audio and the MDM profile are the v1.x candidates.

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
| OSC feedback, MIDI notes/CC, MSC, timeline, varispeed audio, 10-bit output, per-channel blend gamma, frame blending, MDM profile, CA profile for iPads | noted in their sections |

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
| OPEN-12 | Folder 0 numbering for inputs/generators | **Decided 2026-10-25:** as in §8.2, plus 110 test card, 111 colour sweep, 112 clock (`Generators.names`); 150–169 other apps' Syphon servers (B61, 2026-10-27) |
| OPEN-13 | HAP muxing via AVAssetWriter passthrough vs own muxer | **Resolved (Phases 2–4):** `AVAssetWriterInput` with a `sourceFormatHint` format description and passthrough sample buffers writes HAP `.mov` files the engine plays; no own muxer |
| OPEN-14 | Per-channel (RGB) blend gamma | v1.x, cheap |
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
