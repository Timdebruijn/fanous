<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Pixel mapping in three dimensions, and pixels that move

**Status:** design note of 2026-11-25, not built. It fixes what the pixel
mapper (DESIGN §21 "Pixel mapping to DMX fixtures", `feature-gaps.md` G14,
`BACKLOG.md` B407) has to hold from its first version so that a volume of
LEDs (a 20 × 20 × 20 grid of balls) and LEDs on winches (B53 "movement out")
are the same feature, not a second one. The owner's questions are in §6.

**Research:** three web surveys on 2026-11-25 (volumetric mappers, kinetic
rigs, and which inputs those products take from a media server). Sources in
§7. Vendor pages were read; manuals were sampled, not read whole.

## 0. The design in four lines

1. **A pixel map is a list of points.** Every LED has x, y, z in metres and a
   DMX address. Positions come from a grid generator, a CSV with one row per
   LED, or an OPC layout JSON. Nothing else in the mapper knows whether the
   rig is flat.
2. **One GPU pass samples the canvas for every point.** Three ways to turn
   (x, y, z) into a canvas coordinate: *extrude*, *project*, *atlas*. A flat
   strip uses *extrude* and never sees z; a volume uses any of the three.
3. **A moving pixel is a point whose z is driven.** Its height is sampled from
   a height map (a canvas, luma) and sent as 16-bit DMX; its colour is sampled
   at the commanded height. Fanous sends intent, clamped and rate-limited;
   the winch controller owns safety (B53, DESIGN §21).
4. **Generative volume effects stay out.** Fanous is a video server (DESIGN
   §1 non-goals). For noise fields through a volume, Fanous feeds
   TouchDesigner over Syphon on the same Mac, or, once NDI out exists (B74,
   deferred), MADRIX on a separate Windows machine.

## 1. What the field does

| Product | x/y/z per LED | Content in the volume | Geometry in | macOS |
|---|---|---|---|---|
| MADRIX 5 | yes, voxel matrix (`Z = 1` means 2D) | its own effects with a 3D mode | matrix generator, per-fixture patch editor; **no CSV import** | no |
| ChamSys MagicQ | yes | its own effects on Z; 2D effects stacked with offset | 3D grid | yes |
| ENTTEC ELM | yes, 3D workspace | shaders, video (3D use not stated) | presets, **CSV per LED** (position + patch) | not verified |
| TouchDesigner | if you build it | your choice: 3D texture, scene sampling | CSV per LED | yes, Syphon in |
| grandMA3 | fixture positions in the 3D stage | pixel mapper not volumetric | patch, MVR | onPC yes |
| Resolume, MadMapper, Hippotizer, Pixera, disguise | no | 2D sampling (disguise: one UV pixel per lamp) | fixture editor | varies |

Observations:

- Three products have a native volume mapper, all generative. None takes an
  incoming video and extrudes or slices it through the volume. That is the
  gap a video server fills.
- Importing arbitrary positions is rare: ELM and TouchDesigner take a CSV,
  MADRIX does not. There is no open per-LED interchange standard. MVR/GDTF
  (DIN SPEC 15800/15801) place whole fixtures, not the LEDs inside one. The
  de-facto forms are a CSV per LED and the Open Pixel Control layout JSON
  (an array of `{"point": [x, y, z]}` objects, used by Fadecandy, Chromatik
  and the creative-coding tools).
- Kinetic rigs (WHITEvoid Kinetic Lights, Procom KW6/KW9, Showtec Ilumilift)
  are plain DMX: a height fixture (16 bit, often a speed channel, sometimes a
  safety channel) and a separate RGB fixture, in separate universes. The
  MADRIX workflow patches both and drives them from two layers of the same
  show: a greyscale **height map** (full white = fully extended, black = at
  the top) and a colour map. Open loop: no product feeds the measured height
  back into the colour. PosiStageNet is feedback and tracking (disguise,
  grandMA3 receive it), not a way to command a winch.
- Safety: Kinesys states that ANSI E1.11 advises against DMX for lifting and
  that EN 17206 cannot be met with direct DMX control; its winches run under
  TAIT Navigator with feedback and SIL-rated drives. A media server sends
  position intent to a controller with its own limits, nothing more.

