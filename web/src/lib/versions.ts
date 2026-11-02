// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Project versions (B23): the `project.versions` result, row texts and when a revert is allowed.
import { LOCKED_TITLE } from './patch-screen';

/** One entry of `project.versions`, newest first. `at` is epoch seconds. */
export interface ProjectVersion {
  id: string;
  at: number;
  name: string;
  automatic: boolean;
  layers: number;
  outputs: number;
  canvases: number;
  cues: number;
}

const count = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

/** Entries without an id or a time are dropped; a malformed answer is an empty list. */
export function parseVersions(value: unknown): ProjectVersion[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((raw) => {
    const o = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>;
    if (typeof o.id !== 'string' || o.id === '' || typeof o.at !== 'number') return [];
    return [{
      id: o.id, at: o.at, name: typeof o.name === 'string' ? o.name : o.id, automatic: o.automatic !== false,
      layers: count(o.layers), outputs: count(o.outputs), canvases: count(o.canvases), cues: count(o.cues),
    }];
  });
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** "8 layers · 2 outputs · 1 canvas · 12 cues" */
export function versionSummary(v: ProjectVersion): string {
  return [plural(v.layers, 'layer'), plural(v.outputs, 'output'), plural(v.canvases, 'canvas', 'canvases'), plural(v.cues, 'cue')].join(' · ');
}

const pad = (n: number) => n.toString().padStart(2, '0');

/** Local time: "14:30" today, "25 Oct 14:30" on another day of the year, with the year when it differs. */
export function versionTime(at: number, now: Date = new Date()): string {
  const d = new Date(at * 1000);
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === now.toDateString()) return time;
  const day = `${d.getDate()} ${d.toLocaleString('en-GB', { month: 'short' })}`;
  return d.getFullYear() === now.getFullYear() ? `${day} ${time}` : `${day} ${d.getFullYear()} ${time}`;
}

/** Status bar caption: when the engine last saved an automatic version. */
export function lastVersionText(lastAutomatic: number | null | undefined, now: Date = new Date()): string {
  return lastAutomatic && lastAutomatic > 0 ? versionTime(lastAutomatic, now) : 'none yet';
}

/** Why a revert is not possible right now (the engine refuses the same cases); null when it is. */
export function revertBlocked(state: { programmer: boolean; showLock: boolean; showMode: boolean }): string | null {
  if (!state.programmer) return LOCKED_TITLE;
  if (state.showLock) return 'The show is locked; unlock it first';
  if (state.showMode) return 'Leave show mode first';
  return null;
}
