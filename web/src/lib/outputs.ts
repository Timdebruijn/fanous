// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers of the Outputs & Mapping screen: the output model as the engine stores it (OutputModel.swift),
// geometry for the mapper overlay, blend curve points and display naming.

export interface MapPoint {
  x: number;
  y: number;
}

export interface BlendEdge {
  overlap: number;
  power: number;
  gamma: number;
  gammaRGB?: number[] | null;
}

export interface BlendSettings {
  left: BlendEdge;
  right: BlendEdge;
  top: BlendEdge;
  bottom: BlendEdge;
  lift: number;
  liftFeather: number;
}

export interface MeshWarp {
  cols: number;
  rows: number;
  points: MapPoint[];
}

export interface WarpSettings {
  cornerPin: MapPoint[];
  mesh: MeshWarp | null;
}

export interface MaskSettings {
  path: MapPoint[];
  feather: number;
}

export interface SliceConfig {
  id: number;
  canvas: number;
  source: { x: number; y: number; w: number; h: number };
  dest: MapPoint[];
  mask: MaskSettings | null;
  opacity: number;
}

/** Per-output colour (DESIGN §9.9): gain per channel 0–2 and the black offset 0–0.2. */
export interface OutputColor {
  gain: [number, number, number];
  black: number;
}

/** A stored mapping preset (DESIGN §9.10 item 3): the warp and slices only; blend, colour and the rest stay live. */
export interface MappingPreset {
  number: number;
  name: string;
  warp: WarpSettings;
  slices: SliceConfig[];
}

export interface OutputConfig {
  id: number;
  name: string;
  display: { uuid: string; name: string } | null;
  region: { x: number; y: number; w: number; h: number } | null;
  mode: { width: number; height: number; hz: number } | null;
  intensity: number;
  blend: BlendSettings;
  warp: WarpSettings;
  slices: SliceConfig[];
  testPattern: number;
  /** absent in projects saved before M1.7: `colorOf` */
  color?: OutputColor;
  /** absent when the output has none (the engine writes it only then) */
  presets?: MappingPreset[];
}

export interface CanvasConfig {
  id: number;
  name: string;
  width: number;
  height: number;
  clockMaster: number | null;
  /** absent in projects saved before B31: 60 */
  fps?: number;
}

/** Canvas presets and rates `canvas.set` accepts (engine: ProjectDocument.validated). */
export const CANVAS_PRESETS = [
  { width: 1920, height: 1080 },
  { width: 3840, height: 2160 },
  { width: 1280, height: 720 },
] as const;
export const CANVAS_RATES = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60] as const;

/** Canvases a project may have (engine: ProjectDocument.maxCanvases); they all run at canvas 1's rate. */
export const MAX_CANVASES = 4;

/** Preview target of a canvas: "canvas" for canvas 1 (also what CITP streams), "canvas:<id>" for the others. */
export function canvasTarget(id: number): string {
  return id === 1 ? 'canvas' : `canvas:${id}`;
}

/** False while a "canvas:<id>" preview target waits for its canvas to render (`live.canvas.canvases`): a new canvas
 * renders only after the asynchronous canvas switch, and the engine refuses a preview of it until then (B62). */
export function previewReady(target: string, rendered: { id: number }[] | undefined): boolean {
  const canvas = /^canvas:(\d+)$/.exec(target);
  const id = Number(canvas?.[1] ?? 1);  // "canvas" and anything else: not waited for (the engine answers those itself)
  return id === 1 || !!rendered?.some((c) => c.id === id);
}

/** The canvas a layer renders into (`project.layerCanvas`, canvas 1 when unset). */
export function layerCanvas(assigned: Record<string, number> | undefined, layer: number): number {
  return assigned?.[String(layer)] ?? 1;
}

/** Layer numbers (1…layerCount) that render into a canvas. */
export function layersOn(assigned: Record<string, number> | undefined, layerCount: number, canvas: number): number[] {
  return Array.from({ length: Math.max(0, layerCount) }, (_, i) => i + 1).filter((n) => layerCanvas(assigned, n) === canvas);
}

/** "1–4, 7": layer numbers as runs. */
export function layerRuns(numbers: number[]): string {
  const runs: string[] = [];
  for (let i = 0; i < numbers.length; i++) {
    let j = i;
    while (j + 1 < numbers.length && numbers[j + 1] === numbers[j]! + 1) j++;
    runs.push(j > i ? `${numbers[i]}–${numbers[j]}` : String(numbers[i]));
    i = j;
  }
  return runs.join(', ');
}

/** Why the engine would refuse this canvas size, or null when it is fine. */
export function canvasSizeError(width: number, height: number): string | null {
  for (const [name, v] of [['Width', width], ['Height', height]] as const) {
    if (!Number.isInteger(v) || v < 320 || v > 8192) return `${name} must be a whole number from 320 to 8192.`;
    if (v % 2 !== 0) return `${name} must be even.`;
  }
  return null;
}