## 2. Geometry

A **pixel map** is a project object (`pixelMaps[]`, one per rig) holding:

- `points[]`: `x y z` in metres (proposed stage frame: x right, y depth
  towards the audience, z up, origin at the stage centre line on the floor;
  the LED tools and MADRIX use z up, PSN uses y up, see §6 Q1), `universe`,
  `address`, `footprint` (`rgb`, `rgbw`, `rgb16`, `w`), optional `group` (a
  ball, a tube, a strip) and `order` within a group. A tube of 32 LEDs is 32
  points in one group.
- `kinetic` (optional, per group, set in the UI; the files below carry only
  the group name): `heightUniverse`, `heightAddress`, `travel` in metres,
  `top` (the z at zero travel), `rateLimit` in m/s, `safe` (`0…255` written
  to the fixture's safety channel when it has one; a project setting,
  default none).

Three ways in, all producing the same point list:

1. **Grid generator**: counts and pitch per axis, a start address and the
   addressing order (which axis runs first, serpentine per row or not). This
   covers a 20 × 20 × 20 rig in six fields.
2. **CSV**: header `x,y,z,universe,address[,footprint,group,order]`. The
   field names and units are documented in the user guide; a file from ELM
   or a spreadsheet maps onto it with a header rename.
3. **OPC layout JSON**: `point` per LED, addresses assigned in file order
   from one start address. Read only; Fanous writes CSV.

Fixture types (DESIGN §6.1) are untouched: the LEDs are not fixtures the
console patches into Fanous, they are what Fanous patches out. ADR-0008
(fixed footprints) is not affected.

## 3. Sampling

One compute pass per tick, encoded by the compositor thread after the
canvas pass in the same command buffer (DESIGN §4.3): for every point, a
canvas coordinate `(u, v)`, one texture read, and a write of the footprint's
bytes into a shared universe buffer, which a sender thread reads at DMX
cadence (§5). The buffers are allocated with the pixel map; the pass
allocates nothing per tick (ADR-0002).

| Mode | `(u, v)` from `(x, y, z)` | Use |
|---|---|---|
| **Extrude** | drop one axis (default the depth axis y), scale the other two by the map's bounds onto the canvas | a flat strip or panel; a volume lit "through" from the front, every ball on a line gets the same colour |
| **Project** | a virtual camera (position, look-at, field of view) projects the point onto the canvas, the camera maths designed for 3D projection mapping (DESIGN §21, not built) | video that looks projected through the volume from a chosen seat |
| **Atlas** | the canvas holds `n` tiles in a grid, tile `k` is slice `z = k`; `(u, v)` is the point's x/y inside its tile | a true volume from one 2D clip (a flipbook of slices), or from `n` layers each masked to a tile |

Every mode takes the same two extras:

