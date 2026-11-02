<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Getting started

## Install

1. Copy `Fanous.app` to the Applications folder (drag it from the disk image
   `Fanous-<version>.dmg`).
2. Open it. A notarized build passes the Gatekeeper check (`spctl`, checked
   for 1.0.0-rc.1); a real first open on a clean account is not tested yet
   (backlog B50). A build signed ad hoc (`scripts/bundle.sh` without
   `CODESIGN_IDENTITY`) may be refused at first open; allow it in System
   Settings › Privacy & Security.

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
you choose so; the outputs keep running. Auto-login is your choice for an
unattended machine; it is not required.

macOS may also ask for Local Network access (Fanous receives Art-Net, sACN
and OSC and announces itself over CITP) and, when you first pick an LTC input,
for the Microphone. Allow both. The microphone prompt was checked on the
notarized build; neither prompt has been tested on a clean account yet (B50).

## Firewall

If the Mac runs Little Snitch or another firewall, allow `fanousd`:

| Direction | Protocol, port | For |
|---|---|---|
| in | UDP 6454 | Art-Net |
| in | UDP 5568 | sACN |
| in | UDP and TCP 8000 | OSC |
| in | TCP 8443 | web UI (HTTPS and WebSocket) |
| in and out | UDP 8002 (System › Sync) | multi-server sync, only with several Macs |
| out | UDP to 224.0.0.180 and 239.224.0.180, port 4809 | CITP announcements |

The CITP server also listens on a TCP port the system picks; System › Network
shows it on the CITP line. Bonjour (`_fanous._tcp` and `_https._tcp`) is
advertised as well.

## The main window

![The Layers screen in the app window, with numbered parts](images/main-window.png)

The window is a normal browser view of the web UI, the same page an iPad or
another computer opens. Every screen has the same frame:

1. The **status bar**: lock, show mode, frame timing, DMX universes, outputs,
   versions, clients, Undo and Redo, the shortcut list and your role (below).
2. The **rail**: the seven screens, also on the keys 1 to 7. Below 1100 px wide
   only the icons show; hover a screen for its name and key.
3. On the Layers screen, one strip for the **Master** (intensity, speed,
   control, test pattern) and one per **Output** fixture (intensity, control,
   test pattern, blend), each with **Select** to edit it.
4. One **row per layer**: a live picture, what it plays, the position in the
   clip, intensity, play mode, audio, who controls it and its state.
5. The **preview**: the whole canvas, or only the selected layer (**This
   layer**).
