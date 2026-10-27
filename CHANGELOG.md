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
- Per-universe settings on the Patch screen: protocol, interface, hold-on-loss and sACN priority (B28). sACN
  listens on all interfaces and shares its port with other sACN apps on the Mac; readiness warns about a
  missing or unusable interface and a failed sACN bind.
- Audio: forward loops are gapless (B3). Ingest makes rotated and flipped phone footage upright (B18).
  State sync and HTTP endpoints hide paths, host and TLS details from lower roles (B25). OSC burst
  regression tests; the reported loss is not reproducible (B30).
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
