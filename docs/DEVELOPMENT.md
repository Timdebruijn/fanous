<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Development

Building, protocols, endpoints and internals. The user guide is in [`user/`](user/README.md).


Requirements: Apple Silicon Mac with a ProRes engine, macOS 15+, Swift 6.2+
(Command Line Tools are enough until Metal shaders arrive), Node 26 for the
web UI.

```bash
swift build                      # engine, shell, core
scripts/test.sh                  # Core unit tests (Swift Testing)
scripts/check-mallocs.sh         # §4.6 zero-malloc rule, release build (before merging compositor changes)
(cd web && npm install && npm run build)   # web UI → web/dist
.build/debug/fanousd --foreground        # https://127.0.0.1:8443 (self-signed; fingerprint in the log)
swift run FanousShell          # native shell; starts fanousd as a child in development
scripts/bundle.sh                # dist/Fanous.app (ad-hoc signed; CODESIGN_IDENTITY=… for Developer ID)
```

An isolated engine (tests, a second engine next to a running one):
`FANOUS_HOME=DIR` (an absolute path; anything else is ignored with a warning,
and `reset-tls` then refuses) puts everything the engine keeps under `DIR`
instead of the home directory (`DIR/Library/Application Support/Fanous`,
`DIR/Library/Logs/Fanous`, the TLS identity, the cache and the default library
`DIR/Movies/Fanous Library`); a keychain-stored TLS key gets a tag of its own
(`org.fanous.tls@DIR`), so `FANOUS_HOME=DIR fanousd reset-tls` never touches the
real install's key. `--no-network` leaves out Art-Net (6454), sACN (5568),
OSC (8000), CITP and Bonjour and binds HTTPS to 127.0.0.1 only (a fresh home has
every role open):

```bash
FANOUS_HOME=$(mktemp -d) .build/debug/fanousd --foreground --no-network --port 18443
```

Multi-server sync on one Mac (DESIGN.md §23): two such engines, each with its
own sync port in `settings.json` and the other's port as a unicast target (a
unicast datagram reaches only one of two sockets sharing a port, and
`--no-network` sends to 127.0.0.1 only), the same file as folder 1 file 1:

```bash
for e in A:48802:48812 B:48812:48802; do
  IFS=: read name port peer <<< "$e"
  mkdir -p "/tmp/sync/$name/Library/Application Support/Fanous"
  echo "{\"sync\": {\"port\": $port, \"target\": \"127.0.0.1:$peer\"}}" > "/tmp/sync/$name/Library/Application Support/Fanous/settings.json"
done
echo '{"layerCount": 2, "policy": "ltp", "audio": false, "syphonOutput": false,
 "media": [{"folder": 1, "file": 1, "path": "/path/clip.mov"}]}' > /tmp/sync/scene.json
FANOUS_HOME=/tmp/sync/A .build/debug/fanousd --foreground --no-network --port 48443 --scene /tmp/sync/scene.json &
FANOUS_HOME=/tmp/sync/B .build/debug/fanousd --foreground --no-network --port 48444 --scene /tmp/sync/scene.json &
```

Then on both engines (UI or `cmd` over the WebSocket, `fixture.set` on
`Layer 1`): intensity full, folder 1, file 1; Sync raw 10 (master group 1) on
A and 90 (slave group 1) on B. B's live document shows
`layers[0].sync = {role: "slave", state: "locked", offsetMs, master}` and
`sync.packetsIn` counting at the tick rate; Sync off on A turns B to
`freewheel`, then `lost` after 2 s. `/metrics` › `sync` has the packet totals.

Browser end-to-end tests (`web/e2e/`, Playwright with Chromium) run the built
UI against such an engine, one engine per test on a free port with a fresh
temporary `FANOUS_HOME`, opened as the shell does (`?token=` from that home, so
programmer). A page error, console error, refused command or refused stream
fails, except a preview refused for an output or canvas that appeared less than
1.5 s earlier (two known engine races, see `web/e2e/fixtures.ts`). Each home
holds `fanousd.pid`; the next run kills engines an aborted run left behind. The
tests need `.build/debug/fanousd` and `web/dist` (or `FANOUSD=/path/to/fanousd`):

```bash
swift build
cd web && npm run build
npx playwright install chromium   # once
npm run e2e                       # npx playwright test --headed / --ui to watch
```

CI runs them in the `e2e` job on macOS; on a failure the traces and engine
logs are uploaded as the `e2e-results` artifact. To see the preview tests as
CI's slow VideoToolbox does (B98): `CI=1 E2E_SLOW_DECODER=6000 npm run e2e`
delays every `VideoDecoder.isConfigSupported` by 6 s (past the browser's 5 s
JPEG fallback), `CI=1 E2E_FAILING_DECODER=1 npm run e2e -- -g preview` makes
each decoder fail after its first picture; `CI=1` gives the CI timeouts and
skips.

