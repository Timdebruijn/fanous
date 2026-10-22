# Contributing to Lanthorn

Thank you for considering a contribution. Lanthorn is a media server for live
events; stability and performance come before features, and the project is
dual-licensed (GPL-3.0-only with additional terms, and a commercial license).
That second point shapes the rules below.

## 1. Contributor License Agreement (required)

Every contribution — code, shaders, documentation, test fixtures, media —
requires a signed **Contributor License Agreement** (`docs/licensing/CLA.md`).
The CLA grants the project owner the right to sublicense and relicense your
contribution, which is what makes the commercial edition possible. A
Developer Certificate of Origin (`Signed-off-by`) is **not** sufficient and
is not accepted as a substitute.

Signing happens once, through the CLA bot on your first pull request
(cla-assistant). Entities sign the Entity CLA; the bot records which GitHub
accounts are covered. Pull requests from unsigned authors are not merged.

## 2. Before you write code

- Read `docs/DESIGN.md` and the ADRs in `docs/adr/`. A change that contradicts
  an ADR needs a new ADR first; open an issue to discuss it.
- Open an issue for anything bigger than a bug fix. Features not in the v1
  roadmap are not merged into v1.
- Hardware: Apple Silicon with a ProRes engine (M1 Pro/Max/Ultra, M2 or
  later). Core-only changes can be developed on any Mac.

## 3. Rules every pull request follows

- **SPDX header** on every source file (Swift, Metal, C/C++/ObjC, TS, Svelte,
  CSS, shell):
  ```
  // SPDX-License-Identifier: GPL-3.0-only
  // Copyright (c) 2026 Tim de Bruijn and Lanthorn contributors
  // Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
  ```
  `scripts/license-headers.sh` checks this in CI.
- **No new dependencies** without an ADR and a row in
  `docs/licensing/DEPENDENCIES.md`. Vendored C code is pinned to a commit.
- **`LanthornCore` imports only Foundation.** Protocol parsers come with
  fixture-based tests (real captures in `Tests/Fixtures/captures/`).
- **Hot paths** (render, decode, DMX, audio, timecode): no Swift Concurrency,
  no allocations in steady state, no locks. See ADR-0002.
- **Tests**: run `scripts/test.sh` (wraps `swift test`); unit tests for Core changes; golden images for anything visual;
  benchmark numbers in the PR description for anything that touches the
  render or decode path (run `lanthorn-bench` before and after).
- **Commits** in English, imperative mood, one topic per commit. PRs describe
  what was measured, not only what was changed.
- Code style: `swift-format` configuration in the repo; `eslint`/`prettier`
  for `web/`.

## 4. Review and merge

The maintainer reviews every PR. Expect questions about measurements. PRs
that reduce complexity are welcome; PRs that add flexibility "for later" are
usually declined with a pointer to the roadmap.

## 5. Security

Report security issues privately to the maintainer (see the repository's
security policy) rather than in a public issue.
