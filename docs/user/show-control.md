<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Show control

The Show screen (key 5, "Show control") holds timecode, the cue list, OSC and
the MIDI source list. Fanous can also be seen and browsed from a console
over CITP/MSEX.

Before you build a show on cues or OSC parameter values, set the project's
source policy (Patch screen toolbar) to **Console + UI (latest wins)**,
**Console + UI (highest wins)** or **UI and cues only**: with the default
**Console only** those values are recorded but do not move a layer, and the
Show control screen shows a yellow warning. See
[console-setup.md](console-setup.md#sources-and-merging).

The **Timecode on/off** switch belongs to the operator and also works under
show lock; the source, device, channel and offsets are programmer settings.

The big **GO · Space** button (72 px high) fires the next cue and says which
one: "Next: 3 Chorus". **Back** sits at the far right, apart from Go, so it is
not pressed by mistake. The toolbar has a **Cue no.** field with **Go to**.
Operators and programmers can use them, also while the show is locked. The Space
key does the same as GO, but only when no field or button has the focus.

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
| Offset (frames) | subtracted from the incoming time, project wide. The line under it shows the same offset in seconds at the current rate, for example "+25 frames = +1.00 s at 25 fps" |
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
  copies fade and values, not trigger and follow. **Remove** shows "Undone? Undo" for 8 seconds. **Move
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
| `/fanous/project/load` | s | Revert to the newest named project version with this name (or to a version id); refused in show mode and while the show is locked |

OSC bundles with timetags are honoured: the contents run at the given time.
Send a burst slowly: messages sent back to back from one socket can be partly
lost, so leave about 50 ms between them (B30).

### Reading state back (feedback)

A controller (Bitfocus Companion, QLab, TouchOSC) can also read values back,
in two ways.

**Ask once.** Add `/get` to any address below: `/fanous/layer/3/intensity/get`
answers with `/fanous/layer/3/intensity 0.75`, `/fanous/layer/3/get` with every
value of layer 3, `/fanous/cue/get` with the cue state. `/fanous/get` on its own
answers with a summary: version, show mode, show lock, ready, current cue,
frames per second and missed frames. The answer goes back to the address and
port the question came from. A controller that listens on another port than it
sends from adds that port as an int (`/fanous/get 9000`); that only works once
that port has a confirmed subscription (below), otherwise the answer still goes
to the port the question came from. One question answers at most 256 addresses;
ask per layer rather than for all layers at once. Answers come from a snapshot
that is at most 25 ms old.

**Subscribe** takes two steps. `/fanous/subscribe <host> <port> [prefix]`
(s, i, s) is answered with `/fanous/subscribe/confirm <cookie>` (s) on that
port; the controller sends `/fanous/subscribe/ack <cookie>` back within 5
seconds, from the same computer. From then on every change under the prefix
(default `/fanous`, everything) goes to that port. This way nobody can make
Fanous send a stream to a computer that did not ask for it. Right after the ack
you get all current values once, then only changes. Changes
are collected for 50 ms and sent together, so a value goes out at most 20 times
a second and always as its latest value; a console fading a layer does not
flood the controller. A subscription ends after 60 seconds unless it is renewed
with another `/fanous/subscribe` (no new cookie needed once confirmed) or a
`/fanous/ping` (answered with `/fanous/pong`): let the controller send one every
30 seconds.
`/fanous/unsubscribe` ends every subscription of the sending computer;
`/fanous/unsubscribe <host> <port> [prefix]` ends one. Every cue go (Go, Back,
Go to, from the UI, the Space key or OSC) sends the cue addresses again, also
when the cue did not change.

Answers and changes come as OSC bundles with the timetag "immediately", each
smaller than one network packet. Values are in the same units you send:
parameters as a float from 0 to 1 of their range (send one back and you set the
same value), so a fader on a controller can follow a layer.

| Address | Type | Value |
|---|---|---|
| `/fanous/layer/{n}/{param}` | f | Layer parameter as it is applied (after the source policy) |
| `/fanous/layer/{n}/media` | ii | Folder, file |
| `/fanous/master/{param}` | f | Master parameter |
| `/fanous/output/{n}/{param}` | f | Output parameter |
| `/fanous/output/{n}/state` | s | `bound`, `lost` or `unassigned` |
| `/fanous/output/{n}/bound` | i | 1 when the output shows on its display |
| `/fanous/cue/current` | f | Number of the current cue, -1 for none |
| `/fanous/cue/current/name` | s | Its name, empty for none |
| `/fanous/cue/next` | f | Number of the next cue, -1 for none |
| `/fanous/cue/next/name` | s | Its name |
| `/fanous/cue/fading` | i | 1 while a cue fades |
| `/fanous/cue/count` | i | Number of cues |
| `/fanous/show/mode` | i | 1 in show mode |
| `/fanous/show/lock` | i | 1 when the show is locked |
| `/fanous/show/ready` | i | 1 when no readiness item blocks show mode |
| `/fanous/timecode/enable` | i | 1 when timecode is switched on |
| `/fanous/timecode/state` | s | `off`, `locked`, `freewheel` or `lost` |
| `/fanous/timecode/value` | s | `hh:mm:ss:ff` |
| `/fanous/engine/version` | s | Fanous version |
| `/fanous/engine/fps` | f | Frames rendered in the last second |
| `/fanous/engine/missed` | i | Frames missed in the last second |

Nothing that names a file or folder on the Mac (library root, project file) can
be read over OSC.

**Who gets feedback.** Fanous only sends to the computer that asked: a subscribe
naming another host is refused with `/fanous/error`, and a stream starts only
after the cookie came back. At most 16 confirmed subscriptions exist at once.
Each computer can send 10 feedback requests (get, subscribe, ack, ping) a second,
20 in a burst; more are ignored. OSC has no passwords, so keep it on the show
network. For a
controller that cannot subscribe, set a **fixed feedback target** in
`~/Library/Application Support/Fanous/settings.json` (next to `passwords`, keep
those), then restart the engine:

```json
{
  "passwords": { … },
  "oscFeedback": { "host": "192.168.1.20", "port": 9000, "prefix": "/fanous/cue" }
}
```

That target gets every change under the prefix (default `/fanous`) for as long
as the engine runs, and the answers to `/get` from any controller too. There is
no field for it on the System screen yet.

**Example: Bitfocus Companion.** Add a *Generic OSC* connection with the Fanous
Mac's address as target and port 8000, and let it listen for OSC on a port of
its own, say 9000 (the field names differ between Companion versions). Then:

- the simplest: put the Companion computer in `settings.json` as fixed target
  (`"host": "<Companion's address>", "port": 9000`); no subscribe needed;
- or subscribe in two steps. A trigger that runs every 30 seconds sends
  *Send message* `/fanous/subscribe` with the arguments `<Companion's address>`
  (string), `9000` (integer) and `/fanous/cue` (string). Store the received
  `/fanous/subscribe/confirm` argument in a variable, and let a second trigger
  on that variable changing send `/fanous/subscribe/ack` with the variable as
  string argument. Once confirmed, the 30-second subscribe only renews (no new
  cookie);
- a button with the action *Send message* `/fanous/cue/go` fires the next cue;
- received `/fanous/cue/current/name` and `/fanous/cue/next/name` fill
  variables to show on that button ("Next: Chorus"), and a feedback on
  `/fanous/show/ready` = 0 can turn a button red before show mode.

TouchOSC sends from and listens on the same port: it gets the cookie on that
port, from port 8000, and answers with the ack (a small script on a control:
on `/fanous/subscribe/confirm`, send `/fanous/subscribe/ack` with the same
argument); changes then come from port 8000 too.

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
- a **canvas preview stream** of Canvas 1: JPEG at 640x360, up to 10 frames per
  second, only produced while a console asks for it.

MSEX versions 1.0 to 1.2 are negotiated; the highest common one is used.

## Not done yet

- **Source policy applies to the whole project**, not per layer: one setting
  on the Patch screen for every fixture.
- MIDI notes and CC as parameters, MIDI Show Control and MIDI-triggered cue
  recording do not exist (B36). The OSC feedback target can only be set in
  `settings.json`, not on the System screen.
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
| 113 | Motion test: a bar moving 16 px per frame (at 1080p), stripes scrolling 8 px per frame and a strip of 60 cells with one lit per frame. At a steady rate every step is equal; a dropped or doubled frame shows as a jump or a stop |

Judge motion on an output (a display or projector), not in the preview: the
preview is 640 × 360 at 30 fps and shows only every second frame of a 60 fps
canvas, so moving content always looks jerky there.

## Controlling layers from the UI

Without a console on site, open the Layers screen, select a layer and turn on
**Control** in its panel. Every channel gets a control: a slider for continuous
values (double-click: default), a list for modes, a number for folder and file.
Values enter as the UI source, so the project's source policy must be
**Console + UI (latest wins)**, **Console + UI (highest wins)** or **UI and cues
only**; the panel offers **Use Console + UI (latest wins)** when it is Console
only. With latest wins, whoever moved last wins between console and UI.
**Release** hands the layer back to the console. UI control is refused while the
show is locked.

**Preview of one layer.** Above the preview on the Layers screen, **Canvas**
shows the whole canvas (with several canvases there is a button per canvas
instead) and **This layer** shows only the selected layer, in the shape of its
own canvas: its
media with its own position, scale, rotation, fit, crop, colour, effects and
intensity, in the canvas frame, over black. Layers above and below it are left
out, and its blend mode is shown as Normal (Multiply or Darken over black would
show nothing). The preview follows the selection; with Master or an output
selected in the strips it shows the canvas, **Canvas** is lit and the caption
says "Canvas (no layer selected)"; select a layer again and it returns to that
layer. The caption ends with what is shown, for example
`H.264 · 640×360 · 30 fps · Layer 3`. The browser remembers the choice; other
browsers keep their own. A layer at intensity 0 or without media is black.

**Master and outputs.** The strips above the layer list have a **Select**
button: it puts Master (intensity and speed) or an output (intensity and test
pattern) in the side panel, with the same **Control** switch, **Release** and
rules as a layer. Select a layer row to go back to the layer.

**Expiry.** UI values only run down while they mask a console: Art-Net or sACN
comes in for the fixture's universe and at least one UI value is what the layer
shows. That is never the case with **Console only** (UI values are not shown),
with latest wins only until the desk moves that channel again, and with highest
wins only where the UI value is the higher one. After 10 minutes of masking
since the last UI change the UI values are released and the log says so. While
it runs, the panel says "UI control · console active, releases in 7:42";
**Keep** (or any change from the UI) restarts the 10 minutes. Otherwise it says
just "UI control" and the count pauses: a console that drops out and comes back
continues where it was, and testing before the desk is on site never loses the
values (they stay until **Release**).

**Media from the library** lists every playable file as "Folder 3 · Intro / 12 ·
loop.mov" and puts the choice on the layer (folder and file, and intensity to
full if it was 0). The same works from the Media screen: select a file and pick
**Play on layer** (Layer 1 to n). The panel shows the library names of what the
layer plays, not only the numbers.