export interface DisplayDoc {
  uuid: string;
  name: string;
  width: number;
  height: number;
  hz: number;
  main: boolean;
  builtin: boolean;
  modes: { width: number; height: number; hz: number }[];
}

export interface OutputStatusDoc {
  id: number;
  state: 'unassigned' | 'bound' | 'lost';
  display: string | null;
  width: number;
  height: number;
  hz: number;
  master: boolean;
  /** yellow display-mode warning (desired mode differs, unavailable, or not a multiple of the canvas rate) */
  modeNote?: string | null;
  /** the Keystone fixture moves this output's corners (DESIGN §9.10 item 2) */
  keystone?: boolean;
  /** the console's keystone values were refused (not a convex quad): the last valid keystone stays */
  keystoneInvalid?: boolean;
  /** the mapping preset the output shows (DESIGN §9.10 item 3); null: the edited mapping */
  preset?: number | null;
  /** who asks for it: Output ch 6 or a held Compare */
  presetSource?: 'console' | 'compare' | null;
  /** a preset number asked for that the output does not have: it shows the edited mapping */
  presetMissing?: number | null;
}

/** "Preset N (console)", "Preset N (compare)" and, in yellow, "Preset N missing": what the output shows instead of the
 * mapping being edited. */
export function presetBadges(status: OutputStatusDoc | undefined): { text: string; warn: boolean }[] {
  const badges: { text: string; warn: boolean }[] = [];
  if (status?.preset != null) badges.push({ text: `Preset ${status.preset} (${status.presetSource ?? 'console'})`, warn: false });
  if (status?.presetMissing != null) badges.push({ text: `Preset ${status.presetMissing} missing`, warn: true });
  return badges;
}

/** Said under the preview while the output shows a preset: the edits go to the mapping it does not show right now. */
export function presetNote(status: OutputStatusDoc | undefined): string | null {
  if (status?.preset == null) return null;
  const back = status.presetSource === 'compare' ? 'when Compare is let go' : 'at channel 6 = 0';
  return `The output shows Preset ${status.preset}. Edits go to its own mapping, shown here, and on the output again ${back}.`;
}

/** The toast after a recall: on a wall, the outputs whose slice 1 became manual (`{ manual: [{ wall, output, field }] }`). */
export function recalledText(number: number, reply: unknown, name: (id: number) => string): string {
  const manual = (reply as { manual?: { output: number }[] } | null)?.manual ?? [];
  const outputs = [...new Set(manual.map((m) => m.output))].map(name);
  if (outputs.length === 0) return `Preset ${number} recalled.`;
  return `Preset ${number} recalled. Slice 1 is manual now on ${outputs.join(', ')}: it differs from the wall's part of the canvas.`;
}

/** Presets that every output in `outputs` has (a wall recalls them on all its outputs at once), by number; the name
 * is the first output's. */
export function sharedPresets(outputs: OutputConfig[]): { number: number; name: string }[] {
  const [first, ...rest] = outputs;
  return (first?.presets ?? [])
    .filter((p) => rest.every((o) => o.presets?.some((q) => q.number === p.number)))
    .map((p) => ({ number: p.number, name: p.name }));
}

/** The lowest preset number none of `outputs` uses, for "Store as"; null when 1–255 are all taken. */
export function freePresetNumber(outputs: OutputConfig[]): number | null {
  const used = new Set(outputs.flatMap((o) => o.presets?.map((p) => p.number) ?? []));
  for (let n = 1; n <= 255; n++) if (!used.has(n)) return n;
  return null;
}

/** Compare held from the UI (DESIGN §9.10 item 4): `start` sends the preset at once and again every `every` ms (the
 * engine lets the lease run out 5 s after the last one); `stop` ends it with preset 0. The latest `start` wins. */
export function compareLease(send: (preset: number) => void, every = 2000) {
  let timer: ReturnType<typeof setInterval> | null = null;
  return {
    start(preset: number) {
      if (timer) clearInterval(timer);
      send(preset);
      timer = setInterval(() => send(preset), every);
    },
    stop() {
      if (!timer) return;
      clearInterval(timer);
      timer = null;
      send(0);
    },
  };
}

/** Badges for what the output shows beyond its edited mapping; the preview and the editor show the mapping as edited. */
export function keystoneBadges(status: OutputStatusDoc | undefined): { text: string; warn: boolean }[] {
  const badges: { text: string; warn: boolean }[] = [];
  if (status?.keystone) badges.push({ text: 'Keystone active', warn: false });
  if (status?.keystoneInvalid) badges.push({ text: 'Keystone invalid', warn: true });
  return badges;
}

