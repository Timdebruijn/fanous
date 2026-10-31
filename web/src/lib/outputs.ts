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

/** A mask point (DESIGN §9.10 item 5); its handles are offsets from it, and without them it is a corner. */
export interface MaskPoint extends MapPoint {
  in?: MapPoint;
  out?: MapPoint;
}

/** One mask of a slice: a path (3 or more points, nonzero fill) or a library image. The slice shows the union of its
 *  add masks (all of it without one) minus the union of its subtract masks. */
export interface MaskShape {
  mode: 'add' | 'subtract';
  feather: number;
  path?: MaskPoint[];
  image?: { folder: number; file: number };
}

export interface SliceConfig {
  id: number;
  canvas: number;
  source: { x: number; y: number; w: number; h: number };
  dest: MapPoint[];
  /** absent when the slice has none (the engine writes it only then) */
  masks?: MaskShape[];
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
  /** a running morph into the preset (Output ch 7): from and to as drawn, 0 = the edited mapping, and its fade in seconds */
  morph?: { from: number; to: number; fade: number } | null;
  /** the edit overlay (DESIGN §9.10 item 4) while its lease runs: drawn, or why not; null without a lease */
  overlay?: 'shown' | 'preset' | 'raw' | null;
}

/** "Preset N (console)", "Preset N (compare)" and, in yellow, "Preset N missing": what the output shows instead of the
 * mapping being edited; "Preset A → B", "Edited → Preset B" or "Preset A → edited" while a morph runs (only the console
 * morphs, so no source; short, as it wraps next to "Keystone active" on a phone). */
