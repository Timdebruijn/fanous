<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Show control

The Show screen (key 5, "Show control") holds timecode, the cue list, OSC and
the MIDI source list. Fanous can also be seen and browsed from a console
over CITP/MSEX.

Before you build a show on cues or OSC parameter values, set the project's
source policy (Patch screen toolbar) to LTP, HTP or Internal only: with the
default **DMX only** those values are recorded but do not move a layer, and the
Show control screen shows a yellow warning. See
[console-setup.md](console-setup.md#sources-and-merging).

The **Timecode on/off** switch belongs to the operator and also works under
show lock; the source, device, channel and offsets are programmer settings.

The toolbar has **Go** (also the Space key), **Back**, and a **Cue no.** field
with **Go to**. Operators and programmers can use them, also while the show is
locked. Space only works when no field or button has the focus.

## Timecode

The Timecode panel shows the current time in big digits, a state pill and the
number of frames seen. States: **Locked** (green), **Freewheel** (yellow, the
signal dropped and the clock keeps running for the Freewheel time), **Lost**
(red, layers stop chasing) and **Off**.

| Field | Meaning |
|---|---|
| Source | Off, LTC (audio input) or MTC (MIDI) |
| Device | an audio input for LTC ("Default input" or a named device), a MIDI source for MTC ("All sources" or one) |
| Channel | LTC only: input channel of the device, 1 is the first |
| Offset (frames) | subtracted from the incoming time, project wide |
| Freewheel (s) | how long a dropped signal is bridged; default 2 |
| Timecode on/off | the switch in the panel header |

**LTC** reads any audio input on the Mac. Frame rates 24, 25, 29.97 (drop and
non-drop) and 30 are detected by themselves. LTC needs the Microphone
permission: macOS asks once when you pick an input. If you said no, turn it on
in System Settings › Privacy & Security › Microphone. **MTC** reads quarter-frame and full-frame messages from any
MIDI source; connected sources are listed in the MIDI panel on the right, with a
"timecode" badge on the chosen one. MIDI is MTC only in this version.

Offsets: besides the project offset the engine supports one offset per layer
(also frames); the Show screen only has the project offset field.

To make a layer follow the timecode set its Play mode channel (channel 5) to
128 to 143, "Timecode". The layer then shows the file position
`(timecode − project offset − layer offset)` at the file's own frame rate, looped
between the In point and Out point channels.

Changing timecode settings, including the on/off switch, is a configuration
change: it needs the programmer role and is refused while the show is locked.
Set it up and switch it on before you lock the show.

## Cues

A cue has a number, a name, a fade time, a list of values, an optional timecode
trigger and an optional follow time. The list shows No., Name, Fade, Trigger,
Follow and Values; the header says "Now 2 Name · next 3 Name", and the rows are
marked current (or fading) and next.

- **Add cue** takes the next free number and the name "Cue N". **Duplicate**
  copies fade and values, not trigger and follow. **Remove** asks first. **Move
  up** and **Move down** swap numbers with the neighbour. Numbers may have
  decimals (2.5) and must be unique.
- In the editor: **Number**, **Name**, **Fade (s)**, **Trigger**, **Follow (s)**,
  and **Go to this cue**.
- **Values** are rows of Fixture (Layer n, Master, Output n), Parameter, Value
  and an optional Fade (s) that overrides the cue fade. Value is a number in
  the parameter's raw range or, for parameters with named bands such as Play
  mode or Blend mode, a choice list. **Add value** adds a row.
- Fades are linear for continuous parameters. Parameters that are choices
  (play mode, blend mode, effects, folder, file) switch when the fade starts.
- **Trigger** is `hh:mm:ss:ff@rate`, for example `00:01:30:00@25`. Rates: 24,
  25, 29.97df, 29.97ndf, 30; without `@rate` it means 25. The cue fires when the
  timecode passes that time, and arms again after a jump back.
- **Follow** fires the next cue that many seconds after this one. Leave it empty
  for none.

**Go** fires the next cue, **Back** the previous one, **Go to** a given number.
Editing cues is a configuration change (programmer, refused while the show is
locked); Go, Back and Go to are not.

## OSC

Fanous listens for OSC on port 8000, UDP, and on TCP 8000 with SLIP framing.
The OSC panel shows the port, the last received messages (time and command) and
the address list. Try `/fanous/cue/go` first. Parameter keys are the "OSC key"
column of [channel-map.md](../channel-map.md); a float is a value from 0 to 1 of
the parameter's range, an int is the raw value.

| Address | Args | Effect |
|---|---|---|
| `/fanous/layer/{n}/{param}` | f | Layer parameter; param is a key of the channel map |
| `/fanous/layer/{n}/media` | ii | Folder, file |
| `/fanous/layer/{n}/retrigger` | | Restart the media |
| `/fanous/master/{param}` | f | Master parameter |
| `/fanous/output/{n}/{param}` | f | Output parameter |
| `/fanous/cue/go` | | Fire the next cue |
| `/fanous/cue/back` | | Fire the previous cue |
| `/fanous/cue/goto` | i | Fire the cue with this number |
| `/fanous/cue/{number}/go` | | Fire that cue |
| `/fanous/show/lock` | i | 1 locks the show, 0 unlocks |
| `/fanous/show/mode` | i | 1 enters show mode, 0 leaves |
| `/fanous/timecode/enable` | i | 1 switches timecode on, 0 off |

OSC bundles with timetags are honoured: the contents run at the given time.
Send a burst slowly: messages sent back to back from one socket can be partly
lost, so leave about 50 ms between them (B30). Fanous does not send OSC back.

## CITP/MSEX

Fanous announces itself to consoles every 5 seconds on the CITP multicast
groups 224.0.0.180 and 239.224.0.180 (port 4809), under the Mac's host name, and
serves MSEX over TCP on a port the system picks (shown in System › Network, CITP
line, together with the connected consoles and open streams). The console must
be on the same subnet and the firewall must let the traffic through. A console
sees:

- one DMX source per layer and the **layer status** (media, position, playing)
  four times a second;
- the **libraries and elements**: numbered folders and numbered files with name,
  size, frame rate and length;
- **thumbnails** of the files (the library thumbnails);
- a **canvas preview stream**: JPEG at 640x360, up to 10 frames per second, only
  produced while a console asks for it.

MSEX versions 1.0 to 1.2 are negotiated; the highest common one is used.

## Not done yet

- **Source policy applies to the whole project**, not per layer: one setting
  on the Patch screen for every fixture.
- No OSC feedback (query or notify). MIDI notes and CC as parameters, MIDI Show
  Control and MIDI-triggered cue recording do not exist (B36).
- `/fanous/project/load` is refused; projects have no versions yet (B23, B35).
- CITP: only the canvas can be streamed, not single layers; thumbnails are sent
  at their stored size whatever the console asks for (B41). No real console has
  been tried (B40).
- Timecode chase is tested with generated LTC and simulated MTC, not with real
  hardware, and not at 29.97 drop frame or over long runs (B44). The
  microphone prompt has not been tested on a clean install (B37). Cue fades
  have not been measured from cue to picture (B43).

## Built-in content (folder 0)

Folder 0 holds content the engine draws itself: no files, any layer, selected
like a clip (Folder 0, File n) from the console or from the layer panel
(**Control** › **Built-in content**). It goes through the layer like media:
position, scale, colour, effects and dissolves apply.

| File | Content |
|---|---|
| 100 | Solid colour: white times the layer's Red/Green/Blue channels |
| 101–107 | The seven output test patterns as layer content |
| 110 | Test card: grid, aspect circle, border, colour bars, running time (or the incoming timecode when it runs) with a frame number, a bar that sweeps once a second, and two squares that swap every frame (a dropped or doubled frame shows as both lit or both dark) |
| 111 | Colour sweep: a slow moving hue gradient |
| 112 | Clock: time of day, hh:mm:ss |
| 113 | Motion test, locked to the frame counter: a bar moving 16 px per frame (at 1080p), stripes scrolling 8 px per frame and a strip of 60 cells with one lit per frame. At a steady rate every step is equal; a dropped or doubled frame shows as a jump or a stop |

Judge motion on an output (a display or projector), not in the preview: the
preview is 640 × 360 at 30 fps and shows only every second frame of a 60 fps
canvas, so moving content always looks jerky there.

## Controlling layers from the UI

Without a console on site, open the Layers screen, select a layer and turn on
**Control** in its panel. Every channel gets a control: a slider for continuous
values (double-click: default), a list for modes, a number for folder and file.
Values enter as the UI source, so the project's source policy must be LTP, HTP
or Internal only; the panel offers **Use LTP** when it is DMX only. With LTP the
latest change wins between console and UI. **Release** hands the layer back to
the console. UI control is refused while the show is locked.

