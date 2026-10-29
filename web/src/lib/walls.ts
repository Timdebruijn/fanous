// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure logic of projector walls on the Outputs screen (DESIGN §9.9): the wall as the engine stores it (WallModel.swift),
// the wizard's grid choice and canvas preview, the mini-map's seams, badges, test patterns and the seam check steps.
import { TEST_PATTERNS, type DisplayDoc, type OutputConfig } from './outputs';

export type ManualField = 'source' | 'overlap.left' | 'overlap.right' | 'overlap.top' | 'overlap.bottom';

export interface SeamConfig {
  a: number;
  /** right of or below `a` */
  b: number;
  power: number;
  gamma: number;
  /** per-channel gamma; null or absent = `gamma` for all three */
  gammaRGB?: number[] | null;
}

export interface WallConfig {
  id: number;
  name: string;
  canvas: number;
  rect: { x: number; y: number; w: number; h: number };
  cols: number;
  rows: number;
  /** row-major from the top left */
  outputs: number[];
  /** fraction of one projector's width (x) and height (y), 0–0.5 */
  overlap: { x: number; y: number };
  seams: SeamConfig[];
  manual: { output: number; field: ManualField }[];
}

export interface Grid {
  cols: number;
  rows: number;
}

/** Test pattern raw values (engine `TestPattern`, the index into TEST_PATTERNS). */
export const PATTERN = { grid: 1, blendCheck: 3, outputID: 4, grey0: 8, grey25: 9, grey75: 10, white: 11 } as const;

/** Canvas limits of `canvas.set` and `wall.add` makeCanvas (engine ProjectDocument.canvasSides, maxCanvasPixels). */
export const CANVAS_SIDES = { min: 320, max: 8192 } as const;
export const MAX_CANVAS_PIXELS = 4 * 3840 * 2160;

/** Grids of 1–4 columns and rows with exactly `count` projectors (at least two), one row first. */
export function grids(count: number): Grid[] {
  const out: Grid[] = [];
  if (count < 2) return out;
  for (let rows = 1; rows <= 4; rows++) if (count % rows === 0 && count / rows <= 4) out.push({ cols: count / rows, rows });
  return out;
}

/** A tap on a tile: the output joins the end of the order, or leaves it (the later ones move up). */
export function tap(order: number[], id: number): number[] {
  return order.includes(id) ? order.filter((x) => x !== id) : [...order, id];
}

/** Row and column (from 1) of the `index`-th output, row-major. */
export function rc(index: number, cols: number): { row: number; col: number } {
  return { row: Math.floor(index / cols) + 1, col: (index % cols) + 1 };
}

/** The wall an output is in. */
export function wallOf(walls: WallConfig[] | undefined, output: number): WallConfig | undefined {
  return walls?.find((w) => w.outputs.includes(output));
}

/** "Wall 1 · r1 c2" */
export function badge(wall: WallConfig, output: number): string {
  const { row, col } = rc(wall.outputs.indexOf(output), wall.cols);
  return `${wall.name} · r${row} c${col}`;
}

export function isManual(wall: WallConfig | undefined, output: number, field: ManualField): boolean {
  return !!wall?.manual.some((m) => m.output === output && m.field === field);
}

/** Outputs a new wall can use: those not in another wall (`editing`: that wall's own outputs count as free). */
export function freeOutputs(outputs: OutputConfig[], walls: WallConfig[] | undefined, editing?: number): OutputConfig[] {
  return outputs.filter((o) => {
    const w = wallOf(walls, o.id);
    return !w || w.id === editing;
  });
}

export interface SeamLine extends SeamConfig {
  /** the line runs along a's right edge (between columns) or its bottom edge (between rows) */
  side: 'right' | 'bottom';
  /** a's row and column, from 0 */
  row: number;
  col: number;
}

/** The wall's seams placed on the grid, for the mini-map; a seam whose outputs are not neighbours is left out. */
export function seamLines(wall: WallConfig): SeamLine[] {
  const out: SeamLine[] = [];
  for (const seam of wall.seams) {
    const i = wall.outputs.indexOf(seam.a), j = wall.outputs.indexOf(seam.b);
    if (i < 0 || j < 0) continue;
    const row = Math.floor(i / wall.cols), col = i % wall.cols;
    if (j === i + 1 && col + 1 < wall.cols) out.push({ ...seam, side: 'right', row, col });
    else if (j === i + wall.cols) out.push({ ...seam, side: 'bottom', row, col });
  }
  return out;
}

