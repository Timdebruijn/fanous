<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Outputs and mapping

Layers are composited into a **canvas** (1920x1080 at 60 fps in a new
project; change it on the Canvases tab, see below). A project can have up to
four canvases, for example layers 1 to 4 on Canvas 1 for the projectors and
layers 5 to 8 on Canvas 2 for an LED wall (see "Several canvases" below).
**Outputs** take parts of the canvases to displays
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
in its own aspect ratio. The preview stream has that shape too, and is about as
wide as the preview is on your screen in pixels: 320, 640, 960 or 1280 pixels,
so a large or high-resolution screen gets a sharper picture. Resizing the window
switches size after a moment.

## Canvas size and frame rate

On the Canvases tab, **Size w × h** sets the canvas in pixels (or pick a preset:
1920 × 1080, 3840 × 2160, 1280 × 720) and **Frame rate** the rate the engine
renders at: 23.976, 24, 25, 29.97, 30, 50, 59.94 or 60 fps. Width and height
must be even and between 320 and 8192. Nothing changes until you press
**Apply** and confirm; **Revert** drops your edits.

Applying re-creates the canvas: every output blanks (or holds its last picture)
for a moment, so do it before the show, not during it. It is refused while the
show is locked or show mode is on. An undo, redo or project load that changes the
canvas during show mode waits: the tab says which canvas is rendering, and the
change applies when show mode ends. If the engine cannot make the new canvas
(not enough memory), the old one keeps running, the project goes back to it and
the tab shows the error. Previews and generator layers (test card, grid) follow
the new size. Outputs keep their display, blend, warp and
slices: slice sources are stored as fractions of the canvas, so a slice that
showed the left half still shows the left half (in pixels, the numbers double
when you go from 1920 × 1080 to 3840 × 2160). Content that was made for the
old size is scaled to the new canvas by each layer's fit mode. Undo (Cmd-Z)
goes back to the previous size.

## Several canvases

Not every layer has to be on every output. **Add canvas** on the Canvases tab
adds a canvas (at most four, and all canvases together at most four times
3840 × 2160 pixels, for GPU memory; it starts at the size of Canvas 1); the buttons
above the editor pick which canvas the editor and the preview show. Each canvas
has its own name and size. All canvases run at the frame rate of Canvas 1: the
**Frame rate** list is only enabled on Canvas 1, and changing it there changes
every canvas. The clock master is set on Canvas 1 too.

- **Which layers:** every layer is on Canvas 1 until you pick another canvas in
  the small list under the layer's name on the Layers screen (the list appears
  once there are two canvases). A layer is drawn only into its own canvas. The
  Canvases tab lists the layers of the selected canvas. This is a project
  setting, not a DMX channel; it needs the programmer role and is refused while
  the show is locked.
- **Which outputs:** on Warp & Slices, every slice has a **Canvas** list: the
  slice takes its picture from that canvas. One output can mix slices from
  different canvases.
- **Remove canvas** (not Canvas 1): its layers and the slices that showed it
  move to Canvas 1, in one step that Undo reverses.
- Adding, removing or resizing a canvas re-creates the canvases: outputs blank
  briefly, so do it before the show. It is refused in show mode and under show
  lock. An undo, redo or project load in show mode that brings back a canvas
  waits for the end of show mode like a size change; until then its layers
  are drawn on Canvas 1 and the slices that show it show Canvas 1, so nothing
  goes dark. If a canvas cannot be made (not enough memory), the canvases go
  back to what renders, the tab shows the error and what was on the missing
  canvas moves to Canvas 1. A layer costs the same layer capacity on any
  canvas; each extra canvas costs one more render pass while it has layers, and
  three textures of its size in GPU memory.
- A slice whose canvas no longer exists (a hand-edited project) stays black and
  the engine log says which slice; pick another canvas for it. A browser
  previewing a canvas that was removed gets an error instead of a frozen
  picture.