export function presetBadges(status: OutputStatusDoc | undefined): { text: string; warn: boolean }[] {
  const badges: { text: string; warn: boolean }[] = [];
  const m = status?.morph;
  if (m) {
    const to = m.to === 0 ? 'edited' : m.from === 0 ? `Preset ${m.to}` : `${m.to}`;
    badges.push({ text: `${m.from === 0 ? 'Edited' : `Preset ${m.from}`} → ${to}`, warn: false });
  } else if (status?.preset != null) badges.push({ text: `Preset ${status.preset} (${status.presetSource ?? 'console'})`, warn: false });
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

export type OverlaySelection = { slice: number; kind: 'corner' | 'mesh' | 'slice' | 'mask'; mask?: number; point: number };

/** The point the edit overlay marks on the output (`output.overlay`'s `selected`): the anchor's index in the mode's
 *  handles, on slice `slice` (its index; 0 for a corner pin or mesh point, which the engine reads without one, so
 *  picking another slice sends nothing new); a mask point by its mask and its index there, from the handle's `path`;
 *  null with nothing selected. */
export function overlaySelection(mode: MapperMode, slice: number, point: number, path?: string | null): OverlaySelection | null {
  if (point < 0) return null;
  const kind = ({ cornerPin: 'corner', mesh: 'mesh', slices: 'slice', mask: 'mask' } as const)[mode];
  if (kind === 'mask') {
    const handle = maskHandle(path);
    return handle ? { slice, kind, mask: handle.mask, point: handle.point } : null;
  }
  return { slice: kind === 'corner' || kind === 'mesh' ? 0 : slice, kind, point };
}

/** The slice, mask and point of a mask handle's pointer (`/slices/s/masks/m/path/i`), and `side` for one of the point's
 *  Bézier handles (`…/i/in`, `…/i/out`); null for any other. */
export function maskHandle(path: string | null | undefined): { slice: number; mask: number; point: number; side?: 'in' | 'out' } | null {
  const m = path?.match(/^\/slices\/(\d+)\/masks\/(\d+)\/path\/(\d+)(?:\/(in|out))?$/);
  return m ? { slice: Number(m[1]), mask: Number(m[2]), point: Number(m[3]), side: m[4] as 'in' | 'out' | undefined } : null;
}

/** The `output.set` that puts a handle at `to` (stored coordinates): a mask point keeps its Bézier handles, a Bézier
 *  handle is stored as the offset from its point (both write the point); any other handle writes its own pointer. */
export function movedHandle(output: OutputConfig, path: string, to: MapPoint): { path: string; value: MaskPoint } {
  const h = maskHandle(path);
  const point = h ? output.slices[h.slice]?.masks?.[h.mask]?.path?.[h.point] : undefined;
  if (!h || !point) return { path, value: { x: to.x, y: to.y } };
  const at = `/slices/${h.slice}/masks/${h.mask}/path/${h.point}`;
  return { path: at, value: h.side ? { ...point, [h.side]: { x: to.x - point.x, y: to.y - point.y } } : { ...point, x: to.x, y: to.y } };
}

/** The mask Warp & Slices' Add points acts on: the selected point's, else the slice's first path mask (an image mask
 *  has no points); −1 without a path mask. */
export function maskTarget(slice: SliceConfig | undefined, sliceIndex: number, handle: string | null): number {
  const masks = slice?.masks ?? [];
  const h = maskHandle(handle);
  return h && h.slice === sliceIndex && masks[h.mask]?.path ? h.mask : masks.findIndex((m) => !!m.path);
}

/** The edit overlay's lease from Warp & Slices (DESIGN §9.10 item 4): `start` sends at once when the output or the
 *  selection changed (or it was off) and renews every `every` ms; after `quiet` ms without `edited` (an edit, the tab
 *  opened or the switch turned on) it ends the lease with `on: false` and calls `idle`, and a `start` after that long
 *  does the same instead of sending (a lease off meanwhile: a hidden page, show lock or show mode); `stop` ends it with
 *  `on: false`. */
export function overlayLease(send: (id: number, on: boolean, selected: OverlaySelection | null) => void, idle: () => void, every = 2000, quiet = 600_000) {
  let timer: ReturnType<typeof setInterval> | null = null;
  let id = 0, selected: OverlaySelection | null = null, editedAt = 0;
  function stop() {
    if (!timer) return;
    clearInterval(timer);
    timer = null;
    send(id, false, null);
  }
  return {
    start(output: number, next: OverlaySelection | null) {
      if (timer && output === id && JSON.stringify(next) === JSON.stringify(selected)) return;
      if (timer && output !== id) stop();
      if (!timer && Date.now() - editedAt >= quiet) return idle();
      [id, selected] = [output, next];
      send(id, true, selected);
      if (timer) clearInterval(timer);
      timer = setInterval(() => {
        if (Date.now() - editedAt < quiet) return send(id, true, selected);
        stop();
        idle();
      }, every);
    },
    edited() {
      editedAt = Date.now();
    },
    stop,
  };
}

/** Why the output does not draw the edit overlay while it is asked for (it belongs to the edited mapping). */
export function overlayBadges(status: OutputStatusDoc | undefined): { text: string; warn: boolean }[] {
  if (status?.overlay === 'preset') return [{ text: 'Overlay hidden: a preset shows', warn: true }];
  if (status?.overlay === 'raw') return [{ text: 'Overlay hidden: Raw', warn: true }];
  return [];
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
    case 'mask':
      // every path mask's points, mask by mask; a point keeps its handles (`point` is the stored `MaskPoint`) and each
      // Bézier handle follows its point (`point` where it lies), so Tab and the remote step through them too
      return (output.slices[sliceIndex]?.masks ?? []).flatMap((mask, m) =>
        (mask.path ?? []).flatMap((point, i) => {
          const path = `/slices/${sliceIndex}/masks/${m}/path/${i}`;
          const sides = (['in', 'out'] as const).filter((side) => point[side]);
          return [{ path, point, group: sliceIndex }, ...sides.map((side) => ({ path: `${path}/${side}`, point: { x: point.x + point[side]!.x, y: point.y + point[side]!.y }, group: sliceIndex }))];
        }),
      );
  }
}

const lerp = (a: MapPoint, b: MapPoint, t: number): MapPoint => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
const offset = (from: MapPoint, to: MapPoint): MapPoint => ({ x: to.x - from.x, y: to.y - from.y });

/** The segment from `p` to `q` as a cubic's control points; a missing handle lies on its point. */
function cubic(p: MaskPoint, q: MaskPoint): MapPoint[] {
  return [p, { x: p.x + (p.out?.x ?? 0), y: p.y + (p.out?.y ?? 0) }, { x: q.x + (q.in?.x ?? 0), y: q.y + (q.in?.y ?? 0) }, q];
}