/** Index = the engine's TestPattern raw value (Output/Master channel 4 band order). */
export const TEST_PATTERNS = [
  'Off', 'Grid', 'Colour bars', 'Blend check', 'Output ID', 'Crosshair', 'Grey steps', 'Checkerboard',
  'Grey 0 %', 'Grey 25 %', 'Grey 75 %', 'White',
] as const;
export const EDGES = ['left', 'right', 'top', 'bottom'] as const;
export type Edge = (typeof EDGES)[number];
export type MapperMode = 'cornerPin' | 'mesh' | 'slices' | 'mask';

export const UNIT_QUAD: MapPoint[] = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];

export function meshIdentity(cols: number, rows: number): MeshWarp {
  const points: MapPoint[] = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) points.push({ x: c / (cols - 1), y: r / (rows - 1) });
  return { cols, rows, points };
}

/** An output's colour; gain 1 and black 0 when its project predates it, as the engine reads it. */
export function colorOf(output: OutputConfig): OutputColor {
  return output.color ?? { gain: [1, 1, 1], black: 0 };
}

export function clamp01(v: number): number {
  return Math.min(1, Math.max(0, v));
}

/** Pixel size of an output: its region, else its display's size, else 1920×1080. */
export function outputSize(output: OutputConfig, displays: DisplayDoc[]): { w: number; h: number } {
  if (output.region) return { w: output.region.w, h: output.region.h };
  const display = displays.find((d) => d.uuid === output.display?.uuid);
  return display ? { w: display.width, h: display.height } : { w: 1920, h: 1080 };
}

/** "3840 × 2160 @ 60" */
export function modeText(mode: { width: number; height: number; hz: number } | null | undefined): string {
  return mode ? `${mode.width} × ${mode.height} @ ${Number(mode.hz.toFixed(2))}` : '—';
}

export function statusText(status: OutputStatusDoc | undefined, output: OutputConfig): { text: string; tone: 'green' | 'red' | 'faint' } {
  if (!status || status.state === 'unassigned') return { text: output.display ? 'binding…' : 'not assigned to a display', tone: 'faint' };
  if (status.state === 'lost') return { text: `display missing: ${output.display?.name ?? '?'}`, tone: 'red' };
  return { text: `${status.display} · ${status.width} × ${status.height} @ ${Number(status.hz.toFixed(0))}${status.master ? ' · clock master' : ''}`, tone: 'green' };
}

/** The S-curve of DESIGN §9.2 as SVG path points (t from 0 to 1 across the overlap), gamma applied. */
export function blendCurvePath(edge: BlendEdge, width: number, height: number, samples = 48): string {
  const parts: string[] = [];
  for (let i = 0; i <= samples; i++) {
    const t = i / samples;
    const s = t < 0.5 ? 0.5 * Math.pow(2 * t, edge.power) : 1 - 0.5 * Math.pow(2 * (1 - t), edge.power);
    const f = Math.pow(s, 1 / Math.max(0.1, edge.gamma));
    parts.push(`${i === 0 ? 'M' : 'L'}${(t * width).toFixed(1)} ${((1 - f) * height).toFixed(1)}`);
  }
  return parts.join(' ');
}

/** Points of the overlay for a mapper mode, with the JSON pointer each one writes to. */
export function handles(output: OutputConfig, mode: MapperMode, sliceIndex: number): { path: string; point: MapPoint; group: number }[] {
  switch (mode) {
    case 'cornerPin':
      return output.warp.cornerPin.map((point, i) => ({ path: `/warp/cornerPin/${i}`, point, group: 0 }));
    case 'mesh':
      return (output.warp.mesh?.points ?? []).map((point, i) => ({ path: `/warp/mesh/points/${i}`, point, group: 0 }));
    case 'slices': {
      // only the selected slice is draggable: a new slice starts on the same corners as the others
      const slice = output.slices[sliceIndex];
      return (slice?.dest ?? []).map((point, i) => ({ path: `/slices/${sliceIndex}/dest/${i}`, point, group: sliceIndex }));
    }
    case 'mask': {
      const slice = output.slices[sliceIndex];
      return (slice?.mask?.path ?? []).map((point, i) => ({ path: `/slices/${sliceIndex}/mask/path/${i}`, point, group: sliceIndex }));
    }
  }
}