The size and rate are saved in the project and used at every start. Developers
who start the engine with `--scene FILE` override them: the scene file's canvas
wins for that run and is shown (and saved, on the next edit) in the project.
Keep the frame rate equal to the refresh rate of the displays (see "Not done
yet": display modes are not set by Fanous).

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
| Mode | the wanted resolution and refresh rate, chosen from the modes the display offers. Applied when show mode turns on (see below); **Current** leaves the display as it is |
| Region x · y · w · h (px) | the part of the display this output draws on; **Full display** resets it |
| Intensity % | multiplied with the Output fixture's intensity and the Master intensity |

### Display modes

Outside show mode Fanous uses whatever mode the display runs and only warns:
the output list shows a yellow line such as "Mode differs: 1920 × 1080 @ 59.94,
wanted @ 60. Applied in show mode." When **show mode** turns on, Fanous
switches every display whose output has a Mode to that mode, all at once, and
logs the old and new mode. Turning show mode off or stopping Fanous puts the
previous modes back. A display that is unplugged and replugged during show
mode gets its mode again.

- 59.94 and 60 Hz (and 29.97/30, 23.976/24) count as the same rate. The exact
  rate is used when the display offers it.
- Resolution means pixels. On a HiDPI display Fanous keeps the current scaling
  when both a scaled and a 1:1 mode have the asked pixel size.
- When the display does not offer the mode, nothing is switched: the output
  list and the readiness check (**Outputs in their desired display mode**,
  a yellow warning) name the closest mode that is available.
- A refresh rate that is not a whole multiple of the canvas frame rate (50 Hz
  for a 60 fps canvas) is warned about the same way: motion judders.
- macOS refuses display changes while the screen is locked. The output then
  says "Not applied: screen locked: modes applied when unlocked", and Fanous
  switches as soon as the screen is unlocked (or wakes) while show mode is
  still on. Any other refusal shows the macOS error the same way, in the
  output list and in the readiness check.
- If several outputs share a display, the first output with a Mode decides.
  An output on the same display that wants another mode says "Conflicts with
  Output N on the same display" in yellow and in the readiness check.
- The Mode list only offers modes macOS marks as usable for the desktop
  (all modes when a display marks none).
- The previous modes are also written to
  `~/Library/Application Support/Fanous/display-modes.json`. If Fanous crashes
  or is killed in show mode, it comes back in show mode and the displays keep
  their show modes; the file stays until you leave show mode, which puts the
  previous modes back. When it starts outside show mode with the file present
  (an older crash), it puts them back and removes the file. A display that is
  unplugged at that moment gets its mode back when it is plugged in again while
  Fanous runs (outside show mode).

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
  or 33x33 points. Changing the density keeps the shape: the new points are
  placed on the current surface, so you can start coarse and refine; going to
  a lower density keeps the overall shape, not the detail between the points
  that remain. The picture
  follows a smooth surface through the points. **Reset mesh** flattens it.
- **Slices**: a slice is a piece of the canvas placed somewhere on the output.
  It takes a rectangle of the canvas (**Source x · y · w · h**, in canvas
  pixels; the tooltip shows the stored 0 to 1 value) and stretches it into a
  four-corner area on the output (the handles). Only the slice chosen in the
  **Slice** list has handles; the others are drawn as outlines. An output starts with one slice
  that shows the whole canvas, so you only need more when one projector covers
  several surfaces that each need their own part of the picture: three screens
  on a stage, the pillars of a facade, a strip next to a screen. **Opacity %**
  per slice; **Add slice**, **Reset slice** (whole canvas on the whole output,
  the mask stays) and **Remove slice** (an output keeps at least one); later
  slices draw over earlier ones. **Spread canvas** makes one picture across all
  slices, for the faces of an object: from left to right on the output, each
  slice gets the next strip of the canvas, as wide as the slice is on the
  output (full canvas height). Fine-tune a seam by changing the w of one slice
  and the x of the next by the same amount. The warp (corner pin, mesh) applies to the whole output on top.
- **Mask**: a mask hides everything of a slice outside its shape (windows,
  doors, the sky above a building). **Draw mask** and then tap the corners of
  the area that stays visible on the picture, in order around it; **Done**
  when you have at least three, **Undo last corner** and **Cancel** while
  drawing. **Rectangle** starts with a rectangle 10 % inside instead. To add
  points to an existing mask, turn on **Add points** and tap where the point
  goes, or double-click anywhere: the point joins the nearest edge. Drag points
  to move them, nudge with the arrow keys or the pad, **Backspace** (or
  **Remove point**) deletes the selected one; a mask keeps at least three.
  **Feather (px)** softens the edge, **Redraw** starts the shape again,
  **Remove mask** deletes it.
- **Content template (PNG)**: downloads a picture at the size of the selected
  slice's canvas that shows, per slice on that canvas, which rectangle it uses and (filled) what its mask
  leaves visible. Give it to whoever makes the content, as a layer under their
  design, so windows and edges land where the mapping expects them.

Canvas 1 is also published as the Syphon server "Fanous – Canvas" (in Syphon's
OpenGL row order; checked upright in the Syphon Simple Client), so
another app on the same Mac can receive it (the other canvases are not
published). Receiving a Syphon server into a layer was checked with a
second engine's canvas, which arrives upright. Other apps' Syphon servers are
layer content in folder 0, files 150–169 (see
[show-control.md](show-control.md#built-in-content-folder-0)).

Editing on this screen needs the programmer role and is refused while the show
is locked.

## Not done yet

- **Hot-plug** (unplug and replug) is only partly tested: through unit tests and
  by binding and releasing the built-in display. Test it on your machine before
  the show (B34).
- Dithering is a simple noise function; if you see banding on a projector, tell
  the developers (B34).
- Not available: per-output Syphon, Syphon for canvases other than Canvas 1,
  a frame rate per canvas, 10-bit output, separate blend gamma for red, green
  and blue.
