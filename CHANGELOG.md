<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Changelog

Dates are the day the phase was committed on `main`. The design each phase
implements is `docs/DESIGN.md`; known limitations are in `docs/BACKLOG.md`.

## 1.0.0-rc.1 — unreleased (Phase 8, 2026-10-24)

- Renamed Lanthorn → **Fanous** (2026-10-25; name collisions, `docs/RELEASE.md` §7). Existing machine
  state moves once from `~/Library/Application Support/Lanthorn` and `~/Library/Logs/Lanthorn`.
- App icon and mark (a fanous lantern, `assets/`); UI fonts Atkinson Hyperlegible Next and Mono
  (Braille Institute, OFL), bundled with the UI, chosen for unambiguous glyphs when reading fast in the dark.
- Layer cap stays 32 for v1 (OPEN-8).
- Built-in content in folder 0: solid colour, the test patterns, a moving test card, colour sweep,
  clock and a frame-locked motion test (113), drawn on the GPU and selectable from the console or the UI.
  Layer status shows their size and "Built-in" instead of 0 × 0.
- Several canvases (up to 4): `canvas.add/remove`, a canvas per layer (`layer.set`) and per slice, one
  render pass per canvas, `canvas:<id>` previews; removing a canvas moves its layers and slices to
  canvas 1. Layers screen: a Canvas / This layer preview toggle (`layer:<n>` preview target). Show mode
  survives an engine crash, `kill -9` or Engine › Restart Engine: the engine resumes in show mode, keeps
  the display modes and shows a notice; a clean stop still leaves it. Outputs: Reset slice, Spread canvas
  (one picture across the slices of an object), Add slice fixed, only the selected slice has handles.
- Quitting the app asks whether to keep the engine running (default) or stop it too; logout and
  restart skip the question. Canvas size and frame rate are set on the Outputs screen and applied
  live (B31). Show mode applies each output's display mode and restores it afterwards (B33). UI
  values release only after masking a console for 10 minutes; Master and Output fixtures can be
  set from the Layers screen (B27).
- Project versions: `versions/` snapshots next to the project (start, show mode, every 10 minutes after a change, before a
  revert), named versions and Revert… on the System screen, undoable; OSC `/fanous/project/load` (B23, B35). A library root
  changed on the System screen takes effect at once, outside show mode and ingest (B51). Browser end-to-end tests with Playwright against a
  real engine, also in CI (B47). Syphon: the canvas arrives upright in other apps and Syphon inputs are sampled
  the right way up, effects included (B6). A scene may name a Syphon app without a server name
  (`"syphon": "App/"`): the first server of that app, for apps with a single server.
- Live layer thumbnails (B29): the Layers screen rows show each layer's own picture, 4 times a second, from one
  atlas pass on the GPU that runs only while someone watches (`sub {stream:"thumbs"}`); a layer that shows nothing
  keeps the library thumbnail. CITP consoles can stream single layers: `GVSr`/`VSrc` list the canvas and each layer
  as video sources (B41, scaling to a requested size still open).
- Layer channel 51 **Sync** (off / master group 1–8 / slave group 1–8) in the channel map, GDTF and OSC, and the
  `FSYN` clock packet codec; nothing sends or follows it yet (B60 step 2, DESIGN §23).
- Multi-server sync in the engine (B60 step 3): master layers send their clock on UDP 8002 (broadcast, or a unicast
  target in `settings.json` › `sync`), slave layers follow their group's master, freewheel and go lost after 2 s;
  `live.sync`, per-layer `sync` state, two readiness items and `sync` counters in `/metrics`. No UI yet.
- Multi-server sync in the UI (B60 step 4): `M3`/`S3` badges and the state in the layer detail, a "sync lost"
  status-bar item, System › Sync with the `sync.set` command for interface, port and target, and
  `docs/user/multi-server.md`.
- Per-universe settings on the Patch screen: protocol, interface, hold-on-loss and sACN priority (B28). sACN
  listens on all interfaces and shares its port with other sACN apps on the Mac; readiness warns about a
  missing or unusable interface and a failed sACN bind.
- Audio: forward loops are gapless (B3). Ingest makes rotated and flipped phone footage upright (B18).
  State sync and HTTP endpoints hide paths, host and TLS details from lower roles (B25). OSC burst
  regression tests; the reported loss is not reproducible (B30).
- Bonjour also advertises `_https._tcp` (TXT `path=/`) next to `_fanous._tcp`, so Bonjour browsers list
  the web UI with its port; `--no-network` advertises neither (B39).
- README rewritten around the console-as-controller story with screenshots and a tour GIF
  (`docs/images/`); the developer reference moved to `docs/DEVELOPMENT.md`; market research and
  positioning in `docs/marketing/positioning.md`.
