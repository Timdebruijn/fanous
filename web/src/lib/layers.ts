// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers for the Layers / Mixer screen: formatting and lookups over the live document, no DOM, no store.
import type { CaptureLiveDoc, LayerStatus, PatchEntry, ProjectDoc, ResolvedParameter, SyphonServerDoc } from './docs';

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
  { file: 113, name: 'Motion test (smoothness, frame-locked)' },
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

/** "App/Server", or "App" when the server has no name (engine `LiveCatalog.Entry.label`). */
export function syphonName(server: SyphonServerDoc): string {
  return server.server ? `${server.app}/${server.server}` : server.app;
}

/** One entry of folder 0: a generator, a camera or capture card (1–20), a display (21–28) or a Syphon server (150–169). */
export interface FolderZeroItem {
  file: number;
  name: string;
  kind: 'generator' | 'capture' | 'screen' | 'syphon';
  running: boolean;
  gone: boolean;
  inUse: boolean;
  label: string;
}

/** Folder 0 group headings, the same on the Media screen and in the layer panel's picker. */
export const ZERO_GROUPS: { kind: FolderZeroItem['kind']; title: string }[] = [
  { kind: 'generator', title: 'Built-in content' },
  { kind: 'capture', title: 'Cameras and capture cards (1–20)' },
  { kind: 'screen', title: 'Displays (21–28)' },
  { kind: 'syphon', title: 'Syphon servers (150–169)' },
];

/** Why a live input (camera, display, Syphon server) shows no picture, for the Media list; null while it runs (or for a generator). In use = connected, opened by another app (cameras only). */
export function zeroCaption(item: FolderZeroItem): string | null {
  if (item.inUse) return 'in use by another app';
  if (item.running) return null;
  return item.gone ? 'not seen since the engine started' : 'not running';
}

/** Folder 0 as a list: the generators, the cameras and capture cards, the displays (B73), then the Syphon servers of other apps by number (B61). */
export function folderZeroItems(servers: SyphonServerDoc[] | undefined, capture?: CaptureLiveDoc): FolderZeroItem[] {
  const live = (kind: FolderZeroItem['kind'], list: { file: number; name: string; running: boolean; gone?: true; inUse?: true }[]) =>
    [...list].sort((a, b) => a.file - b.file).map((s) => {
      const suffix = s.inUse ? ' (in use by another app)' : s.running ? '' : ' (not running)';
      return { file: s.file, name: s.name, kind, running: s.running, gone: s.gone === true, inUse: s.inUse === true, label: `${s.file} · ${s.name}${suffix}` };
    });
  return [
    ...GENERATORS.map((g) => ({ ...g, kind: 'generator' as const, running: true, gone: false, inUse: false, label: `${g.file} · ${g.name}` })),
    ...live('capture', capture?.devices ?? []),
    ...live('screen', capture?.screens ?? []),
    ...live('syphon', (servers ?? []).map((s) => ({ ...s, name: `Syphon: ${syphonName(s)}` }))),
  ];
}

export interface ChannelMap {
  footprints: { layer: number; master: number; output: number };
  modes: { layer: ChannelSpec[]; master: ChannelSpec[]; output: ChannelSpec[] };
}

/** The part of GET /api/library the Layers screen reads: thumbnails and the names for the media picker. */
export interface LibrarySnapshot {
  folders: { number: number | null; name?: string; items: { folder: number; file: number | null; name?: string; status?: string; thumbnail?: string | null }[] }[];
  scannedAt: number;
}

/**
 * Who controls (the source policy, DESIGN §6.6): the long label for the Patch card and messages, the short one for the
 * per-layer Source badge, the line under the card. The stored values stay dmx / internal / ltp / htp.
 */
export const POLICIES: Record<ProjectDoc['policy'], { label: string; short: string; line: string }> = {
  dmx: {
    label: 'Console only',
    short: 'Console',
    line: 'Fanous follows the console. A fixture without an address stays at its defaults; cues and OSC are recorded but do nothing.',
  },
  internal: { label: 'Fanous only (UI, cues, OSC, MIDI)', short: 'Fanous', line: 'The console is shown but ignored.' },
  ltp: { label: 'Console and Fanous, latest change wins', short: 'Both · latest', line: 'Per parameter, the latest change wins.' },
  htp: {
    label: 'Console and Fanous, highest value wins',
    short: 'Both · highest',
    line: 'Intensity and other numbers take the highest value; folder, file and modes the latest change.',
  },
};

/** The long label, or the short one for the Source badge; an unknown value is shown as is. */
export function policyName(policy: string, short = false): string {
  const p = POLICIES[policy as ProjectDoc['policy']];
  return p ? (short ? p.short : p.label) : policy;
}

export const RELEASE_TEXT = 'Console and this screen both control these values; whoever moved last wins. Release hands them back to the console.';