Protocol fixtures: `scripts/capture-dmx.py artnet|sacn|osc <name>` records
real console packets into `Tests/Fixtures/captures/` (stop `fanousd` first;
see the README there). `fanousd channel-map` prints the DMX channel map,
`fanousd gdtf FILE` writes the GDTF fixture file; `scripts/check-channel-map.sh`
keeps `channel-map.md` in sync.

The first engine start generates an ECDSA key and self-signed certificate and
writes the public certificate and its fingerprint to
`~/Library/Application Support/Fanous/tls/`. Signed builds keep the key in
the data-protection keychain; builds without a team identifier (ad-hoc
development builds) keep it in `tls/private-key.der` (mode 0600) and never
touch the login keychain, so there are no keychain prompts. `fanousd
reset-tls` discards the identity. Logs: `~/Library/Logs/Fanous/fanousd.log`.

Until projects exist (Phase 5), `fanousd --scene scene.json` renders a scene
driven by the standard DMX patch:

```json
{"canvasWidth": 1920, "canvasHeight": 1080, "fps": 60, "display": 0, "layerCount": 4,
 "media": [{"folder": 1, "file": 1, "path": "/path/loop.mov"},
           {"folder": 1, "file": 2, "path": "/path/still.png"},
           {"folder": 0, "file": 1, "syphon": "Some App/Server name"}]}
```

`syphon` is `"App/Server name"`, split on the first `/`; `"App/"` takes the
first server of that app (Syphon servers may have an empty name).

Layers pick media with their Folder/File channels. The engine indexes the
library root (`~/Movies/Fanous Library` by default, `"library"` in the
scene to override): folders `NNN_name/` and files `NNN_name.ext`, numbered
1–255, ProRes/HAP `.mov` and stills playable, everything else marked "needs
transcode"; FSEvents keep the index current, metadata and thumbnails are
cached under `~/Library/Application Support/Fanous/cache/`. Explicit scene
`media` entries (Syphon servers, test files) take precedence over the library.
The canvas is published as the Syphon server "Fanous – Canvas".

Ingest: `fanousd ingest DIR out.mov` converts an image sequence from the
command line; the engine's ingest queue (`/api/ingest`) transcodes uploads and
"needs transcode" items to ProRes or HAP one job at a time at utility
priority, yielding when the compositor is busy, and moves originals to
`_originals/`. Remote clients upload with `PUT /api/upload/<folder>/<name>`
(streamed to `_incoming/`, then queued). Endpoints: `/api/library`,
`/api/library/rescan`, `/api/thumbnail/<name>.jpg`, `/api/ingest`.

State and roles (Phase 5, DESIGN.md §11): the UI talks WebSocket on
`wss://<host>:8443/ws` (hello → welcome with the `project` and `live`
documents, commands with acks, RFC 6902 patches per revision, `snapshot` for
a lagging client, `sub` for the DMX monitor stream). Roles are monitor,
operator and programmer with optional passwords (`roles.setPassword`,
PBKDF2-HMAC-SHA256 in `~/Library/Application Support/Fanous/settings.json`);
`POST /api/login` returns the session cookie, `GET /api/session` shows the
current role and which roles are open. The local shell authenticates with the
token in `shell-token` (mode 0600). The project is autosaved to `project.json`
and loaded at start; `fanousd protocol-dts` prints `web/src/lib/protocol.d.ts`
(checked by `scripts/check-protocol-dts.sh`).

Web UI (`web/`, Svelte 5 + Vite, served by the engine from `web/dist`):
status bar, Layers / Mixer (rows with the resolved media, position, intensity
and the DMX inspector of the selected layer), Media (library browser, upload,
transcode, ingest queue) and Patch / DMX (fixture groups and blocks with collisions,
`patch.set` and `patch.setMany`, a 512-cell monitor fed by the `dmx` stream). The canvas preview
on the Layers screen uses WebCodecs (H.264 from VideoToolbox, `sub` stream
`preview`) and falls back to JPEG at 5 fps. Keys 1–6 switch screens.
`cd web && npm run dev` proxies `/api`, `/ws` and `/healthz` to a running
engine; `npm run build` writes `web/dist`. The web checks, in the order of
CI's `web` job: `npm test && npm run typecheck && npm run check && npm run build`; `check` is
`svelte-check` (types in the `.svelte` script blocks, Svelte's a11y rules,
warnings fail). svelte-check needs the TypeScript 6 API, so `typescript` is 6
and TypeScript 7 is installed as `@typescript/native`, which `typecheck` runs.

