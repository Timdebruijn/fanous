// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { UNIT_QUAD, ellipsePath, handles, meshIdentity, rectanglePath, smoothPoint, type MapPoint, type MaskPoint, type MaskShape, type OutputConfig } from './outputs';
import { choose, grid, groups, label, members, nudgeCommand, nudgeQueue, step, trackpad } from './remote';
import { toScreen } from './warp';

function output(change: Partial<OutputConfig['warp']> = {}): OutputConfig {
  return {
    id: 1, name: 'Output 1', display: null, region: null, mode: null, intensity: 1, testPattern: 0,
    blend: {} as OutputConfig['blend'],
    warp: { cornerPin: UNIT_QUAD, mesh: null, ...change },
    slices: [{ id: 2, canvas: 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: UNIT_QUAD, masks: [{ mode: 'add', feather: 0, path: [...rectanglePath({ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.9 }), { x: 0.5, y: 0.95 }] }], opacity: 1 }],
  };
}
const size = { w: 1000, h: 500 };
const quad = grid(output(), 'cornerPin', 4);
const mesh = output({ mesh: meshIdentity(5, 3) });
const cells = grid(mesh, 'mesh', 15);

describe('selection', () => {
  it('lays a quad out as 2 × 2 (stored clockwise) and a mesh as its grid; a mask has no grid', () => {
    expect(quad).toEqual([[0, 1], [3, 2]]);
    expect(cells).toEqual([[0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10, 11, 12, 13, 14]]);
    expect(grid(output(), 'mask', 5)).toBeNull();
    expect(grid(output(), 'mesh', 0)).toBeNull();
    expect(groups('mask')).toEqual(['point', 'all']);
    expect(groups('cornerPin')).not.toContain('row');
  });

  it('a row, a column and each edge of a mesh; an edge of a quad is its two corners', () => {
    expect(members(cells, 15, 'row', 7)).toEqual([5, 6, 7, 8, 9]);
    expect(members(cells, 15, 'column', 7)).toEqual([2, 7, 12]);
    expect(members(cells, 15, 'top', 7)).toEqual([0, 1, 2, 3, 4]);
    expect(members(cells, 15, 'right', 7)).toEqual([4, 9, 14]);
    expect(members(cells, 15, 'bottom', 7)).toEqual([10, 11, 12, 13, 14]);
    expect(members(cells, 15, 'left', 7)).toEqual([0, 5, 10]);
    expect(members(quad, 4, 'top', 0)).toEqual([0, 1]);
    expect(members(quad, 4, 'right', 0)).toEqual([1, 2]);
    expect(members(quad, 4, 'bottom', 0)).toEqual([3, 2]);
    expect(members(quad, 4, 'left', 0)).toEqual([0, 3]);
    expect(members(null, 5, 'all', 2)).toEqual([0, 1, 2, 3, 4]);
    expect(members(null, 5, 'point', -1)).toEqual([]);
  });

  it('next and previous: row-major points (wrapping), rows, columns, sides clockwise; none selected starts at an end', () => {
    const points = (from: number, dir: 1 | -1, n: number) => {
      const seen: number[] = [];
      for (let a = from, i = 0; i < n; i++) seen.push((a = step(quad, 4, 'point', a, dir).anchor));
      return seen;
    };
    expect(points(-1, 1, 5)).toEqual([0, 1, 3, 2, 0]);
    expect(points(-1, -1, 2)).toEqual([2, 3]);
    expect(step(cells, 15, 'point', 4, 1).anchor).toBe(5);
    expect(step(cells, 15, 'row', 7, 1)).toEqual({ group: 'row', anchor: 12 });
    expect(step(cells, 15, 'row', 12, 1)).toEqual({ group: 'row', anchor: 2 });
    expect(step(cells, 15, 'column', 9, 1)).toEqual({ group: 'column', anchor: 5 });
    expect(step(cells, 15, 'column', 5, -1)).toEqual({ group: 'column', anchor: 9 });
    expect(step(quad, 4, 'top', 1, 1)).toEqual({ group: 'right', anchor: 1 });
    expect(step(quad, 4, 'left', 0, 1)).toEqual({ group: 'top', anchor: 0 });
    expect(step(null, 5, 'point', 4, 1).anchor).toBe(0);
    expect(step(null, 5, 'all', 3, 1)).toEqual({ group: 'all', anchor: 3 });
  });

  it('choosing an edge brings the anchor onto it; a group without an anchor starts at the first point', () => {
    expect(choose(cells, 15, 'bottom', 7)).toEqual({ group: 'bottom', anchor: 10 });
    expect(choose(cells, 15, 'bottom', 12)).toEqual({ group: 'bottom', anchor: 12 });
    expect(choose(cells, 15, 'row', -1)).toEqual({ group: 'row', anchor: 0 });
    expect(choose(null, 0, 'all', -1)).toEqual({ group: 'all', anchor: -1 });
  });

  it('labels per mode', () => {
    expect(label(output(), 'cornerPin', 0, quad, 'point', 2)).toBe('corner bottom-right');
    expect(label(mesh, 'mesh', 0, cells, 'point', 7)).toBe('r2 c3');
    expect(label(mesh, 'mesh', 0, cells, 'row', 7)).toBe('row 2');
    expect(label(mesh, 'mesh', 0, cells, 'column', 7)).toBe('column 3');
    expect(label(output(), 'slices', 0, quad, 'point', 3)).toBe('slice 2 · bottom-left');
    expect(label(output(), 'slices', 0, quad, 'left', 3)).toBe('slice 2 · left edge');
    expect(label(output(), 'mask', 0, null, 'point', 4)).toBe('slice 2 · mask point 5');
    expect(label(output(), 'mask', 0, null, 'all', 4)).toBe('slice 2 · all mask points');
    expect(label(mesh, 'mesh', 0, cells, 'all', 4)).toBe('all points');
    expect(label(output(), 'cornerPin', 0, quad, 'point', -1)).toBe('no point selected');
  });
});

