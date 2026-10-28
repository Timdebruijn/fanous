// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers for multi-server sync (B60, DESIGN §23.4): the layer badge and its words, the System screen's Sync section.
import type { LayerSyncDoc, SyncLiveDoc, SyncMasterDoc } from './docs';

export type SyncTone = 'green' | 'yellow' | 'red' | 'grey';

/** A machine id as the UI shows it: the first 8 characters of the install UUID. */
export function shortId(machine: string): string {
  return machine.slice(0, 8);
}

/** "Layer 1 on A": the master's name when the engine knows it (its own machine), otherwise its short id. */
export function masterText(master: SyncMasterDoc): string {
  return `Layer ${master.layer} on ${master.name ?? shortId(master.machine)}`;
}

/** One decimal, a real minus sign: "−0.2 ms", "0.0 ms". */
export function offsetText(ms: number): string {
  const tenths = Math.round((Number.isFinite(ms) ? ms : 0) * 10);
  return `${tenths < 0 ? '−' : ''}${(Math.abs(tenths) / 10).toFixed(1)} ms`;
}

/**
 * The badge of layer `n` (`M3` / `S3`), its colour and the state in words (title and layer detail); null with Sync off.
 * A master is green while it is its group's clock, red when another master in the group wins or a second machine
 * masters it too, grey while it sends nothing (no movie playing). A slave: locked green, freewheel yellow, lost or
 * conflict red, no master or no movie grey.
 */
export function syncStatus(n: number, sync: LayerSyncDoc | undefined, live: SyncLiveDoc | null | undefined): { label: string; tone: SyncTone; text: string } | null {
  if (!sync || sync.role === 'off' || !sync.group) return null;
  const g = sync.group;
  if (sync.role === 'master') {
    const label = `M${g}`;
    const clock = live?.masters[String(g)];
    if (!clock) return { label, tone: 'grey', text: `master of group ${g}, not sending (no movie playing)` };
    if (clock.machine !== live?.machine || clock.layer !== n) return { label, tone: 'red', text: `two masters in group ${g}; ${masterText(clock)} wins` };
    if (live.conflicts.includes(g)) return { label, tone: 'red', text: `two masters in group ${g}; this one wins` };
    return { label, tone: 'green', text: `master of group ${g}, sending` };
  }
  const label = `S${g}`;
  const who = sync.master ? masterText(sync.master) : `the master of group ${g}`;
  const offset = offsetText(sync.offsetMs ?? 0);
  switch (sync.state) {
    case 'locked':
      return { label, tone: 'green', text: `locked to ${who}, ${offset}` };
    case 'freewheel':
      return { label, tone: 'yellow', text: `freewheel: packets from ${who} late, running on its last rate` };
    case 'lost':
      return { label, tone: 'red', text: 'lost: no packets for 2 s' };
    case 'conflict':
      return { label, tone: 'red', text: `two masters in group ${g}; following ${who}, ${offset}` };
    case 'noMaster':
      return { label, tone: 'grey', text: `no master in group ${g}` };
    default:
      return { label, tone: 'grey', text: `slave of group ${g}, no movie playing` };
  }
}

/** The groups this machine is the clock of, with the layer: "Group 1 · Layer 3". */
export function mastersHere(live: SyncLiveDoc): { group: number; layer: number }[] {
  return Object.entries(live.masters)
    .filter(([, m]) => m.machine === live.machine)
    .map(([group, m]) => ({ group: Number(group), layer: m.layer }))
    .sort((a, b) => a.group - b.group);
}

/** Sync interface choices: any, each interface name once, and the current setting (an address, a gone interface) when it is none of them. */
export function interfaceChoices(interfaces: { name: string; address: string }[] | undefined, current: string): string[] {
  const names = ['any', ...new Set((interfaces ?? []).map((i) => i.name))];
  return names.includes(current) ? names : [...names, current];
}
