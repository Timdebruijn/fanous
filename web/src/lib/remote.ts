// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// iPad remote mode on Warp & Slices (DESIGN §9.9): which points a selection covers, stepping through them, the label
// in large type, the trackpad gain and the one `output.set` that moves them. A selection is a group plus an anchor, the
// index of one point in `handles(output, mode, sliceIndex)`; the anchor is the point the mapper has selected.
import type { JSONValue } from './protocol';
import { handles, maskHandle, type MapPoint, type MapperMode, type OutputConfig } from './outputs';
import { nudgeStored, toScreen } from './warp';

export const SIDES = ['top', 'right', 'bottom', 'left'] as const;
export type Side = (typeof SIDES)[number];
/** What moves: the anchor point, its row or column of the grid, every point on one border side, or all points. */
export type Group = 'point' | 'row' | 'column' | 'all' | Side;

const CORNERS = ['top-left', 'top-right', 'bottom-right', 'bottom-left'];

function isSide(group: Group): group is Side {
  return (SIDES as readonly string[]).includes(group);
}

function wrap(i: number, n: number): number {
  return ((i % n) + n) % n;
}

/** The points as a grid, rows top to bottom: a quad (corner pin, slice) is 2 × 2, stored clockwise from the top left;
 *  a mesh is its own grid. A mask has none, nor has a mode without points. */
export function grid(output: OutputConfig, mode: MapperMode, count: number): number[][] | null {
  if ((mode === 'cornerPin' || mode === 'slices') && count === 4) return [[0, 1], [3, 2]];
  const mesh = output.warp.mesh;
  if (mode !== 'mesh' || !mesh || count !== mesh.cols * mesh.rows) return null;
  return Array.from({ length: mesh.rows }, (_, r) => Array.from({ length: mesh.cols }, (_, c) => r * mesh.cols + c));
}

/** The groups a mode offers: rows and columns only on a mesh (on a quad they are its edges), no edges on a mask. */
export function groups(mode: MapperMode): Group[] {
  if (mode === 'mask') return ['point', 'all'];
  return mode === 'mesh' ? ['point', 'row', 'column', 'all', ...SIDES] : ['point', 'all', ...SIDES];
}

function cell(cells: number[][] | null, index: number): { r: number; c: number } | null {
  if (!cells) return null;
  for (let r = 0; r < cells.length; r++) {
    const c = cells[r]!.indexOf(index);
    if (c >= 0) return { r, c };
  }
  return null;
}

/** The indices that move, row-major. */
export function members(cells: number[][] | null, count: number, group: Group, anchor: number): number[] {
  if (group === 'all') return Array.from({ length: count }, (_, i) => i);
  if (group === 'point') return anchor >= 0 && anchor < count ? [anchor] : [];
  if (!cells) return [];
  const at = cell(cells, anchor);
  switch (group) {
    case 'row': return at ? cells[at.r]! : [];
    case 'column': return at ? cells.map((row) => row[at.c]!) : [];
    case 'top': return cells[0]!;
    case 'bottom': return cells.at(-1)!;
    case 'left': return cells.map((row) => row[0]!);
    case 'right': return cells.map((row) => row.at(-1)!);
  }
}

/** Picks a group: an anchor is needed (the first point if there is none), and an edge brings the anchor onto it. */
export function choose(cells: number[][] | null, count: number, group: Group, anchor: number): { group: Group; anchor: number } {
  if (count === 0) return { group, anchor: -1 };
  const a = anchor >= 0 && anchor < count ? anchor : 0;
  const on = isSide(group) ? members(cells, count, group, a) : [];
  return { group, anchor: on.length && !on.includes(a) ? on[0]! : a };
}

/** Next (+1) or previous (−1), wrapping: the next point row-major, the next row or column, the next side clockwise. */
export function step(cells: number[][] | null, count: number, group: Group, anchor: number, dir: 1 | -1): { group: Group; anchor: number } {
  if (count === 0 || group === 'all') return { group, anchor };
  if (isSide(group) && cells) return choose(cells, count, SIDES[wrap(SIDES.indexOf(group) + dir, SIDES.length)]!, anchor);
  const at = cell(cells, anchor);
  if (cells && at && group === 'row') return { group, anchor: cells[wrap(at.r + dir, cells.length)]![at.c]! };
  if (cells && at && group === 'column') return { group, anchor: cells[at.r]![wrap(at.c + dir, cells[0]!.length)]! };
  const order = cells?.flat() ?? Array.from({ length: count }, (_, i) => i);
  const i = order.indexOf(anchor);
  return { group, anchor: order[i < 0 ? (dir > 0 ? 0 : order.length - 1) : wrap(i + dir, order.length)]! };
}

