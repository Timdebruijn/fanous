# Lanthorn — Design

Status: **Approved 2026-10-22** (defaults of §22 accepted) · Owner: Tim de Bruijn

Lanthorn is an open-source media server for live events, programmed from a
lighting console as if it were a fixture (Catalyst-style). This document is the
single design reference for v1. Key decisions are recorded as ADRs in
`docs/adr/`; where this document and an ADR disagree, the ADR wins. Open
questions are tagged `[OPEN-n]` inline and collected in §22.

Conventions: "engine" = the headless render process `lanthornd`; "shell" = the
native WKWebView host app; "client" = any UI (shell or browser); "console" =
the lighting desk sending DMX.

---

## 1. Goals, non-goals, priorities

**Priorities, in order:** 1) never drop a frame or lose an output during a
show, 2) predictable DMX behaviour, 3) a UI that shows at a glance what the
server is doing and why, 4) feature count.

**v1 scope** is the brief's "Scope v1" list plus the clarifications in
`docs/BRIEF.md` (audio, stills, image sequences, Syphon input, 3D layer
rotation, Output fixture). Everything under "Later" is designed for (an
extension point exists) but not built.

**Non-goals:** SMPTE ST 2110, generative/real-time 3D engines, XR, Windows,
Linux, Intel, base M1, a timeline editor.

