// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it, vi } from 'vitest';
import { canvasSizeError, canvasTarget, colorOf, compareLease, freePresetNumber, previewReady, layerCanvas, layerRuns, layersOn, overlayBadges, overlayLease, overlaySelection, presetBadges, presetNote, recalledText, sharedPresets, sourceFromPixels, sourcePixels, spreadSources, blendCurvePath, KAPPA, UNIT_QUAD, circleMask, ellipsePath, finishMask, freehandPath, handles, insertNearest, keystoneBadges, maskHandle, maskOutline, maskRemoval, maskTarget, meshIdentity, modeText, movedHandle, outlines, outputSize, rectanglePath, simplify, smoothPoint, statusText, toggleSmooth, toolPath, triangleDest, type MapPoint, type MaskPoint, type MaskShape, type OutputConfig } from './outputs';

const output: OutputConfig = {
  id: 1,
  name: 'Output 1',
  display: { uuid: 'U', name: 'Epson' },
  region: null,
  mode: null,
  intensity: 1,
  blend: { left: { overlap: 0, power: 2, gamma: 2.2 }, right: { overlap: 0, power: 2, gamma: 2.2 }, top: { overlap: 0, power: 2, gamma: 2.2 }, bottom: { overlap: 0, power: 2, gamma: 2.2 }, lift: 0, liftFeather: 0 },
  warp: { cornerPin: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], mesh: meshIdentity(3, 3) },
  slices: [{ id: 1, canvas: 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], masks: [{ mode: 'add', feather: 4, path: [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.5, y: 0.9 }] }], opacity: 1 }],
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

  it('shows every path mask of a slice: its points with the pointer each edits, its outline with curves sampled', () => {
    const k = (4 / 3) * (Math.SQRT2 - 1) * 0.25;
    const circle = [
      { x: 0.75, y: 0.5, in: { x: 0, y: -k }, out: { x: 0, y: k } }, { x: 0.5, y: 0.75, in: { x: k, y: 0 }, out: { x: -k, y: 0 } },
      { x: 0.25, y: 0.5, in: { x: 0, y: k }, out: { x: 0, y: -k } }, { x: 0.5, y: 0.25, in: { x: -k, y: 0 }, out: { x: k, y: 0 } },
    ];
    const slice = { ...output.slices[0]!, masks: [...output.slices[0]!.masks!, { mode: 'subtract' as const, feather: 0, image: { folder: 1, file: 2 } }, { mode: 'subtract' as const, feather: 0, path: circle }] };
    const several = { ...output, slices: [slice] };
    const points = handles(several, 'mask', 0);
    // each curved point is followed by its Bézier handles, where they lie
    const circlePaths = [0, 1, 2, 3].flatMap((i) => ['', '/in', '/out'].map((side) => `/slices/0/masks/2/path/${i}${side}`));
    expect(points.map((h) => h.path)).toEqual([0, 1, 2].map((i) => `/slices/0/masks/0/path/${i}`).concat(circlePaths));
    expect(points[3]!.point, 'the stored point, handles included').toEqual(circle[0]);
    expect(points[5]!.point, 'the out handle where it lies').toEqual({ x: 0.75, y: 0.5 + k });
    expect(maskHandle(points[6]!.path)).toEqual({ slice: 0, mask: 2, point: 1 });
    expect(maskHandle(points[7]!.path)).toEqual({ slice: 0, mask: 2, point: 1, side: 'in' });
    expect(maskHandle('/slices/0/dest/1')).toBeNull();
    const lines = outlines(several, 'mask', 0);
    expect(lines.map((l) => l.points.length), "the triangle's corners, the circle's four curves in 8 steps, nothing for the image").toEqual([3, 32]);
    expect(lines.map((l) => l.subtract), 'a subtract mask (Invert) is drawn apart').toEqual([false, true]);
    lines[1]!.points.forEach((p) => expect(Math.hypot(p.x - 0.5, p.y - 0.5)).toBeCloseTo(0.25, 3));
    expect(lines[1]!.points[0]).toEqual({ x: 0.75, y: 0.5 });
  });

  it("the mask tools act on the selected point's mask, else the first path mask, never an image mask", () => {
    const path = output.slices[0]!.masks![0]!;
    const slice = { ...output.slices[0]!, masks: [{ mode: 'add' as const, feather: 0, image: { folder: 1, file: 1 } }, path, { ...path, feather: 9 }] };
    // a point of mask 3 (index 2) selected: Feather writes /slices/0/masks/2/feather, no other mask
    expect(maskTarget(slice, 0, handles({ ...output, slices: [slice] }, 'mask', 0)[3]!.path)).toBe(2);
    expect(maskTarget(slice, 0, null), 'nothing selected: the first path mask, not the image').toBe(1);
    expect(maskTarget(slice, 0, '/slices/1/masks/2/path/0'), "another slice's point").toBe(1);
    expect(maskTarget({ ...slice, masks: [slice.masks[0]!] }, 0, null), 'only an image mask: none, the tools add one').toBe(-1);
    expect(maskTarget(undefined, 0, null)).toBe(-1);
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
    // a morph over Output ch 7: from and to as drawn, 0 = the edited mapping (also for a missing number)
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', morph: { from: 1, to: 3, fade: 2 } })).toEqual([{ text: 'Preset 1 → 3', warn: false }]);
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', morph: { from: 0, to: 3, fade: 2 } }).map((b) => b.text)).toEqual(['Edited → Preset 3']);
    expect(presetBadges({ ...bound, preset: null, presetSource: null, morph: { from: 3, to: 0, fade: 2 } }).map((b) => b.text)).toEqual(['Preset 3 → edited']);
    expect(presetBadges({ ...bound, preset: null, presetSource: 'console', presetMissing: 9, morph: { from: 3, to: 0, fade: 2 } }).map((b) => b.text)).toEqual(['Preset 3 → edited', 'Preset 9 missing']);
    expect(presetBadges({ ...bound, preset: 3, presetSource: 'console', morph: null }).map((b) => b.text)).toEqual(['Preset 3 (console)']);
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

  it('edit overlay lease: sent at once, renewed every 2 s, again at once on a new selection, off after 10 minutes without an edit', () => {
    vi.useFakeTimers();
    try {
      const sent: [number, boolean, unknown][] = [];
      let idle = 0;
      const lease = overlayLease((id, on, selected) => sent.push([id, on, selected]), () => idle++);
      const a = overlaySelection('mesh', 0, 7), b = overlaySelection('slices', 1, 2);
      lease.stop();
      expect(sent, 'nothing to end').toEqual([]);
      lease.edited();  // the tab opens
      lease.start(1, a);
      lease.start(1, overlaySelection('mesh', 0, 7));  // the same again (the screen re-runs its effect): nothing new
      vi.advanceTimersByTime(4100);
      expect(sent).toEqual([[1, true, a], [1, true, a], [1, true, a]]);
      lease.start(1, b);  // sent at once, then every 2 s from there
      vi.advanceTimersByTime(1900);
      expect(sent.slice(3)).toEqual([[1, true, b]]);
      lease.start(2, null);  // another output: the first one's ends
      expect(sent.slice(4)).toEqual([[1, false, null], [2, true, null]]);
      sent.length = 0;
      // the 10 minutes run from opening, and an edit starts them again
      vi.advanceTimersByTime(500_000);
      lease.edited();
      vi.advanceTimersByTime(500_000);
      expect(idle).toBe(0);
      expect(sent.every(([id, on]) => id === 2 && on)).toBe(true);
      vi.advanceTimersByTime(100_000);
      expect(idle).toBe(1);
      expect(sent.at(-1)).toEqual([2, false, null]);
      const count = sent.length;
      vi.advanceTimersByTime(10_000);
      lease.stop();
      expect(sent.length, 'stopped: nothing more, not even an ending').toBe(count);
      lease.start(2, null);  // the screen's effect runs again (another selection, the page shown): still idle
      expect([sent.length, idle]).toEqual([count, 2]);
      lease.edited();  // the switch on again
      lease.start(2, null);
      lease.stop();
      expect(sent.slice(count)).toEqual([[2, true, null], [2, false, null]]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('edit overlay lease: off while the page is hidden or the show locked, back afterwards within 10 minutes of the last edit', () => {
    vi.useFakeTimers();
    try {
      const sent: [number, boolean][] = [];
      let idle = 0;
      const lease = overlayLease((id, on) => sent.push([id, on]), () => idle++);
      lease.edited();
      lease.start(1, null);
      vi.advanceTimersByTime(60_000);
      lease.stop();  // the page hidden, the show locked
      expect(sent.at(-1)).toEqual([1, false]);
      vi.advanceTimersByTime(300_000);
      lease.start(1, null);  // shown again 6 minutes after the edit: on
      expect(sent.at(-1)).toEqual([1, true]);
      lease.stop();
      vi.advanceTimersByTime(300_000);
      const count = sent.length;
      lease.start(1, null);  // 11 minutes: idle, nothing sent
      expect([sent.length, idle]).toEqual([count, 1]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('edit overlay selection and badges', () => {
    const status = { id: 1, state: 'bound' as const, display: 'Epson', width: 1920, height: 1200, hz: 60, master: true };
    expect(overlaySelection('cornerPin', 2, 3)).toEqual({ slice: 0, kind: 'corner', point: 3 });
    expect(overlaySelection('mesh', 4, 7)).toEqual({ slice: 0, kind: 'mesh', point: 7 });
    expect(overlaySelection('mask', 2, 5, '/slices/2/masks/1/path/3')).toEqual({ slice: 2, kind: 'mask', mask: 1, point: 3 });
    expect(overlaySelection('mask', 2, 6, '/slices/2/masks/1/path/3/out'), 'a Bézier handle: the overlay marks its point').toEqual({ slice: 2, kind: 'mask', mask: 1, point: 3 });
    expect(overlaySelection('mask', 2, 5, '/slices/2/dest/1')).toBeNull();
    expect([overlaySelection('mesh', 0, 7)?.kind, overlaySelection('slices', 1, 2)?.kind]).toEqual(['mesh', 'slice']);
    expect(overlaySelection('slices', 0, -1), 'nothing selected').toBeNull();
    expect(overlayBadges({ ...status, overlay: 'shown' })).toEqual([]);
    expect(overlayBadges({ ...status, overlay: 'preset' })).toEqual([{ text: 'Overlay hidden: a preset shows', warn: true }]);
    expect(overlayBadges({ ...status, overlay: 'raw' })).toEqual([{ text: 'Overlay hidden: Raw', warn: true }]);
    expect(overlayBadges(undefined)).toEqual([]);
  });

  it('blend curve', () => {
    const path = blendCurvePath({ overlap: 100, power: 2, gamma: 1 }, 100, 50, 4);
    expect(path).toBe('M0.0 50.0 L25.0 43.8 L50.0 25.0 L75.0 6.3 L100.0 0.0');
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

/** A mask path's segment from `p` to `q` at `t`, by the Bernstein form (not the de Casteljau of outputs.ts). */
function bezier(p: MaskPoint, q: MaskPoint, t: number): MapPoint {
  const c1 = { x: p.x + (p.out?.x ?? 0), y: p.y + (p.out?.y ?? 0) }, c2 = { x: q.x + (q.in?.x ?? 0), y: q.y + (q.in?.y ?? 0) };
  const s = 1 - t, [a, b, c, d] = [s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t];
  return { x: a * p.x + b * c1.x + c * c2.x + d * q.x, y: a * p.y + b * c1.y + c * c2.y + d * q.y };
}

/** How far `p` is from the segment p0–p1 of a mask path, sampled at 20,000 steps (under 1e-4 apart here). */
function offCurve(p0: MaskPoint, p1: MaskPoint, p: MapPoint): number {
  return Math.min(...Array.from({ length: 20001 }, (_, k) => bezier(p0, p1, k / 20000)).map((q) => Math.hypot(q.x - p.x, q.y - p.y)));
}

/** Numbers rounded to 1e-9, so float noise does not decide a `toEqual`. */
function round<T>(value: T): T {
  return JSON.parse(JSON.stringify(value, (_, v: unknown) => (typeof v === 'number' ? Math.round(v * 1e9) / 1e9 : v))) as T;
}

describe('mask tools (masks v2, M2.8)', () => {
  const size = { w: 1000, h: 500 };

  it('RDP keeps a point only when it lies farther than the tolerance from the simplified line', () => {
    const line = (bump: number) => [{ x: 0, y: 0 }, { x: 2, y: 0.5 }, { x: 5, y: bump }, { x: 8, y: -0.5 }, { x: 10, y: 0 }];
    expect(simplify(line(1.9), 2)).toEqual([{ x: 0, y: 0 }, { x: 10, y: 0 }]);
    expect(simplify(line(2.1), 2)).toEqual([{ x: 0, y: 0 }, { x: 5, y: 2.1 }, { x: 10, y: 0 }]);
    expect(simplify([{ x: 0, y: 0 }, { x: 1, y: 5 }], 2), 'two points stay two').toHaveLength(2);
  });

  it('freehand: RDP at 2 output px, the end back at the start dropped, a sharp turn kept as a corner', () => {
    // a box traced in 50 px steps on the 1000 × 500 output, a bump up in the middle of the top edge, back to the start
    const trace = (bump: number) => {
      const px: MapPoint[] = [];
      for (let x = 200; x < 800; x += 50) px.push({ x, y: x === 500 ? 100 - bump : 100 });
      for (let y = 100; y < 400; y += 50) px.push({ x: 800, y });
      for (let x = 800; x > 200; x -= 50) px.push({ x, y: 400 });
      for (let y = 400; y >= 100; y -= 50) px.push({ x: 200, y });
      return px.map((p) => ({ x: p.x / size.w, y: p.y / size.h }));
    };
    const inPixels = (path: MaskPoint[] | null) => round(path!.map((p) => [p.x * size.w, p.y * size.h]));
    expect(inPixels(freehandPath(trace(1.9), size))).toEqual([[200, 100], [800, 100], [800, 400], [200, 400]]);
    const path = freehandPath(trace(2.1), size)!;
    expect(inPixels(path)).toEqual([[200, 100], [500, 97.9], [800, 100], [800, 400], [200, 400]]);
    expect(path.map((p) => !!(p.in && p.out)), 'the four 90° corners stay corners, the bump is smooth').toEqual([false, true, false, false, false]);
    expect(freehandPath(trace(0).slice(0, 2), size), 'a stroke of under 3 points: no mask').toBeNull();
  });

  it('freehand: a smooth stroke is the Catmull-Rom spline through its points; traced corners keep straight edges', () => {
    const hd = { w: 1920, h: 1080 };
    // a stroke through these corners (output px), a point every 4 px
    const stroke = (corners: number[][]) => corners.slice(1).flatMap((b, i) => {
      const a = corners[i]!, n = Math.max(1, Math.round(Math.hypot(b[0]! - a[0]!, b[1]! - a[1]!) / 4));
      return Array.from({ length: n + 1 }, (_, k) => ({ x: (a[0]! + ((b[0]! - a[0]!) * k) / n) / hd.w, y: (a[1]! + ((b[1]! - a[1]!) * k) / n) / hd.h }));
    });
    // the farthest the mask's outline gets from the stroke, in output px
    const px = (p: MapPoint) => ({ x: p.x * hd.w, y: p.y * hd.h });
    const toSegment = (a: MapPoint, b: MapPoint, p: MapPoint) => {
      const [dx, dy] = [b.x - a.x, b.y - a.y];
      const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy || 1)));
      return Math.hypot(a.x + t * dx - p.x, a.y + t * dy - p.y);
    };
    const apart = (path: MaskPoint[], line: MapPoint[]) => {
      const [o, l] = [maskOutline(path, 32).map(px), line.map(px)];
      return Math.max(...o.map((q) => Math.min(...l.slice(1).map((b, i) => toSegment(l[i]!, b, q)))));
    };
    const shapes = {
      rectangle: [[400, 200], [1400, 200], [1400, 700], [400, 700], [400, 200]],
      house: [[600, 700], [600, 400], [960, 200], [1320, 400], [1320, 700], [600, 700]],
      window: [[800, 400], [1100, 400], [1100, 600], [800, 600], [800, 400]],
    };
    for (const [name, corners] of Object.entries(shapes)) {
      const path = freehandPath(stroke(corners), hd)!;
      expect(path.some((p) => p.in || p.out), `${name}: its corners are corners`).toBe(false);
      expect(apart(path, stroke(corners)), name).toBeLessThanOrEqual(2);
    }
    // a 700 × 400 blob: smooth everywhere, within 2 px of the stroke, every segment the uniform Catmull-Rom spline
    const blob = Array.from({ length: 200 }, (_, i) => [960 + 350 * Math.cos((i / 199) * 2 * Math.PI), 540 + 200 * Math.sin((i / 199) * 2 * Math.PI)]);
    const path = freehandPath(stroke(blob), hd)!;
    expect(path.every((p) => p.in && p.out)).toBe(true);
    expect(apart(path, stroke(blob))).toBeLessThanOrEqual(2);
    const cr = (a: number, b: number, c: number, d: number, t: number) =>
      0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t);
    const n = path.length;
    path.forEach((p, i) => {
      const [a, q, d] = [path[(i + n - 1) % n]!, path[(i + 1) % n]!, path[(i + 2) % n]!];
      for (const t of [0.25, 0.5, 0.8]) {
        const b = bezier(p, q, t);
        expect(b.x).toBeCloseTo(cr(a.x, p.x, q.x, d.x, t), 12);
        expect(b.y).toBeCloseTo(cr(a.y, p.y, q.y, d.y, t), 12);
      }
    });
  });

  it('rectangle: the box from either corner, clockwise from the top left; a tap makes none', () => {
    const box = [{ x: 0.2, y: 0.1 }, { x: 0.7, y: 0.1 }, { x: 0.7, y: 0.6 }, { x: 0.2, y: 0.6 }];
    expect(rectanglePath({ x: 0.7, y: 0.6 }, { x: 0.2, y: 0.1 })).toEqual(box);
    expect(toolPath('rectangle', [{ x: 0.7, y: 0.6 }, { x: 0.4, y: 0.4 }, { x: 0.2, y: 0.1 }], size), 'from where the drag started to where it ended').toEqual(box);
    expect(toolPath('rectangle', [{ x: 0.5, y: 0.5 }, { x: 0.5015, y: 0.6 }], size), 'under 2 px wide').toBeNull();
    expect(toolPath('ellipse', [{ x: 0.5, y: 0.5 }], size), 'a tap').toBeNull();
  });

  it('ellipse: 4 points on the sides of the box, handles κ × the radius along them, the outline on the ellipse', () => {
    const e = ellipsePath({ x: 0.6, y: 0.5 }, { x: 0.2, y: 0.1 });
    expect(round(e.map((p) => [p.x, p.y]))).toEqual([[0.4, 0.1], [0.6, 0.3], [0.4, 0.5], [0.2, 0.3]]);
    const k = KAPPA * 0.2;
    expect(round(e.map((p) => [p.in, p.out]))).toEqual(round([
      [{ x: -k, y: 0 }, { x: k, y: 0 }], [{ x: 0, y: -k }, { x: 0, y: k }], [{ x: k, y: 0 }, { x: -k, y: 0 }], [{ x: 0, y: k }, { x: 0, y: -k }],
    ]));
    // κ's circle is within 0.03 % of its radius
    maskOutline(e, 16).forEach((p) => expect(Math.hypot((p.x - 0.4) / 0.2, (p.y - 0.3) / 0.2)).toBeCloseTo(1, 3));
  });

  it('Add points on a curve splits it (de Casteljau): the new point lies on it, smooth, and the shape stays', () => {
    const e = ellipsePath({ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 });
    const { path, index } = insertNearest(e, { x: 0.5, y: 0.2 }); // just outside the top-right quarter, near its start
    expect(index).toBe(1);
    expect(path).toHaveLength(5);
    expect(path[1]!.in && path[1]!.out, 'smooth').toBeTruthy();
    expect(path.slice(3), 'the other quarters as they were').toEqual(e.slice(2));
    for (const [a, b] of [[0, 1], [1, 2]] as const) for (let k = 0; k <= 20; k++) expect(offCurve(e[0]!, e[1]!, bezier(path[a]!, path[b]!, k / 20))).toBeLessThan(1e-4);
    // where the curve comes nearest to the tap: on the radius through it (κ's quarter is within 6e-5 of the circle;
    // the nearest of the 63 samples alone is up to 0.0025 off, the chord's nearest point 0.015)
    const towards = Math.hypot(0.1, -0.2);
    expect(Math.hypot(path[1]!.x - 0.4 - (0.2 * 0.1) / towards, path[1]!.y - 0.4 + (0.2 * 0.2) / towards)).toBeLessThan(2e-4);
    // a curve with a handle at one end only: the other end stays a corner, and the curve stays too
    const half = [{ x: 0, y: 0 }, { x: 1, y: 0, in: { x: 0, y: -0.5 } }, { x: 0.5, y: 1 }];
    const split = insertNearest(half, { x: 0.6, y: -0.2 }).path;
    expect(split[0]).toEqual({ x: 0, y: 0 });
    for (const [a, b] of [[0, 1], [1, 2]] as const) for (let k = 0; k <= 20; k++) expect(offCurve(half[0]!, half[1]!, bezier(split[a]!, split[b]!, k / 20))).toBeLessThan(1e-4);
  });

  it("a double-tap toggles corner ↔ smooth: handles a sixth of the neighbours' chord, or none", () => {
    const box = rectanglePath({ x: 0, y: 0 }, { x: 0.6, y: 0.3 });
    const smooth = toggleSmooth(box, 1);
    expect(round(smooth)).toEqual({ x: 0.6, y: 0, in: { x: -0.1, y: -0.05 }, out: { x: 0.1, y: 0.05 } });
    expect(smoothPoint(box, 1)).toEqual(smooth);
    expect(toggleSmooth([box[0]!, smooth, ...box.slice(2)], 1)).toEqual({ x: 0.6, y: 0 });
    expect(toggleSmooth([box[0]!, { ...box[1]!, out: { x: 0, y: 0.1 } }, ...box.slice(2)], 1), 'one handle is smooth too').toEqual({ x: 0.6, y: 0 });
  });

  it('Backspace on a Bézier handle removes the handle, on a point the point (a mask keeps 3)', () => {
    const e = ellipsePath({ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 });
    const o = { ...output, slices: [{ ...output.slices[0]!, masks: [{ mode: 'add' as const, feather: 0, path: e }] }] };
    const { in: _, ...cornerIn } = e[1]!;
    expect(maskRemoval(o, '/slices/0/masks/0/path/1/in')).toEqual({ path: '/slices/0/masks/0/path/1', value: cornerIn });
    expect(maskRemoval(o, '/slices/0/masks/0/path/1')).toEqual({ path: '/slices/0/masks/0/path', value: [e[0], e[2], e[3]] });
    const three = { ...o, slices: [{ ...o.slices[0]!, masks: [{ mode: 'add' as const, feather: 0, path: e.slice(0, 3) }] }] };
    expect(maskRemoval(three, '/slices/0/masks/0/path/1'), 'three points stay').toBeNull();
    expect(maskRemoval(three, '/slices/0/masks/0/path/1/out'), 'a handle still goes').not.toBeNull();
    expect(maskRemoval(o, '/slices/0/dest/1')).toBeNull();
  });

  it('a dragged Bézier handle is stored as the offset from its point; a dragged point keeps its handles', () => {
    const e = ellipsePath({ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 });
    const o = { ...output, slices: [{ ...output.slices[0]!, masks: [{ mode: 'add' as const, feather: 0, path: e }] }] };
    const handle = movedHandle(o, '/slices/0/masks/0/path/1/out', { x: 0.7, y: 0.5 });
    expect(handle.path).toBe('/slices/0/masks/0/path/1');
    expect(round(handle.value)).toEqual(round({ ...e[1]!, out: { x: 0.1, y: 0.1 } }));
    expect(movedHandle(o, '/slices/0/masks/0/path/1', { x: 0.65, y: 0.4 })).toEqual({ path: '/slices/0/masks/0/path/1', value: { ...e[1]!, x: 0.65, y: 0.4 } });
    expect(movedHandle(o, '/warp/cornerPin/2', { x: 0.9, y: 1 })).toEqual({ path: '/warp/cornerPin/2', value: { x: 0.9, y: 1 } });
  });

  it("slice shapes: Triangle meets the top corners mid-edge; Circle adds an ellipse filling the corners' bounding box", () => {
    const skewed = [{ x: 0.1, y: 0.2 }, { x: 0.7, y: 0.1 }, { x: 0.9, y: 0.8 }, { x: 0.2, y: 0.9 }];
    expect(round(triangleDest(skewed))).toEqual([{ x: 0.4, y: 0.15 }, { x: 0.4, y: 0.15 }, { x: 0.9, y: 0.8 }, { x: 0.2, y: 0.9 }]);
    expect(triangleDest(UNIT_QUAD)).toEqual([{ x: 0.5, y: 0 }, { x: 0.5, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }]);
    const circle = round(circleMask(skewed));
    expect(circle).toMatchObject({ mode: 'add', feather: 0 });
    expect(circle.path!.map((p) => [p.x, p.y]), 'touching each side of the box 0.1…0.9').toEqual([[0.5, 0.1], [0.9, 0.5], [0.5, 0.9], [0.1, 0.5]]);
    expect(circle.path![0]!.out).toEqual({ x: round(KAPPA * 0.4), y: 0 });
  });

  it('Redraw replaces its mask wherever it is now; a mask changed or gone meanwhile is left, the path added', () => {
    const a: MaskShape = { mode: 'add', feather: 0, path: rectanglePath({ x: 0.1, y: 0.1 }, { x: 0.5, y: 0.5 }) };
    const b: MaskShape = { mode: 'subtract', feather: 4, path: rectanglePath({ x: 0.3, y: 0.3 }, { x: 0.4, y: 0.4 }) };
    const image: MaskShape = { mode: 'add', feather: 0, image: { folder: 1, file: 2 } };
    const path = ellipsePath({ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 });
    const added = { mode: 'add', feather: 0, path };
    expect(finishMask([a, b], path, null), 'a tool appends an add mask').toEqual([a, b, added]);
    expect(finishMask([a, b], path, b), 'mode and feather stay').toEqual([a, { ...b, path }]);
    // another client changed the list while mask 2 was redrawn
    expect(finishMask([b], path, b), 'mask 1 removed: b is at 0 now').toEqual([{ ...b, path }]);
    expect(finishMask([image, a, b], path, b), 'one added in front: a, now at 1, stays').toEqual([image, a, { ...b, path }]);
    const moved = { ...b, path: b.path!.map((p, i) => (i === 0 ? { ...p, x: 0.31 } : p)) };
    expect(finishMask([a, moved], path, b), "b's point moved: not overwritten").toEqual([a, moved, added]);
    expect(finishMask([a], path, b), 'b removed').toEqual([a, added]);
  });
});
