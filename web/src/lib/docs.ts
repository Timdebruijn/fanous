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
  ui: Record<string, unknown>;
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
};
