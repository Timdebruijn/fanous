# ADR-0007: rgba16Float canvases, gamma-encoded blending, dithered output

Status: Proposed · 2026-10-22

## Context
Edge-blend curves and black-lift need more than 8 bits to avoid banding;
ProRes delivers 10/12-bit content. VJ/media-server users expect Add/Screen
to look like Catalyst/Resolume, which blend in display-referred
(gamma-encoded) space, not linear light.

## Decision
- Canvases are `rgba16Float`; "performance" tier mode can switch to
  `rgba8Unorm` (visible in System settings, off by default).
- Blending and effects operate on display-referred (sRGB/Rec.709-encoded)
  values. No linearization in v1. A per-canvas colour-space tag exists in
  the project schema so a later HDR/P3 mode is a transform in the output
  pass, not a rewrite.
- Output drawables are 8-bit with blue-noise dithering in the output pass;
  10-bit drawables are a v1.x option.

## Consequences
+ Blend zones and black lift are smooth; content keeps its precision until
  the last pass.
− 2× canvas bandwidth versus 8-bit; measured in the benchmark, with the
  8-bit mode as the escape hatch.
