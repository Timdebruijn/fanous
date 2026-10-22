# ADR-0019: Audio: one output device, layer clock is master

Status: Accepted · 2026-10-22

## Context
Audio playback per layer is in v1 (owner's decision). Multiple output
devices per engine would need multiple audio graphs or aggregate devices;
varispeed audio is a rabbit hole.

## Decision
- One `AVAudioEngine` with one `AVAudioSourceNode` on one output device
  (machine setting; aggregate devices allowed). Per-layer volume, pan and
  output-pair selection; real-time mix in the render callback from
  per-layer PCM rings (48 kHz float, 250 ms).
- The layer's video clock is master; audio follows with drift correction
  (±20 ms window, ≤ 2 ms correction per callback). Audio plays only forward
  at 100 % speed; otherwise muted. Dissolves crossfade audio.
- Audio tracks are LPCM in the library (ingest transcodes), decoded via a
  second sample cursor + `AudioConverter` on the layer's decode thread.
- LTC input uses a separate input graph (`AVAudioSinkNode`).

## Consequences
+ RT-safe, simple, measurable (underruns, drift corrections in metrics).
− No varispeed/pitch, no per-layer devices in v1; both are v1.x candidates
  and do not change the ring design.
