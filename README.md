# Lanthorn

Open-source media server for live events, programmed from a lighting console
as a fixture (Catalyst-style): video layers driven by Art-Net/sACN on Apple
Silicon Macs, with edge blending, warping and video mapping on the GPU.

Status: **Phase 0 (skeleton)** — engine serves the UI over HTTPS; no media
features yet. Roadmap: `docs/DESIGN.md` §19.

## Development

Requirements: Apple Silicon Mac with a ProRes engine, macOS 15+, Swift 6.2+
(Command Line Tools are enough until Metal shaders arrive), Node 26 for the
web UI.

```bash
swift build                      # engine, shell, core
scripts/test.sh                  # Core unit tests (Swift Testing)
(cd web && npm install && npm run build)   # web UI → web/dist
.build/debug/lanthornd --foreground        # https://127.0.0.1:8443 (self-signed; fingerprint in the log)
swift run LanthornShell          # native shell; starts lanthornd as a child in development
scripts/bundle.sh                # dist/Lanthorn.app (ad-hoc signed; CODESIGN_IDENTITY=… for Developer ID)
```

Protocol fixtures: `scripts/capture-dmx.py artnet|sacn|osc <name>` records
real console packets into `Tests/Fixtures/captures/` (stop `lanthornd` first;
see the README there). `lanthornd channel-map` prints the DMX channel map,
`lanthornd gdtf FILE` writes the GDTF fixture file; `scripts/check-channel-map.sh`
keeps `docs/channel-map.md` in sync.

The first engine start generates an ECDSA key and self-signed certificate and
writes the public certificate and its fingerprint to
`~/Library/Application Support/Lanthorn/tls/`. Signed builds keep the key in
the data-protection keychain; builds without a team identifier (ad-hoc
development builds) keep it in `tls/private-key.der` (mode 0600) and never
touch the login keychain, so there are no keychain prompts. `lanthornd
reset-tls` discards the identity. Logs: `~/Library/Logs/Lanthorn/lanthornd.log`.

Until projects exist (Phase 5), `lanthornd --scene scene.json` renders a scene
driven by the standard DMX patch:

```json
{"canvasWidth": 1920, "canvasHeight": 1080, "fps": 60, "display": 0, "layerCount": 4,
 "media": [{"folder": 1, "file": 1, "path": "/path/loop.mov"},
           {"folder": 1, "file": 2, "path": "/path/still.png"},
           {"folder": 0, "file": 1, "syphon": "Some App/Server name"}]}
```

Layers pick media with their Folder/File channels. The engine indexes the
library root (`~/Movies/Lanthorn Library` by default, `"library"` in the
scene to override): folders `NNN_name/` and files `NNN_name.ext`, numbered
1–255, ProRes/HAP `.mov` and stills playable, everything else marked "needs
transcode"; FSEvents keep the index current, metadata and thumbnails are
cached under `~/Library/Application Support/Lanthorn/cache/`. Explicit scene
`media` entries (Syphon servers, test files) take precedence over the library.
The canvas is published as the Syphon server "Lanthorn – Canvas".

Ingest: `lanthornd ingest DIR out.mov` converts an image sequence from the
command line; the engine's ingest queue (`/api/ingest`) transcodes uploads and
"needs transcode" items to ProRes or HAP one job at a time at utility
priority, yielding when the compositor is busy, and moves originals to
`_originals/`. Remote clients upload with `PUT /api/upload/<folder>/<name>`
(streamed to `_incoming/`, then queued). Endpoints: `/api/library`,
`/api/library/rescan`, `/api/thumbnail/<name>.jpg`, `/api/ingest`.

`/api/metrics` reports frame timing, the DMX-to-photon estimate and audio
drift; `lanthorn-bench run` ramps layers until a frame drops (`--effects
blur,edge`, `--dissolve 2`, `--ingest FILE` for the Phase 3/4 variants) and
`scripts/bench-sweep.sh` / `scripts/bench-phase3.sh` run the matrices.

- `docs/DESIGN.md` — the design (architecture, pipeline, channel map, UI, roadmap)
- `docs/adr/` — architecture decision records
- `docs/licensing/` — license terms, CLA, dependency audit
- `CONTRIBUTING.md`, `TRADEMARKS.md`

License: GPL-3.0-only with additional terms (see `docs/licensing/`).
Copyright (c) 2026 Tim de Bruijn.
