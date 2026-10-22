# ADR-0008: One fixture type, three modes, fixed 64/8/8 footprints

Status: Proposed · 2026-10-22

## Context
Console programmers patch media servers as fixtures; footprints must never
change once show files exist. The owner wants an own channel map (not
Catalyst's), layers, outputs and the server itself as fixtures, 16-bit
precision, and one mode in v1.

## Decision
- GDTF fixture type "Lanthorn" with DMX modes **Layer (64 ch)**, **Master
  (8 ch)**, **Output (8 ch)**; a Serial mode is reserved for later.
- 16-bit parameters as coarse/fine pairs on adjacent channels. Layer
  channels 51–64 are reserved and ignored so additions never change the
  footprint; 8 layers fill a universe exactly.
- The channel map is generated from `ParameterSpec` (single source of
  truth) into DMX tables, GDTF, OSC, UI labels and `docs/channel-map.md`.
  A test locks the footprints.
- Band widths of 16 values for enumerated channels, defaults as declared in
  the GDTF (new layer: black, empty, 100 % speed).

## Consequences
+ One profile for consoles; footprints are stable forever.
− Reserved channels cost address space (14 per layer); accepted.
− Catalyst muscle memory does not transfer; documented in the user guide.
