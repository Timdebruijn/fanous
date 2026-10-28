<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Multi-server sync

Two or more Macs can show one picture: each drives its own projector with its
own part of the picture, its own blend and its own warp, and a layer on one Mac
plays in step with a layer on the other. The console decides which layers
follow which with one channel per layer, **Sync** (layer channel 51).

## What sync does and does not do

Sync shares one thing: the **clock** of a layer, that is where in its file it
is, how fast and in which direction it runs. A **master** layer sends its
clock on the network under a group number (1 to 8). A **slave** layer in the
same group, on any Mac and any layer number, takes that clock every frame.

Everything else stays local to each layer and each Mac: folder and file,
intensity, position, scale, crop, colour, effects, blend mode, audio volume,
and the outputs with their slices, blend and warp. So the left Mac can show the
left half and the right Mac the right half, from the same console, in step.

- A slave ignores its own play mode, speed, in and out points and timecode
  chase while it has a master, and a Retrigger on the slave does nothing; a
  retrigger on the master reaches the slave as a jump.
- Different frame rates are fine: a 25 fps file can follow a 50 fps master and
  keeps the same time. Files of different length drift apart at the loop point;
  that is up to you.
- Only movies have a clock to share. A still, built-in content from folder 0
  and Syphon input neither send nor follow.
- A slave's audio plays while its master runs at normal speed, forward, without
  a loop region.
- OSC, MIDI, cues fired from one machine's UI and timecode reach that machine
  only. Drive everything that must happen on both machines from the console.

**How close.** The slave sets its position from the master's packet every
frame; it never adds up small errors, so the offset after an hour is the same
as after a second: packet jitter, well under a millisecond on a wired network.
What remains is **one frame of display phase**: Macs have no genlock, so the two
projectors refresh at slightly different moments, up to one output frame apart.
Both show the same frame of the file, but not at the same microsecond. This is
the floor; nothing in Fanous makes it smaller.

## The Sync channel

| Value | Means |
|---|---|
| 0–9 | Off: the layer plays on its own clock |
| 10–89 | Master, group 1 to 8 (10–19 group 1, 20–29 group 2, …) |
| 90–169 | Slave, group 1 to 8 (90–99 group 1, 100–109 group 2, …) |
| 170–255 | Off (reserved) |

A group also works inside one Mac: layer 3 as slave 1 follows layer 1 as
master 1 on the same machine, with no offset at all.

**One master per group.** Two masters in one group on different Macs: the Mac
with the lower machine id wins, slaves follow it, and both the layer badge and
the readiness list say so. A slave in a group without a master plays on its own
clock and is marked "no master".

## Two Macs, one picture: left and right

This is the setup sync was made for: two Mac minis, two projectors side by
side with a soft-edge blend in the middle, one console.

1. **Same library numbering on both Macs.** Copy the library so every file
   the show uses has the same folder and file number on both machines
   ([media-library.md](media-library.md)). With pre-split files (below) the
   numbers are the same and the contents differ.
2. **One set of layer fixtures per Mac on the console.** The Sync channel has
   to say "master" on one Mac and "slave" on the other, so the two Macs' layer
   fixtures need different DMX addresses: on the second Mac's Patch screen move
   its layers to free addresses, in another universe (for example Layer 1 to 8
   on A 0.0.4) or at other start addresses in the same one, and patch both sets
   on the console. Keep the layer layout the same on both, so a console group
   of "Layer 1 on both" sets folder, file and intensity in one go.
3. **The console reaches both Macs**: Art-Net broadcast, or sACN (multicast
   reaches every machine that listens to the universe). Check on each Mac's
   Patch screen that its universe pills are green.
4. **Sync channel**: on the left Mac, Layer 1 Sync = **Master 1**; on the right
   Mac, Layer 1 Sync = **Slave 1**. Put the same media on both (step 1).
   Further layers that must play in step get their own group: Layer 2 Master 2
   on the left and Slave 2 on the right, and so on. Layers that need no sync
   stay Off.
