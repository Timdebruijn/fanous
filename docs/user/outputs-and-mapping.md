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

**Black lift (%)** (0 to 50) raises the black level so it matches the overlaps,
where the blacks of two projectors add up. On an output with overlaps on one
axis it lifts the area outside the overlaps; **Lift feather px** softens where
the lift ends. Use Grey 0 % (or Grey steps) to match it by eye.
On an output with overlaps both across and down (a wall with rows and columns)
every point rises to the black level of the corner where four projectors
overlap: the lift then shows its value in the two-projector overlaps and about
1.6 times it where one projector lights alone, and the feather softens each of
those steps. A project tuned with a version before M2.1 needs Grey 0 % checked
again.
The lift adds light, as a second projector's black does, so a lift set on
Grey 0 % stays right on brighter pictures (see the note under Test patterns).
Grids work: a corner pixel gets the product of the horizontal and vertical
ramps.

### Test patterns

Buttons: Off, Grid, Colour bars, Blend check, Output ID, Crosshair, Grey steps,
Checkerboard, Grey 0 %, Grey 25 %, Grey 75 %, White. The Test pattern channel
of the Output fixture (per projector) and of the Master (all outputs) overrides
the button, so a console can call them up.
Patterns follow the corner pin and mesh and show the blend map; set the Output
fixture's **Blend** channel to 128 or more (Raw) to see them without blend and
warp. Line widths and cells follow the output's height, so a pattern reads
the same on a monitor and on a 4K projector.

Patterns follow the same Dimmer and Blackout as the picture: the output's
Intensity %, the Output fixture's Intensity and the Master's Intensity dim
them, and an Output or Master Blackout makes them black, also in Raw. A
console's Grand Master or DBO therefore takes a pattern down with the rest; to
focus or align, bring the Output and Master Intensity up (both are 100 % when
nothing is patched).
Freeze holds the picture, not the pattern: a pattern shows live over a frozen
output, and the held frame is back when the pattern is switched off.

| Pattern | Use it for |
|---|---|
| Grid | alignment: centred square cells, border (overscan), centre cross, a circle for aspect ratio, diagonals |
| Colour bars | 75 % SMPTE bars and 100 % white/red/green/blue/black: colour and level match between projectors |
| Blend check | flat 50 % grey shows a blend seam as a bright or dark band; grid lines in this output's own colour let two overlapping projectors be laid on top of each other |
| Output ID | the output number, large, on the output's colour: which projector is which |
| Crosshair | centre and focus, circles every 1/8 of the height |
| Grey steps | 0–100 % in 10 % steps (top) and 0–10 % in 1 % steps (bottom): gamma and black level, black lift |
| Checkerboard | focus and pixel geometry |
| Grey 0 % | black floor: a seam lighter than the rest needs more black lift on the projectors next to it |
| Grey 25 % | dark-grey match: one projector darker than its neighbours or tinted, or a colour shift only inside a seam |
| Grey 75 % | light-grey match, as Grey 25 %, where the projectors' upper range differs |
| White | full-level match: brightness and colour of each projector, and a seam that stays bright or dark at full level |

Grey 0 %, 25 % and 75 % and White are flat fields at that output signal level
(25 % is code 64 of 255, 75 % is 191) with every intensity at 100 %, on the
same scale as Blend check's 50 % grey. A
console calls them up on Test pattern channel 4: 128 Grey 0 %, 144 Grey 25 %,
160 Grey 75 %, 176 White.