- Test patterns reworked after a review: resolution-scaled lines, centred grid with border, aspect
  circle and diagonals, 100 % colour references, "Blend check" (was Blend zones), a readable output
  number, a 1 % black-level ramp.
- Fixed: opening the app showed no window when the engine was running (the engine registered as the app;
  it is now a helper app, `Contents/Helpers/FanousEngine.app`); service dialogs are sheets on the window;
  opening the app no longer restarts the engine in local builds.
- Fixed: periodic frame-drop bursts on a display output (two drawables blocked against the display's clock;
  now three, 0 missed in 6 min on the 120 Hz built-in panel).
- Review round (three review agents, then three fix branches):
  - Bugs: a projector could stay black after a display mode change; cue follow without a fade never fired;
    timecode triggers fired early across frame rates; malformed OSC numbers could crash the engine; output
    fixture numbers follow the output id; editing the cue list no longer shifts the current cue and removed
    cues release their values; dragging in the mapper is one undo step; warp sampled half a texel off;
    Output Freeze works; preview blend scaling.
  - Performance: no live updates without clients, DMX publishes only on change with O(1) lookups, no GPU
    work when nobody watches, static pictures and generators are not redrawn, decoders sleep on a full ring
    and pause after 2 s invisible, audio starts and stops with audio content, one preview stream per target
    (CITP always the canvas), timers only while used, HAP decodes in place, the UI pauses when hidden.
  - Usability: status chips next to the layer dots, Play on layer from the Media screen and a media picker
    in the layer panel, plain policy names, Show mode and lock in the status bar, a large GO with the next
    cue, bigger mapper handles with a nudge pad, handles that follow the warp, Undo toasts instead of
    confirmations, error messages with a next step, better contrast and 44 px targets, guidance after adding
    an output, physical values, empty states with an action, a shortcuts overlay.
- Fixed: mask and warp handles did not line up with the picture on outputs that are not 16:9 (the
  preview filled 16:9, the handles used the output's shape); the output preview now has the output's shape.
- Layers can be controlled from the UI (layer panel Control switch, `fixture.set`/`fixture.release`).
- Fixed: the first live document after a client joined could stall for seconds while the engine enumerated
  CoreMIDI and CoreAudio devices (over 5 s on the CI virtual machine: an empty status bar and no preview); the
  5 s refresh of those lookups also ran on the live feed. They now run off it, the first one at start, and a
  slow one is logged.
- Preview streams are sized to the browser (B32): 320, 640, 960 or 1280 pixels wide by the preview's width on
  screen, in the shape of what is shown; an output preview is no longer a 16:9 stream stretched into the output's
  shape. One encoder per target and size; past 4 encoders a new size of a target falls back to the nearest size it has.
- Fixed: the preview of a just added canvas was refused and stayed empty: it was asked for before the canvas
  rendered. A canvas preview now waits for the canvas switch, captioned "starting…", and one subscribed while the
  switch rebuilds the previews is no longer dropped as if its canvas were gone (B62 b).
- Fixed: after a refused preview request the next preview could stay on "connecting…": the refusal did not settle the
  waiting request, so the next reply went to the wrong one. A refused preview now names its stream (`error` with `id`
  and `stream`) and the UI shows "no preview" with the reason; a lost connection also settles waiting previews (B62 c).
- `npm run check` (svelte-check) type-checks the `.svelte` script blocks and applies Svelte's a11y rules, in
  CI's `web` job (B45). It found a type error in the preview's frame sizing (no behaviour change), a link
  announced as a status in the status bar (now a link inside a status element), a Preview prop read outside a
  reactive context, and two a11y warnings on the mapper SVG (ignored, with the reason in the source).
- Fixed: the preview of a just added (or undone) output was sometimes refused (about 1 in 30): clients got the
  project change before the engine's change handler ran. It now runs before any client hears of the change, so a
  client that asks for the preview of an output it was just told about finds it; the asynchronous parts (canvas
  switch, DMX patch, output windows) may still follow (B62).
- Fixed: a parallel `swift test` of the engine suite hung (every cooperative-pool thread waiting in `finishWriting`); the
  media-writing test helpers now run on a thread of their own and `scripts/test.sh` runs the tests in parallel again (B63).
- Fixed: a layer detail value changed just before picking another layer went to the newly picked layer (B80).
- Fixed: the GDTF's last channel set of Play mode, Control and other banded channels ran to 255 (a console showed
  "Scrub" for 144–255); the exporter now ends each with a set for the rest named after the band the engine decodes there (B72).

- Hardening: one engine per user (`engine.lock`), cumulative frame counters in
  `/metrics`, show mode hides the cursor over the outputs.
- `scripts/soak.sh` (scripted Art-Net via `fanous-bench dmx`, 1 s samples,
  `kill -9` restarts, pass/fail report) and `docs/RELEASE.md`.