/** 462 → "7:42" for the UI-control expiry countdown. */
export function clockText(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** Which parameters the Layers screen offers for Master and Output fixtures (B27); layers show every channel. */
export function controlKeys(fixture: string): string[] | undefined {
  if (fixture === 'Master') return ['intensity', 'speed'];
  if (fixture.startsWith('Output ')) return ['intensity', 'testPattern'];
  return undefined;
}

/** "012_Intro" → "Intro" (the number has its own place in the label). */
function plainName(name: string): string {
  const rest = name.replace(/^\d{1,3}[ _-]*/, '');
  return rest === '' || rest.startsWith('.') ? name : rest;
}

/** "Folder 3 · Intro / 12 · loop.mov" from the library; null when the folder or file is not in it. */
export function mediaPath(library: LibrarySnapshot | null, folder: number, file: number): string | null {
  const f = library?.folders.find((x) => x.number === folder);
  const item = f?.items.find((x) => x.file === file);
  if (!f || !item?.name) return null;
  return `Folder ${folder}${f.name ? ` · ${plainName(f.name)}` : ''} / ${file} · ${item.name}`;
}

/** Every addressable, playable item in numeric order, labelled for a picker. */
export function mediaOptions(library: LibrarySnapshot | null): { folder: number; file: number; label: string }[] {
  const out: { folder: number; file: number; label: string }[] = [];
  for (const f of library?.folders ?? []) {
    if (f.number === null) continue;
    for (const item of f.items) {
      if (item.file === null || item.status === 'invalid' || item.status === 'unreadable') continue;
      out.push({ folder: f.number, file: item.file, label: mediaPath(library, f.number, item.file) ?? `Folder ${f.number} / ${item.file}` });
    }
  }
  return out.sort((a, b) => a.folder - b.folder || a.file - b.file);
}

/** The fixture.set calls that put a file on a layer: folder, file, and full intensity when it is at 0. */
export function playSteps(params: ResolvedParameter[] | undefined, folder: number, file: number): { parameter: string; raw: number }[] {
  const steps = [{ parameter: 'folder', raw: folder }, { parameter: 'file', raw: file }];
  if (params?.find((p) => p.key === 'intensity')?.raw === 0) steps.push({ parameter: 'intensity', raw: 65535 });
  return steps;
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
  ['avc1', 'H.264'], ['hvc1', 'HEVC'], ['hev1', 'HEVC'], ['generator', 'Built-in'],
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
  // a Syphon server that went keeps its name: "Syphon: App/Server · not running"
  if (layer.kind === 'live' && layer.error && layer.name) return line(layer.name, layer.error, 'error');
  if (layer.kind === 'missing' || layer.error) return line(`${layer.folder} / ${layer.file}`, layer.error || 'File missing', 'error');
  const name = layer.name ?? '—';
  switch (layer.kind) {
    case 'none':
      return line('no media', '', 'faint');
    case 'live':
      return line(name, layer.width > 0 ? `Live · ${layer.width}×${layer.height}` : 'Live', 'normal');
    case 'still':
      return line(`${layer.folder} / ${layer.file} · ${name}`, `Still · ${layer.width}×${layer.height}`, 'normal');
    default:
      return line(`${layer.folder} / ${layer.file} · ${name}`, `${codecName(layer.codec)} · ${layer.height}p${fpsText(layer.fps)}`, 'normal');
  }
}

/** Status dot plus the same state as a short word, so the colour never carries it alone. */
export function layerState(layer: LayerStatus | undefined): { dot: DotColor; label: string; chip: string } {
  if (!layer || layer.kind === 'none') return { dot: 'off', label: 'No media', chip: 'NO MEDIA' };
  if (layer.kind === 'missing') return { dot: 'red', label: 'Media file is missing', chip: 'MISSING FILE' };
  // Syphon: "not running" or "could not connect"
  if (layer.kind === 'live' && layer.error) return { dot: 'red', label: `Live input ${layer.error}`, chip: layer.error.toUpperCase() };
  if (layer.error) return { dot: 'red', label: 'Decoder error', chip: 'DECODER ERROR' };
  if (layer.kind === 'live') return { dot: 'green', label: 'Live input', chip: 'LIVE' };
  return { dot: 'green', label: 'Media OK', chip: 'OK' };
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

/** `artnet:0.0.1 · ch 145–208 · 64 ch`, or "no address" (address 0 is how patch.set unpatches; DESIGN §6.6). */
export function patchText(entry: PatchEntry | undefined, footprint: number): string {
  if (!entry || entry.address <= 0) return 'no address';
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

/** One frame of the `thumbs` stream (B29, engine `ThumbnailAtlas.frame`): `[u8 layer number][u16 be w][u16 be h][JPEG]`;
 * w and h 0 (no JPEG) = the layer shows nothing. Null for a frame too short to have the header, or a size without JPEG
 * bytes (it would make a broken image). */
export function parseThumbFrame(payload: Uint8Array): { layer: number; w: number; h: number; jpeg: Uint8Array } | null {
  if (payload.length < 5) return null;
  const w = (payload[1]! << 8) | payload[2]!;
  if (w > 0 && payload.length === 5) return null;
  return { layer: payload[0]!, w, h: (payload[3]! << 8) | payload[4]!, jpeg: payload.subarray(5) };
}

/** A layer row's picture: the live thumbnail while the engine sends one, otherwise the library thumbnail (or none). */
export function rowThumb(live: string | undefined, library: string | null): { src: string | null; live: boolean } {
  return live ? { src: live, live: true } : { src: library, live: false };
}

/** What the Layers screen preview shows: the whole canvas or the selected layer alone. */
export type PreviewSource = 'canvas' | 'layer';

/**
 * Preview target and caption label for the Layers screen. "This layer" follows the selected layer (null = Master or an
 * output picked in the strips); without one it falls back to the canvas and says so.
 */
export function layerPreview(source: PreviewSource, selected: number | null): { target: string; label: string; shows: PreviewSource } {
  if (source === 'layer' && selected !== null) return { target: `layer:${selected}`, label: `Layer ${selected}`, shows: 'layer' };
  return { target: 'canvas', label: source === 'layer' ? 'Canvas (no layer selected)' : 'Canvas', shows: 'canvas' };
}
