# Dependencies and license compatibility

Every dependency of the server, the vendored C/ObjC code, the web build and
the protocols with license conditions. Compatibility is with GPL-3.0-only.
Versions verified 2026-10-22 (web dev tools, vendored code, fonts and swift-collections re-checked 2026-11-17); "pinned" means an exact version/commit in the
manifest or lockfile. Adding a row is mandatory for any new dependency (reviewed by hand;
no CI job checks it).

## Server (Swift packages)

| Package | Version | License | GPLv3-compatible | Use | Pinned |
|---|---|---|---|---|---|
| apple/swift-log | 1.17.2 (2026-11-17) | Apache-2.0 | yes | logging facade (os_log + file handlers) | exact |
| apple/swift-collections | 1.7.6 (2026-11-10) | Apache-2.0 | yes | only if a concrete need appears (Deque/Heap); not added by default | exact |
| apple/swift-atomics | — | Apache-2.0 | yes | **not used**: minimum macOS is 15 (ADR-0020), the stdlib `Synchronization` module replaces it | — |

## Vendored C / Objective-C (SPM targets)

| Code | Version / commit | License | GPLv3-compatible | Use | Notes |
|---|---|---|---|---|---|
| Vidvox/hap (`hap.c`, `hap.h`) | master @ `d847f6b` (2024-07-25), vendored in `Sources/CHap` | BSD-2-Clause | yes | HAP encode/decode (chunk callback for parallel decode) | no commits since 2024-07; we own fixes: local bounds checks (B265, listed in `VENDORED.md`), fuzz-tested in `HAPFrameBoundsTests` |
| google/snappy | 1.3.1 = `9c28114` (2026-09-18), vendored in `Sources/CSnappy` | BSD-3-Clause (text match; COPYING unlabeled) | yes | HAP frame (de)compression | C++17 target; `snappy-stubs-public.h` generated for macOS; upstream HEAD `9466064` (2026-10-23) is two commits past the 1.3.1 tag and not vendored (B248) |
| Syphon/Syphon-Framework | main @ `f476167` (2026-09-21); last tagged release "5" is from 2019 | Syphon Framework License (BSD-3-Clause style) | yes | Syphon Metal server (output) and client (input), vendored in `Sources/Syphon` | pin to commit, not tag; Metal path only, shaders compiled at runtime (`Sources/Syphon/VENDORED.md`) |

Not used: Vidvox/hap-in-avfoundation (multi-license file with YCoCg/EA
sections; our own sample-cursor + hap.c path makes it unnecessary).

## Apple frameworks

Metal, MetalKit (optional), AVFoundation, VideoToolbox, CoreVideo,
CoreMedia, CoreAudio/AVFAudio, CoreMIDI, Network, Security, ServiceManagement,
IOKit, ImageIO, CoreGraphics, AppKit, WebKit. System frameworks are the
platform; the GPL's system-library exception covers linking against them.

## Web (build-time; only the Svelte runtime ships in the bundle)

| Package | Version | License | GPLv3-compatible | Use |
|---|---|---|---|---|
| svelte | 5.59.1 (2026-11-20) | MIT | yes | UI framework (runtime ships) |
| @sveltejs/vite-plugin-svelte | 7.3.2 (2026-11-23) | MIT | yes | build |
| vite | 8.3.8 (2026-11-11) | MIT | yes | build/dev server |
| vitest | 5.1.2 (2026-11-25) | MIT | yes | tests |
| svelte-check | 4.7.8 (2026-11-01) | MIT | yes | type checking and Svelte diagnostics (`npm run check`) |
| @playwright/test | 1.65.1 (2026-11-13) | Apache-2.0 | yes | end-to-end tests (CI) |
| typescript | 6.0.3 (2026-04-16) | Apache-2.0 | yes | type checking (svelte-check) |

Rejected alternative: preact 11.0.1 + @preact/signals 2.11.3 (MIT) — see
ADR-0012.

## Fonts (shipped with the web UI)

| Font | Version / source | License | GPLv3-compatible | Use |
|---|---|---|---|---|
| Atkinson Hyperlegible Next | font version 2.001 (`head`/`name` tables; 2.66 is the WOFF2 header of the file), `fonts/webfonts/AtkinsonHyperlegibleNext[wght].woff2` of `googlefonts/atkinson-hyperlegible-next`, byte-identical to its HEAD `7925f50` (2025-02-21) on 2026-11-17 (fetched 2026-10-25) | SIL OFL 1.1 (`web/public/fonts/OFL-Next.txt`; "Atkinson" and "Hyperlegible" are reserved names) | yes (font files ship unmodified next to the code) | UI text |
| Atkinson Hyperlegible Mono | font version 2.001 (`head`/`name` tables; 2.66 is the WOFF2 header of the file), `fonts/webfonts/AtkinsonHyperlegibleMono[wght].woff2` of `googlefonts/atkinson-hyperlegible-next-mono`, byte-identical to its HEAD `154d503` (2024-11-20) on 2026-11-17 (fetched 2026-10-25) | SIL OFL 1.1 (`web/public/fonts/OFL-Mono.txt`) | yes | values, addresses, timecode |

## Protocols and specifications with conditions

| Protocol | Spec | Conditions |
|---|---|---|
| Art-Net 4 | Artistic Licence, protocol version 14 (document revision to be cited from the PDF at Phase 1) | royalty-free subject to conditions: credit "Art-Net™ Designed by and Copyright Artistic Licence Engineering Ltd" in the product; OEM code registration (free) for `ArtPollReply` — 0xFFFF until registered |
| sACN | ANSI E1.31-2025 (supersedes E1.31-2018), ESTA TSP, free download under EULA | none for implementers |
| CITP / MSEX | CITP spec (MSEX 1.0–1.2); canonical host unclear in 2026, spec mirrored by Capture/third parties | "open for anyone, free of charge" (Capture) |
| GDTF | GDTF 1.2 = DIN SPEC 15800:2022; `mvrdevelopment/spec` on GitHub | open specification |
| OSC 1.0 | opensoundcontrol.org | open |
| LTC (SMPTE 12M), MTC (MIDI 1.0 spec) | standards | implementation from the public descriptions; no code copied |

## Explicitly excluded from the server

FFmpeg (any form), Vapor/Hummingbird/any web framework, game engines,
creative-coding frameworks, NDI SDK, Blackmagic DeckLink SDK (plugins only,
ADR-0016), NotchLC SDK (proprietary; no public spec — verified 2026-10-22).