5. **Split the picture** (next section) and set the **blend** on each Mac's
   Outputs screen: the left output's right edge and the right output's left
   edge get the same Overlap ([outputs-and-mapping.md](outputs-and-mapping.md#blend-edges)).
   Check the seam with the Blend check test pattern.
6. **Check** the Layers screen on the right Mac: Layer 1's badge reads **S1**
   in green, "locked to Layer 1 on" the left Mac. Then run the camera check
   below once per rig.

Both Macs need the same sync port (8002 unless you changed it) and must be on
the same network segment for broadcast to reach them. If a firewall runs on
the Macs, allow `fanousd` UDP 8002 in and out
([getting-started.md](getting-started.md#firewall)).

## Three ways to split a picture

| Way | Canvas on each Mac | Files | Use it when |
|---|---|---|---|
| **Slices of one file** | the whole picture (for example 3584 × 1080 for two 1920 projectors with a 256 px overlap) | the same full-width file on both Macs | the usual case: one file to make and update, the overlap is just more of the same picture. Each Mac decodes the whole file |
| **Pre-split files** | one projector's part, overlap included | the left part on the left Mac, the right part on the right Mac, under the same folder and file number | the full file is too heavy to decode on one Mac, or the parts are made separately anyway |
| **One canvas per Mac** | one projector's part | the same full-width file on both | you want no slices: each Mac's layer places its half of the file on its own canvas with the layer's Fit mode (Native) and Position X |

With **slices**, each Mac's output keeps one slice and sets its **Source x · w**
to its part of the canvas (Outputs › Warp & Slices › Slices): on the left Mac
x 0, w 1920; on the right Mac x 1664, w 1920 for the example above. The
overlap is the 256 pixels both slices share, and the blend edge Overlap is
256 on both outputs.

## What the screens show

**Layers screen.** A layer with Sync on gets a badge under its name: **M** for
master or **S** for slave, then the group, so **S3** is a slave of group 3.
Hover it (or tap the layer and read the detail) for the state in words.

| Badge colour | Master | Slave |
|---|---|---|
| green | this layer is its group's clock and sends it | **locked**: following the master |
| yellow | | **freewheel**: packets are late; running on at the master's last speed |
| red | a second master in the group (one wins) | **lost**: no packets for 2 s; or two masters in the group (it follows the winner) |
| grey | not sending: no movie playing | **no master** in the group, or no movie playing on the slave |

The layer detail repeats the state under the Sync channel, for a slave with the
master's layer and machine and the correction of the last frame, for example
"locked to Layer 1 on 415FF791, −0.2 ms". The machine is its name for a master
on the same Mac and the first 8 characters of its machine id otherwise (System ›
Sync shows each machine's id).

**Status bar.** "sync lost" appears in red while any slave on this Mac is lost;
it links to the Layers screen.

**System › Sync**:

- **Machine**: this Mac's name and the first 8 characters of its machine id
  (hover for the whole id). The lower id wins a group with two masters.
- **Packets**: in (from other Macs), out (sent by this Mac) and decode errors,
  counting up live. While a master plays, out counts at the frame rate; with
  no master it still sends one packet a second. In stays at 0 on a Mac that
  hears no other Mac: check the network and the port.
- **Masters here**: the groups this Mac is the clock of, with the layer.
- **Conflicts**: groups in which a second Mac also sends a master.
- **Interface**, **Port**, **Target**: the settings, below.

## Readiness

Two items in the readiness list (System screen) cover sync. Both are
**warnings**: they never block show mode, because a slave without a master
still plays on its own.

| Item | Warns when |
|---|---|
| Sync groups have one master | a slave in use has no master, or a group has two masters (on this Mac, or another Mac outranks this one's) |
| Sync packets arriving | a slave in use has had no packet for 2 s |

## When packets stop

- A packet that is late (1.5 frames, at least 50 ms) puts the slave in
  **freewheel**: it keeps running at the master's last speed, so a late packet
  never stutters the picture. The next packet puts it back on the exact
  position; normally that is a correction of less than a frame.
- After **2 seconds** without a packet the slave is **lost**: it keeps
  freewheeling, the badge turns red, the status bar says "sync lost" and the
  readiness item turns yellow. Over 2 seconds the freewheel drifts by about
  0.1 ms, nothing you can see.
- The first packet that arrives relocks it. There is nothing to reset.

If the master Mac goes away for good, the slave keeps freewheeling at the
master's last speed. Set its Sync to Off (it then plays on its own clock), or
make another layer master of the group, to take over.

## Sync settings

System › Sync (programmer; refused while the show is locked or show mode is
on). **Apply** saves them on this Mac (not in the project, so a project version
or undo does not change them) and restarts sending and receiving at once.

| Setting | Default | Means |
|---|---|---|
| Interface | any | the network interface the broadcast goes out on: **any** is the first active, non-loopback interface; or pick one (en0) if the Mac has more than one |
| Port | 8002 | the UDP port packets are sent to and received on; the same on every Mac of the show |
| Target | broadcast | **broadcast**: every Mac on the interface's network hears it, like Art-Net. Or one IPv4 address (`10.0.0.12`), optionally with a port (`10.0.0.12:8003`), to send to one Mac only |

Broadcast is right for almost every show. A unicast target only reaches the Mac
it names, so with more than two Macs every one but that one stops hearing the
master.

The port must be free: the ports of Art-Net (6454), sACN (5568) and OSC (8000,
8001) are refused. If another program holds the port you apply, the settings are
saved but this Mac receives no sync packets until you apply a port that works;
the message on screen and the log say so.

## The camera check

Once per rig, before the first show, check what the audience sees:

1. Make a test movie with the frame number burned into every frame (any video
   tool), as the same folder and file number on both Macs.
2. Play it on Layer 1 on both: Master 1 on the left Mac, Slave 1 on the right
   Mac, both shown on their projector (the full frame, or at least the numbers).
3. Film both projections at once with a phone at 240 fps (slow motion), for
   10 minutes.
4. Step through the video. **Pass**: the numbers are never more than one frame
   apart, the difference does not grow over the 10 minutes, the slave never
   stutters, and the blend seam does not breathe.
