<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Glossary

Every term the guide uses, in one or two lines, for a lighting technician who
has not driven video from a console before. Lighting terms are here where
Fanous behaves differently from a desk or a node (universe numbering, Art-Net
and sACN merging) or where a video person means something else by them
(keystone, master). Terms are grouped by where you meet them; use your
browser's find for a word. Back to the [index](../README.md).

## The picture

| Term | Meaning |
|---|---|
| **Layer** | One piece of content with its own position, size, colour, effects and intensity. Fanous has up to 32; each is a 64-channel fixture on the console. Layer 1 is at the bottom of the stack. |
| **Canvas** | The picture the layers are drawn into, in pixels (1920 × 1080 at 60 fps in a new project). A project can have up to four, for example one for the projectors and one for an LED wall. Nothing is shown until an output takes it to a display. |
| **Output** | What goes to one display or projector: a display (or a region of it), an intensity, blend edges, a warp, one or more slices, masks and colour. Each output is also an 8-channel Output fixture on the console. |
| **Display** | A physical screen, projector or LED processor as macOS sees it: the built-in panel or anything on a video port. An output is **bound** to a display, **unassigned** when it has none, or **lost** when its display went away. |
| **Region** | The part of a display an output draws on, in pixels. The default is the full display; one display can carry several outputs, for example a 4K port into a splitter. |
| **Slice** | A rectangle of the canvas placed somewhere on an output. Every output starts with one slice that shows the whole canvas; more are needed only when one projector covers several surfaces (three screens, pillars, a strip next to a screen). |
| **Fit mode** | How a layer's content is sized into the canvas: **Fit** (whole picture visible, bars where the shapes differ), **Fill** (covers the canvas, edges cut off), **Stretch** (distorted to fit), **Native** (one content pixel is one canvas pixel). Layer channel 23. |
| **Blend mode** | How a layer mixes with the layers below it: Normal, Add, Screen, Multiply, Subtract, Difference, Lighten, Darken. Layer channel 37. Not to be confused with blend *edges* on an output. |
| **Alpha** | Transparency stored in the file (ProRes 4444, HAP Alpha, PNG). Where the alpha is zero the layers below show through. The Media screen marks such files with **α**. |
| **Still** | An image file on a layer: PNG, JPEG, TIFF, HEIF, GIF (first frame), BMP, WebP, EXR. |
| **Image sequence** | A folder of numbered stills inside a numbered folder, played as a movie after transcoding. |
| **Frame rate** | Frames per second of a file, the canvas or a display. Written as in `1080p25`: 1080 lines, progressive, 25 fps. The display's refresh rate should be the canvas rate or a whole multiple of it (60 fps on a 120 Hz panel is fine; 24 fps on 60 Hz judders). 59.94 and 60 count as the same rate for Fanous, but a 59.94 Hz display showing a 60 fps canvas repeats a frame about every 16 s. |
| **Pixel aspect ratio** | Some sources (anamorphic 1440 × 1080 shown as 16:9) have non-square pixels. Fanous keeps the tag and draws the file at its intended width. |
| **4K** | 3840 × 2160 pixels. "4K60" is that size at 60 fps, four times the work of 1080p60. |

## Files and the library

