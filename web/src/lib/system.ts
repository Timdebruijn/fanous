// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers of the System / Health screen: clocks, readiness verdicts, the /metrics summary, the frame-time
// sparkline and the log filter. The screen stays thin so everything that can go wrong is tested here.
import type { ReadinessItemDoc } from './docs';
import type { Role } from './protocol';

export { LOCKED_TITLE } from './patch-screen';
export const OPERATOR_TITLE = 'Locked: operator or programmer';
export const ROLES: readonly Role[] = ['monitor', 'operator', 'programmer'];

/** Text colour of a stat: '' is the neutral colour (red = look now, yellow = attention). */
export type Tone = '' | 'yellow' | 'red';
export type DotTone = 'green' | 'yellow' | 'red' | 'off';

const pad = (n: number) => n.toString().padStart(2, '0');
const finite = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

/** The notice after show mode came back by itself (engine crash or kill); null when it was entered by hand. */
export function resumedText(resumedAt: number | null | undefined): string | null {
  if (!resumedAt || !(resumedAt > 0)) return null;
  const d = new Date(resumedAt * 1000);
  return `Show mode resumed after the engine restarted at ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** "h:mm:ss" */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.floor(finite(seconds)));
  return `${Math.floor(s / 3600)}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`;
}

/** "hh:mm:ss" in local time for a stamp in epoch seconds; 0 means it never happened. */
export function stampText(epochSeconds: number): string {
  if (!(epochSeconds > 0)) return 'never';
  const d = new Date(epochSeconds * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** "M4 Max · macOS 27.0 · engine 0.7.0 · up 1:02:03"; parts the engine has not published yet are left out. */
export function headerCaption(parts: { chip: string; os: string; version: string; uptimeSeconds: number }): string {
  return [parts.chip, parts.os, parts.version && `engine ${parts.version}`, `up ${formatClock(parts.uptimeSeconds)}`].filter(Boolean).join(' · ');
}

/** "never" for the engine's -1, else seconds with one decimal. */
export function ageText(seconds: number): string {
  return seconds < 0 ? 'never' : `${seconds.toFixed(1)} s`;
}

/** "62 % free · 64 GB" */
export function memoryText(freeFraction: number, gb: number): string {
  const free = `${Math.round(Math.min(1, Math.max(0, finite(freeFraction))) * 100)} % free`;
  return gb > 0 ? `${free} · ${gb} GB` : free;
}

export function thermalTone(thermal: string): DotTone {
  if (thermal === 'nominal') return 'green';
  return thermal === 'serious' || thermal === 'critical' ? 'red' : 'yellow';
}

export function outputTone(state: string): DotTone {
  return state === 'bound' ? 'green' : state === 'lost' ? 'red' : 'off';
}

/** One row of Capture permissions (B73): dot, word, whether Authorize shows, and the caption. A screen grant applies
 * to a new engine process (B125). An unknown state reads as denied for the dot and button but keeps its own word. */
export function permissionRow(kind: 'camera' | 'screen', state: string): { tone: DotTone; word: string; authorize: boolean; caption: string | null } {
  if (state === 'granted') return { tone: 'green', word: 'granted', authorize: false, caption: null };
  const word = state === 'notDetermined' ? 'not asked' : state;
  return { tone: 'yellow', word, authorize: true, caption: kind === 'screen' ? 'opens System Settings › Privacy & Security › Screen & System Audio Recording: allow Fanous, then Engine › Restart Engine' : null };
}

/** Dot colour and word of one readiness row (the word is the accessible name of the dot). */
export function readinessBadge(item: Pick<ReadinessItemDoc, 'state' | 'acknowledged'>): { tone: DotTone; label: string } {
  if (item.state === 'ok') return { tone: 'green', label: 'ok' };
  if (item.state === 'warn') return { tone: 'yellow', label: 'warning' };
  if (item.state === 'hard') return { tone: 'red', label: 'blocking' };
  if (item.state === 'fail') return item.acknowledged ? { tone: 'yellow', label: 'acknowledged' } : { tone: 'red', label: 'failed' };
  return { tone: 'off', label: 'manual' };
}

export interface ReadinessSummary {
  status: 'unchecked' | 'ready' | 'notReady';
  /** hard failures and failures nobody acknowledged: they refuse show mode */
  blocking: ReadinessItemDoc[];
}

export function readinessSummary(items: readonly ReadinessItemDoc[], checkedAt: number): ReadinessSummary {
  const blocking = items.filter((i) => i.state === 'hard' || (i.state === 'fail' && !i.acknowledged));
  return { status: blocking.length > 0 ? 'notReady' : checkedAt > 0 ? 'ready' : 'unchecked', blocking };
}

export interface AudioMetrics {
  callbacks: number;
  underruns: number;
  corrections: number;
  maxDriftMs: number;
}

export interface PreviewMetrics {
  framesIn: number;
  framesOut: number;
  skipped: number;
}

/** `GET /metrics`: the 1-second summary (Engine.swift). `audio` and `preview` exist only while those subsystems run. */
export interface Metrics {
  frames: number;
  missed: number;
  late: number;
  textureMisses: number;
  cpuMsP50: number;
  cpuMsP99: number;
  cpuMsMax: number;
  gpuMsP50: number;
  gpuMsP99: number;
  gpuMsMax: number;
  dmxToPhotonMsP50: number;
  dmxToPhotonMsP99: number;
  dmxSamples: number;
  windowSeconds: number;
  clients: number;
  lagging: number;
  showMode: boolean;
  uptimeSeconds: number;
  audio: AudioMetrics | null;
  preview: PreviewMetrics | null;
}

function numbers<K extends string>(value: unknown, keys: readonly K[]): Record<K, number> | null {
  if (typeof value !== 'object' || value === null) return null;
  const o = value as Record<string, unknown>;
  return Object.fromEntries(keys.map((k) => [k, finite(o[k])])) as Record<K, number>;
}

/** Anything missing or malformed becomes 0 (or null for the optional groups): a half-answered poll never throws. */
export function parseMetrics(value: unknown): Metrics {
  const o = (typeof value === 'object' && value !== null ? value : {}) as Record<string, unknown>;
  const n = (key: string) => finite(o[key]);
  return {
    frames: n('frames'), missed: n('missed'), late: n('late'), textureMisses: n('textureMisses'),
    cpuMsP50: n('cpuMsP50'), cpuMsP99: n('cpuMsP99'), cpuMsMax: n('cpuMsMax'),
    gpuMsP50: n('gpuMsP50'), gpuMsP99: n('gpuMsP99'), gpuMsMax: n('gpuMsMax'),
    dmxToPhotonMsP50: n('dmxToPhotonMsP50'), dmxToPhotonMsP99: n('dmxToPhotonMsP99'), dmxSamples: n('dmxSamples'),
    windowSeconds: n('windowSeconds'), clients: n('clients'), lagging: n('lagging'),
    showMode: o.showMode === true, uptimeSeconds: n('uptimeSeconds'),
    audio: numbers(o.audio, ['callbacks', 'underruns', 'corrections', 'maxDriftMs']),
    preview: numbers(o.preview, ['framesIn', 'framesOut', 'skipped']),
  };
}

export interface Tile {
  id: string;
  value: string;
  caption: string;
  note?: string;
  tone: Tone;
}

/** Dropped frames are a "look now" in show mode only; before the show they are just worth knowing. */
export function droppedTone(dropped: number, showMode: boolean): Tone {
  return dropped > 0 ? (showMode ? 'red' : 'yellow') : '';
}

/** The stat tiles of the Live metrics panel; `null` (nothing received yet) renders dashes. */
export function metricTiles(m: Metrics | null, showMode: boolean): Tile[] {
  const ms = (v: number) => v.toFixed(1);
  const triple = (a: number, b: number, c: number) => (m ? `${ms(a)} / ${ms(b)} / ${ms(c)}` : '—');
  const dropped = m ? m.missed + m.late : 0;
  const fps = m ? Math.round(m.windowSeconds > 0 ? m.frames / m.windowSeconds : m.frames) : 0;
  return [
    { id: 'fps', value: m ? String(fps) : '—', caption: 'fps · frames in the last second', tone: '' },
    { id: 'dropped', value: m ? String(dropped) : '—', caption: m ? `dropped · missed ${m.missed} + late ${m.late}` : 'dropped · missed + late', tone: droppedTone(dropped, showMode) },
    { id: 'gpu', value: triple(m?.gpuMsP50 ?? 0, m?.gpuMsP99 ?? 0, m?.gpuMsMax ?? 0), caption: 'GPU ms · p50 / p99 / max', tone: '' },
    { id: 'cpu', value: triple(m?.cpuMsP50 ?? 0, m?.cpuMsP99 ?? 0, m?.cpuMsMax ?? 0), caption: 'CPU ms · p50 / p99 / max', tone: '' },
    {
      id: 'dmx',
      value: m ? (m.dmxSamples > 0 ? `${ms(m.dmxToPhotonMsP50)} / ${ms(m.dmxToPhotonMsP99)}` : '—') + ` (${m.dmxSamples})` : '—',
      caption: 'DMX to photon ms · p50 / p99 (samples)',
      note: 'display scan-out not included',
      tone: '',
    },
    { id: 'textureMisses', value: m ? String(m.textureMisses) : '—', caption: 'texture misses', tone: m && m.textureMisses > 0 ? 'yellow' : '' },
    { id: 'clients', value: m ? String(m.clients) : '—', caption: m ? `clients · ${m.lagging} lagging` : 'clients · lagging', tone: m && m.lagging > 0 ? 'yellow' : '' },
    {
      id: 'preview',
      value: m?.preview ? `${m.preview.framesIn} / ${m.preview.framesOut} / ${m.preview.skipped}` : '—',
      caption: m && !m.preview ? 'preview frames · no encoder running' : 'preview frames · in / out / skipped',
      tone: '',
    },
    {
      id: 'audio',
      value: m?.audio ? `${m.audio.underruns} / ${m.audio.corrections} / ${m.audio.maxDriftMs.toFixed(1)} ms` : '—',
      caption: m && !m.audio ? 'audio · no mixer running' : 'audio · underruns / corrections / max drift',
      tone: m?.audio && m.audio.underruns > 0 ? 'yellow' : '',
    },
  ];
}

/** Appends to a rolling history of at most `max` values. */
export function pushHistory(history: readonly number[], value: number, max = 60): number[] {
  return [...history, value].slice(-max);
}

/**
 * Polyline points for a sparkline in a `width` x `height` box (2 px of padding so a 2 px stroke is not clipped).
 * The scale is the larger of `ceil` (e.g. the frame budget) and the data, so a calm trace stays low; `refY` is the
 * y of `ceil` for a reference line (null without one). Fewer than two values draw nothing.
 */
export function sparkline(values: readonly number[], width: number, height: number, ceil = 0): { points: string; refY: number | null } {
  const top = 2;
  const span = height - 2 * top;
  const max = Math.max(ceil, ...values, 0.001);
  const y = (v: number) => (top + span - (Math.max(0, v) / max) * span).toFixed(1);
  const step = values.length > 1 ? width / (values.length - 1) : 0;
  return {
    points: values.length < 2 ? '' : values.map((v, i) => `${(i * step).toFixed(1)},${y(v)}`).join(' '),
    refY: ceil > 0 ? Number(y(ceil)) : null,
  };
}

/** Case-insensitive substring filter over log lines; a trailing newline does not count as a line. */
export function filterLines(text: string, query: string): { text: string; shown: number; total: number } {
  if (text === '') return { text: '', shown: 0, total: 0 };
  const lines = text.replace(/\n$/, '').split('\n');
  const q = query.toLowerCase();
  const kept = q ? lines.filter((line) => line.toLowerCase().includes(q)) : lines;
  return { text: kept.join('\n'), shown: kept.length, total: lines.length };
}

/** `GET /api/session`: the roles that need no password, in role order; anything else is ignored. */
export function parseOpenRoles(value: unknown): Role[] {
  const open = (value as { open?: unknown } | null)?.open;
  return Array.isArray(open) ? ROLES.filter((role) => open.includes(role)) : [];
}
