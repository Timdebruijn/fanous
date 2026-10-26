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
| **Output-N** (one per non-master display) | `Thread` + RunLoop + `CAMetalDisplayLink` | `.userInteractive` | output pass + present for that display | reads latest completed canvas texture via atomic index |
| **Decode-L** (one per layer) | `Thread` | `.userInitiated` | demux + decode for layer L, frame ring producer | preallocated pixel-buffer/texture pool, no allocations after warm-up |
| **HAP chunk pool** | fixed pool of P-core-count threads | `.userInitiated` | Snappy/DXT chunk decode for all HAP layers | work items are preallocated slots |
| **DMX** | serial `DispatchQueue` (Network.framework requires a queue) | `.userInteractive` | Art-Net/sACN receive, parse, universe buffers, parameter resolution | packet → parameters in one pass, no allocations; measured latency, see §13 |
| **Control** | serial `DispatchQueue` | `.userInitiated` | project model, commands, undo, cue engine, OSC, publishes scene config + parameter snapshots to render side | may allocate; never touched by render threads |
| **Audio out** | CoreAudio real-time render callback (`AVAudioSourceNode`) | RT | mixes per-layer PCM rings | RT-safe, no allocations/locks |
| **Audio in / LTC** | CoreAudio real-time input callback (`AVAudioSinkNode`) | RT | LTC bit decoding | RT-safe |
| **MIDI / MTC** | CoreMIDI callback thread | (CoreMIDI) | MTC quarter-frame assembly | no allocations |
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
  compositor reads the latest at the start of each tick. Values from internal
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
  applies after an engine restart (B51).
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
3. Done. The canvas texture index is marked complete in the command buffer's
   completion handler (CPU side), making it visible to output threads.

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
- Acceptance test (Phase 2): malloc count on the compositor thread over 1 000
  steady-state frames is **0**, measured with `malloc_zone_statistics`.
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

64 channels per layer = 8 layers per universe exactly. Channels 51–64 of the
Layer mode are **reserved** so that additions never change the footprint.
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
| 51–64 | Reserved | — | 0 | ignored |

Effect parameter semantics per effect are listed in `docs/channel-map.md`
(generated from `ParameterSpec` in Phase 1 so docs, GDTF, OSC and UI labels
can never disagree). `[OPEN-9]` exact bands and the speed/scale upper limits.

### 6.3 Master mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Master intensity | 16 | 65535 | multiplies all canvases |
| 3 | Control | 8 | 0 | 0–63 normal · 64–127 Freeze all · 128–191 Blackout · 192–255 reserved |
| 4 | Test pattern | 8 | 0 | 0–15 off · 16–31 Grid · 32–47 Colour bars · 48–63 Blend zones · 64–79 Output ID · 80–95 Crosshair/alignment · 96–111 Grey steps · 112–127 Checkerboard · 128–255 reserved — overrides every output |
| 5–6 | Master speed | 16 | 32768 | multiplies layer speed (same mapping as layer speed) |
| 7–8 | Reserved | — | 0 | |

### 6.4 Output mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping |
|---|---|---|---|---|
| 1–2 | Intensity | 16 | 65535 | output master |
| 3 | Control | 8 | 0 | 0–63 normal · 64–127 Blackout · 128–191 Freeze (hold frame) · 192–255 reserved |
| 4 | Test pattern | 8 | 0 | as Master ch 4, this output only |
| 5 | Blend | 8 | 0 | 0–127 blend/warp on (default) · 128–255 raw (bypass blend, warp, mask — for alignment) |
| 6–8 | Reserved | — | 0 | |

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
  status bar. Hold-vs-release is a project setting.
- The server answers `ArtPoll` with `ArtPollReply` (name, IP, port
  addresses; unicast back to the poller, one reply per Net/Sub-Net group of
  four ports) and sACN discovery (E1.31 universe discovery packets are
  received; the server advertises nothing in v1 as it only receives).
- sACN multicast groups are joined on the default-route interface until the
  per-protocol interface setting exists (Phase 5); unicast sACN on port 5568
  is accepted on every interface.