**Platform floor:** Apple Silicon with a hardware ProRes engine. Minimum macOS
15 (ADR-0020; the brief said 14, raised with the owner's approval of `[OPEN-1]`).

---

## 2. Process architecture

```
┌──────────────────────────── Lanthorn.app ─────────────────────────────┐
│  Contents/MacOS/Lanthorn          shell: AppKit + WKWebView, no logic  │
│  Contents/MacOS/lanthornd         engine: headless, owns everything   │
│  Contents/Library/LaunchAgents/org.lanthorn.engine.plist              │
│  Contents/Resources/web/          built UI (static files)             │
└───────────────────────────────────────────────────────────────────────┘

   console ──Art-Net/sACN──▶ ┌──────────┐ ──Metal──▶ displays (outputs)
   OSC / MTC / LTC ────────▶ │ lanthornd│ ──Syphon─▶ other apps
   shell / browsers ◀─HTTPS─▶│          │ ──CoreAudio▶ audio device
   console ◀───CITP/MSEX───▶ └──────────┘ ──logs/metrics
```

### 2.1 Engine as a LaunchAgent in one bundle (ADR-0001)

- `lanthornd` is registered as a **LaunchAgent** via `SMAppService.agent(plistName:)`
  from the shell's first launch. It runs in the logged-in user's session (a
  LaunchDaemon cannot reach the WindowServer, so it cannot drive displays).
  `KeepAlive` restarts it within ~1 s after a crash; `RunAtLoad` starts it at
  login. Auto-login is a deployment choice for unattended machines, not a
  requirement: the user starts `Lanthorn.app` like any app, the app starts the
  agent if it is not running. macOS asks once to allow the agent under
  System Settings › Login Items; the shell detects "not approved" and shows a
  banner with the exact step.
- The shell is disposable: it only hosts the UI. Quitting it does not stop the
  engine. It also offers Start/Stop/Restart engine, "Open logs", "Install /
  remove service" and the About screen (attribution, see §17).
- The engine can also run in the foreground for development
  (`swift run lanthornd --foreground --project X`). Same binary, no agent.
- The engine creates its output windows itself. It runs an `NSApplication`
  with activation policy `.accessory` (no Dock icon, no menu bar), so it can
  create borderless fullscreen windows at shielding window level on any
  display without ever becoming the frontmost app.
- One instance per user: a lock file in `~/Library/Application Support/Lanthorn/`.
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

---

## 3. Module / package layout (ADR-0003)

One SwiftPM package, `Package.swift` at repo root, plus the `web/` frontend.

```
Lanthorn/
├── Package.swift
├── Sources/
│   ├── LanthornCore/        pure Swift, Foundation only. Unit-testable on any Mac.
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
│   ├── LanthornEngine/      Metal, AVFoundation, VideoToolbox, CoreAudio, CoreMIDI, Network.framework
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
│   ├── LanthornPluginAPI/   C header + Swift shim: the plugin ABI (design only in v1)
│   ├── CHap/                vendored Vidvox hap.c/.h (BSD) — C target
│   ├── CSnappy/             vendored google/snappy (BSD-3) — C++ target
│   ├── Syphon/              vendored Syphon-Framework sources (BSD) — ObjC target
│   ├── lanthornd/           executable: wiring, CLI flags; serves web/dist (located at runtime, see below)
│   ├── LanthornShell/       executable: AppKit app, WKWebView, SMAppService, About
│   └── lanthorn-bench/      executable: benchmark harness
├── Tests/
│   ├── LanthornCoreTests/   protocol fixtures (captures), parameter/channel map, GDTF, cues, mapping math
│   ├── LanthornEngineTests/ golden images, decode spikes — Apple Silicon only
│   └── Fixtures/            captures/*.bin + .pcapng, golden/*.png, media/ (generated)
├── web/                     Svelte 5 + Vite + TypeScript; builds to web/dist (copied into the .app by bundle.sh)
├── scripts/                 bundle.sh (assemble .app), sign.sh, license-headers.sh, fixtures.sh
└── docs/
```

Rules enforced by CI (Phase 0): `LanthornCore` imports only `Foundation`
(a test greps for other imports); every source file starts with the SPDX
header; no new package dependencies without an entry in
`docs/licensing/DEPENDENCIES.md`.

The `.app` bundle is assembled by `scripts/bundle.sh` from SPM products
(no Xcode project): Info.plist, LaunchAgent plist, embedded `lanthornd`,
`web/dist` as `Contents/Resources/web`, entitlements, then `codesign` +
`notarytool`. The engine locates its web root at runtime (`--web-root`,
`$LANTHORN_WEB_ROOT`, `Contents/Resources/web`, or `web/dist` relative to a
development build) instead of using SPM resources, so one binary serves both
the bundle and `swift run`. Bundle identifiers: `org.lanthorn.app` (shell),
`org.lanthorn.engine` (agent) (`[OPEN-2]`, decided: `org.lanthorn`).

---

## 4. Decode → render pipeline (ADR-0004, ADR-0005, ADR-0006)

### 4.1 Sources

Every layer plays a `Source`. All sources deliver `Frame`s to the same ring
contract; the compositor does not care where a texture came from.

| Source | Demux | Decode | Texture path | Notes |
|---|---|---|---|---|
| ProRes 422 (Proxy/LT/422/HQ) | `AVSampleCursor` + `AVSampleBufferGenerator` (random access, all-intra) | `VTDecompressionSession`, hardware required (`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`) | IOSurface-backed `CVPixelBuffer` in the decoder's native packed 16-bit 4:2:2 format `v216` (`kCVPixelFormatType_422YpCbCr16`) → `MTLTexture` made directly from the IOSurface as `rgba16Unorm` at **half width** (one texel = Cb, Y0, Cr, Y1) | Apple names `v216` as the most native output of the hardware decoder (WWDC20 10090); the layer shader unpacks the pair and converts YCbCr→RGB (Rec.709/2020 per track). Zero copy. |
| ProRes 4444 / 4444 XQ (with alpha) | same | same | native `y416` (`kCVPixelFormatType_4444AYpCbCr16`, packed A Y Cb Cr 16-bit) → `rgba16Unorm` texture from the IOSurface, swizzled in-shader | the delivered format is asserted at runtime; if a decoder ever delivers something else the layer logs it and falls back to a `VTPixelTransferSession` on its decode thread (`[OPEN-3]`) |
| HAP / HAP Alpha / HAP Q / HAP Q Alpha / HAP Alpha-only | same (compressed samples only) | `hap.c` `HapDecode` with chunk callback → Snappy on the HAP chunk pool; DXT bytes written straight into a pooled shared-storage `MTLBuffer` | blit `MTLBuffer` → `MTLTexture` (`bc1_rgba`, `bc3_rgba`, `bc4_rUnorm`; HAP Q = `bc3` interpreted as scaled YCoCg in shader; HAP Q Alpha = two textures) | CPU-bound (Snappy); unified memory means the "upload" is a GPU-side copy, no PCIe. HAP R (`bc7`) is the same path later. |
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
   - Effects are branches of one uber-shader selected by a function constant
     per (effect-1, effect-2) combination, compiled lazily and cached on
     first use (a pipeline-state cache keyed by the combination; the first
     use of a new combination is compiled on Control, never on the
     compositor, and the layer uses the "no effect" pipeline until the
     specialized one is ready). Neighbourhood effects (blur, pixelate,
     kaleidoscope, edge) sample the *source* texture multiple times; no
     intermediate textures.
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
| Media-engine count, max external displays | **static table** keyed by chip name (`LanthornCore/Capabilities`), marked "Apple spec" in the UI, with `unknown` fallback → conservative tier and a yellow "unknown chip, benchmark recommended" status |
| Thermal / power | `ProcessInfo.thermalState`, `IOPSCopyPowerSourcesInfo` (on battery = yellow) |

Unsupported machine (no hardware ProRes, i.e. base M1 / Intel): the engine
starts, shows a red "unsupported hardware" status, and refuses to enter show
mode. Development on such a machine still works for the UI.

### 5.2 Tiers

Tiers group chips by media-engine count and GPU/bandwidth class. Layer counts
below are **initial expectations** derived from Apple's published ProRes stream
counts and bandwidth; they are replaced by measured numbers from
`lanthorn-bench` (Phase 2) and stored per machine. The UI shows the measured
numbers for *this* machine when available, otherwise the tier expectation
labelled "not yet benchmarked".

| Tier | Chips | Media engines (Apple spec) | Expected max layers, canvas 1080p60 | Expected max layers, canvas 4K60 | Notes |
|---|---|---|---|---|---|
| **1 Base** | M2, M3, M4, M5 | 1 | 6 × 1080p60 ProRes 422 HQ · 8 × 1080p60 HAP Q | 2 × 4K60 ProRes HQ · 3 × 4K60 HAP Q | 8 GB/16 GB memory limits ring depth; 2 external displays |
| **2 Pro** (reference: M1 Pro) | M1 Pro, M2 Pro, M3 Pro, M4 Pro, (M5 Pro) | 1 | 8 × 1080p60 ProRes 422 HQ · 12 × 1080p60 HAP Q | 4 × 4K30 / 2–3 × 4K60 ProRes HQ · 4 × 4K60 HAP Q | all v1 acceptance criteria are defined on this tier first |
| **3 Max** | M1 Max, M2 Max, M3 Max, M4 Max, (M5 Max) | 2 | 16 (cap) | 8 × 4K60 ProRes HQ · 8 × 4K60 HAP Q | 4 external displays |
| **4 Ultra** | M1 Ultra, M2 Ultra, M3 Ultra | 4 | 16 (cap) | 16 (cap) | 5+ displays |

Tier knobs the engine sets automatically (overridable in System settings):
frame-ring depth, HAP chunk-pool size, canvas precision (`rgba16Float`
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

The server exposes **one GDTF fixture type, "Lanthorn", with three DMX modes**
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

`LanthornCore/Parameters/ParameterSpec.swift` is the single source of truth:

```swift
struct ParameterSpec {
  let id: ParameterID            // .layer(.intensity), .master(.control), .output(.testPattern)
  let name: String               // "Intensity"
  let kind: Kind                 // .continuous(range, unit) | .enumerated([Band]) | .discrete(0...255)
  let dmx: DMXEncoding           // .u8(channel) | .u16(coarse, fine)
  let defaultRaw: UInt16
  let osc: String                // "intensity" → /lanthorn/layer/{n}/intensity
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
| Internal: UI override | programmer-set values (only while "override" is on in the UI; auto-expires after 10 min to avoid show-time surprises) | on command |

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
`~/Movies/Lanthorn Library`), local volumes only (network volumes are rejected
with an explanation). Catalyst-style numeric prefixes:

```
Lanthorn Library/
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
  `~/Library/Application Support/Lanthorn/cache/` keyed by path + mtime + size.
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

`[OPEN-12]` final numbering of folder 0.

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
- HAP muxing through `AVAssetWriter` passthrough is a Phase 4 spike; the
  fallback is a small all-intra QuickTime muxer in `LanthornEngine/Ingest`
  (`[OPEN-13]`).
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
├── Canvas[]          id, name, size (px), background, layer assignment (fixed in patch), clock-master output
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

`SyphonMetalServer` per canvas, named `Lanthorn – <canvas name>`, published
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
  in `LanthornCore/Protocol` (small, unit-tested) on top of Network.framework
  TLS connections; no web framework. `[OPEN-16]` evaluate
  `NWProtocolWebSocket` in server role in the Phase 5 spike; if it works on
  the same listener it replaces the hand-written framing.
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
- Bonjour: `_lanthorn._tcp` and `_https._tcp` advertised so a browser on the
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
  `[OPEN-18]` whether "monitor" should be open by default even when others
  are protected.
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

### 11.4 Frontend (ADR-0012)

Svelte 5 (runes) + Vite + TypeScript strict, Vitest for unit tests; no UI
component library, no router library (six screens, hash routing in 30
lines), no runtime CDN loads. Chosen over Preact because fine-grained compiled
reactivity updates exactly the DOM nodes that changed when 1 000+ live values
tick at 20 Hz, with no virtual DOM diff and a smaller runtime; the UI must
stay smooth on an iPad while the mapping editor renders an SVG overlay over a
live preview.

Structure: `web/src/{lib/protocol,lib/state,screens/*,components/*}`; the
protocol types are generated from `LanthornCore/Protocol` (a small Swift
script emits `protocol.d.ts` in Phase 5) so client and server cannot drift.

Touch: Pointer Events everywhere; the mapping editor's handles are ≥ 44 px
hit targets, two-finger pan/zoom, numeric fields with a stepper and keyboard
arrows (±1 fine, ±10 coarse with Shift, ±0.1 with Alt).

### 11.5 Undo, redo, versioning

- One **global** undo history on the server (commands with inverses),
  shared by all programmer clients, 500 entries, cleared on project load.
  Show-lock/unlock and cue *go* are not undoable (they are not config).
- Project format: a directory bundle `Name.lanthorn/` with `project.json`
  (schema-versioned, migrated on load), `versions/` (one JSON snapshot per
  change burst, debounced 2 s; keep last 200 + one per day for 90 days +
  all named versions), `thumbs/` (cache). Snapshots are full documents
  (they are small); diffs between any two versions are shown in the UI.
- Auto-save after every command burst; "named version" and "revert to…" are
  commands themselves (and therefore undoable).
- Machine settings (library root, interfaces, audio devices, TLS identity
  reference, role passwords, last project) live outside the project in
  `~/Library/Application Support/Lanthorn/settings.json`.

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
file in `~/Library/Logs/Lanthorn/` (10 × 10 MB). Log lines in hot paths are
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
  real-time thread; the biphase-mark decoder in `LanthornCore/Timecode` is
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
/lanthorn/layer/{1..n}/{param}  f (normalized 0–1 or unit value; both accepted via type tag)   e.g. /lanthorn/layer/3/intensity 0.75
/lanthorn/layer/{n}/media       ii (folder, file)
/lanthorn/layer/{n}/retrigger
/lanthorn/master/{param}        /lanthorn/output/{n}/{param}
/lanthorn/cue/go  /cue/back  /cue/goto i  /cue/{number}/go
/lanthorn/show/lock i  /lanthorn/show/mode i  /lanthorn/timecode/enable i
/lanthorn/project/load s (programmer; refused while show-locked)
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
  status: media, position, playing state at 4 Hz), `ELIn`/`EInf` (element
  libraries = folders, elements = files with names/dimensions/fps/length),
  `EThn` (JPEG/RGB8 thumbnails from the library cache), `StFr` (streaming
  frames of a layer or canvas, JPEG, ≤ 320 px, rate as requested up to
  10 fps, from the live-thumbnail path).
- Implementation in Core (packets) + Engine (transport). Fixtures: packet
  captures from free console software (grandMA3 onPC, ETC Eos Nomad,
  ChamSys MagicQ PC, Vista) since no hardware console is available yet;
  interop with those is the Phase 7 acceptance test.

### 16.2 GDTF export

`Patch › Export GDTF` writes `Lanthorn.gdtf` (zip: `description.xml` +
thumbnail PNG) describing fixture type "Lanthorn" with the three DMX modes,
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

## 17. Licensing setup (ADR-0015)

| File | Content |
|---|---|
| `LICENSE` | Verbatim GNU GPL v3 text, unmodified so license scanners recognise it; the notice "GPL-3.0-only with additional terms under section 7, see `LICENSE-ADDITIONAL-TERMS.md`" is in `README.md` and in every source header. |
| `LICENSE-ADDITIONAL-TERMS.md` | The two §7 additions: (b) attribution preservation (text in `docs/licensing/ATTRIBUTION.md`), and the additional *permission* for plugins (`docs/licensing/PLUGIN-EXCEPTION.md`, DRAFT until lawyer-reviewed; shipped only after review). |
| `docs/licensing/ATTRIBUTION.md` | exact wording of the attribution term and the exact strings the About screen and web footer must show |
| `docs/licensing/PLUGIN-EXCEPTION.md` | DRAFT additional permission for linking plugins against proprietary SDKs via `LanthornPluginAPI` |
| `docs/licensing/CLA.md` | Individual + Entity CLA text granting copyright and patent licenses with the right to sublicense and relicense (enables the commercial license) — DRAFT for lawyer review |
| `docs/licensing/DEPENDENCIES.md` | every dependency (server, vendored C/ObjC, web build-time and runtime), version, license, GPLv3 compatibility, how it is pinned |
| `CONTRIBUTING.md` | CLA requirement (DCO is not enough), how signing works, coding rules (SPDX header, Core purity, no new dependencies, tests), review process |
| `TRADEMARKS.md` | name and logo policy: code under GPL, name/logo not |
| Source headers | `// SPDX-License-Identifier: GPL-3.0-only` + `// Copyright (c) 2026 Tim de Bruijn` + `// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md` — the pointer line is what GPLv3 §7 requires when additional terms exist. A LicenseRef expression would be more SPDX-pure but makes license scanners stop recognising GPL; the ADR records the trade-off. `scripts/license-headers.sh` checks every `.swift`, `.metal`, `.c/.h`, `.ts`, `.svelte`, `.css`, `.sh` file in CI. |
| CLA tool | **cla-assistant (SAP)**, hosted at cla-assistant.io (or self-hosted) as a GitHub App: blocks merge until the PR author has signed the CLA stored in the repo; `contributor-assistant/github-action` is archived and EasyCLA is LF-only. Enabled when the repository goes public; until then the CLA text already lives in the repo. |
| About / footer | shell About window and web footer render the attribution string from one constant in `LanthornCore` (`Attribution.text`), with the repository link; a UI test asserts both render it. The About screen also carries the third-party notices, including the Art-Net credit Artistic Licence requires. |

Dual licensing: the author is the sole copyright holder; every external
contribution is covered by the CLA, so the whole can also be offered under a
commercial license. Vendored BSD code (hap, snappy, Syphon) keeps its own
notices in `THIRD-PARTY-NOTICES.md` and is compatible with both licenses.

Release checklist items that come from this section: remove `docs/BRIEF.md`;
lawyer review of `PLUGIN-EXCEPTION.md`, `CLA.md` and `ATTRIBUTION.md`;
trademark search for "Lanthorn" (`[OPEN-21]`).

---

## 18. Testing strategy

| Level | What | Where it runs |
|---|---|---|
| **Unit (Core)** | every parser/builder (Art-Net, sACN, OSC, CITP, LTC, MTC, HTTP/WS framing), channel map ↔ units, GDTF XML against the XSD, cue fades, blend/warp math, project migrations, JSON patch/undo | GitHub Actions `macos-26` (no GPU needed) and locally via `scripts/test.sh`; Swift Testing |
| **Protocol fixtures** | real packet captures: `Tests/Fixtures/captures/<protocol>/<source>-<desc>.bin` (raw UDP/TCP payloads extracted from `.pcapng` kept next to them with provenance in `README.md`). Sources in v1: grandMA3 onPC, Eos Nomad, MagicQ PC, QLC+, sACNView, plus hand-built edge cases (sequence wrap, priorities, sync packets, malformed lengths). Fuzz-style tests mutate fixtures and assert no crash | same |
| **Golden images** | deterministic scenes (synthetic textures, fixed parameters) rendered through the real compositor and output pass, read back, compared to PNGs with per-channel tolerance (±2/255) and a diff image on failure: blend modes, effects, transforms, dissolve, blend maps, warp, masks, test patterns, YCbCr/YCoCg conversion | Apple Silicon only: locally and on a self-hosted runner when available; skipped (not failed) on hosted CI |
| **Decode conformance** | one sample file per codec variant (generated by the ingest encoder from a synthetic source, checked against known pixel values) | Apple Silicon |
| **Allocation / latency** | 0 mallocs on the compositor thread over 1 000 frames; DMX→photon p99 under the tier's limit | Apple Silicon |
| **Benchmark** | `lanthorn-bench`: generates media (codec × resolution × fps), ramps layer count until any frame drops within 60 s, confirms with a 10-minute soak at the found count, with 0 and 4 preview clients; writes `docs/benchmarks/<chip>-<date>.json/.md` and the tier record the UI shows | Apple Silicon; first on the M1 Pro reference machine |
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
| **0 — Skeleton** | Package layout, CI, license files, SPDX headers, `web` scaffold, `scripts/bundle.sh`, empty `lanthornd` that starts, serves the UI shell page over HTTPS with the generated certificate, and logs | `swift build` + `swift test` green on hosted CI; `.app` assembles, signs ad-hoc and launches; TLS identity generated and pinned by the shell; license-header and Core-purity checks pass; `DEPENDENCIES.md` complete |
| **1 — Core protocols & parameter model** | Art-Net/sACN receive + merge, universe model, `ParameterSpec`, channel map, resolver with source policies, OSC server, LTC/MTC decoders, GDTF export, cue fade engine, `docs/channel-map.md` generated | all fixture captures pass; footprint test locks 64/8/8; GDTF validates against the XSD and imports into grandMA3 onPC and Eos Nomad; OSC and DMX drive the same resolver in tests; LTC decoder locks on a generated 25/29.97DF file within 2 frames |
| **2 — Render spike & benchmark** | ProRes and HAP decode via sample cursor + VT / hap.c, zero-copy textures, compositor with intensity/position/scale, one canvas, one output, display link, instrumentation, `lanthorn-bench` v1, DMX→photon estimate | **spike results written down**: native ProRes pixel formats confirmed IOSurface-backed and used without conversion; HAP chunk decode parallelism measured; benchmark on the M1 Pro: tier-2 numbers recorded for 1080p60/4K30/4K60 × ProRes HQ/HAP Q; 0 mallocs per frame; `preferredFrameLatency 1` holds at the measured layer count; DMX→photon p99 ≤ 2 frames + display |
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
| R6 | TLS identity in the keychain from a LaunchAgent (prompts, ACLs) | first-run friction | Phase 0 spike; fallback: identity stored as PKCS#12 in Application Support (0600) and imported into an in-memory keychain at start |
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

---

## 21. Designed-for-later features (not built in v1)

| Feature | Extension point already in the design |
|---|---|
| NotchLC decode in Metal | `Source` protocol + compute-shader decode stage before the ring; **blocked on licence** (R11) |
| HAP R | `bc7_rgbaUnorm` in the HAP texture path; ingest encoder flag |
| NDI in/out, DeckLink in/out | `LanthornPluginAPI` (ADR-0016): C ABI, `dlopen`ed from `~/Library/Application Support/Lanthorn/Plugins/`, sources hand over IOSurfaces into the same frame rings; sinks subscribe to completed canvas textures like Syphon |
| Pixel mapping to DMX fixtures | Art-Net/sACN *builders* already exist in Core (needed for tests); a GPU sampling pass reads canvas regions into a small buffer per universe on the preview thread |
| Main/backup failover (v2) | projects reference media by number; `live` is a replicable document; a backup engine subscribes to the main's state over WSS and runs the same DMX; outputs are switched by the operator (status bar "backup" slot reserved) |
| 3D projection mapping | the output pass already renders arbitrary meshes through a displacement field; a projected OBJ with a calibrated camera matrix replaces the slice mesh |
| Serial device fixture | fixture type in `ParameterSpec`; POSIX termios on `/dev/cu.*`, no dependency |
| OSC feedback, MIDI notes/CC, MSC, timeline, varispeed audio, 10-bit output, per-channel blend gamma, frame blending, MDM profile, CA profile for iPads | noted in their sections |

---

## 22. Open questions

| ID | Question | Proposed default |
|---|---|---|
| OPEN-1 | Raise the minimum macOS from 14 to **15**? Gains: stdlib `Synchronization` (`Atomic`, `Mutex`, macOS 15+) instead of swift-atomics (whose own README says it is superseded), one dependency fewer; macOS 14 Sonoma received its last update in Aug 2026 and is absent from the Sep 2026 security batches (verified 2026-10-22), i.e. outside Apple's n-2 window now that macOS 27 is out. CAMetalDisplayLink needs 14+, so 15 keeps everything in the brief. Metal 4 (macOS 26+) is not needed. | **Decided 2026-10-22: 15** |
| OPEN-2 | Bundle identifier / reverse-DNS prefix | **Decided: `org.lanthorn`** (`org.lanthorn.app`, `org.lanthorn.engine`) |
| OPEN-3 | Native pixel formats of the hardware ProRes decoder (422 bi-planar 10-bit; 4444 with alpha) | decided by the Phase 2 spike |
| OPEN-4 | Optional frame blending for rate-mismatched content | v1.x |
| OPEN-5 | 10-bit output drawables (`bgr10a2`/`rgba16Float` with EDR off) | v1.x; blue-noise dither in v1 |
| OPEN-6 | Keep the chip capability table in `docs/hardware.md` and in Core; who verifies new chips | owner verifies per generation |
| OPEN-7 | Serial fixture in v1 or v1.x | v1.x |
| OPEN-8 | Engine hard cap on layer count | 32 |
| OPEN-9 | Exact DMX bands (play modes, effects), speed max 400 %, scale max 800 % | as in §6.2; review before Phase 1 locks the GDTF |
| OPEN-10 | sACN per-address priority (0xDD start code) | not in v1 |
| OPEN-11 | Per-parameter smoothing vs a global switch | per parameter, default off |
| OPEN-12 | Folder 0 numbering for inputs/generators | as in §8.2 |
| OPEN-13 | HAP muxing via AVAssetWriter passthrough vs own muxer | spike in Phase 4 |
| OPEN-14 | Per-channel (RGB) blend gamma | v1.x, cheap |
| OPEN-15 | Audio varispeed / pitch at speed ≠ 100 % | v1.x; mute in v1 |
| OPEN-16 | `NWProtocolWebSocket` in server role vs hand-written framing | spike in Phase 5 |
| OPEN-17 | Downloadable CA profile for iPads | v1.x |
| OPEN-18 | Monitor role open by default when other roles have passwords | yes |
| OPEN-19 | Prometheus metrics endpoint | v1.x |
| OPEN-20 | MDM profile for show machines | later (owner's choice) |
| OPEN-21 | Trademark search for "Lanthorn" before public release | owner |
| OPEN-22 | Browser smoke tests (Playwright) | Phase 5 if cheap |
| OPEN-23 | Library default location `~/Movies/Lanthorn Library` | yes |
| OPEN-24 | Default ports: HTTPS 8443, OSC 8000/8001; configurable | yes |
| OPEN-25 | Register an Art-Net OEM code with Artistic Licence (free, needed for a proper `ArtPollReply`) | owner, before 1.0; 0xFFFF until then |