/** Closed outlines to draw under the handles. */
export function outlines(output: OutputConfig, mode: MapperMode, sliceIndex: number): { points: MapPoint[]; group: number }[] {
  switch (mode) {
    case 'cornerPin':
      return [{ points: output.warp.cornerPin, group: 0 }];
    case 'mesh': {
      const mesh = output.warp.mesh;
      if (!mesh) return [];
      const lines: { points: MapPoint[]; group: number }[] = [];
      for (let r = 0; r < mesh.rows; r++) lines.push({ points: mesh.points.slice(r * mesh.cols, (r + 1) * mesh.cols), group: 0 });
      for (let c = 0; c < mesh.cols; c++) lines.push({ points: Array.from({ length: mesh.rows }, (_, r) => mesh.points[r * mesh.cols + c]!), group: 0 });
      return lines;
    }
    case 'slices':
      return output.slices.map((slice, s) => ({ points: slice.dest, group: s }));
    case 'mask': {
      const slice = output.slices[sliceIndex];
      return slice?.mask ? [{ points: slice.mask.path, group: sliceIndex }] : [];
    }
  }
}

/** A mask inset 10 % on every side, the starting point for a new mask. */
export function defaultMask(): MaskSettings {
  return { path: [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.1, y: 0.9 }], feather: 0 };
}

/** Inserts `p` into the closed path on the edge nearest to it, so a tapped point never tangles the shape. */
export function insertNearest(path: MapPoint[], p: MapPoint): { path: MapPoint[]; index: number } {
  if (path.length < 2) return { path: [...path, p], index: path.length };
  let best = 0;
  let bestDistance = Infinity;
  for (let i = 0; i < path.length; i++) {
    const a = path[i]!, b = path[(i + 1) % path.length]!;
    const dx = b.x - a.x, dy = b.y - a.y;
    const length2 = dx * dx + dy * dy;
    const t = length2 > 0 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0;
    const qx = a.x + t * dx - p.x, qy = a.y + t * dy - p.y;
    const distance = qx * qx + qy * qy;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = i;
    }
  }
  const next = [...path];
  next.splice(best + 1, 0, p);
  return { path: next, index: best + 1 };
}

/** Inserts a point halfway between `index` and the next one (wrapping). */
export function insertPoint(path: MapPoint[], index: number): MapPoint[] {
  const a = path[index] ?? path[0]!;
  const b = path[(index + 1) % path.length]!;
  const next = [...path];
  next.splice(index + 1, 0, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
  return next;
}

export function nextSliceId(output: OutputConfig): number {
  return Math.max(0, ...output.slices.map((s) => s.id)) + 1;
}

type SourceRect = { x: number; y: number; w: number; h: number };

/** Slice source (stored 0–1 of the canvas) in canvas pixels, rounded; the canvas defaults to 1920×1080 until known. */
export function sourcePixels(source: SourceRect, canvas: { width: number; height: number } | undefined): SourceRect {
  const w = canvas?.width ?? 1920;
  const h = canvas?.height ?? 1080;
  return { x: Math.round(source.x * w), y: Math.round(source.y * h), w: Math.round(source.w * w), h: Math.round(source.h * h) };
}

/** One typed pixel value back to the stored 0–1 fraction (clamped); null for a non-number. */
export function sourceFromPixels(key: keyof SourceRect, pixels: number, canvas: { width: number; height: number } | undefined): number | null {
  if (!Number.isFinite(pixels)) return null;
  const total = key === 'x' || key === 'w' ? (canvas?.width ?? 1920) : (canvas?.height ?? 1080);
  return clamp01(pixels / total);
}

/** One picture across all slices (faces of an object): slices ordered left to right by their centre on the output,
 *  each gets the next strip of the canvas in proportion to its width on the output (mean of top and bottom edge, in
 *  output pixels); full canvas height. Returns the slices with new sources, in their original order. */
export function spreadSources(slices: SliceConfig[], size: { w: number; h: number }): SliceConfig[] {
  const edge = (a: MapPoint, b: MapPoint) => Math.hypot((b.x - a.x) * size.w, (b.y - a.y) * size.h);
  const width = (d: MapPoint[]) => (d.length === 4 ? (edge(d[0]!, d[1]!) + edge(d[3]!, d[2]!)) / 2 : 0);
  const centre = (d: MapPoint[]) => d.reduce((sum, p) => sum + p.x, 0) / Math.max(1, d.length);
  const order = slices.map((s, i) => ({ i, w: width(s.dest), c: centre(s.dest) })).sort((a, b) => a.c - b.c);
  const total = order.reduce((sum, o) => sum + o.w, 0);
  if (total <= 0) return slices;
  const out = slices.slice();
  let x = 0;
  for (const o of order) {
    const w = o.w / total;
    out[o.i] = { ...slices[o.i]!, source: { x, y: 0, w, h: 1 } };
    x += w;
  }
  return out;
}

/** Nudge in pixels of the output, as a normalized delta. */
export function nudge(point: MapPoint, dx: number, dy: number, size: { w: number; h: number }): MapPoint {
  return { x: clamp01(point.x + dx / size.w), y: clamp01(point.y + dy / size.h) };
}
