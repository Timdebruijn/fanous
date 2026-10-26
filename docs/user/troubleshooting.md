<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Troubleshooting

Start with the cause that is most likely, in the order given. Logs are at the
end.

## The UI says the engine is unreachable

Banners: "Connecting to the engine…", "Engine unreachable: …; retrying", or the
red "Connection lost … values shown are stale".

1. Open the **Engine** menu in the app and read the first line. "Engine 1.0.0-rc.1
   running · service installed" means the engine is fine and the problem is the
   connection (network, firewall, wrong address). "Engine not running" means it
   is down.
2. Choose **Start Engine**, or **Restart Engine** if it hangs. The engine also
   restarts itself within about a second after a crash.
3. Open `https://127.0.0.1:8443/healthz` in a browser on the Mac. A short JSON
   with `"status":"ok"` means the engine answers.
4. On another device: same network, `https`, port 8443, and the firewall allows
   TCP 8443 into `fanousd`.
5. Read the log (see below).

A second engine refuses to start with "fanousd is already running (pid n)":
there is one engine per user. If you started `fanousd` by hand in Terminal,
stop it first.

## "service needs approval in Login Items", or no engine at all

The first launch needs your approval once. Open System Settings › General ›
Login Items & Extensions and switch Fanous on under "Allow in the Background".
Then choose **Start Engine** in the Engine menu. Other first lines of the menu:
"service not installed" (choose Start Engine; it registers the service) and
"service plist missing" (the app is damaged; reinstall it).

## Certificate warning on the iPad

Expected once: the engine makes its own certificate. Compare the fingerprint in
the warning with System › Network › TLS fingerprint on the Mac, then continue.
It warns again if the certificate was reset or you use a different device or
browser. If the page does not load at all, check the address (see
getting-started.md) and the firewall. If the preview is a still image that
updates five times a second, the browser used the JPEG fallback instead of
H.264.

## A DMX universe is silent

The status bar has one pill per universe. Green: packets arrive. Yellow with
"silent": nothing received yet. Yellow with seconds: silent for less than 2.5 s.
Red: a patched universe silent for more than 2.5 s. The fixtures **hold their
last values** meanwhile.

- Console: output enabled for that universe, right protocol, right universe
  number. Art-Net `A 0.0.0` is port-address 0; some consoles start counting at 1.
- Compare with the DMX monitor on the Patch screen: its universe buttons list
  every universe that was heard. If the console sends universe 1 and you patched
  universe 0, you see the mismatch.
- System › Machine, section DMX universes, shows the sender's address, the packet
  count and the age of the last packet.
- Network: Mac and console on the same subnet, one active interface (see the
  show-day checklist), firewall allows UDP 6454 (Art-Net) and 5568 (sACN).
- sACN on a universe other than 1, 2 and 3 must be sent unicast to the Mac.
- Two sources on one universe: Art-Net takes the latest packet, sACN the highest
  priority. Send each universe from one console.

## A layer shows an error, or the picture is black

The Layers screen (key 1) shows the problem in the Media column of the row.

- Red "no file N in folder M": the number does not exist or the file is not
  playable. On the Media screen look for a red "invalid name" badge (fix the
  name), a yellow "needs transcode" badge (press Transcode), or "unreadable".
  See media-library.md.
- A decoder message in red: the file cannot be decoded. Transcode it again, or
  replace it. After fixing, send Control 24 to 31 (Clear error) on Layer
  channel 50.
- The row is green but the output is black. Check, in this order: Intensity
  (channels 1 and 2) of the layer; Folder and File are not 0; if you patched the
  Master fixture, its Intensity (channels 1 and 2) and Control (channel 3, 128 to
  191 is Blackout); if you patched the Output fixture, its Intensity and Control
  (channel 3, 64 to 127 is Blackout); the output is bound (Outputs screen);
  the Layer's Scale and Crop channels. The Layer detail panel on the Layers
  screen shows the value of every channel as Fanous reads it.