describe('nudge', () => {
  it('one point writes its own path, a group its whole list with only the group moved', () => {
    expect(nudgeCommand(output(), 'cornerPin', 0, [1], 0, 2, size)).toEqual({ path: '/warp/cornerPin/1', value: { x: 1, y: 0.004 } });
    const row = nudgeCommand(mesh, 'mesh', 0, members(cells, 15, 'row', 7), 0, -5, size)!;
    expect(row.path).toBe('/warp/mesh/points');
    const points = row.value as unknown as MapPoint[];
    expect(points).toHaveLength(15);
    points.forEach((p, i) => expect(p.y).toBeCloseTo(mesh.warp.mesh!.points[i]!.y - (i >= 5 && i < 10 ? 0.01 : 0), 12));
    expect(nudgeCommand(output(), 'mask', 0, [0, 1, 2, 3, 4], 0.25, 0, size)!.path).toBe('/slices/0/masks');
    expect(nudgeCommand(output(), 'slices', 0, [0, 1], 0, 1, size)!.path).toBe('/slices/0/dest');
    expect(nudgeCommand(output(), 'slices', 0, [0, 1], 1, 0, size)).toBeNull(); // the top edge spans the output
  });

  it('a mask point keeps its handles; several masks move as their list, and the label names the mask', () => {
    const o = output();
    const curve = { mode: 'add' as const, feather: 0, path: [{ x: 0.5, y: 0.5, in: { x: -0.1, y: 0 }, out: { x: 0.1, y: 0 } }, { x: 0.8, y: 0.5 }, { x: 0.6, y: 0.8 }] };
    const two = { ...o, slices: [{ ...o.slices[0]!, masks: [curve, o.slices[0]!.masks![0]!] }] };
    const one = nudgeCommand(two, 'mask', 0, [0], 10, 0, size)!;
    expect(one.path).toBe('/slices/0/masks/0/path/0');
    expect(one.value).toMatchObject({ y: 0.5, in: { x: -0.1, y: 0 }, out: { x: 0.1, y: 0 } });
    expect((one.value as unknown as MapPoint).x).toBeCloseTo(0.51, 12);
    // the list: mask 1 point 1, its in and out handles, points 2 and 3, then mask 2
    expect(label(two, 'mask', 0, null, 'point', 6)).toBe('slice 2 · mask 2 point 2');
    const all = nudgeCommand(two, 'mask', 0, members(null, 10, 'all', 0), 0, 5, size)!;
    expect(all.path).toBe('/slices/0/masks');
    const masks = all.value as unknown as MaskShape[];
    expect(masks[0]!.path![0]).toMatchObject({ in: { x: -0.1, y: 0 }, out: { x: 0.1, y: 0 } });
    masks.forEach((m, i) => m.path!.forEach((p, j) => expect(p.y).toBeCloseTo(two.slices[0]!.masks![i]!.path![j]!.y + 0.01, 12)));
  });

  it('steps through a mask point and then its Bézier handles; a handle moves alone, as the offset from its point', () => {
    const o = output();
    const oval = { ...o, slices: [{ ...o.slices[0]!, masks: [{ mode: 'subtract' as const, feather: 0, path: ellipsePath({ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 }) }] }] };
    const count = handles(oval, 'mask', 0).length;
    expect(count, 'four points with two handles each').toBe(12);
    const names = [0, 1, 2, 3].map((i) => label(oval, 'mask', 0, null, 'point', step(null, count, 'point', i - 1, 1).anchor));
    expect(names).toEqual(['slice 2 · mask point 1', 'slice 2 · mask point 1 in', 'slice 2 · mask point 1 out', 'slice 2 · mask point 2']);
    expect(label(oval, 'mask', 0, null, 'point', step(null, count, 'point', 0, -1).anchor), 'Previous wraps to the last handle').toBe('slice 2 · mask point 4 out');
    // the top point's out handle 10 px right: the point stays, its out handle grows by 0.01, its in handle stays
    const top = oval.slices[0]!.masks[0]!.path[0]!;
    const knob = nudgeCommand(oval, 'mask', 0, [2], 10, 0, size)!;
    expect(knob.path).toBe('/slices/0/masks/0/path/0');
    const moved = knob.value as unknown as MaskPoint;
    expect([moved.x, moved.y, moved.in]).toEqual([top.x, top.y, top.in]);
    expect(moved.out!.x).toBeCloseTo(top.out!.x + 0.01, 12);
    // all points down 5 px: the handles go with them, unchanged, and are not points of their own
    const all = nudgeCommand(oval, 'mask', 0, members(null, count, 'all', 0), 0, 5, size)!.value as unknown as MaskShape[];
    expect(all[0]!.path).toHaveLength(4);
    all[0]!.path!.forEach((p, i) => {
      expect(p.y).toBeCloseTo(oval.slices[0]!.masks[0]!.path[i]!.y + 0.01, 12);
      expect([p.in, p.out]).toEqual([oval.slices[0]!.masks[0]!.path[i]!.in, oval.slices[0]!.masks[0]!.path[i]!.out]);
    });
  });

  it('a Bézier handle outside the output (a smoothed corner at its edge) still moves, either way', () => {
    const o = output();
    const box = rectanglePath({ x: 0, y: 0 }, { x: 1, y: 1 });
    const smooth = { ...o, slices: [{ ...o.slices[0]!, masks: [{ mode: 'add' as const, feather: 0, path: box.map((_, i) => smoothPoint(box, i)) }] }] };
    // the top-left point's in handle, at (−1/6, 1/6), is index 1 of the list
    expect(handles(smooth, 'mask', 0)[1]!.point.x).toBeLessThan(0);
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
      const moved = nudgeCommand(smooth, 'mask', 0, [1], dx * 10, dy * 5, size)!.value as unknown as MaskPoint;
      expect(moved.in!.x + 1 / 6).toBeCloseTo(dx / 100, 12);
      expect(moved.in!.y - 1 / 6).toBeCloseTo(dy / 100, 12);
    }
  });

  it('a group moves as one: it stops at the edge of the output instead of being squeezed', () => {
    const all = members(cells, 15, 'all', 0);
    expect(nudgeCommand(mesh, 'mesh', 0, all, 10, 0, size)).toBeNull();
    // the mask spans 0.1…0.9 across: 100 px to the left edge, so 300 px moves it 100 px
    const mask = (nudgeCommand(output(), 'mask', 0, [0, 1, 2, 3, 4], -300, 0, size)!.value as unknown as MaskShape[])[0]!.path!;
    expect(mask.map((p) => Math.round(p.x * 1000) / 1000)).toEqual([0, 0.8, 0.8, 0, 0.4]);
  });

  it('under a warp a point held at 0…1 holds the whole group: nothing is squeezed or bent', () => {
    const inset = [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.1, y: 0.9 }];
    const bent = { cols: 3, rows: 3, points: [[0, 0], [0.5, 0.05], [1, 0], [0.02, 0.5], [0.55, 0.45], [0.98, 0.5], [0, 1], [0.5, 0.95], [1, 1]].map(([x, y]) => ({ x: x!, y: y! })) };
    const cases = [
      { out: output({ cornerPin: inset, mesh: meshIdentity(3, 3) }), mode: 'mesh' as const, indices: [3, 4, 5] }, // middle row
      { out: output({ cornerPin: inset, mesh: meshIdentity(3, 3) }), mode: 'mesh' as const, indices: [2, 5, 8] }, // right edge
      { out: output({ cornerPin: inset, mesh: bent }), mode: 'slices' as const, indices: [0, 1] }, // slice top edge
      { out: output({ cornerPin: inset, mesh: bent }), mode: 'slices' as const, indices: [1, 2] }, // slice right edge
    ];
    let movedCount = 0;
    for (const { out, mode, indices } of cases) {
      const all = mode === 'mesh' ? out.warp.mesh!.points : out.slices[0]!.dest;
      for (const [dx, dy] of [[10, 0], [-10, 0], [0, 10], [0, -10]] as const) {
        const command = nudgeCommand(out, mode, 0, indices, dx, dy, size);
        if (!command) continue;
        movedCount++;
        const after = command.value as unknown as MapPoint[];
        all.forEach((p, i) => {
          const before = toScreen(out, mode, p), now = toScreen(out, mode, after[i]!);
          const [ex, ey] = indices.includes(i) ? [dx, dy] : [0, 0];
          expect((now.x - before.x) * size.w).toBeCloseTo(ex, 3);
          expect((now.y - before.y) * size.h).toBeCloseTo(ey, 3);
        });
      }
    }
    expect(movedCount).toBeGreaterThan(0); // inward moves do happen (the row up and down, the right edge left)
    // the cases the review found: a border point at stored x = 1 would stay while the rest of the row moves right
    expect(nudgeCommand(cases[0]!.out, 'mesh', 0, [3, 4, 5], 10, 0, size)).toBeNull();
    expect(nudgeCommand(cases[1]!.out, 'mesh', 0, [2, 5, 8], 10, 0, size)).toBeNull();
    expect(nudgeCommand(cases[1]!.out, 'mesh', 0, [2, 5, 8], -10, 0, size)).not.toBeNull();
  });

  it('respects a warp in effect: each mesh point moves 4 px on screen through a corner pin', () => {
    const pinned = output({ cornerPin: [{ x: 0.1, y: 0.05 }, { x: 0.95, y: 0 }, { x: 0.9, y: 1 }, { x: 0, y: 0.9 }], mesh: meshIdentity(3, 3) });
    const column = [1, 4, 7];
    const value = nudgeCommand(pinned, 'mesh', 0, column, 4, 0, size)!.value as unknown as MapPoint[];
    for (const i of column) {
      const before = toScreen(pinned, 'mesh', pinned.warp.mesh!.points[i]!);
      const after = toScreen(pinned, 'mesh', value[i]!);
      expect((after.x - before.x) * size.w).toBeCloseTo(4, 6);
      expect(after.y - before.y).toBeCloseTo(0, 9);
    }
  });

  it('trackpad: 1 output px per 4 CSS px, four times that above 600 CSS px/s', () => {
    expect(trackpad(8, -4, 100)).toEqual([2, -1]); // 89 px/s
    expect(trackpad(40, 0, 50)).toEqual([40, 0]); // 800 px/s
    expect(trackpad(5, 0, 8)).toEqual([5, 0]); // 625 px/s at 120 Hz
    expect(trackpad(2, 0, 1)).toEqual([0.5, 0]); // right after touching down: not a flick
  });
});

