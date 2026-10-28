# ADR-0021: Multi-server sync with a Sync channel and a broadcast clock packet

Status: Proposed · 2026-10-28 (design only, B60)

## Context
A show can need two Macs for one picture: each drives one projector with
its own slice, blend and warp, and the layers that carry the same content
must play frame-locked. The owner's brief (B60) asked for a master that
publishes its clock over the LAN like Art-Net, with every machine on the
same console. Precedents: Catalyst had a play mode "Synchronize to master
unit"; High End's Axon/DL.3 had "Sync Mode" and "Sync To" channels per layer
(a slave points at the master's fixture id and a master layer), synced over
Ethernet and dependent on all-I-frame content.

A first draft of DESIGN.md §23 mirrored a whole machine over the WSS state
connection (a follower rendering the master's resolved parameters, one
project holding every machine's outputs, a `follower` role, promote and
swap). The owner's review rejected it as the base: both machines already
hear the same Art-Net/sACN and are set up alike, so only the clocks need
syncing, and the sync should be a console parameter, not a machine mode.

## Decision
- **Layer channel 51, "Sync"**: off, master group 1–8, slave group 1–8.
  A master layer publishes its clock under its group; a slave layer, on any
  machine and any layer number, sets its clock from that group's packet and
  keeps everything else of its own (media, intensity, geometry, effects,
  blend, warp). Groups replace Axon's fixture ids; machines need not know
  each other. Two masters in a group: the lowest install UUID wins.
- **One UDP packet per tick**, broadcast on the sync interface (port 8002,
  configurable; a unicast target for one-Mac tests), 22 B per master
  layer plus a 34 B header (738 B for 32 layers): media key, fps, position, direction, finished, rate. The
  compositor writes a triple-buffered slot; a sender thread sends it. The
  receiver is one `SO_REUSEPORT` socket feeding a per-group table read once
  per tick.
- **Set, never integrate**: a slave's position each tick is the packet's
  position plus its rate times the packet's local age, scaled by the fps
  ratio. No clock synchronisation between machines. A missing packet is
  freewheeled with the packet's rate; lost after the freewheel time (2 s);
  the next packet relocks.
- The mirror/backup design stays as "later" (DESIGN.md §23.6, OPEN-27).

## Consequences
+ The offset between master and slave is bounded (jitter plus one sampled
  tick) and does not grow; a retrigger is one all-intra frame of decode on
  the slave.
+ Nothing new to pair, discover or authenticate; it behaves like DMX on the
  same cable, and two layers on one machine can sync the same way.
+ Small: one parameter in Core, one packet codec, one sender, one receiver,
  one branch in `prepare`.
− One frame of display phase is the floor: Mac displays have no genlock, so
  the moment a frame reaches the glass can differ by up to one output period
  between machines. The frame content is the same frame.
− Broadcast UDP is unauthenticated on the LAN, like Art-Net; a show network
  is assumed. Packets from an unknown machine id in a group with a known
  master are ignored (lowest id wins), so a stray sender cannot take over a
  locked group silently; `live.sync.conflicts` names it.
− Anything that is not DMX (OSC to one IP, MIDI on one machine, cues fired
  in one UI) still reaches one machine only; the mirror design of §23.6
  is the answer when a show is driven that way.