/** de Casteljau at `t`: the rows of the construction from the control points (`l[0]`) to the point on the curve
 *  (`l[3][0]`); the left half is (l[0][0], l[1][0], l[2][0], l[3][0]), the right half (l[3][0], l[2][1], l[1][2], l[0][3]). */
function casteljau(c: MapPoint[], t: number): MapPoint[][] {
  const levels = [c];
  while (levels.at(-1)!.length > 1) {
    const row = levels.at(-1)!;
    levels.push(row.slice(1).map((q, i) => lerp(row[i]!, q, t)));
  }
  return levels;
}

/** A mask path's closed outline: its points, and `pieces` steps along each curved segment (a handle at either end). */
export function maskOutline(path: MaskPoint[], pieces = 8): MapPoint[] {
  const out: MapPoint[] = [];
  path.forEach((p, i) => {
    const q = path[(i + 1) % path.length]!;
    out.push({ x: p.x, y: p.y });
    if (!p.out && !q.in) return;
    for (let k = 1; k < pieces; k++) out.push(casteljau(cubic(p, q), k / pieces)[3]![0]!);
  });
  return out;
}

/** Closed outlines to draw under the handles; a subtract mask's says so, the editor draws it apart. */
export function outlines(output: OutputConfig, mode: MapperMode, sliceIndex: number): { points: MapPoint[]; group: number; subtract?: boolean }[] {
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
    case 'mask':
      return (output.slices[sliceIndex]?.masks ?? []).flatMap((mask) => (mask.path && mask.path.length >= 3 ? [{ points: maskOutline(mask.path), group: sliceIndex, subtract: mask.mode === 'subtract' }] : []));
  }
}

/** The parameter of the point on segment a–b nearest to `p` (0 on a segment of no length). */
function nearestOn(a: MapPoint, b: MapPoint, p: MapPoint): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  const length2 = dx * dx + dy * dy;
  return length2 > 0 ? clamp01(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2) : 0;
}

/** Inserts `p` into the closed path on the edge nearest to it, so a tapped point never tangles the shape. On a curved
 *  edge the new point goes onto the curve where it comes nearest to `p` (the nearest of 63 points along it, refined
 *  between its neighbours) and de Casteljau splits the curve there, so the shape stays as it was. */
export function insertNearest(path: MaskPoint[], p: MapPoint): { path: MaskPoint[]; index: number } {
  if (path.length < 2) return { path: [...path, p], index: path.length };
  let best = 0, bestT = 0, bestDistance = Infinity;
  for (let i = 0; i < path.length; i++) {
    const a = path[i]!, b = path[(i + 1) % path.length]!;
    const curved = !!(a.out || b.in);
    for (const t of curved ? Array.from({ length: 63 }, (_, k) => (k + 1) / 64) : [nearestOn(a, b, p)]) {
      const q = curved ? casteljau(cubic(a, b), t)[3]![0]! : lerp(a, b, t);
      const distance = (q.x - p.x) ** 2 + (q.y - p.y) ** 2;
      if (distance < bestDistance) [best, bestT, bestDistance] = [i, t, distance];
    }
  }
  const next = [...path];
  const a = path[best]!, j = (best + 1) % path.length, b = path[j]!;
  if (!(a.out || b.in)) {
    next.splice(best + 1, 0, p);
    return { path: next, index: best + 1 };
  }
  // ternary search between the neighbouring samples (so close, the distance has one minimum), not onto an end point
  const off = (t: number) => {
    const q = casteljau(cubic(a, b), t)[3]![0]!;
    return (q.x - p.x) ** 2 + (q.y - p.y) ** 2;
  };
  let [lo, hi] = [Math.max(1 / 128, bestT - 1 / 64), Math.min(127 / 128, bestT + 1 / 64)];
  for (let k = 0; k < 40; k++) {
    const [t1, t2] = [lo + (hi - lo) / 3, hi - (hi - lo) / 3];
    if (off(t1) < off(t2)) hi = t2;
    else lo = t1;
  }
  const l = casteljau(cubic(a, b), (lo + hi) / 2), q = l[3]![0]!;
  // a handle that was not there stays away: its half's handle lies on its point, as before
  if (a.out) next[best] = { ...a, out: offset(a, l[1]![0]!) };
  if (b.in) next[j] = { ...b, in: offset(b, l[1]![2]!) };
  next.splice(best + 1, 0, { x: q.x, y: q.y, in: offset(q, l[2]![0]!), out: offset(q, l[2]![1]!) });
  return { path: next, index: best + 1 };
}

