# ADR-0017: GPL-3.0-only with §7 terms, SPDX headers, CLA via cla-assistant

Status: Accepted · 2026-10-22 · needs lawyer review before public release

## Context
The owner wants GPL-3.0-only, an attribution term (GPLv3 §7(b)), a plugin
exception (additional permission), dual licensing (needs relicensing rights
from contributors) and SPDX headers. Verified 2026-10-22: SPDX allows
`WITH` only for listed exceptions; custom terms need a `LicenseRef-`
expression. `contributor-assistant/github-action` is archived; EasyCLA is
Linux-Foundation-only; SAP's cla-assistant (v2.13.2, 2026-10-13) is active.

## Decision
- `LICENSE` = GPLv3 text with a notice pointing to
  `LICENSE-ADDITIONAL-TERMS.md`, which contains the attribution term and (once
  reviewed) the plugin additional permission.
- Source headers: `SPDX-License-Identifier: GPL-3.0-only`, a copyright line,
  and the §7-required pointer line to the additional terms. We do **not**
  use a `LicenseRef-` expression in headers because license scanners would
  stop recognising the GPL; the ADR records this trade-off for the lawyer.
- CLA: text in `docs/licensing/CLA.md` (individual + entity; copyright and
  patent grant with the right to sublicense under any license). Tool:
  **cla-assistant (SAP)** as a GitHub App, enabled when the repository goes
  public; it blocks merges until the author has signed. Self-hosting the
  same tool is the fallback if the hosted service disappears.
- `TRADEMARKS.md` reserves name and logo; vendored third-party notices in
  `THIRD-PARTY-NOTICES.md`.

## Consequences
+ Dual licensing stays possible; attribution survives forks; plugins can
  link proprietary SDKs once the exception is reviewed.
− Lawyer review is on the release checklist; until then the plugin
  exception is a draft and no plugin is distributed.
