<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Release checklist

Everything a Lanthorn release needs, in order. "Owner" steps need Tim's
accounts, hardware or signature; the rest is scripted. The checklist is the
Phase 8 deliverable of `DESIGN.md` §19; v1.0 ships when every box is ticked.

## 1. Code is green

- [ ] `scripts/test.sh` (engine tests bind the DMX/OSC/HTTPS ports: stop any
      running `lanthornd` first)
- [ ] `LANTHORN_NET_TESTS=1 scripts/test.sh --filter CITPServerTests` on a Mac
      whose firewall allows the test runner's outgoing UDP (the CITP beacon)
- [ ] `scripts/check-protocol-dts.sh`, `scripts/check-channel-map.sh`,
      `scripts/core-purity.sh`, `scripts/license-headers.sh`
- [ ] `cd web && npm run typecheck && npm test && npm run build`
- [ ] `docs/BACKLOG.md` has a row for every known limitation; nothing is
      silently missing

## 2. Version

- [ ] `LanthornVersion.string` in `Sources/LanthornCore/Attribution.swift`
      (semver; `-rc.N` for candidates). The bundle, About window, `/healthz`,
      `caps.version` and CITP `SInf` read it.
- [ ] `CHANGELOG.md` entry with the date
- [ ] tag `v<version>` on `main` after the commit that bumps it

## 3. Measurements (per release, per machine)

- [ ] `scripts/bench-sweep.sh` and `scripts/bench-phase3.sh` on every
      available machine → `docs/benchmarks/<chip>-…-<date>.md/.json` and the
      tier table in `docs/benchmarks/README.md`; `docs/hardware.md` lists the
      chips verified (OPEN-6: owner verifies per generation)
- [x] `scripts/soak.sh 8` on the reference machine → `docs/benchmarks/soak-<date>.md`
      says PASS: no missed frames outside the restart windows, memory flat,
      every `kill -9` → `/healthz` under 3 s (DESIGN §2.3); late presents are
      warnings. Done for 1.0.0-rc.1 with the test agent
      (`soak-2026-10-24-0928.md`); repeat with the installed notarized agent
      (`LABEL=org.lanthorn.engine`) before the final release
- [ ] a second display plugged and unplugged during the soak once a Mac with
      one is available (B34)

## 4. Console interop (owner, B40)

With Lanthorn and the console software on one subnet (Little Snitch: allow
`lanthornd` incoming UDP 6454/5568/8000 and outgoing UDP to
224.0.0.180/239.224.0.180:4809):

- [ ] grandMA3 onPC, ChamSys MagicQ PC, ETC Eos Nomad: GDTF import
      (`Patch › Export GDTF`), DMX end to end (intensity, folder/file, play
      mode), CITP: Lanthorn appears as a media server, thumbnails show, the
      canvas stream plays
- [ ] packet captures of what the consoles send go to
      `Tests/Fixtures/captures/` with provenance in its `README.md`
- [ ] Art-Net OEM code registered with Artistic Licence and set in
      `ArtPollReply` (OPEN-25; 0xFFFF until then)

## 5. Build and notarize (owner: Developer ID)

- [ ] `CODESIGN_IDENTITY="Developer ID Application: <name> (<team>)" scripts/bundle.sh`
      — hardened runtime, `scripts/entitlements.plist` (microphone for LTC),
      usage strings and `NSBonjourServices` in `Info.plist`, timestamped
- [ ] `xcrun notarytool store-credentials lanthorn --apple-id … --team-id … --password <app-specific>` once, then
      `NOTARY_PROFILE=lanthorn scripts/notarize.sh` → `dist/Lanthorn-<version>.dmg`, stapled, `spctl --assess` passes
- [ ] `shasum -a 256 dist/Lanthorn-<version>.dmg` goes into the release notes

## 6. Clean-account install test (owner)

On a fresh macOS user account (or a fresh Mac) with the notarized dmg:

- [ ] drag to Applications, first launch opens without a Gatekeeper warning
- [ ] "Allow in the Background" appears once; after approval `lanthornd` runs
      (`launchctl print gui/$(id -u)/org.lanthorn.engine`) and the UI loads
- [ ] the Local Network prompt appears on first Art-Net/sACN receive and the
      microphone prompt when an LTC input is chosen; both attributed to Lanthorn
- [ ] `kill -9` of the engine: outputs back within 3 s (`scripts/soak.sh 0.1`)
- [ ] an iPad on the same network reaches `https://<mac>.local:8443`, accepts
      the certificate once (fingerprint under System › Network), WebCodecs
      preview plays (B46)
- [ ] Quit the app: the engine keeps running; `Engine › Stop Engine…` removes
      the service; the next launch installs it again

## 7. Legal and naming (owner)

- [ ] remove `docs/BRIEF.md` (DESIGN §17) and this line from the design
- [ ] lawyer review of `docs/licensing/PLUGIN-EXCEPTION.md`, `CLA.md`,
      `ATTRIBUTION.md` (all marked DRAFT until then)
- [ ] trademark search for "Lanthorn" (OPEN-21); `TRADEMARKS.md` final.
      Web survey 2026-10-24 (not a legal search): no media server or lighting
      software of that name; collisions to weigh: `hrmasss/lanthorn` (GPL
      Android video player, v1.0.0 2026-10-22), Lanthorn.ai (video analytics,
      claims the mark in its terms), USPTO serial 99907978 "LANTHORN" (class 42
      SaaS, filed 2026-06-26 by another company, seen on an aggregator only),
      LanthornLED (luminaires, Namibia); EUIPO not checked
- [ ] positioning: the survey found no open-source media server with DMX
      fixtures + GDTF + CITP + timecode chase together; closest are
      OpenVideoServer (Apache-2.0, Debian/Windows, 2026) and ossia score; the
      free Katrin Media Server (Logvinov, Mac, last release 2013, closed
      source) is the historical precedent to name in the README
- [ ] `docs/licensing/DEPENDENCIES.md` and `THIRD-PARTY-NOTICES.md` match
      `Package.resolved` and `web/package-lock.json`
- [ ] cla-assistant enabled on the public repository

## 8. Docs

- [ ] `README.md` install paragraph points at the dmg and `docs/user/`
- [ ] `docs/user/*` read through against the build (button labels, paths)
- [ ] `docs/DESIGN.md`: every phase has its "as built" notes; `[OPEN-n]`
      rows are decided, resolved or marked v1.x; §19 scope guard lists the
      v1.x candidates
- [ ] `docs/BACKLOG.md`: rows that shipped are removed, the rest carry a
      trigger

## 9. Publish

- [ ] GitHub release `v<version>` with the dmg, its SHA-256, the CHANGELOG
      section and the interop/benchmark notes
- [ ] Apple Feedback for the CAMetalDisplayLink stall (R17) referenced in the
      release notes so early adopters know why the drawable-loop driver is the
      default
