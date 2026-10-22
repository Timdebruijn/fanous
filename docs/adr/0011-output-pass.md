# ADR-0011: Single output pass: displacement-field warp, blend map, slices, masks

Status: Accepted · 2026-10-22

## Context
The brief requires all output/mapping configuration to be applied on the GPU
in the final pass with no extra copies. Warps, blends and masks are edited
rarely but rendered every frame.

## Decision
- Edit-time compilation on Control: blend settings → `rg16Float` blend map
  (factor, lift) per output; warp control points → `rg32Float` displacement
  field per output; mask paths → `r8` SDF-feathered mask per slice; slice
  destinations → tessellated vertex buffers.
- Render-time: one render pass per display; per slice the vertex shader
  applies the displacement field, the fragment shader samples the canvas,
  mask, blend map, intensities, test pattern and dithers to the drawable.
- Outputs are regions of a display, so one display can carry several
  outputs for splitter setups.

## Consequences
+ Render cost is independent of warp/mask complexity; no intermediate
  textures.
− Displacement-field warps need enough tessellation (64×64 minimum per
  slice); corner-pin exactness is verified by golden images.
