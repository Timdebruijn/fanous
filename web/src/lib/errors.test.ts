// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { errorHint } from './errors';

describe('errors', () => {
  it('maps known codes to a next step', () => {
    expect(errorHint('showLocked')).toContain('press L');
    expect(errorHint('forbidden')).toContain('programmer');
    expect(errorHint('notReady')).toContain('System');
    expect(errorHint('whatever')).toBe('');
  });
  it('keeps the readiness hint byte for byte for a real readiness refusal', () => {
    const hint = 'Show mode is blocked by failed readiness checks — open System to fix or acknowledge them.';
    expect(errorHint('notReady')).toBe(hint);
    expect(errorHint('notReady', 'readiness: outputs, spotlight')).toBe(hint);
  });
  it('does not send a library root switch to System (B239)', () => {
    const hint = errorHint('notReady', 'readiness: libraryRootChanging');
    expect(hint).toBe('Show mode was refused: the library root is being switched; send it again in a few seconds.');
    expect(hint).not.toContain('readiness');
  });
});
