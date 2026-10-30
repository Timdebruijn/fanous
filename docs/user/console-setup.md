<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Console setup

Fanous is one fixture type, "Fanous", with four DMX modes. You patch each
mode as its own fixture on the console.

| Mode | Channels | Patch one per | Does |
|---|---|---|---|
| Layer | 64 | layer | Everything about one layer: intensity, media, play mode, position, colour, effects, crop, audio |
| Master | 8 | machine | Master intensity, freeze or blackout, a global test pattern, master speed |
| Output | 8 | output | Output intensity, blackout or freeze, test pattern, blend on or raw, mapping preset and its fade |
| Keystone | 16 | output, optional | Moves the output's four corners on top of its alignment ([outputs-and-mapping.md](outputs-and-mapping.md#keystone-from-the-console)) |

Test patterns follow the Master and Output Intensity and Blackout like the
picture, so a Grand Master or DBO takes them down too: keep the Dimmer up to
focus.

Output channel 6, **Mapping preset**, switches the output between the
alignments stored on it: 0 is the mapping as edited, 1 to 255 the output's
preset with that number; a number the output does not have keeps the edited
mapping (see [outputs-and-mapping.md](outputs-and-mapping.md#mapping-presets)).
Output channel 7, **Mapping fade**, is how long the output glides from one
preset to the next when channel 6 changes: 0 cuts, 1 to 255 is 0.1 to 25.5 s,
as Layer Dissolve. Value ÷ 10 = seconds (50 = 5 s). Fanous reads channel 7 at
the moment channel 6 changes. Changing channel 7 during a glide does nothing to
that glide. If your console fades channel 7 along with the cue, make it snap,
or set it in an earlier cue. Output channel 8 is reserved.

16-bit values (intensity, speed, position, in and out points and others) are
coarse/fine pairs on adjacent channels, coarse first. Layer channel 51 is Sync
(see [multi-server.md](multi-server.md)); 52 to 64 are reserved. Every channel,
default and value band is in
[channel-map.md](../channel-map.md); the OSC key of each parameter is in the
same table.

A new install has 8 layers. The Patch screen has **Add layer** and **Remove
last layer** and shows "N of M layers" where M is the limit the engine reports.
It also has **Add output**; select an output's fixture to **Remove output**.
Each output has its own Output fixture, patched when the output is added and
unpatched when it is removed.

**Add layer** continues the layers' block. While every patched layer sits on
its place counted from one start (Layer n at the start + (n − 1) × 64, moved to
address 1 of the next universe where a universe is full), the new layer goes on
its place: with Layers 1 to 8 at A 0.0.4 from address 1, Layer 9 goes to
A 0.0.5 at 1. When the layers are patched by hand off such a block, it goes
right after the layer before it, or at its standard address (below) when that
one is unpatched. When those 64 channels are taken, as by the Master with the
standard patch of 8 layers, the new layer stays unpatched until you give it an
address. A layer above the layer count or above 32 cannot get an address.

## The standard patch

A fresh project is patched like this:

- Layer n goes on Art-Net universe `(n-1) / 8` (whole number division) at
  address `(n-1) % 8 * 64 + 1`. Eight layers fill one universe exactly.
- Master goes on the next universe after the layers, at address 1.
- Output n follows the Master on the Master's universe, at `Master + 8 × n`
  (9, 17, 25, 33 … with the Master at 1). It is patched when the output is
  added (Patch or Outputs & Mapping screen) and only when those 8 channels are
  free; otherwise it stays unpatched until you give it an address. A new
  project has no Output fixtures until an output is added. Console control
  covers outputs 1 to 8: output 9 and up has no Output fixture.

With 8 layers and four outputs:

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
the fixture file. On a wide screen the left column has Who controls, the
fixture table and Selected fixture, the right column Universes and the DMX
monitor; on a narrow one (an iPad upright) they stack in that order.

- **Who controls** (programmer): the project's source policy, with a line
  that explains the current choice (see [Sources and merging](#sources-and-merging)).
- **Fixture table**: Fixture, Type (with footprint), Universe, Address,
  Footprint, Status. Status says "ok", "unpatched · no console control",
  "collides with Layer 2 · 65-128" or "exceeds universe". There is one Output
  row (and its Keystone row) per output on the Outputs & Mapping screen, no
  more and no fewer; removing an output unpatches both.
  Projects from before 30 October 2026 had Output 1 to 4 patched whether those
  outputs existed or not; opening such a project unpatches the ones without an
  output.
- **Selected fixture** (programmer): choose the Universe (A 0.0.0 to 0.0.3 and
  S 1 to S 4, plus every universe that has been heard or has settings), set the Address with the
  stepper (Shift steps by 10; **0 means unpatched**), or press **Unpatch**.
  For an output it also says which display shows it, links to Outputs &
  Mapping, and has **Remove output** (the output with its mapping; Undo brings
  it back).
- **Universes**: one row per universe that
  - a fixture is patched to,
  - a console is sending to now (packets, or quiet for no longer than the
    universe's Signal lost after time), or
  - has settings in the project.

  A row shows the universe, the fixtures on it ("Layers 1–8, Master"), the
  health pill, and its protocol, interface and Hold on signal loss. Without a
  fixture it says:
  - "heard, nothing patched" (yellow): a console sends to a universe no
    fixture listens on; often the console's universe is one off. The row goes
    away once that universe has been quiet for its Signal lost after time,
    unless it has settings or is open in the panel or shown in the DMX monitor
    (then it stays, with a yellow "quiet" pill, until you pick another one);
  - "feeds A 0.0.0": the other protocol's universe that a patched universe
    receives (its protocol is sACN or Art-Net + sACN, see
    [Universe settings](#universe-settings));
  - "not used": the universe has settings but no fixture and no console; the
    settings stay.

  A universe without fixtures never shows a red pill: once it is quiet for
  longer than its Signal lost after time, the pill says "quiet" in yellow (the
  status bar's yellow "silent" means nothing was received yet). Tap a row to open its settings (see
  [Universe settings](#universe-settings)); the DMX monitor switches to it.
- **DMX monitor**: 512 cells for one universe, coloured per fixture, red where
  fixtures collide, with live values. Click a cell to pin it: you see the
  fixture, the channel inside it, the parameter, the raw value and what it means
  ("17 → Loop rev"). The buttons above the grid switch universe.

The pill for a universe is green while packets arrive. It is yellow when
nothing has been received yet or for up to the universe's Signal lost after time
(2.5 s by default) of silence, and red when a patched universe has been silent longer.
What the fixtures do then is the universe's **Hold on signal loss** setting; by
default they **hold their last values**. An unpatched fixture holds nothing
from the console: unpatching a layer, Master or output (or moving it to another
universe) drops the console's values.

**Unpatched means no console address, not no control.** Every layer up to the
layer count (at most 32), the Master and each output's Output and Keystone
fixture exist whether they are patched or not, and follow the
[source policy](#sources-and-merging): with **Console only** an unpatched
fixture stays at its defaults (a layer black with no file, the Master at full,
an output normal, a Keystone centred); with the other policies the UI, cues,
OSC and MIDI control it. A show without a console therefore does not need a
patch at all. The Status column's "no console control" means just that.

## Universe settings

Every universe has its own receive settings. Tap the universe in the
**Universes** panel of the Patch screen to open them (programmer; locked while
the show lock is on). The settings belong to the universe, not to the fixtures
on it: a change applies to every fixture on that universe. Changes apply at once,
without dropping the other universes, and are part of the project and of
undo. A universe you never changed runs the defaults, which are how Fanous
received before these settings existed.

| Setting | Choices | Default | Does |
|---|---|---|---|
| Protocol | Art-Net, sACN, Art-Net + sACN | the universe's own (A = Art-Net, S = sACN) | Which protocol feeds the universe. The other protocol arrives on the paired universe. |
| sACN universe / Art-Net universe | a universe of the other protocol, e.g. `S 1` or `A 0.0.0` | S n+1 for A port-address n (A 0.0.0 ↔ S 1) | Shown when the protocol is not the universe's own. Set it when your console numbers the other way. |
| Interface | All interfaces, an interface (`en0`) or one of its addresses | All interfaces | All interfaces: every sender is accepted and sACN multicast is joined on every interface that can multicast. A named interface: only senders in its network are accepted and sACN multicast is joined on it alone. |
| Hold on signal loss | Hold last values, Go to zero, UI and cues take over | Hold last values | What the fixtures do when the universe goes silent. "UI and cues take over" resolves them as Who controls *Fanous only* until packets return. Changing it while the universe is already lost applies at once. |
| Signal lost after (s) | 1 to 60 | 2.5 | Silence after which the universe counts as lost (red pill, Hold on signal loss applies). At least 1 s: consoles that send only on change repeat every 0.8 to 1 s. |
| sACN priority | Highest wins, Merge equal (HTP) | Highest wins | Sources at the same, highest priority: the latest packet wins, or they merge with the highest value per channel. |

There are two timeouts. **Signal lost after** is this universe's: when it
counts as lost and Hold on signal loss applies. The **sACN source timeout** is
fixed at 2.5 s (E1.31): a console silent that long drops out of the priority
merge, so a backup console at a lower priority takes over after 2.5 s whatever
Signal lost after says. With a Signal lost after time above 2.5 s and no backup,
the universe has no source between 2.5 s and that time; the fixtures keep their
values until it is lost.

**Go to zero** sets every channel of the universe's fixtures to 0 as a new DMX
change, except a Keystone fixture's: it goes to its default, 32768 on every
channel, so a lost universe centres the keystone instead of moving the picture. Under Who controls *Console and Fanous* (latest change or highest value wins) that
change is the latest, so the zeros also win over UI and cue values set before
the loss; the UI or a cue has to set a value again after it.

With Art-Net + sACN, Art-Net competes as an sACN source at priority 100: a
higher sACN priority wins, a lower one loses, equal priorities follow the sACN
priority setting. Either protocol drops out after the 2.5 s source timeout.

An interface that is not on this Mac (an adapter that is unplugged, or a
project from another machine) is accepted, but the universe receives nothing
until it is there: the Patch screen says so under the settings and the show
readiness check warns ("Universe interfaces usable"). The check also warns when
the interface is there but its sACN multicast could not be joined. A replugged
adapter is joined again within 5 s.

## GDTF

**Patch › Export GDTF** writes `Fanous.gdtf` (GDTF 1.2). It contains the
fixture type "Fanous" with the Layer, Master, Output and Keystone modes, channel
functions with their physical ranges, a channel set for every band (play modes,
blend modes, effects, test patterns), the 16-bit links and the default values.
If you imported `Fanous.gdtf` before the Keystone mode or the Mapping preset and
Mapping fade channels existed, export and import it again: the fixture type keeps
its ID, so a console may keep the older file until you replace it.
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
With Interface "All interfaces" (the default) sACN multicast is joined on every
network interface that is up and can multicast (Ethernet, Wi-Fi, a USB adapter
without a gateway), not only on the one with the default route; with a named
Interface only on that one. Without any sACN universe in the patch, universe 1
is joined so the multicast path is ready. To receive an Art-Net universe from
an sACN console without repatching, set its Protocol to sACN (see
[Universe settings](#universe-settings)).

**Sharing port 5568.** Fanous opens the sACN port so that other receivers can
open it too (SO_REUSEPORT): sACNView or a second Fanous on the same Mac keep
receiving multicast side by side. Unicast sACN to the Mac goes to only one of
them, the one that opened the port last: while sACNView is receiving, Fanous
gets no unicast. If a program holds the port exclusively (for example
`nc -u -l 5568`), Fanous starts without sACN, logs it, and the show readiness
check warns "sACN port 5568 available"; quit that program and restart the
engine. `sudo lsof -nP -iUDP:5568` shows who holds the port.

### sACN manual test (sACNView)

The automated tests check multicast memberships in the kernel but cannot
receive real multicast (that needs the Local Network permission). Run this
with sACNView, or another sACN source, on a second machine, a console on a real
network, and the Show screen's readiness list open. Patch Layer 1 on `S 1`.

- [ ] **Default route.** Mac and sACNView on the default-route network (Wi-Fi or
      Ethernet with gateway), Interface "All interfaces": S 1 multicast turns the
      pill green and moves Layer 1.
- [ ] **Named NIC.** A second NIC (USB Ethernet) to the console network, Interface
      set to that NIC (`en7`): S 1 arrives; sACN sent on the other network is
      ignored.
- [ ] **Any with NIC.** Same NIC, no gateway on it, Interface back to "All
      interfaces": S 1 still arrives (joined on every multicast interface).
- [ ] **Unplug and replug.** Unplug the USB NIC: readiness warns "Universe
      interfaces usable" for a named Interface; the pill goes red once
      Signal lost after has passed. Replug: packets return within 5 s without touching anything.
- [ ] **Unicast.** sACNView unicast to the Mac's address on S 1: received, with
      the sender shown in the pill.
- [ ] **sACNView receiving on the Mac.** Open a sACNView receive window for S 1 on
      the same Mac: both show multicast; note that unicast now goes to sACNView
      only.
- [ ] **Port held.** Quit Fanous, run `nc -u -l 5568`, start the engine: it runs,
      the log says "sACN port in use", readiness warns "sACN port 5568
      available"; Art-Net still works. Quit nc, Engine › Restart Engine: sACN is
      back.
- [ ] **Load.** 32 universes at full rate for 10 minutes: no silent universe,
      DMX p99 in the status bar stays where it is with Art-Net.
- [ ] **Priority takeover.** Two sources on S 1, priority 150 and 100, different
      levels: 150 wins; stop it: the 100 source takes over after 2.5 s, also
      with Signal lost after set to 10 s.

## Sources and merging

Send each universe from one console. Within Art-Net the latest packet for a
port-address wins. Within sACN the highest priority wins, equal priorities go to
the most recent packet (or merge per channel, if the universe says so), and
per-address priority is not supported.

**Who controls** (the project's source policy; a card on the Patch screen,
programmer) decides how DMX combines with values from the UI, cues, OSC and
MIDI:

| Choice | Source badge | Does | Stored as |
|---|---|---|---|
| **Console only** (the default) | Console | Fanous follows the console. A fixture without an address stays at its defaults; cues and OSC are recorded but do nothing. | `dmx` |
| **Fanous only (UI, cues, OSC, MIDI)** | Fanous | The console is shown but ignored. | `internal` |
| **Console and Fanous, latest change wins** | Both · latest | Per parameter, the latest change wins (LTP in console terms). | `ltp` |
| **Console and Fanous, highest value wins** | Both · highest | Intensity and other numbers take the highest value; folder, file and modes the latest change (HTP in console terms). | `htp` |

The Layers screen shows the short name in each layer's Source badge, and the
Show control screen warns while it is Console only. Pick Console and Fanous,
latest change wins for a show that mixes console control with cues.

With either Console and Fanous choice the console takes part only once its DMX
has arrived for that fixture: on a fixture without an address, or one whose
console was never heard, the UI and cues are not beaten by a default (a Master
without an address can be dimmed from the UI with highest value wins). A console
that held a value and then went silent with **Hold last values** still competes
with that held value.

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
