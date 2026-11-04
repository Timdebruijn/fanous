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
});
