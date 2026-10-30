// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it, vi } from 'vitest';
import { canvasSizeError, canvasTarget, colorOf, compareLease, freePresetNumber, previewReady, layerCanvas, layerRuns, layersOn, presetBadges, presetNote, recalledText, sharedPresets, sourceFromPixels, sourcePixels, spreadSources, blendCurvePath, handles, insertPoint, keystoneBadges, meshIdentity, modeText, nudge, outlines, outputSize, statusText, type OutputConfig } from './outputs';

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
  it('reads an output without colour (saved before M1.7) as gain 1, black 0', () => {
    expect(colorOf(output)).toEqual({ gain: [1, 1, 1], black: 0 });
    const tinted = { gain: [0.9, 1, 1.1] as [number, number, number], black: 0.02 };
    expect(colorOf({ ...output, color: tinted })).toEqual(tinted);
  });

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

  it('spreads the canvas over the slices left to right, by their width on the output', () => {
    const quad = (x0: number, x1: number) => [{ x: x0, y: 0 }, { x: x1, y: 0 }, { x: x1, y: 1 }, { x: x0, y: 1 }];
    const base = output.slices[0]!;
    // stored right face first: the result follows the position on the output, not the list order
    const slices = [{ ...base, id: 2, dest: quad(0.6, 1) }, { ...base, id: 1, dest: quad(0, 0.6) }];
    const spread = spreadSources(slices, { w: 1920, h: 1080 });
    expect(spread.map((s) => s.id)).toEqual([2, 1]);
    expect(spread[1]!.source).toEqual({ x: 0, y: 0, w: 0.6, h: 1 });
    expect(spread[0]!.source.x).toBeCloseTo(0.6);
    expect(spread[0]!.source.w).toBeCloseTo(0.4);
    // degenerate slices are left alone
    expect(spreadSources([{ ...base, dest: [] }], { w: 1920, h: 1080 })[0]!.source).toEqual(base.source);
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

  it('badges the keystone as live.outputs reports it (DESIGN §9.10 item 2)', () => {
    const bound = { id: 1, state: 'bound' as const, display: 'Epson', width: 1920, height: 1200, hz: 60, master: true };
    expect(keystoneBadges(undefined)).toEqual([]);
    expect(keystoneBadges({ ...bound, keystone: false, keystoneInvalid: false })).toEqual([]);
    expect(keystoneBadges({ ...bound, keystone: true, keystoneInvalid: false })).toEqual([{ text: 'Keystone active', warn: false }]);
    expect(keystoneBadges({ ...bound, keystone: true, keystoneInvalid: true }).map((b) => [b.text, b.warn])).toEqual([['Keystone active', false], ['Keystone invalid', true]]);
  });

  it('badges the preset an output shows and one it lacks (DESIGN §9.10 item 3)', () => {
    const bound = { id: 1, state: 'bound' as const, display: 'Epson', width: 1920, height: 1200, hz: 60, master: true };
    expect(presetBadges(undefined)).toEqual([]);
    expect(presetBadges({ ...bound, preset: null, presetSource: null, presetMissing: null })).toEqual([]);
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', presetMissing: null })).toEqual([{ text: 'Preset 3 (console)', warn: false }]);
    expect(presetBadges({ ...bound, preset: 2, presetSource: 'compare' })).toEqual([{ text: 'Preset 2 (compare)', warn: false }]);
    expect(presetBadges({ ...bound, preset: null, presetSource: 'console', presetMissing: 9 })).toEqual([{ text: 'Preset 9 missing', warn: true }]);
    // a morph over Output ch 7: from and to, 0 = the edited mapping
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', morph: { from: 1, to: 3, fade: 2 } })).toEqual([{ text: 'Preset 1 → 3 (console)', warn: false }]);
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', morph: { from: 0, to: 3, fade: 2 } }).map((b) => b.text)).toEqual(['Edited → Preset 3 (console)']);
    expect(presetBadges({ ...bound, preset: null, presetSource: null, morph: { from: 3, to: 0, fade: 2 } }).map((b) => b.text)).toEqual(['Preset 3 → edited (console)']);
    expect(presetBadges({ ...bound, preset: null, presetSource: 'console', presetMissing: 9, morph: { from: 3, to: 9, fade: 2 } }).map((b) => b.text)).toEqual(['Preset 3 → 9 (console)', 'Preset 9 missing']);
    expect(presetNote({ ...bound, preset: null, presetMissing: 9 })).toBeNull();
    expect(presetNote({ ...bound, preset: 3, presetSource: 'console' })).toContain('at channel 6 = 0');
    expect(presetNote({ ...bound, preset: 3, presetSource: 'compare' })).toContain('when Compare is let go');
  });

  it('a wall recall says which outputs it made manual', () => {
    const name = (id: number) => `Output ${id}`;
    expect(recalledText(2, null, name)).toBe('Preset 2 recalled.');
    const manual = { manual: [{ wall: 1, output: 1, field: 'source' }, { wall: 1, output: 3, field: 'source' }] };
    expect(recalledText(2, manual, name)).toBe("Preset 2 recalled. Slice 1 is manual now on Output 1, Output 3: it differs from the wall's part of the canvas.");
  });

  it('a wall strip offers the presets all its outputs have; Store as takes the lowest free number', () => {
    const preset = (number: number, name = `Preset ${number}`) => ({ number, name, warp: output.warp, slices: output.slices });
    const a = { ...output, presets: [preset(1, 'Wide'), preset(2), preset(4)] };
    const b = { ...output, id: 2, presets: [preset(2), preset(1, 'Other')] };
    expect(sharedPresets([a])).toEqual([{ number: 1, name: 'Wide' }, { number: 2, name: 'Preset 2' }, { number: 4, name: 'Preset 4' }]);
    expect(sharedPresets([a, b]).map((p) => p.number)).toEqual([1, 2]);
    expect(sharedPresets([output])).toEqual([]);
    expect(sharedPresets([])).toEqual([]);
    expect(freePresetNumber([output])).toBe(1);
    expect(freePresetNumber([a, b])).toBe(3);
    expect(freePresetNumber([{ ...output, presets: Array.from({ length: 255 }, (_, i) => preset(i + 1)) }])).toBeNull();
  });

  it('holding Compare sends the lease at once, renews it every 2 s and ends it with 0', () => {
    vi.useFakeTimers();
    try {
      const sent: number[] = [];
      const lease = compareLease((p) => sent.push(p));
      lease.stop();
      expect(sent, 'nothing to end').toEqual([]);
      lease.start(4);
      vi.advanceTimersByTime(4100);
      expect(sent).toEqual([4, 4, 4]);
      lease.start(5);  // another preset while held: the latest wins, one renewal timer
      vi.advanceTimersByTime(2000);
      lease.stop();
      lease.stop();
      vi.advanceTimersByTime(6000);
      expect(sent).toEqual([4, 4, 4, 5, 5, 0]);
    } finally {
      vi.useRealTimers();
    }
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

describe('multiple canvases', () => {
  it('names preview targets, keeping "canvas" for canvas 1', () => {
    expect(canvasTarget(1)).toBe('canvas');
    expect(canvasTarget(3)).toBe('canvas:3');
  });
  it('holds a canvas preview back until that canvas renders', () => {
    const rendered = [{ id: 1 }, { id: 2 }];
    expect(previewReady('canvas', undefined)).toBe(true);
    expect(previewReady('output:3', undefined)).toBe(true);
    expect(previewReady('layer:2', [])).toBe(true);
    expect(previewReady('canvas:2', rendered)).toBe(true);
    expect(previewReady('canvas:3', rendered)).toBe(false);
    expect(previewReady('canvas:3', undefined)).toBe(false);
    expect(previewReady('canvas:1', undefined)).toBe(true);  // the default canvas always renders
    expect(previewReady('canvas:x', [])).toBe(true);  // not a canvas id: asked for, and refused by the engine
  });
  it('finds the canvas of a layer and the layers of a canvas', () => {
    const assigned = { '5': 2, '6': 2, '7': 2, '8': 2 };
    expect(layerCanvas(assigned, 5)).toBe(2);
    expect(layerCanvas(assigned, 1)).toBe(1);
    expect(layerCanvas(undefined, 3)).toBe(1);
    expect(layersOn(assigned, 8, 1)).toEqual([1, 2, 3, 4]);
    expect(layersOn(assigned, 6, 2)).toEqual([5, 6]);
    expect(layersOn(assigned, 8, 3)).toEqual([]);
  });
  it('writes layer numbers as runs', () => {
    expect(layerRuns([1, 2, 3, 4, 7, 9, 10])).toBe('1–4, 7, 9–10');
    expect(layerRuns([])).toBe('');
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
