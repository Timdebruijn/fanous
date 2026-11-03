<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Release checklist

Everything a Fanous release needs, in order. "Owner" steps need Tim's
accounts, hardware or signature; the rest is scripted. The checklist is the
Phase 8 deliverable of `DESIGN.md` §19; v1.0 ships when every box is ticked.

## 1. Code is green

- [ ] `scripts/test.sh` (engine tests bind the DMX/OSC/HTTPS ports: stop any
      running `fanousd` first). Tests run in parallel and wait with a deadline,
      so a loaded Mac makes the run slower, not red, in the loads tested (load
      average up to ~100); negative checks keep fixed windows (B67)
- [ ] `scripts/check-mallocs.sh`: 0 allocations for the tick's own work, with no
      GPU encoding (DESIGN §4.6), in a release build. `fanous-bench` reports the
      GPU path's count per tick: 4 at the minimum, all Metal's own (B105). Also
      required before merging a PR that touches the compositor path (B89)
- [x] `FANOUS_NET_TESTS=1 scripts/test.sh --filter CITPServerTests` on a Mac
      whose firewall allows the test runner's outgoing UDP (the CITP beacon)
- [ ] `scripts/check-generated.sh`, `scripts/core-purity.sh`,
      `scripts/license-headers.sh`
- [ ] `cd web && npm test && npm run typecheck && npm run check && npm run build`
- [ ] `docs/BACKLOG.md` has a row for every known limitation; nothing is
      silently missing

## 2. Version

- [ ] `FanousVersion.string` in `Sources/FanousCore/Attribution.swift`
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
      (`LABEL=org.fanous.engine`) before the final release
- [ ] a second display plugged and unplugged during the soak once a Mac with
      one is available (B34)

## 4. Console interop (owner, B40)

With Fanous and the console software on one subnet (Little Snitch: allow
`fanousd` incoming UDP 6454/5568/8000 and outgoing UDP to
224.0.0.180/239.224.0.180:4809):

- [ ] grandMA3 onPC, ChamSys MagicQ PC, ETC Eos Nomad: GDTF import
      (`Patch › Export GDTF`), DMX end to end (intensity, folder/file, play
      mode). CITP on MagicQ PC only (grandMA3 and Eos have none, see
      `feature-gaps.md` §0): Fanous appears as a media server, thumbnails show,
      the canvas stream plays
- [ ] packet captures of what the consoles send go to
      `Tests/Fixtures/captures/` with provenance in its `README.md`
- [ ] Art-Net OEM code registered with Artistic Licence and set in
      `ArtPollReply` (OPEN-25; 0xFFFF until then)

## 5. Build and notarize (owner: Developer ID)

- [ ] `CODESIGN_IDENTITY="Developer ID Application: <name> (<team>)" scripts/bundle.sh`
      — hardened runtime, `scripts/entitlements.plist` (microphone for LTC,
      camera for capture devices), usage strings and `NSBonjourServices` in
      `Info.plist`, timestamped. Done for 1.0.0-rc.1 on 2026-11-02 (B50); repeat per release
