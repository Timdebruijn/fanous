<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Files, ports and the command line

Everything the engine writes, listens on or accepts from the command line,
for whoever backs up a show machine, runs a firewall, or starts a test
engine. Back to the [index](../README.md).

## Where files live

All of it is under your home folder. `FANOUS_HOME=DIR` (an absolute path)
moves every path below from `~` to `DIR`, which is how a test engine runs
next to the installed one.

### The library

| Path | What |
|---|---|
| `~/Movies/Fanous Library/` | The media library: numbered folders with numbered files. Change it under System › Machine › Library |
| `…/_incoming/` | Uploads on their way in; emptied when the ingest finishes |
| `…/NNN_name/_originals/` | The files a transcode replaced |

### Application Support

Everything below is in `~/Library/Application Support/Fanous/` (mode 0700).

| File | What | Notes |
|---|---|---|
| `project.json` | The project: patch, layer count, Who controls, canvases, outputs, walls, presets, cues, timecode and MIDI settings, universe settings | Saved 2 s after the last change; a show-lock change is written at once. A file that does not read as a project is kept as `project.json.unreadable-<time>` and the engine starts with the standard patch |
| `versions/<time>-<name>.json` | Project versions | Automatic at every engine start, on entering show mode, every 10 minutes after a change (only when the project differs from the newest version) and before a revert; the newest 50 automatic ones are kept. Named versions never expire. See System › Project versions |
| `settings.json` | Machine settings (mode 0600) | `passwords` (hashed, per role), `sync` (interface, port, target), `oscFeedback` (fixed OSC target). Unknown fields are kept. The engine rewrites it; see the hand-edit rule below |
| `shell-token` | The app window's programmer token (mode 0600) | 64 hex characters, made at first start. The app opens the UI with it, so the window is always programmer |
| `install-uuid` | This install's identity | The CITP server id and the sync machine id |
| `engine.lock` | One engine per user | Holds the engine's pid; a second `fanousd` refuses to start |
| `show-state.json`, `restart-pending` | Show mode across a crash or restart | The first is written every 30 s while show mode is on: show mode resumes after a crash or kill (on the same boot, however long ago), or after a power cut when the engine starts within two hours of the last write; a planned Restart or Shut Down of the Mac removes it. The second is written by the app right before Engine › Restart Engine and honoured for 60 s. |
| `display-modes.json` | The display modes to put back after show mode | Only while modes are switched |
| `ingest-queue.json` | The ingest queue | Survives an engine restart; done jobs leave the list after a minute |
| `cache/library-index.json`, `cache/thumbnails/*.jpg` | Media metadata and thumbnails | Keyed by path, size and modification time; a changed file is probed again |
| `tls/` | The engine's certificate and `fingerprint.sha256` | An ad-hoc build keeps the private key here (mode 0600); a signed build keeps it in the keychain. `fanousd reset-tls` makes a new one |

### Logs

| Path | What | Notes |
|---|---|---|
| `~/Library/Logs/Fanous/fanousd.log` | The engine log | Rotated once to `fanousd.log.1` when it passes 10 MB. System › Logs shows and downloads the current file only |

**Editing `settings.json` by hand.** The engine reads it at start and rewrites
it at every password or sync change, keeping fields it does not know. A record
you add while the engine runs takes effect at the next such change or at the
next start, and the file wins then: an editor that saves an older copy brings
old records back. If `passwords` is not an object, password and sync changes
are refused until you fix it; a single unreadable record keeps the passwords in
use until the next start, which would leave every role open.

```json
{
  "passwords": { "programmer": { "salt": "…", "hash": "…", "iterations": 600000 } },
  "sync": { "interface": "any", "port": 8002, "target": "broadcast" },
  "oscFeedback": { "host": "192.168.1.20", "port": 9000, "prefix": "/fanous/cue" }
}
```

