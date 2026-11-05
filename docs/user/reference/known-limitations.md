<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Known limitations

What this version of Fanous does not do, or has not been tested on, in plain
words, for anyone deciding what to rely on for a show. Each row names its
entry in [BACKLOG.md](../../BACKLOG.md), which has the technical detail and
the state; a dash means the behaviour is intended or has no entry. The pages
of the guide repeat the rows that matter for their topic in one sentence and
link here. Back to the [index](../README.md).

## Consoles and protocols

| Limitation | Backlog |
|---|---|
| The GDTF file has not been imported into a real grandMA3, Eos or MagicQ yet. If the import fails, build the fixture by hand from the [channel map](../../channel-map.md). | B7 |
| No real console has talked to Fanous over CITP/MSEX yet; it is tested against captured packets. | B40 |
| Over CITP, streams and thumbnails come at a fixed size (Canvas 1 at 640 pixels wide, each layer at 160, thumbnails as stored) whatever size the console asks for. | B41 |
| No NDI. grandMA3 and Eos have no CITP, so they get no thumbnails or preview of Fanous on the desk. | B74 |
| Only GDTF: no grandMA2 XML, MagicQ head file, Avolites personality, Eos library request or Onyx fixture. Eos's GDTF import creates no media or model list. | B77 |
| Fanous answers ArtPoll, but has no registered Art-Net OEM code yet. | B13 |
| The ArtPollReply names the Mac's first network address, which on a Mac with Wi-Fi and a show adapter can be the wrong one, and carries no MAC address, so two Macs look like one node to a desk that keys on it. Enter the Mac's address on the desk by hand. | B166 |
| Another program holding the Art-Net port 6454 is only reported in the engine log; the readiness list warns for the sACN port only. | B167 |
| A loss of OSC messages sent back to back was seen once and never reproduced. If a controller's bursts seem partly lost, leave about 50 ms between messages and report it. | B30 |
| Who controls applies to the whole project, not per layer. | — |

## Show control

| Limitation | Backlog |
|---|---|
| No MIDI output: no controller lights, no MSC replies. Cues cannot be recorded from MIDI. MIDI ranges (low and high of a mapping) can only be set with the `midi.map.set` command. | B36, DESIGN §15.4 |
| MIDI and MSC are tested with injected messages and a virtual source, not with a real controller. | — |
| Timecode chase is tested with generated LTC and simulated MTC, not with real hardware, not at 29.97 drop frame and not over long runs. | B44 |
| A cue's timecode trigger fires only when the clock advances by less than 5 seconds at a time: a jump forward of 5 s or more fires nothing in between. A jump back arms the triggers again. | — |
| A cue trigger with a rate the engine does not know (`@29.97df` instead of `@29.97 DF`) is stored as typed and shown in the cue list, but never fires, with no error, when it comes in over OSC or the WebSocket; the UI spells the rate right by itself. | B159 |
| Cue fades are measured up to the engine's published state (first step 1.2 to 1.4 ms, full after about 1 s for a 1 s fade), not up to the photons on the screen. | B43 |
| The OSC feedback target for a controller that cannot subscribe can only be set in `settings.json`, not on the System screen. | — |

## Media and inputs

