<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Readiness items

Every item of the System screen's readiness list, in the order shown, with
its threshold, what the row reads, the fix hint and whether it blocks show
mode. How to work the list on the day is in
[show-day-checklist.md](../show-day-checklist.md#the-readiness-list); the
panel's controls are in [screens/system.md](../screens/system.md#readiness).
Back to the [index](../README.md).

Each item has a kind: a failed item blocks show mode until a programmer
acknowledges it; a warning never blocks; a manual item cannot be read and
is yours to check; the one blocking item cannot be acknowledged. The id is
what the API's `readiness.acknowledge` takes. The checks run when show mode
turns on, every 30 seconds while it is on, once after a resumed show mode,
after a display mode switch in show mode, and on **Run checks**.

| Id | Item | Fails or warns when | The row reads | Fix hint | Blocks |
|---|---|---|---|---|---|
| `power` | On AC power | The first power source is not mains; a Mac without a battery passes | "AC power (battery N %)", "on battery, N %", "no battery" | Connect the power adapter | Fails |
| `thermal` | Thermal state nominal | macOS reports serious or critical; nominal and fair pass | "nominal", "fair", "serious", "critical" | Let the machine cool down, improve airflow | Fails |
| `disk` | Free disk > 10 % | The library's volume has 10 % or less free | "N % free (X GB)" | Free space on the library volume | Fails |
| `memory` | Memory headroom | Less than 15 % of the memory is free, inactive or purgeable | "N % free" | Quit other applications | Fails |
| `dmx` | All patched universes receiving | A patched universe has had no packet within its Signal lost after time (2.5 s to start), or none ever | "all receiving", "silent: artnet:0.0.1" | Check the console's output and the network | Fails |
| `interfaces` | Universe interfaces usable | A universe is set to an interface this Mac lacks, or one without sACN multicast | "present, or any interface", "not usable: …" | Connect the network adapter, or pick another interface for the universe (Patch › Interface) | Warns |
| `sacnport` | sACN port 5568 available | Another program holds UDP 5568 exclusively, so the engine runs without sACN; a program that shares the port does not count | "listening", "in use, running without sACN: …" | Quit the program that holds UDP 5568 (`sudo lsof -nP -iUDP:5568`), then Engine › Restart Engine | Warns |
| `outputs` | All outputs bound to their displays | An output is lost or unassigned, or no output is bound at all (also with no outputs) | "N bound", "no output bound", "lost: […], unassigned: […]" | Connect the displays, assign every output | Fails |
| `modes` | Outputs in their desired display mode | A bound output's Mode is not available on its display, was not applied in show mode, is no multiple of the canvas rate, or conflicts with another output on the display; outputs without a Mode are not checked | "applied in show mode, or none set", or the output's note | Pick an available mode for the output (Outputs › Mode), or set it in System Settings › Displays | Warns |
| `syncmaster` | Sync groups have one master | A slave playing a movie has no master, a group has two masters, or this Mac's master is outranked | "every slave in use has one master, or none in use", "Layer 2 (group 1): no master" | Set exactly one layer per group to master (Sync channel); a slave without a master plays on its own | Warns |
| `syncpackets` | Sync packets arriving | A slave in use is lost (no packets for 2 s) | "arriving, or no slave in use", "lost (freewheeling): Layer 2 (group 1)" | Check the master machine and the network; sync uses UDP port 8002 by default (System › Sync) | Warns |
| `camera` | Camera permission granted | A layer shows a camera (folder 0, 1–20) and the permission is not granted; nothing in use passes | "no capture device in use", "camera: denied" | System Settings › Privacy & Security › Camera, then Engine › Restart | Fails |
| `screen` | Screen recording granted | A layer shows a display (folder 0, 21–28): without the permission it fails; with it, it warns, because macOS asks again about monthly | "no display in use", "screen: granted", "screen: denied" | Not granted: System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart. Granted: macOS asks about monthly to keep recording the screen, on the main display; prefer a capture card for a show-critical feed | Fails, or warns |
| `microphone` | Microphone permission granted | The timecode Source is LTC and the permission is not granted, whatever the timecode switch says | "timecode not on LTC", "microphone: denied" | Inputs › Authorize microphone, or System Settings › Privacy & Security › Microphone | Fails |
| `decoders` | No decoder errors | A layer shows an error: a missing file, a decoder error, a live input that is not running | "none", "Layer 3: no file 4 in folder 2" | Fix or replace the failing media | Fails |
| `maskimages` | Image masks found | An image mask, in the edited mapping or a stored preset, points at a file that is not a still in the library | "found, or none in use", "missing, covering nothing: Output 2 slice 1: folder 3 file 5" | Put the greyscale file in the library under that folder and file number, or change the mask (Outputs › Warp & Slices › Mask) | Warns |
| `library` | Library on a local volume | The library's volume is a network or removable one | "local", "network or removable volume" | Copy the library to the internal disk | Fails |
| `spotlight` | Spotlight indexing off for the library volume | `mdutil -s` says indexing is enabled on the library's volume; a Spotlight Privacy exclusion does not change that | "off", "indexing enabled", "unknown" (manual) | `sudo mdutil -i off <volume>`, or add the library to Spotlight Privacy | Fails; manual when unreadable |
| `updates` | Automatic macOS updates off | macOS is set to install updates by itself; the other update switches are not read | "off", "automatic install enabled", "unknown" (manual) | System Settings › General › Software Update › Automatic updates | Fails; manual when unreadable |
| `timemachine` | Time Machine not backing up | A backup is running now | "idle", "backup running", "unknown" (manual) | Stop the backup or disable Time Machine for the show | Fails; manual when unreadable |
| `focus` | Focus / Do Not Disturb on | Always manual: macOS does not tell | "cannot be read; check the menu bar" | Turn on a Focus so notifications stay off the outputs | Manual |
| `displaysleep` | Display sleep disabled | The display sleep setting is anything but Never, although show mode holds the display awake meanwhile; an unreadable value passes | "never", "60 min (held off by the show-mode assertion)" | System Settings › Lock Screen › Turn display off: never | Fails |
| `hardware` | Supported hardware | The chip is the base M1, which has no ProRes engine | "Apple Silicon with ProRes engine", "no hardware ProRes decoder" | Use an Apple Silicon Mac with a ProRes engine (M1 Pro or newer) | Blocking |

Entering show mode is also refused, without an item, while a library root
change is in progress ("readiness: libraryRootChanging").

## How the panel reads

| Part | Means |
|---|---|
| **ready** (green) | Every check ran and none blocks; warnings do not change it |
| **not ready** (red) | A failed item is not acknowledged, or the blocking item fails |
| **not checked** (yellow), "checked never" | No check has run since the engine started |
| **Acknowledge** | On a failed row, for the programmer: accepts it until the engine restarts |
| **warning**, **acknowledged**, **manual**, **blocking** | The badges of the other states; a green row has none |
| Yellow banner "Show mode resumed after the engine restarted at HH:MM" | The engine came back in show mode; the second sentence about an unclean stop also appears after a deliberate Engine › Restart Engine |
| Red banner "Show mode is on with blocking items: …" | A resumed show mode runs with items that would have refused it |

The status bar's **Show mode** tag shows "Cannot enter show mode" with the
blocking items and their fix hints when it refuses, with **Open System**;
the yellow banner at the top names the items by id ("readiness: dmx,
displaysleep").
