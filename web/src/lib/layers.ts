// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers for the Layers / Mixer screen: formatting and lookups over the live document, no DOM, no store.
import type { LayerStatus, PatchEntry, ResolvedParameter } from './docs';

/** One entry of GET /api/channel-map.json `modes.*`; `channel` is the first (1-based) channel of the parameter. */
export interface ChannelSpec {
  name: string;
  key: string;
  channel: number;
  bits: number;
  default: number;
  group: string;
  unit: string;
  bands?: { from: number; to: number; name: string }[];
}

/** Folder 0 generators (engine `Generators.names`, DESIGN §8.2): drawn on the GPU, no files. */
export const GENERATORS: { file: number; name: string }[] = [
  { file: 110, name: 'Test card (timecode, frame flags)' },
  { file: 100, name: 'Solid colour (Red/Green/Blue channels)' },
  { file: 101, name: 'Grid' },
  { file: 102, name: 'Colour bars' },
  { file: 103, name: 'Blend check' },
  { file: 104, name: 'Output ID' },
  { file: 105, name: 'Crosshair' },
  { file: 106, name: 'Grey steps' },
  { file: 107, name: 'Checkerboard' },
  { file: 111, name: 'Colour sweep' },
  { file: 112, name: 'Clock' },
];

export interface ChannelMap {
  footprints: { layer: number; master: number; output: number };
  modes: { layer: ChannelSpec[]; master: ChannelSpec[]; output: ChannelSpec[] };
}

/** The part of GET /api/library the Layers screen reads (thumbnails only). */
export interface LibrarySnapshot {
  folders: { number: number; items: { folder: number; file: number; thumbnail?: string | null }[] }[];
  scannedAt: number;
}

export type Tone = 'normal' | 'faint' | 'error';
export type DotColor = 'red' | 'green' | 'off';

/** `mm:ss.s`, truncated to a tenth (never rounds 59.96 up to 60.0); minutes are not capped at 59. */
export function formatTime(seconds: number): string {
  const tenths = Math.floor((Number.isFinite(seconds) && seconds > 0 ? seconds : 0) * 10 + 1e-9);
  const minutes = Math.floor(tenths / 600);
  const rest = tenths % 600;
  return `${String(minutes).padStart(2, '0')}:${String(Math.floor(rest / 10)).padStart(2, '0')}.${rest % 10}`;
}

export function clampPercent(value: number): number {
  return Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0;
}

/** Playhead position of a movie in percent of its length. */
export function playedPercent(layer: LayerStatus | undefined): number {
  return layer && layer.frames > 0 ? clampPercent((layer.frame / layer.frames) * 100) : 0;
}

/** Caption under the scrubber: `elapsed / total` for movies, `still` / `live`, a dash when there is nothing to show. */
export function positionCaption(layer: LayerStatus | undefined): string {
  if (!layer) return '—';
  if (layer.kind === 'still') return 'still';
  if (layer.kind === 'live') return 'live';
  if (layer.kind !== 'movie') return '—';
  const fps = layer.fps > 0 ? layer.fps : Infinity; // no frame rate: both times read 00:00.0
  return `${formatTime(layer.frame / fps)} / ${formatTime(layer.frames / fps)}`;
}

/** Frame rates print without trailing zeros: 25, 29.97, 23.976. */
function fpsText(fps: number): string {
  return String(Number(fps.toFixed(3)));
}

const codecNames = new Map([
  ['apch', 'ProRes 422 HQ'], ['apcn', 'ProRes 422'], ['apcs', 'ProRes 422 LT'], ['apco', 'ProRes 422 Proxy'], ['ap4h', 'ProRes 4444'], ['ap4x', 'ProRes 4444 XQ'],
  ['Hap1', 'HAP'], ['Hap5', 'HAP Alpha'], ['HapY', 'HAP Q'], ['HapM', 'HAP Q Alpha'], ['HapA', 'HAP Alpha Only'], ['HapR', 'HAP R'],
  ['avc1', 'H.264'], ['hvc1', 'HEVC'], ['hev1', 'HEVC'],
]);

/** "apch" → "ProRes 422 HQ"; unknown codecs are shown as the engine names them. */
export function codecName(codec: string): string {
  return codecNames.get(codec) ?? codec;
}

/**
 * The media description in the layer list: `title` = "12 / 4 · intro_loop.mov", `detail` = "HAP Q · 1080p60";
 * `text` joins both. A decoder error or a missing file replaces the description.
 */