/** "corner top-left", "r3 c5", "slice 2 · bottom-right", "slice 2 · mask point 5" ("mask 2 point 5" with several), "row 3", "top edge", "all points". */
export function label(output: OutputConfig, mode: MapperMode, sliceIndex: number, cells: number[][] | null, group: Group, anchor: number): string {
  const slice = mode === 'slices' || mode === 'mask' ? `slice ${output.slices[sliceIndex]?.id ?? sliceIndex + 1} · ` : '';
  const at = cell(cells, anchor);
  if (group === 'all') return `${slice}all ${mode === 'mask' ? 'mask ' : ''}points`;
  if (isSide(group)) return `${slice}${group} edge`;
  if (group === 'row' && at) return `row ${at.r + 1}`;
  if (group === 'column' && at) return `column ${at.c + 1}`;
  if (anchor < 0) return 'no point selected';
  switch (mode) {
    case 'cornerPin': return `corner ${CORNERS[anchor]}`;
    case 'mesh': return at ? `r${at.r + 1} c${at.c + 1}` : `point ${anchor + 1}`;
    case 'slices': return `${slice}${CORNERS[anchor]}`;
    case 'mask': {
      // the mask's number only when the slice has more than one
      const h = maskHandle(handles(output, mode, sliceIndex)[anchor]?.path);
      const several = (output.slices[sliceIndex]?.masks?.length ?? 0) > 1;
      return h ? `${slice}mask ${several ? `${h.mask + 1} ` : ''}point ${h.point + 1}` : 'no point selected';
    }
  }
}

/** The one `output.set` that moves `indices` by (dx, dy) output pixels as seen on screen, through the warp
 *  (`nudgeStored`). The points move as one: the step stops where the first of them would leave the output, and under a
 *  warp a point whose stored position would leave 0…1 holds the whole group, so a group is never squeezed or bent.
 *  A single point writes its own path (a mask point keeps its handles), several write their whole list (mask points:
 *  the slice's masks). Null when nothing moves. */
export function nudgeCommand(
  output: OutputConfig, mode: MapperMode, sliceIndex: number, indices: number[], dx: number, dy: number, size: { w: number; h: number },
): { path: string; value: JSONValue } | null {
  const all = handles(output, mode, sliceIndex);
  const moving = indices.filter((i) => all[i]);
  if (moving.length === 0) return null;
  const on = moving.map((i) => toScreen(output, mode, all[i]!.point));
  const limit = (d: number, values: number[]) => Math.min(Math.max(d, Math.min(0, -Math.min(...values))), Math.max(0, 1 - Math.max(...values)));
  const nx = limit(dx / size.w, on.map((p) => p.x));
  const ny = limit(dy / size.h, on.map((p) => p.y));
  if (nx === 0 && ny === 0) return null;
  const moved = moving.map((i) => nudgeStored(output, mode, all[i]!.point, nx * size.w, ny * size.h, size));
  // nudgeStored clamps the stored point; its own error is below 0.001 px, so 0.05 px off means it was held back
  const held = moved.some((m, k) => {
    const to = toScreen(output, mode, m);
    return Math.abs((to.x - on[k]!.x - nx) * size.w) > 0.05 || Math.abs((to.y - on[k]!.y - ny) * size.h) > 0.05;
  });
  if (held || moved.every((m, k) => m.x === all[moving[k]!]!.point.x && m.y === all[moving[k]!]!.point.y)) return null;
  // a mask point keeps its handles
  if (moving.length === 1) return { path: all[moving[0]!]!.path, value: { ...all[moving[0]!]!.point, ...moved[0]! } };
  if (mode === 'mask') {
    // the points of several masks: their list as a whole
    const masks = (output.slices[sliceIndex]?.masks ?? []).map((m) => ({ ...m, path: m.path?.slice() }));
    moving.forEach((i, k) => {
      const h = maskHandle(all[i]!.path)!;
      masks[h.mask]!.path![h.point] = { ...masks[h.mask]!.path![h.point]!, ...moved[k]! };
    });
    return { path: `/slices/${sliceIndex}/masks`, value: masks as unknown as JSONValue };
  }
  const points: MapPoint[] = all.map((h) => h.point);
  moving.forEach((i, k) => (points[i] = moved[k]!));
  const first = all[0]!.path;
  return { path: first.slice(0, first.lastIndexOf('/')), value: points as unknown as JSONValue };
}

/** Output pixels for a trackpad move of (dx, dy) CSS px in `ms`: 1 px per 4 CSS px, four times that above 600 CSS px/s.
 *  An interval shorter than a 120 Hz frame counts as one (the first move right after touching down is not a flick). */
export function trackpad(dx: number, dy: number, ms: number): [number, number] {
  const gain = (Math.hypot(dx, dy) / Math.max(ms, 8)) * 1000 > 600 ? 1 : 0.25;
  return [dx * gain, dy * gain];
}

/** Nudges go out one command at a time and at most one per `gap` ms; what comes in meanwhile for the same selection
 *  (`key`) is added up and sent next. A fast burst of taps or a trackpad drag then loses no step to a command that
 *  was computed before the previous one came back, and the engine is not flooded. */
export function nudgeQueue(gap = 100) {
  const queue: { key: string; dx: number; dy: number; run: (dx: number, dy: number) => Promise<unknown> }[] = [];
  let busy = false;
  async function drain() {
    busy = true;
    for (let next = queue.shift(); next; next = queue.shift()) {
      // a failed send must not stall the nudges behind it
      await Promise.all([next.run(next.dx, next.dy).catch(() => undefined), new Promise((done) => setTimeout(done, gap))]);
    }
    busy = false;
  }
  return (key: string, dx: number, dy: number, run: (dx: number, dy: number) => Promise<unknown>) => {
    const last = queue.at(-1);
    if (last?.key === key) {
      last.dx += dx;
      last.dy += dy;
    } else {
      queue.push({ key, dx, dy, run });
    }
    if (!busy) void drain();
  };
}
