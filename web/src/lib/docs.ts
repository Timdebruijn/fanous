// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Shapes of the `project` and `live` documents the engine publishes (DESIGN.md §11.2). The engine is the
// source of truth; every field here is optional-safe in the screens because a patch may arrive mid-render.

export interface PatchEntry {
  fixture: string; // "Layer 3", "Master", "Output 1"
  universe: string; // "artnet:0.0.1", "sacn:3"
  address: number; // 1-based
}

import type { CanvasConfig, DisplayDoc, OutputConfig, OutputStatusDoc } from './outputs';
import type { WallConfig } from './walls';

export interface ProjectDoc {
  schema: number;
  name: string;
  showLock: boolean;
  layerCount: number;
  patch: PatchEntry[];
  policy: 'dmx' | 'internal' | 'ltp' | 'htp';
  library: { root: string };
  canvases: CanvasConfig[];
  /** layer number → canvas id; a layer not listed is on canvas 1 (`layer.set`) */
  layerCanvas?: Record<string, number>;
  /** Syphon numbering by folder 0 file "150"–"169" (B69): written by the engine, freed by `syphon.forget` */
  syphon?: Record<string, { app: string; server: string }>;
  /** per-universe receive settings (`universe.set`, B28); a universe without an entry runs the defaults */
  universes?: UniverseSettingsDoc[];
  outputs: OutputConfig[];
  /** projector walls (`wall.*`, DESIGN §9.9); absent in projects saved before walls existed */
  walls?: WallConfig[];
  /** cue list (DESIGN §15.2): fixture and parameter by name, raw DMX values */
  cues: CueDoc[];
  timecode: TimecodeSettingsDoc;
  /** MIDI control (DESIGN §15.4, B36); absent until first set */
  midi?: MIDISettingsDoc;
  ui: Record<string, unknown>;
}

export interface UniverseSettingsDoc {
  id: string; // "artnet:0.0.1", "sacn:3"
  protocol: 'artnet' | 'sacn' | 'both';
  interface: string; // "any", "en0" or an IPv4 address
  holdOnLoss: 'hold' | 'zero' | 'internal';
  lossTimeout: number; // seconds
  sacnPriorityMode: 'highest' | 'htp';
  pair: string; // the other protocol's universe
}

export interface CueValueDoc {
  fixture: string; // "Layer 3" | "Master" | "Output 1"
  parameter: string; // parameter key, e.g. "intensity", "playMode"
  raw: number;
  fade?: number; // seconds, overrides the cue's fade
}

export interface CueDoc {
  id: string;
  number: number;
  name: string;
  fade: number; // seconds
  values: CueValueDoc[];
  trigger?: string | null; // "hh:mm:ss:ff@25" (rates: 24, 25, 29.97df, 30)
  follow?: number | null; // seconds after which the next cue fires
}

export interface TimecodeSettingsDoc {
  source: 'off' | 'ltc' | 'mtc';
  device: string | null;
  channel: number;
  offset: number; // frames
  freewheel: number; // seconds
  layerOffsets: Record<string, number>; // layer number → frames
  enabled?: boolean | null; // the operator's switch; missing or null = on
}

export interface MIDIMappingDoc {
  id: string;
  source?: string | null; // MIDI source name; missing = any source
  channel: number; // 1–16, 0 = any
  kind: 'note' | 'cc' | 'cc14' | 'pc';
  number?: number | null; // note / controller (cc14: MSB 0–31) / program; missing on pc = any program
  target: string; // "cue.go" | "cue.back" | "cue.goto" | "fixture:Layer 3/intensity" | "master/intensity"
  cue?: number | null; // cue.goto
  curve: 'linear' | 'toggle';
  pickup: boolean;
  low: number; // 0–1 of the parameter's range
  high: number;
}

export interface MIDISettingsDoc {
  source?: string | null; // missing or null = every source
  mscDevice: number; // 0–111; the all-call 127 is always answered
  mscFormat?: number | null; // MSC command format answered; missing/null = video 0x30–0x3F; all-types 0x7F always
  map: MIDIMappingDoc[];
}

export interface ResolvedParameter {
  key: string;
  name: string;
  raw: number;
  physical: number;
  label: string;
  unit: string;
  source: 'none' | 'dmx' | 'cue' | 'osc' | 'ui' | 'midi';
}

export interface UniverseInfo {
  id: string;
  active: boolean;
  packets: number;
  source: string;
  ageSeconds: number; // -1 = never seen
}