- Bundle: hardened runtime with `scripts/entitlements.plist`, microphone and
  local-network usage strings, `NSBonjourServices`; `scripts/notarize.sh`
  (notarytool, stapler, dmg).
- Shell: Engine menu with a live status line, Start / Restart / Stop Engine
  (stop removes the LaunchAgent registration).
- User documentation in `docs/user/`.
- Fixed after Tim's first hands-on test: the app window answered every
  confirmation with "no" (removing an output did nothing) and ignored file
  pickers and downloads, because the web view had no UI delegate; test
  patterns were drawn flat over the output and ignored the warp, so aligning
  on a grid was impossible; the warp modes now say "Corner pin · 4 points" and
  "Mesh · up to 33 × 33"; ad-hoc rebuilds re-register the engine service (B54).
- 8 h soak on the M1 Pro passed (0 dropped frames, kill -9 → healthz 0.26 s,
  memory flat; `docs/benchmarks/soak-2026-10-24-0928.md`).
- Fixed: the engine renders without a scene file (the bundled agent did not);
  the project's source policy is applied (cues and OSC had no effect with the
  default `dmx`); sACN joins the patched universes, not 1–3; operators can
  switch timecode on and off (`timecode.enable`, also under show lock); the
  Patch screen has the source-policy selector.
- Fixed: an MTC source plugged in after the timecode source was set was only picked up after a settings
  change or an engine restart; MTC now reconnects when MIDI sources come and go. An unplugged MTC source
  is signal loss (Freewheel, then Lost after the freewheel time), leaves `live.timecode.device` at once,
  and `live.timecode.error` says "MTC source … is not connected" when none is left (B64).
- Syphon servers of other apps are layer content in folder 0, files 150–169, numbered in the order they
  appear and kept until the engine restarts (`live.syphon.servers`); the Media screen lists folder 0
  (generators and Syphon servers with their number and state) and the layer panel offers them. A layer on a
  server that went says "not running" (within about 11 s after a crash) and picks the picture up again when
  it returns (B61).
- The canvas preview's H.264 encoder is moved off the start path: on the CI virtual machine the engine sometimes
  never finished starting, its log ending at that step (B66). A preview's encoder is now made, for its first H.264 viewer, and released with
  the last; JPEG previews and CITP streaming need none. A browser that gets no H.264 description within 5 s falls back
  to JPEG (B66).
- The preview e2e tests wait up to 30 s on CI for the preview to stream (H.264 or JPEG) instead of 5 s (B81).
- Fixed: MTC timecode flickered between Locked and Freewheel while the sender ran; the lock window is now 1.5 times
  the source's update interval (MTC assembles a time every 2 frames, LTC decodes every frame) (B65).
- Fixed: CITP layer status and secondary displays read the parameter triple buffer beside the compositor, so the DMX
  writer could fill the slot the compositor was rendering from; they now read a copy the writer keeps (B71).
- Fixed: `roles.setPassword` and `sync.set` re-read `settings.json` and write only the role's password or the sync members
  given, so unknown fields, records that could not be read at start and hand edits to the other fields stay in the file; a
  file that does not parse is refused, not overwritten (B79).
- Fixed: a preview that was streaming stayed frozen ("no new frames") after a reconnect; it now lets go of its stream
  when the connection closes and subscribes again, once, when it is back (B68).
- Fixed: the 4 preview encoders bounded extra sizes only, so viewers on several targets could run more; the limit now holds
  across targets (a fallback size of the target or its canvas, else JPEG), and a released encoder goes to a viewer on a size or
  canvas fallback (a viewer refused to JPEG stays on JPEG in the browser, until B86) (B70). `/metrics` `preview.encoders` now counts H.264
  encoders: canvas 1 always, the others while they have an H.264 subscriber; JPEG-only streamers no longer count. It is a
  reservation count: for a few ms around an asynchronous release and create a fifth session can exist.
- Fixed: engine tests that slept a fixed time or waited a fixed budget failed in a parallel run on a loaded Mac; they now
  poll with a deadline or probe the listener first, so `scripts/test.sh` stays green under load (B67).
- Syphon numbers (folder 0, 150–169) are kept in the project (`syphon`), so they survive an engine restart; a server not
  seen since the start is listed greyed (`gone`), and `syphon.forget` (Media screen **Forget**) frees a number (B69).
- The §4.6 zero-malloc test counts only the compositor thread's allocations (a `malloc_logger` hook), not the process (B89).
- Fixed: removing a canvas ended the preview of a viewer that watched it only as a fallback (an output or layer at the
  encoder limit); it now keeps its own target when an encoder or another fallback is free, and an encoder the removal
  frees goes to a waiting viewer (B88).
