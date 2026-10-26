<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Getting started

## Install

1. Copy `Fanous.app` to the Applications folder (drag it from the disk image
   `Fanous-<version>.dmg`).
2. Open it. Until a notarized build exists (backlog B50), macOS may refuse the
   first open; allow it in System Settings › Privacy & Security.

`Fanous.app` holds two programs: the window you see (the shell) and
`fanousd`, the engine. The engine does all the work: DMX, decoding, outputs,
the web UI server. The shell only shows the web UI in a window.

## First launch

The app registers the engine as a background service (a LaunchAgent named
`org.fanous.engine`). macOS wants your approval **once**:

1. A dialog says "Allow Fanous to run its engine in the background". Click
   **Open System Settings** (or choose Later and do it by hand).
2. Open System Settings › General › Login Items & Extensions.
3. Under "Allow in the Background", switch Fanous on.

After that the engine starts at login and macOS restarts it within about a
second if it ever crashes. **Quitting the app does not stop the engine** unless
you choose so; the outputs keep running. Auto-login is your choice for an unattended machine; it
is not required.

macOS may also ask for Local Network access (Fanous receives Art-Net, sACN
and OSC and announces itself over CITP) and, when you first pick an LTC input,
for the Microphone. Allow both. Neither prompt has been tested on a clean
install yet (B50, B37).

## Firewall

If the Mac runs Little Snitch or another firewall, allow `fanousd`:

| Direction | Protocol, port | For |
|---|---|---|
| in | UDP 6454 | Art-Net |
| in | UDP 5568 | sACN |
| in | UDP and TCP 8000 | OSC |
| in | TCP 8443 | web UI (HTTPS and WebSocket) |
| out | UDP to 224.0.0.180 and 239.224.0.180, port 4809 | CITP announcements |

The CITP server also listens on a TCP port the system picks; System › Network
shows it on the CITP line. Bonjour (`_fanous._tcp`) is advertised as well.

## The main window

The window is a normal browser view of the web UI. Menus:

- **Engine**: the first line shows the state, for example "Engine 1.0.0-rc.1
  running · service installed" (or "service needs approval in Login Items").
  **Reload UI** (Cmd-R) reloads the page. **Start Engine**, **Restart Engine**
  and **Stop Engine…** control the service. Stop removes the service
  registration, so outputs go black until the next start. **Open Logs** opens
  `~/Library/Logs/Fanous` in Finder.
- **Edit**: Undo and Redo, Cut, Copy, Paste.

Closing the window quits the app. When the engine is running, the app asks
"Quit Fanous?" first:

- **Keep Engine Running** (the default, Return): the app quits, the outputs
  keep running.
- **Stop Engine and Quit**: the same as Engine › **Stop Engine…**, then quit.
- **Cancel**: nothing happens.

Tick **Don't ask again** with Keep Engine Running to quit without the question
from then on (`defaults delete org.fanous.app KeepEngineOnQuit` brings it
back). Stopping is never remembered. When the engine is not running, the app
quits without asking.

The **status bar** is on every screen. From the left: the lock tag (UNLOCKED or
LOCKED; press it or L), the **SHOW MODE: ON/OFF** button (operator; when the
readiness checks refuse, a small popover under it lists what blocks, with a
link to System), frames per second with GPU and CPU timing, dropped frames over the
last second, one pill per DMX universe (green = receiving), the timecode
readout and state, outputs on or off, ingest progress, connected clients, a
yellow "web UI open" notice while the programmer role has no password, and on
the right Undo, Redo, **?** (keyboard shortcuts) and your role. Red means look now: dropped frames or a
lost timecode or output while the show is locked, a patched universe that went
silent.

Refused commands show a yellow banner with the next step ("Show lock is on:
press L or the LOCKED tag to unlock", "Not allowed for this role: log in as
programmer"). It disappears after 10 seconds; **Recent messages** on the banner
lists the last 20.

The Layers screen header says "tier allows N layers". The tier is the
performance class of this Mac's chip (System shows the chip); N is the number of
layers it plays without dropping frames, measured with the benchmark. **Add
layer** on the Patch screen stops at N so a show cannot be built that the
machine cannot play. Each layer row shows its state as a word next to the
dot (OK, LIVE, NO MEDIA, MISSING FILE, DECODER ERROR).

## Open the UI from an iPad or another computer

Browse to `https://<mac-name>.local:8443`. The exact host name, the IP
addresses and the port are under System › Network (Host, Addresses, Port,
Bonjour). Fanous only advertises `_fanous._tcp`, so it will not show up in a
browser's Bonjour list (B39); type the address.

The engine makes its own certificate the first time it runs, so the browser
shows a certificate warning once:

1. On the Mac open System › Network and read the **TLS fingerprint** (SHA-256).
2. In the browser's warning, check that the fingerprint matches, then continue
   to the site. (The Copy button next to it may not work in every context; you
   can select the text.)

The preview on the Layers screen uses H.264 through WebCodecs. If the browser
cannot decode it, the preview falls back to JPEG at 5 frames per second. This
works on an iPad in Safari.

If you ever reset the certificate (`fanousd reset-tls`), the fingerprint
changes and every browser warns again.

## Roles and passwords

| Role | Can do |
|---|---|
| monitor | Look. No commands. |
| operator | Cues (Go, Back, Go to), show mode on or off, run the readiness checks |
| programmer | Everything: patch, media, outputs, cues editing, passwords, show lock |

DMX from the console (blackout, test patterns, everything else) does not depend
on roles.

By default no role has a password, so anyone who can reach the address is
programmer, and the status bar says "web UI open". **Set a programmer password
before the show**: System › Roles and passwords, type the new password for
the role, press **Set**. **Clear** removes it again, and the role is open.

A role without a password is open to everyone who can reach the address; each
role is open or protected on its own. A browser gets the highest role it asks
for that it is entitled to. To change role click the role name at the right of
the status bar, pick the role, enter its password and press **Log in**; **Log
out** drops the session. After five wrong attempts in a minute you must wait.

The app window on the Mac itself is always programmer; it needs no password.

## Where files live

| What | Where |
|---|---|
| Media library | `~/Movies/Fanous Library` |
| Project (patch, outputs, cues, timecode settings) | `~/Library/Application Support/Fanous/project.json` |
| Machine settings, role passwords (hashed) | `~/Library/Application Support/Fanous/settings.json` |
| Certificate and fingerprint | `~/Library/Application Support/Fanous/tls/` |
| Thumbnail and metadata cache | `~/Library/Application Support/Fanous/cache/` |
| Ingest queue | `~/Library/Application Support/Fanous/ingest-queue.json` |
| Logs | `~/Library/Logs/Fanous/fanousd.log` |

The project is saved automatically two seconds after your last change. Back it
up by copying `project.json`.