- **Depth weight**: a second canvas (or the same canvas's alpha) sampled at
  (normalised depth y, normalised height z) of the point, multiplied into
  the colour. A vertical white bar moving across that map is a plane
  sweeping the volume front to back, a horizontal bar a floor rising; in
  *extrude* mode this is what makes a front-lit volume look
  three-dimensional.
- **Mapping bounds**: which part of the canvas the map covers, as with a
  slice (DESIGN §9.4), so several maps share a canvas.

The point values are converted canvas → fixture: 16 → 8 or 16 bit, optional
gamma per map, white derived for `rgbw`. No other colour science in v1.

Expected cost, to be measured in the first version: 8 000 points are 8 000
texture reads and 24 000 bytes. At 170 RGB pixels per universe (no pixel
straddles a universe) a 20 × 20 × 20 rig is 48 universes, 48 UDP packets per
DMX frame, before any height or safety channels.

## 4. Pixels that move

A kinetic group adds one sample per group and tick:

1. `h = luma(heightMap at the group's (x, y))` in the *extrude* projection of
   the height canvas, `0…1`.
2. The commanded height: `z' = top − h × travel`, moved towards from the last
   commanded z (`top` at project load and after Home) by at most
   `rateLimit × dt`, then clamped to `[top − travel, top]` (a guard for a
   `travel` or `top` edited while the show runs; with `h` in `0…1` it never
   bites otherwise).
3. `h' = (top − z') / travel`, scaled to `0…65535`, is written as 16-bit DMX
   (coarse, fine) to the height address; the safety byte, when set, with it.
4. The group's points sample their colour at `z'`, not at their patched z.

So the colour follows the commanded position in every mode, and a ball
lowering through a depth-weighted volume shows the right slice as it goes.
The real position is unknown to Fanous. B53's PSN receiver can later replace
`z'` with the measured z for groups that carry a tracker.

What this does not claim: smooth motion. DMX runs at 44 frames a second; the
winch's own speed channel and controller interpolate. Fanous changes the
target at DMX rate and limits how fast the target moves, nothing else.
The safety rule of DESIGN §21 stands word for word: Fanous is never the
safety layer, the winch controller's limits, e-stop and certification are
the integrator's.

## 5. Output path and what changes on the wire

- `ArtDmx.encoded()` is in Core; the sACN packet builder lives in the tests
  and moves to Core. The sender is the engine's raw UDP socket (`UDPSend`)
  on a cadence thread of its own: a fixed DMX refresh independent of the
  canvas rate, last buffer repeated, no Network.framework queue in the path
  (ADR-0002's socket-thread clause, for the receive side, applies only if
  measured jitter demands it). One `UniverseID(protocol, number)` per output
  universe, the same key as the input side (DESIGN §6.5). An output universe
  the console also sends to Fanous is a configuration error the Patch screen
  reports.
- **Wire change, to be named in that PR:** the ArtPollReply advertises
  output ports only (`portTypes = 0x80`: the node outputs DMX from the
  network, that is, it consumes ArtDmx); an engine that sends ArtDmx also
  sets the input bit (`0x40`) with the matching GoodInput and SwIn fields,
  and the sACN sender needs a source CID and a priority setting (default
  100).
- The user sees it on the Outputs screen as a third kind beside displays and
  Syphon: a pixel map with its canvas, mode, bounds, a 3D preview of the
  points (a dependency for it needs an ADR) and a "send" toggle; a map that is
  off sends zero frames, not black. Kinetic groups get a travel readout and a
  **Home** button (height map ignored, all groups move to `top` at the rate
  limit).

## 6. Questions for the owner

1. Stage frame: z up (this note, MADRIX, most LED tools) or y up (PSN,
   B53)? One choice, documented, with the CSV importer able to swap axes.
2. Is the OPC JSON import worth the day it costs, or is CSV enough for v1?
3. Does the height map come from its own canvas, or from a named layer's luma
   on the same canvas? Own canvas is simpler to reason about and costs one
   more canvas in the project.
4. Order: 2D strips first (G14 as planned), with the point list and the
   *extrude* mode, then *atlas* and *project*, then kinetic? Or kinetic before
   *project*, since it is the rig in hand?

## 7. Sources

- MADRIX: 2D or 3D (`help.madrix.com/m5/html/madrix/hidd_2d_or_3d.html`),
  matrix generator, 3D patch tutorial, kinetic tutorial
  (`help.madrix.com/tutorials/html/hidd_control_a_kinetic_system_with_.html`),
  forum on CSV import (topic 1825) and on the height map (posts 3707, 5079,
  5095), system requirements (Windows only), NDI and Spout pages.
- ChamSys MagicQ 3D pixel mapper (`chamsyslighting.com/?p=3489`); ENTTEC ELM
  (`enttec.com/sku/70-581`); Resolume fixture editor (article 55) and the
  forum request for 3D fixtures; MadMapper 6 DMX and LED mapping docs;
  TouchDesigner Syphon Spout In TOP and the forum thread on CSV pixel
  mapping; disguise Art-Net driver and the Millenia Tower example; grandMA3
  position fixtures and PSN remote input; xLights custom model manual.
- Kinetic: WHITEvoid product news (DMX control), Procom KW6/KW9 datasheets,
  Showtec Ilumilift, Kinesys Sculptor (EN 17206, DMX not for lifting),
  disguise PSN and PRG Stage Command drivers, Modulo Kinetic PSN output.
- Formats: MVR and GDTF specs (`github.com/mvrdevelopment/spec`), Fadecandy
  OPC layouts, Chromatik model definition.