- `ArtSync` and E1.31 synchronization packets: when received, a universe
  update is applied at the sync packet, otherwise immediately.

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
  fragment: canvas.sample(uv) × mask(uv) × slice.opacity
            → × blendMap.factor + blendMap.lift                 (skipped when Output "raw" is set)
            → × output intensity × master intensity
            → test pattern override (if any)
            → blue-noise dither → drawable (bgra8 / bgr10 later)
```

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
  holds a copy per canvas a plan uses. A slice whose canvas does not render is
  skipped (black) and the coordinator logs it once per change.
- Preview: `canvas:<id>` targets ("canvas" = "canvas:1"), sized to their canvas;
  `layer:<n>` is made at its layer's canvas aspect and rebuilt when the layer
  changes canvas; output previews sample every canvas of the tick.
- Not built: Syphon for canvases other than canvas 1, CITP streams canvas 1
  only, a rate per canvas.

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

### 9.8 Syphon

**As built (2026-10-26, Syphon orientation):** Syphon surfaces hold the picture in OpenGL order (row 0 at the bottom). `SyphonOutput` publishes the canvas with `flipped: true` so OpenGL clients (Syphon Simple Client) and Metal clients both see it upright; `SyphonInput` reports `bottomUp`, and the compositor samples such frames with v0/v1 swapped (`Compositor.uvRect`), so crops keep their meaning. Before this the own round trip looked right while every other app saw the canvas upside down.

`SyphonMetalServer` per canvas, named `Fanous – <canvas name>`, published
from the compositor after the canvas pass with the same completed texture
(no copy; Syphon shares the IOSurface). Per-output Syphon (post-warp) later.

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
  iPad finds `https://<host>.local:8443`.
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
client → server   {"t":"sub","stream":"dmx","universe":"artnet:0:0:1"} / {"t":"sub","stream":"preview","target":"canvas:1","w":640,"h":360,"fps":30}
server → client   binary frames: [u8 kind][u32 streamId][payload]   kind 1 = H.264 AU (AVCC) , 2 = JPEG , 3 = DMX universe (512 B) , 4 = metrics ring page
```

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
  (`avc` with `description`) into a `<canvas>`.
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
  This layer (per browser, `localStorage`). B29 thumbnails can reuse
  `drawLayer` into an atlas; not built.

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

### 11.6 Phase 5 as built (2026-10-23)

- Transport: hand-written RFC 6455 framing on the HTTPS listener
  (`FanousCore/Protocol/WebSocket.swift`, SHA-1 in Core), `/ws` handled by
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
  all subscribers. Per-layer live thumbnails are deferred (B29).
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
  `TimecodeSource` interface.
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

### 15.4 MIDI

MTC only in v1 (§15.1). The CoreMIDI client, port enumeration and the
Show-control screen's MIDI section are built so that notes/CC → parameters,
MSC and MIDI-triggered cues are additions, not rewrites.

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
  reads full-frame SysEx. The compositor chases in the `timecode` play mode:
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
  screen shows. `/fanous/project/load` waits for project bundles (B35).
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
  preview, clients), `/api/logs` (ring tail), Bonjour `_fanous._tcp`,
  `live.system` (thermal, power, memory, OS, host, addresses, TLS fingerprint).
- **CITP/MSEX**: codec in Core (`CITP/CITP.swift`, `CITP/CITPMSEX.swift`:
  PINF `PLoc`/`PNam`, MSEX 1.0–1.2 `CInf`/`SInf`/`Nack`/`LSta`/`GELI`/`ELIn`/
  `GEIn`/`MEIn`/`GETh`/`EThn`/`RqSt`/`StFr`, little-endian, byte-exact tests);
  transport in Engine (`Net/CITPServer.swift`): one `NWListener` on an
  ephemeral TCP port, `PLoc` every 5 s to `224.0.0.180` and `239.224.0.180`
  (both groups, port 4809, a BSD socket: `NWConnection` does not deliver to
  multicast groups), per session the highest common version ≤ 1.2,
  `SInf` with one DMX source string per layer, `LSta` at 4 Hz from the layer
  status, libraries = numbered folders, elements = numbered files with their
  probed metadata, thumbnails from the library cache, streaming frames = the
  canvas JPEG from the preview path (≤ 10 fps, only encoded while a console
  streams), `Nack` for MSEX types we do not model. The server UUID is a
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
| **UI** | Vitest unit tests for the protocol client, state store and mapping-editor geometry; a Playwright smoke test against a mock server is `[OPEN-22]` | GitHub Actions |

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
blending, varispeed audio, browser end-to-end tests (OPEN-22) and the MDM
profile are the v1.x candidates.

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
| Main/backup failover (v2) | projects reference media by number; `live` is a replicable document; a backup engine subscribes to the main's state over WSS and runs the same DMX; outputs are switched by the operator (status bar "backup" slot reserved) |
| 3D projection mapping | the output pass already renders arbitrary meshes through a displacement field; a projected OBJ with a calibrated camera matrix replaces the slice mesh |
| 3D-model layers (media as texture on a mesh) | the layer pass is one quad in a perspective camera (§4.3); a mesh from Model I/O (USDZ/OBJ) with its own UVs replaces the quad, the fragment shader is unchanged; needs a depth attachment on the canvas pass and a "Geometry" parameter in the reserved Layer channels 51–64 (0 = flat, 1–255 = model from the library); `docs/BACKLOG.md` B9 |
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
| OPEN-12 | Folder 0 numbering for inputs/generators | **Decided 2026-10-25:** as in §8.2, plus 110 test card, 111 colour sweep, 112 clock (`Generators.names`) |
| OPEN-13 | HAP muxing via AVAssetWriter passthrough vs own muxer | **Resolved (Phases 2–4):** `AVAssetWriterInput` with a `sourceFormatHint` format description and passthrough sample buffers writes HAP `.mov` files the engine plays; no own muxer |
| OPEN-14 | Per-channel (RGB) blend gamma | v1.x, cheap |
| OPEN-15 | Audio varispeed / pitch at speed ≠ 100 % | v1.x; mute in v1 |
| OPEN-16 | `NWProtocolWebSocket` in server role vs hand-written framing | **Resolved in Phase 5**: hand-written RFC 6455 framing in `FanousCore/Protocol/WebSocket.swift` (SHA-1 for the accept key is in Core too, Foundation-only). `NWProtocolWebSocket` owns a whole listener, so it could not share port 8443 with the HTTP/1.1 routes and static files; the upgrade is handled by the existing HTTPS connection handler. |
| OPEN-17 | Downloadable CA profile for iPads | v1.x |
| OPEN-18 | Monitor role open by default when other roles have passwords | **Decided in Phase 5**: each role is open or protected independently; a client gets the highest role ≤ the one it asked for that its session cookie or shell token entitles it to, or that is open. Monitor stays open unless it has its own password. |
| OPEN-19 | Prometheus metrics endpoint | v1.x |
| OPEN-20 | MDM profile for show machines | later (owner's choice) |
| OPEN-21 | Trademark search for "Fanous" before public release | owner; `docs/RELEASE.md` §7 |
| OPEN-22 | Browser smoke tests (Playwright) | **v1.x** (B47): Vitest covers the client, store and screen helpers; the screens were checked by hand in Phases 5–7 |
| OPEN-23 | Library default location `~/Movies/Fanous Library` | yes |
| OPEN-24 | Default ports: HTTPS 8443, OSC 8000/8001; configurable | yes |
| OPEN-26 | Keychain strategy for unsigned development builds (prompt on every rebuild vs. ephemeral per-process identity) | **Decided 2026-10-23:** file-backed in-memory identity (`SecIdentityCreate`), no login keychain; ADR-0015 amendment |
| OPEN-25 | Register an Art-Net OEM code with Artistic Licence (free, needed for a proper `ArtPollReply`) | owner, `docs/RELEASE.md` §4; 0xFFFF until then |
