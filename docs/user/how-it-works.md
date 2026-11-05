<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# How Fanous works

Fanous turns an Apple Silicon Mac into a media server that your lighting
console drives like any other fixture. This page is the whole picture on one
page; every other page of the guide goes into one part of it. Every term is
in the [glossary](reference/glossary.md).

## Two programs: the engine and the UI

`Fanous.app` holds two programs.

- **The engine** (`fanousd`) does all the work. It runs as a background
  service inside your login: it starts when you log in, and macOS restarts
  it within about a second if it ever crashes. It receives DMX, OSC, MIDI and
  timecode, plays the media, renders the picture to the projectors and
  displays, keeps the project, and serves the UI over HTTPS on port 8443.
- **The UI** is a web page served by the engine. The app window on the Mac
  shows it, and so does any browser on the network: an iPad next to the desk,
  a laptop at front of house. Every UI is a remote control; close all of them
  and the show keeps playing.

Every connected UI shows the same live state. A change made on one shows on
the others at once, and the status bar on every screen says what the engine
is doing: frames, universes, outputs, clients.

## From console to projector

![From console to projector: the console and the other sources feed the patch and Who controls, values reach the layers, layers stack into a canvas, outputs cut the canvas up for the displays, the Master and Output fixtures act on the outputs; the preview, CITP and Syphon report back](images/pipeline.svg)

1. **The console sends DMX.** Fanous listens for Art-Net and sACN on the
   universes in its patch. Each video layer is a 64-channel **Layer fixture**,
   eight to a universe (16 layers need two universes, 32 need four). The
   **Master fixture** (8 channels) and one **Output fixture** per projector
   (8 channels) act on the finished picture: master and output intensity,
   blackout, freeze, test patterns, mapping presets. An optional **Keystone
   fixture** (16 channels) moves an output's corners from the desk. You patch
   them on the console from the GDTF file Fanous exports. See
   [console-setup.md](console-setup.md).
2. **Who controls decides which value counts.** Besides the console, values
   can come from the UI, from Fanous's own cue list (fired by hand, by
   timecode or by a follow time), from OSC and from MIDI. The project's
   **Who controls** setting on the Patch screen picks between console only,
   Fanous only, or both. The layer panel shows, per channel, where its value
   came from.
3. **A layer plays one piece of content.** Layer channels 3 and 4 pick it by
   number: a folder and a file in the media library (`001_Opening/002_intro.mov`
   is folder 1, file 2), or folder 0 (channel 3 at 0) for content Fanous draws
   itself, the cameras and displays of this Mac and Syphon from other apps.
   The other channels set how it plays (loop, once, bounce, timecode, speed,
   in and out points) and how it looks (intensity, position, scale, rotation,
   colour, blend mode, two effects, crop, dissolve). See
   [media-library.md](media-library.md).
4. **Layers stack into a canvas**, the picture the layers are drawn into, in
   pixels. Layer 1 is at the bottom, each higher layer on top of it with its
   blend mode. A new project has one canvas of 1920 × 1080 at 60 fps; a show
   can use up to four, for example one for the projectors and one for an LED
   wall.
5. **Outputs cut the canvas up for the displays.** Each output is a display
   (or a region of one) that shows one or more slices of a canvas: blended at
   the edges where projectors overlap, warped to the surface (corner pin,
   mesh), masked, colour-matched. A projector wall sets up several outputs in
   one go. All of this runs on the GPU after the layers are composited, so it
   does not count against the layer limit. See
   [outputs-and-mapping.md](outputs-and-mapping.md).
6. **Fanous reports back.** The UI shows a live preview of a canvas, a layer
   or an output: H.264 at up to 1280 pixels wide, not in step with the output
   and no colour reference. A console that speaks CITP/MSEX gets the media
   list, thumbnails and a preview stream of Canvas 1; OSC can read every value
   back; other apps on the Mac can take Canvas 1 over Syphon. See
   [show-control.md](show-control.md).

