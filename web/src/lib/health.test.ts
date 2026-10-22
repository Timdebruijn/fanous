// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { formatUptime, parseHealth } from './health';

describe('parseHealth', () => {
  it('accepts a valid payload', () => {
    expect(parseHealth({ status: 'ok', version: '0.0.1', uptimeSeconds: 5, chip: 'Apple M1 Pro' })).toEqual({
      status: 'ok',
      version: '0.0.1',
      uptimeSeconds: 5,
      chip: 'Apple M1 Pro',
    });
  });
  it('rejects bad payloads', () => {
    expect(() => parseHealth(null)).toThrow();
    expect(() => parseHealth({ status: 'down' })).toThrow();
    expect(() => parseHealth({ status: 'ok', version: 1 })).toThrow();
  });
});

describe('formatUptime', () => {
  it('formats minutes and hours', () => {
    expect(formatUptime(0)).toBe('0m 00s');
    expect(formatUptime(65)).toBe('1m 05s');
    expect(formatUptime(3723)).toBe('1h 02m 03s');
  });
});
