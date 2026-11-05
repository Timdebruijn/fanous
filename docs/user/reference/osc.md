<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# OSC reference

Every OSC address Fanous understands and sends, with its arguments and
limits. How to use them from a controller, with Companion and TouchOSC
recipes, is in [remote-control.md](../remote-control.md#osc). The roles
named below are the UI's roles ([ui.md](../ui.md#roles-and-logging-in));
OSC itself carries no login. Back to the [index](../README.md).

## Transport

| Item | Value |
|---|---|
| Port | 8000, UDP and TCP (SLIP framing, OSC 1.1), on every interface; not configurable. Port 8001 is reserved and unused |
| Off | With `--no-network` there is no OSC listener and no feedback |
| Port in use | Logged ("OSC UDP failed"); OSC then does not work and nothing on screen says so |
| Packet size | UDP: no limit in Fanous; TCP: 64 KiB per SLIP packet, longer ones are dropped and logged |
| Bundles | Supported, nested up to 8 deep. A timetag between 1 ms and 3600 s ahead delays the contents to that time; a timetag in the past, or further ahead, runs them at once |
| Argument types | `i f s S b h d t T F N I`; messages without a type tag string (OSC 1.0) are read too |
| Matching | Addresses are matched literally; no wildcards or patterns |
| Pacing | Leave about 50 ms between messages sent back to back from one socket ([known limitations](known-limitations.md#consoles-and-protocols)) |
| Authentication | None. Parameter messages bypass the roles; the commands below run with a fixed role |
| Errors | An unreadable packet, an unknown address, a wrong argument type or an unknown key is dropped without a reply or a log line; a refused command (show mode blocked, project load under the lock) is logged, not answered |

## Control

Values for a parameter: a float (`f`, `d`) is 0 to 1 of the parameter's
raw range, times 255 for an 8-bit parameter and 65535 for a 16-bit one,
rounded; an int (`i`, `h`) is the raw value; `T` is the maximum and `F`
is 0. Out-of-range values are clamped. Only the first argument counts. The
keys are the "OSC key" column of the [channel map](../../channel-map.md).
`{n}` is 1 to the project's layer count (32 at most) for layers, 1 to 8
for outputs and keystones; other numbers are ignored. Parameter values
enter as the source "osc": the project's Who controls decides whether they
show, and they are never refused by the show lock or show mode.

| Address | Args | Does | Role |
|---|---|---|---|
| `/fanous/layer/{n}/{key}` | 1 value | Sets a layer parameter; keys: `intensity folder file playMode speed inPoint outPoint dissolve positionX positionY positionZ scaleX scaleY fitMode rotationX rotationY rotationZ red green blue brightness contrast saturation hue blendMode effect1 effect1A effect1B effect2 effect2A effect2B cropLeft cropRight cropTop cropBottom audioVolume audioPan control sync` | none |
| `/fanous/layer/{n}/media` | 2 values (folder, file) | Sets Folder and File; floats are truncated | none |
| `/fanous/layer/{n}/retrigger` | none | Restarts the media: writes `control` 8 (Retrigger) and 0 after 0.1 s, over any `control` value you set | none |
| `/fanous/master/{key}` | 1 value | Master: `intensity control testPattern speed` | none |
| `/fanous/output/{n}/{key}` | 1 value | Output n: `intensity control testPattern blend preset fade` | none |
| `/fanous/keystone/{n}/{key}` | 1 value | Keystone of output n: `topLeftX topLeftY topRightX topRightY bottomRightX bottomRightY bottomLeftX bottomLeftY` | none |
| `/fanous/cue/go` | none | The next cue | operator |
| `/fanous/cue/back` | none | The previous cue | operator |
| `/fanous/cue/goto` | 1 number (`i f h d`, or `T`/`F`) | The cue with that number (decimals work); a non-number is ignored | operator |
| `/fanous/cue/{number}/go` | none | That cue | operator |
| `/fanous/show/lock` | 1 bool-like (`i` or `f` non-zero, `T`, `F`, or an impulse `I` for true; `h` and `d` are ignored) | Locks or unlocks | programmer, also while locked |
| `/fanous/show/mode` | 1 bool-like | Enters or leaves show mode; entering is refused silently while readiness items block | operator |
| `/fanous/timecode/enable` | 1 bool-like | The timecode switch | operator |
| `/fanous/project/load` | 1 string | Restores the newest named project version with that name (case-insensitive), else the version with that id; the same version within 2 s is ignored; refused in show mode and while the show is locked | programmer |

Operator commands work while the show is locked. Nothing that names a file
or a folder on the Mac can be set or read over OSC.

## Reading state and subscribing

Requests, handled before the control addresses. All of them, unsubscribe
included, are rate-limited per sending host to 10 a second (20 in a
burst) and for all hosts together to 200 a second (400 in a burst); excess
is dropped without a reply, so pace a loop of per-layer `/get`s.

| Address | Args | Does |
|---|---|---|
| `/fanous/get` | optional port | Answers with the summary: `/fanous/engine/version`, `/fanous/show/mode`, `/fanous/show/lock`, `/fanous/show/ready`, `/fanous/cue/current`, `/fanous/engine/fps`, `/fanous/engine/missed` |
| `/fanous/{path}/get` | optional port | Answers with every readable address at or below `{path}`, sorted, at most 256 messages; no match, no reply |
| `/fanous/subscribe` | host (s), port (number 1–65535), optional prefix (s, `/fanous` or below) | Step 1: `/fanous/subscribe/confirm {cookie}` is sent to host:port. The host must be the sender's own IP address written as an address (`localhost` for the same Mac; a name fails), else `/fanous/error`. On a confirmed subscription it renews it (60 s) and adds the prefix (8 at most), without a reply |
| `/fanous/subscribe/ack` | cookie (s) | Step 2, within 5 s, from the same host: the subscription is confirmed, and every current value under its prefixes follows. A bad or late cookie gets `/fanous/error` |
| `/fanous/unsubscribe` | none, or host, port, prefix | Ends every subscription of the sending host; with arguments only the matching one, with a prefix only that prefix. A host that is not the sender's is ignored |
| `/fanous/ping` | none | Renews the sender's subscriptions (60 s); answered with `/fanous/pong` |

A subscribe with fewer than two arguments, a port out of range or a
prefix outside `/fanous` is dropped without a reply. `/fanous/error`
comes with one of three texts: "subscribe: host must be the sender's
address …", "subscribe: 16 subscribers at most" (also for too many pending
or too many prefixes) and "subscribe/ack: unknown or expired cookie, or no
free subscription". The cookie is up to 16 hexadecimal characters and can
look like a number: keep it as text.

Answers to a `/get` go back to the address and port the question came
from; over TCP, on that connection. A port argument sends them to that
port on the sender's host instead, but only once that host:port has a
confirmed subscription. A subscriber that listens on the port it sends
from (TouchOSC, or a TCP client naming its own port) is answered on that
flow, from port 8000; any other port gets a UDP connection of its own.
Answers and changes are OSC bundles with the timetag "immediately", at
most 1200 bytes each; a snapshot is at most 25 ms old.

A confirmed subscription gets every change under its prefixes: changes are
collected for 50 ms and sent together, latest value only, so an address
goes out at most 20 times a second; at most 200 messages per subscription
per 50 ms (the rest follow in the next ticks, so the first full sync of a
large project spans several ticks). Every cue go, back or go-to from any
source sends the `/fanous/cue` addresses again. A subscription lasts 60 s
and is renewed by `/fanous/subscribe` or `/fanous/ping`; at most 16 are
confirmed at once and 64 pending.

The fixed target in `settings.json` (`oscFeedback` with `host`, `port` and
an optional `prefix`, read at engine start) gets every change under its
prefix for as long as the engine runs, plus the answers to every `/get`
from anyone; it is not counted in the 16 and never expires. A prefix
outside `/fanous` makes the target ignored, with a warning in the log.

Readable addresses:

| Address | Type | Value |
|---|---|---|
| `/fanous/layer/{n}/{key}` | f | The layer parameter as applied, after Who controls, as 0 to 1 of its range (`folder` and `file` as fractions of 255: use `media`) |
| `/fanous/layer/{n}/media` | i i | Folder, file |
| `/fanous/master/{key}`, `/fanous/output/{n}/{key}`, `/fanous/keystone/{n}/{key}` | f | The same for the Master, the outputs and the keystones |
| `/fanous/output/{n}/state` | s | `bound`, `lost` or `unassigned` |
| `/fanous/output/{n}/bound` | i | 1 when the output shows on its display |
| `/fanous/cue/current` | f | The current cue's number, −1 for none |
| `/fanous/cue/current/name` | s | Its name, empty for none |
| `/fanous/cue/next` | f | The next cue's number, −1 for none |
| `/fanous/cue/next/name` | s | Its name |
| `/fanous/cue/fading` | i | 1 while a cue fades |
| `/fanous/cue/count` | i | The number of cues |
| `/fanous/show/mode` | i | 1 in show mode |
| `/fanous/show/lock` | i | 1 while the show is locked |
| `/fanous/show/ready` | i | 1 when no readiness item blocks show mode |
| `/fanous/timecode/enable` | i | 1 when the timecode switch is on |
| `/fanous/timecode/state` | s | `off`, `locked`, `freewheel` or `lost` |
| `/fanous/timecode/value` | s | `hh:mm:ss:ff` (`hh:mm:ss;ff` for drop frame), or `--:--:--:--` while off |
| `/fanous/engine/version` | s | The Fanous version |
| `/fanous/engine/fps` | f | Frames rendered in the last second |
| `/fanous/engine/missed` | i | Frames missed in the last second |

Outgoing addresses besides these: `/fanous/subscribe/confirm {cookie}`,
`/fanous/pong`, `/fanous/error {text}`. Fanous sends no other OSC.