**Backing up a show.** Copy `project.json`, `versions/` and `settings.json`
(passwords, sync and OSC feedback), and the library: the project and the
console only know folder and file numbers, so the spare Mac needs a library
with the same numbers. The files are written whole, so a copy while the
engine runs is safe. Do not copy `install-uuid` to another Mac (two Macs
with one id ignore each other's sync packets), nor `engine.lock`,
`show-state.json` or `shell-token` (the app window's programmer credential).
A restored Mac makes a new certificate, so every iPad warns once again.

## Ports

| Direction | Port | For | Disabled by |
|---|---|---|---|
| in | UDP 6454 | Art-Net (ArtDmx in; ArtPoll is answered with an ArtPollReply naming the patched port-addresses) | `--no-network` |
| out | UDP to the poller, from 6454 | The ArtPollReply | `--no-network` |
| in | UDP 5568 | sACN, multicast joined per patched universe; the port is shared with other receivers on the Mac | `--no-network`, or another program holding the port exclusively |
| in | UDP 8000 and TCP 8000 | OSC (TCP with SLIP framing) | `--no-network` |
| out | UDP to each subscriber's port and the fixed target | OSC feedback, bundles of at most 1200 bytes | `--no-network` |
| in | TCP 8443 | The web UI: HTTPS and the WebSocket | `--port` changes it for a hand-started engine; the installed engine and the app window always use 8443 |
| out | UDP 5353 (macOS, not `fanousd`) | Bonjour and the `.local` name; across VLANs use the address, or an mDNS reflector | |
| in and out | UDP 8002 | Multi-server sync, only with several Macs; System › Sync changes it | |
| out | UDP 4809 to 224.0.0.180 and 239.224.0.180 | CITP announcements every 5 s, TTL 1 (same subnet) | `--no-network` |
| in | TCP, a port the system picks | CITP/MSEX for consoles; shown on the CITP line of System › Network | `--no-network` |
| out | Bonjour | `_fanous._tcp` and `_https._tcp` with the port | `--no-network` |

A firewall on the Mac (Little Snitch, the macOS firewall) must allow `fanousd`
on the rows you use. The Mac and the console must be on the same subnet for
Art-Net broadcast, sACN multicast and CITP; unicast Art-Net or sACN to the
Mac's address works across subnets.

## The engine on the command line

The app starts the engine for you. The command line is for a test engine next
to the installed one, for exports, and for the certificate.

```
fanousd [--port N] [--web-root PATH] [--foreground] [--no-network] [--scene FILE]
fanousd --version
fanousd channel-map            print docs/channel-map.md
fanousd gdtf FILE              write the GDTF fixture file
fanousd reset-tls              delete the TLS key and certificate; a new one is made at the next start
fanousd protocol-dts           print the WebSocket message and command types (TypeScript)
fanousd ingest DIR OUT.mov [--fps N] [--codec prores4444|prores422hq|prores422|hap|hapalpha|hapq|hapalphaonly]
                               convert an image sequence to a movie (25 fps and ProRes 4444 by default)
```

| Flag or variable | Does |
|---|---|
| `--port N` | HTTPS port, default 8443 |
| `--web-root PATH` | The built web UI; otherwise `FANOUS_WEB_ROOT`, then the app bundle's copy, then a `web/dist` next to the source |
| `--foreground` | Accepted for scripts; the engine runs attached to the terminal either way when started by hand |
| `--no-network` | No Art-Net, sACN, OSC, CITP or Bonjour; HTTPS on 127.0.0.1 only. For tests and a second engine on one Mac |
| `--scene FILE` | A JSON scene whose canvas size, frame rate, layer count, media, Who controls and library win over the project for this run (developers; see `docs/DEVELOPMENT.md`) |
| `FANOUS_HOME=DIR` | Every path above under `DIR` instead of `~` (absolute path, else ignored with a warning) |
| `FANOUS_LOG=debug` | Debug logging |

Exit codes: 0 after SIGTERM or SIGINT, 64 for a wrong argument, 75 when
another engine of this user already runs ("fanousd is already running
(pid n)"), 1 when the engine cannot start or an export or ingest fails.

## Service and process names

| Name | What |
|---|---|
| `Fanous.app` | The app bundle; the engine is the helper `Fanous.app/Contents/Helpers/FanousEngine.app/Contents/MacOS/fanousd` (bundle id `org.fanous.engine`), the program a firewall or filter rule must name. From the terminal, with the engine stopped: `/Applications/Fanous.app/Contents/Helpers/FanousEngine.app/Contents/MacOS/fanousd reset-tls` |
| `org.fanous.engine` | The LaunchAgent the app registers; listed under System Settings › General › Login Items & Extensions as "Fanous" |
| `org.fanous.app` | The app's preference domain (`defaults delete org.fanous.app KeepEngineOnQuit` brings the quit question back) |
| `org.fanous` | The subsystem to search for in Console.app |
| "Fanous Engine" | How macOS names the engine in a Camera, Microphone or Screen Recording prompt; listed as "Fanous" in System Settings |

## Web addresses

| Address | What |
|---|---|
| `https://<mac-name>.local:8443/` | The UI. The exact host name and the addresses are under System › Network |
| `https://127.0.0.1:8443/healthz` | `{"status":"ok","version":…,"uptimeSeconds":…,"chip":…}` when the engine answers; no login needed |
| `https://…:8443/api/channel-map.md` | The channel map the Patch screen's **Channel map** opens |

The OSC address space is in [osc.md](osc.md); the HTTP endpoints, the
roles and the WebSocket protocol for integrators are in [api.md](api.md).