| Limitation | Backlog |
|---|---|
| No text layer: no user text, countdown or subtitles. The clock and the test card draw digits only. | B75 |
| HAP files cannot be imported or transcoded (macOS cannot decode them): copy them into the library with Finder. HAP Q Alpha cannot be written; alpha sources go to HAP Alpha or ProRes 4444. | B20, B16 |
| 16-bit stills become 8-bit. | B10 |
| A Rec.601 (SD) file played directly is read as Rec.709; transcoding it fixes the colours. A 601 camera is read as 709 too. | B21 |
| Only `.mov`, `.mp4`, `.m4v`, `.avi`, `.mkv` and `.mxf` are listed; a `.webm`, `.mpg`, `.wmv` or other container is skipped without a message. | B161 |
| An image sequence transcoded from the Media screen is always written at 25 frames per second; another rate needs the `fanousd ingest --fps` command. | B165 |
| **Transcode** on a `.mov` that needs a transcode (an iPhone's H.264 `.mov`, a rotated ProRes file) fails with "source and destination are the same file"; use **Import…** for such a file instead. | B169 |
| HAP refuses a source whose width or height is not a multiple of 4 (854 × 480, 1366 × 768): pick ProRes 422 HQ for it. | — |
| A thumbnail of a packed 4:2:2 movie (v210, yuvs) may draw at half width. | B149 |
| A UVC webcam (Logitech C920, Brio) may stay at its driver's default format, for example 640 × 480 on a larger canvas. Capture cards follow their input. | B131 |
| Blackmagic DeckLink and AJA cards do not appear: they need their own SDK, which is planned for the Pro build. Windows of other apps (folder 0, files 29 to 32) are reserved but not available. | B73 |
| Audio plays on the Mac's default output device in one stereo mix: no device choice, no latency compensation, no output routing per layer. | B4, B76 |
| Audio plays only forward at 100 % speed (layer speed × Master speed); at any other speed, and in Freeze, Scrub and Timecode, the layer is silent. A looping clip whose audio is shorter than its video has a short gap at the loop; the first moment after a long pause can be silent. | B3 |

## Outputs and mapping

| Limitation | Backlog |
|---|---|
| Hot-plugging a display is checked with one external display; with two or more it rests on unit tests. Test it on your machine before the show. | B34 |
| Output frames are paced by the engine's own clock at the canvas rate, not locked to the display's refresh. A display whose refresh is not a whole multiple of the canvas rate (50 Hz or 24 Hz for a 60 fps canvas) judders; match the canvas frame rate to the display. Even with matching rates the two clocks drift, so a frame is repeated or skipped now and then; how often is not measured. | B58 |
| In the 8-hour soak on the M1 Pro, about one frame in 340 000 was presented one refresh late. | B52 |
| Dithering is a simple noise function; report banding on a projector. | B34 |
| No per-output Syphon, no Syphon for canvases other than Canvas 1, no frame rate per canvas, no 10-bit output. | B59 |
| The outputs of one projector wall need the same pixel size. **Hold to compare** reaches outputs 1 to 8. | — |
| Colour gain, black lift and black offset assume a gamma-2.2 projector; there is no per-output gamma for them. | — |
| A permanent dissolve on layers that also run Blur and Edge needs more memory than the compositor's documented budget: 16 such layers at 1080p60 showed texture misses. | B148 |

## Show mode and the machine

| Limitation | Backlog |
|---|---|
| Show mode does not lower the log level, throttle thumbnails or check for mirrored displays. | B42 |
| Readiness probes for Spotlight, automatic updates and Time Machine read macOS tools; when the output changes they show **manual** and you check by hand. Focus (Do Not Disturb) is always manual. | B38 |
| An acknowledged readiness item stays acknowledged until the engine restarts: there is no un-acknowledge, and the item keeps its acknowledgement if it fails again later. | B163 |
| There is one project per machine: versions of it can be restored, but there are no project bundles to open or switch between, and no diff between two versions. | — |
| The layer limit is 32 on every Mac: the engine's ceiling, not a measurement of this Mac. What a Mac plays without dropping frames can be far lower, at 4K for example. | B145 |
| Everything measured was measured on one MacBook Pro M1 Pro. Other Apple Silicon chips are expectations; the idle 4K60 figures are to be re-measured. | B49 |
| A first install on a clean Mac account has not been tested; the notarized build was checked on a developer Mac. | B50 |
| Not supported at all: Intel Macs, Windows, Linux. | — |

## The web UI and security

| Limitation | Backlog |
|---|---|
| A few addresses need no login whatever passwords are set: `/healthz`, `/metrics`, `/api/metrics`, `/api/live` (DMX senders and every fixture value), `/api/patch`, `/api/gdtf`, `/api/session`, the channel map, the thumbnails and `POST /api/library/rescan`. Keep the Mac on the show network, not on a guest network. | B160 |
| OSC has no passwords. | — |
| The engine's certificate is self-signed, so every browser warns once; confirm it against the fingerprint under System › Network. | — |
