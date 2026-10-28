<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Media library

The library is a folder on the Mac, `~/Movies/Fanous Library` unless you
choose another one (see "Change the library root" below). The console
picks media by number: channel 3 (Folder) and channel 4 (File) of a Layer. Show
files store those numbers, never paths, so a library on another Mac works as
long as the numbers match.

Use a folder on a local disk. Network volumes are not supported.

## Folder and file names

```
Fanous Library/
├── 001_Opening/
│   ├── 001_intro_loop.mov
│   ├── 002_title.png
│   └── _originals/002_title.psd     ignored
├── 012_Show/
│   └── 004_intro_loop.mov
└── _incoming/                       uploads on their way in
```

- The folder number is the first one to three digits of the folder name; the
  file number is the first one to three digits of the file name. Both must be
  **1 to 255**. Anything that is not a digit may follow (`001_Name`, `12-Show`,
  `7 intro.mov`). 0 means "none" on the console.
- Folders and files whose names start with `_` or `.` are ignored. Files that
  are not media are ignored.
- These are **invalid** and can never be reached from DMX: no number prefix,
  number 0 or above 255, four or more digits, and duplicates (when two
  names carry the same number, the one that sorts first alphabetically keeps it).

The Media screen (key 2) shows invalid items in red: a folder row gets an
"N invalid" badge, a file tile gets an "invalid name" badge with the reason
("no 1-255 prefix", "duplicate file number 4", "folder: duplicate folder number
3"), and the header counts "N invalid name". An invalid folder has no number in
the list. The library is watched, so a rename in Finder shows up after a moment;
**Rescan** (the circular arrow) forces it.

A layer that points at a number that does not exist, or at a file that is not
playable, shows the red message "no file N in folder M" on the Layers screen.

The first row of the folder list, **0 · Built-in and Syphon**, is folder 0: the
content the engine draws itself and the Syphon servers of other apps on this
Mac, each with the file number a console dials (see
[show-control.md](show-control.md#built-in-content-folder-0)). Select an item
and use **Play on layer** to put it on a layer from here.

## Create a folder

On the Media screen press **New folder**, type a number (the first free one is
filled in; 1 to 255) and a name, then **Create**. The engine makes
`NNN_name` under the library root (and the root itself if it is missing). You can
also make folders in Finder. Creating folders is for the programmer role. If the
screen says "The library root does not exist", create a folder this way or make
`~/Movies/Fanous Library` yourself.

## Change the library root

On the System screen (Machine › Library) type the path of another folder and
press **Apply**. `~` stands for your home folder. The change takes effect at
once: the engine stops watching the old folder, indexes the new one and every
layer looks up its folder and file number again in the new library. A layer
whose number does not exist there shows "no file N in folder M"; the outputs
keep running. A file the engine has not seen before shows that message until it
has been probed (a moment per file), then it plays. While the switch runs (the
scan of a large library can take a few seconds), entering show mode and adding
ingest jobs are refused; try again a moment later. Metadata and thumbnails are cached per file, so switching back to
a library that was used before needs no new probing.

- The folder must already exist and be readable; the engine does not create it
  or any numbered folders in it. Make it in Finder first, then create numbered
  folders with **New folder** on the Media screen.
- The change is refused in show mode, under show lock, and while ingest jobs
  are queued or running (they write into the old library): let them finish or
  cancel them first.
- Changing the root is for the programmer role. The monitor role never sees the
  path.
- Undo and redo work on the root like on any other setting.

## Formats

| Plays directly ("native") | Notes |
|---|---|
| ProRes 422 Proxy, LT, 422, 422 HQ; ProRes 4444 and 4444 XQ (alpha) | in a `.mov`; decoded by the Mac's ProRes engine |
| HAP, HAP Alpha, HAP Q, HAP Q Alpha, HAP Alpha-only | in a `.mov`; decoded on the CPU |
| Stills: PNG, JPEG, TIFF, HEIF | loaded once; 16-bit images become 8-bit (B10) |

Everything else (H.264, HEVC, `.mp4`, `.avi`, `.mkv`, `.mxf` and other codecs)
is listed with a **needs transcode** badge and cannot be played until it is
transcoded. Long-GOP video is refused on purpose: it cannot scrub, run in
reverse or chase timecode reliably. Very small movie frames can fail hardware
ProRes decode; 320x176 works, 64x48 does not (B5).

Audio in a movie is played on the Mac's default output device, with the Layer's
Audio volume and Audio pan channels (48 and 49). There is no device choice yet
(B4).

### Image sequences

Put a **folder** of images inside a numbered folder and number it like a file
(`001_Opening/005_Flames/` with `flames_0001.png`, `flames_0002.png`, ...). It
needs at least two images of the same size; they play in name order. It is
listed as "needs transcode" with a frame count. Transcode turns it into a
movie; the Media screen uses 25 frames per second. Choose ProRes 4444 or HAP
Alpha if the images have alpha.

## Import from the browser

Select a numbered folder, press **Import…** and pick one or more files. The
upload is streamed to `_incoming/` and queued; the list under the toolbar shows
each file as waiting, uploading, queued or failed. Only the programmer role can
import.

- Every uploaded movie goes through the ingest queue and is re-encoded: ProRes
  422 HQ, or ProRes 4444 if the source has alpha. Stills are copied.
- The file gets the next free number in that folder and the name
  `NNN_<original name without leading digits>`; the temporary copy in
  `_incoming/` is deleted afterwards.
- **HAP files cannot be imported or transcoded** (the macOS decoder cannot read
  them; B20). Copy HAP files into the folder with Finder under the right name.
- Phone footage with a rotation flag (portrait video) is imported upright: the
  rotation is baked in and the file gets the swapped width and height.
  Variable-frame-rate sources can drift against their audio (B19).

## Transcode a file that is already in the library

On a "needs transcode" tile choose the codec and press **Transcode** (the
button says "Queued" while the job waits). The choices are HAP Q (the default),
HAP, HAP Alpha, ProRes 422 HQ and ProRes 4444. The result is `NNN_name.mov` with
the same number, and the original is moved to `_originals/` in that folder.
Sources with alpha are promoted to ProRes 4444 or HAP Alpha; HAP Q Alpha cannot
be written (B16).

## The ingest queue

The panel at the bottom of the Media screen shows "N running · N queued". Each
job shows source, destination, codec, state (queued, transcoding with a
percentage, done, failed with the reason, cancelled) and a progress bar, plus
**Cancel** or **Remove**. Jobs run one at a time at low priority and wait while
frames are tight. They are paused while show mode is on (resume by leaving show
mode) and survive an engine restart. The status bar shows the progress too.

## Thumbnails

The engine renders one frame from the middle of each file, 320 pixels wide, and
caches it with the file's metadata (codec, size, frame rate, duration, alpha,
audio) in `~/Library/Application Support/Fanous/cache/`. Tiles say "probing…"
until it is done. The same thumbnails go to consoles over CITP, and appear on
the Layers screen for a layer that shows nothing right now; a layer that shows
something has its live picture there instead. A file that changes is probed again.

## Performance advice

- Use all-intra formats only: ProRes or HAP.
- Make the clip the same size as the canvas. **HAP Q** (decoded on the CPU) or
  **ProRes 422 HQ** (decoded by the ProRes engine) at the canvas resolution is
  the safe default.
- Measured on the M1 Pro reference machine (1080p60 canvas): 16 layers of
  ProRes 422 HQ or HAP Q ran without dropped frames; 16 was the limit of the
  test. At 4K30: 16 layers likewise. At 4K60: 3 to 7 layers of ProRes 422 HQ
  (occasional missed frame from decode jitter, B1) and at least 4 of HAP Q.
- Effects cost frame time: Blur and Edge take about 1.6 to 1.9 ms per 1080p
  layer each, so 2 to 3 layers with both at 1080p60 (B2). A dissolve (Dissolve
  channel) uses a second decoder, which counts as one more layer.
- Watch "dropped" in the status bar and the tiles under System › Live metrics while
  you build the show.
- Keep the library on the internal disk with more than 10 % free, and switch
  Spotlight indexing off for that volume (see the show-day checklist).