export interface LayerStatus {
  index: number; // 1-based
  folder: number;
  file: number;
  name: string | null; // resolved file name, "Syphon: …" for live inputs
  kind: 'movie' | 'still' | 'live' | 'none' | 'missing';
  codec: string;
  width: number;
  height: number;
  fps: number;
  frames: number;
  frame: number; // current frame index
  error: string | null;
  /** Layer channel 51 (B60, DESIGN §23); absent from engines before B60. */
  sync?: LayerSyncDoc;
}

/** A group's master as the engine saw it; `name` only for a master on the engine's own machine. */
export interface SyncMasterDoc {
  machine: string;
  layer: number;
  name?: string;
}

/** `live.layers[n].sync`: state, offset and master only for a slave; state null = no movie playing on it. */
export interface LayerSyncDoc {
  role: 'off' | 'master' | 'slave';
  group?: number;
  state?: 'locked' | 'freewheel' | 'lost' | 'noMaster' | 'conflict' | null;
  offsetMs?: number;
  master?: SyncMasterDoc | null;
}

/** `live.sync`: this machine's id, the settings, packet totals, the fresh master per group ("1"–"8"), groups with two masters. */
export interface SyncLiveDoc {
  machine: string;
  interface: string;
  port: number;
  target: string;
  packetsIn: number;
  packetsOut: number;
  decodeErrors: number;
  masters: Record<string, SyncMasterDoc>;
  conflicts: number[];
}

/** A Syphon server of another app as folder 0 file 150–169 (B61); a gone server keeps its number, running false. */
export interface SyphonServerDoc {
  file: number;
  app: string;
  server: string; // "" = the app's only, unnamed server
  running: boolean;
  /** from the project and not announced since the engine started (B69) */
  gone?: true;
}

/** A camera or capture card (folder 0 files 1–20) or a display (21–28), numbered like a Syphon server (B73, DESIGN §8.2.1). */
export interface CaptureSourceDoc {
  file: number;
  name: string;
  running: boolean;
  /** from the project and not seen since the engine started */
  gone?: true;
  /** connected but opened by another app (Continuity Camera in FaceTime), sent with running true; devices only (a display has none) */
  inUse?: true;
}

/** `live.capture` (B73 step 2): absent from engines before it; `screens` and `permissions` may be missing from a partial feed. */
export interface CaptureLiveDoc {
  devices: CaptureSourceDoc[];
  screens?: CaptureSourceDoc[];
  /** screen `pending`: after Authorize screen, while the engine polls for the grant and then restarts itself (step 3) */
  permissions?: { camera: 'granted' | 'denied' | 'notDetermined'; screen: 'granted' | 'denied' | 'pending' };
}

export interface IngestJobDoc {
  id: string;
  source: string;
  destination: string;
  kind: unknown;
  state: unknown; // {queued:{}} | {running:{progress}} | {done:{}} | {failed:{_0}} | {cancelled:{}}
  queuedAt?: string;
}

