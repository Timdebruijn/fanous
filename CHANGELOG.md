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
- Test patterns reworked after a review: resolution-scaled lines, centred grid with border, aspect
  circle and diagonals, 100 % colour references, "Blend check" (was Blend zones), a readable output
  number, a 1 % black-level ramp.
- Fixed: opening the app showed no window when the engine was running (the engine registered as the app;
  it is now a helper app, `Contents/Helpers/FanousEngine.app`); service dialogs are sheets on the window;
  opening the app no longer restarts the engine in local builds.
- Layers can be controlled from the UI (layer panel Control switch, `fixture.set`/`fixture.release`).

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
