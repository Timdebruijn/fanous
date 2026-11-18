# Working on Fanous as an agent

Fanous is a media server for live events: a Swift 6 engine (`Sources/`) driven by lighting consoles over
Art-Net, sACN, OSC, MIDI and timecode, with a Svelte 5 web UI (`web/`). Stability and measured behaviour come
before features. This file is for coding and review agents (Copilot, Claude, others); `CONTRIBUTING.md` holds
the rules for humans and `docs/DEVELOPMENT.md` the build details.

## Where things are
- `docs/DESIGN.md` and `docs/adr/`: the design and its decisions. A change that contradicts an ADR needs a new ADR.
- `docs/BACKLOG.md`: every deferred item as a row `| Bnnn | item | origin | trigger | owner |`. A row that lands is
  struck through in place: `| B123 | ~~…~~ **Done YYYY-MM-DD** (PR #N): one sentence |`. New findings get a new
  row with the next free id; the id must appear exactly once.
- `CHANGELOG.md`: one line per PR under `## Unreleased`, ending `(PR #N)`.
- `docs/user/`: the user guide. It quotes UI texts and shows screenshots; a change in behaviour or wording changes
  the guide in the same PR, and a screenshot that no longer matches is retaken, not left.
- `Tests/Fixtures/captures/`: real packet captures; protocol parsers are tested against them.

## Hard rules
- Every source file starts with the SPDX header (`scripts/license-headers.sh` checks it).
- `FanousCore` imports Foundation only (`scripts/core-purity.sh`).
- Hot paths (render, decode, DMX, audio, timecode) use no Swift Concurrency, allocate nothing in steady state and
  take no locks (ADR-0002; `scripts/check-mallocs.sh` measures it).
- No new dependency without an ADR and a row in `docs/licensing/DEPENDENCIES.md`.
- Wire formats stay byte-for-byte the same unless the PR says otherwise: the WebSocket documents, REST bodies,
  OSC, CITP, Art-Net and sACN. `web/src/lib/protocol.d.ts` and `docs/channel-map.md` are generated
  (`scripts/check-generated.sh`).
- One subject per PR, branched from `main`. Commits in English, imperative mood. No `Co-Authored-By` or
  "Generated with" lines anywhere: the repository owner is the sole author of record.
- A `// ponytail:` comment marks a deliberate simplification with its ceiling; do not flag it as a bug.

## Before a PR is ready
- Engine: `swift build` warning-free in the touched files, `scripts/test.sh` (full suite), and a check on a
  running engine for anything the tests cannot show (a test instance: `FANOUS_HOME=<dir> fanousd --foreground
  --no-network --port <free port>`; never 8443, 6454, 5568, 8000, 4809 or 8002, which the installed engine owns).
  Such an instance announces no Syphon server. A test leaves `announced` of `SyphonOutput` (and `announceSyphon` of
  `RenderService`) at its default, false: an announced server takes a permanent number in every engine on the Mac (B340).
- Web: `cd web && npm run check && npm test && npm run build`; the Playwright e2e suite runs on CI.
- A bug fix comes with a test that fails on the old code, and the PR says how the bug was reproduced.
- Claims about performance or behaviour are measured, not assumed; the PR body says what was measured and how.

## What a reviewer should look for
- A test that would also pass against the old code.
- A comment or doc line that claims what the code no longer does.
- A changed string that the guide still quotes, or a picture that now shows the old state.
- An unintended change on the wire (a renamed JSON key, a different error code, a reordered reply).
- Data loss on the ingest and project paths: the original file or the project must survive every failure and
  crash window.
- Anything on a hot path that allocates, locks or awaits.
- Scope creep: changes that belong to another subject.
