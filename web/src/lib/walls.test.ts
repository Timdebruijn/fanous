// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { DisplayDoc, OutputConfig } from './outputs';
import {
  MAX_CANVAS_PIXELS, SEAM_STEPS, badge, editDraft, fitCanvas, freeOutputs, grids, isManual, newDraft, overlapHint, patternChange, patternRestore, pixelSize,
  rc, savedFrom, seamLines, share, tap, unrestored, wallArgs, wallPixels, type WallConfig,
} from './walls';

const edge = { overlap: 0, power: 2, gamma: 2.2 };
function output(id: number, change: Partial<OutputConfig> = {}): OutputConfig {
  return {
    id, name: `Output ${id}`, display: null, region: { x: 0, y: 0, w: 1920, h: 1080 }, mode: null, intensity: 1,
    blend: { left: edge, right: edge, top: edge, bottom: edge, lift: 0, liftFeather: 0 },
    warp: { cornerPin: [], mesh: null }, slices: [], testPattern: 0, ...change,
  };
}
function wall(cols: number, rows: number, outputs: number[], change: Partial<WallConfig> = {}): WallConfig {
  return { id: 1, name: 'Wall 1', canvas: 1, rect: { x: 0, y: 0, w: 1, h: 1 }, cols, rows, outputs, overlap: { x: 0.15, y: 0.15 }, seams: [], manual: [], ...change };
}

describe('the wizard', () => {
  it('offers only grids of 1–4 columns and rows that hold exactly the tapped projectors, one row first', () => {
    expect(grids(1)).toEqual([]);
    expect(grids(2)).toEqual([{ cols: 2, rows: 1 }, { cols: 1, rows: 2 }]);
    expect(grids(4)).toEqual([{ cols: 4, rows: 1 }, { cols: 2, rows: 2 }, { cols: 1, rows: 4 }]);
    expect(grids(5)).toEqual([]);
    expect(grids(6)).toEqual([{ cols: 3, rows: 2 }, { cols: 2, rows: 3 }]);
    expect(grids(16)).toEqual([{ cols: 4, rows: 4 }]);
    expect(grids(17)).toEqual([]);
  });

  it('keeps the tapped order; a second tap takes a tile out and the later ones move up', () => {
    expect([3, 1, 2].reduce(tap, [] as number[])).toEqual([3, 1, 2]);
    expect(tap([3, 1, 2], 1)).toEqual([3, 2]);
    // tapped order is row-major: the third of a 2 × 2 grid is row 2, column 1
    expect(rc(2, 2)).toEqual({ row: 2, col: 1 });
    expect(rc(5, 3)).toEqual({ row: 2, col: 3 });
  });

  it('offers outputs that are in no other wall', () => {
    const walls = [wall(2, 1, [1, 2]), wall(2, 1, [3, 4], { id: 2 })];
    const all = [1, 2, 3, 4, 5].map((id) => output(id));
    expect(freeOutputs(all, walls).map((o) => o.id)).toEqual([5]);
    expect(freeOutputs(all, walls, 2).map((o) => o.id)).toEqual([3, 4, 5]);
    expect(freeOutputs(all, undefined).map((o) => o.id)).toEqual([1, 2, 3, 4, 5]);
  });

  it('builds wall.add, and wall.set for Edit layout… without the overlap when it did not change', () => {
    const draft = { ...newDraft(1), order: [2, 1], grid: { cols: 2, rows: 1 } };
    expect(wallArgs(draft)).toEqual({ cols: 2, rows: 1, outputs: [2, 1], overlap: { x: 0.15, y: 0.15 }, canvas: 1, fit: 'canvas' });
    const edited = editDraft(wall(2, 1, [1, 2], { id: 3, canvas: 2, overlap: { x: 0.2, y: 0.1 } }));
    expect(edited).toMatchObject({ edit: 3, order: [1, 2], grid: { cols: 2, rows: 1 }, overlap: 20, canvas: 2 });
    expect(wallArgs({ ...edited, grid: edited.grid!, order: [2, 1] })).toEqual({ id: 3, cols: 2, rows: 1, outputs: [2, 1], canvas: 2, fit: 'canvas' });
    expect(wallArgs({ ...edited, grid: edited.grid!, overlap: 12, fit: 'makeCanvas' })).toMatchObject({ id: 3, overlap: { x: 0.12, y: 0.12 }, fit: 'makeCanvas' });
  });

  it('hints in yellow below 10 % and above 25 % overlap', () => {
    expect(overlapHint(15)).toBeNull();
    expect(overlapHint(10)).toBeNull();
    expect(overlapHint(25)).toBeNull();
    expect(overlapHint(9)).toMatch(/^Below 10 %/);
    expect(overlapHint(26)).toMatch(/^Above 25 %/);
  });
});

