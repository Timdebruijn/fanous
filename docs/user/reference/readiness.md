<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Readiness items

Every item of the System screen's readiness list, in the order shown, with
its threshold, what the row reads, the fix hint and its type. How to work
the list on the day is in
[Show-day checklist](../show-day-checklist.md#the-readiness-list); the
panel's controls are in [System screen](../screens/system.md#readiness).
Back to the [index](../README.md).

Types: Fails blocks show mode until it is fixed or a programmer
acknowledges it; Warns never blocks; Manual cannot be read and is yours to
check; Blocking cannot be acknowledged. The "What to do" column is the
row's fix hint, shortened; the on-screen hint for the hardware item
says "M1 Pro or newer", while every chip but the base M1 passes. The checks run when
show mode turns on, every 30 seconds while it is on, once after a resumed
show mode or a start that did not read `project.json`, after a display mode switch in show mode, and on **Run checks**;
an item that turns red in show mode shows in the log, and in the status bar
when it is not acknowledged (below). The Spotlight, Time
Machine and display sleep rows ask macOS tools (`mdutil`, `tmutil`,
`pmset`); a tool that has not answered within 3 seconds is stopped: the
Spotlight and Time Machine rows then read "unknown" and are yours to check,
the display sleep row reads "unknown" and passes. The free disk, library
and Spotlight rows read the library's volume, also for at most 3 seconds: a
volume that has not answered (a network mount that stopped responding)
reads "library volume not answering", free disk and library fail, Spotlight
is manual. Each hanging tool and a volume that does not answer add at most
3 seconds each to turning show mode on. Checks asked for while one runs
(Run checks, the 30-second timer) wait as one: a single check follows the
running one. The last column is
the id the API's `readiness.acknowledge` and `readiness.unacknowledge` take and the yellow banner names
("readiness: dmx, spotlight").

| Item | Fails or warns when | The row reads | What to do | Type | Id |
|---|---|---|---|---|---|
| Project file read at start | `project.json` did not read as a project at an engine start; the engine runs the newest version that can be restored, or a new project ([The project is gone after a restart](../troubleshooting.md#the-project-is-gone-after-a-restart)). It fails at every start, also after a repair by hand, until it is acknowledged. For this item an acknowledgement means seen, the same in the running engine and across restarts: `project.json.notice` is removed and the item passes from then on, also after show mode is left; Take back writes the notice again and the item fails again; a notice that cannot be removed refuses the acknowledgement. The engine runs the list once by itself after such a start | "read", "At the start of 2026-11-18T14:44:45+0100: project.json was not readable; running project "B281 show" from version "Manual" of 2026-11-18T14:13:53+0100; the file is kept as project.json.unreadable-…. Check the patch, the cues and the outputs. A repaired file goes back as project.json with the engine stopped.", "… project.json is from a newer Fanous (schema 2); … For that project, go back to the newer Fanous and put … back as project.json with the engine stopped.", "…; not written to project.json (…) until a later save succeeds; … Free disk space now: until a save succeeds, a stop loses the changes.", "… and could not be kept aside (…); …; changes are not saved to project.json (versions are still made). Fix the permissions of the folder that holds project.json or free disk space, then restart the engine.", "… and no version restores; a new project runs; the file is kept as …. A repaired file goes back as project.json with the engine stopped." | The row's last sentence; then acknowledge: "Do what the last sentence above says, then acknowledge: that marks it seen, and the item passes from then on, also at later starts" | Fails | `project` |
| On AC power | The first power source is not mains; a Mac without a battery passes | "AC power (battery N %)", "on battery, N %", "no battery" | Connect the power adapter | Fails | `power` |
| Thermal state nominal | macOS reports serious or critical; nominal and fair pass | "nominal", "fair", "serious", "critical" | Let the machine cool down, improve airflow | Fails | `thermal` |
| Free disk > 10 % | The library's volume has 10 % or less free; the home volume with the project and the log is not checked | "N % free (X GB)", "library volume not answering" | Free space on the library volume; when not answering: reconnect the library volume, or copy the library to the internal disk | Fails | `disk` |
| Memory headroom | 15 % or less of the memory is free, inactive or purgeable | "N % free" | Quit other applications | Fails | `memory` |
| All patched universes receiving | A patched universe has had no packet within its Signal lost after time (2.5 s to start), or none ever | "all receiving", "silent: artnet:0.0.1" | Check the console's output and the network | Fails | `dmx` |
| Universe interfaces usable | A universe is set to an interface this Mac lacks, or one without sACN multicast | "present, or any interface", "not usable: …" | Connect the network adapter, or pick another interface for the universe (Patch › Interface) | Warns | `interfaces` |
| Art-Net port 6454 available | The Art-Net listener is down now: another program holds UDP 6454 exclusively (a program that shares the port does not count), or the listener failed when the network went away; the engine makes it again every 5 s at most and the item turns green when it listens | "listening", "not listening: …, trying again", "not listening: waiting for a usable network: …" | Quit a program that holds UDP 6454 (`sudo lsof -nP -iUDP:6454`), or check the network: the engine listens again by itself within 5 s | Warns | `artnetport` |
| sACN port 5568 available | Another program holds UDP 5568 exclusively, so the engine runs without sACN; a program that shares the port does not count | "listening", "in use, running without sACN: …" | Quit the program that holds UDP 5568 (`sudo lsof -nP -iUDP:5568`), then Engine › Restart Engine | Warns | `sacnport` |
| OSC port 8000 available | An OSC listener (UDP or TCP 8000) is down now, for the same reasons as Art-Net | "listening", "not listening: UDP: …, trying again", "not listening: TCP: …" | Quit a program that holds port 8000 (`sudo lsof -nP -i:8000`), or check the network: the engine listens again by itself within 5 s | Warns | `oscport` |
| All outputs bound to their displays | An output is lost or unassigned, or no output is bound at all (also with no outputs) | "N bound", "no output bound", "lost: […], unassigned: […]" | Connect the displays, assign every output | Fails | `outputs` |
| Outputs in their desired display mode | A bound output's Mode is not available on its display, was not applied in show mode, is no multiple of the canvas rate, or conflicts with another output on the display; for an output without a Mode, the rate its display runs at in show mode (another output's Mode on it, else the current rate) is no multiple of the canvas rate | "applied in show mode, or none set", or the output's note | Pick an available mode for the output (Outputs › Mode), or set it in System Settings › Displays | Warns | `modes` |
| Sync groups have one master | A slave playing a movie has no master, a group has two masters, or this Mac's master is outranked | "every slave in use has one master, or none in use", "Layer 2 (group 1): no master" | Set exactly one layer per group to master (Sync channel); a slave without a master plays on its own | Warns | `syncmaster` |
| Sync packets arriving | A slave in use is lost (no packets for 2 s) | "arriving, or no slave in use", "lost (freewheeling): Layer 2 (group 1)" | Check the master machine and the network; sync uses UDP port 8002 by default (System › Sync) | Warns | `syncpackets` |
| Camera permission granted | A layer shows a camera (folder 0, 1–20) and the permission is not granted; nothing in use passes | "no capture device in use", "camera: denied" | System Settings › Privacy & Security › Camera, then Engine › Restart Engine | Fails | `camera` |
| Screen recording granted | A layer shows a display (folder 0, 21–28): without the permission it fails; with it, it warns, because macOS asks again about monthly | "no display in use", "screen: granted", "screen: denied" | Not granted: System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart Engine. Granted: prefer a capture card for a show-critical feed | Fails, or warns | `screen` |
| Microphone permission granted | The timecode Source is LTC and the permission is not granted, whatever the timecode switch says | "timecode not on LTC", "microphone: denied" | Inputs › Authorize microphone, or System Settings › Privacy & Security › Microphone | Fails | `microphone` |
| No decoder errors | A layer shows an error: a missing file, a decoder error, a live input that is not running | "none", "Layer 3: no file 4 in folder 2" | Fix or replace the failing media | Fails | `decoders` |
| Image masks found | An image mask, in the edited mapping or a stored preset, points at a file that is not a still in the library, or at a still listed as unreadable because the engine stopped twice while reading it ("(unreadable)" after the file) | "found, or none in use", "missing, covering nothing: Output 2 slice 1: folder 3 file 5" | Put the greyscale file in the library under that folder and file number, or change the mask (Outputs › Warp & Slices › Mask) | Warns | `maskimages` |
| Library on a local volume | The library's volume is a network or removable one | "local", "network or removable volume", "library volume not answering" | Copy the library to the internal disk | Fails | `library` |
| Spotlight indexing off for the library volume | `mdutil -s` says indexing is enabled on the library's volume. It reads the volume's switch only: macOS lets only an administrator read Spotlight Privacy, so a library folder excluded there still fails | "off", "indexing enabled", "unknown", "library volume not answering" | `sudo mdutil -i off <volume>` (`/` for the internal disk), or acknowledge | Fails; manual when unreadable | `spotlight` |
| Automatic macOS updates off | macOS is set to install updates by itself; the other update switches are not read | "off", "automatic install enabled", "unknown" | System Settings › General › Software Update › Automatic updates | Fails; manual when unreadable | `updates` |
| Time Machine not backing up | A backup is running now | "idle", "backup running", "unknown" | Stop the backup or disable Time Machine for the show | Fails; manual when unreadable | `timemachine` |
| Focus / Do Not Disturb on | Always manual: macOS does not tell | "cannot be read; check the menu bar" | Turn on a Focus so notifications stay off the outputs | Manual | `focus` |
| Display sleep disabled | The display sleep setting is anything but Never; show mode holds the display awake meanwhile, so it never blocks; an unreadable value passes | "never", "60 min; show mode keeps the display awake", "unknown" | Show mode keeps the display awake; for outside show mode too: System Settings › Lock Screen › Turn display off: never | Warns | `displaysleep` |
| Supported hardware | The chip is the base M1, which has no ProRes engine; every other Apple Silicon chip passes | "Apple Silicon with ProRes engine", "no hardware ProRes decoder" | Use any Apple Silicon Mac except the base M1 | Blocking | `hardware` |

Entering show mode is also refused, without an item, while a library root
change is in progress.

## How the panel reads

| Part | Means |
|---|---|
| **ready** (green) | Every check ran and none blocks; warnings do not change it |
| **not ready** (red) | A failed item is not acknowledged, or the blocking item fails |
| **not checked** (yellow), "checked never" | No check has run since the engine started |
| **Acknowledge** | On a failed row, for the programmer: accepts it until it is taken back, show mode is left, the engine restarts, or (only outside show mode) the item passes a check: green or warning; a manual (unreadable) result keeps it; a different detail while it keeps failing keeps it. Project file read at start is the exception: acknowledging it marks it seen for good (its row) |
| **Take back** | The same button on an acknowledged row, for the programmer: the item blocks again |
| **warning**, **acknowledged**, **manual**, **blocking** | The badges of the other states; a green row has none |
| Yellow banner "Show mode resumed after the engine restarted at HH:MM" | The engine came back in show mode; the second sentence says whether it stopped uncleanly or was restarted with Engine › Restart Engine |
| Red banner "Show mode is on with blocking items: …" | Show mode is on and an item fails unacknowledged: after a resume (acknowledgements are lost), or an item that turned red during the show |

The status bar's **Show mode** tag shows "Cannot enter show mode" with the
blocking items and their fix hints when it refuses, with **Open System**
(during a library root change it says "The library root is being switched; try
again in a few seconds." and offers only **Close**);
the yellow banner at the top names the items by id. While show mode is on
and an item blocks (it fails and is not acknowledged, or it is a hard
failure), the status bar reads "not ready: " and the first item's title,
"+ 2 more" when there are more, in red, as a link to System; hover it for all
titles. A long title is cut off with an ellipsis, and the auto version item
makes room while it shows. A phone shows "not ready" alone. An acknowledged
item is not in the bar, also when it fails again during the show: that is in
the log only.

In show mode every check that changes something logs one line, "readiness
changed in show mode": `failing` the items that started failing,
`acknowledged` those of them that are acknowledged, `passing` the items that
pass again, and `blocking` what blocks now (`none` for an empty list). It is
a warning when an item started blocking, otherwise info. Acknowledging and
taking back log their own line, "readiness acknowledged in show mode" and
"readiness acknowledgement taken back in show mode", with `item` and
`blocking`. After a resumed show the acknowledgements are gone, so the first
check logs every failing item as blocking.

<img src="../images/banner-readiness.png" width="1396" alt="The yellow banner: readiness: dmx, spotlight, updates, with the line Show mode is blocked by failed readiness checks, and the buttons Recent messages and Dismiss">