/** An output's pixels, as the engine decides them: its region, else its desired mode, else its display's current mode. */
export function pixelSize(output: OutputConfig, displays: DisplayDoc[]): { width: number; height: number } | null {
  if (output.region) return { width: output.region.w, height: output.region.h };
  if (output.mode) return { width: output.mode.width, height: output.mode.height };
  const d = displays.find((x) => x.uuid === output.display?.uuid);
  return d ? { width: d.width, height: d.height } : null;
}

/** The one pixel size every output of a wall needs (v1), or why there is none (the engine's wording). */
export function wallPixels(ids: number[], outputs: OutputConfig[], displays: DisplayDoc[]): { width: number; height: number } | string {
  let first: { width: number; height: number; id: number } | null = null;
  for (const id of ids) {
    const o = outputs.find((x) => x.id === id);
    const size = o && pixelSize(o, displays);
    if (!size) return `Output ${id} has no pixel size yet: bind it to a display, or set its region or display mode.`;
    if (first && (first.width !== size.width || first.height !== size.height)) {
      return `The outputs of a wall need one pixel size: Output ${first.id} is ${first.width} × ${first.height}, Output ${id} is ${size.width} × ${size.height}.`;
    }
    first ??= { ...size, id };
  }
  return first ? { width: first.width, height: first.height } : 'Tap the projectors first.';
}

/** Share of the wall one of `n` projectors covers along an axis: `1 / (n − (n − 1) · overlap)` (WallLayout.share). */
export function share(n: number, overlap: number): number {
  return 1 / (n - (n - 1) * overlap);
}

/** The wall at projector resolution: `cols · w − (cols − 1) · overlap · w`, and likewise in height, unrounded. */
export function wallSize(grid: Grid, overlap: { x: number; y: number }, output: { width: number; height: number }): { width: number; height: number } {
  return { width: output.width / share(grid.cols, overlap.x), height: output.height / share(grid.rows, overlap.y) };
}

/** The canvas "make a canvas that fits" gives (WallLayout.canvasSize): the wall's size rounded to even; a wall larger
 * than 8192 px or than `maxPixels` (what the other canvases leave) is scaled down whole and rounded down. */
export function fitCanvas(grid: Grid, overlap: { x: number; y: number }, output: { width: number; height: number }, maxPixels: number): { width: number; height: number } {
  const { width: w, height: h } = wallSize(grid, overlap, output);
  const scale = Math.min(1, CANVAS_SIDES.max / Math.max(w, h), Math.sqrt(Math.max(0, maxPixels) / (w * h)));
  const even = (v: number) => {
    const half = (v * scale) / 2;
    // Swift's .rounded() takes a half away from zero, as Math.round does for these positive values; 1e-9: 8192 · (x / x)
    // may land just below
    const rounded = scale < 1 ? Math.floor(half + 1e-9) : Math.round(half);
    return Math.min(CANVAS_SIDES.max, Math.max(CANVAS_SIDES.min, 2 * rounded));
  };
  return { width: even(w), height: even(h) };
}

/** The yellow hint of the overlap slider, or null between 10 and 25 %. */
export function overlapHint(percent: number): string | null {
  if (percent < 10) return 'Below 10 %: the fade is short, so a seam shows more easily. Fine for projectors that match very well.';
  if (percent > 25) return 'Above 25 %: many pixels and much light go into the overlaps; the wall gets less resolution.';
  return null;
}

/** The wizard's choices (steps 1 and 2). */
export interface WizardDraft {
  /** the wall being edited (Edit layout…), null for a new one */
  edit: number | null;
  step: 1 | 2;
  /** tapped output ids, in the order the projectors hang */
  order: number[];
  grid: Grid | null;
  /** percent of one projector */
  overlap: number;
  /** the overlap the edited wall had, in percent: unchanged, a different x and y stay */
  overlapWas: number | null;
  canvas: number;
  fit: 'canvas' | 'makeCanvas';
}

export function newDraft(canvas: number): WizardDraft {
  return { edit: null, step: 1, order: [], grid: null, overlap: 15, overlapWas: null, canvas, fit: 'canvas' };
}

/** Edit layout…: the wizard pre-filled with the wall. */
export function editDraft(wall: WallConfig): WizardDraft {
  const overlap = Math.round(wall.overlap.x * 100);
  return { edit: wall.id, step: 1, order: [...wall.outputs], grid: { cols: wall.cols, rows: wall.rows }, overlap, overlapWas: overlap, canvas: wall.canvas, fit: 'canvas' };
}

