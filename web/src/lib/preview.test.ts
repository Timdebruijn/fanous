// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it, vi } from 'vitest';
import { latestOnly } from './preview';

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
