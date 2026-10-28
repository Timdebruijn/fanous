// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { SyncLiveDoc } from './docs';
import { interfaceChoices, mastersHere, offsetText, syncStatus } from './sync';

const A = '0A1B2C3D-0000-4000-8000-000000000001';
const B = '9F8E7D6C-0000-4000-8000-000000000002';
const live = (over: Partial<SyncLiveDoc> = {}): SyncLiveDoc => ({
  machine: A, interface: 'any', port: 8002, target: 'broadcast', packetsIn: 0, packetsOut: 0, decodeErrors: 0, masters: {}, conflicts: [], ...over,
});

describe('syncStatus', () => {
  it('shows nothing with Sync off or absent', () => {
    expect(syncStatus(1, undefined, live())).toBeNull();
    expect(syncStatus(1, { role: 'off' }, live())).toBeNull();
  });

  it('a master: green while it is the clock, grey while it sends nothing, red with a second master', () => {
    const m = { role: 'master' as const, group: 3 };
    expect(syncStatus(1, m, live({ masters: { '3': { machine: A, layer: 1, name: 'A' } } }))).toEqual({ label: 'M3', tone: 'green', text: 'master of group 3, sending' });
    expect(syncStatus(1, m, live())).toEqual({ label: 'M3', tone: 'grey', text: 'master of group 3, not sending (no movie playing)' });
    expect(syncStatus(1, m, null)?.tone).toBe('grey');
    expect(syncStatus(1, m, live({ masters: { '3': { machine: A, layer: 1 } }, conflicts: [3] }))).toEqual({ label: 'M3', tone: 'red', text: 'two masters in group 3; this one wins' });
    expect(syncStatus(1, m, live({ masters: { '3': { machine: B, layer: 2 } }, conflicts: [3] }))).toEqual({ label: 'M3', tone: 'red', text: 'two masters in group 3; Layer 2 on 9F8E7D6C wins' });
    expect(syncStatus(4, m, live({ masters: { '3': { machine: A, layer: 1, name: 'A' } } }))?.text).toBe('two masters in group 3; Layer 1 on A wins');
  });

  it('a slave in every state', () => {
    const s = (state: 'locked' | 'freewheel' | 'lost' | 'noMaster' | 'conflict' | null, master: { machine: string; layer: number; name?: string } | null = { machine: B, layer: 1 }) =>
      syncStatus(2, { role: 'slave', group: 1, state, offsetMs: -0.24, master }, live());
    expect(s('locked')).toEqual({ label: 'S1', tone: 'green', text: 'locked to Layer 1 on 9F8E7D6C, −0.2 ms' });
    expect(s('locked', { machine: A, layer: 1, name: 'A' })?.text).toBe('locked to Layer 1 on A, −0.2 ms');
    expect(s('freewheel')).toEqual({ label: 'S1', tone: 'yellow', text: 'freewheel: packets from Layer 1 on 9F8E7D6C late, running on its last rate' });
    expect(s('lost')).toEqual({ label: 'S1', tone: 'red', text: 'lost: no packets for 2 s' });
    expect(s('conflict')).toEqual({ label: 'S1', tone: 'red', text: 'two masters in group 1; following Layer 1 on 9F8E7D6C, −0.2 ms' });
    expect(s('noMaster', null)).toEqual({ label: 'S1', tone: 'grey', text: 'no master in group 1' });
    expect(s(null, null)).toEqual({ label: 'S1', tone: 'grey', text: 'slave of group 1, no movie playing' });
  });

  it('formats the offset with one decimal and a real minus', () => {
    expect(offsetText(-0.24)).toBe('−0.2 ms');
    expect(offsetText(-0.04)).toBe('0.0 ms');
    expect(offsetText(1.25)).toBe('1.3 ms');
    expect(offsetText(Number.NaN)).toBe('0.0 ms');
  });
});

describe('System › Sync', () => {
  it('lists the groups this machine masters, in group order', () => {
    expect(mastersHere(live({ masters: { '5': { machine: A, layer: 2 }, '1': { machine: A, layer: 3 }, '2': { machine: B, layer: 1 } } }))).toEqual([
      { group: 1, layer: 3 },
      { group: 5, layer: 2 },
    ]);
  });

  it('offers any, each interface once, and keeps a setting that is not among them', () => {
    const ifs = [{ name: 'lo0', address: '127.0.0.1' }, { name: 'en0', address: '10.0.0.2' }, { name: 'en0', address: '10.0.1.2' }];
    expect(interfaceChoices(ifs, 'any')).toEqual(['any', 'lo0', 'en0']);
    expect(interfaceChoices(ifs, 'en7')).toEqual(['any', 'lo0', 'en0', 'en7']);
    expect(interfaceChoices(undefined, 'any')).toEqual(['any']);
  });
});