export function mediaLine(layer: LayerStatus | undefined): { text: string; title: string; detail: string; tone: Tone } {
  const line = (title: string, detail: string, tone: Tone) => ({ text: detail ? `${title} · ${detail}` : title, title, detail, tone });
  if (!layer) return line('no live data', '', 'faint');
  if (layer.kind === 'missing' || layer.error) return line(`${layer.folder} / ${layer.file}`, layer.error || 'File missing', 'error');
  const name = layer.name ?? '—';
  switch (layer.kind) {
    case 'none':
      return line('no media', '', 'faint');
    case 'live':
      return line(name, `Live · ${layer.width}×${layer.height}`, 'normal');
    case 'still':
      return line(`${layer.folder} / ${layer.file} · ${name}`, `Still · ${layer.width}×${layer.height}`, 'normal');
    default:
      return line(`${layer.folder} / ${layer.file} · ${name}`, `${codecName(layer.codec)} · ${layer.height}p${fpsText(layer.fps)}`, 'normal');
  }
}

/** Status dot: red only for a missing file or a decoder error, off without media, green otherwise. */
export function layerState(layer: LayerStatus | undefined): { dot: DotColor; label: string } {
  if (!layer || layer.kind === 'none') return { dot: 'off', label: 'No media' };
  if (layer.kind === 'missing' || layer.error) return { dot: 'red', label: 'Media missing or decoder error' };
  return { dot: 'green', label: 'Media OK' };
}

export function findParam(params: ResolvedParameter[] | undefined, key: string): ResolvedParameter | undefined {
  return params?.find((p) => p.key === key);
}

/** Up to one decimal, no trailing zero: 75, 75.3. */
export function formatPercent(value: number): string {
  return Number.isFinite(value) ? String(Math.round(value * 10) / 10) : '—';
}

/** The engine's own label ("Loop fwd", "75.3 %"); physical value and unit when it sent none. */
export function valueText(param: ResolvedParameter): string {
  return param.label || `${formatPercent(param.physical)}${param.unit ? ` ${param.unit}` : ''}`;
}

/** DMX channels of a parameter within its fixture: `3`, or `1–2` for a 16-bit coarse/fine pair. */
export function channelRange(spec: ChannelSpec | undefined): string {
  if (!spec) return '—';
  const last = spec.channel + Math.ceil(spec.bits / 8) - 1;
  return last > spec.channel ? `${spec.channel}–${last}` : String(spec.channel);
}

/** "Showing all 50 of 64 channels; 51–64 reserved" from the channel map. */
export function reservedText(specs: ChannelSpec[], footprint: number): string {
  const used = specs.reduce((max, s) => Math.max(max, s.channel + Math.ceil(s.bits / 8) - 1), 0);
  const shown = `Showing all ${used} of ${footprint} channels`;
  return used < footprint ? `${shown}; ${used + 1}–${footprint} reserved` : shown;
}

/** `artnet:0.0.1 · ch 145–208 · 64 ch`; address 0 is how patch.set unpatches. */
export function patchText(entry: PatchEntry | undefined, footprint: number): string {
  if (!entry || entry.address <= 0) return 'unpatched';
  return `${entry.universe} · ch ${entry.address}–${entry.address + footprint - 1} · ${footprint} ch`;
}

/** Fixture names "Output 1", "Output 2", … present in the live document, in numeric order. */
export function outputFixtures(fixtures: Record<string, unknown>): string[] {
  const number = (name: string) => Number(/^Output (\d+)$/.exec(name)?.[1] ?? NaN);
  return Object.keys(fixtures)
    .filter((name) => Number.isFinite(number(name)))
    .sort((a, b) => number(a) - number(b));
}

/** `folder/file` → thumbnail URL for every library item that has a thumbnail. */
export function thumbnailIndex(library: LibrarySnapshot | null): Map<string, string> {
  const index = new Map<string, string>();
  for (const folder of library?.folders ?? []) {
    for (const item of folder.items) {
      if (item.thumbnail) index.set(`${item.folder}/${item.file}`, `/api/thumbnail/${encodeURIComponent(item.thumbnail)}`);
    }
  }
  return index;
}

export function thumbnailFor(index: Map<string, string>, layer: LayerStatus | undefined): string | null {
  return layer ? (index.get(`${layer.folder}/${layer.file}`) ?? null) : null;
}
