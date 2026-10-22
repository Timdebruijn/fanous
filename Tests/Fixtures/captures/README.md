# Protocol captures

Raw UDP payloads (one datagram per `.bin`) recorded with
`scripts/capture-dmx.py` from real console software, plus their provenance in
the `.txt` next to them. `CaptureTests` parses every file here; a capture that
stops parsing is a regression.

| Directory | Source software | Notes |
|---|---|---|
| `artnet/` | see per-file `.txt` | ArtDmx, ArtPoll as sent on the wire |
| `sacn/` | see per-file `.txt` | E1.31 data, sync and discovery packets |
| `osc/` | see per-file `.txt` | OSC messages/bundles |

Capturing: stop `lanthornd` (it binds the same ports), run
`scripts/capture-dmx.py artnet <name> --note "QLC+ 5.3.0, universe 1, …"`,
then make the console send. Hand-built packets live in the unit tests, not here.
