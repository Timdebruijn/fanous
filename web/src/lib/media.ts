// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers of the Media screen: library shapes (LibraryIndex.swift), codec and job-state names for what Swift's
// synthesized Codable writes (IngestQueue.swift, MovieWriter.swift), formatting and filtering.
import type { IngestJobDoc } from './docs';

export { LOCKED_TITLE } from './patch-screen';

export interface MediaMetadata {
  width: number;
  height: number;
  frameRate: number;
  duration: number;
  codec: string; // fourcc ("apch", "HapY") or "png" etc.
  hasAlpha: boolean;
  audioChannels: number;
  audioSampleRate: number;
  frameCount: number;
}

export interface LibraryItem {
  folder: number;
  file: number | null; // null = invalid name
  name: string;
  path: string;
  kind: 'movie' | 'still' | 'sequence' | 'other';
  status: 'playable' | 'needsTranscode' | 'invalid' | 'unreadable' | 'probing';
  reason: string | null;
  metadata: MediaMetadata | null;
  thumbnail: string | null;
}

export interface LibraryFolder {
  number: number | null; // null = invalid folder name
  name: string;
  path: string;
  items: LibraryItem[];
}

export interface LibrarySnapshot {
  root: string;
  rootExists: boolean;
  folders: LibraryFolder[];
  scannedAt: number;
  fileCount: number;
  invalidCount: number;
}

/** The names `POST /api/ingest` takes (IngestAPI.codec(named:)); the first is the default. */
export const transcodeCodecs = [
  { value: 'hapq', label: 'HAP Q' },
  { value: 'hap', label: 'HAP' },
  { value: 'hapalpha', label: 'HAP Alpha' },
  { value: 'prores422hq', label: 'ProRes 422 HQ' },
  { value: 'prores4444', label: 'ProRes 4444' },
] as const;

// MARK: library

const fourCCNames = new Map([
  ['apch', 'ProRes 422 HQ'],
  ['apcn', 'ProRes 422'],
  ['apcs', 'ProRes 422 LT'],
  ['apco', 'ProRes 422 Proxy'],
  ['ap4h', 'ProRes 4444'],
  ['ap4x', 'ProRes 4444 XQ'],
  ['Hap1', 'HAP'],
  ['Hap5', 'HAP Alpha'],
  ['HapY', 'HAP Q'],
  ['HapM', 'HAP Q Alpha'],
  ['HapA', 'HAP Alpha Only'],
  ['HapR', 'HAP R'],
  ['avc1', 'H.264'],
  ['hvc1', 'HEVC'],
  ['hev1', 'HEVC'],
  ['generator', 'Built-in'],
]);

/** Display name of a probed codec or a layer's codec ("generator" for folder 0); unknown ones stay as they are (the badge upper-cases them). */
export function codecLabel(codec: string): string {
  return fourCCNames.get(codec) ?? codec;
}

/** "m:ss.s", tenths rounded as a whole so 59.96 s reads 1:00.0, never 0:60.0. */
export function formatDuration(seconds: number): string {
  const tenths = Math.round(Math.max(0, seconds) * 10);
  const minutes = Math.floor(tenths / 600);
  return `${minutes}:${((tenths % 600) / 10).toFixed(1).padStart(4, '0')}`;
}

/** Text of the tile's bottom-right badge; null while nothing is known. */
export function durationBadge(item: LibraryItem): string | null {
  if (item.kind === 'still') return 'still';
  const meta = item.metadata;
  if (!meta) return null;
  if (item.kind === 'sequence') return meta.frameCount > 0 ? `${meta.frameCount} frames` : null;
  return meta.duration > 0 ? formatDuration(meta.duration) : null;
}

/** "1080p25" (rate without a trailing .0, 29.97 stays 29.97); "1920×1080" where there is no frame rate (stills, sequences). */
export function formatLabel(meta: MediaMetadata): string {
  if (meta.height <= 0) return '';
  if (meta.frameRate > 0) return `${meta.height}p${Number(meta.frameRate.toFixed(3))}`;
  return meta.width > 0 ? `${meta.width}×${meta.height}` : `${meta.height}p`;
}

/** "48k" / "44.1k"; empty when there is no audio track. */
export function audioLabel(meta: MediaMetadata): string {
  return meta.audioChannels > 0 && meta.audioSampleRate > 0 ? `${Number((meta.audioSampleRate / 1000).toFixed(1))}k` : '';
}

/** Names carry their number ("012_Show"); the number has its own badge, so the list shows the rest. */
export function displayName(name: string, numbered: boolean): string {
  if (!numbered) return name;
  const rest = name.replace(/^\d{1,3}[ _-]*/, '');
  return rest === '' || rest.startsWith('.') ? name : rest;
}

/** Items that are red: invalid names, plus everything in a folder whose own name is invalid. */
export function invalidCount(items: LibraryItem[]): number {
  return items.filter((item) => item.status === 'invalid' || item.file === null).length;
}