describe('nudgeQueue', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('sends the first nudge at once, adds up what comes in meanwhile and sends it after the gap', async () => {
    const sent: [string, number, number][] = [];
    const run = (key: string) => async (dx: number, dy: number) => void sent.push([key, dx, dy]);
    const nudge = nudgeQueue(100);
    nudge('a', 1, 0, run('a'));
    nudge('a', 1, 0, run('a'));
    nudge('a', 0.25, -1, run('a'));
    expect(sent).toEqual([['a', 1, 0]]);
    nudge('b', 0, 1, run('b')); // another selection is not merged into the previous one
    await vi.advanceTimersByTimeAsync(100);
    expect(sent).toEqual([['a', 1, 0], ['a', 1.25, -1]]);
    await vi.advanceTimersByTimeAsync(100);
    expect(sent.at(-1)).toEqual(['b', 0, 1]);
    await vi.advanceTimersByTimeAsync(100);
    nudge('a', 1, 0, run('a')); // idle again: at once
    expect(sent).toHaveLength(4);
  });

  it('a failed send does not stall the nudges behind it', async () => {
    const sent: number[] = [];
    const nudge = nudgeQueue(100);
    nudge('a', 1, 0, () => Promise.reject(new Error('socket closed')));
    nudge('b', 2, 0, async (dx) => void sent.push(dx));
    await vi.advanceTimersByTimeAsync(100);
    expect(sent).toEqual([2]);
  });
});
