<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# REST and WebSocket API

For integrators: what the engine serves over HTTPS, how a client logs in,
and the WebSocket protocol the web UI itself uses, with every command. OSC
is [OSC reference](osc.md); files, ports and the command line are
[Files, ports and the command line](files-and-ports.md). Back to the [index](../README.md).

For parameters, prefer OSC: an OSC parameter message needs no role, is
never refused and never expires, while `fixture.set` over the WebSocket
is the programmer's, refused while the show is locked, and expires after
10 minutes of masking a live console like a UI value.

## Transport

| Item | Value |
|---|---|
| Port | 8443, HTTPS and WSS on one TCP port, on every interface; `fanousd --port N` changes it (the app window always opens 8443); `--no-network` binds 127.0.0.1 only |
| TLS | TLS 1.2 or newer, a self-signed ECDSA P-256 certificate made at first start, valid 10 years, for `localhost`, the host name, `<host>.local`, `127.0.0.1`, `::1` and the Mac's IPv4 addresses at that time. The certificate is `~/Library/Application Support/Fanous/tls/certificate.der`, its SHA-256 in `fingerprint.sha256` next to it (lowercase hex, no colons) and on System › Network; `fanousd reset-tls` makes a new one. A client pins the fingerprint or accepts the certificate once |
| Discovery | Bonjour `_fanous._tcp` (TXT `port`, `v`) and `_https._tcp` (TXT `path`, `port`) under the host name (not with `--no-network`) |
| Requests | HTTP/1.1; request head at most 16 KiB; a body at most 1 MiB, except an upload, which streams to disk |
| Headers | `Server: fanousd/<version>` and `X-Content-Type-Options: nosniff` on every answer; no CORS headers, so a browser page from another origin cannot read the answers |
| Origin | The WebSocket upgrade answers 404 when the request's `Origin` host does not match its `Host`; native clients without an Origin pass |
| Shapes | `fanousd protocol-dts` prints the message and command types as TypeScript, generated from the engine's own registry; the same file is `web/src/lib/protocol.d.ts` in the source |

## Roles and logging in

