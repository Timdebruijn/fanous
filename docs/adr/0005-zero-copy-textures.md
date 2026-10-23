# ADR-0005: Zero-copy textures and in-shader colour conversion

Status: Accepted · 2026-10-22

## Context
Every copy of a 4K frame costs bandwidth the compositor needs. Apple Silicon
has unified memory and IOSurface sharing; the hardware ProRes decoder emits
packed 16-bit YCbCr; HAP frames are GPU block-compressed formats.

## Decision
- ProRes frames stay in their IOSurface. The layer samples an `MTLTexture`
  created from the IOSurface (`makeTexture(descriptor:iosurface:plane:)`):
  `rgba16Unorm` at half width for `v216`, full width for `y416`. YCbCr→RGB
  with the track's matrix/range happens in the layer fragment shader.
- HAP frames are `bc1/bc3/bc4` (later `bc7`) textures; HAP Q's scaled YCoCg
  and HAP Q Alpha's second texture are handled in the same shader.
- No `VTPixelTransferSession`, no CPU readback, no intermediate RGBA
  textures anywhere between decoder and canvas.
- Blend modes use programmable blending (`[[color(0)]]` input), so
  compositing is a single pass per canvas.

## Consequences
+ Decode→canvas is one texture read per layer per frame.
− The layer shader is an uber-shader with function constants; pipeline
  variants are compiled on Control and cached (first use of a new effect
  combination is not instantaneous — the layer renders without the effect
  for one or two frames).
− If a future decoder emits an unexpected format, the fallback is a transfer
  session on the decode thread, logged and visible in metrics.

## Amendment 2026-10-23 (Phase 2 spike)

On macOS 27 the hardware ProRes decoder's native output is Apple's
lossless-compressed bi-planar 16-bit YCbCr (`&sv2` for 4:2:2, `&sv4` for
4:4:4), not `v216`/`y416`. `CVMetalTextureCache` wraps those planes as
`r16Unorm` + `rg16Unorm` textures without a copy, so the zero-copy claim holds
and bandwidth is lower than with packed formats. `&sv4` carries no alpha, so
ProRes 4444 sessions request `y416` (≈0.8 ms extra per 1080p frame on the
decode thread). HAP frames reach the GPU through `MTLTexture.replace` into
pooled textures (0.4–0.8 ms per 1080p frame including Snappy); a blit from a
shared buffer remains the alternative if that copy ever shows up in profiles.