These are signal levels: on a gamma-2.2 projector Grey 25 % is about 5 % of
white's light, Grey 75 % about 53 %. The black lift and the black offset
(below) add the light they give on black, computed for a gamma-2.2 projector:
set them on Grey 0 %, and a brighter picture gets only that bit of light more.
On an output blended on one axis a lift of 8 % shows as 8 % on Grey 0 % outside
the overlaps, but raises Grey 25 % only from 64 to 66 of 255 (versions before
M1.7 added the 8 % as signal, 64 to 84, so a lifted area looked brighter at mid
greys). On an output blended on both axes the single-projector area shows about
13 % and Grey 25 % goes from 64 to 71 there (see [Blend edges](#blend-edges)).

The first seven patterns, a moving test card and a few more are also available
as layer content in folder 0 (see
[show-control.md](show-control.md#built-in-content-folder-0)); for a flat grey
on a layer use Solid colour (file 100) with the layer's Red, Green and Blue.

### Colour

Under the test patterns, **Colour** matches this projector to the others by
eye. Look at Colour bars, Grey steps, Grey 25 %, Grey 75 % or White on all
projectors at once and turn the one that is off.

| Control | Range (start) | What it does |
|---|---|---|
| Gain R, Gain G, Gain B | 0–200 % (100 %) | scales that colour of everything this output shows: lower the channel that is too strong on a tinted projector, or all three on one that is too bright |
| Black offset | 0–20 % (0 %) | raises this projector's black over the whole output, overlaps included: for a projector whose black is darker than its neighbours' |

- The gain scales the signal, not the light: on a gamma-2.2 projector 50 %
  gain is about a fifth of the light. Tune by eye, in small steps.
- The black offset adds light like the black lift does (see the note above):
  it shows its full value on Grey 0 % and adds only that light on brighter
  pictures.
- Colour applies to the picture and to the test patterns, and after it the
  output's intensity: an Output or Master Blackout, or an intensity at 0, is
  black, black offset included.
- Gain and black offset also apply in Raw (the Output fixture's Blend channel
  at 128 or more): they belong to the projector, not to the mapping, so its
  colour does not change while you align. Raw leaves out the blend ramps and
  the black lift.
- Drag a slider or tap **−** and **+** for fine steps (0.5 % gain, 0.1 % black
  offset). A drag is one step for **Undo**. In a projector wall the same
  controls are on the wall panel when you tap a projector.

## Projector walls

A **projector wall** is two to sixteen projectors that together show one
picture: side by side, stacked, or a grid of up to 4 × 4. Fanous keeps the two
kinds of work apart:

- **Geometry** is computed. From the grid and the overlap the wall gives each
  projector its part of the canvas (slice 1's source) and sets the overlap of
  the inner blend edges, equal on both sides of every seam. That is always
  right for projectors hung as that grid.
- **Tuning** is done by eye: gamma and curve per seam, black floor and colour
  per projector. No start value fits every room, because projector age, ambient
  light and the surface differ. The **seam check** below is the route.

All wall controls need the programmer role and are refused while the show is
locked; they are greyed out with the reason.

### New projector wall

**New projector wall** (above the output list on the Outputs tab) opens a
wizard. Every output of the wall needs a pixel size: a connected display, or a
region or display mode. The outputs of one wall need the same pixel size.

1. **Order.** Every output on a display shows its Output ID, a large number.
   Tap the tiles in the order the projectors hang: the top row from left to
   right, then the next row. A second tap takes a tile out again. Then pick the
   grid (rows × columns); only grids that fit the number of tiles are offered,
   for four tiles 1 × 4, 2 × 2 and 4 × 1. The drawing below shows where each
   output lands.
2. **Overlap and canvas.** The overlap is a percentage of one projector,
   15 % to start with; the line below says how many pixels that is. Below
   10 % or above 25 % a yellow line says why that is unusual. Then choose:
   - **Use Canvas N** as it is: the wall stretches over that canvas. The
     wizard says the wall's size at projector resolution, so you can see
     whether the canvas has the same shape.
   - **Make Canvas N fit the wall**: the canvas becomes the wall's size (the
     size is shown before you apply; a very large wall is scaled down whole to
     stay within the canvas limits). Every output blanks briefly. This is not
     possible in show mode.
3. **Make wall.** Blend check appears on every projector of the wall and the
   wall's panel opens on the seam check.

**Cancel** at any step changes nothing: each output gets its own test pattern
back. **Undo** right after Make wall takes the wall away again.

### The wall panel

Each wall has a panel above the output list, built around a **map** of the
wall: one tile per projector (name, Output ID, row and column) and the seams as
lines between them, each with its gamma (**RGB** when R, G and B are set apart).

- **Tap a seam** for its controls. Both sides of the seam always follow.
  - **Gamma** (0.5 to 5, 2.2 to start): down for a bright band in the seam,
    up for a dark one.
  - **Link R, G, B** is on: one gamma for all three colours. Turned off,
    **Gamma R**, **Gamma G** and **Gamma B** replace the single gamma, each
    starting at the single gamma's value, and each changes its own colour in the seam: use
    them for a colour shift only inside a seam. Turning the link on again
    drops the per-colour values and the single gamma is back.
  - **Curve** (0.1 to 10, 2 to start): how steep the fade is; change it when
    you see an edge where the overlap starts.
  - **Apply to all seams** gives every seam of the wall this seam's values:
    its R, G and B when they are unlinked here, else one gamma (other seams
    lose their own R, G and B).
  - Drag a slider or tap **−** and **+** for fine steps. A drag, or taps less
    than a second apart, are one step for **Undo**.
- **Tap a projector** for its **black floor** (the output's Black lift):
  it lifts the black to match the overlaps, where the blacks of two (or, on a
  wall with rows and columns, four) projectors add up. Below it are the projector's **Gain R, G, B** and **Black offset**
  (see [Colour](#colour)): the gain for a projector that is darker or tinted
  next to its neighbours, the black offset for one whose black is darker
  everywhere. **Open in Warp & Slices** takes you to that projector's warp.
- **Geometry**: the overlap across and down (in %), **Edit layout…** (the
  wizard again, filled in: change the order, the grid, the overlap or the
  canvas) and **Remove wall**. Removing a wall keeps the outputs as they are
  now; Undo brings the wall back.
- In the output list a wall output carries a badge such as "Wall 1 · r1 c2".

**Manual fields.** If you type an inner edge's overlap on the Outputs tab, or
change slice 1's source on Warp & Slices, that field becomes **manual**: it
shows a yellow "manual" chip, and the wall leaves it alone from then on, also
when you change the wall's overlap. **Back to wall** next to the chip gives the
field back to the wall. A power or gamma typed on an inner edge goes to its
seam, so the neighbour follows. An edge whose seam has R, G and B set apart
shows the three values instead of a gamma field; **One gamma for R, G, B**
there links them again.

### Seam check

**Seam check** on the wall panel steps through test patterns on every
projector of the wall at once. Each step says what to look for and which
control to turn. Tap a line of the card, then tap the seam or projector on the
map that shows the problem: its control opens, outlined. (Without a camera
Fanous cannot know which seam is off, so your eye picks it.)

| Step | You see | Turn |
|---|---|---|
| Grid | lines that do not meet across a seam | the warp, not the blend: tapping the projector opens Warp & Slices |
| Blend check (50 % grey) | a bright band in a seam | that seam's gamma, down |
| | a dark band | that seam's gamma, up |
| | a visible edge where the overlap starts | that seam's curve |
| Grey 0 % | seams lighter than the rest | the black floor of the projectors next to it, up, one by one until even |
| Grey 25 %, Grey 75 %, White | one projector darker, or tinted | that projector's colour gain, the colour that is off: tapping the projector opens its Gain R, G, B |
| | a colour shift only inside a seam | unlink R, G, B on that seam and tune the colour that is off |

On a wall with rows and columns the black of Grey 0 % now rises to the black
level of the corner where four projectors overlap, so a wall tuned with a
version before M2.1 needs its Grey 0 % step checked again.

You can switch to Warp & Slices during the check, for example to fix the
warp: a yellow line there says the check is still running and takes you back.
**End seam check**, or leaving the Outputs screen, gives each output its own
test pattern back (leaving the screen also cancels the wizard). Every pattern
change is an ordinary output change, so it is also a step for Undo.

An output keeps its own pattern on record until it really has it back. While
the show is locked, or without the programmer role, the check stays open and
says so: unlock the show and end it again. If the page is reloaded during the
wizard or the check, the Outputs screen offers **Give the test patterns back**
(or **Keep them**).

## Warp & Slices tab

Choose what to edit with **Corner pin**, **Mesh**, **Slices** or **Mask**.
Handles sit over the output preview. Drag them with mouse or finger (the hit
target is large for touch); with a handle selected the arrow keys move it by one
output pixel, Shift by ten, Tab and Shift-Tab select the next and previous
point, and Esc lets go of it. On an iPad use the **nudge pad** that appears under
the mode buttons once a point is selected: arrows move by 1 px, the **10 px**
key in the middle makes every press move ten, and holding an arrow for half a
second moves 0.25 px. A selected point also shows
numeric x and y fields in pixels. Changes go to the engine while you drag.

**Remote mode** is for aligning from an iPad while you look at the projection
instead of the screen. Turn it on with **Remote** next to the mode buttons; it
is on by default on touch screens narrower than 900 px, and each browser
remembers your choice. The controls then come before the preview:

- The selection in large type: "corner top-left", "r3 c5" (row 3, column 5 of
  the mesh), "slice 2 · bottom-right", "slice 2 · mask point 5", or a group such as
  "row 3" with how many points move together.
- **Previous** and **Next** go through the points row by row (left to right,
  then the next row) and wrap around. With a group selected they step the
  group: the next row, the next column, or the next edge clockwise.
- **One point**, **Row**, **Column** (mesh only) and **All** choose what moves:
  the selected point, its row or column, or every point. **Top**, **Right**,
  **Bottom** and **Left** select every point on that edge; on a corner pin or a
  slice an edge is its two corners. A mask has no rows, columns or edges.
  Tapping or dragging a handle on the picture selects just that point again
  (**One point**), and so does turning Remote off or picking another output.
- The nudge pad moves the selection by 1 px, 10 px, or 0.25 px on a long press.
  The points always move as one: when the first of them reaches the edge of the
  output, or under a warp cannot go further, the group stops there instead of
  being squeezed or bent.
- The **trackpad** area beside it moves the selection as you drag, so your
  finger never covers the picture: 1 output pixel per 4 screen pixels of finger
  travel, four times as far when you drag fast.

Distances are output pixels as seen on the projector, also under a corner pin
or mesh. Moves go to the engine up to ten times a second; taps in between are
added up, so none is lost. Nudges of the same point or the same group less than
a second apart are one step for **Undo**. Without the programmer role, or while
the show is locked, you can still select and step through points, but not move
them.

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

## Keystone from the console

The **Keystone** fixture (16 channels, see
[console-setup.md](console-setup.md)) moves an output's four corners from the
console, on top of the alignment you made here: for moving scenery, or a quick
fix from FOH without touching the hand alignment.

- Patch one per output, next to its Output fixture: "Keystone 1" belongs to
  Output 1. The Patch screen lists a Keystone row under every Output row; it is
  not in the standard patch, so set its address when you want it.
- Each corner has an X and a Y channel, 16-bit, from −50 % to +50 % of the
  output's width or height; + moves right or down. The default, 32768 (50 %
  on a fader), is no change, so a centred or unpatched Keystone leaves the
  output as aligned.
- The whole mapping moves: every slice and test pattern, with their masks. The
  blend ramps and the black lift stay where they are on the projector, so the
  overlap of a wall stays put while the picture moves.
- Raw on the Output fixture (Blend channel 128 or more) shows the output
  without blend, warp and keystone, for alignment.
- The preview and the Warp & Slices handles show the mapping as you edited it,
  without the keystone, so a handle stays where you drag it. The output row
  and the Warp & Slices tab say **Keystone active** while it moves the output.
- Corners that would fold the picture (one pulled onto or past the line
  between two others) are refused: the output keeps the last keystone that
  worked and shows **Keystone invalid** in yellow until the console sends
  corners that work again.
- OSC: `/fanous/keystone/{n}/topLeftX` and the other keys of the channel map.

## Not done yet

- **Hot-plug** (unplug and replug) is only partly tested: through unit tests and
  by binding and releasing the built-in display. Test it on your machine before
  the show (B34).
- Dithering is a simple noise function; if you see banding on a projector, tell
  the developers (B34).
- Not available: per-output Syphon, Syphon for canvases other than Canvas 1,
  a frame rate per canvas, 10-bit output.
- Projector walls: the outputs of one wall need the same pixel size.
- Colour, black lift and black offset assume a gamma-2.2 projector; there is no
  per-output gamma for them yet.
