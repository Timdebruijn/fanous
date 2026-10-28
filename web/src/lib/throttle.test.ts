// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { throttledSender } from './throttle';

describe('throttledSender (B80)', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('sends the last value per parameter once, 50 ms later', () => {
    const out = vi.fn();
    const { send } = throttledSender(out);
    send('Layer 1', 'intensity', 10);
    send('Layer 1', 'intensity', 20.4);
    expect(out).not.toHaveBeenCalled();
    vi.advanceTimersByTime(50);
    expect(out.mock.calls).toEqual([['Layer 1', 'intensity', 20]]);
  });

  it('a pending value goes to the fixture it was queued for, not the one selected when the timer fires', () => {
    const out = vi.fn();
    const { send } = throttledSender(out);
    send('Layer 1', 'sync', 1);
    send('Layer 2', 'sync', 2); // another layer picked within 50 ms
    vi.advanceTimersByTime(50);
    expect(out.mock.calls).toEqual([['Layer 1', 'sync', 1], ['Layer 2', 'sync', 2]]);
  });

  it('a fixture change flushes what is pending at once, and the timer then sends nothing twice', () => {
    const out = vi.fn();
    const { send, flush } = throttledSender(out);
    send('Layer 1', 'intensity', 100);
    flush();
    expect(out.mock.calls).toEqual([['Layer 1', 'intensity', 100]]);
    vi.advanceTimersByTime(50);
    expect(out).toHaveBeenCalledTimes(1);
    send('Layer 2', 'intensity', 5); // a new timer after the flush
    vi.advanceTimersByTime(50);
    expect(out.mock.calls.at(-1)).toEqual(['Layer 2', 'intensity', 5]);
  });
});
