<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Console setup

Fanous is one fixture type, "Fanous", with three DMX modes. You patch each
mode as its own fixture on the console.

| Mode | Channels | Patch one per | Does |
|---|---|---|---|
| Layer | 64 | layer | Everything about one layer: intensity, media, play mode, position, colour, effects, crop, audio |
| Master | 8 | machine | Master intensity, freeze or blackout, a global test pattern, master speed |
| Output | 8 | output | Output intensity, blackout or freeze, test pattern, blend on or raw |

16-bit values (intensity, speed, position, in and out points and others) are
coarse/fine pairs on adjacent channels, coarse first. Layer channels 51 to 64
are reserved. Every channel, default and value band is in
[channel-map.md](../channel-map.md); the OSC key of each parameter is in the
same table.

A new install has 8 layers. The Patch screen has **Add layer** and **Remove
last layer** and shows "N of M layers" where M is the limit the engine reports.

## The standard patch

A fresh project is patched like this:

- Layer n goes on Art-Net universe `(n-1) / 8` (whole number division) at
  address `(n-1) % 8 * 64 + 1`. Eight layers fill one universe exactly.
- Master goes on the next universe after the layers, at address 1.
- Outputs 1 to 4 follow the Master on that universe, at 9, 17, 25 and 33.

With 8 layers:

| Fixture | Universe | Address |
|---|---|---|
| Layer 1 to 8 | A 0.0.0 | 1, 65, 129, 193, 257, 321, 385, 449 |
| Master | A 0.0.1 | 1 |
| Output 1 to 4 | A 0.0.1 | 9, 17, 25, 33 |

With 16 layers, layers 9 to 16 use A 0.0.1 and Master and Outputs move to A 0.0.2.

Fanous writes Art-Net universes as `net.subnet.universe`, shortened to
`A 0.0.1`, and sACN universes as `S 1`. `A 0.0.0` is Art-Net port-address 0.
Some consoles count Art-Net universes from 0, others from 1: check which one
yours does.

## The Patch / DMX screen (key 4)

The toolbar shows "N fixtures · N universes" and, in red, the number of
collisions. **Channel map** opens the channel list; **Export GDTF** downloads
the fixture file.

- **Fixture table**: Fixture, Type (with footprint), Universe, Address,
  Footprint, Status. Status says "ok", "unpatched · no console control",
  "collides with Layer 2 · 65-128" or "exceeds universe".
- **Selected fixture** (programmer): choose the Universe (A 0.0.0 to 0.0.3 and
  S 1 to S 4, plus any universe that has been heard), set the Address with the
  stepper (Shift steps by 10; **0 means unpatched**), or press **Unpatch**.
  Below it: Protocol, Interface, Hold on loss and sACN priority of the
  universe. These four are fixed engine defaults (all interfaces, 2.5 s, priority
  100) and read-only (B28).
- **DMX monitor**: 512 cells for one universe, coloured per fixture, red where
  fixtures collide, with live values. Click a cell to pin it: you see the
  fixture, the channel inside it, the parameter, the raw value and what it means
  ("17 → Loop rev"). The buttons above the grid switch universe.

The pill for a universe is green while packets arrive. It is yellow when
nothing has been received yet or for up to 2.5 s of silence, and red when a
patched universe has been silent longer than 2.5 s. In that case the fixtures
**hold their last values**.

## GDTF

**Patch › Export GDTF** writes `Fanous.gdtf` (GDTF 1.2). It contains the
fixture type "Fanous" with the Layer, Master and Output modes, channel
functions with their physical ranges, a channel set for every band (play modes,
blend modes, effects, test patterns), the 16-bit links and the default values.
The file is generated from the same table as the channel map, so they cannot
disagree. On the command line: `fanousd gdtf FILE`.

Import it with your console's GDTF import, then patch the modes as above.
grandMA3, Eos and MagicQ are the intended targets, but the import has not
been verified in any of them yet (B7, B40). If your console cannot read GDTF,
build a fixture by hand from the channel map.

## sACN instead of Art-Net

Choose an `S n` universe in the inspector instead of an `A` one and send sACN
(UDP 5568). The engine joins the multicast group of every sACN universe in the
patch and follows patch changes; unicast to the Mac works for any universe.
sACN multicast is joined on the default-route interface.

## Sources and merging

Send each universe from one console. Within Art-Net the latest packet for a
port-address wins. Within sACN the highest priority wins, equal priorities go to
the most recent packet, and per-address priority is not supported.

The project's **Source policy** (Patch screen toolbar, programmer) decides how
DMX combines with values from cues and OSC: **DMX only** (the default: cues and
OSC parameter values are recorded but do not move a layer), **Internal only**
(cues and OSC only, DMX is shown but ignored), **LTP** (latest change per
parameter wins) or **HTP** (highest value wins for numbers such as intensity;
folder, file and mode channels fall back to LTP). The Layers screen shows the
policy in the Source column, and the Show control screen warns while the policy
is DMX only. Pick LTP for a show that mixes console control with cues.

## First light

1. **Media.** On the Media screen press **New folder**, enter number 1 and a
   name, **Create**. Press **Import…** and pick a clip; wait until the ingest
   queue says done. Or put a ProRes or HAP `.mov` in
   `~/Movies/Fanous Library/001_Test/001_clip.mov` with Finder.
2. **Output.** On the Outputs screen choose a display under **Add output on**.
   A new output shows the whole canvas.
3. **Console.** Patch fixture "Fanous", mode Layer, on A 0.0.0 at address 1.
   The universe pill in the status bar turns green when packets arrive.
4. **Values.** Set Folder to 1, File to 1 and Intensity to full (100 %; 65535
   on the 16-bit pair). The other channels can stay at their defaults, which the
   GDTF carries.
5. **Check.** On the Layers screen row Layer 1 shows `1 / 1 · 001_clip.mov`, the
   codec and size, intensity 100 % and a green dot, and the preview shows the
   picture. If the row shows a red message such as "no file 1 in folder 1", the
   file name or format is wrong; see [media-library.md](media-library.md).
