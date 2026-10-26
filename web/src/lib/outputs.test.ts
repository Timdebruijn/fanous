// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { canvasSizeError, sourceFromPixels, sourcePixels, blendCurvePath, handles, insertPoint, meshIdentity, modeText, nudge, outlines, outputSize, statusText, type OutputConfig } from './outputs';

const output: OutputConfig = {
  id: 1,
  name: 'Output 1',
  display: { uuid: 'U', name: 'Epson' },
  region: null,
  mode: null,
  intensity: 1,
  blend: { left: { overlap: 0, power: 2, gamma: 2.2 }, right: { overlap: 0, power: 2, gamma: 2.2 }, top: { overlap: 0, power: 2, gamma: 2.2 }, bottom: { overlap: 0, power: 2, gamma: 2.2 }, lift: 0, liftFeather: 0 },
  warp: { cornerPin: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], mesh: meshIdentity(3, 3) },
  slices: [{ id: 1, canvas: 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], mask: { path: [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.5, y: 0.9 }], feather: 4 }, opacity: 1 }],
  testPattern: 0,
};

describe('outputs helpers', () => {
  it('builds handles with the JSON pointer each one edits', () => {
    expect(handles(output, 'cornerPin', 0).map((h) => h.path)).toEqual(['/warp/cornerPin/0', '/warp/cornerPin/1', '/warp/cornerPin/2', '/warp/cornerPin/3']);
    expect(handles(output, 'mesh', 0)).toHaveLength(9);
    expect(handles(output, 'mesh', 0)[4]!.point).toEqual({ x: 0.5, y: 0.5 });
    expect(handles(output, 'slices', 0)[2]!.path).toBe('/slices/0/dest/2');
    // two slices on the same corners: only the selected one gets handles, both keep an outline
    const two = { ...output, slices: [output.slices[0]!, { ...output.slices[0]!, id: 2 }] };
    expect(handles(two, 'slices', 1).map((h) => h.path)).toEqual(['/slices/1/dest/0', '/slices/1/dest/1', '/slices/1/dest/2', '/slices/1/dest/3']);
    expect(handles(two, 'slices', 0).every((h) => h.path.startsWith('/slices/0/'))).toBe(true);
    expect(outlines(two, 'slices', 0)).toHaveLength(2);
    expect(handles(output, 'mask', 0)).toHaveLength(3);
    expect(handles({ ...output, warp: { ...output.warp, mesh: null } }, 'mesh', 0)).toEqual([]);
  });

  it('draws mesh rows and columns as outlines', () => {
    expect(outlines(output, 'mesh', 0)).toHaveLength(6);
    expect(outlines(output, 'mask', 0)[0]!.points).toHaveLength(3);
    expect(outlines(output, 'slices', 0)[0]!.group).toBe(0);
  });

  it('sizes, modes and status texts', () => {
    expect(outputSize(output, [{ uuid: 'U', name: 'Epson', width: 1920, height: 1200, hz: 60, main: false, builtin: false, modes: [] }])).toEqual({ w: 1920, h: 1200 });
    expect(outputSize({ ...output, region: { x: 0, y: 0, w: 800, h: 600 } }, [])).toEqual({ w: 800, h: 600 });
    expect(modeText({ width: 3840, height: 2160, hz: 59.94 })).toBe('3840 × 2160 @ 59.94');
    expect(statusText(undefined, output).tone).toBe('faint');
    expect(statusText({ id: 1, state: 'lost', display: 'Epson', width: 0, height: 0, hz: 0, master: false }, output)).toEqual({ text: 'display missing: Epson', tone: 'red' });
    expect(statusText({ id: 1, state: 'bound', display: 'Epson', width: 1920, height: 1200, hz: 60, master: true }, output).text).toContain('clock master');
  });

  it('blend curve, point insertion and nudging', () => {
    const path = blendCurvePath({ overlap: 100, power: 2, gamma: 1 }, 100, 50, 4);
    expect(path).toBe('M0.0 50.0 L25.0 43.8 L50.0 25.0 L75.0 6.3 L100.0 0.0');
    expect(insertPoint([{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }], 2)).toEqual([{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0.5, y: 0.5 }]);
    expect(nudge({ x: 0.5, y: 0.5 }, 10, -10, { w: 1000, h: 500 })).toEqual({ x: 0.51, y: 0.48 });
    expect(nudge({ x: 0.999, y: 0 }, 10, -10, { w: 1000, h: 500 })).toEqual({ x: 1, y: 0 });
  });
});

describe('slice source in pixels', () => {
  const canvas = { width: 3840, height: 1080 };
  it('converts between the stored fraction and canvas pixels', () => {
    expect(sourcePixels({ x: 0.5, y: 0, w: 0.5, h: 1 }, canvas)).toEqual({ x: 1920, y: 0, w: 1920, h: 1080 });
    expect(sourcePixels({ x: 0.25, y: 0.5, w: 1, h: 1 }, undefined)).toEqual({ x: 480, y: 540, w: 1920, h: 1080 });
    expect(sourceFromPixels('x', 1920, canvas)).toBe(0.5);
    expect(sourceFromPixels('h', 540, canvas)).toBe(0.5);
    expect(sourceFromPixels('w', 99999, canvas)).toBe(1);
    expect(sourceFromPixels('w', Number.NaN, canvas)).toBeNull();
  });
});

describe('canvasSizeError', () => {
  it('accepts even sizes from 320 to 8192 and names the first problem', () => {
    expect(canvasSizeError(3840, 2160)).toBeNull();
    expect(canvasSizeError(320, 8192)).toBeNull();
    expect(canvasSizeError(1921, 1080)).toBe('Width must be even.');
    expect(canvasSizeError(1920, 200)).toMatch(/^Height must be a whole number/);
    expect(canvasSizeError(Number.NaN, 1080)).toMatch(/^Width/);
  });
});