| Term | Meaning |
|---|---|
| **Library** | The folder on the Mac that holds the media: `~/Movies/Fanous Library` unless you change it. Numbered folders with numbered files. |
| **Folder and file number** | The first one to three digits of a folder or file name, 1 to 255. The console dials media by these two numbers (layer channels 3 and 4), never by name. `001_Opening/002_title.png` is folder 1, file 2. |
| **Folder 0** | Not a folder on disk: the content Fanous makes itself (test card, clock, solid colour), the cameras and displays of this Mac and the Syphon servers of other apps, each with a file number. Dial it with channel 3 at 0 and channel 4 at the file number (the channel map's "0 = none" is the case with channel 4 at 0 too). See [Built-in content](../reference/built-in-content.md). |
| **Codec** | The way the pictures in a movie file are compressed. Fanous plays two families directly: ProRes and HAP. Everything else is re-encoded first. |
| **ProRes** | Apple's production codec. Apple Silicon Macs (except the base M1) decode it in dedicated hardware, which is why Fanous needs such a Mac. 422 HQ is the usual choice; 4444 carries alpha. |
| **HAP** | A codec made for media servers: the file holds GPU texture blocks, so the CPU only unpacks them and the GPU reads them directly. Very light to play, but the files are several times the size of ProRes, so the disk's read speed matters. HAP Q is the quality variant, HAP Alpha carries transparency. |
| **All-intra** | Every frame is stored complete, so the player can jump, scrub, run backwards and chase timecode. ProRes and HAP are all-intra. |
| **Long-GOP** | H.264, HEVC and most phone and web video: most frames are stored as differences from earlier frames. Fine for playback in a browser, bad for scrubbing and reverse, so Fanous does not play it and offers **Transcode** instead. Other all-intra codecs (DNxHR, Cineform, MJPEG) are transcoded too: only ProRes and HAP play as they are. |
| **Container** | The file wrapper: `.mov`, `.mp4`. Fanous plays `.mov` with ProRes or HAP directly; the other containers it knows (`.mp4`, `.m4v`, `.avi`, `.mkv`, `.mxf`) show as **needs transcode**. |
| **Transcode** | Re-encode a file into ProRes or HAP so it plays. Done by the ingest queue; the original moves to `_originals/`. |
| **Import** | Upload a file from the browser into a numbered folder. Every imported movie is transcoded; stills are copied. |
| **Ingest queue** | The panel at the bottom of the Media screen that runs imports and transcodes, one at a time, paused in show mode. |
| **Thumbnail** | One frame from the middle of each file, 320 pixels wide, shown on the Media screen, on a layer that plays nothing and on the console over CITP. |
| **Probing** | The engine reading a new file's codec, size, length and alpha and making its thumbnail. A tile says "probing…" meanwhile. |

## Mapping

| Term | Meaning |
|---|---|
| **Soft-edge blend** | Two projectors overlap by a strip; each fades out across the strip so the sum is flat. Fanous calls the strip the **overlap** of a **blend edge** (left, right, top, bottom of an output). |
| **Power, Gamma** (blend) | The shape of the fade across the overlap. Gamma should match the projector (2.2 is usual) so the two ramps add up to a flat field; Power is how steep the S-curve is. |
| **Black lift** | Projectors are never fully black. Where two overlap, the blacks add up and the seam shows on a dark picture. Black lift raises the black of the rest of the output to match. Set per output on the Outputs tab (0 to 50 %). |
| **Black floor** | The wall panel's name for the same value, for one projector of a wall; its slider runs 0 to 20 %. One setting, two labels. |
| **Black offset** | A different setting: raises this projector's black over the whole output, overlaps included, for a projector whose black is darker than its neighbours'. Under Colour (0 to 20 %). Which one when: a seam lighter than the rest wants black lift; a whole projector darker than the others wants black offset. |
| **Gain R, G, B** | Scales one colour of everything an output shows, to match a tinted or brighter projector to the others by eye. |
| **Warp** | Bending the whole output picture so it lands straight on the surface. Two kinds: **corner pin** (four corners; a flat surface seen at an angle) and **mesh** (a grid of up to 33 × 33 points; a curved or uneven surface). |
| **Keystone** | In Fanous: a 16-channel console fixture that moves an output's four corners on top of the hand alignment, for moving scenery or a quick fix from the desk. A projector's own keystone setting is something else. |
| **Mask** | A shape that hides part of a slice: everything outside an **add** mask, everything inside a **subtract** mask. Polygon, rectangle, ellipse, freehand or a greyscale image. |
| **Feather** | Softening of a mask edge or of where the black lift ends, in pixels. |
| **Projector wall** | Two to sixteen projectors that show one picture as a grid of up to 4 × 4. The wall computes each projector's slice and overlaps; you tune the seams by eye. |
| **Seam** | The overlap between two neighbouring projectors of a wall, with its own gamma and curve. |
| **Seam check** | The wall panel's guided walk through test patterns, one symptom at a time, that tells you which control to turn. |
| **Test pattern** | Grid, colour bars, blend check, output ID, crosshair, grey steps, checkerboard and flat greys, drawn on an output for alignment. Called up with buttons or from the console. |
| **Raw** | The Output fixture's Blend channel at 128 or more: the output without blend ramps, black lift, masks, warp and keystone, for alignment. Colour gain and black offset still apply. |
| **Align** | What the Outputs screen calls the warp, blend and mask work on one output: **Align this output** opens the Warp & Slices tab for it. |
| **Mapping preset** | A stored alignment (warp, slices, masks) under a number 1 to 255, so an output can switch between surfaces from the console (Output channel 6) with a timed glide (channel 7). |
| **Show on output** | Draws the warp lines, slice outlines and the selected point on the projector itself while you edit, so you can align while looking at the surface. |
| **Content template** | A PNG at canvas size that shows the content maker where each slice and mask lands. |
| **Clock master** | The display the compositor hands its frames to first; when that display is behind, the compositor waits for it. Fanous still runs its own clock at the canvas rate, not the display's refresh, so this is pacing, not genlock. The first bound output unless you pick another on the Canvases tab. |
| **Display mode** | A display's resolution and refresh rate as macOS lists them. An output can ask for one; show mode applies it. |
| **Extended, mirrored** | macOS can show the same picture on two displays (mirrored) or treat them as separate (extended). Fanous needs **extended**: a mirrored display cannot be an output of its own. |

## Console, protocols, control

| Term | Meaning |
|---|---|
| **Fixture** | On the console, one patched unit with a DMX address. Fanous has one fixture type, "Fanous", with four modes: Layer (64 ch), Master (8), Output (8), Keystone (16). |
| **Universe** | 512 DMX channels. Fanous writes Art-Net universes as `A net.subnet.universe` (`A 0.0.1`) and sACN universes as `S n`. `A 0.0.0` is port-address 0; a console that counts from 1 calls it universe 1. sACN universes run from 1 to 63999: there is no sACN universe 0. |
| **Art-Net** | DMX over Ethernet, UDP port 6454, usually broadcast. Fanous does not merge Art-Net: the latest packet for a universe wins, so two consoles on one Art-Net universe fight. Send each universe from one console. |
| **sACN** (E1.31) | DMX over Ethernet, UDP port 5568, multicast, with a **priority** per source: the highest priority wins; at equal priority the latest packet wins, or the channels merge by highest value if the universe is set so. A source silent for 2.5 s drops out. Per-address priority is not supported. |
| **Who controls** | The project setting that decides how the console's values combine with values from the UI, cues, OSC and MIDI: Console only, Fanous only, or both with latest change wins (LTP) or highest value wins (HTP). On the Patch screen. |
| **Source** | Where a layer's current values come from: the badge on the Layers screen says Console, Fanous, Both · latest or Both · highest. |
| **Hold on signal loss** | What a universe's fixtures do when its packets stop: hold their last values (default), go to zero, or let the UI and cues take over. |
| **GDTF** | The fixture-description file format consoles import. Fanous exports one from the Patch screen, generated from the same table as the channel map. |
| **CITP / MSEX** | The protocol some consoles implement to browse a media server's layers, media lists, thumbnails and a preview stream (grandMA2, MagicQ, Hog 4, Onyx and Titan implement it; grandMA3 and Eos do not). Not yet tested against a real console, see [known limitations](known-limitations.md#consoles-and-protocols). |
| **OSC** | Open Sound Control: short network messages such as `/fanous/cue/go` that apps and controllers (QLab, Companion, TouchOSC) send to Fanous and can read back. UDP and TCP port 8000. |
| **MIDI** | Notes, controllers (CC) and program changes from a controller (APC, Launchpad, a keyboard) that fire cues or move parameters. Input only. |
| **MSC** | MIDI Show Control: a show controller's GO message with a cue number, sent over MIDI. Fanous acts on it when the **MSC device id** (0–111, or the all-call 127) and the **MSC format** (Video by default, Lighting for most desks) match. |
| **Subscribe, cookie** | How an OSC controller gets changes pushed to it: it asks, Fanous sends a one-time code (the cookie) to the address it named, and the controller sends the code back within 5 s. |
| **Note, CC, program change** | The three MIDI messages Fanous maps: a note is a pad or key pressed and released, a controller (CC) a fader or knob from 0 to 127, a program change a patch number. |
| **Timecode** | A running clock `hh:mm:ss:ff` (hours, minutes, seconds, frames) from the sound or show system that layers and cues can follow. |
| **LTC** | Timecode as an audio signal, on one channel of an audio interface. |
| **MTC** | Timecode sent over MIDI. |
| **Drop frame** | 29.97 fps timecode that skips two frame numbers each minute (except every tenth) to stay on clock time; no picture is dropped, only numbers. Written `29.97 DF`; non-drop is `29.97 NDF`. Fanous reads 24, 25, 29.97 DF and NDF and 30; chase at 29.97 DF is not yet tested with real hardware. |
| **Freewheel** | When timecode stops arriving, the clock keeps running for the Freewheel time (2 s by default) before the state goes to **Lost**. |
| **Tracking** | How Fanous cues work: a cue sets only the values it holds, and every other value stays where the last cue left it. A cue that takes a layer out needs its intensity at 0. |
| **Trigger, Follow** | A cue's two automatic fires: a trigger fires it when timecode passes `hh:mm:ss:ff@rate`; a follow fires the next cue that many seconds after this one. |
| **Chase** | A layer whose position in its file is locked to the timecode (Play mode Timecode, channel 5 at 128 to 143), offset by the Offset field. |
| **Dissolve** | Layer channel 12: how long a new file crossfades in when the media changes. Read when the new file's first frame is ready. |
| **Cue** | A numbered step in Fanous's own cue list: parameter values with a fade, optionally fired by a timecode trigger or a follow time. |
| **Retrigger** | Layer channel 50 at 8 to 15: restart the clip from its in point. It fires once, when the channel enters the band; a value held there does not loop the clip. Return the channel to 0 before the next retrigger. |
| **Blackout** | Master channel 3 at 128 to 191 (all outputs) or Output channel 3 at 64 to 127 (one output): the picture and the test patterns go black. A console's DBO or Grand Master does the same through the intensities. |
| **Machine id** | The first 8 characters of a Mac's install id, shown under System › Sync; it names a Mac in the sync badges and decides which of two Sync masters wins (the lower one). Two Macs installed from one cloned disk share it and ignore each other. |
| **Broadcast** | A packet every machine on the network segment receives (Art-Net and sync use it); multicast reaches those that joined a group (sACN, CITP). Broadcast and CITP stay within one subnet. |
| **Sync master, Sync slave** | Layer channel 51: a layer that sends its clock to a group (master) or follows that group's clock (slave), so layers on several Macs play in step. Not the Master fixture. |

## Engine, UI and measurements

| Term | Meaning |
|---|---|
| **Engine** | `fanousd`, the program that does the work: DMX, decoding, rendering, the web server. Runs as a background service inside your login and keeps playing when the app window is closed. |
| **The app window** | `Fanous.app`: the window that shows the UI on the Mac, with the Engine menu. Always programmer. |
| **Web UI** | The same screens in any browser on the network at `https://<mac>.local:8443`; an iPad is the intended second screen. |
| **Role** | What a browser may do: **monitor** (look), **operator** (cues, show mode, readiness, timecode switch), **programmer** (everything). Each role can have a password. |
| **Show lock** | The L key or the Locked tag: refuses every change to the setup while cues, show mode and the timecode switch keep working. |
| **Show mode** | Runs the readiness list, then keeps the Mac awake, pauses the ingest queue, hides the cursor on the outputs and applies display modes. |
| **Readiness** | The list of checks on the System screen (power, heat, disk, universes, outputs, permissions, macOS settings). A failed item blocks show mode until fixed or acknowledged. |
| **Project** | Everything you set up, one per Mac: patch, Who controls, canvases, outputs, walls, presets, cues, timecode and MIDI settings. Saved by itself; **versions** of it can be restored. |
| **Clients** | Browsers and app windows connected to the engine. A **lagging** client is one that cannot keep up with the state updates. |
| **Preview** | The live picture in the UI: H.264 through the browser's decoder, or JPEG at 5 fps when the browser cannot decode it. At most 1280 pixels wide, not in step with the output and no colour reference: judge motion and colour on an output. |
| **Syphon** | A macOS way for apps on the same Mac to share video frames. Fanous publishes Canvas 1 and can take other apps' servers as layer content (folder 0, files 150 to 169). |
| **Capture card** | A USB or Thunderbolt box that turns an HDMI or SDI signal into a camera for the Mac. UVC cards (Elgato Cam Link, Magewell) appear as cameras. |
| **Screen recording permission** | The macOS permission Fanous needs to show one of this Mac's displays on a layer. macOS asks again about once a month. |
| **Dropped frame** | A canvas frame that was not shown on time: **missed** (not rendered) or **late** (rendered, but after the display's deadline). |
| **p50, p99** | Of the frame times in a window, the middle one and the one that 99 % stay under. p99 is the slowest frame in a hundred: the number to watch. |
| **Frame budget** | The time one frame may take: 16.7 ms at 60 fps, 40 ms at 25 fps. GPU p99 above it means dropped frames. |
| **DMX to photon** | Time from a DMX change arriving to the engine handing the frame that shows it to the display: measured p99 about 30 ms on the M1 Pro at 60 fps. The display's or LED processor's own delay comes on top and is not measured. |
| **Texture miss** | A layer that had no decoded frame ready when the compositor needed it: the previous frame is shown again. |
| **dBFS** | Decibels relative to full scale, for the LTC level meter: 0 is the loudest the input can take, −3 is close to clipping, −60 is silence. |
| **Bonjour** | macOS's way of announcing services on the local network; Fanous appears as `_fanous._tcp` and `_https._tcp`. |
| **TLS fingerprint** | The SHA-256 checksum of the engine's self-made certificate, shown under System › Network, to confirm a browser's certificate warning. |
