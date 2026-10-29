<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Fanous: blending and mapping, research and a user-friendly design

**Status:** proposal of 2026-10-28. The owner's decisions are in §6, and the
M1 design is DESIGN §9.9. Building waits for the owner's approval of §9.9.

**Research:** three web surveys:
- professional media servers
- desktop and VJ tools
- dedicated calibration software, projector-side tools and calibration
  techniques

Those surveys were checked against the code. Effort and accuracy figures are
estimates. Competitor prices stay out of the repository.

## 0. The design in five lines

1. **Describe the rig, not the numbers.** A *projector wall* (columns ×
   rows, overlap %) computes each projector's share of the canvas, its slice
   and its blend edges. A seam between two projectors is one object with one
   set of controls.
2. **Align at the wall.** While a point is being edited, Fanous draws the
   mesh and the selected point on the projector itself, and the iPad becomes
   a remote. You look at the wall, not at a small preview.
3. **A blend that is right without understanding the maths.** One seam
   panel holds gamma (RGB linked or split), curve and black lift. The black
   lift counts how many projectors overlap, so the corners of a 2×2 wall stay
   dark. The panel adds a seam check that names the fix for each symptom.
4. **Never lose work.** A density change resamples the mesh instead of
   resetting it. Named mapping presets give a before/after toggle and can be
   recalled from the console.
5. **Let a camera do it, as the next step.** A Mac camera (a USB webcam, or an
   iPhone through Continuity Camera) first sets a corner pin automatically,
   then scans a whole wall. MPCDI import lets VIOSO, Scalable and
   domeprojection users bring their calibration.

## 1. Fanous today, and where it hurts

**As built** (DESIGN §9, `docs/user/outputs-and-mapping.md`):
- **Blend edges per output side:** overlap in px, an S-curve power, gamma,
  black lift % with a feather.
- **Warp:** a corner pin and a Catmull-Rom mesh of 2×2 … 33×33 points.
- **Slices:** a canvas rectangle stretched into a quad.
- **Masks:** one polygon per slice, with feather.
- **Editing aids:**
  - nudge keys and an iPad nudge pad, numeric x/y fields
  - test patterns that follow the warp
  - a raw switch on the Output fixture
  - content template PNG export
- **Undo:** a drag or nudge burst already merges into one undo step
  (`StateStore`, 1 s coalescing window).

**Frictions, measured against the surveys:**

| # | Friction | Today |
|---|---|---|
| F1 | A 2×1 or 3×1 blend is all typing | Per output, type the slice source rectangle in canvas pixels including the overlap. Type the overlap on both sides of every seam; the two values must agree. Set gamma and lift per output. "Spread canvas" only works inside one output. No product in the surveys makes the user do this by hand. |
| F2 | Changing the mesh density throws the warp away | It restarts from flat. Kantan Mapper and Stoner do the same, and users name it as a pain point. Avolites and Millumin resample instead. |
| F3 | The black lift is binary | Per edge it is "in overlap or not" (`MappingMath`, `inZone = max(...)`). In a 2×2 wall the four-projector corner gets no extra treatment, so it stays visibly lighter than the two-projector seams in black. |
| F4 | Editing happens on the preview | At the wall nothing shows which point is selected, so the operator looks back and forth between the iPad and the projection. |
| F5 | Masks are straight-segment polygons | One per slice, no holes, no curves, no invert. |
| F6 | No before/after and no recall | No named states, and nothing a console can switch. |
| F7 | No automatic help | No camera, and no import from calibration tools. |

## 2. How others do it

