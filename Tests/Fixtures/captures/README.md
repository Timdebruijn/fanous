# Protocol captures

Raw UDP payloads (one datagram per `.bin`) recorded with
`scripts/capture-dmx.py` from real console software, plus their provenance in
the `.txt` next to them. `CaptureTests` parses every file here; a capture that
stops parsing is a regression.

| Directory | Source software | Notes |
|---|---|---|
| `artnet/qlcplus-universe1-*` | QLC+ 5.3.0 (macOS), ArtNet output plugin, universe 1 → Art-Net 0.0.0, unicast to 127.0.0.1 | one ArtPoll QLC+ sends on its own, then ArtDmx frames with consecutive sequence numbers; channels 1–5 and 512 set over the QLC+ web API (`CH\|n\|value`) |
| `artnet/qlcplus-poll-*` | QLC+ 5.3.0 | ArtPoll from QLC+ and ArtDmx frames; QLC+ does not answer ArtPoll (it is a controller, not a node) |
| `sacn/sacnview-universe1-*` | sACNView 3.1.0 (macOS), Transmit window, universe 1, priority 100, 512 slots | ratified E1.31 data packets, source name "sACNView", consecutive sequence numbers, all slots 0 |
| `sacn/sacnview-universe1-full-*` | sACNView 3.1.0 | same source with channels 1–512 at 255 |
| `osc/` | — | no real OSC sender available yet; OSC fixtures are the hand-built packets in `OSCTests` |

Not captured yet (needs software that is not installed or cannot run offline): sACN sync and universe-discovery packets, ArtPollReply from a real node, CITP/MSEX (MagicQ), consoles with hardware keys (Eos Nomad). Phase 7 adds those.

Capturing: stop `fanousd` (it binds the same ports), run
`scripts/capture-dmx.py artnet <name> --note "QLC+ 5.3.0, universe 1, …"`,
then make the console send. Hand-built packets live in the unit tests, not here.
