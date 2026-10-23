# Third-party notices

Lanthorn includes or depends on the following third-party software and
specifications. Full license texts are in the linked files or packages.

| Component | License | Notes |
|---|---|---|
| apple/swift-log 1.16.2 | Apache-2.0 | Swift package dependency |
| Vidvox hap (hap.c/hap.h) | BSD-2-Clause | vendored in `Sources/CHap` (commit d847f6b); license in `Sources/CHap/LICENSE` |
| google/snappy 1.3.1 | BSD-3-Clause | vendored in `Sources/CSnappy`; license in `Sources/CSnappy/LICENSE` |
| Syphon-Framework (Metal server/client) | Syphon Framework License (BSD-3-Clause style) | vendored in `Sources/Syphon` (commit f476167); copyright 2010 bangnoise (Tom Butterworth) & vade (Anton Marini); license in `Sources/Syphon/LICENSE` |
| Art-Net™ | — | **Art-Net™ Designed by and Copyright Artistic Licence Engineering Ltd** (credit required by Artistic Licence; implementation is Lanthorn's own) |
| Svelte 5 (runtime in the web bundle) | MIT | build-time tooling (Vite, Vitest, TypeScript) is not distributed |

See `docs/licensing/DEPENDENCIES.md` for versions, pins and GPL compatibility.