describe('sizes (WallModel.swift; values pinned from WallLayoutTests)', () => {
  it('shares the wall: 1 / (n − (n − 1) · overlap)', () => {
    expect(share(2, 0.2)).toBeCloseTo(1 / 1.8, 12);
    expect(share(3, 0.25)).toBe(0.4);
    expect(share(1, 0.3)).toBe(1);
    expect(share(4, 0)).toBe(0.25);
  });

  it('previews the canvas "make a canvas that fits" gives: even, within the side and pixel limits', () => {
    const size = (cols: number, rows: number, x: number, y: number, width: number, height: number, budget = MAX_CANVAS_PIXELS) =>
      fitCanvas({ cols, rows }, { x, y }, { width, height }, budget);
    expect(size(2, 1, 0.15, 0.15, 1920, 1080)).toEqual({ width: 3552, height: 1080 });
    expect(size(2, 2, 0.2, 0.1, 1920, 1080)).toEqual({ width: 3456, height: 2052 });
    expect(size(2, 1, 0.123, 0, 1920, 1080)).toEqual({ width: 3604, height: 1080 });
    expect(size(4, 1, 0.15, 0, 3840, 2160)).toEqual({ width: 8192, height: 1298 });
    expect(size(2, 1, 0, 0, 200, 100)).toEqual({ width: 400, height: 320 });
    expect(size(4, 4, 0.15, 0.15, 3840, 2160)).toEqual({ width: 7680, height: 4320 });
    expect(size(3, 3, 0.15, 0.15, 3840, 2160)).toEqual({ width: 7680, height: 4320 });
    expect(size(3, 3, 0.15, 0.15, 3840, 2160, MAX_CANVAS_PIXELS - 1920 * 1080)).toEqual({ width: 7436, height: 4182 });
  });

  it("takes an output's pixels from its region, else its mode, else its display", () => {
    const displays = [{ uuid: 'U', width: 1280, height: 800 } as DisplayDoc];
    expect(pixelSize(output(1), displays)).toEqual({ width: 1920, height: 1080 });
    expect(pixelSize(output(1, { region: null, mode: { width: 3840, height: 2160, hz: 60 }, display: { uuid: 'U', name: 'P' } }), displays)).toEqual({ width: 3840, height: 2160 });
    expect(pixelSize(output(1, { region: null, display: { uuid: 'U', name: 'P' } }), displays)).toEqual({ width: 1280, height: 800 });
    expect(pixelSize(output(1, { region: null, display: { uuid: 'gone', name: 'P' } }), displays)).toBeNull();
  });

  it('needs one known pixel size for all outputs of a wall', () => {
    const outputs = [output(1), output(2), output(3, { region: null }), output(4, { region: { x: 0, y: 0, w: 1920, h: 1200 } })];
    expect(wallPixels([1, 2], outputs, [])).toEqual({ width: 1920, height: 1080 });
    expect(wallPixels([1, 3], outputs, [])).toMatch(/^Output 3 has no pixel size yet/);
    expect(wallPixels([1, 4], outputs, [])).toBe('The outputs of a wall need one pixel size: Output 1 is 1920 × 1080, Output 4 is 1920 × 1200.');
  });
});

