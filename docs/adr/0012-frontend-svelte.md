# ADR-0012: Frontend: Svelte 5 + Vite + TypeScript

Status: Accepted · 2026-10-22

## Context
The UI shows 1 000+ live values updating at 20 Hz plus a live video preview
and an SVG mapping editor, and must stay smooth on an iPad. The owner asked
for whichever framework has the least performance impact. Verified
2026-10-22: Svelte 5.57 (MIT), Preact 11.0 (MIT), Vite 8.3, Vitest 5.0,
TypeScript 7.0 (Apache-2.0); see `docs/licensing/DEPENDENCIES.md`.

## Decision
- Svelte 5 (runes) with Vite and TypeScript strict; Vitest for unit tests.
  No SvelteKit, no router library, no UI component library, no runtime CDN
  loads. The built `web/dist` is embedded in `lanthornd`.
- Protocol types are generated from `LanthornCore` into `protocol.d.ts`.

## Rationale
Svelte compiles components to direct DOM updates with fine-grained
signals; a live-value tick touches only the text nodes that changed, with
no virtual-DOM diff. Preact + signals gets close but still reconciles
component output; its advantage (React compatibility) is irrelevant here.
Both are MIT and GPLv3-compatible.

## Consequences
+ Smallest runtime work per live update; small bundle.
− Svelte 5's compiler is a build-time dependency with its own release
  cadence; pinned exact versions, updated deliberately.
