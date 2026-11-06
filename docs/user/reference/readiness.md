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
row's fix hint, shortened; the on-screen hint for Spotlight also names
Spotlight Privacy, which does not count, and the one for the hardware item
says "M1 Pro or newer", while every chip but the base M1 passes. The checks run when
show mode turns on, every 30 seconds while it is on, once after a resumed
show mode, after a display mode switch in show mode, and on **Run checks**;
nothing alerts you when an item turns red meanwhile. The last column is
the id the API's `readiness.acknowledge` takes and the yellow banner names
("readiness: dmx, spotlight").

| Item | Fails or warns when | The row reads | What to do | Type | Id |
|---|---|---|---|---|---|
| On AC power | The first power source is not mains; a Mac without a battery passes | "AC power (battery N %)", "on battery, N %", "no battery" | Connect the power adapter | Fails | `power` |
| Thermal state nominal | macOS reports serious or critical; nominal and fair pass | "nominal", "fair", "serious", "critical" | Let the machine cool down, improve airflow | Fails | `thermal` |
| Free disk > 10 % | The library's volume has 10 % or less free; the home volume with the project and the log is not checked | "N % free (X GB)" | Free space on the library volume | Fails | `disk` |
| Memory headroom | 15 % or less of the memory is free, inactive or purgeable | "N % free" | Quit other applications | Fails | `memory` |
| All patched universes receiving | A patched universe has had no packet within its Signal lost after time (2.5 s to start), or none ever | "all receiving", "silent: artnet:0.0.1" | Check the console's output and the network | Fails | `dmx` |
| Universe interfaces usable | A universe is set to an interface this Mac lacks, or one without sACN multicast | "present, or any interface", "not usable: …" | Connect the network adapter, or pick another interface for the universe (Patch › Interface) | Warns | `interfaces` |
| sACN port 5568 available | Another program holds UDP 5568 exclusively, so the engine runs without sACN; a program that shares the port does not count | "listening", "in use, running without sACN: …" | Quit the program that holds UDP 5568 (`sudo lsof -nP -iUDP:5568`), then Engine › Restart Engine | Warns | `sacnport` |
| All outputs bound to their displays | An output is lost or unassigned, or no output is bound at all (also with no outputs) | "N bound", "no output bound", "lost: […], unassigned: […]" | Connect the displays, assign every output | Fails | `outputs` |
| Outputs in their desired display mode | A bound output's Mode is not available on its display, was not applied in show mode, is no multiple of the canvas rate, or conflicts with another output on the display; outputs without a Mode are not checked | "applied in show mode, or none set", or the output's note | Pick an available mode for the output (Outputs › Mode), or set it in System Settings › Displays | Warns | `modes` |
| Sync groups have one master | A slave playing a movie has no master, a group has two masters, or this Mac's master is outranked | "every slave in use has one master, or none in use", "Layer 2 (group 1): no master" | Set exactly one layer per group to master (Sync channel); a slave without a master plays on its own | Warns | `syncmaster` |
| Sync packets arriving | A slave in use is lost (no packets for 2 s) | "arriving, or no slave in use", "lost (freewheeling): Layer 2 (group 1)" | Check the master machine and the network; sync uses UDP port 8002 by default (System › Sync) | Warns | `syncpackets` |
| Camera permission granted | A layer shows a camera (folder 0, 1–20) and the permission is not granted; nothing in use passes | "no capture device in use", "camera: denied" | System Settings › Privacy & Security › Camera, then Engine › Restart Engine | Fails | `camera` |
| Screen recording granted | A layer shows a display (folder 0, 21–28): without the permission it fails; with it, it warns, because macOS asks again about monthly | "no display in use", "screen: granted", "screen: denied" | Not granted: System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart Engine. Granted: prefer a capture card for a show-critical feed | Fails, or warns | `screen` |
| Microphone permission granted | The timecode Source is LTC and the permission is not granted, whatever the timecode switch says | "timecode not on LTC", "microphone: denied" | Inputs › Authorize microphone, or System Settings › Privacy & Security › Microphone | Fails | `microphone` |
| No decoder errors | A layer shows an error: a missing file, a decoder error, a live input that is not running | "none", "Layer 3: no file 4 in folder 2" | Fix or replace the failing media | Fails | `decoders` |
| Image masks found | An image mask, in the edited mapping or a stored preset, points at a file that is not a still in the library | "found, or none in use", "missing, covering nothing: Output 2 slice 1: folder 3 file 5" | Put the greyscale file in the library under that folder and file number, or change the mask (Outputs › Warp & Slices › Mask) | Warns | `maskimages` |
| Library on a local volume | The library's volume is a network or removable one | "local", "network or removable volume" | Copy the library to the internal disk | Fails | `library` |
| Spotlight indexing off for the library volume | `mdutil -s` says indexing is enabled on the library's volume. The on-screen hint also names Spotlight Privacy; an exclusion there does not change what the item reads | "off", "indexing enabled", "unknown" | `sudo mdutil -i off <volume>` (`/` for the internal disk), or acknowledge | Fails; manual when unreadable | `spotlight` |
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
| **Acknowledge** | On a failed row, for the programmer: accepts it until the engine restarts |
| **warning**, **acknowledged**, **manual**, **blocking** | The badges of the other states; a green row has none |
| Yellow banner "Show mode resumed after the engine restarted at HH:MM" | The engine came back in show mode; the second sentence about an unclean stop also appears after a deliberate Engine › Restart Engine |
| Red banner "Show mode is on with blocking items: …" | Show mode is on and an item fails unacknowledged: after a resume (acknowledgements are lost), or an item that turned red during the show |

The status bar's **Show mode** tag shows "Cannot enter show mode" with the
blocking items and their fix hints when it refuses, with **Open System**;
the yellow banner at the top names the items by id.

<img src="../images/banner-readiness.png" width="1396" alt="The yellow banner: readiness: dmx, spotlight, updates, with the line Show mode is blocked by failed readiness checks, and the buttons Recent messages and Dismiss">
