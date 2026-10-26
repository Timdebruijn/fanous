// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { lastVersionText, parseVersions, revertBlocked, versionSummary, versionTime } from './versions';

const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo, d, h, mi).getTime() / 1000;

describe('project versions', () => {
  it('parses the version list and drops malformed entries', () => {
    const list = parseVersions([
      { id: 'a', at: 10, name: 'Before doors', automatic: false, layers: 8, outputs: 2, canvases: 1, cues: 12 },
      { id: 'b', at: 5, name: 'Periodic', automatic: true, layers: 'x' },
      { id: '', at: 1 },
      { at: 1 },
      null,
    ]);
    expect(list.map((v) => v.id)).toEqual(['a', 'b']);
    expect(list[0].automatic).toBe(false);
    expect(list[1].layers).toBe(0);
    expect(parseVersions(undefined)).toEqual([]);
    expect(parseVersions({ id: 'a' })).toEqual([]);
  });

  it('summarises counts with plurals', () => {
    const [v] = parseVersions([{ id: 'a', at: 1, layers: 8, outputs: 1, canvases: 2, cues: 0 }]);
    expect(versionSummary(v)).toBe('8 layers · 1 output · 2 canvases · 0 cues');
  });

  it('shows the time today, the date on other days and the year when it differs', () => {
    const now = new Date(2026, 9, 26, 18, 0);
    expect(versionTime(at(2026, 9, 26, 14, 5), now)).toBe('14:05');
    expect(versionTime(at(2026, 9, 25, 9, 30), now)).toBe('25 Oct 09:30');
    expect(versionTime(at(2025, 11, 31, 23, 59), now)).toBe('31 Dec 2025 23:59');
    expect(lastVersionText(null, now)).toBe('none yet');
    expect(lastVersionText(0, now)).toBe('none yet');
    expect(lastVersionText(at(2026, 9, 26, 17, 50), now)).toBe('17:50');
  });

  it('blocks a revert in the same cases as the engine', () => {
    expect(revertBlocked({ programmer: true, showLock: false, showMode: false })).toBeNull();
    expect(revertBlocked({ programmer: false, showLock: false, showMode: false })).toMatch(/programmer/);
    expect(revertBlocked({ programmer: true, showLock: true, showMode: false })).toMatch(/locked/);
    expect(revertBlocked({ programmer: true, showLock: false, showMode: true })).toMatch(/show mode/);
  });
});
