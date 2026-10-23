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

The first engine start generates an ECDSA key and self-signed certificate
(data-protection keychain for signed builds, login keychain otherwise) and
writes the public certificate and its fingerprint to
`~/Library/Application Support/Lanthorn/tls/`. Unsigned development builds:
the login keychain prompts when the binary changes, so run
`lanthornd reset-tls` after a rebuild to regenerate the identity for the
current build. Logs: `~/Library/Logs/Lanthorn/lanthornd.log`.

Phase 2 render spike: `lanthornd --scene scene.json` renders a static scene
(`{"canvasWidth":1920,"canvasHeight":1080,"fps":60,"display":0,"layers":["a.mov","b.mov"]}`),
driven by the standard DMX patch; `/api/metrics` reports frame timing and the
DMX-to-photon estimate. `scripts/bench-sweep.sh` runs the benchmark matrix.

- `docs/DESIGN.md` — the design (architecture, pipeline, channel map, UI, roadmap)
- `docs/adr/` — architecture decision records
- `docs/licensing/` — license terms, CLA, dependency audit
- `CONTRIBUTING.md`, `TRADEMARKS.md`

License: GPL-3.0-only with additional terms (see `docs/licensing/`).
Copyright (c) 2026 Tim de Bruijn.