- Video plays but is frozen: Master Control 64 to 127 is Freeze all; Output
  Control 128 to 191 is Freeze; Play mode 112 to 127 is Freeze.

## Outputs stay black although the layers play

The engine renders the project's canvas (System › Machine shows the library and
displays it found) and every output you assign on the Outputs & Mapping screen.
Check that the output is bound to a connected display (its badge says "bound",
not "lost" or "unassigned"), that its intensity is up and that the layer's
intensity and media are set. Changing the library root on the System screen
takes effect after Engine › Restart Engine.

## Dropped frames

The status bar shows "dropped · 1 s"; System › Live metrics shows missed and late
frames, GPU and CPU time, texture misses. In show mode any dropped frame is red.

- **Heat or power**: System › Machine › Thermal should be "nominal"; the Mac must
  be on AC power. Fix airflow first.
- **Other work on the Mac**: quit other applications (Memory headroom in the
  readiness list), pause Time Machine, switch Spotlight off for the library
  volume, turn show mode on (it pauses ingest). Many open browser previews also
  cost time: see the clients tile.
- **Display mode**: the display must run at the canvas frame rate and not be
  mirrored. Fanous does not apply display modes (B33): set them in System
  Settings › Displays and compare with the Outputs status line ("@ 60").
- **Too much media**: 4K60 ProRes, many effects (Blur, Edge) and dissolves cost
  more than they look. See the performance advice in media-library.md.

## LTC does not lock

Show › Timecode: the pill should say Locked and "frames seen" should count up.

- Source is **LTC**, the **Timecode** switch is on, the right **Device** is
  chosen (an unplugged one is listed as "not connected").
- **Channel**: 1 is the first input channel of the device; the LTC may be on
  another channel.
- **Level**: LTC that is too quiet or clipped does not decode; check the input
  level of the audio interface.
- **Permission**: System Settings › Privacy & Security › Microphone must allow
  Fanous. An error text in red under the readout names the problem.
- Freewheel (yellow) means the signal dropped; Lost (red) means it stayed away
  longer than the Freewheel time.

For **MTC** the MIDI panel must list the source; connect the interface or enable
a network MIDI session, then choose it under Device (or "All sources").

## A CITP console does not see Fanous

- System › Network, CITP line: "not running" means the CITP server did not
  start (look for "CITP start failed" in the log); otherwise it shows the TCP
  port, the consoles and the open streams.
- Same subnet as the console, and multicast must pass the network (managed
  switches: check multicast settings).
- Firewall: `fanousd` needs outgoing UDP to 224.0.0.180 and 239.224.0.180 on
  port 4809. Little Snitch holds the first outgoing UDP packets until you allow
  them (B40).
- CITP has not been tried with a real console yet (B40).

## Logs

- **System › Logs**: the last 64 KB of the engine log, with a filter field,
  **Refresh** and **Download**.
- `~/Library/Logs/Fanous/fanousd.log` (Engine › **Open Logs** opens the
  folder).

## Restart the engine

Engine › **Restart Engine**. Outputs go black for a moment and the UI reloads.
DMX restores the state at once; playback positions are not restored. Do not do
this during a show. Quitting the app does not stop the engine unless you choose
**Stop Engine and Quit** in the quit question; **Stop Engine…** does, and
**Start Engine** starts it again.

## Reset the project

This deletes your patch changes, outputs, cues and timecode settings. Copy
`project.json` first if you might want it back.

1. Engine › **Stop Engine…**, or quit and choose **Stop Engine and Quit**
   (Keep Engine Running leaves the engine running with the old project in
   memory).
2. In Finder move `~/Library/Application Support/Fanous/project.json` away,
   for example to the Desktop.
3. Engine › **Start Engine**. The engine starts with the standard patch (8 layers).

Role passwords and the certificate are not in `project.json`. To clear all role
passwords move `settings.json` in the same folder away the same way (this also
resets the other machine settings). The certificate is reset with
`fanousd reset-tls`; browsers then warn again.
