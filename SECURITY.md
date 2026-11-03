<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Security policy

Fanous runs on show networks and opens network services: HTTPS and WebSocket
on 8443 (web UI, roles and passwords), Art-Net (UDP 6454), sACN (UDP 5568),
OSC (UDP/TCP 8000), CITP (multicast 4809 plus a TCP port) and, between several
Macs, multi-server sync (UDP 8002). A flaw in any of them can stop a show, so
please report it privately.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository
(Security › Report a vulnerability). Do not open a public issue for a
security problem.

Please include the version (`fanousd --version` or the About window), the
macOS version, what an attacker needs (network access, a role, a password)
and the steps or packets that reproduce it.

You get an answer within 7 days. Fixes for confirmed issues go into the next
release; we credit reporters in the release notes unless you ask us not to.

## Supported versions

Only the latest release (and the `main` branch until 1.0) receives security
fixes.

## Scope and known limits

- Art-Net, sACN, OSC and multi-server sync have no authentication by design;
  anyone on the show network can send DMX, or a sync clock that moves a slave's
  layers. Keep the control network separate from public networks. This is
  expected behaviour, not a vulnerability.
- The web UI is open (no password) until you set one under System › Roles and
  passwords; the status bar shows "web UI open" until then.
- The engine's TLS certificate is self-signed; the Mac app pins its
  fingerprint, browsers ask once (fingerprint under System › Network).
