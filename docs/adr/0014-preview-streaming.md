# ADR-0014: VideoToolbox H.264 over WebSocket to WebCodecs, JPEG fallback

Status: Proposed · 2026-10-22

## Context
Clients need a live view without full frames crossing the network. WebCodecs
`VideoDecoder` is available only in secure contexts; Safari/iPadOS report
full WebCodecs support from version 26 and partial from 16.4 (verified
2026-10-22), so a real decode test is needed.

## Decision
- The compositor renders the chosen target (canvas/output/layer) into a
  pooled, Metal-compatible `CVPixelBuffer` at preview size; a
  `VTCompressionSession` (H.264, real-time, no B-frames) encodes on its own
  queue; access units travel as binary WebSocket frames with the `avcC`
  record; the browser decodes with WebCodecs into a canvas.
- One encoder per distinct (target, size), fan-out to subscribers; at most
  4 video-preview clients on tiers 1–2.
- A connect-time decode test selects the fallback: JPEG frames at 5 fps.
- Layer thumbnails and CITP streaming frames reuse one downscale + JPEG path.

## Consequences
+ Hardware encode keeps CPU free; latency ~2 frames + network.
− Requires HTTPS for remote clients (see ADR-0015) and WebCodecs-capable
  browsers for the smooth path.
