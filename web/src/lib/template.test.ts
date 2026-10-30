// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { insertNearest, type OutputConfig, type SliceConfig } from './outputs';
import { bilinear, inverseBilinear, maskPointOnCanvas, templateSVG } from './template';

const skewed = [{ x: 0.1, y: 0.05 }, { x: 0.95, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.05, y: 0.8 }];

describe('inverseBilinear', () => {
  it('inverts the slice mapping', () => {
    for (const [u, v] of [[0, 0], [1, 1], [0.3, 0.7], [0.5, 0.5]] as const) {
      const p = bilinear(skewed, u, v);
      const back = inverseBilinear(skewed, p)!;
      expect(back.u).toBeCloseTo(u, 6);
      expect(back.v).toBeCloseTo(v, 6);
    }
  });
});

describe('maskPointOnCanvas', () => {
  it('maps an output point through the slice back to canvas pixels', () => {
    const slice: SliceConfig = { id: 1, canvas: 1, source: { x: 0.5, y: 0, w: 0.5, h: 1 }, dest: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], opacity: 1 };
    const q = maskPointOnCanvas(slice, { x: 0.5, y: 0.25 }, { width: 1920, height: 1080 })!;
    expect(q.x).toBeCloseTo(1440, 3);
    expect(q.y).toBeCloseTo(270, 3);
  });
});

describe('insertNearest', () => {
  it('puts the point on the nearest edge', () => {
    const square = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];
    const { path, index } = insertNearest(square, { x: 0.95, y: 0.5 });
    expect(index).toBe(2);
    expect(path[2]).toEqual({ x: 0.95, y: 0.5 });
    expect(insertNearest(square, { x: 0.5, y: 0.98 }).index).toBe(3);
    expect(insertNearest(square, { x: 0.02, y: 0.4 }).index).toBe(4);
  });
});

describe('templateSVG', () => {
  it('labels every slice in canvas pixels and fills masks', () => {
    const output = {
      id: 1, name: 'Output 1',
      slices: [
        { id: 1, canvas: 1, source: { x: 0, y: 0, w: 0.5, h: 1 }, dest: skewed, masks: [{ mode: 'add', feather: 0, path: [{ x: 0.2, y: 0.2 }, { x: 0.8, y: 0.2 }, { x: 0.5, y: 0.8 }] }], opacity: 1 },
        { id: 2, canvas: 1, source: { x: 0.5, y: 0, w: 0.5, h: 1 }, dest: skewed, opacity: 1 },
      ],
    } as unknown as OutputConfig;
    const svg = templateSVG(output, { width: 3840, height: 2160 });
    expect(svg).toContain('width="3840" height="2160"');
    expect(svg).toContain('Slice 1 · 0,0 · 1920×2160 px · masked');
    expect(svg).toContain('Slice 2 · 1920,0 · 1920×2160 px');
    expect(svg.match(/<polygon/g)?.length).toBe(2); // the mask's shape and its outline
  });

  it('cuts a subtract mask out of the slice and leaves an image mask out (its file is in the library)', () => {
    const unit = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];
    const triangle = [{ x: 0.2, y: 0.2 }, { x: 0.8, y: 0.2 }, { x: 0.5, y: 0.8 }];
    const masks = [{ mode: 'subtract' as const, feather: 0, path: triangle }, { mode: 'add' as const, feather: 0, image: { folder: 1, file: 1 } }];
    const svg = templateSVG({ id: 1, name: 'O', slices: [{ id: 1, canvas: 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: unit, masks, opacity: 1 }] } as unknown as OutputConfig, { width: 100, height: 100 });
    expect(svg).toContain('<mask id="mask0"><rect x="0" y="0" width="100" height="100" fill="white"/><polygon points="20.0,20.0 ');
    expect(svg).toContain('fill="black"/></mask>');
    expect(svg.match(/<polygon/g)?.length).toBe(2);
  });
});
