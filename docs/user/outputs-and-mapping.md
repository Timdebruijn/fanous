<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Outputs and mapping

All layers are composited into one **canvas** (1920x1080 unless the engine was
started with another scene). **Outputs** take parts of the canvas to displays
and projectors. An output is a display, a region of it, an intensity, blend
edges, a warp and one or more slices. A new output shows the whole canvas with
no blend and no warp. Everything is applied on the GPU in the last step, so it
costs no layer capacity.

The Outputs screen (key 3, "Outputs & Mapping") has three tabs: **Canvases**,
**Outputs** and **Warp & Slices**. The output list is on the left. The preview
on top shows the canvas on the Canvases tab and the selected output on the other
two. The output preview has the output's own aspect ratio (4:3, 16:10, an
ultra-wide LED wall), and the handles are drawn over exactly the same box, so
they sit on the picture whatever the display. The Canvases tab shows the canvas
at 16:9. The preview image itself is a 640 x 360 stream stretched back into the
output's shape.

After you add an output, a yellow bar says **Next: align this output**; its
button opens the Warp & Slices tab for that output.

## Displays and binding

Under **Add output on** choose a connected display (name, size, "(this Mac)"
for the built-in one) or "Unassigned (assign later)". An output is tied to a
display by its identity, not by its position, so a projector you unplug and
plug in again lands on the same output, and a replaced projector shows up as
missing until you pick the new display in the **Display** field.

The list shows a status line per output:

- green: `<display> · 1920 × 1080 @ 60`, with "clock master" on one of them
- "not assigned to a display" (grey), or "binding…"
- red: "display missing: <name>". A red banner also says "Output N lost" and that
  the other outputs keep running. Re-plugging rebinds it.

The compositor follows the **clock master**: the first bound output unless you
pick another under **Clock master** on the Canvases tab. The other displays show
the most recent finished canvas. One display can carry several outputs (regions),
for example a 4K port into a splitter that feeds four projectors.

If an output uses the Mac's own display, the screen says so in yellow: the app
window is hidden behind it. Use the web UI from another device then.

## Outputs tab

| Field | Meaning |
|---|---|
| Name | free text |
| Display | the bound display, or Unassigned |
| Mode | the wanted resolution and refresh rate. **Stored but not applied** (B33): set the display mode in System Settings › Displays |
| Region x · y · w · h (px) | the part of the display this output draws on; **Full display** resets it |
| Intensity % | multiplied with the Output fixture's intensity and the Master intensity |

**Remove output** takes effect at once and shows "Undone? Undo" for 8 seconds
(Undo also works with Cmd-Z). Slices, masks, cues and the last layer work the
same way.

### Blend edges

For each edge (left, right, top, bottom) set **Overlap**: the width of the strip
shared with the neighbouring projector, in pixels of this output. Then **Power**
and **Gamma**; each has a one-line explanation under it on the screen. The curve next
to the fields shows the ramp. Power (0.1 to 10, default 2) is how steep the
S-curve is; set **Gamma** (0.5 to 5, default 2.2) to the projector's gamma so
the sum of both projectors stays flat in the overlap. In tests a flat field
over two or four projectors stayed within 2 % across the overlap.

**Black lift (%)** (0 to 50) raises the black level outside the overlaps so the
single-projector area matches the doubled black of the overlap; **Lift feather
px** softens where the lift ends. Use the Grey steps pattern to match it by eye.
Grids work: a corner pixel gets the product of the horizontal and vertical
ramps.

### Test patterns

Buttons: Off, Grid, Colour bars, Blend check, Output ID, Crosshair, Grey steps,
Checkerboard. The Test pattern channel of the Output fixture (per projector) and
of the Master (all outputs) overrides the button, so a console can call them up.
Patterns follow the corner pin and mesh and show the blend map; set the Output
fixture's **Blend** channel to 128 or more (Raw) to see them without blend, warp
and mask. Line widths and cells follow the output's height, so a pattern reads
the same on a monitor and on a 4K projector.

| Pattern | Use it for |
|---|---|
| Grid | alignment: centred square cells, border (overscan), centre cross, a circle for aspect ratio, diagonals |
| Colour bars | 75 % SMPTE bars and 100 % white/red/green/blue/black: colour and level match between projectors |
| Blend check | flat 50 % grey shows a blend seam as a bright or dark band; grid lines in this output's own colour let two overlapping projectors be laid on top of each other |
| Output ID | the output number, large, on the output's colour: which projector is which |
| Crosshair | centre and focus, circles every 1/8 of the height |
| Grey steps | 0–100 % in 10 % steps (top) and 0–10 % in 1 % steps (bottom): gamma and black level, black lift |
| Checkerboard | focus and pixel geometry |

The same patterns, a moving test card and a few more are also available as layer
content in folder 0 (see [show-control.md](show-control.md#built-in-content-folder-0)).

## Warp & Slices tab

Choose what to edit with **Corner pin**, **Mesh**, **Slices** or **Mask**.
Handles sit over the output preview. Drag them with mouse or finger (the hit
target is large for touch); with a handle selected the arrow keys move it by one
output pixel, Shift by ten. On an iPad use the **nudge pad** that appears under
the mode buttons once a point is selected: arrows move by 1 px, the **10 px**
key in the middle makes every press move ten. A selected point also shows
numeric x and y fields in pixels. Changes go to the engine while you drag.

Slice, mask and mesh points are stored before the warp, but the preview shows
the warped picture. The editor therefore draws these handles where the picture
really is (through the corner pin and mesh) and moves them in that picture, so
a handle stays on the spot you touch while a warp is active.

- **Corner pin**: four corners. **Reset corners** puts them back.
- **Mesh**: **Density** is Off (corner pin only) or 2x2, 3x3, 5x5, 9x9, 17x17
  or 33x33 points. Changing the density starts from a flat grid. The picture
  follows a smooth surface through the points. **Reset mesh** flattens it.
- **Slices**: a slice takes a rectangle of the canvas (**Source x · y · w · h**,
  in pixels of the canvas; the tooltip shows the stored 0 to 1 value) and puts it on a four-corner destination on the output (the
  handles). **Opacity %** per slice. **Add slice** and **Remove slice**; slices
  draw in order, later over earlier. Use slices to feed different parts of the
  canvas to different regions.
- **Mask**: **Add mask** starts with a rectangle 10 % inside the slice. Everything
  outside the path is hidden. **Feather (px)** softens the edge in output pixels.
  **Add point** inserts a point after the selected one, **Remove point** deletes
  the selected one (a mask keeps at least three), **Remove mask** deletes it.

The canvas is also published as the Syphon server "Fanous – Canvas", so
another app on the same Mac can receive it. This was checked between processes
by the bench tool, not yet with a third-party app (B6).

Editing on this screen needs the programmer role and is refused while the show
is locked.

## Not done yet

- **Display modes** are not applied. Set resolution and refresh rate yourself in
  System Settings › Displays and keep them at the canvas rate (B33).
- **Hot-plug** (unplug and replug) is only partly tested: through unit tests and
  by binding and releasing the built-in display. Test it on your machine before
  the show (B34).
- The canvas size and frame rate cannot be changed from the UI (B31).
- Dithering is a simple noise function; if you see banding on a projector, tell
  the developers (B34).
- Not available: per-output Syphon, 10-bit output, separate blend gamma for red,
  green and blue.