6. The **layer panel** of the selected layer: every DMX channel with its value
   and where it came from, and **Control** to set values from the screen (see
   [Controlling layers from the UI](show-control.md#controlling-layers-from-the-ui)).

Menus of the app window:

- **Fanous**: About, Hide, Quit.
- **Engine**: the first line shows the state, for example "Engine 1.0.0-rc.1
  running · service installed" (or "service needs approval in Login Items").
  **Reload UI** (Cmd-R) reloads the page. **Start Engine**, **Restart Engine**
  and **Stop Engine…** control the service. Stop removes the service
  registration, so outputs go black until the next start. **Open Logs** opens
  `~/Library/Logs/Fanous` in Finder.
- **Edit**: Undo and Redo, Cut, Copy, Paste, Select All.
- **Window**: Minimize, Zoom.

In the app window, **Export GDTF** and **Download** (logs) open a macOS save
dialog; in a browser they download as usual.

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

### The status bar

![The status bar: lock, show mode, timing, universes, outputs, versions, clients](images/status-bar.png)

The status bar is on every screen. From the left:

| Item | What it says |
|---|---|
| **UNLOCKED** / **LOCKED** | The show lock; press it or L (programmer) |
| **SHOW MODE: ON/OFF** | Show mode (operator). When the readiness checks refuse, a popover under it lists what blocks, with **Open System**. After the engine restarted while show mode was on, "Show mode resumed after the engine restarted at HH:MM" appears next to it, as a link to System |
| fps, ms | Frames per second, GPU p99 and CPU time; "no outputs rendering: add or assign one (Outputs)" while nothing renders |
| dropped · 1 s | Missed and late frames over the last second |
| One pill per universe | Green: receiving. Yellow: never received ("silent"), quiet for up to 2.5 s, or quiet but not in the patch. Red: a patched universe that received and then went quiet for more than 2.5 s. "no DMX received" instead of pills while no universe is patched and none has been heard |
| timecode | The incoming time and its state; only while timecode is switched on or running |
| outputs | On while the engine renders the picture |
| ingest | Progress of the running transcode; only while one runs |
| auto version | When the engine last saved a version of the project; opens System |
| clients | Browsers and windows connected, and how many lag behind |
| sync lost | Red, only when a sync slave layer lost its master (see [multi-server.md](multi-server.md)) |
| web UI open | Yellow while the programmer role has no password |
| Undo, Redo, **?**, role | Undo and redo (programmer), the shortcut list, and your role: press it to log in as another one |

Red means look now: dropped frames, a lost timecode or no outputs while the
show is locked, a patched universe that went silent, a lost sync master.

Refused commands show a yellow banner with the next step ("Show lock is on:
press L or the LOCKED tag to unlock", "Not allowed for this role: log in as
programmer"). It disappears after 10 seconds; **Recent messages** on the banner
lists the last 20.

The Layers screen header says "tier allows N layers". The tier is the
performance class of this Mac's chip (System shows the chip); N is the number of
layers it plays without dropping frames, measured with the benchmark. **Add
layer** on the Patch screen stops at N so a show cannot be built that the
machine cannot play. Each layer row shows its state as a word next to the
dot (OK, LIVE, NO MEDIA, MISSING FILE, DECODER ERROR, or for a live input
that fails the reason itself, such as NOT RUNNING), and on the left a live
picture of that layer alone, four times a second (colour, effects and position
included). A layer that shows nothing (no media, intensity 0) shows the library
thumbnail of its file instead. The live pictures stop while the tab is in the
background or another screen is open.

## Open the UI from an iPad or another computer

Browse to `https://<mac-name>.local:8443`. The exact host name, the IP
addresses and the port are under System › Network (Host, Addresses, Port,
Bonjour). Fanous also advertises itself as an HTTPS service (`_https._tcp`)
under the host name shown on the Bonjour line of System › Network, so a
Bonjour browser on the network lists it with the right port.

<img src="images/network.png" width="692" alt="System › Network: the web UI open warning, host, addresses, port, Bonjour, TLS fingerprint with Copy, clients and CITP">

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
| operator | Cues (Go, Back, Go to), show mode on or off, run the readiness checks, timecode on or off; all of these also while the show is locked |
| programmer | Everything: patch, media, outputs, cues editing, passwords, show lock |

DMX from the console (blackout, test patterns, everything else) does not depend
on roles.

By default no role has a password, so anyone who can reach the address is
programmer, and the status bar says "web UI open". **Set a programmer password
before the show**: System › Roles and passwords, type the new password for
the role, press **Set**. **Clear** removes it again, and the role is open.

![System › Roles and passwords: each role open, with Set and Clear](images/roles.png)

A role without a password is open to everyone who can reach the address; each
role is open or protected on its own. A browser gets the highest role it asks
for that it is entitled to. To change role click the role name at the right of
the status bar, pick the role, enter its password and press **Log in**; **Log
out** drops the session. After five wrong attempts in a minute you must wait.

<img src="images/login.png" width="420" alt="The Log in dialog opened from the role at the right of the status bar">

The app window on the Mac itself is always programmer; it needs no password.

The passwords are stored hashed in `settings.json` (see below). A password
record copied into that file by hand while the engine runs takes effect at the
next password or sync change, or at the next engine start. The file wins at
that change: an editor that saves an older copy of it brings the old records
back. If the `passwords` field is not an object, password and sync changes are
refused ("passwords in settings.json could not be read; fix it first"); if a
record in it cannot be read, the passwords in use stay as they were while the
engine runs. Fix either before the next start, which would leave every role
open.

## Where files live

| What | Where |
|---|---|
| Media library | `~/Movies/Fanous Library` |
| Project (patch, outputs, cues, timecode settings) | `~/Library/Application Support/Fanous/project.json` |
| Project versions | `~/Library/Application Support/Fanous/versions/` |
| Machine settings, role passwords (hashed) | `~/Library/Application Support/Fanous/settings.json` |
| Certificate and fingerprint | `~/Library/Application Support/Fanous/tls/` |
| Thumbnail and metadata cache | `~/Library/Application Support/Fanous/cache/` |
| Ingest queue | `~/Library/Application Support/Fanous/ingest-queue.json` |
| Logs | `~/Library/Logs/Fanous/fanousd.log` |

The project is saved automatically two seconds after your last change. Versions
of it are saved at every engine start, on entering show mode and every 10
minutes after a change; save a named one with System › Project versions ›
**Save version…**. Back it up by copying `project.json` and `versions/`.