/** Ramer–Douglas–Peucker: the fewest of `points` (kept in order, both ends kept) that stay within `tolerance` of the
 *  polyline. */
export function simplify(points: MapPoint[], tolerance: number): MapPoint[] {
  const keep = points.map((_, i) => i === 0 || i === points.length - 1);
  const spans: [number, number][] = points.length > 2 ? [[0, points.length - 1]] : [];
  for (let span = spans.pop(); span; span = spans.pop()) {
    const [i, j] = span;
    let far = -1, farthest = tolerance;
    for (let k = i + 1; k < j; k++) {
      const q = lerp(points[i]!, points[j]!, nearestOn(points[i]!, points[j]!, points[k]!));
      const distance = Math.hypot(q.x - points[k]!.x, q.y - points[k]!.y);
      if (distance > farthest) [far, farthest] = [k, distance];
    }
    if (far < 0) continue;
    keep[far] = true;
    spans.push([i, far], [far, j]);
  }
  return points.filter((_, i) => keep[i]);
}

/** Point `i` made smooth: Bézier handles along its neighbours' chord, a sixth of it each way, as Catmull-Rom through
 *  the points gives (a third of its tangent (next − previous) / 2). */
export function smoothPoint(path: MapPoint[], i: number): MaskPoint {
  const n = path.length, p = path[i]!, d = offset(path[(i + n - 1) % n]!, path[(i + 1) % n]!);
  return { x: p.x, y: p.y, in: { x: -d.x / 6, y: -d.y / 6 }, out: { x: d.x / 6, y: d.y / 6 } };
}

/** A double-tap on a mask point: a corner becomes smooth, a point with a handle a corner. */
export function toggleSmooth(path: MaskPoint[], i: number): MaskPoint {
  const p = path[i]!;
  return p.in || p.out ? { x: p.x, y: p.y } : smoothPoint(path, i);
}

/** Bézier handles of a circle's quarter, as a fraction of its radius: 4 (√2 − 1) / 3. */
export const KAPPA = 0.5522847498;

/** The Rectangle tool: the box from corner `a` to corner `b`, its 4 corners clockwise from the top left. */
export function rectanglePath(a: MapPoint, b: MapPoint): MaskPoint[] {
  const [x0, x1, y0, y1] = [Math.min(a.x, b.x), Math.max(a.x, b.x), Math.min(a.y, b.y), Math.max(a.y, b.y)];
  return [{ x: x0, y: y0 }, { x: x1, y: y0 }, { x: x1, y: y1 }, { x: x0, y: y1 }];
}

/** The Ellipse tool: the ellipse filling the box from `a` to `b`, 4 points clockwise from the top, handles κ × the
 *  radius along the box's sides. */
export function ellipsePath(a: MapPoint, b: MapPoint): MaskPoint[] {
  const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2, rx = Math.abs(b.x - a.x) / 2, ry = Math.abs(b.y - a.y) / 2;
  const kx = KAPPA * rx, ky = KAPPA * ry;
  return [
    { x: cx, y: cy - ry, in: { x: -kx, y: 0 }, out: { x: kx, y: 0 } },
    { x: cx + rx, y: cy, in: { x: 0, y: -ky }, out: { x: 0, y: ky } },
    { x: cx, y: cy + ry, in: { x: kx, y: 0 }, out: { x: -kx, y: 0 } },
    { x: cx - rx, y: cy, in: { x: 0, y: ky }, out: { x: 0, y: -ky } },
  ];
}

/** A freehand point where the stroke turns by more than this stays a corner. Between RDP's points a curve of radius r
 *  output px turns by at most 2 acos(1 − 2 / r), under 40° from r ≈ 35 px, so drawn curves stay smooth; the corners
 *  people trace (a window's 90°, a 45° roof) turn more. */
export const FREEHAND_CORNER = (40 * Math.PI) / 180;

/** How far the closed path turns at point `i`, 0 to π (radians). */
function turn(path: MapPoint[], i: number): number {
  const n = path.length, a = offset(path[(i + n - 1) % n]!, path[i]!), b = offset(path[i]!, path[(i + 1) % n]!);
  return Math.abs(Math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y));
}