| Topic | What the surveys found | Best examples |
|---|---|---|
| Wall setup | Enter rows × columns, resolution and overlap; the tool builds the canvas, regions and blends | QLab "Multi-Output Stage", Mbox "Add Matrix of Outputs", MediaMaster "Soft Edge Span", Pixera Feed Areas, Watchout "Create Display Grid", MadMapper Video Wall, Mitti rows × columns |
| Overlap | Derived from where outputs sit, with a manual-override switch | QLab auto blends, Watchout auto soft edge, disguise Dynamic Blend, Pixera "Generate Auto Softedge", MadMapper Auto Setup, HeavyM Auto width |
| Blend controls | Width, curve (power / linear / S / raised cosine), gamma. Gamma R/G/B with a link toggle | MediaMaster (symmetric values, RGB link), Resolume (Gamma R/G/B, Luminance), Mbox (curve types on DMX) |
| Black level | Lift the single-projector areas ("black level compensation", MPCDI beta map). Watchout and Millumin leave it to the projector | Resolume BLC, VIOSO "Prj Gamma", Scalable uplift |
| Seam tuning | Multi-select outputs and tune one gamma. Symptom tables | Watchout (Masked mode, 10–20 % overlap, 25/50/75/100 % grey) |
| Warp grid | Insert a row or column by clicking an edge; the shape is kept | Avolites, Watchout (Ctrl+click), MadMapper (Alt+click), Millumin (resample on density change) |
| Point control | Bezier or smooth-versus-sharp per point, select a whole row/column/edge, step to the next point, fine/coarse nudge | Watchout, VIOSO (linear/cubic), Stoner (row/column), Pixera (Alt+arrow), QLab (edge drag, axis constraint) |
| At the screen | Remote apps and controls drawn on the output | Modulo Warp Remote, Q Surface (iPad), TouchOSC with camSchnappr, Millumin "Show Controls in Output", LuxCanvas phone remote, Ghost Arcade companion, Watchout gamepad |
| Presets | Warps recalled by index, also over DMX. Live-switchable output presets. A/B warp slots | Hippotizer, Avolites (8 presets), Mbox (keystone as a DMX fixture) |
| Masks | Freehand drag smoothed into Bezier, shape presets, invert, image masks | MadMapper, Resolume (invert by default), Watchout (alpha per junction), QLab (image mask that reloads on change) |
| Camera, simple | Project a few dots, tap the screen's four corners in the camera picture | LuxCanvas (9 dots, about 10 s), Christie Mystique Lite (one webcam, up to 3 projectors) |
| Camera, full | Dot grid or Gray code from one fixed camera gives warp, blend, black level, sometimes colour | VIOSO, Scalable (about 30 s per projector), domeprojection, Modulo Kinetic, disguise OmniCal |
| Recalibration | Saved camera plan, then one click | disguise RigCheck + Execute, Modulo "One-click" |
| Interchange | MPCDI 2D: PFM warp grid up to 32×32 (level 1), PNG alpha = blend, beta = black lift | Watchout, Pixera, Hippotizer read it; VIOSO, Scalable and domeprojection write it. Nobody among the media servers writes it. |

Recommended overlap is 10–25 % (Dataton, Resolume, Scalable, VIOSO); below 5 %
a seam is hard to hide.

## 3. What makes it easy, what users hate

**Easy:**
- the tool asks about the rig, not about pixels
- blends follow geometry
- one control for a seam
- feedback on the wall itself
- big touch targets with fine steps
- a saved state you can go back to
- a camera flow with one action: "tap the four corners"

**Hated:**
- typing matching numbers on both sides of a seam
- a grid reset on a density change
- a grey seam in dark scenes (black level)
- blends that only work on straight quads
- tiny viewports and weak numeric entry
- camera tools that need a dark room, a fixed camera and a licence, and that
  fail silently
- imports that drop data without a warning
- an auto-mapping that overwrites hand work (Pixera documents this)

**Not found in any reviewed product:** soft selection (proportional editing)
of mesh points, and a loupe. These are options to stand out.

## 4. Proposal

### 4.1 Projector wall

**Flow:** Outputs › **New projector wall**.

1. **Displays.** Every free display shows its Output ID, a big number. The
   user taps the numbers on the iPad in the order the projectors hang, left
   to right and top to bottom. Rows × columns follow from a choice of
   1×2 … 4×4.
