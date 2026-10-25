# Fanous

Open-source media server for live events, programmed from a lighting console
as a fixture (Catalyst-style): video layers driven by Art-Net/sACN on Apple
Silicon Macs, with edge blending, warping and video mapping on the GPU.

Status: **1.0.0 release candidate** — all phases of `docs/DESIGN.md` §19 are
built; the release steps that need the owner are in `docs/RELEASE.md`. Until
2026-10-25 the project was called Lanthorn. The name is the Egyptian lantern
(fanous): coloured light for a show.

## Getting Fanous, support and paid editions

- **Free:** the source on GitHub under GPL-3.0-only with additional terms, and
  a notarized `Fanous-<version>.dmg` with every GitHub release.
- **Fanous Pro (paid binary):** the same engine plus the plugins that need
  closed vendor SDKs (NDI, DeckLink, AJA; `FanousPluginAPI` boundary,
  `docs/licensing/PLUGIN-EXCEPTION.md`), signed and auto-updating.
- **Support and training:** support contracts with response times, show
  commissioning (patch, mapping, timecode) and operator training.
- **Sponsored features:** companies may propose a feature and pay for its
  development; it lands in the open core unless it needs a closed SDK.
- **Commercial license:** for products that cannot ship GPL code (dual
  licensing through the CLA).

## Development

Requirements: Apple Silicon Mac with a ProRes engine, macOS 15+, Swift 6.2+
(Command Line Tools are enough until Metal shaders arrive), Node 26 for the
web UI.

```bash
swift build                      # engine, shell, core
scripts/test.sh                  # Core unit tests (Swift Testing)
(cd web && npm install && npm run build)   # web UI → web/dist
.build/debug/fanousd --foreground        # https://127.0.0.1:8443 (self-signed; fingerprint in the log)
swift run FanousShell          # native shell; starts fanousd as a child in development
scripts/bundle.sh                # dist/Fanous.app (ad-hoc signed; CODESIGN_IDENTITY=… for Developer ID)
```

Protocol fixtures: `scripts/capture-dmx.py artnet|sacn|osc <name>` records
real console packets into `Tests/Fixtures/captures/` (stop `fanousd` first;
see the README there). `fanousd channel-map` prints the DMX channel map,
`fanousd gdtf FILE` writes the GDTF fixture file; `scripts/check-channel-map.sh`
keeps `docs/channel-map.md` in sync.

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
transcode, ingest queue) and Patch / DMX (fixture table with collisions,
`patch.set`, a 512-cell monitor fed by the `dmx` stream). The canvas preview
on the Layers screen uses WebCodecs (H.264 from VideoToolbox, `sub` stream
`preview`) and falls back to JPEG at 5 fps. Keys 1–6 switch screens.
`cd web && npm run dev` proxies `/api`, `/ws` and `/healthz` to a running
engine; `npm run build` writes `web/dist`.

Outputs and mapping (Phase 6, DESIGN.md §9): the project holds `outputs[]`
(display identity, region, mode, intensity, blend edges with power and gamma,
black lift, corner pin and mesh warp, slices with source rectangle,
destination quad, mask path and feather, test pattern) and `canvases[]`.
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

Install and release (Phase 8, `docs/RELEASE.md`): `scripts/bundle.sh` assembles
`dist/Fanous.app` (shell + `fanousd` LaunchAgent + web UI) with the
hardened runtime; `CODESIGN_IDENTITY` selects a Developer ID and
`scripts/notarize.sh` notarizes and staples a dmg. First launch asks once to
allow the engine under Login Items. `scripts/soak.sh HOURS` runs the soak test
(scripted Art-Net, 1 s metrics samples, `kill -9` restarts) and writes a
PASS/FAIL report to `docs/benchmarks/`. User documentation: `docs/user/`.

`/api/metrics` reports frame timing, the DMX-to-photon estimate and audio
drift; `fanous-bench run` ramps layers until a frame drops (`--effects
blur,edge`, `--dissolve 2`, `--ingest FILE` for the Phase 3/4 variants) and
`scripts/bench-sweep.sh` / `scripts/bench-phase3.sh` run the matrices.

- `docs/DESIGN.md` — the design (architecture, pipeline, channel map, UI, roadmap)
- `docs/adr/` — architecture decision records
- `docs/licensing/` — license terms, CLA, dependency audit
- `CONTRIBUTING.md`, `TRADEMARKS.md`

License: GPL-3.0-only with additional terms (see `docs/licensing/`).
Copyright (c) 2026 Tim de Bruijn.
