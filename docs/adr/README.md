# Architecture Decision Records

One file per decision, numbered, never deleted: a reversed decision gets a new
ADR that supersedes the old one. Format: Status · Context · Decision ·
Consequences. Status is one of Proposed, Accepted, Superseded by ADR-n.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-engine-launchagent-single-bundle.md) | Engine as a LaunchAgent inside one app bundle | Proposed |
| [0002](0002-threading-model.md) | Threading model: dedicated threads, lock-free hand-off, no Swift Concurrency in hot paths | Proposed |
| [0003](0003-package-layout.md) | One SwiftPM package; Core has no GPU/AV dependencies; vendored C/ObjC targets | Proposed |
| [0004](0004-demux-and-decode.md) | Demux with AVSampleCursor, decode with VTDecompressionSession and hap.c | Proposed |
| [0005](0005-zero-copy-textures.md) | Zero-copy textures and in-shader colour conversion | Proposed |
| [0006](0006-render-clock.md) | CAMetalDisplayLink per display, compositor on the master display | Proposed |
| [0007](0007-canvas-precision-and-colour.md) | rgba16Float canvases, gamma-encoded blending, dithered output | Proposed |
| [0008](0008-dmx-fixture-model.md) | One fixture type, three modes, fixed 64/8/8 footprints | Proposed |
| [0009](0009-parameter-sources.md) | Parameter sources and per-layer merge policy | Proposed |
| [0010](0010-media-library.md) | Numeric-prefix library, number-based references, playable codecs only | Proposed |
| [0011](0011-output-pass.md) | Single output pass: displacement-field warp, blend map, slices, masks | Proposed |
| [0012](0012-frontend-svelte.md) | Frontend: Svelte 5 + Vite + TypeScript | Proposed |
| [0013](0013-state-sync-protocol.md) | Snapshot + revisioned JSON patches, commands with acks, global undo | Proposed |
| [0014](0014-preview-streaming.md) | VideoToolbox H.264 over WebSocket to WebCodecs, JPEG fallback | Proposed |
| [0015](0015-security-tls-roles.md) | TLS everywhere with a self-generated certificate; role passwords, no accounts | Proposed |
| [0016](0016-plugin-boundary.md) | Plugin boundary: C ABI, dynamically loaded (design only in v1) | Proposed |
| [0017](0017-licensing-and-cla.md) | GPL-3.0-only with §7 terms, SPDX headers, CLA via cla-assistant | Proposed |
| [0018](0018-dependencies.md) | Dependency and vendoring policy | Proposed |
| [0019](0019-audio.md) | Audio: one output device, layer clock is master | Proposed |
| [0020](0020-minimum-macos.md) | Minimum macOS version 15 | Proposed (needs owner decision) |
