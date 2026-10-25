<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Fanous user guide

Fanous is a media server for live events. Your lighting console patches it
as a fixture and drives video layers over Art-Net or sACN; Fanous plays the
media, blends, warps and maps it onto projectors and displays, and reports back
what it is doing. This guide describes version 1.0.0-rc.1.

## Who this is for

Operators and programmers of lighting consoles who need to get a show running
on a Mac: patch the fixture, put media in the library, set up the outputs,
program cues, and run the machine reliably on show day. It does not teach
Art-Net, sACN or console programming.

## Requirements

- An Apple Silicon Mac with a hardware ProRes engine. Base M1 and Intel Macs are
  not supported (the engine refuses show mode on them). The M1 Pro is the
  reference machine; all numbers in this guide that come from measurements are
  from it.
- macOS 15 or newer.
- A lighting console (or software) that sends Art-Net or sACN to the Mac.
- For the web UI on another device: a browser on the same network. An iPad is
  the intended second screen.

## Pages

| Page | What is in it |
|---|---|
| [getting-started.md](getting-started.md) | Install, first launch, firewall, the main window, the web UI from an iPad, roles and passwords, where files live |
| [console-setup.md](console-setup.md) | Fixture types, the standard patch, the Patch / DMX screen, GDTF export, sACN, a first-light walkthrough |
| [media-library.md](media-library.md) | Folder and file naming, supported formats, import and ingest, thumbnails, performance advice |
| [outputs-and-mapping.md](outputs-and-mapping.md) | Displays, outputs, blend edges, corner pin and mesh warp, slices, masks, test patterns |
| [show-control.md](show-control.md) | Timecode (LTC, MTC), cues, OSC, CITP/MSEX |
| [show-day-checklist.md](show-day-checklist.md) | A printable checklist for the day of the show |
| [troubleshooting.md](troubleshooting.md) | Symptoms, causes, fixes, logs, restart and reset |

Reference material outside this guide: [channel-map.md](../channel-map.md) lists
every DMX channel, [DESIGN.md](../DESIGN.md) is the technical design, and
[BACKLOG.md](../BACKLOG.md) lists everything that is known to be missing.

## The six screens

Switch screens with the left rail or the keys 1 to 6.

| Key | Screen | Purpose |
|---|---|---|
| 1 | Layers | One row per layer: media, position, intensity, play mode, source; canvas preview |
| 2 | Media | The library: folders, files, import, transcode, ingest queue |
| 3 | Outputs (Outputs & Mapping) | Canvases, outputs, blend, warp, slices, masks |
| 4 | Patch (Patch / DMX) | Fixture table, DMX monitor, GDTF export |
| 5 | Show (Show control) | Timecode, cues, OSC, MIDI sources |
| 6 | System (System / Health) | Show mode and readiness, metrics, network, roles, logs |

Other keys: Cmd-Z undo and Shift-Cmd-Z redo (programmer), L lock or unlock the
show (programmer, with a confirmation), Space fires the next cue on the Show
screen (operator and programmer). Keys do nothing while you type in a field.

## Known limitations

Everything below is also in [BACKLOG.md](../BACKLOG.md) under the given number.
The pages that follow repeat the ones that matter for their topic.

- Display modes (resolution, refresh rate) stored on an output are not applied;
  set them in System Settings › Displays (B33).
- Hot-plugging a display has only been tested through unit tests and the
  built-in display (B34).
- Project versions do not exist yet: there is one `project.json`, autosaved,
  with no named versions and no "revert to" (B23). The OSC message
  `/fanous/project/load` is refused (B35).
- Layers show the library thumbnail of the playing file, not a live picture of
  the layer (B29). You can see values but not hold an override from the UI
  (B27). Per-universe settings are read-only (B28).
- Consoles over CITP/MSEX get the canvas only, as a 640x360 JPEG stream; there
  are no per-layer streams and thumbnails ignore the requested size (B41). No
  real console has talked to Fanous over CITP yet (B40).
- OSC has no feedback (no query, no notify); MIDI notes, MIDI Show Control and
  MIDI-triggered cues do not exist (B36).
- Several OSC messages sent back to back from one socket may be partly lost;
  leave about 50 ms between messages (B30).
- Show mode does not yet lower the log level, throttle thumbnails or check for
  display mirroring (B42).
- Audio plays on the default output device; there is no device choice and no
  latency compensation (B4). A looping clip with audio has a short silent gap at
  the loop point (B3).
- Not verified on iPad Safari (B46). No notarized build and no clean-account
  install test yet (B50). No app icon (B48).
- The GDTF file has not been imported into grandMA3, Eos or MagicQ yet (B7).
