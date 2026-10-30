# ADR-0009: Parameter sources and per-layer merge policy

Status: Accepted · 2026-10-22

## Context
Values can come from DMX, cues, OSC and the UI. Shows without a console
need cues to drive layers; shows with a console must never be surprised by
an internal source.

## Decision
- Per layer (and master/outputs) a **source policy**: `dmx` (default),
  `internal`, `ltp`, `htp` (HTP for scalar parameters only; enumerated
  parameters fall back to LTP).
- A single resolver produces the render snapshot and records *which source*
  set each value; the UI shows it next to the value.
- UI overrides are explicit, programmer-only and expire after 10 minutes.
- One source protocol per universe (Art-Net or sACN); sACN priority
  honoured within sACN. Loss of signal holds last values (configurable).

## Consequences
+ Predictable: a `dmx` layer cannot be moved by a stray OSC message.
+ Mixed shows (console + cues) are possible per layer without global modes.
− HTP across sources only makes sense for intensity-like parameters;
  documented.

## Amendment 2026-10-30 (B120, DESIGN §6.6): a fixture exists without a patch

Designed, not built yet.

- Every fixture that exists has a resolver: Layer 1…`layerCount`, the Master,
  and each output's Output and Keystone. The patch is only its console
  address. An unpatched fixture follows the source policy: at its defaults
  under `dmx`, controlled by the UI, cues, OSC and MIDI under the other
  policies. Before this, an unpatched fixture had no resolver and nothing
  could control it.
- Unpatching resets the DMX side of the resolver to the defaults and keeps the
  internal values, so an unpatched fixture never holds the console's last
  look.
- In `ltp` and `htp` the DMX side takes part only once DMX was received, so a
  high default (Master intensity) does not beat a UI value on a fixture no
  console reaches.

+ A show without a console no longer has to patch its layers; "Unpatch" means
  only "no console address".
− The resolver set follows the layer count and the outputs as well as the
  patch, so `DMXStore` takes both.
