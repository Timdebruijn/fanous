// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it, vi } from 'vitest';
import { classChanged, latestOnly, previewClass, wantedWidth } from './preview';

const resolveIn = (ms: number, stop: () => void) => new Promise<() => void>((r) => setTimeout(() => r(stop), ms));

describe('latestOnly', () => {
  it('stops a subscription that resolves after a newer one began', async () => {
    const latest = latestOnly();
    const [stopA, stopB] = [vi.fn(), vi.fn()];
    // layer:1 is slow; layer:2 starts before it resolves and wins
    const first = latest.begin();
    const a = resolveIn(20, stopA).then((stop) => first.keep(stop));
    const second = latest.begin();
    expect(first.current()).toBe(false);
    expect(second.keep(await resolveIn(1, stopB))).toBe(true);
    expect(await a).toBe(false);
    expect(stopA).toHaveBeenCalledOnce();
    expect(stopB).not.toHaveBeenCalled();
  });

  it('stops a pending subscription after cancel', () => {
    const latest = latestOnly();
    const pending = latest.begin();
    latest.cancel();
    const stop = vi.fn();
    expect(pending.current()).toBe(false);
    expect(pending.keep(stop)).toBe(false);
    expect(stop).toHaveBeenCalledOnce();
  });
});

describe('preview size', () => {
  it('asks for the rendered width in device pixels and maps it to the class the engine picks', () => {
    expect(wantedWidth(300, 2)).toBe(600);
    expect(wantedWidth(300.2, 1)).toBe(301);
    expect(wantedWidth(0, 2)).toBeUndefined();
    expect(wantedWidth(500, 0)).toBe(500);
    expect([100, 320, 321, 600, 640, 641, 961, 4000].map(previewClass)).toEqual([320, 320, 640, 640, 640, 960, 1280, 1280]);
  });

  it('re-subscribes only when a resize crosses into another class', () => {
    expect(classChanged(600, 630)).toBe(false);
    expect(classChanged(630, 700)).toBe(true);
    expect(classChanged(1300, 2000)).toBe(false);
    expect(classChanged(undefined, 600)).toBe(false); // no width yet: the engine's 640
    expect(classChanged(undefined, 300)).toBe(true);
  });

  it('keeps the class within 5 % past its edges', () => {
    expect(classChanged(640, 660)).toBe(false); // 3 % over 640
    expect(classChanged(640, 680)).toBe(true);
    expect(classChanged(700, 630)).toBe(false); // the 960 stream stays for a box 2 % under 640
    expect(classChanged(700, 600)).toBe(true);
  });
});
