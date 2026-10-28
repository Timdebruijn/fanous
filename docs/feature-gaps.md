<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->

# Fanous: feature gaps against existing media servers

Research of 2026-10-28. Four web surveys covered console-native servers,
touring/show servers, Mac VJ/theatre software, and the console ecosystem and
standards. They were merged and checked against this repository. Product facts
come from manuals, release notes and vendor pages. Four load-bearing claims were
re-read by hand (§7). Prevalence counts are what the surveys found documented;
a missing count does not prove a product lacks the feature. Update this file
when a gap closes or a product changes. The market overview and positioning
stay in `docs/marketing/positioning.md`; competitor prices stay out of the
repository.

## 0. Summary

1. **The weak spot is the path into grandMA3 and Eos, not the effect count.**
   - grandMA3 lists no CITP (protocol page 2.4/2.5; Pixera, Jan 2025: MA "has
     not yet committed"). Eos has none either.
   - Their live-preview path is NDI: MA3, and also MagicQ and Onyx (Titan
     used NDI until it dropped it in v19, Dec 2025). Per the survey, Eos takes
     an SRT/RTSP H.264 stream.
   - Our CITP/MSEX therefore reaches only MA2, MagicQ, Hog 4, Onyx and Titan.
   - NDI is designed as a closed plugin and deferred for its licence
     obligations (§4, B74). Until it lands, an MA3 programmer sees no
     Fanous picture on the desk.
2. **Live input is the gap nearly every product has closed.**
   - Cameras or capture cards: all 6 Mac tools, all 5 console-native servers
     and 5 of 6 touring servers. Fanous takes Syphon only.
   - AVFoundation capture and ScreenCaptureKit are native, need no SDK, and fit
     folder 0, files 1–32. DESIGN §8.2 reserves those slots for live inputs, but
     they were never built.
3. **Audio goes to the default device only, in stereo.**
   - The cause is B4: `AudioMixer.deviceUID` is ignored. The per-layer channel
     pairs of DESIGN §10 are not built either.
   - Every other class routes multichannel.
   - Device selection alone also brings Dante, because Dante Virtual Soundcard
     is a CoreAudio device; with the stereo mix that is a 2-channel feed until
     the channel pairs land.
4. **Content is thin where it shows in a demo.**

   | | Fanous | Others |
   |---|---|---|
   | Transitions | crossfade only | 3 to ~66 types |
   | Effects | 11 | 60–220, mostly through ISF/GLSL/FFGL |
   | Text layer | clock only | nearly universal |
   | Per-layer mask | crop and keys only | most |

5. **The designed-for-later list is the right list.** Pixel mapping, backup,
   3D mapping, PSN and frame blending are what the console-native class has;
   multi-server sync (B60) is built up to the two-Mac test. The open question
   is the order of the rest.
6. **Decide the Layer channel budget before 1.0.**
   - Channels 52–64 (13) are all that is left.
   - Transition type, layer mask, a third effect slot and the 3D Geometry
     channel all want some of them.
   - The shipped GDTF locks the map at 1.0 (OPEN-9). See §5.

## 1. What was compared

| Class (short name) | Products and version found |
|---|---|
| Console-native servers (CN) | Hippotizer 4.9.5 (Windows, own hardware) · Avolites Ai 12.2.9 (Windows) · PRG Mbox 5.6 (macOS, Apple Silicon native) · ChamSys MediaMaster 26.0 (Windows; macOS promised for 27.0) · Catalyst V5 (Mac; no dated release evidence after 2015) |
| Touring/show servers (HE) | disguise r34.2 · Pixera 26.2 · Watchout 7.8.4 · Modulo Kinetic V7 · Pandoras Box V10 (twoloox since 2025-10) · Smode R15. All are Windows. |
| Mac VJ/theatre (Mac) | Resolume Arena 7.28.1 · Millumin 5.14 · MadMapper 6 · VDMX 6.3 · QLab 5.6.5 · Isadora 4.5. Briefly: Mitti 2.8, TouchDesigner. |
| Consoles (integration side) | grandMA3 2.5 · Eos 3.3 · MagicQ 1.9.9 · Titan 19 · Onyx 4.32 · Hog 4 OS 5.0.1 |
| Open source | OpenVideoServer 0.3.7 · Ghost Arcade · LuxCanvas 1.7 · dmxCanvas · PrismVJ · Phosphor. None has CITP/MSEX or GDTF export. Katrin (free, closed source, Intel Mac, last release 2013) is the historical precedent. |

## 2. Market facts that changed since the positioning survey (2026-10-26)

**MediaMaster and ChamSys**
- ChamSys bought MediaMaster, Kling-Net and GrandVJ in Sep 2025.
- MediaMaster 26.0 (12 Oct 2026) runs on Windows. ChamSys promises a native
  macOS build "for the MediaMaster 27.0 release".
- ADJ lists MediaMaster Pro 5 as discontinued.
- MagicHD left MagicQ in 1.9.9.0. A ChamSys feature page still advertises a
  free 8-layer server, which conflicts with that.

**PRG Mbox: the paid Mac peer**
- Mbox 5.6 (15 Sep 2026) runs natively on Apple Silicon and Intel, macOS 12–26.
- Designer is a paid annual licence and allows two activations (primary and
  backup).
- Layer counts: Mini 6, Studio and Studio+ 12, Designer 24.

**Other changes**
- **Catalyst V5:** Arcus still lists it, but the newest dated evidence is a V5
  beta of March 2015.
- **Avolites NDI:** removed from Titan, Prism and Ai in Dec 2025 for licensing
  reasons. Its return is unconfirmed.
- **Pandoras Box and Widget Designer:** moved from Christie to twoloox on
  2025-10-15, now at V10.
- **Free tiers:** common, but none can run a show unwatermarked.

  | Product | Limit |
  |---|---|
  | disguise Starter | watermark, 2K |
  | Pixera Creator | watermark |
  | Watchout Producer | no output without a key |
  | MediaMaster | demo |

- **CITP coverage:** grandMA3 and Eos have none (§0.1). The README and
  `docs/marketing/positioning.md` should name the desks CITP thumbnails reach.

## 3. Gap matrix

**Who has it:** the documented count per class, written CN x/5 · HE x/6 · Mac x/6.

**Fanous column:**
- `—` none
- `◐` partly
- `D` designed in DESIGN §21 or the backlog, not built

**Effort** is an estimate: S takes days, M one to two weeks, L more. The
priority for each row comes from §4.

### 3.1 Inputs and content

| # | Capability | Who has it | Fanous | Effort |
|---|---|---|---|---|
| G1 | Camera/capture input: UVC, and capture cards with a macOS driver | CN 5/5 · HE 5/6 · Mac 6/6 | `—` (folder 0, files 1–32 reserved, never built) | M: `AVCaptureSession` → `CVMetalTextureCache`, as a `LiveTextureSource` like Syphon and the folder 0 generators |
| G2 | NDI in and out | CN 3/5 (Ai pulled it) · HE 6/6 in · Mac 6/6 in; **the live-preview path of MA3, MagicQ and Onyx** (Titan until v19) | `D`: closed plugin (ADR-0016), deferred for its licence (B74) | M, plus the plugin loader |
| G3 | Screen/window capture: slides, presentation and lyrics apps | Millumin, VDMX, Isadora, Mitti | `—` | S–M: ScreenCaptureKit, the same `LiveTextureSource` path as G1 |
| G4 | Text layer: static and live text over OSC/API, countdown, SRT subtitles | CN 4/5 · HE 5/6 · Mac 5/6 | `◐` clock generator only | M: CoreText into a folder 0 generator; text set over OSC/WebSocket |
| G5 | Transitions beyond crossfade: through black, fade-up-first, wipes, shader transitions | CN 4/5 (Hippotizer 3, Ai 38, Mbox ~66) · Resolume, Millumin | `◐` crossfade 0.1–25.5 s | S for through black and fade-up-first; M for a catalogue. Needs 1–2 reserved channels |
| G6 | More effects through a shader format (others have 60–220 effects) | ISF/GLSL: Mbox, Ai, Pixera, Smode · Mac 5/6 (ISF, FFGL, GLSL) · Notch blocks: HE 4/6 | `◐` 11 fixed effects, 2 slots | M–L: ISF is GLSL and Fanous is Metal, so either a translation dependency (SPIRV-Cross) or our own MSL format |
| G7 | Per-layer mask, stencil or gobo from the library | CN 4/5 · HE 3/6 · Mac 4/6 | `◐` crop, keys, output masks | M: a mask texture in the layer shader. Needs 2 channels |
| G8 | Frame blending for slow or mismatched-rate playback | CN 4/5 | `D` (OPEN-4, §21) | S–M |
| G9 | Direct H.264/HEVC playback | Mac 4/6 · Watchout, Kinetic, Pixera · Mbox (H.264) | `◐` transcoded at ingest, by design | — |
| G10 | NotchLC, HAP R | NotchLC: HE 5/6, Hippotizer · HAP R: VDMX, Pixera, Watchout, Smode | `D` (NotchLC is blocked on its licence, R11) | — |
| G11 | Web/HTML layer | disguise, Pixera, Millumin | `—` | M: offscreen WKWebView |
| G12 | Generative/real-time engines: Notch, TouchEngine, Unreal | HE 4/6 · Hippotizer, Ai | `—` | non-goal (Windows SDKs, DESIGN §1) |
| G13 | Live audio input | Pixera 26.2, Watchout, QLab (mic cue) | `—` | S |

### 3.2 Outputs, mapping, colour

| # | Capability | Who has it | Fanous | Effort |
|---|---|---|---|---|
| G14 | Pixel mapping to Art-Net/sACN LED fixtures | CN 5/5 · HE 5/6 · Mac 4/6 | `D` (§21) | M–L |
| G15 | 3D projection mapping, 3D-model layers | CN 5/5 (MediaMaster: primitives only) · HE most | `D` (§21, B9) | L |
| G16 | MPCDI import from camera-calibration systems such as VIOSO | Hippotizer, Pixera, Watchout | `—` | S–M: XML plus a PFM warp into the mesh |
| G17 | Camera-based auto-calibration | disguise OmniCal, Kinetic, Mbox (pixel placement) | `—` | L, touring scale |
| G18 | 3D LUT (`.cube`) per output or layer | disguise, Pixera, Smode (LUT/OCIO); colour pipelines in all of HE · Millumin | `—` | S: a 3D texture lookup in the output pass |
| G19 | 10-bit or HDR output | Hippotizer, MediaMaster · HE 6/6 · Resolume, Millumin | `D` (OPEN-5, §21) | M |
| G20 | Recording the output to a file | Resolume, VDMX | `—` | S (`MovieWriter` exists) |
| G21 | Genlock, EDID management | own hardware only | `—` | not possible on Macs |

### 3.3 Console integration and protocols

| # | Capability | Who has it | Fanous | Effort |
|---|---|---|---|---|
| G22 | Desk personalities beyond GDTF (MA2 XML, MagicQ head file, Avolites personality, Eos library request, Onyx), plus a test on a real desk. Eos's GDTF import does not create media or models (ETC support page) | CN 5/5 ship desk profiles or appear in MagicQ's patch presets | `◐` GDTF only, untested (B7, B40) | S each, plus owner time |
| G23 | CITP compliance details. Fall back to a v1.0 `SInf`. Respect the 256-library/256-element cap and 0-based contiguous indexes. Titan Active Fixtures auto-patch from what the server reports. MagicQ needs layers on ascending DMX addresses with ascending head numbers. | MA2, MagicQ, Hog, Onyx, Titan | `◐` MSEX 1.2, verified on loopback only (B40) | S |
| G24 | Thumbnails for desks without CITP (MA3, Eos): export the library thumbnails as an image set named by folder and file, for the desk's image pool | none found (users build it by hand) | `—` | S; first check what MA3 and Eos can import |
| G25 | SRT/RTSP H.264 preview stream for Eos (3.3.5 and later, per the survey; the page returned 404 on re-check) | Eos side only | `◐` the H.264 encoder exists for the web preview | M |
| G26 | Art-Net timecode in (`ArtTimeCode`, 0x9700) | Pixera, Kinetic; MagicQ sends it | `—` (Core parses `ArtSync` only) | S |
| G27 | Timecode out, LTC generator | QLab, Millumin, VDMX, Pixera | `◐` `LTCEncoder` in Core, used by tests only | S–M |
| G28 | PosiStageNet and tracking | HE 5/6 · Hippotizer; MA3 and MagicQ send PSN | `D` (B53) | M |
| G29 | GDTF `MediaServerLayer` / `MediaServerMaster` geometry types | no consuming desk verified | `◐` generic `Geometry` | S |
| G30 | Honour sACN sync and `ArtSync`; sACN 0xDD | niche | `◐` parsed | S |
| G31 | Kling-Net, Sig-Net | MediaMaster / ChamSys only | `—` | watch |

### 3.4 Show control, API, workflow

| # | Capability | Who has it | Fanous | Effort |
|---|---|---|---|---|
| G32 | Multi-server sync | CN 4/5 · HE 6/6 | `◐` B60: Sync channel 51, sender, receiver, slave clock, UI and guide built (PRs #31, #32, #35); two-Mac acceptance test open | S (the test) |
| G33 | Hot backup, failover | HE 6/6 · Mbox (backup mode) | `D` (OPEN-27) | L |
| G34 | Media distribution between machines | CN 4/5 · HE 5/6 | `—` (OPEN-28) | M |
| G35 | Timeline editor | all classes | non-goal | — |
| G36 | Richer cue list: groups, wait, goto, notes, CSV import/export | QLab, Millumin, VDMX, MadMapper, Pixera (CSV) | `◐` simple list | S–M |
| G37 | Projector control: PJLink, serial | HE 5/6 · Mac 3/6 · Catalyst | `D` serial (OPEN-7) | S for PJLink |
| G38 | Documented public API and a Bitfocus Companion module | API: HE 6/6, Hippotizer, Resolume · Companion: Hippotizer, Smode, Kinetic, QLab, Mitti | `◐` WebSocket, REST and OSC exist; Companion over Generic OSC (`docs/user/show-control.md`) | S |
| G39 | Presets stored on the server, recalled with a few channels | CN 4/5 | `◐` cues | M, plus channels |
| G40 | Time-of-day schedule for installations | Kinetic, MadMapper, Hippotizer | `—` | S: a cue trigger on the wall clock |
| G41 | Scripting (Python, Lua, JS) | HE 5/6 · Mac 5/6 | `—` | non-goal: the OSC/WebSocket API covers it |
| G42 | BPM, audio-reactive control, autopilot | VJ class · Ai, MediaMaster | `—` | non-goal: the console drives timing |
| G43 | DMX recorder and player | Smode, Watchout, MadMapper | `◐` DMX monitor | S |

### 3.5 Audio

| # | Capability | Who has it | Fanous | Effort |
|---|---|---|---|---|
| G44 | Choice of output device | standard in every class | `—` (B4: `deviceUID` ignored, so the default device only) | S |
| G45 | Multichannel per-layer routing, Dante | CN 4/5 · HE 6/6 · QLab 128 ch · Isadora 64 ch | `◐` stereo mix. Pairs are designed (§10) but not built. Dante works through DVS once G44 lands, as a 2-channel feed until the pairs land | M |
| G46 | Varispeed audio | none documented | `D` (OPEN-15, §21) | — |

## 4. Proposed priorities

**P1: close before 1.0 or right after.** These are the gaps a first user hits.
1. **G1 and G3: live inputs** through AVFoundation and ScreenCaptureKit, in
   folder 0, files 1–32 (already reserved). Both are system frameworks, with
   no vendor SDK.
2. **G44 and G45: audio device selection** and per-layer channel pairs (B4 and
   DESIGN §10).
3. **G4: text layer** with text set over OSC.
4. **G22 and G23: desk personalities and CITP compliance**, together with the
   desk tests of B7 and B40.

**Deferred: G2 NDI** (owner, 2026-10-28: later if the licence is a nuisance).
- Nothing found so far blocks it: the SDK is royalty-free on macOS, with no
  key or fee. Two licence points are still open (§7).
- The obligations are the nuisance:
  - our own EULA carrying NDI's terms
  - an indemnity
  - keeping up with the latest SDK
  - termination on 30 days' notice
  - trademark rules
- Pick it up when the plugin exception gets its legal review
  (`docs/RELEASE.md` §7), with NDI's licence added to it. Details are in B74.
- Accepted for now: the headline gap of §0.1 has no P1 item. The cheapest
  stopgap for MA3 and Eos is G24 (P2).

**P2: v1.x**, roughly in this order:
1. G5 transitions
2. G18 LUT
3. G26 Art-Net timecode
4. G38 public API and Companion module
5. G37 PJLink
6. G32 two-Mac test (B60), then G33–G34
7. G14 pixel mapping
8. G7 layer masks
9. G8 frame blending
10. G6 shader format (decide ISF or our own MSL format first)
11. G24 thumbnail export (verify that it works first)

**P3: later, or when a show asks for it.** G10, G11, G13, G15, G16, G19, G20,
G25, G27–G30, G36, G39, G40, G43, G46.

**Kept as designed:** G9. **Watch:** G31.

**Proposed non-goals.** DESIGN §1 already has ST 2110, generative engines, XR
and the timeline editor. If the rest is accepted, add it to DESIGN §1 and the
README:
- G12 Notch, Unreal and XR
- G17 camera auto-calibration
- G21 genlock and EDID
- G35 timeline editor
- G41 scripting
- G42 VJ features
- ST 2110 and IPMX
- depth/lidar SDKs in the open build (plugin boundary only, DESIGN §21, B53)
- laser

## 5. Layer channel budget (decide before 1.0)

Channels 52–64 (13) are reserved; 51 is Sync. These candidates compete for them:

| Candidate | Channels | From |
|---|---|---|
| Transition type and transition parameter | 2 | G5 |
| Layer mask folder and file | 2 | G7 |
| Third effect slot with parameters A and B | 3 | Pandoras Box has 3 slots × 9 params |
| Geometry | 1 | B9, DESIGN §21 |
| Rotation pivot X/Y | 2–4 | Pandoras Box |
| Continuous rotation speed | 1 | Pandoras Box |
| Frame blending | 0 | a layer setting, not a channel |

Mbox uses 84 channels per layer, Pandoras Box 97, and Ai offers 40, 80 or 100.
Going past 64 would break eight layers per universe.

**Suggestion:** reserve three groups in one GDTF revision before 1.0.

| Channels | Use |
|---|---|
| 52–53 | transition |
| 54–55 | mask |
| 56 | Geometry |
| 57–64 | kept free |

## 6. Where Fanous leads (keep it, and say it)

- **Browser UI.** No console-native server has a browser UI for any number of
  operators with roles and passwords.
  - Mbox Director and Remote are native Mac apps, Zookeeper is Windows, and
    QLab Remote is iOS.
  - The closest is Modulo Kinetic Panel, a browser UI with accounts and a PIN,
    in the touring class.
- **Show day.** The surveyed docs mention no pre-show readiness check, show mode
  or show lock like ours.
- **GDTF.** Ours is generated from the parameter spec. Hippotizer's exporter can
  write empty files (4.9.0 release notes).
- **MSEX 1.2 with per-layer streams.** This matches Mbox and MediaMaster 6.4.
  None of the six touring servers documents MSEX; Pandoras Box exchanges
  thumbnails only.
- **Free and open, with CITP and GDTF built.** Fanous is free with no
  watermark and no licence key; CITP and GDTF are not yet tested on a real
  desk (B7, B40). No open-source rival has CITP or GDTF.
- **Apple Silicon native.** Among console-native servers only Mbox is too;
  MediaMaster has announced it.

## 7. Verification and open checks

**Re-read by hand on 2026-10-28:**
- The grandMA3 protocol page: no CITP. The page body says version 2.4.
- MA forum thread 7703: "Not yet - afaik" (2022).
- The ChamSys MediaMaster 26.0 post: macOS in 27.0.
- The PRG Mbox page: v5.6, Apple Silicon, paid annual licence.

The Eos video-stream page returned 404. Everything else is as the surveys
reported it.

**Unverified or conflicting:**
- Eos SRT/RTSP input (G25).
- Which capture cards appear as AVFoundation devices on macOS (G1); check each
  vendor's driver.
- ChamSys's free 8-layer server against the removal of MagicHD.
- Hippotizer hot backup.
- Which desks take CITP (MA2, Hog 4, Onyx, Titan) and Eos having none come
  from the console survey and were not re-read.
- Pandoras Box V10 DMX tables (the 8.11 help file was used).
- NDI SDK, read on 2026-10-28 (licence text of 2025-08-21). Two points are
  open: whether `libndi.dylib` may be bundled (NDI licence §2d), and whether the 6.3.2
  licence differs (B74).

## 8. Sources (main pages per product)

- **Console-native servers**
  - Hippotizer: <https://www.manula.com/manuals/green-hippo/hippotizer-v4/4.9.5/en/topic/release-notes>, <https://support.green-hippo.com/hc/en-gb/articles/39544854912914-Hippotizer-version-4-9-5>
  - Avolites Ai: <https://www.avolites.com/app/uploads/2025/12/Ai-v12.2-Manual.pdf>, NDI note <https://www.avolites.com/avolites-release-titan-v19-important-information>
  - PRG Mbox: <https://www.prg.com/en/technology/innovation/mbox-designer> (v5.6 manual and release notes linked there)
  - MediaMaster: <https://chamsyslighting.com/chamsys-officially-releases-mediamaster-26-0-stable/>, <https://docs.chamsys.co.uk/mediamaster/manual/introduction.html>, <https://www.tpimagazine.com/chamsys-acquires-arkaos-mediamaster/>
  - Catalyst: <http://www.arcus-lighting.com/en/catalyst/>
- **Touring/show servers**
  - disguise: <https://help.disguise.one/> (Sockpuppet personality editor, failover, OmniCal, r34 release notes)
  - Pixera: <https://help.pixera.one/en_US/> (Art-Net/sACN input patching, backup, mapping), <https://help.pixera.one/citp-thumbnail-exchange>
  - Watchout: <https://docs.dataton.com/watchout-7/print.html>, <https://dataton.com/watchout/release-notes>
  - Modulo Kinetic: <https://support.modulo-pi.com/modulo-kinetic-manual/v7/en/topic/version-7-0>
  - Pandoras Box: <https://www.twoloox.de/>, <https://pandorasboxhelpfile.com/home/dmx-table_video-layer.htm>
  - Smode: <https://doc.smode.io/>
- **Mac VJ/theatre**
  - Resolume: <https://resolume.com/support/en/>
  - Millumin: <https://help.millumin.com/docs/>
  - MadMapper: <https://docs.madmapper.com/madmapper/6/>
  - VDMX: <https://docs.vidvox.net/vdmx/>
  - QLab: <https://qlab.app/docs/v5/>
  - Isadora: <https://troikatronix.com/isadora/specifications/>
  - Mitti: <https://imimot.com/mitti/>
- **Consoles**
  - grandMA3: <https://help.malighting.com/grandMA3/2.5/HTML/network_design_protocols.html>, <https://forum.malighting.com/forum/thread/7703-is-citp-implemented/>
  - MagicQ: <https://docs.chamsys.co.uk/magicq/1.9.9.x/manual/media_servers.html>, <https://docs.chamsys.co.uk/magicq-change-notes/stable/version1-9-9/v1.9.9-change-notes.html>
  - Avolites: <https://manual.avolites.com/docs/networking/using-active-fixtures>
  - Onyx: <https://support.obsidiancontrol.com/Content/Onyx_Manual/Networking/CITP.htm>
  - Eos: <https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/GDTF>
- **Standards**
  - CITP spec (2020-11-27): <https://bitbucket.org/lars_wernlund/citp/downloads/master_2020-11-27.pdf>
  - GDTF/MVR: <https://github.com/mvrdevelopment/spec>
  - Art-Net 4 (rev 1.4dp): <https://art-net.org.uk/downloads/art-net.pdf>
  - PosiStageNet: <https://posistage.net>
  - NDI: <https://docs.ndi.video/docs/docs/release-notes>
- **Open source**
  - <https://github.com/testbild-media/OpenVideoServer>
  - <https://github.com/riskcapital/ghost-arcade>
  - <https://github.com/dio99/luxcanvas>
  - <https://github.com/arneBersch/dmxCanvas>
  - <https://github.com/jwfeniello/prismvj>
  - <https://github.com/fillinthe/phosphor>