describe('the wall panel', () => {
  it('places the seams between neighbours on the mini-map: right of a, or below it', () => {
    const seams = [{ a: 1, b: 2 }, { a: 1, b: 3 }, { a: 2, b: 4 }, { a: 3, b: 4 }, { a: 2, b: 3 }].map((s) => ({ ...s, power: 2, gamma: 2.2 }));
    const lines = seamLines(wall(2, 2, [1, 2, 3, 4], { seams }));
    expect(lines.map((l) => `${l.a}-${l.b} ${l.side} r${l.row} c${l.col}`)).toEqual(['1-2 right r0 c0', '1-3 bottom r0 c0', '2-4 bottom r0 c1', '3-4 right r1 c0']);
    // 1 × 3 and 3 × 1: the seams run between columns, or between rows
    const row = [{ a: 5, b: 6 }, { a: 6, b: 7 }].map((s) => ({ ...s, power: 2, gamma: 2.2 }));
    expect(seamLines(wall(3, 1, [5, 6, 7], { seams: row })).map((l) => `${l.side} c${l.col}`)).toEqual(['right c0', 'right c1']);
    expect(seamLines(wall(1, 3, [5, 6, 7], { seams: row })).map((l) => `${l.side} r${l.row}`)).toEqual(['bottom r0', 'bottom r1']);
  });

  it('badges a wall output with its row and column, and knows its manual fields', () => {
    const w = wall(2, 2, [5, 7, 9, 11], { manual: [{ output: 7, field: 'overlap.left' }] });
    expect(badge(w, 7)).toBe('Wall 1 · r1 c2');
    expect(badge(w, 9)).toBe('Wall 1 · r2 c1');
    expect(isManual(w, 7, 'overlap.left')).toBe(true);
    expect(isManual(w, 7, 'source')).toBe(false);
    expect(isManual(undefined, 7, 'source')).toBe(false);
  });

  it('puts a test pattern on outputs and gives each its own back afterwards', () => {
    let outputs = [output(1, { testPattern: 2 }), output(2), output(3, { testPattern: 4 })];
    const shown = patternChange(outputs, [1, 2, 3, 9], 4, {});
    // every output is sent the pattern, also one that seems to show it already (the project may lag); a missing one not
    expect(shown.set).toEqual([{ id: 1, pattern: 4 }, { id: 2, pattern: 4 }, { id: 3, pattern: 4 }]);
    expect(shown.saved).toEqual({ 1: 2, 2: 0, 3: 4 });
    outputs = outputs.map((o) => ({ ...o, testPattern: 4 }));
    // the next pattern keeps the first saved one
    const next = patternChange(outputs, [1, 2], 3, shown.saved);
    expect(next.saved).toEqual({ 1: 2, 2: 0, 3: 4 });
    // the wall keeps outputs 1 and 2 on its pattern; output 3 was not tapped and gets its own back
    expect(patternRestore(outputs, next.saved, [1, 2])).toEqual({ set: [{ id: 3, pattern: 4 }], saved: { 1: 2, 2: 0 } });
    expect(patternRestore(outputs, { 1: 2, 2: 0 })).toEqual({ set: [{ id: 1, pattern: 2 }, { id: 2, pattern: 0 }], saved: {} });
    // a removed output is skipped
    expect(patternRestore(outputs.slice(1), { 1: 2 }).set).toEqual([]);
  });

  it('keeps the saved pattern of every output whose restore was refused, so it can be tried again', () => {
    const back = patternRestore([output(1, { testPattern: 3 }), output(2, { testPattern: 3 })], { 1: 2, 2: 0, 3: 7 }, [3]);
    expect(unrestored(back.saved, back.set, [])).toEqual({ 1: 2, 2: 0, 3: 7 });
    expect(unrestored(back.saved, back.set, [2])).toEqual({ 1: 2, 3: 7 });
    expect(unrestored(back.saved, back.set, [1, 2])).toEqual({ 3: 7 });
  });

  it('reads saved patterns back after a reload, and nothing else', () => {
    expect(savedFrom(JSON.stringify({ wall: 2, saved: { 1: 0, 4: 7 } }))).toEqual({ wall: 2, saved: { 1: 0, 4: 7 } });
    expect(savedFrom(JSON.stringify({ saved: { 1: 0 } }))).toEqual({ wall: null, saved: { 1: 0 } });
    for (const bad of [null, '', '{', '{"saved":{}}', '{"saved":{"x":1}}', '{"saved":{"1":"0"}}', '[]']) expect(savedFrom(bad)).toBeNull();
  });

  it('steps through Grid, Blend check, Grey 0, 25, 75 % and White', () => {
    expect(SEAM_STEPS.map((s) => [s.name, s.pattern])).toEqual([['Grid', 1], ['Blend check', 3], ['Grey 0 %', 8], ['Grey 25 %', 9], ['Grey 75 %', 10], ['White', 11]]);
    expect(SEAM_STEPS[1]!.hints.map((h) => [h.target, h.control])).toEqual([['seam', 'gamma'], ['seam', 'gamma'], ['seam', 'curve']]);
    // Grey 25 / 75 % and White: a darker or tinted projector opens that projector's colour gain
    for (const step of SEAM_STEPS.slice(3)) expect(step.hints.map((h) => [h.target, h.control])).toEqual([['projector', 'colour'], ['seam', 'rgb']]);
  });
});
