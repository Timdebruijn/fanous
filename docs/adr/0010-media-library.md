# ADR-0010: Numeric-prefix library, number-based references, playable codecs only

Status: Proposed · 2026-10-22

## Context
Catalyst-style folder/file addressing from DMX; a future backup machine must
run the same project against its own copy of the media; network volumes are
too slow and too variable for show playback.

## Decision
- One library root per machine on a local volume; folders and files are
  addressed by the leading 1–3 digits of their names (1–255; folder 0 is
  reserved for live inputs/generators). Duplicates and out-of-range numbers
  are invalid and never addressable.
- Projects reference media by `(folder, file)` only; paths are resolved per
  machine.
- Only ProRes/HAP in `.mov` and stills are playable; everything else is
  indexed as "needs transcode" and converted by the ingest queue, originals
  kept in `_originals/`.
- Index + metadata/thumbnail cache maintained by the engine with FSEvents.

## Consequences
+ Deterministic console addressing; projects are portable between machines.
− Users must number their files; the Media screen helps (renumber, conflict
  detection) and ingest assigns numbers.
