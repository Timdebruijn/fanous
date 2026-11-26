<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Troubleshooting

From the symptom to the cause, the most likely first. The readiness items
with their fixes are in [Readiness items](reference/readiness.md);
the log is under [Logs](#logs).

| You see | Go to |
|---|---|
| The picture froze, the iPad says "Connection lost" | [The engine died during the show](#the-engine-died-during-the-show) |
| The UI cannot reach the engine | [Engine unreachable](#the-ui-says-the-engine-is-unreachable) |
| The iPad warns about the certificate, or will not load the UI | [The iPad warns about the certificate](#the-ipad-warns-about-the-certificate) |
| The console moves nothing | [The console moves nothing](#the-console-moves-nothing) |
| A universe pill is not green | [A DMX universe is silent](#a-dmx-universe-is-silent) |
| A layer reads an error, or is black | [A layer shows an error, or the picture is black](#a-layer-shows-an-error-or-the-picture-is-black) |
| An import or transcode ends "failed" | [An ingest job fails](#an-ingest-job-fails) |
| The picture is frozen | [The picture is frozen](#the-picture-is-frozen) |
| A projector is black | [Outputs stay black although the layers play](#outputs-stay-black-although-the-layers-play) |
| Lines and a yellow cross on a projector | [Lines on the projector](#lines-and-a-yellow-cross-on-the-projector) |
| The picture stutters, "dropped" above 0 | [Dropped frames](#dropped-frames) |
| No sound | [No sound](#no-sound) |
| A cue does not fire | [A cue does not fire](#a-cue-does-not-fire) |
| Timecode does not lock | [LTC does not lock](#ltc-does-not-lock) |
| The console does not list Fanous | [A CITP console does not see Fanous](#a-citp-console-does-not-see-fanous) |
| The second Mac does not follow | [Multi-server sync](multi-server.md#when-the-slave-does-not-follow) |
| Show mode refuses | [Show-day checklist](show-day-checklist.md#the-readiness-list) |
| The patch or the cues are gone after a restart | [The project is gone after a restart](#the-project-is-gone-after-a-restart) |

Who can do what: an operator on an iPad can read every screen, run the
checks, enter and leave show mode and fire cues. Everything else below
needs the programmer, or someone at the Mac: the Engine menu is in the
menu bar at the top of the Mac's screen while the Fanous app is in front
(click Fanous in the Dock), not in the browser or on the iPad. Its first
line says what the engine is doing, "Engine <version> running · service
installed" when all is well ([The user interface](ui.md#menus-of-the-app-window)).

## The engine died during the show

1. Wait 15 seconds: macOS restarts the engine by itself. Done when the
   status bar reads "Show mode resumed after the engine restarted at
   HH:MM" and the projectors show a picture.
2. Log in again on every iPad; the logins did not survive the restart.
3. The cue that was current is current again with the values the cues
   held; clips start from their first frame (except on layers that chase
   timecode) and a timecode trigger that fell meanwhile did not fire: Go
   fires the next cue.
4. Programmer, System screen: acknowledge again what the red banner "Show
   mode is on with blocking items" names; acknowledgements did not survive
   either.
5. Not back after 30 seconds: at the Mac, Engine › **Restart Engine**.
   Still nothing: the next section.
6. Afterwards, copy the log before any further restart, and look in
   `~/Library/Logs/DiagnosticReports` for a crash report of `fanousd`.

## The UI says the engine is unreachable

Inside a loaded page: "Connecting to the engine…" (yellow) while nothing
has arrived yet, "Engine unreachable: …; retrying" (yellow) when the
connection failed before any data, or the red "Connection lost · … · values
shown are stale" after data had arrived; the red one goes off for a moment
at each retry. The app window shows a blank page when the engine is down at
launch and retries every second by itself.

```mermaid
flowchart TD
  start["Engine menu, first line"] --> line{"The two halves read?"}
  line -- "running · service installed" --> conn["The engine is fine: the connection (below)"]
  line -- "not running · service installed" --> log["Engine › Open Logs: the newest lines"]
  log -- "HTTPS listener failed; trying again" --> port["Another program holds port 8443: the engine runs without its UI.<br>Quit that program: the UI is back within 5 s"]
  log -- "a crash report, or nothing recent" --> startit["Start Engine; after a crash macOS restarts it by itself (10 s after a quick crash)"]
  line -- "service needs approval in Login Items" --> approve["System Settings › General › Login Items & Extensions › Allow in the Background: Fanous on, then Start Engine"]
  line -- "service not installed" --> install["Start Engine registers and starts it"]
  line -- "service plist missing" --> reinstall["The app is damaged: reinstall it"]
```

The connection, when the engine runs: the same network, `https`, port
8443, the firewall allowing `fanousd` on TCP 8443, the certificate accepted
on that device, and macOS's Local Network permission granted to Fanous.
`https://127.0.0.1:8443/healthz` in a browser on the Mac answers a short
JSON with `"status":"ok"` when the engine answers (the browser warns about
the certificate first); the Engine menu uses the same address with a
one-second timeout, so a hung engine also reads "Engine not running".

Do not press **Start Engine** on a hunch while the show runs: when an
engine runs but does not answer within 10 seconds (port 8443 held by
another program, or hung), Start Engine restarts it, and the outputs go
black for a moment. Read the log first. A port held by another program
(8443, Art-Net 6454, OSC 8000) does not stop the engine; the log says
"HTTPS listener failed; trying again", "Art-Net listener failed; trying
again" or "OSC UDP failed; trying again", the engine runs without that
listener and tries again every 5 s at most, so it listens again within 5 s
of that program quitting; the readiness items **Art-Net port 6454
available** and **OSC port 8000 available** warn meanwhile ([known limitations](reference/known-limitations.md#show-mode-and-the-machine)).
The OSC item covers TCP 8000 too: a program that holds only TCP 8000 (a
development web server, say) keeps it on a warning while OSC over UDP
works; "OSC TCP listening" in the log says when TCP is back.

## An iPad or browser is refused or dropped

The engine limits what one device holds and closes connections that went
silent ([the limits](reference/files-and-ports.md)). What the log says:

- "HTTPS connection refused: too many open from one address": an address
  already holds 64 connections to the engine, and the next one is closed at
  once. At most one such line a minute: `peer` is the address refused as the
  line was written, `refused` counts the connections closed since the last
  line from every address; `/metrics` has the total under
  `refusedConnections`. On the refused device a page that is not open yet
  shows the browser's own error page ("can't connect" or similar). A UI that
  had loaded its data and loses its connection shows the red "Connection
  lost · … · values shown are stale" (the middle part is the browser's
  reason, such as "code 1006") while it retries; one that never got its first
  data shows the yellow "Engine unreachable: …; retrying". Either comes back
  by itself, usually within about 30 s, as idle connections close. All devices behind one
  address count together: a travel router doing NAT, a VPN, or a reverse
  proxy on another computer that every user reaches the engine through.
  Otherwise it is a browser with very many tabs of the UI, or a script: close
  tabs. The app window on the Mac is never refused.
- "WebSocket closed: client silent": a device sent nothing, not even the
  answer to the engine's ping, for 45 s: it went to sleep, out of Wi-Fi
  range, or its battery died. Its UI shows "Connection lost" when it wakes
  and reconnects by itself. "WebSocket closed: no hello" is a client that
  connected and did not log in within 10 s.
- "CITP connection refused: too many open from one address": a console
  holds 8 CITP connections already. "CITP client closed: stalled": a console
  stopped reading what the engine sends, or left half a message, for 30 s;
  it connects again by itself when it is back. A console that died without
  closing is found this way only once the engine's sends to it stop being
  taken, after the network's buffers have filled with the 4 Hz layer status:
  98 s in a loopback test (32 layers), many minutes with one or two layers;
  not measured on a real network.
- "upload cut: no data from the client; partial file removed" (a warning,
  with `seconds` and how much was `received`): an upload sent nothing for
  30 s while the engine was ready to read, so the engine closed it and
  removed the partial copy from `_incoming/`. In the Media screen's upload
  list the file reads "failed", with the browser's error ("Failed to fetch"
  in Chrome, "Load failed" in Safari). Upload it again over a better link.

## The iPad warns about the certificate

Expected once per device: the engine makes its own certificate. On the
iPad tap Show Details › visit this website. To check that it is your Mac,
compare the fingerprint with System › Network › TLS fingerprint on the Mac
(the browser shows it with colons and in capitals). It warns again after
`fanousd reset-tls`, on another device or browser, and when you use an
address the certificate was not made for: it holds the Mac's name and the
addresses it had at first start, so a new network needs a reset
([Files, ports and the command line](reference/files-and-ports.md)). If the
page does not load at all, check the address
([The user interface](ui.md#the-ui-on-an-ipad-or-another-computer)) and the firewall.

A preview that is a still image updating five times a second is the JPEG
fallback instead of H.264: the browser cannot decode the stream, or the
engine's four encoders are taken.

## The console moves nothing

The universe pill is green but the layer does not follow the desk.

1. Who controls (Patch screen) on **Fanous only**: the console is ignored.
   Set it to Console only or one of the "Console and Fanous" choices
   ([Console setup](console-setup.md#who-controls)).
2. The fixture's address: the Patch screen's DMX monitor shows what
   arrives on each channel; the console's address and mode must match the
   patch sheet ([Console setup](console-setup.md#tell-the-console)).
3. The layer's Intensity (channels 1 and 2) above 0, Folder and File not 0.
4. A UI or MIDI value masking the console: the layer panel reads "UI
   control" or "MIDI control"; **Release** hands it back.

## A DMX universe is silent

| Pill | Means |
|---|---|
| Green | Packets arrive within the universe's Signal lost after time (2.5 s to start) |
| Yellow "silent" | Nothing has ever arrived on it, also right after an engine restart |
| Yellow with seconds | Silent for less than 2.5 s, or an unpatched universe (which is never red) |
| Red | A patched universe silent for longer than its Signal lost after time and 2.5 s |

The fixtures hold their last values meanwhile, unless the universe's
**Hold on signal loss** says otherwise ([Console setup](console-setup.md#when-the-console-goes-silent)).

1. System › Machine › DMX universes: the sender's address, the packet count
   and the age of the last packet. "No DMX universes seen" means nothing
   arrives at all: the console's target address, the cable or Wi-Fi, or
   macOS's Local Network permission.
2. Console: output enabled for that universe, right protocol, right
   universe number. Art-Net `A 0.0.0` is port-address 0; some consoles
   count from 1.
3. Patch screen › Universes: a universe the console sends to with no
   fixture on it reads "heard, nothing patched". If the console sends 1 and
   you patched 0, `A 0.0.1` says that while `A 0.0.0` stays silent.
4. Network: Mac and console on the same subnet, one active interface, the
   firewall allowing UDP 6454 (Art-Net) and 5568 (sACN).
5. Two sources on one universe: Art-Net takes the latest packet, sACN the
   highest priority. Send each universe from one console.
6. The console lost the engine after the network dropped (a cable pulled,
   a switch restarted, the Mac woke from sleep): the [log](#logs) says
   "Art-Net listener failed; trying again" (or "OSC UDP failed; trying
   again") with the error once, and "Art-Net listening" when it listens
   again. The engine makes the listener again 1, 2 and 4 s after the
   failure and then every 5 s, so Art-Net and OSC come back by themselves
   within 5 s of the network; no restart is needed. Meanwhile readiness
   reads "not listening: …" on **Art-Net port 6454 available** or **OSC
   port 8000 available**. "… waiting for a usable network" means macOS
   holds the listener until a network is up; it goes on by itself.
   OSC feedback: a subscribed controller gets feedback again once it sends
   anything (at the latest its renewal within 60 s); the fixed feedback
   target (`oscFeedback` in `settings.json`) gets it again only when it sends something itself,
   so a target that only listens may need Engine › Restart Engine until
   that is fixed (B352).

Done when the pill turns green.

## A layer shows an error, or the picture is black

The Layers screen shows the problem in the row's Media column.

| The row reads | Do |
|---|---|
| "no file N in folder M" | The number does not exist or the file is not playable: Media screen, that folder: invalid name, needs transcode, unreadable ("AVFoundation cannot open .webm files": a `.webm`, `.mkv`, `.mxf`, `.wmv`, `.flv`, `.ogv`, `.asf`, `.f4v`, `.divx`, convert it on another machine) ([Media library](media-library.md)) |
| "<file>: the engine stopped twice while reading it: replace or re-save the file to try again" | The engine stopped twice while this file was read, opened on a layer or decoded as a mask, so it is listed as unreadable: replace or re-save the file; it is read again when it changes ([Media library](media-library.md#thumbnails-and-probing)) |
| A decoder error ("unsupported codec", "VideoToolbox error", "no video track", "frame rate above 1000 fps") | Transcode the file again or replace it, then select another clip on the layer and this one again, or send Clear error (Layer channel 50 at 24 to 31): the file is opened anew |
| A decoder error on a movie that was playing ("HapDecode failed", "VideoToolbox error") | For half a second or more no frame of the file decoded. The layer shows the last frame that did. When not one frame of a newly selected file decodes from its start frame, the layer goes on playing the clip it showed before. The error goes by itself when a frame decodes again, or when another clip is selected. Transcode the file again or replace it |
| "no capture device / display / Syphon server numbered N" | Nothing has that number in folder 0: Inputs screen, **Number** ([Live inputs](live-inputs.md)) |
| "not running", "in use by another app", "no signal" | The live input: plugged in, not open in another app, a signal on the card |
| "M/N <file> is not answering: the volume is slow or gone" | The file selected as M/N did not open within 2 seconds: its disk is asleep, unplugged or a network share that went away, or a cloud copy not downloaded. The layer keeps its picture, and the row still describes that picture with this error added (today the row's chip reads a red "Decoder error" for a movie or still that keeps playing, and the whole text for a live picture); the clip plays if it opens while it is still selected; other layers change as usual meanwhile. If the file then fails to open, the error becomes "M/N <file>: <why>" and the layer still keeps its picture until another selection. Select another clip or bring the volume back; keep show media on the Mac's own disk |
| A permission text | Inputs screen › **Authorize** (not in show mode); screen recording needs Engine › Restart Engine after the grant |

The row is green and the picture black, in this order, done when the
picture appears:

1. The layer's Intensity (channels 1 and 2) above 0; Folder and File not 0.
2. Play mode 112 to 127 is Freeze.
3. The Master fixture, if patched: Intensity (channels 1 and 2) up,
   Control (channel 3) below 64; 64 to 127 is Freeze all, 128 to 191
   Blackout.
4. The Output fixture, if patched: Intensity up, Control below 64; 64 to
   127 is Blackout, 128 to 191 Freeze.
5. The output bound ([below](#outputs-stay-black-although-the-layers-play)).
6. Scale and Crop.
7. The value came from the UI, a cue or OSC and Who controls is **Console
   only**: it is kept, not shown ([Remote control](remote-control.md#who-controls)).

The Layer panel on the Layers screen shows every channel's value as the
engine reads it.

## An ingest job fails

The Media screen's ingest queue shows the reason under the job.

| The job reads | Do |
|---|---|
| "AVFoundation cannot open .webm files" (or `.mkv`, `.wmv`, …) | macOS has no reader for that container. Convert the file on another machine and import the result. An imported copy stays in `_incoming/` in the library root (as `name-2.ext` when that name was taken): **Remove** the job, then delete that copy in Finder |
| "Cannot Open" | A damaged file in a container macOS reads (`.mov`, `.mp4`, `.m4v`): export it again |
| "cannot read the source: unknown duration" (or "unknown frame rate", "frame rate above 1000 fps") | The movie's header gives no usable length or frame rate, or claims more than 1000 frames per second (a damaged or badly written file): export it again and import the result. An imported copy stays in `_incoming/` in the library root: **Remove** the job, then delete that copy in Finder |

## The picture is frozen

Play mode 112 to 127 is Freeze on the layer; Master Control 64 to 127 is
Freeze all; Output Control 128 to 191 is Freeze. A frozen output shows a
test pattern live over the held frame. A still image, or a live input that
lost its signal, holds its last frame by design.

A movie whose frames do not decode holds the last good frame. A bad frame
in the middle of a clip is skipped: the frame before it stays up a moment
longer. The log says `decode failed, frame skipped` with the frame number
and a count, at most once every 10 seconds. A bad frame where playback
starts (the start of the file, a seek, a retrigger, a cue jump) is not
skipped: the layer keeps what it showed before, the frame before the seek
or the previous clip, until a frame decodes. When no frame decodes for half
a second, the Layers row shows the decoder error (see above) and the log
says `decode failing`, then `decode still failing` with a count, and
`decode recovered` when a frame decodes again. These lines too come at most
once every 10 seconds, each with the number of lines held back, so a
damaged clip that loops does not fill the log.

## Outputs stay black although the layers play

- The output's row on the Outputs screen: green with its display, not "not
  assigned to a display" or the red "display missing"
  ([Outputs and mapping](outputs-and-mapping.md#add-an-output-and-bind-it-to-a-display)).
- Its Intensity up, and the Output and Master fixtures' Intensity up with
  no Blackout: a test pattern follows them like the picture, so a pattern
  that stays black points at them.
- No output at all: the status bar's outputs item reads 0 (the project has
  no output) or off (the engine renders nothing; the fps item then reads
  "no outputs rendering: add or assign one (Outputs)").
- After a library root change the layers look their media up in the new
  library at once: a number that does not exist there reads "no file N in
  folder M".
- A display layer (folder 0, 21 to 28) black: "screen permission not
  granted" wants **Authorize screen** on the Inputs screen, the grant under
  Privacy & Security › Screen & System Audio Recording, then Engine ›
  Restart Engine; macOS asks again about once a month, on the main
  display ([Live inputs](live-inputs.md#displays-2128)).

## Lines and a yellow cross on the projector

Someone has Warp & Slices open: the projector shows what they edit
([Warp, slices and masks](warp-and-masks.md#show-on-output)). Leave the tab or
switch **Show on output** off; a browser that went away takes them with it
within a few seconds.

## Dropped frames

The status bar shows "dropped · 1 s"; in show mode the tile on System ›
Live metrics is red, and the status bar's item is red while the show is
locked. The tile to read is **dropped**; the graph shows the GPU's p99
against the frame budget ([System screen](screens/system.md#live-metrics)).

<img src="images/metrics.png" width="1396" alt="System › Live metrics: tiles for fps, dropped, GPU and CPU time, DMX to photon, texture misses, clients, preview and audio, and the GPU graph">

- Heat or power: System › Machine › Thermal nominal (fair still passes the
  readiness item); AC power. Fix airflow first; the engine only reports the
  thermal state and does not slow itself down.
- Other work on the Mac: quit other applications, switch Time Machine
  off, Spotlight off for the library's volume, show mode on (it pauses
  ingest and the library's thumbnails). Many open browser previews cost time too: the clients tile.
- Display mode: the display at the canvas frame rate or a multiple of it,
  not mirrored; the output's Mode set, so show mode applies it
  ([Outputs and mapping](outputs-and-mapping.md#display-modes)).
- Too much media: 4K60 ProRes, Blur and Edge, dissolves on many layers
  ([Media library](media-library.md#what-a-mac-can-play)).

## A layer shows stale frames

`/metrics` (see [the API](reference/api.md)) counts `staleFrames`: a movie
shown with an older frame than its play position. `layerStaleFrames` says
which layer (the first number is layer 1, counted since the engine started).
Some counts are by design: a retrigger, a switch of play mode and a bounce
turn above about 1.2x speed hold about 1; a bounce turn at normal speed and
the wrap of a loop with in and out points hold none. A count that keeps rising on a plain
loop means the decoder cannot keep up: too many or too heavy layers (4K60 on
several layers), or a slow volume for the library.

## No sound

Audio plays on the Mac's default output device in one stereo mix
([Media library](media-library.md#audio)). System Settings › Sound ›
Output: the right device; a replugged HDMI display can switch it. The
layer's audio channels on the console (volume, mute); audio plays only at
100 % speed forward. System › Live metrics › audio counts underruns. Sound
late or early against a display that delays the picture: set
`audio.offsetMs` in `settings.json` ([Media library](media-library.md#audio)).

## A cue does not fire

- From GO: Who controls on **Console only** keeps the cue's values from
  showing; the Show screen says so in yellow.
- From a trigger: the timecode must be Locked and pass the trigger time
  running; a start exactly at the trigger, a jump back, or a jump forward
  of 5 seconds or more fires nothing ([Show control](show-control.md#triggers-and-follows)).
  Fire a skipped cue with Go to.
- From OSC or MSC: the OSC panel's "Last received" or the MIDI panel's last
  message shows whether it arrived (a listed Go to a number with no cue
  arrived and fired nothing); the MSC format and device id must match
  ([Remote control](remote-control.md#midi-show-control)). A cue command is
  never refused, so the log has no line for it: a goto to a number that does
  not exist fires nothing. Only `/fanous/show/mode 1` is refused, while
  readiness blocks: the OSC panel says so in red ("Refused at …") and the
  [log](#logs) has "OSC/MIDI command refused".
- After an engine start outside show mode no cue is current: Go to the
  right one. In show mode a crash or a restart keeps the current cue.

## LTC does not lock

Show screen › Timecode: the state should read **Locked** and "frames seen"
count up ([Show control](show-control.md#timecode)).

- Source **LTC**, the **Timecode** switch on, the right **Device** (an
  unplugged one reads "not connected") and **Channel** (1 is the first; the
  LTC may be on another).
- Level: the meter under the readout shows the channel's peak. Near the
  bottom, nothing arrives on this channel; yellow, above −3 dBFS, is close
  to clipping. Too quiet or clipped LTC does not decode: set the interface's
  input level.
- Permission: the red line under the readout says "microphone permission
  denied" when Fanous is not allowed under Privacy & Security › Microphone
  (or **Authorize microphone** on the Inputs screen, not in show mode).
- Freewheel (yellow) means the signal dropped; Lost (red) means it stayed
  away longer than the Freewheel time.
- An input whose device drops, changes its sample rate or comes back opens
  again by itself; turning **Timecode** off and on again reopens it by hand.

For MTC the MIDI panel must list the source; connect the interface or
enable a network MIDI session, then choose it under Device or All sources.

## A CITP console does not see Fanous

- System › Network, CITP line: "not running" means the CITP server did not
  start (the log says "CITP start failed"), or its listener is down for the
  moment ("CITP listener failed; trying again"): then consoles already
  connected stay connected and may keep streaming, although the line hides
  them until "CITP listening". Otherwise it shows the TCP port, the
  consoles and the open streams.
- Same subnet as the console, and multicast must pass the network (managed
  switches: check multicast settings); not with `--no-network`.
- Firewall: `fanousd` needs outgoing UDP to 224.0.0.180 and 239.224.0.180
  on port 4809; a network filter holds the first packets until you allow
  them ("CITP PLoc beacon failed" in the log).
- No hardware console has been tried yet
  ([known limitations](reference/known-limitations.md#consoles-and-protocols)).

## The project is gone after a restart

When `project.json` does not read as a project at start (a file cut off by
a crash or a full disk, an empty file, a hand edit, a file from another
version), the engine keeps a copy of it as `project.json.unreadable-<time>`
and runs the newest [project version](screens/system.md#project-versions)
that can be restored instead, skipping versions that are damaged too; that
version is then saved as `project.json`. If there is no space for the copy,
the kept name is a second name for the same file until a save succeeds:
do not edit `project.json` in place until then. If the save fails (a full
disk), the damaged file stays `project.json` until a later save succeeds,
and a start before that falls back again. Only when no version can be
restored does it start with the standard patch and no cues. Show mode that
resumes after a crash resumes on that version. If the damaged file cannot
be kept aside at all, the engine runs the version but saves no change to
`project.json`, so nothing is written over the file; versions are still
made.

The readiness item **Project file read at start** then fails, without
**Run checks**. It says when it happened, the project and the version that
run, with the version's date and time, or that a new project runs, the
kept file, and what to do, for example "At the start of
2026-11-18T14:44:45+0100: project.json was not readable; running project
"B281 show" from version "Manual" of 2026-11-18T14:13:53+0100; the file is
kept as project.json.unreadable-20261118T134445.943Z. Check the patch, the
cues and the outputs. A repaired file goes back as project.json with the
engine stopped." The last sentence is the action:

| The row reads | Do |
|---|---|
| "project.json was not readable; running project …" | Check the patch, the cues and the outputs; a repaired file goes back as `project.json` with the engine stopped |
| "project.json is from a newer Fanous (schema 2); running project …" | The version is the newest one this Fanous can read, from before the newer one was installed: check the project name. For the newer project, go back to the newer Fanous and put the kept file back as `project.json` with the engine stopped |
| "… not written to project.json (…) until a later save succeeds …" | Free disk space now: until a save succeeds, a stop loses the changes |
| "… could not be kept aside (…) …; changes are not saved to project.json (versions are still made)" or "… could not be moved aside …" | Fix the permissions of the folder that holds `project.json` or free disk space, then restart the engine |
| "… and no version restores; a new project runs …" | Repair the kept file and put it back with the engine stopped, or build the show again |

In show mode the status bar reads "not ready: Project file read at start".
The log line is "project file not readable at start", with the same text.

The text waits in `project.json.notice`: the item fails at every start
until someone acknowledges it, also after a restart that reads the
restored `project.json`, and also after you put a repaired file back (the
engine cannot tell your repair from its own saves; the "At the start of"
time says how old the notice is). Acknowledging it marks it seen: the
notice is removed and the item passes from then on, in this run and at
later starts; **Take back** brings both back. When the notice cannot be
removed, the acknowledgement is refused with the reason.

Changes made after that version are not in it: versions are saved at
engine start, on entering show mode and every 10 minutes after a change.
To get the kept file back: with the engine stopped (Engine › **Stop
Engine…**), move it back to `project.json` once it is repaired, or after
going back to the newer Fanous.

## Logs

System › Logs (programmer) shows the last 64 KB of the engine log with a
filter field, **Refresh** (it does not follow the log live) and
**Download** (the whole current file). The start-up lines are in the 64 KB
view only when the engine started recently. The Service line shows the
engine version and its uptime: a short uptime you did not expect means it
restarted.

<img src="images/logs.png" width="1395" alt="System › Logs with the filter field set to compositor, Refresh, Download and the Service line">

The file is `~/Library/Logs/Fanous/fanousd.log` (Engine › **Open Logs**
opens the folder); it rotates once at 10 MB to `fanousd.log.1`, which
Download does not serve, and the rotation drops the older copy, so copy the
log before restarting anything in a crash loop. A crash leaves no trace in
it: look in `~/Library/Logs/DiagnosticReports` for a report of `fanousd`.
The same lines are in the unified log under the subsystem `org.fanous`:

```bash
log show --predicate 'subsystem == "org.fanous"' --last 1h
```

| Line | Means |
|---|---|
| "HTTPS listener failed; trying again", "Art-Net listener failed; trying again", "OSC UDP failed; trying again", "OSC TCP failed; trying again" | That listener could not open or stopped working (a port another program holds, the network gone); the engine runs without it and makes it again every 5 s at most, logging the next line only when the outcome changes: "HTTPS listening", "Art-Net listening", "OSC listening" (UDP), "OSC TCP listening" when it is back |
| "… waiting for a usable network" | macOS holds that listener until a network is up; it listens by itself then |
| "CITP listener failed; trying again" | The CITP server's port stopped working; the console does not list Fanous until "CITP listening" (a new port, announced by the next beacon) |
| "sACN port in use; running without sACN" | The readiness item warns too |
| "sync port in use; not receiving sync packets" | System › Sync: apply a free port |
| "CITP start failed", "CITP PLoc beacon failed (firewall?)" | The console will not list Fanous |
| "media not found", "media open failed" | The layer's row says the same |
| "media open not answering" | A file did not open within 2 seconds (`file`, `layer`): the section [above](#a-layer-shows-an-error-or-the-picture-is-black). "media open answered after a newer selection, dropped" means an open finished (opened or failed) after its layer had moved on: something else was selected, or the newer selection was still waiting for an open slot or for this open; nothing is shown from it. "media open failed" after a "not answering" is that file failing late: the layer keeps its picture |
| "project file not readable" | The section above |
| "stale show state ignored" | The engine or the Mac was down for more than 2 hours since show mode was last written: a normal start |
| "show mode resumed after an unclean stop", "show mode kept across a restart" | Show mode came back; the second is a deliberate Restart Engine |
| "readiness changed in show mode" | A check during the show found an item that started failing or passes again: `failing`, `acknowledged` (of those failing), `passing` and `blocking` (what blocks now). A warning when an item started blocking. An acknowledged item that fails again is here only, not in the status bar |
| "readiness acknowledged in show mode", "readiness acknowledgement taken back in show mode" | The programmer acknowledged or took back `item` on System during the show; `blocking` is what blocks now |
| "the engine stopped while reading this library file", "the engine stopped twice while reading this library file" | `file` was being read (probed or thumbnailed) when the engine last stopped: a crash, a kill or a power cut. The first time it is read once more; the second time the Media screen lists it as unreadable, "the engine stopped twice while reading it: replace or re-save the file to try again", and the engine starts without reading it. A copy of the file, or saving it again, is read again; Rescan alone does not |
| "the engine stopped while a layer or a mask decoded this library file", "the engine stopped twice while a layer or a mask decoded this library file" | The same for a file a layer was opening, or a still an image mask was decoding, when the engine last stopped. The first time it is opened once more (an open of the file that comes through in between starts the count again); the second time the Media screen lists it as unreadable with the same reason, a layer that selects it shows that reason as its error instead of playing it, and an image mask on it covers nothing (the readiness check lists the mask as "(unreadable)") |
| "the engine stopped during this ingest job", "the engine stopped twice during this ingest job: failed; no file is moved or deleted for it" | The same for the ingest job of `source`: the first time it starts over, the second time it fails, "the engine stopped twice during this job"; failing moves or deletes no file. Remove the job and queue it again to try once more |
| "the engine stopped before this ingest job put its original away", "the engine stopped before this ingest job was done and its output is missing" | The engine stopped after the job's result was in the library. The first: the job is done and the original is left where it was (an upload's copy in `_incoming/`); move or delete it yourself. The second: the result was removed since; the job fails and the source is left in place |
| "autosave failed", "show mode state not saved" | The disk or the folder is not writable: the engine plays on and saves nothing |
| "OSC/MIDI command refused" | A show-control command from OSC did nothing; in practice `/fanous/show/mode 1` while readiness blocks. `command` is the message in its plain form, `code` and `reason` say why (`notReady` names the blocking readiness items). One line per command and code every 3 s at most; `repeats` counts the refusals in the 3 s after the previous line, so after a burst that stopped, the rest of its count comes with the next refusal, whenever that is, unless that command was taken from OSC or MIDI in between: then the next refusal logs at once and the old count is dropped |

## Disk full, or the folder not writable

The readiness item checks the library's volume only; the project, the
versions and the log live on the home volume. When that is full or
`~/Library/Application Support/Fanous` is not writable, the engine keeps
playing but saves nothing and the UI does not say so: the log reads
"autosave failed". Free space, or fix the folder's owner and permissions,
then save a named version.

## Restart the engine

Engine › **Restart Engine**: the outputs go black for a moment and the UI
reloads; every iPad logs in again; the console's values apply again at once
and playback positions start over. Avoid it during a show; if show mode is
on, the engine comes back in show mode and the displays keep their modes
([Show-day checklist](show-day-checklist.md#what-comes-back-after-the-engine-stops)).
Quitting the app does not stop the engine unless you choose **Stop Engine
and Quit** in the quit question; **Stop Engine…** does, and **Start
Engine** starts it again.

## Go back to an earlier version

A change made the show worse and Undo is no help. System › **Project
versions** holds the versions: automatic ones at every engine start, on
entering show mode, every 10 minutes and before a revert, each only when
the project changed since the newest version (the newest 50 automatic ones
are kept); named ones from **Save version…**, kept until you delete them.

<img src="images/versions.png" width="1396" alt="System › Project versions with a named version Before doors and its Revert and Delete buttons">

```mermaid
flowchart TD
  start["Revert… on the version"] --> role{"Programmer?"}
  role -- no --> login["Log in as programmer"]
  role -- yes --> lock{"Show locked?"}
  lock -- yes --> unlock["L to unlock"]
  lock -- no --> mode{"Show mode on?"}
  unlock --> mode
  mode -- yes --> leave["Leave show mode: the display modes go back for a moment"]
  mode -- no --> dialog["Confirm: the current project is saved as a version first"]
  leave --> dialog
  dialog --> done["Reverted; the show lock stays as it was"]
  done --> wrong{"Wrong version?"}
  wrong -- "yes: Undo" --> back["Back to the saved copy"]
  wrong -- no --> fin["Show mode on again"]
```

Everything in the project goes back: layers, patch, outputs, canvases,
cues, timecode and MIDI settings. Undo is refused when a live input's
number changed meanwhile; revert to the "Before revert to …" version then.
A console can do the same with OSC: `/fanous/project/load "Doors 19:30"`
restores the newest named version with that name, under the same rules
([OSC reference](reference/osc.md)).

## Reset the project

This drops the patch changes, outputs, cues and timecode settings. Save a
named version first; the `versions/` folder is not touched.

1. Engine › **Stop Engine…**, or quit and choose **Stop Engine and Quit**.
2. Finder › Go › Go to Folder, paste `~/Library/Application Support/Fanous`
   and move `project.json` away, for example to the Desktop.
3. Engine › **Start Engine**. Done when the UI shows the standard patch.

## A forgotten password

At the Mac: the app window always has programmer access. System › Roles
and passwords sets a new password or clears it. Only without the Mac's
screen: stop the engine, remove the `passwords` entry from
`~/Library/Application Support/Fanous/settings.json` (or move the file
away, which also resets the sync and OSC feedback settings) and start the
engine; the role is open again. The certificate is reset with
`fanousd reset-tls`, with the engine stopped
([Files, ports and the command line](reference/files-and-ports.md#service-and-process-names)).

## For the venue's systems technician

- Monitor without a login: `https://<mac>:8443/healthz` (status, version,
  uptime; an uptime that reset is a restart), `/metrics` (frames, missed,
  late, stale frames per layer, show mode, clients) and `/api/live` (per universe `active` and the
  age of the last packet); use `curl -k -m 8`. Readiness, the show lock and
  timecode are on the WebSocket only. These addresses need no password, so
  reach them from a management network only.
- Firewall both ways: in UDP 6454, 5568, 8000, 8002 and TCP 8443; out UDP
  to the Art-Net poller, to OSC subscribers, to 224.0.0.180 and
  239.224.0.180 on 4809, and sync on 8002
  ([Files, ports and the command line](reference/files-and-ports.md#ports)).
  Allow-list the console's addresses: OSC and Art-Net carry no login.
- A managed Mac: a profile can block the login item (the Engine menu then
  reads "service needs approval"), pre-deny the camera and microphone,
  force updates (the readiness item cannot be satisfied) or lock the
  lock-screen settings; ask for the profile list before the first show.
  Keep the app in Applications: a moved or re-signed app leaves the
  background service pinned to the old binary until Stop Engine and Start
  Engine.
- Time Machine off during the show, not paused: a Time Machine target that
  does not answer can stall the readiness probe, which runs on the same
  queue as the UI's live values.
