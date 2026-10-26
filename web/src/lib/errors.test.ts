// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { MESSAGE_LIMIT, errorHint, makeMessage, pushMessage, type UIMessage } from './errors';

describe('errors', () => {
  it('maps known codes to a next step', () => {
    expect(errorHint('showLocked')).toContain('press L');
    expect(errorHint('forbidden')).toContain('programmer');
    expect(errorHint('notReady')).toContain('System');
    expect(errorHint('whatever')).toBe('');
  });
  it('keeps the newest 20, newest first', () => {
    let list: UIMessage[] = [];
    for (let i = 0; i < 25; i++) list = pushMessage(list, makeMessage(i, i, { code: 'failed', message: `m${i}` }));
    expect(list).toHaveLength(MESSAGE_LIMIT);
    expect(list[0]!.message).toBe('m24');
    expect(list.at(-1)!.message).toBe('m5');
  });
});