- Fixed: the shell token test failed 1 run in 16, when the token ended in "0" (B84).
- Fixed: undoing `syphon.forget` overwrote a Syphon number another server had taken meanwhile; the undo is now refused (B90).
- Fixed: the preview left its H.264 decoder open after every target change and disconnect; it now closes it (B85).
- Fixed: a new `settings.json` (hashed role passwords) and the shell token file were readable by other users between the write
  and the change to mode 0600; both are now written 0600 from the start, and a new Application Support folder is 0700 (B83).
- A change of mesh density keeps the warp: the new points are placed on the current surface instead of a flat grid
  (points shared by both grids keep their position); **Reset mesh** still flattens (M1, DESIGN §9.9).
- Fixed: a role password added to `settings.json` by hand while the engine runs was kept in the file at the next write but
  the role stayed open until a restart; every write now takes the passwords from the file as written (B82).
- Fixed: a preview refused H.264 at the encoder limit waited 5 s and re-subscribed as JPEG, so it was never upgraded; it now
  shows the refused stream's JPEG frames at once and turns H.264 when the engine frees an encoder for it (B86).
- Fixed: an output preview on the canvas stream at the encoder limit was stretched to the output's shape; it is now
  letterboxed and its caption says "canvas fallback" (B87).
- Projector walls in the engine (M1.1, DESIGN §9.9): `walls` in the project and `wall.add/set/seam/seams/remove`. A wall
  of 1×2 … 4×4 outputs computes each projector's part of the canvas (slice 1's source) and the overlap of the inner blend
  edges, and keeps one gamma and curve per seam for both sides; `fit: "makeCanvas"` sizes the canvas to the wall. A hand
  edit of a wall output's source or inner overlap becomes manual and stays; editing one side of a seam moves the other.
  `output.remove` refuses an output that is in a wall, and `canvas.remove` moves a wall on that canvas to canvas 1 with
  its slices. `BlendEdge.gammaRGB` is stored but not rendered yet. No UI yet.
- Mapping, iPad remote mode on Warp & Slices (M1.4, DESIGN §9.9): a **Remote** toggle (on by default on touch screens
  narrower than 900 px, remembered per browser) with the selection in large type ("r3 c5", "corner top-left"),
  previous / next point row-major, select row, column, edge or all (the group moves as one, in one `output.set`), the
  nudge pad at 1 / 10 px with a long press for 0.25 px, and a trackpad area (1 output px per 4 CSS px, ×4 above
  600 px/s). Moves go out at most ten times a second, taps in between added up; nudges of the same point or group
  less than a second apart are one undo step. Tab / Shift-Tab step through the points in the mapper, Esc lets go; the
  nudge pad's long press also works outside remote mode.
- Seam-check test patterns (M1.5, DESIGN §9.9): Grey 0 %, Grey 25 %, Grey 75 % and White, flat fields at that output
  signal level (Blend check is the 50 % grey), on test-pattern channel 4 of the Master and Output fixtures at 128, 144, 160
  and 176 (192–255 stays reserved), in the GDTF and the channel map, and as buttons on the Outputs tab. They follow the warp
  and blend map like the other patterns; they are not layer content in folder 0 (Solid colour covers a flat field).
- Fixed: test patterns ignored the output's Intensity %, the Output and Master Intensity and both Blackouts, so a console's
  Grand Master or DBO left a full-field pattern (White is 100 %) on the projectors. Patterns now follow the same Dimmer and
  Blackout as the picture, Raw included; bring the Dimmer up to focus. Freeze holds the picture, not the pattern.

## 0.0.1 — Phases 0–7 (2026-10-22 … 2026-10-24)

- Phase 7: LTC/MTC timecode with layer chase, cue list with fades and
  triggers, the complete OSC address map, show mode with readiness checks,
  CITP/MSEX server, Show control and System / Health screens.
- Phase 6: multi-output with blend edges, corner pin and mesh warp, slices,
  masks, test patterns, display identity, Output fixture, Outputs & Mapping
  screen.
- Phase 5: WebSocket state sync with undo, roles and passwords, project
  autosave, H.264/JPEG preview streaming, Layers, Media and Patch / DMX
  screens.
- Phase 4: media library index with thumbnails, ingest queue (ProRes and HAP),
  image sequences, browser upload.
- Phase 3: the full layer feature set (transform, fit, crop, colour, blend
  modes, effects, dissolve, play modes), stills, Syphon, audio, Master fixture.
- Phase 2: ProRes and HAP decode, zero-copy textures, compositor, display
  output, `fanous-bench`.
- Phase 1: Art-Net/sACN, channel map, resolver with source policies, OSC
  server, LTC/MTC decoders, GDTF export, cue fade engine.
- Phase 0: package layout, licenses, CI checks, HTTPS with a generated
  certificate, app bundle script.