/** First numbered folder, else the first folder. */
export function defaultFolder(folders: LibraryFolder[]): LibraryFolder | undefined {
  return folders.find((folder) => folder.number !== null) ?? folders[0];
}

export function filterItems(items: LibraryItem[], query: string): LibraryItem[] {
  const needle = query.trim().toLowerCase();
  return needle === '' ? items : items.filter((item) => item.name.toLowerCase().includes(needle));
}

export function basename(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1);
}

/** The last `parts` path components: "…/003_Intro/012_clip.mov" → "003_Intro/012_clip.mov". */
export function pathTail(path: string, parts = 2): string {
  return path.split('/').filter(Boolean).slice(-parts).join('/');
}

// MARK: ingest jobs

type Obj = Record<string, unknown>;

function obj(value: unknown): Obj | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Obj) : undefined;
}

/** Swift writes an enum case as `{"caseName": {…payload…}}`; returns the name and the payload. */
function enumCase(value: unknown): [name: string, payload: Obj] | undefined {
  const o = obj(value);
  const name = o && Object.keys(o)[0];
  return o && name !== undefined ? [name, obj(o[name]) ?? {}] : undefined;
}

const hapVariants = new Map([
  ['hap', 'HAP'],
  ['hapAlpha', 'HAP Alpha'],
  ['hapQ', 'HAP Q'],
  ['hapAlphaOnly', 'HAP Alpha Only'],
]);

/** `MovieWriter.Codec`: {"proRes422HQ":{}} · {"hap":{"_0":"hapQ"}}. */
function codecName(codec: unknown): string {
  const c = enumCase(codec);
  switch (c?.[0]) {
    case 'proRes422HQ':
      return 'ProRes 422 HQ';
    case 'proRes422':
      return 'ProRes 422';
    case 'proRes4444':
      return 'ProRes 4444';
    case 'hap':
      return hapVariants.get(String(c[1]._0)) ?? 'HAP';
    default:
      return 'Unknown';
  }
}

/** `IngestJob.Kind`: {"transcode":{"codec":…}} · {"sequence":{"fps":25,"codec":…}} · {"still":{}}. */
export function describeCodec(kind: unknown): string {
  const k = enumCase(kind);
  switch (k?.[0]) {
    case 'still':
      return 'Still';
    case 'transcode':
    case 'sequence':
      return codecName(k[1].codec);
    default:
      return 'Unknown';
  }
}

export type JobLabel = 'queued' | 'transcoding' | 'done' | 'failed' | 'cancelled';

export interface JobState {
  label: JobLabel;
  progress: number; // 0–1
  error?: string;
}

/** `IngestJob.State`: {"queued":{}} · {"running":{"progress":0.4}} · {"done":{}} · {"failed":{"_0":"…"}} · {"cancelled":{}}. */
export function describeJobState(state: unknown): JobState {
  const s = enumCase(state);
  switch (s?.[0]) {
    case 'running': {
      const progress = Number(s[1].progress);
      return { label: 'transcoding', progress: Number.isFinite(progress) ? Math.min(1, Math.max(0, progress)) : 0 };
    }
    case 'done':
      return { label: 'done', progress: 1 };
    case 'failed':
      return { label: 'failed', progress: 0, error: typeof s[1]._0 === 'string' ? s[1]._0 : 'unknown error' };
    case 'cancelled':
      return { label: 'cancelled', progress: 0 };
    default:
      return { label: 'queued', progress: 0 };
  }
}

export function isActive(label: JobLabel): boolean {
  return label === 'queued' || label === 'transcoding';
}

/** Newest first (the engine lists oldest first), jobs that are still going ahead of the finished ones. */
export function orderJobs(jobs: IngestJobDoc[]): IngestJobDoc[] {
  const newest = [...jobs].reverse();
  const active = (job: IngestJobDoc) => isActive(describeJobState(job.state).label);
  return [...newest.filter(active), ...newest.filter((job) => !active(job))];
}

export function queueSummary(jobs: IngestJobDoc[]): { running: number; queued: number } {
  const labels = jobs.map((job) => describeJobState(job.state).label);
  return { running: labels.filter((l) => l === 'transcoding').length, queued: labels.filter((l) => l === 'queued').length };
}

/** Sources with a job still going: their Transcode button must not queue a second one. */
export function activeSources(jobs: IngestJobDoc[]): Set<string> {
  return new Set(jobs.filter((job) => isActive(describeJobState(job.state).label)).map((job) => job.source));
}

// MARK: requests

/** Sends a state-changing request; resolves to an error message, or null when the engine accepted it. */
export async function send(url: string, init: RequestInit): Promise<string | null> {
  try {
    const response = await fetch(url, init);
    if (response.ok) return null;
    return `${response.status} ${(await response.text()).trim() || response.statusText}`.trim();
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}