Outputs and mapping (Phase 6, DESIGN.md §9): the project holds `outputs[]`
(display identity, region, mode, intensity, blend edges with power and gamma,
black lift, corner pin and mesh warp, slices with source rectangle,
destination quad, masks (paths or library images) with feather, test pattern)
and `canvases[]`.
Commands `output.add`, `output.remove`, `output.set` (a JSON pointer inside the
output, validated as a whole) and `canvas.set`; `live.displays` lists the
connected displays by UUID and `live.outputs` whether each output is bound,
lost or unassigned. The engine opens one window per bound display, drives the
compositor from the clock-master display and presents the others from the
latest completed canvas; blend maps, warp fields and masks are compiled on
Control and swapped into the render thread. The Outputs & Mapping screen edits
all of it with handles over the output preview (`sub` stream `preview` with
`target: "output:<id>"`).

Show control (Phase 7, DESIGN.md §14–16): `project.timecode` selects LTC (any
CoreAudio input) or MTC (any CoreMIDI source) with project and per-layer
offsets; layers in the `timecode` play mode chase it. `project.cues[]` holds
cues with fades, timecode triggers and follows (`cue.add/set/remove`,
`cue.go/back/goto`, Space on the Show screen); cue values enter the resolver
as the internal source. The complete OSC address map is live (UDP 8000,
bundles with timetags). Show mode (`show.mode`) takes power assertions and
pauses ingest after the readiness check (`readiness.run/acknowledge`,
`live.show`). CITP/MSEX advertises the engine (`PLoc` on both multicast
groups) and serves consoles layer status, libraries, elements, thumbnails and
streaming frames over TCP (`live.citp`). `/metrics` and `/api/logs` feed the
System / Health screen.

Install and release (Phase 8, `RELEASE.md`): `scripts/bundle.sh` assembles
`dist/Fanous.app` (shell + `fanousd` LaunchAgent + web UI) with the
hardened runtime; `CODESIGN_IDENTITY` selects a Developer ID and
`scripts/notarize.sh` notarizes and staples a dmg. First launch asks once to
allow the engine under Login Items. `scripts/soak.sh HOURS` runs the soak test
(scripted Art-Net, 1 s metrics samples, `kill -9` restarts) and writes a
PASS/FAIL report to `benchmarks/`. User documentation: `user/`.

An ad-hoc signed `dist/Fanous.app` gets a new code identity with every
`scripts/bundle.sh`, and TCC keys its grants on that identity. TCC books the
engine's grants on the shell (the LaunchAgent is registered through
`SMAppService` with `org.fanous.app` as parent bundle), so System Settings
lists one entry, "Fanous", under Camera and under Screen & System Audio
Recording. After a rebuild that entry keeps its switch on but no longer
matches the binary: the engine reads `notDetermined` / `denied`, and macOS
does not ask again. Reset the stale entries, then authorize on the System
screen and switch "Fanous" on:

```
tccutil reset Camera org.fanous.app
tccutil reset ScreenCapture org.fanous.app
```

In the "Fanous may not be able to record the contents of your screen until it
is quit" dialog choose Later: Quit & Reopen quits the shell and the engine and
does not reopen a dev build (`open dist/Fanous.app`). A Developer ID build
keeps its identity and its grants.

A network filter that keys its rules on code identity (Little Snitch) is the
likely reason sync output can stay dead after a rebuild: it would hold the
new binary's flows until its alert is answered, and the engine shows nothing
of it beyond `sync.packetsDropped` in the live document. No alert was
confirmed seen, so this rests on timing. Measured 2026-10-30: the engine
started at 19:01:50 and its sync keepalives (broadcast to port 8002, one a
second) were dropped from the 19th packet on, the socket's send buffer
holding 18. The system log shows the application firewall's first flow from
that pid at 23:22:26, 4 h 20 min later, while the user was answering system
prompts at the keyboard; from then on the firewall saw each new flow at
once, and its own verdict was the known-app allow, so the firewall was not
the blocker. When `packetsDropped` keeps rising after a rebuild, look for a
pending filter alert, and check whether the engine's flows have reached the
firewall at all:

```
log show --last 1h --predicate 'process == "socketfilterfw" AND eventMessage CONTAINS "org.fanous"'
```

A "Handle flow" line for the engine's pid means the flow reached the
application firewall; in the run above that happened only after the delay.

`/api/metrics` reports frame timing, the DMX-to-photon estimate and audio
drift; `fanous-bench run` ramps layers until a frame drops (`--effects
blur,edge`, `--dissolve 2`, `--ingest FILE` for the Phase 3/4 variants) and
`scripts/bench-sweep.sh` / `scripts/bench-phase3.sh` run the matrices.
