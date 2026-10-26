<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Fanous: market, demand and positioning

Research of 2026-10-26: three web and code surveys (market landscape, user
demand, our own strengths), condensed. Prices and facts carry their source; a
web survey is not a legal or exhaustive market study. Use this file as the
briefing for README, website and talks, and update it when facts change.

## 1. The market in one picture

The price and platform comparison with sources is kept out of the repository.

**Reading:** console-driven playback with CITP/GDTF lives in quote-only
hardware (disguise, Pixera, Hippotizer, Ai, Mbox) or ended (Catalyst, Katrin).
Mac software that is affordable (Resolume, Millumin, MadMapper, QLab) is built
around its own GUI, not around being a console fixture. Nobody found offers a
free, open, console-first media server on Apple Silicon with GDTF and CITP.

## 2. What users ask for (evidence is directional, mostly forums)

1. **Console integration that actually works:** thumbnails over CITP/MSEX,
   reliable layer control from the desk. MA forum 2022: "Is CITP implemented?"
   "Not yet"; Pixera docs: thumbnail exchange does not work with grandMA3;
   Resolume staff: CITP "not on our roadmap"; Vista users hand-build folder
   structures to get thumbnails; Resolume DMX clip triggers misfire (2024).
2. **Cost, licences, dongles:** dongles showing unlicensed before a show
   (Resolume forum 2024), subscriptions that block opening a project, paid
   spares for backup machines, educational licences as a "deal breaker"
   (ControlBooth 2026).
3. **Reliability and offline operation:** "If our production network is down,
   we don't have a show" (ControlBooth 2026); macOS updates breaking tools.
4. **Low-cost, volunteer-friendly operation** for churches, schools and small
   theatres; "steep learning curve" of consoles and servers.
5. **Affordable multi-projector blending and mapping** (mapping is a paid tier
   almost everywhere).
6. **No credible open-source option** exists for console-driven video.

Users' words: media server, video as fixtures, layers, CITP thumbnails, MSEX,
no dongle, free, open source, Art-Net, sACN, grandMA3, Eos, Avolites, cue-based,
projection mapping, edge blending, volunteer, show day.

## 3. Our strengths (proof in the repository)

Status: [M] measured, [V] verified in code and tests, [D] designed and built,
not yet verified with real consoles or hardware.

| Strength | Status | Proof |
|---|---|---|
| Each video layer is a 64-channel DMX fixture (media, play modes, speed, position/scale/rotation, colour, 8 blend modes, 11 effects, dissolve); Master and Output fixtures | V | docs/channel-map.md |
| GDTF file generated from the same parameter spec as the DMX map | V (export), D (console import) | DESIGN §16.2, B7 |
| CITP/MSEX server: layer status, libraries, thumbnails, preview stream | V (loopback, beacon on the network), D (real consoles) | benchmarks Phase 7, B40 |
| Art-Net + sACN with merge and source policy; full OSC map with timetags | V | DESIGN §6–7, §15.3 |
| ProRes from the Apple hardware decoder straight into Metal; HAP / HAP Q / HAP Alpha | M | DESIGN §4.1, benchmarks |
| 16 layers 1080p60 ProRes 422 HQ or HAP Q on a MacBook Pro M1 Pro: 0 missed, 0 late, GPU p99 ≈ 10 ms on a 120 Hz panel | M | benchmarks, 2026-10-26 |
| 16 layers 4K30 (ProRes or HAP Q with an 8-frame ring) | M | benchmarks |
| 8-hour soak: 0 dropped frames in ~1.7 M frames, three kill -9 restarts back in 0.26 s, memory flat | M | soak-2026-10-24-0928.md |
| DMX-to-photon p99 ≈ 30–32 ms (two frames at 60 fps, scan-out excluded) | M | benchmarks |
| Multi-projector soft-edge blending measured flat in linear light (< 2–3.5 % error), black lift, corner pin + mesh warp up to 33 × 33, slices, drawn masks, content template export | M / V | benchmarks Phase 6, docs/user/outputs-and-mapping.md |
| Test patterns that follow the warp, built-in generators (test card, motion test, clock) selectable from the console | V | CHANGELOG |
| LTC/MTC timecode chase per layer (±1 frame on generated LTC), cue list with fades, triggers and follows | M / V, D (real hardware) | ShowControlTests, B44 |
| Show mode + readiness check (power, thermal, disk, universes, outputs, Spotlight, updates, Time Machine), show lock | V | DESIGN §14, show-day checklist |
| Engine runs as a background service that survives the app quitting and restarts after a crash; web UI for any number of browsers and iPads with roles and passwords | M / V, D (clean install); iPad Safari used by the owner 2026-10-26 | benchmarks Phase 5, B46, B50 |
| UI made for the dark and for haste: legible type, 44 px targets, undo toasts, plain wording | V | CHANGELOG |
| No dongle, no licence server, no account; GPL-3.0 source; offline by design | V | LICENSE, DESIGN |
| Published benchmarks with a zero-dropped-frame pass criterion | M | docs/benchmarks |

## 4. USPs (what to lead with)

1. **Your console already knows how to run it.** Video layers are fixtures:
   patch the GDTF, program video like lights, cue it with the rest of the show.
2. **Free and open, no dongle, works offline.** The capabilities others put in
   their paid tier (console control, mapping, blending, timecode) are in the
   free build.
3. **Built on what Apple Silicon is good at:** hardware ProRes straight into
   Metal; 16 layers of 1080p60 on a laptop with zero dropped frames.
4. **Show-safe by design:** crash-restarting engine, readiness check before
   doors, show lock, measured 8-hour soak.
5. **Control from anywhere:** every screen in a browser or on an iPad, any
   number of operators, roles and passwords.
6. **Alignment that respects your time:** test patterns follow the warp, draw
   masks by tapping, export a content template for designers.

## 5. Honest limits (never claim otherwise)

- Release candidate, **source only**: no notarized download yet (B50).
- Not yet tested with real consoles (GDTF import, CITP thumbnails) (B7, B40),
  real LTC/MTC hardware (B44), second-display hot-plug (B34).
- Measured on one machine (MacBook Pro M1 Pro); other chips are expectations (B49).
- Apple Silicon with a ProRes engine only; no Windows, Linux, Intel or base M1.
- 4K60: about 6 ProRes layers; heavy blur/edge effects on 2–3 layers only.
- No NDI/DeckLink/AJA in the open build (planned as Pro plugins); OSC feedback,
  MIDI notes/CC, project versions, 3D mapping are later.
- Pull requests are not accepted until the CLA is final.

## 6. Personas

- **Lighting programmer** on grandMA, Eos, ChamSys or Avolites who wants video
  on the same desk without a separate media-server rig.
- **Small venue, theatre, church or school** with Macs and volunteers: free, no
  licence admin, iPad status, show-day checklist.
- **Rental company / AV crew**: no per-machine licences or dongles for spares,
  multi-projector blending on a laptop.
- **Projection mapper** on a Mac: corner pin, mesh warp, masks, content template,
  Syphon in and out.
- **Integrator**: open protocol (WebSocket JSON, OSC, Art-Net/sACN), scriptable,
  sponsored features and support available.