export interface LiveDoc {
  /** What renders (B31); pending = the project asks for another canvas (deferred in show mode); error = last failed switch. Absent before the first live update. */
  canvas?: { width: number; height: number; fps: number; canvases?: { id: number; width: number; height: number }[]; pending: boolean; error: string | null } | null;
  engine: { version: string; chip: string; uptimeSeconds: number; rendering: boolean };
  metrics: {
    frames: number;
    missed: number;
    late: number;
    textureMisses: number;
    cpuP50: number;
    cpuP99: number;
    gpuP50: number;
    gpuP99: number;
    dmxP99: number;
  };
  dmx: {
    universes: UniverseInfo[];
    fixtures: Record<string, ResolvedParameter[]>;
    policies: Record<string, string>;
    internalValues: Record<string, { key: string; raw: number; source: string }[]>;
    /** Seconds until a fixture's UI values are released; only fixtures whose console is being received (B27). */
    uiExpiresIn: Record<string, number>;
  };
  layers: LayerStatus[];
  ingest: IngestJobDoc[];
  library: { root: string; rootExists: boolean; folders: number; fileCount: number; invalidCount: number; scannedAt: number };
  clients: { count: number; lagging: number };
  security: { webUIOpen: boolean };
  displays: DisplayDoc[];
  outputs: OutputStatusDoc[];
  timecode: { state: 'off' | 'locked' | 'freewheel' | 'lost'; source: string; value: string; rate: string; frames: number; seen: number; error: string | null; device: string };
  cue: { current: number | null; currentName: string | null; next: number | null; nextName: string | null; fading: boolean; count: number };
  /** resumedAt: epoch seconds when show mode came back by itself after an unclean engine stop; null otherwise. */
  show: { mode: boolean; checkedAt: number; ready: boolean; readiness: ReadinessItemDoc[]; resumedAt?: number | null };
  system: {
    thermal: 'nominal' | 'fair' | 'serious' | 'critical';
    onAC: boolean;
    power: string;
    memoryFreeFraction: number;
    memoryGB: number;
    os: string;
    host: string;
    addresses: string[];
    /** every IPv4 interface address, loopback included (universe Interface choices); broadcast and multicast: usable for sync */
    interfaces?: { name: string; address: string; broadcast?: boolean; multicast?: boolean }[];
    port: number;
    tlsFingerprint: string;
    bonjour: string;
  };
  osc: { port: number; recent: { at: number; command: string }[]; midiSources: string[]; audioInputs: string[] };
  /** MIDI control input: sources listened to, the last message ("source · ch 1 · note 36 on · 127"), learn state;
   * error also lists map entries that cannot be read or cannot work. */
  midi: {
    connected: string[];
    last: string | null;
    lastAt: number | null;
    learning: { target: string; cue: number | null } | null;
    learned: string | null;
    error: string | null;
  };
  /** CITP/MSEX media-server side: TCP port advertised by PLoc, connected consoles, open streams. */
  citp: { port: number; clients: string[]; streams: number; multicast: string[] };
  /** Project versions (B23): when the last automatic version was saved (epoch s, null = none) and a counter bumped on every save or delete. */
  versions?: { lastAutomatic: number | null; serial: number } | null;
  /** Other apps' Syphon servers, numbered in folder 0 (B61). Absent from engines before B61. */
  syphon?: { servers: SyphonServerDoc[]; /** running servers past the 20 numbers, "App/Server" (B69) */ unnumbered?: string[] };
  /** Cameras, capture cards and displays in folder 0 with the permissions (B73). Absent from engines before B73 step 2. */
  capture?: CaptureLiveDoc;
  /** Multi-server sync (B60); null without rendering, absent from engines before B60. */
  sync?: SyncLiveDoc | null;
}

export interface ReadinessItemDoc {
  id: string;
  title: string;
  state: 'ok' | 'warn' | 'fail' | 'manual' | 'hard';
  detail: string;
  fix: string;
  acknowledged: boolean;
}

export const emptyProject: ProjectDoc = {
  schema: 1,
  name: '',
  showLock: false,
  layerCount: 0,
  patch: [],
  policy: 'dmx',
  library: { root: '' },
  canvases: [],
  layerCanvas: {},
  outputs: [],
  cues: [],
  timecode: { source: 'off', device: null, channel: 0, offset: 0, freewheel: 2, layerOffsets: {} },
  ui: {},
};

export const emptyLive: LiveDoc = {
  engine: { version: '', chip: '', uptimeSeconds: 0, rendering: false },
  metrics: { frames: 0, missed: 0, late: 0, textureMisses: 0, cpuP50: 0, cpuP99: 0, gpuP50: 0, gpuP99: 0, dmxP99: 0 },
  dmx: { universes: [], fixtures: {}, policies: {}, internalValues: {}, uiExpiresIn: {} },
  layers: [],
  ingest: [],
  library: { root: '', rootExists: false, folders: 0, fileCount: 0, invalidCount: 0, scannedAt: 0 },
  clients: { count: 0, lagging: 0 },
  security: { webUIOpen: false },
  displays: [],
  outputs: [],
  timecode: { state: 'off', source: '', value: '--:--:--:--', rate: '25', frames: 0, seen: 0, error: null, device: '' },
  cue: { current: null, currentName: null, next: null, nextName: null, fading: false, count: 0 },
  show: { mode: false, checkedAt: 0, ready: false, readiness: [], resumedAt: null },
  system: { thermal: 'nominal', onAC: true, power: '', memoryFreeFraction: 1, memoryGB: 0, os: '', host: '', addresses: [], port: 8443, tlsFingerprint: '', bonjour: '' },
  osc: { port: 8000, recent: [], midiSources: [], audioInputs: [] },
  midi: { connected: [], last: null, lastAt: null, learning: null, learned: null, error: null },
  citp: { port: 0, clients: [], streams: 0, multicast: [] },
};
