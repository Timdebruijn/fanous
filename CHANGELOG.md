<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Changelog

Dates are the day the phase was committed on `main`. The design each phase
implements is `docs/DESIGN.md`; known limitations are in `docs/BACKLOG.md`.

## 1.0.0-rc.1 — unreleased (Phase 8, 2026-10-24)

- Hardening: one engine per user (`engine.lock`), cumulative frame counters in
  `/metrics`, show mode hides the cursor over the outputs.
- `scripts/soak.sh` (scripted Art-Net via `lanthorn-bench dmx`, 1 s samples,
  `kill -9` restarts, pass/fail report) and `docs/RELEASE.md`.
- Bundle: hardened runtime with `scripts/entitlements.plist`, microphone and
  local-network usage strings, `NSBonjourServices`; `scripts/notarize.sh`
  (notarytool, stapler, dmg).
- Shell: Engine menu with a live status line, Start / Restart / Stop Engine
  (stop removes the LaunchAgent registration).
- User documentation in `docs/user/`.
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
  output, `lanthorn-bench`.
- Phase 1: Art-Net/sACN, channel map, resolver with source policies, OSC
  server, LTC/MTC decoders, GDTF export, cue fade engine.
- Phase 0: package layout, licenses, CI checks, HTTPS with a generated
  certificate, app bundle script.