/** The Freehand tool: the stroke (output coordinates) simplified by RDP at 2 output pixels and closed (an end back
 *  within 2 px of the start is the start); a point where it turns sharply (`FREEHAND_CORNER`, measured in output
 *  pixels) stays a corner, the others are smooth. Null when under 3 points remain. */
export function freehandPath(stroke: MapPoint[], size: { w: number; h: number }): MaskPoint[] | null {
  const px = simplify(stroke.map((p) => ({ x: p.x * size.w, y: p.y * size.h })), 2);
  if (px.length > 1 && Math.hypot(px.at(-1)!.x - px[0]!.x, px.at(-1)!.y - px[0]!.y) <= 2) px.pop();
  if (px.length < 3) return null;
  const path = px.map((p) => ({ x: p.x / size.w, y: p.y / size.h }));
  return path.map((p, i) => (turn(px, i) > FREEHAND_CORNER ? p : smoothPoint(path, i)));
}

/** The mask tools that take a drag on the picture (Polygon takes taps). */
export type MaskTool = 'rectangle' | 'ellipse' | 'freehand';

/** The path a drag tool makes of its stroke (output coordinates, from where the drag started); null when it is too
 *  small for one: a box under 2 output px either way, a stroke that leaves under 3 points. */
export function toolPath(tool: MaskTool, stroke: MapPoint[], size: { w: number; h: number }): MaskPoint[] | null {
  const a = stroke[0], b = stroke.at(-1);
  if (!a || !b) return null;
  if (tool === 'freehand') return freehandPath(stroke, size);
  if (Math.abs(b.x - a.x) * size.w < 2 || Math.abs(b.y - a.y) * size.h < 2) return null;
  return tool === 'rectangle' ? rectanglePath(a, b) : ellipsePath(a, b);
}

/** The slice's masks with a new path from a tool: an add mask after the others, or in place of `redraw` (the mask
 *  Redraw was chosen on, as it was then). Another client can change the list while a shape is drawn, so `redraw` is
 *  looked up by content: a mask that changed or went makes the path a new mask rather than overwrite another one. */
export function finishMask(masks: MaskShape[], path: MaskPoint[], redraw: MaskShape | null): MaskShape[] {
  const i = redrawIndex(masks, redraw);
  return i >= 0 ? masks.map((m, k) => (k === i ? { ...m, path } : m)) : [...masks, { mode: 'add', feather: 0, path }];
}

/** Where `redraw` is in the list now, by content; −1 when it changed or went (or there is none). */
export function redrawIndex(masks: MaskShape[], redraw: MaskShape | null): number {
  return redraw ? masks.findIndex((m) => JSON.stringify(m) === JSON.stringify(redraw)) : -1;
}

/** Backspace or Remove point on a mask handle: a Bézier handle goes (that side of its point becomes a corner), a
 *  point goes from its path (a path keeps 3); null when nothing can go. */
export function maskRemoval(output: OutputConfig, handle: string | null): { path: string; value: MaskPoint | MaskPoint[] } | null {
  const h = maskHandle(handle);
  const list = h ? output.slices[h.slice]?.masks?.[h.mask]?.path : undefined;
  if (!h || !list?.[h.point]) return null;
  const at = `/slices/${h.slice}/masks/${h.mask}/path`;
  if (!h.side) return list.length > 3 ? { path: at, value: list.filter((_, i) => i !== h.point) } : null;
  const point = { ...list[h.point]! };
  delete point[h.side];
  return { path: `${at}/${h.point}`, value: point };
}

/** Slice shape Triangle (DESIGN §9.10 item 5): the top-left and top-right corners meet in the middle of the top edge. */
export function triangleDest(dest: MapPoint[]): MapPoint[] {
  const top = lerp(dest[0]!, dest[1]!, 0.5);
  return [top, top, ...dest.slice(2)];
}

/** Slice shape Circle: an add mask, the Ellipse tool's path filling the bounding box of the slice's corners. */
export function circleMask(dest: MapPoint[]): MaskShape {
  const xs = dest.map((p) => p.x), ys = dest.map((p) => p.y);
  return { mode: 'add', feather: 0, path: ellipsePath({ x: Math.min(...xs), y: Math.min(...ys) }, { x: Math.max(...xs), y: Math.max(...ys) }) };
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