- [ ] `xcrun notarytool store-credentials fanous --apple-id … --team-id … --password <app-specific>` once, then
      `NOTARY_PROFILE=fanous scripts/notarize.sh` → `dist/Fanous-<version>.dmg`, signed with the app's Developer ID,
      notarized and stapled; the script ends with `spctl --assess --type execute` on the app and
      `spctl --assess --type open --context context:primary-signature` on the dmg, both `accepted`,
      `source=Notarized Developer ID`
      (the app-specific password: account.apple.com › Sign-In and Security › App-Specific Passwords).
      Done for 1.0.0-rc.1 on 2026-11-02: zip and dmg accepted, stapled, Gatekeeper: Notarized
      Developer ID for the app (B50, PR #182); repeat per release. The rc.1 and rc.2 dmgs themselves were not signed
      (measured 2026-11-03: `codesign -dv` "not signed at all", the dmg check "rejected, source=no usable signature",
      `syspolicy_check distribution` flagged the dmg, the app inside passed); the script signs it since PR #234.
      Done again for 1.0.0-rc.2 on 2026-11-03 from main 845948f: zip and signed dmg accepted, both stapled, both
      `spctl` checks `accepted`, `source=Notarized Developer ID`, `syspolicy_check distribution` passes the dmg
- [ ] `shasum -a 256 dist/Fanous-<version>.dmg` goes into the release notes
- [ ] only on a developer Mac that ran ad-hoc builds: the first Developer ID open re-registers the agent (B50), and
      the old Screen Recording switch stays on while the engine reads `denied` after the signature change:
      `tccutil reset ScreenCapture org.fanous.app`, ask again, switch the fresh row on, restart the engine
      (measured 2026-11-02: `granted` after the restart)

## 6. Clean-account install test (owner)

On a fresh macOS user account (or a fresh Mac) with the notarized dmg:

- [ ] drag to Applications, first launch opens without a Gatekeeper warning
- [ ] "Allow in the Background" appears once; after approval `fanousd` runs
      (`launchctl print gui/$(id -u)/org.fanous.engine`) and the UI loads
- [ ] the Local Network prompt appears on first Art-Net/sACN receive and the
      microphone prompt when an LTC input is chosen; both attributed to Fanous
- [ ] `kill -9` of the engine: outputs back within 3 s (`scripts/soak.sh 0.1`)
- [ ] an iPad on the same network reaches `https://<mac>.local:8443`, accepts
      the certificate once (fingerprint under System › Network), WebCodecs
      preview plays (B46: done once on 2026-10-26, repeat per release)
- [ ] Quit the app with the engine running: "Quit Fanous?" appears as a sheet;
      Return (Keep Engine Running) quits and the engine keeps running; Cancel
      keeps the app; Stop Engine and Quit removes the service (outputs black);
      "Don't ask again" with Keep skips the question next time; with the
      engine stopped the app quits without asking
- [ ] `Engine › Stop Engine…` removes the service; the next launch installs
      it again

## 7. Legal and naming (owner)

- [x] remove `docs/BRIEF.md` (DESIGN §17): removed from the repository and its whole history on 2026-10-26, before the first push; kept outside the repo by the owner
- [x] employment contract checked by the owner: Fanous is his own project
      (2026-10-26)
- [x] owner checked the name "Fanous" in TMview/BOIP (2026-10-26)
- [ ] lawyer review of `docs/licensing/PLUGIN-EXCEPTION.md`, `CLA.md`,
      `ATTRIBUTION.md` (all marked DRAFT until then); not needed to make the
      repository public, needed before the first external pull request is
      merged (README and CONTRIBUTING say pull requests are not accepted yet)
- [ ] trademark search for "Fanous" (OPEN-21); `TRADEMARKS.md` final.
      The project was called Lanthorn until 2026-10-25 and was renamed
      because of collisions found in a web survey (Lanthorn.ai claims the mark,
      USPTO serial 99907978 "LANTHORN", the GPL Android player
      `hrmasss/lanthorn`). Web check of "Fanous" on 2026-10-25 (not a legal
      search): no software, media server or live mark; one cancelled US mark
      for jewelry (FANOUS JEWELERS, filed 2002, cancelled). The word is the
      Egyptian decorative lantern (fanous), also used for Ramadan. EUIPO and
      the Benelux register still to check
- [x] positioning (`docs/marketing/positioning.md`; the README has no "Why another media server" section any more, 2026-10-26): the survey found no open-source media server with DMX
      fixtures + GDTF + CITP + timecode chase together; closest are
      OpenVideoServer (Apache-2.0, Debian/Windows, 2026) and ossia score; the
      free Katrin Media Server (Logvinov, Mac, last release 2013, closed
      source) is the historical precedent, named in `positioning.md`
- [x] `docs/licensing/DEPENDENCIES.md` and `THIRD-PARTY-NOTICES.md` match
      `Package.resolved` and `web/package-lock.json` (checked 2026-10-26; the app
      bundle now carries the license texts in `Resources/licenses/`)
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
- [ ] the release notes name the drawable-loop driver and the macOS 27.0.1
      stall (R17, ADR-0006) so early adopters know why it is the default
