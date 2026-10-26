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

export interface ProjectDoc {
  schema: number;
  name: string;
  showLock: boolean;
  layerCount: number;
  patch: PatchEntry[];
  policy: 'dmx' | 'internal' | 'ltp' | 'htp';
  library: { root: string };
  canvases: CanvasConfig[];
  outputs: OutputConfig[];
  /** cue list (DESIGN §15.2): fixture and parameter by name, raw DMX values */
  cues: CueDoc[];
  timecode: TimecodeSettingsDoc;
  ui: Record<string, unknown>;
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

export interface ResolvedParameter {
  key: string;
  name: string;
  raw: number;
  physical: number;
  label: string;
  unit: string;
  source: 'none' | 'dmx' | 'cue' | 'osc' | 'ui';
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
  show: { mode: boolean; checkedAt: number; ready: boolean; readiness: ReadinessItemDoc[] };
  system: {
    thermal: 'nominal' | 'fair' | 'serious' | 'critical';
    onAC: boolean;
    power: string;
    memoryFreeFraction: number;
    memoryGB: number;
    os: string;
    host: string;
    addresses: string[];
    port: number;
    tlsFingerprint: string;
    bonjour: string;
  };
  osc: { port: number; recent: { at: number; command: string }[]; midiSources: string[]; audioInputs: string[] };
  /** CITP/MSEX media-server side: TCP port advertised by PLoc, connected consoles, open streams. */
  citp: { port: number; clients: string[]; streams: number; multicast: string[] };
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
  outputs: [],
  cues: [],
  timecode: { source: 'off', device: null, channel: 0, offset: 0, freewheel: 2, layerOffsets: {} },
  ui: {},
};

export const emptyLive: LiveDoc = {
  engine: { version: '', chip: '', uptimeSeconds: 0, rendering: false },
  metrics: { frames: 0, missed: 0, late: 0, textureMisses: 0, cpuP50: 0, cpuP99: 0, gpuP50: 0, gpuP99: 0, dmxP99: 0 },
  dmx: { universes: [], fixtures: {}, policies: {}, internalValues: {} },
  layers: [],
  ingest: [],
  library: { root: '', rootExists: false, folders: 0, fileCount: 0, invalidCount: 0, scannedAt: 0 },
  clients: { count: 0, lagging: 0 },
  security: { webUIOpen: false },
  displays: [],
  outputs: [],
  timecode: { state: 'off', source: '', value: '--:--:--:--', rate: '25', frames: 0, seen: 0, error: null, device: '' },
  cue: { current: null, currentName: null, next: null, nextName: null, fading: false, count: 0 },
  show: { mode: false, checkedAt: 0, ready: false, readiness: [] },
  system: { thermal: 'nominal', onAC: true, power: '', memoryFreeFraction: 1, memoryGB: 0, os: '', host: '', addresses: [], port: 8443, tlsFingerprint: '', bonjour: '' },
  osc: { port: 8000, recent: [], midiSources: [], audioInputs: [] },
  citp: { port: 0, clients: [], streams: 0, multicast: [] },
};