/** The `wall.add` arguments of a new wall, or the `wall.set` ones of an edited wall. */
export function wallArgs(draft: WizardDraft & { grid: Grid }): {
  id?: number; cols: number; rows: number; outputs: number[]; overlap?: { x: number; y: number }; canvas: number; fit: 'canvas' | 'makeCanvas';
} {
  const overlap = { x: draft.overlap / 100, y: draft.overlap / 100 };
  const base = { cols: draft.grid.cols, rows: draft.grid.rows, outputs: draft.order, canvas: draft.canvas, fit: draft.fit };
  if (draft.edit === null) return { ...base, overlap };
  return draft.overlap === draft.overlapWas ? { id: draft.edit, ...base } : { id: draft.edit, ...base, overlap };
}

/** Puts `pattern` on the outputs `ids`: the test patterns to set, and `saved` with each output's pattern from before
 * (an output already in `saved` keeps the pattern saved first). */
export function patternChange(outputs: OutputConfig[], ids: number[], pattern: number, saved: Record<number, number>): { set: { id: number; pattern: number }[]; saved: Record<number, number> } {
  const next = { ...saved };
  const set: { id: number; pattern: number }[] = [];
  for (const id of ids) {
    const o = outputs.find((x) => x.id === id);
    if (!o) continue;
    next[id] ??= o.testPattern;
    if (o.testPattern !== pattern) set.push({ id, pattern });
  }
  return { set, saved: next };
}

/** Back to the saved test patterns, except for the outputs in `keep`: what to set, and what stays saved. */
export function patternRestore(outputs: OutputConfig[], saved: Record<number, number>, keep: number[] = []): { set: { id: number; pattern: number }[]; saved: Record<number, number> } {
  const set: { id: number; pattern: number }[] = [];
  const left: Record<number, number> = {};
  for (const [key, pattern] of Object.entries(saved)) {
    const id = Number(key);
    if (keep.includes(id)) {
      left[id] = pattern;
      continue;
    }
    const o = outputs.find((x) => x.id === id);
    if (o && o.testPattern !== pattern) set.push({ id, pattern });
  }
  return { set, saved: left };
}

export type Control = 'warp' | 'gamma' | 'curve' | 'floor' | 'colour' | 'rgb';

export interface SeamHint {
  see: string;
  turn: string;
  /** what the user taps on the mini-map to open `control`; null: nothing to open in Fanous yet */
  target: 'seam' | 'projector' | null;
  control: Control;
}

const colourHints: SeamHint[] = [
  { see: 'One projector darker, or tinted', turn: "That projector's colour gain. Not in Fanous yet: use the projector's own colour settings for now.", target: null, control: 'colour' },
  { see: 'A colour shift only inside a seam', turn: 'Unlink RGB on that seam and tune the channel that is off', target: 'seam', control: 'rgb' },
];

/** The seam check (DESIGN §9.9): a pattern on every projector of the wall per step, with what to look for and which
 * control to turn. */
export const SEAM_STEPS: { name: string; pattern: number; shows: string; hints: SeamHint[] }[] = [
  {
    name: TEST_PATTERNS[PATTERN.grid], pattern: PATTERN.grid, shows: 'The alignment grid.',
    hints: [{ see: 'Lines that do not meet across a seam', turn: 'The warp, not the blend: opens Warp & Slices for the projector', target: 'projector', control: 'warp' }],
  },
  {
    name: TEST_PATTERNS[PATTERN.blendCheck], pattern: PATTERN.blendCheck, shows: "50 % grey, with each projector's grid lines in its own colour.",
    hints: [
      { see: 'A bright band in a seam', turn: "That seam's gamma, down", target: 'seam', control: 'gamma' },
      { see: 'A dark band in a seam', turn: "That seam's gamma, up", target: 'seam', control: 'gamma' },
      { see: 'A visible edge where the overlap starts', turn: "That seam's curve", target: 'seam', control: 'curve' },
    ],
  },
  {
    name: TEST_PATTERNS[PATTERN.grey0], pattern: PATTERN.grey0, shows: 'Black: the light a projector gives at black.',
    hints: [{ see: 'Seams lighter than the rest', turn: 'The black floor of the projectors next to it, up, one by one until even', target: 'projector', control: 'floor' }],
  },
  { name: TEST_PATTERNS[PATTERN.grey25], pattern: PATTERN.grey25, shows: 'Dark grey.', hints: colourHints },
  { name: TEST_PATTERNS[PATTERN.grey75], pattern: PATTERN.grey75, shows: 'Light grey.', hints: colourHints },
  { name: TEST_PATTERNS[PATTERN.white], pattern: PATTERN.white, shows: 'Full white.', hints: colourHints },
];
