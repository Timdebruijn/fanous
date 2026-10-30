# ADR-0008: One fixture type, three modes, fixed 64/8/8 footprints

Status: Accepted · 2026-10-22

## Context
Console programmers patch media servers as fixtures; footprints must never
change once show files exist. The owner wants an own channel map (not
Catalyst's), layers, outputs and the server itself as fixtures, 16-bit
precision, and one mode in v1.

## Decision
- GDTF fixture type "Fanous" with DMX modes **Layer (64 ch)**, **Master
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

## Amendment 2026-10-30 (B120, DESIGN §6.6): a fixture exists without a patch

Designed, not built yet. The Keystone mode (16 ch, per output, M2.3) is the
fourth mode; the three footprints above are unchanged.

- Every fixture that exists has a resolver: Layer 1…`layerCount`, the Master,
  and each output's Output and Keystone. The patch is only its console
  address. An unpatched fixture follows the source policy: at its defaults
  under Console only, controlled by the UI, cues, OSC and MIDI under the other
  policies. Before this, an unpatched fixture had no resolver and nothing
  could control it.
- Each mode says what it is patched per (`layer`, `server`, `output`) and
  whether it is optional (Keystone). The channel map serves that list
  (`fixtures` in `/api/channel-map.json`) and the Patch screen groups by it,
  so a new mode on an existing `per` needs no UI code.

+ A show without a console no longer has to patch its layers; "Unpatch" means
  only "no console address".
− The resolver set follows the layer count and the outputs as well as the
  patch, so `DMXStore` takes both.
