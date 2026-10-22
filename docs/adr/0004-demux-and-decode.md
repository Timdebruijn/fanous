# ADR-0004: Demux with AVSampleCursor, decode with VTDecompressionSession and hap.c

Status: Proposed · 2026-10-22

## Context
`AVAssetReader` is forward-only and must be re-created to seek: reverse
play, bounce, scrub and timecode chase would all re-create readers
constantly. ProRes and HAP are all-intra, so any sample can be decoded on
its own. The hardware ProRes decoder is reachable through VideoToolbox; HAP
is not an Apple codec.

## Decision
- Demux every movie with `AVAssetTrack.makeSampleCursor` +
  `AVSampleBufferGenerator` (random access to compressed samples).
- ProRes: one `VTDecompressionSession` per layer, hardware required,
  destination attributes requesting Metal-compatible IOSurface buffers in the
  decoder's native format (`v216` / `y416`, verified at runtime).
- HAP: `HapDecode` from the vendored reference implementation with the
  chunk callback feeding a shared chunk pool (Snappy on CPU), writing DXT
  bytes into pooled shared-storage `MTLBuffer`s.
- Sessions and cursors are re-created only on file change; frame rings are
  filled ahead in play direction.
- Long-GOP codecs (H.264/HEVC) are deliberately not playable; ingest
  converts them.

## Consequences
+ Reverse, bounce, scrub, chase and random seeks are all the same cheap
  operation.
− `AVSampleBufferGenerator` with HAP's custom fourcc is a Phase 2 spike
  (R4); fallback is a small all-intra QuickTime demuxer.
