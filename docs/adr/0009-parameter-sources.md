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