Three roles, monitor < operator < programmer, each with an optional
password set on the System screen. A role without a password is open to
anyone who reaches the port; a new install has no passwords at all
([The user interface](../ui.md#roles-and-logging-in)). A client is one of three things:

| Credential | Gives | How |
|---|---|---|
| The shell token | programmer | 64 hex characters in `~/Library/Application Support/Fanous/shell-token` (mode 0600), on the Mac only. REST: `Authorization: Bearer <token>`; WebSocket: `token` in the `hello` message. A wrong token is ignored, not refused |
| A session cookie | The role logged in | `POST /api/login` with `{"role": "operator", "password": "…"}` answers 204 and sets `fanous_session` (24 hours, in memory, gone at an engine restart). 401 for a wrong password, 400 for a bad body; 5 attempts a minute per address, then 429. A WebSocket client sends the cookie on the upgrade request: `Cookie: fanous_session=…`; `hello` has no password field |
| Nothing | Every open role | |

A client that asks for a role gets the highest role it is entitled to at or
below it; it fails only when none is. REST answers 403 with a plain-text
body when the role is missing; the WebSocket answers `authRequired` and
closes with code 4401. Documents are redacted per role: the library root
and the ingest jobs, the host name and the addresses from operator; Bonjour
and the TLS fingerprint from programmer.

## REST

| Route | Method | Role | Does |
|---|---|---|---|
| `/healthz` | any | none | `{"status":"ok","version":"…","uptimeSeconds":N,"chip":"…"}` |
| `/metrics` | any | none | The last second as JSON: `frames`, `missed`, `late`, `textureMisses`, `cpuMsP50`, `cpuMsP99`, `cpuMsMax`, `gpuMsP50`, `gpuMsP99`, `gpuMsMax`, `dmxToPhotonMsP50`, `dmxToPhotonMsP99`, `dmxSamples`, `windowSeconds`, `clients`, `lagging`, `showMode`, `uptimeSeconds`, `totalFrames`, `totalMissed`, `totalLate`, `pid`, and when present `completionWaits`, `gpuErrors`, `audio`, `sync`, `preview` |
| `/api/metrics` | any | none | The 10-second summary as text |
| `/api/live` | any | none | Every universe, fixture value with its source, policy and UI expiry; exposes the DMX senders' addresses |
| `/api/patch` | any | none | The patch as JSON |
| `/api/session` | any | none | `{"role": "<role>" or null, "open": [...]}`; the role comes from the cookie only, not from a token ([known limitations](known-limitations.md#the-web-ui-and-security)) |
| `/api/login`, `/api/logout` | POST | none | Log in to a role (above); log out drops the cookie |
| `/api/logs` | any | programmer | The last 64 KiB of `~/Library/Logs/Fanous/fanousd.log`; `?download=1` sends the whole file |
| `/api/gdtf` | any | none | `Fanous.gdtf` for the console |
| `/api/channel-map.md`, `/api/channel-map.json` | any | none | The channel map as Markdown or JSON (`footprints`, `modes`, `fixtures`; per fixture mode: name, key, channel, bits, default, group, unit, bands) |
| `/api/library` | any | none; full from operator | `{root, rootExists, folders: [{number, name, path, items: [{folder, file, name, path, kind, status, reason, metadata, thumbnail, modified, size}]}], scannedAt, fileCount, invalidCount}`; `kind` is movie, still, sequence or other, `status` playable, needsTranscode, invalid, unreadable or probing, `thumbnail` the file name for `/api/thumbnail/` or null until made. Below operator the root is empty and the paths relative |
| `/api/library/rescan` | any | none | Rescans the disk |
| `/api/library/folder` | POST | programmer | `{"number": 1–255, "name": "…"}` makes `NNN_name` under the root; 200 with the name, 409 when the number exists |
| `/api/thumbnail/<name>.jpg` | any | none | A thumbnail, `name` from the library item; 404 when there is none; cached a day |
| `/api/ingest` | GET | operator | The ingest jobs: `{id, source, destination, kind, state, originalsDirectory, deleteSource, createdAt, finishedAt}` each, plus `originalMovedTo` when a transcode in place moves the original to `_originals/` (the path it goes to) |
| `/api/ingest` | POST | programmer | `{"source": "<absolute path>", "folder": 1–255, "file"?, "name"?, "codec"?, "fps"?, "keepOriginal"?}`: queues a transcode; `codec` is `prores4444`, `prores422hq`, `prores422`, `hap`, `hapalpha`, `hapq` or `hapalphaonly` (unknown falls back to ProRes 422 HQ, or 4444 for a sequence); `fps` 1–240 applies to a folder source (an image sequence); a still is kept as it is. `keepOriginal` is true unless you say false, and false deletes the source after success. 202 with the job, 404 when the source is missing, 409 when the folder is full |
| `/api/ingest/<id>/cancel`, `/api/ingest/<id>/remove` | POST | programmer | 200 "cancelled" or "removed"; 404 for a malformed id |
| `/api/upload/<folder>/<name>` | PUT | programmer | The body is the file: it lands in `_incoming` and is queued into the folder with the next free number, without the original kept; 202 with the job |

Reads need no login except `/api/logs` (programmer) and `GET /api/ingest`
(operator); every POST and PUT needs programmer except login, logout and
rescan.

## WebSocket

`wss://<host>:8443/ws`. Text frames carry JSON messages with a `t` field;
binary frames carry streams. The first message must be `hello`; the
server answers `welcome` with both documents, then sends `patch` messages
as they change. Everything the web UI does goes through this protocol, so
anything the UI can do a client can do.

```mermaid
sequenceDiagram
  participant C as Client
  participant F as Fanous /ws
  C->>F: hello {schema: 1, clientId, role?, token?}
  F-->>C: welcome {role, rev, project, live, caps}
  C->>F: cmd {id, name, args}
  F-->>C: patch {rev, doc: "project", ops} (to every client, when the project changed)
  F-->>C: ack {id, ok: true, rev, result}
  loop every 50 ms while live values change
    F-->>C: patch {rev, doc: "live", ops}
  end
  C->>F: sub {stream: "preview", codec: "avc", target: "canvas", w: 640}
  F-->>C: sub {id, stream, codec, w, h, fps, target, fallback}
  F-->>C: stream {id, codec, description, w, h, fps, fallback}
  F-->>C: binary [kind][streamId][payload] frames
  C->>F: unsub {id}
```

A session, from a shell on the Mac:

```bash
curl -sk https://127.0.0.1:8443/healthz
```

```text
→ {"t":"hello","schema":1,"clientId":"my-script","role":"programmer","token":"<shell-token>"}
← {"t":"welcome","role":"programmer","rev":812,"project":{…},"live":{…},"caps":{"schema":1,"version":"1.0.0","chip":"Apple M1 Pro","maxLayers":32,"fps":60}}
→ {"t":"cmd","id":"1","name":"cue.go","args":{}}
← {"t":"ack","id":"1","ok":true,"rev":812,"result":null}
→ {"t":"cmd","id":"2","name":"cue.add","args":{"number":4,"name":"Encore","fade":2,"values":[{"fixture":"Layer 1","parameter":"intensity","raw":65535}],"trigger":"00:12:30:00@25"}}
← {"t":"patch","rev":813,"doc":"project","ops":[{"op":"add","path":"/cues/3","value":{"id":"4E3B…","number":4,"name":"Encore","fade":2,"values":[{"fixture":"Layer 1","parameter":"intensity","raw":65535,"fade":null}],"trigger":"00:12:30:00@25","follow":null}}]}
← {"t":"ack","id":"2","ok":true,"rev":813,"result":"4E3B…"}
```

| Message | Direction | Fields |
|---|---|---|
| `hello` | to Fanous | `schema` (1), `clientId` (free text, shown in the logs), `role` (monitor, operator or programmer; monitor when absent), `token` (the shell token). The role granted is fixed for the connection |
| `welcome` | from Fanous | `role`, `rev`, `project`, `live` (both redacted for the role), `caps` (`schema`, `version`, `chip`, `maxLayers`, `fps`) |
| `snapshot` | both | To Fanous: asks for the documents again. From Fanous: `rev`, `project`, `live` |
| `cmd` | to Fanous | `id` (echoed back), `name`, `args` (an object; `{}` when absent). Without `name` the ack says `badMessage` |
| `ack` | from Fanous | `id`, `ok`; on success `rev` and `result` (null when the command returns nothing); on failure `error` with `code` and `message` |
| `patch` | from Fanous | `rev`, `doc` (`project` or `live`), `ops` (RFC 6902 add, remove and replace with RFC 6901 paths, `~0` and `~1` escaped). Project patches go out at once on every change; live patches are collected and sent every 50 ms, latest value per path. An array that changed length is replaced whole |
| `sub` | to Fanous | `stream`: `dmx` with `universe` (`artnet:0.0.1` or `sacn:1`); `preview` with `codec` (`avc` or `jpeg`), `target` (`canvas`, `canvas:2`, `output:1`, `layer:3`) and `w` (160–1280, rounded up to 320, 640, 960 or 1280); or `thumbs`. No role is needed beyond `hello` |
| `sub` | from Fanous | The stream's `id` and what it delivers: for dmx the `universe`; for a preview `codec`, `w`, `h` (the real encoded size), `fps`, `target` and `fallback` (true when the request was served from another stream or as JPEG at the encoder limit); for thumbs `w` 160 and `fps` 4. A universe that does not parse is accepted and sends nothing |
| `stream` | from Fanous | For an H.264 preview: `id`, `codec` (`avc1.…`), the `description` (avcC, base64), `w`, `h`, `fps`, `fallback`; sent before the first frame and when the description changes |
| `unsub` | to Fanous | `id`; no reply |
| `error` | from Fanous | `code` and `message`; with `id` and `stream` for a refused subscription, with `id` alone when a stream went away |

Binary frames: `[u8 kind][u32 stream id][payload]`, every multi-byte
number big-endian. Kind 1 is an H.264 access unit (`[u8 key frame][u64
timestamp in µs][AVCC data]`), kind 2 a JPEG (for thumbs: `[u8 layer,
1-based][u16 width][u16 height][JPEG]`, size 0 when the layer shows
nothing; every layer comes in the one thumbs stream), kind 3 the 512 slot
bytes received for a DMX universe, every 50 ms, with no universe inside:
map frames to universes by stream id. At most 4 H.264 encoders run at
once, shared by every viewer of the same target and size; beyond that a
viewer gets an existing stream or JPEG at 5 fps.

### The documents

`project` is what the project file holds: `name`, `showLock`,
`layerCount`, `policy`, `patch`, `library.root`, `canvases`, `layerCanvas`,
`outputs` (with `presets`), `walls`, `universes`, `cues`, `timecode`,
`midi` (with `map`), `syphon`, `capture`, `screens`, `ui`. The ids that
`cue.set`, `cue.remove` and `midi.map.remove` take are in there. `live` is
what changes by itself: `displays`, `outputs` (state, mode note, preset and
keystone badges), `cue` (`current`, `currentName`, `next`, `nextName`,
`fading`, `count`), `show` (mode, readiness), `timecode`, `osc` (recent
commands, MIDI sources), `midi`, `audio`, `capture`, `syphon`, `citp`,
`sync`, `library`, `ingest`, `versions`, `system`, `engine`, `security`,
`metrics`, `layers` and the DMX parts. It is rebuilt every 100 ms and sent
every 50 ms, so a fixture value arrives about 10 times a second.

### Revisions and reconnecting

`rev` is one counter for both documents: it goes up by one on every
project change and every live flush, and every client gets every patch,
also an empty one after redaction. A gap in `rev` means a missed patch:
send `snapshot` and start again from its documents. Only live patches are
dropped silently (the client is lagging, more than 256 KiB queued); a
refused project patch, or a queue past 1 MiB, closes the connection with
code 1008. `ack.rev` is the revision after the command; a live flush in
between can put it above the project patch's. The counter starts at 0
when the engine starts: after a reconnect, take the new `welcome` and
throw the old state away. Nothing resumes: a new connection means a new
`hello`, a full `welcome`, and every `sub` again. The engine answers
pings and sends none, so a client that needs liveness pings itself.

Other close codes: 1002 protocol error or wrong schema, 1007 invalid text,
1009 message too large (16 MiB), 4401 auth required. Error codes in an
`ack`: `unknownCommand`, `forbidden` (the role is below the command's),
`showLocked` (the command changes the configuration and the show is
locked), `showMode` (refused in show mode), `notReady` (show mode blocked
by readiness items), `invalidArgs`, `nothingToUndo`, `historyConflict`,
`notFound`, `corrupt`, `liveChanged`, `ingestBusy`, `failed`,
`badMessage`. In a message: `badMessage`, `helloFirst`, `schema`,
`authRequired`, `badStream`, `noPreview`, `badTarget`.

Undo and redo are global: 500 steps, and edits of the same path from the
same connection within a second are one step. Commands marked not undoable
are never recorded.

## Commands

The minimum role, whether the show lock refuses the command, and whether
Undo records it. Every command below the programmer's level also works
while the show is locked. A fixture is written `Layer n`, `Master`,
`Output n` or `Keystone n`; a universe `artnet:<net>.<subnet>.<universe>`
(0–127, 0–15, 0–15) or `sacn:<1–63999>`; a path is a JSON pointer.

| Command | Args | Does | Role | Lock | Undo |
|---|---|---|---|---|---|
| `canvas.add` | `width, height, fps?, name?` | Adds a canvas (4 at most, together at most 4 × 3840 × 2160; even sizes 320–8192; fps 23.976, 24, 25, 29.97, 30, 50, 59.94 or 60); refused in show mode; returns the id | programmer | refused | yes |
| `canvas.remove` | `id` | Removes a canvas (not 1); its layers and slices move to Canvas 1; refused in show mode | programmer | refused | yes |
| `canvas.set` | `id, path: /name or /clockMaster, value` or `id, width, height, fps` | Name, clock master, or size and rate (on Canvas 1 for every canvas; outputs blank briefly; refused in show mode) | programmer | refused | yes |
| `capture.authorize` | `kind: camera, screen or microphone` | Asks macOS for the permission; refused in show mode | programmer | refused | no |
| `capture.forget` | `file?` | Frees the number of a capture device (1–20) or display (21–28) that is not running, or of every one | programmer | refused | yes |
| `capture.renumber` | `file, to` | Moves a device or display to another number in its range; a taken one swaps; refused in show mode | programmer | refused | yes |
| `cue.add` | `number, name, fade?, values?, trigger?, follow?` | Adds a cue and returns its id. A value is `{fixture, parameter, raw, fade?}` with `parameter` an OSC key and `raw` 0 to the parameter's maximum; `fade` and `follow` are seconds; the trigger is `hh:mm:ss:ff@rate` with the rate written `24`, `25`, `29.97 DF`, `29.97 NDF` or `30`, and a trigger that does not parse is stored and never fires. A number in use fails with `invalidArgs` | programmer | refused | yes |
| `cue.set` | `id, cue` | Replaces a cue by id; `cue` is the stored shape `{id, number, name, fade, values, trigger, follow}` | programmer | refused | yes |
| `cue.remove` | `id` | Removes a cue and releases what it held | programmer | refused | yes |
| `cue.go`, `cue.back` | none | The next or previous cue | operator | allowed | no |
| `cue.goto` | `number` | That cue | operator | allowed | no |
| `fixture.set` | `fixture, parameter, raw` | Sets a parameter from the UI | programmer | refused | no |
| `fixture.release` | `fixture?` | Drops the UI and MIDI values of one fixture, or all | programmer | allowed | no |
| `fixture.keep` | `fixture` | Restarts the 10-minute expiry of a fixture's UI values | programmer | refused | no |
| `layer.set` | `layer, canvas` | The canvas a layer renders into | programmer | refused | yes |
| `layers.setCount` | `count` | The number of layers, 1 to 64 accepted; only the first 32 exist: layers 33 to 64 are not rendered | programmer | refused | yes |
| `midi.set` | `source?, mscDevice?, mscFormat?` | The MIDI source (null for all), the MSC device id (0–111) and format (0–127, null for video 0x30–0x3F) | programmer | refused | yes |
| `midi.map.set` | `id?, source?, channel, kind: note, cc, cc14 or pc, number?, target, cue?, curve?, pickup?, low?, high?` | Adds or replaces a map entry and returns its id. `channel` 0 is any; `number` 0–127 (cc14: the coarse controller 0–31), null for any program; `target` is `cue.go`, `cue.back`, `cue.goto` (with `cue`, or none for program + 1 with kind pc) or `fixture:<Layer n or Master or Output n>/<key>`; `curve` `linear` or `toggle`; `low` and `high` 0 to 1 of the range (the panel has no fields for them) | programmer | refused | yes |
| `midi.map.remove` | `id` | Removes a map entry | programmer | refused | yes |
| `midi.learn` | `target?, cue?` | Maps the next note, controller or program change to the target; no target cancels | programmer | refused | no |
| `output.add` | `display?: {uuid, name}` | Adds an output, optionally bound; its Output fixture is patched next to the Master when free | programmer | refused | yes |
| `output.remove` | `id` | Removes an output (not a wall member) and unpatches its fixtures | programmer | refused | yes |
| `output.set` | `id, path, value` | One value inside an output by JSON pointer: `/name`, `/display`, `/region`, `/mode`, `/intensity`, `/blend/*`, `/warp/*`, `/slices/*`, `/testPattern`, `/color/*` | programmer | refused | yes |
| `output.pattern` | `patterns: [{id, pattern}]` | The wizard's and seam check's test patterns, a 5-second lease the UI renews every 2 s; pattern 0 ends it; refused in show mode except to end | programmer | refused | no |
| `output.overlay` | `id, on, selected?` | Show on output, a 5-second lease; refused in show mode except to end | programmer | refused | no |
| `output.show` | `ids, preset` | Hold to compare, a 5-second lease on outputs 1–8; preset 0 ends it; refused in show mode | programmer | refused | no |
| `output.preset.store` | `ids, number, name?` | Stores the warp and slices of each output as preset 1–255; an existing number is replaced | programmer | refused | yes |
| `output.preset.recall` | `ids, number` | Copies the preset into each output's mapping | programmer | refused | yes |
| `output.preset.rename` | `ids, number, name` | Renames it (1–64 characters) | programmer | refused | yes |
| `output.preset.remove` | `ids, number` | Removes it | programmer | refused | yes |
| `patch.set` | `fixture, universe, address` | Patches a fixture (address 0 unpatches); layers up to the layer count, outputs and keystones 1–8 | programmer | refused | yes |
| `patch.setMany` | `entries` | Several in one step; one bad entry refuses all | programmer | refused | yes |
| `project.set` | `path, value` | One project value: `/name`, `/policy` (`dmx`, `internal`, `ltp`, `htp`), `/library/root`, `/ui/…` | programmer | refused | yes |
| `project.snapshot` | `name?` | Saves a version now; named ones never expire | programmer | allowed | no |
| `project.versions` | none | Lists the versions, newest first: `id`, `at` (epoch seconds), `name`, `automatic`, `layers`, `outputs`, `canvases`, `cues` | monitor | allowed | no |
| `project.revert` | `id` | Restores a version (the current project is saved first); refused in show mode | programmer | refused | yes |
| `project.deleteVersion` | `id` | Deletes a named version | programmer | refused | no |
| `readiness.run` | none | Runs the readiness checks | operator | allowed | no |
| `readiness.acknowledge` | `id` | Acknowledges a failed item so show mode can start | programmer | allowed | no |
| `roles.setPassword` | `role, password or null` | Sets or clears a role's password | programmer | refused | no |
| `show.lock`, `show.unlock` | none | The show lock | programmer | allowed | no |
| `show.mode` | `on` | Enters or leaves show mode; refused with the blocking items | operator | allowed | no |
| `sync.set` | `interface?, port?, target?` | The sync settings; refused in show mode | programmer | refused | no |
| `syphon.forget` | `file?` | Frees a Syphon number (150–169) | programmer | refused | yes |
| `syphon.renumber` | `file, to` | Moves a Syphon server to another number; refused in show mode | programmer | refused | yes |
| `timecode.set` | `path, value` | `/source` (`off`, `ltc`, `mtc`), `/device`, `/channel` (0-based), `/offset` (frames), `/freewheel` (s), `/layerOffsets/<n>` (frames) | programmer | refused | yes |
| `timecode.enable` | `on` | The timecode switch | operator | allowed | no |
| `universe.set` | `id, path, value` | `/protocol` (`artnet`, `sacn`, `both`), `/interface`, `/holdOnLoss` (`hold`, `zero`, `internal`), `/lossTimeout` (1–60 s), `/sacnPriorityMode` (`highest`, `htp`), `/pair` | programmer | refused | yes |
| `wall.add` | `cols, rows, outputs, overlap: {x, y}, canvas?, fit: canvas or makeCanvas, name?` | Makes a projector wall (1–4 by 1–4, at least 2 outputs, overlap 0–0.5 of a projector); returns the id | programmer | refused | yes |
| `wall.set` | `id, cols?, rows?, outputs?, overlap?, canvas?, name?, fit?, resetManual?` | Changes a wall's geometry and compiles it again | programmer | refused | yes |
| `wall.seam` | `id, a, b, power?, gamma?, gammaRGB?` | Tunes one seam | programmer | refused | yes |
| `wall.seams` | `id, power?, gamma?, gammaRGB?` | Tunes every seam | programmer | refused | yes |
| `wall.remove` | `id` | Removes a wall; its outputs stay | programmer | refused | yes |
| `undo`, `redo` | none | The global history | programmer | refused | no |

## Limits

| Limit | Value |
|---|---|
| Login attempts | 5 a minute per address |
| Session | 24 hours, in memory |
| WebSocket clients | No cap; `/metrics` counts them and the lagging ones |
| Live patches | Every 50 ms, latest value per path; the live document is rebuilt every 100 ms |
| DMX stream | One 512-byte frame per subscription every 50 ms |
| H.264 preview encoders | 4 in total, shared per target and size; the preview width is 160–1280 in four classes |
| Undo history | 500 steps |
| Layers | 32 exist (`caps.maxLayers`); `layers.setCount` accepts up to 64, but 33 to 64 are not rendered |
| Canvases | 4, together at most 4 × 3840 × 2160 pixels |
| Library folders and file numbers | 1–255 |
