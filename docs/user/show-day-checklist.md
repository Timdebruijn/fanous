<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Show-day checklist

Print this page. Date: ______________ Venue: ______________________
Mac: ______________ Fanous version: ______________

## The day before

- [ ] Every file the show uses is in the library on the Mac's **internal disk**,
      with more than 10 % of the disk free.
- [ ] Layers screen: every layer you use shows its file and a green dot, no red
      message.
- [ ] Patch screen: no red "collisions" in the toolbar; every universe you use
      shows a green pill when the console runs.
- [ ] Outputs screen: every output is bound to its display; blend, warp and masks
      checked with the test patterns.
- [ ] Timecode source tested if you chase it; cues stepped through with Go.
- [ ] Copy `~/Library/Application Support/Fanous/project.json` somewhere safe.
- [ ] No macOS update planned between now and the show.

## Mac settings (once per show machine)

- [ ] **AC power** connected. Check cooling and airflow.
- [ ] **Display sleep off**: System Settings › Lock Screen › Turn display off:
      Never.
- [ ] **Spotlight off for the library volume**: `sudo mdutil -i off <volume>`, or
      add the library folder to Spotlight Privacy.
- [ ] **Automatic updates off**: System Settings › General › Software Update ›
      Automatic updates.
- [ ] **Time Machine paused**: stop a running backup, or switch Time Machine off
      for the show.
- [ ] **Focus on** (Do Not Disturb) from the menu bar, so no notification lands
      on an output. Fanous cannot read this; it stays a manual item.
- [ ] **One network interface** for the console network. Turn Wi-Fi off if the
      console is on Ethernet. sACN multicast is joined on the default-route
      interface only, so a second active interface can put it on the wrong network.
- [ ] Displays are **not mirrored** (System Settings › Displays). Fanous does
      not check for mirroring (B42). Set each output's **Mode** in Outputs:
      show mode applies it, and the output list warns in yellow when the
      display runs a different mode.
- [ ] Firewall allows `fanousd` (see getting-started.md).

## In Fanous

- [ ] Console is sending: every patched universe pill in the status bar is green.
- [ ] **Programmer password set** (System › Roles and passwords) and the yellow
      "web UI open" notice is gone. Operator password set if an iPad or a
      second computer is in the room.
- [ ] System screen: press **Run checks**. Work through the Readiness list (below).
- [ ] Switch **Show mode** on (the SHOW MODE button in the status bar, or the
      switch on the System screen). It refuses while an item blocks and says
      which.
- [ ] Timecode on, state **Locked**, if you chase timecode.
- [ ] Press **L** (programmer) to **lock the show**. The status bar says
      LOCKED. Unlocking while show mode is on asks for confirmation.
- [ ] Look at "dropped" in the status bar: it should read 0 and stay there.
- [ ] **Save a named version before doors**: System › Project versions ›
      **Save version…**, a name such as "Doors 19:30". It never expires, works
      while the show is locked, and is what you go back to if a late change goes
      wrong (troubleshooting.md, "Go back to an earlier version").

## The Readiness list

Show mode runs these checks when you switch it on and every 30 seconds while it
is on. Each item shows a fix hint.

| Item | Needs |
|---|---|
| On AC power | power adapter connected |
| Thermal state nominal | cool machine (nominal or fair) |
| Free disk > 10 % | space on the library volume |
| Memory headroom | quit other applications |
| All patched universes receiving | console output and network |
| All outputs bound to their displays | displays connected, outputs assigned |
| Outputs in their desired display mode | the output's Mode is available and a multiple of the canvas rate (warning only) |
| Sync groups have one master | one master per Sync group in use (warning only; [multi-server.md](multi-server.md)) |
| Sync packets arriving | the master Mac and the network, with slaves in use (warning only) |
| No decoder errors | no layer showing a media error |
| Camera permission granted | the camera permission while a layer shows a camera (folder 0, 1–20) or a `--scene` entry has `capture:` (Capture permissions on the System screen) |
| Screen recording granted | the Screen permission while a layer shows a display (folder 0, 21–28) or a `--scene` entry has `screen:`; warns while one does, since macOS asks again about once a month |
| Image masks found | a still image in the library for every image mask, in the edited mappings and stored presets (warning only: a missing file, or a movie, covers nothing) |
| Library on a local volume | library on the internal disk |
| Spotlight indexing off for the library volume | see above |
| Automatic macOS updates off | see above |
| Time Machine not backing up | see above |
| Focus / Do Not Disturb on | manual, check the menu bar |
| Display sleep disabled | see above |
| Supported hardware | Apple Silicon with a ProRes engine |

**Failed** items (red) block show mode. A programmer can press **Acknowledge**
next to an item to accept the risk: the badge changes to "acknowledged" and it
no longer blocks. Do this only for things you decided on purpose, for example a
spare display that is not connected. A setting Fanous cannot read is shown as
"unknown"; check those yourself (B38).

**Warnings** (yellow, "warning" badge) never block show mode. Today that is
the display mode item (it names the closest mode a display offers when the
output's Mode is not available), the two Sync items, since a slave without a
master still plays on its own, and Screen recording granted while a layer
shows a display (folder 0, 21–28): macOS asks again about once a month, on the
main display, whether Fanous Engine may record the screen. Answer it before
doors. Image masks found warns too: a mask whose file is missing covers
nothing, so a slice whose only add mask it is stays black.

**Manual** items (Focus) have no button; the check is yours.

**Blocking** items (shown with a "blocking" badge) cannot be acknowledged. Today
that is Supported hardware: the Mac has no ProRes engine and cannot run a show.
Use a Mac with an M1 Pro or newer.

While show mode is on, the Mac does not sleep (display and system), the engine is
exempt from App Nap, the ingest queue is paused, the cursor is hidden over
the outputs and every output's display runs the output's Mode. Leave show mode
to resume ingest and put the previous display modes back.

If the engine crashes or is killed while show mode is on, it restarts within
about a second **still in show mode**: the displays keep their show modes (no
flip back and forth), the Mac stays awake, ingest stays paused and the cursor
stays hidden. The status bar and System say "Show mode resumed after the engine
restarted at HH:MM" until you leave show mode; download the log after the show.
The readiness checks run again but cannot refuse a resumed show mode. A locked
show stays locked. **Engine › Restart Engine** keeps show mode the same way.
Stopping on purpose (Engine › Stop Engine, Stop Engine and Quit, logging out)
leaves show mode, so the next start is normal. After a power cut or a crash of
the whole Mac, show mode comes back if the Mac restarts within two hours.

## During the show

- [ ] Check the status bar now and then: red means look now (dropped frames, a
      universe that went silent, lost timecode, a lost output).
- [ ] Cue Go, Back and Go to keep working while the show is locked. Everything
      else needs the programmer to unlock first (**L**).
- [ ] Do not import or transcode media during the show; ingest is paused in show
      mode anyway.

## After the show

- [ ] Leave show mode; unlock the show (**L**) if you need to edit.
- [ ] System › Logs › **Download** the log if anything odd happened.
- [ ] Switch automatic updates and Time Machine back on if you want them.
