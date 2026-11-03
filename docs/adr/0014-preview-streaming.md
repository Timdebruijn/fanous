# ADR-0014: VideoToolbox H.264 over WebSocket to WebCodecs, JPEG fallback

Status: Accepted · 2026-10-22

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

## Amendment 2026-11-03: low-latency rate control measured, not taken
Apple's `VTCompressionProperties.h` lists two profiles: "live capture and
live broadcast" (`RealTime`, `ExpectedFrameRate`), which the preview encoder
follows, and "ultra-low-latency conferencing and cloud gaming"
(`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`). The second
was measured with the preview's settings (BGRA input, 30 fps paced, 240
frames, two rounds each, M1 Pro, macOS 27.2, load average 15–30 from other
work), encode latency from `VTCompressionSessionEncodeFrame` to its output
handler:

| Size | Current, p50 / p99 | Low-latency, p50 / p99 |
|---|---|---|
| 640×360 | 4.9 / 7.3 and 5.0 / 20.8 ms | 4.9 / 20.4 and 5.0 / 11.4 ms |
| 1280×720 | 10.2 / 18.2 and 10.2 / 12.3 ms | 9.8 / 10.4 and 11.0 / 15.0 ms |

No gain: the medians match and the tails move with the load. The mode also
selects a different encoder (`com.apple.videotoolbox.videoencoder.h264.rtvc`
instead of the hardware `ave.avc`; the session does not answer
`UsingHardwareAcceleratedVideoEncoder`), and it forces an infinite GOP and
High profile, while the preview relies on a key frame every second for
subscribers that join late and for recovery after a dropped frame. Not
taken; the encoder keeps the live-broadcast profile.