2. **Overlap.** One slider, as a percentage of a projector. Default 15 %;
   below 10 % and above 25 % it shows a yellow hint. Two choices:
   - **Use canvas N:** the wall stretches over that canvas.
   - **Make a canvas that fits:** width = cols × w − (cols − 1) × overlap,
     and likewise for the height.
3. **Check.** **Blend check** and **Grid** appear on all projectors of the
   wall at once. The Warp tab opens on the first projector.

**Model:**
```
walls: [{ id, canvas, rect (on the canvas, 0–1), cols, rows,
          outputs: [id] (row-major), overlap: {x, y} (fraction of one projector),
          seam: { gamma: [r,g,b], gammaLinked, power, blackFloor },
          manual: [{output, edge}] }]
```

- **Edit-time only.** A wall compiles into the fields an output already has:
  the source rectangle of slice 1, and the blend edges on the inner sides. The
  render path does not change.
- **Changing a wall.** Changing the overlap, the rectangle or the seam values
  re-derives every output of the wall.
- **Manual overrides.** Editing a derived field by hand marks that edge
  "manual" (QLab's checkbox), so a later wall change leaves it alone.
- **Deleting a wall** keeps the outputs as they are.

**Why:** this removes F1 entirely, and it is the step every compared product
offers.

### 4.2 Seams and blend

- **A seam is a shared object.** The edge between two neighbours is one seam
  with one overlap and one set of controls, applied to both sides. That
  matches MediaMaster's symmetric values. Seams of a wall share the wall's
  values unless one is unlinked.
- **Seam controls:**

  | Control | Behaviour |
  |---|---|
  | Overlap | from the wall |
  | Gamma | 2.2 by default. **Link RGB** is on by default; unlinking it gives the three-channel gamma of OPEN-14 |
  | Curve (power) | 2 by default |
  | Black floor | % of white |

  Each control keeps its one-line explanation, as today.
- **Coverage-aware black lift** (fixes F3):
  - The blend-map generator knows from the wall how many projectors cover each
    pixel: n = 1, 2 or 4. In a 3×1 wall that is 1 or 2.
  - Every projector covering a pixel lifts it by (n_max − n) × floor / n.
  - Each point then reaches the floor of the most-covered point, including the
    corners of a 2×2 wall.
  - It is still one rgba16Float map per output, built at edit time, so the
    render pass does not change.
  - Outside a wall the current per-edge lift stays.
- **Seam check:** one button runs through these patterns on all projectors of
  the wall: 0 %, 25 %, 50 %, 75 % and 100 % grey, Blend check, and the grid in
  each output's own colour. Each step shows a hint card:

  | You see | Do |
  |---|---|
  | a bright band in the seam | lower gamma |
  | a dark band | raise gamma |
  | a light band only in black | raise the black floor |
  | a colour shift in the seam | match the projectors (§4.6), or unlink RGB gamma |
  | grid lines that do not meet | fix the warp, not the blend |

- **Multi-select:** with the whole wall selected, a slider tunes every seam at
  once (Watchout).

### 4.3 Warp editing at the wall

- **On-output edit overlay** (fixes F4):
  - **What it shows.** While a programmer has the Warp tab open on an output,
    the engine draws that output's mesh as thin lines, through the warp like
    the test patterns. The selected point is a bright crosshair with its
    label ("r3 c5"), and the slice and mask outlines are drawn too.
  - **When it is shown:**
    - It switches off when the tab closes, after 10 minutes without an edit,
      or when show mode or show lock goes on.
    - It is never drawn in show mode.
    - A **Show on output** toggle stays visible.
  - **Implementation:** an extra draw in the output pass from a small uniform
    buffer of points; nothing is rebuilt.
- **iPad remote mode:**
  - **Layout:** a full-width panel with **previous / next point** (row-major,
    wraps) and **select row**, **select column** and **select edge**, which
    selects every point on that border.
  - **Fine / coarse:** 1 or 10 output px; a long press gives 0.25 px.
  - **Trackpad area:** a relative drag with acceleration, so the finger never
    covers the picture.
  - **Undo**, and the selected point's label in large type.
  - **Why:** this is what Modulo's Warp Remote, Q Surface and the TouchOSC
    setups do, but in the existing web UI and without an extra app.
- **Resample instead of reset** (fixes F2): a new density evaluates the
  current Catmull-Rom surface at the new points. `MappingMath` already
  evaluates that surface.
- **Later:**
  - inserting a row or column locally (a non-uniform grid: store the line
    positions)
  - sharp corner points (Watchout's smooth toggle)
  - soft selection with a radius slider (not found anywhere else)
  - arithmetic in number fields ("/3", as in Resolume)

### 4.4 Masks

- **Several masks per slice** (holes for windows and doors), with **invert**.
- **Shapes:** rectangle, ellipse and polygon. A freehand drag is smoothed into
  a Bezier path (MadMapper). Points stay draggable and keep their feather.
- **Mask from an image:** a greyscale PNG from the library, reloaded when the
  file changes (QLab).
- **On the output:** mask outlines are drawn by the overlay of §4.3.
- **Implementation:** the `r8` mask raster stays the render input, so only the
  edit-time rasteriser grows.

### 4.5 Mapping presets and before/after

- **Named presets** per output and per wall: a snapshot of warp, slices,
  masks and blend. **Store**, **Recall** and **Compare**; holding Compare
  shows the previous state.
- **Console recall:** **Output fixture channel 6, "Mapping preset"**: 0 = as
  edited, 1–N = preset N, with a crossfade time on the existing dissolve
  logic. Hippotizer and Avolites recall warps by index; Mbox puts its
  keystone on DMX.
- **Decided:** channel 6 is Mapping preset; it was one of the three reserved
  channels of Output mode.
- **Console keystone (decided for M2).** Full mesh editing from a console is
  impractical: a 33×33 mesh would take thousands of channels. Console mapping
  is used for three things: recalling stored mappings per scene (channel 6),
  following moving scenery, and quick fixes from FOH.
  - **Keystone mode:** a separate fixture mode per output, 16 ch: four corners
    × X/Y, 16-bit.
  - **Offsets:** they sit on top of the mapping edited in the UI, and centre
    means no change. So the console never destroys the hand alignment.
  - **Existing modes:** a new mode leaves the three existing modes alone.
  - **Moving screens:** this fits B53.
  - **Prior art:** Mbox has a DMX keystone fixture; whether Axon/Catalyst
    worked the same way was not checked.

### 4.6 Colour match per output

- **Per output:** RGB gain and a black offset, used with the Colour bars and
  Grey steps patterns. These match Resolume's per-screen controls and
  Watchout's white point.
- **Later:** a 3D LUT per output (feature-gaps G18).

### 4.7 Camera assistance (an iPhone or webcam as the camera)

- **Camera sources (decided):** the iPhone, by two routes. Both feed the same
  Mac-side solver (pattern projection, dot finding, homography and mesh), so
  most of the work is shared.
  1. **First, Continuity Camera:** the iPhone is the Mac's wireless camera. It
     needs no app and no certificate, but the same Apple account as the Mac.
     A USB webcam works the same way.
  2. **Then the iPad/iPhone browser camera,** once a trusted certificate
     exists (CA profile, OPEN-17). Safari gives no control over exposure or
     focus and no full-resolution stills, so patterns are decoded against
     their inverse.
  3. **In both cases:** the camera must not move during a scan, so use a
     small stand or clamp. The iPad shows the camera picture, and the user
     taps the corners there.
- **Step A — auto corner pin, one projector** (the Mystique Lite and LuxCanvas
  flow):
  1. Put the camera where it sees the whole screen.
  2. Fanous projects a dot grid and its inverse, and finds the dots.
  3. The iPad shows the camera picture with the found dots; the user taps the
     screen's four corners.
  4. A homography becomes the corner pin.

  About 10 s. Accuracy is estimated at 2–5 px.
- **Step B — wall scan:**
  - **What it does:** the same flow per projector with a denser dot grid. The
    user taps the corners of the whole screen once. Fanous then solves a mesh
    (up to 33×33) per projector, and the overlap and seams follow from what
    the camera saw.
  - **Scope:** flat and gently curved screens (MPCDI's 2D level).
  - **Accuracy:** estimated at 1–3 px.
  - **Recheck:** reuses the saved camera view, one click (disguise RigCheck).
- **Robustness:**
  - Each pattern is decoded against its inverse, so auto exposure does no harm.
  - Every pattern is held for at least three frames.
  - A projector the camera cannot fully see is refused with a picture of what
    was found, never silently.
  - The result is a mapping preset (§4.5), so nothing hand-made is overwritten.
- **Dependencies:** none new. AVFoundation for capture; dot finding and
  least-squares homography with Accelerate/simd; Core's existing homography
  math.

### 4.8 Interchange

- **MPCDI 2D import** (profile `2d`, geometry level 1; colour levels 1–2):
  - The PFM warp grid (up to 32×32) becomes the mesh.
  - The alpha map becomes the blend factor.
  - The beta map becomes the black lift.
  - The blend map is already a texture per output; it only needs to accept an
    imported one.
  - Unpacking: the ZIP via `ditto -x -k`, or the user picks the unpacked
    folder.
  - **Report:** anything not imported (3D profiles, level-2 per-pixel warps)
    is listed in a visible report, unlike Watchout's silent drop.
- **Content template:** an SVG with slice and mask outlines next to the PNG
  (Millumin, QLab "Save grid image").
- **Later:** MPCDI export. No media server in the surveys writes it.

### 4.9 Later

- **A projector calculator in the wall flow:** screen width and throw ratio
  give distance, pixel density and the canvas size. This is a 2D calculation,
  not disguise's photometric study.
- **3D mapping** (DESIGN §21) with point picking and an error readout (Pixera,
  Watchout, disguise QuickCal).
- **The browser camera,** once a trusted certificate exists.

## 5. Order (one PR per item, after approval)

| Stage | Item | Effort | Fixes |
|---|---|---|---|
| M1, edit time and UI | Projector wall + seams (§4.1, §4.2 without coverage lift) | M | F1 |
| | Resample on density change (§4.3) | S | F2 |
| | iPad remote mode: next point, row/column/edge, fine/coarse, trackpad (§4.3) | M | F4 (partly) |
| | Seam check with hints (§4.2) | S | |
| | Gamma R/G/B link (OPEN-14), per-output RGB gain and black offset (§4.6) | S | |
| M2, engine | On-output edit overlay (§4.3) | M | F4 |
| | Coverage-aware black lift (§4.2) | S–M | F3 |
| | Mapping presets + Output channel 6 (§4.5, after the channel decision) | M | F6 |
| | Masks v2 (§4.4) | M | F5 |
| M3, camera and import | MPCDI 2D import (§4.8) | M | F7 |
| | Auto corner pin with the Mac camera (§4.7 A) | M | F7 |
| | Wall scan (§4.7 B) | L | F7 |
| Later | Local row/column insert, sharp points, soft selection, projector calculator, 3D mapping, browser camera, MPCDI export | — | |

## 6. Decisions (owner, 2026-10-28)

1. **Wall: both.**
   - A wizard creates the wall, and the project keeps it.
   - **Edit layout…** re-opens the wizard pre-filled.
   - **Geometry is computed; tuning is by eye.** No default blend fits, because
     projector age, ambient light and the surface differ. So:
     - The wall computes only the geometry: the canvas share per projector and
       the overlap in pixels. A hand-edited geometry field becomes "manual".
     - Tuning is first-class: gamma and curve per seam (both sides at once),
       black floor and colour per projector.
     - The seam check is the tuning route: per step it says what to look for
       and which control to turn.
     - Start values are only a starting point.
2. **Output fixture channel 6** is Mapping preset. A **Keystone** mode for
   console corner pins comes in M2 (§4.5).
3. **The camera is the iPhone:** Continuity Camera first, then the browser
   camera (§4.7).
4. **M1 first.** The design is DESIGN §9.9. RGB gamma and per-output colour
   touch the output shader a little; everything else in M1 is model, commands
   and UI.
5. **M2 (2026-10-29).** The design is DESIGN §9.10:
   - A console preset change morphs over Output channel 7 (Mapping fade).
   - The edit overlay is on while Warp & Slices is open, with a Show on
     output switch.
   - Masks v2 includes freehand drawing.
   - Presets hold warp, slices and masks. The blend stays live: it is the
     projector's tuning (decision 1), so §4.5's "and blend" is dropped.

## 7. Sources (main pages)

**Media servers**
- disguise QuickCal: <https://help.disguise.one/workflows/calibration-projection/quickcal-overview>
- disguise OmniCal: <https://help.disguise.one/workflows/calibration-projection/omnical-overview>
- disguise Dynamic Blend: <https://legacy-help.disguise.one/en/Content/Stage-Setup/Projector-Simulation/Dynamic-Blend.htm>
- Pixera: <https://pixera.helpjuice.com/warping-feedmodes-and-softedge>, <https://pixera.helpjuice.com/mapping-/marker-calibration-workflow>
- Watchout 7: <https://docs.dataton.com/watchout-7-new/watchout/displays-and-outputs/edge-blending.html>, <https://docs.dataton.com/watchout-7-new/watchout/displays-and-outputs/warp-geometry.html>, MPCDI: <https://docs.dataton.com/guide/watchout/devices/mpcdi.html>
- Modulo Kinetic: <https://support.modulo-pi.com/modulo-kinetic-manual/1/en/topic/autocalibration>, Warp Remote: <https://support.modulo-pi.com/modulo-kinetic-manual/v6/en/topic/warp-remote>
- Avolites Ai v12.2 manual: <https://www.avolites.com/app/uploads/2025/12/Ai-v12.2-Manual.pdf>
- MediaMaster (ArKaos guide): <https://downloads.arkaos.com/pdf/MediaMaster_Documentation.pdf>
- Mbox manuals: <https://www.prg.com/en/technology/innovation/mbox-designer>
- Hippotizer ScreenWarp: <https://www.manula.com/manuals/green-hippo/hippotizer-v4/4.5.5/en/topic/screen-warp-editor>

**Desktop and VJ tools**
- MadMapper: <https://docs.madmapper.com/madmapper/6/>
- Resolume: <https://resolume.com/support/en/edge-blending>, <https://resolume.com/article/54>
- QLab: <https://qlab.app/docs/v5/video/video-output/>
- Millumin: <https://help.millumin.com/docs/display/softedge>
- Mitti: <https://imimot.com/help/mitti/outputs/video-output>
- TouchDesigner: <https://derivative.ca/UserGuide/Palette:stoner>, <https://derivative.ca/UserGuide/Palette:camSchnappr>
- LuxCanvas: <https://github.com/dio99/luxcanvas>
- Ghost Arcade: <https://github.com/riskcapital/ghost-arcade>
- Splash: <https://gitlab.com/splashmapper/splash>

**Calibration**
- VIOSO: <https://docs.vioso.com/llms-full.txt>
- Scalable Display: <https://www.scalabledisplay.com/blending-software/>
- domeprojection: <https://docs.projectiontools.com/projectiontools/6.2/ProjectionTools/walkthrough.html>
- Christie Mystique Lite: <https://www.christiedigital.com/products/warping-blending/mystique/mystique-lite/>

**Theory**
- Bourke, edge blending: <https://paulbourke.net/miscellaneous/edgeblend/>
- Raskar et al. 1999: <https://www.eecs.yorku.ca/~mbrown/pdf/vis99_raskar_brown.pdf>
- Majumder & Stevens: <https://www.cs.unc.edu/Research/ootf/publications/Majumder_TVCG03.pdf>
- OpenCV structured light: <https://docs.opencv.org/4.x/d1/dec/classcv_1_1structured__light_1_1GrayCodePattern.html>
- MDN getUserMedia: <https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia>
