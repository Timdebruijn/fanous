// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { OutputConfig, WarpSettings } from './outputs';
import { nudgeStored, toScreen, applyHomography, homography, invert, meshPoint, resampleMesh, unwarp, warped } from './warp';

// Reference values printed by WarpMath (MappingMath.swift) for exactly these inputs.
const quad = [{ x: 0.05, y: 0.1 }, { x: 0.95, y: 0 }, { x: 1, y: 0.9 }, { x: 0, y: 1 }];
const mesh = {
  cols: 3,
  rows: 3,
  points: [[0, 0], [0.5, 0.05], [1, 0], [0.02, 0.5], [0.55, 0.45], [0.98, 0.5], [0, 1], [0.5, 0.95], [1, 1]].map(([x, y]) => ({ x: x!, y: y! })),
};
const warp: WarpSettings = { cornerPin: quad, mesh };
const close = (p: { x: number; y: number }, x: number, y: number) => {
  expect(p.x).toBeCloseTo(x, 9);
  expect(p.y).toBeCloseTo(y, 9);
};

describe('warp port', () => {
  it('homography matches Swift', () => {
    const h = homography(quad);
    [0.8895027624309392, -0.05, 0.05, -0.1, 0.8005524861878452, 0.1, -0.011049723756906086, -0.09944751381215478, 1].forEach((v, i) => expect(h[i]).toBeCloseTo(v, 12));
    close(applyHomography(h, 0.5, 0.5), 0.49722222222222223, 0.476608187134503);
    close(applyHomography(h, 0.25, 0.75), 0.254565868263473, 0.7320359281437124);
    close(applyHomography(h, 1, 1), 1, 0.9);
  });
  it('mesh and combined warp match Swift', () => {
    close(meshPoint(mesh, 0.5, 0.5), 0.55, 0.45);
    close(meshPoint(mesh, 0.25, 0.75), 0.27578125, 0.71484375);
    close(meshPoint(mesh, 0.9, 0.2), 0.8978176, 0.2012064);
    close(warped(warp, 0.5, 0.5), 0.5443975552968568, 0.42694994179278223);
    close(warped(warp, 0.25, 0.75), 0.28035024987879015, 0.696314287845448);
    close(warped(warp, 0.9, 0.2), 0.8644231991359584, 0.17657957019461681);
  });
  it('unwarp inverts warped, with and without a mesh', () => {
    for (const w of [warp, { cornerPin: quad, mesh: null }]) {
      for (const [u, v] of [[0.5, 0.5], [0.25, 0.75], [0.9, 0.2], [0.1, 0.1]] as const) {
        const q = unwarp(w, warped(w, u, v));
        expect(q.x).toBeCloseTo(u, 5);
        expect(q.y).toBeCloseTo(v, 5);
      }
    }
  });
  it('invert and degenerate quads', () => {
    expect(invert([1, 2, 3, 2, 4, 6, 0, 0, 1])).toBeNull();
    expect(homography([])).toEqual([1, 0, 0, 0, 1, 0, 0, 0, 1]);
  });
});

describe('nudge through the warp', () => {
  const output = { warp } as unknown as OutputConfig;
  it('moves a slice point by whole screen pixels even under a warp', () => {
    const stored = { x: 0.5, y: 0.5 };
    const next = nudgeStored(output, 'slices', stored, 10, 0, { w: 1000, h: 1000 });
    const before = toScreen(output, 'slices', stored);
    const after = toScreen(output, 'slices', next);
    expect((after.x - before.x) * 1000).toBeCloseTo(10, 3);
    expect(after.y - before.y).toBeCloseTo(0, 6);
  });
});

describe('mesh resample', () => {
  it('gives a flat grid without a mesh', () => {
    expect(resampleMesh(null, 2, 2).points).toEqual([{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }]);
  });
  it('keeps shared points exactly and the shape between them', () => {
    const bent = { cols: 3, rows: 3, points: [
      { x: 0, y: 0 }, { x: 0.5, y: 0.05 }, { x: 1, y: 0 },
      { x: 0.02, y: 0.5 }, { x: 0.55, y: 0.48 }, { x: 0.97, y: 0.5 },
      { x: 0, y: 1 }, { x: 0.5, y: 0.96 }, { x: 1, y: 1 },
    ] };
    const fine = resampleMesh(bent, 5, 5);
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        const p = fine.points[r * 2 * 5 + c * 2]!, q = bent.points[r * 3 + c]!;
        expect(p.x).toBeCloseTo(q.x, 12);
        expect(p.y).toBeCloseTo(q.y, 12);
      }
    }
    const between = fine.points[1]!; // u = 0.25 on the top row
    expect(between).toEqual(meshPoint(bent, 0.25, 0));
    const back = resampleMesh(fine, 3, 3);
    back.points.forEach((p, i) => { expect(p.x).toBeCloseTo(bent.points[i]!.x, 12); expect(p.y).toBeCloseTo(bent.points[i]!.y, 12); });
  });
});