The picture leaves the Mac as 8-bit Rec.709 video at the canvas size and
rate. The engine paces its frames on its own clock at the canvas rate; it is
not locked to a display's refresh, so a display whose refresh is not a whole
multiple of the canvas rate judders (details under
[known limitations](reference/known-limitations.md#outputs-and-mapping)).

## Who wins: the four Who controls settings

| Setting | Rule | Use it for |
|---|---|---|
| **Console only** (the default) | The console's values win. Values from the UI, cues, OSC and MIDI are recorded but do not move anything | a show driven from the desk alone |
| **Fanous only** | The console is shown but ignored; the UI, cues, OSC and MIDI drive the layers | a show without a console |
| **Console and Fanous, latest change wins** | Per parameter, whoever moved last wins (LTP in console terms) | the usual choice when the desk and cues share the work; pick it for rehearsals |
| **Console and Fanous, highest value wins** | Intensity, position and other continuous values take the higher one (HTP); folder, file and modes take the latest change | a UI or cue value that the desk must not beat down |

Three things the rule leaves out:

- The console "moves" a channel only when its value changes. A desk that sits
  at 100 % does not win a latest-change contest against a cue fired later;
  at the same instant the UI or cue value wins. With either "Console and
  Fanous" setting the console takes part only once its DMX has arrived for
  that fixture, so a fixture without an address follows the UI and cues.
- UI and MIDI values that hide a live console value let go after 10 minutes.
  The layer panel counts down ("UI control · console active, releases in
  7:42") and **Keep** restarts the clock; **Release** hands the layer back at
  once. Cue and OSC values never expire.
- The setting applies to the whole project, not per layer. What a universe's
  fixtures do when the console goes silent is a setting of the universe:
  [console-setup.md](console-setup.md#sources-and-merging).

## The project

Everything you set up is one **project** per Mac: the patch and the number of
layers, Who controls, canvases, outputs, walls and mapping presets, the cue
list, timecode and MIDI settings, the universe settings. Fanous saves it two
seconds after your last change, and every setup change can be undone (⌘Z)
and redone.

The engine also keeps **versions** of the project: one at every start and on
entering show mode (unless nothing changed since the last one), one every 10
minutes after a change, one before every revert, and named ones you save
yourself before doors. Any of them can be brought back from System › Project
versions, and the revert itself can be undone.

The media is not in the project. The project and the console only know folder
and file numbers, so the same show runs on a spare Mac whose library has the
same numbers. Role passwords and multi-server sync settings belong to the
machine, not the show. Every file and where it is:
[reference/files-and-ports.md](reference/files-and-ports.md).

## Safe on show day

- **Show lock** (L, or the Locked tag in the status bar) refuses every change
  to the setup, for everyone, while cues, show mode and the timecode switch
  keep working. Locking has no confirmation; L again unlocks (it asks first
  while show mode is on).
- **Show mode** runs the **readiness** list first (power, heat, disk,
  universes, outputs, permissions, macOS settings that interrupt a show), then
  keeps the Mac and the displays awake, pauses the ingest queue, hides the
  cursor on the outputs and switches each display to the mode its output asks
  for. A failed item blocks show mode until it is fixed or a programmer
  acknowledges it; an operator can run the list but not acknowledge, so have a
  programmer login ready before doors. See
  [show-day-checklist.md](show-day-checklist.md).
- **Roles** (monitor, operator, programmer) with their own passwords decide
  what each browser may do. The app window on the Mac is always programmer.
  See [ui.md](ui.md#roles-and-logging-in).
- **When the console goes silent**, each universe's fixtures hold their last
  values unless its settings say otherwise, so a crashed desk leaves the last
  picture up.
- **The engine outlives the UI.** Quit the app, lose the iPad, close the
  laptop: the outputs keep running. If the engine itself is killed while show
  mode is on, it comes back in show mode within about a second; after a
  reboot it resumes show mode when someone logs in within two hours.
- **Several Macs** can play one picture in step, each its own part of it. See
  [multi-server.md](multi-server.md).

When something goes wrong, [troubleshooting.md](troubleshooting.md) starts from
what you see.
