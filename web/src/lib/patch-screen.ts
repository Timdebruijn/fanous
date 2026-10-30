// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure logic of the Patch / DMX screen: the fixtures by group with their blocks, channel ranges, collisions and status
// words (DESIGN §6.6), per-universe cell ownership, parameter lookup by fixture-relative channel, universe naming and
// option lists, the Universes panel's rows.
import type { PatchEntry, UniverseInfo, UniverseSettingsDoc } from './docs';

export const UNIVERSE_SIZE = 512;
export const LOCKED_TITLE = 'Locked: programmer only';
/** Console control covers layers 1–32 and outputs 1–8 (engine `ParameterSnapshotSlot`): the fixtures that exist. */
export const MAX_LAYERS = 32;
export const MAX_OUTPUTS = 8;

/** 11 hues at one lightness: dark backgrounds that carry light mono text. */
export const FIXTURE_COLOURS = ['#4A3A1E', '#1E4A3A', '#1F3B5E', '#3E2A5E', '#5E2A4A', '#2A5E4A', '#5E4A2A', '#2A4A5E', '#4A2A5E', '#5E2A2A', '#2A5E5E'] as const;

/** A fixture mode of the channel map: "layer", "master", "output", "keystone", or one a newer engine adds. */
export type FixtureType = string;

/** One entry of the channel map's `fixtures` (DESIGN §6.6 item 3). */
export interface FixtureMode {
  mode: FixtureType;
  /** "Layer" (fixtures "Layer 1", "Layer 2" …), or the whole name of a `machine` mode's one fixture ("Master") */
  name: string;
  /** what it is patched per: `layer`, `machine` (one per Mac) or `output` */
  per: string;
  /** a show runs fine without patching it (Keystone) */
  optional: boolean;
}

/** Used until /api/channel-map.json has arrived (or when it cannot be fetched). */
export const FALLBACK_FIXTURES: readonly FixtureMode[] = [
  { mode: 'layer', name: 'Layer', per: 'layer', optional: false },
  { mode: 'master', name: 'Master', per: 'machine', optional: false },
  { mode: 'output', name: 'Output', per: 'output', optional: false },
  { mode: 'keystone', name: 'Keystone', per: 'output', optional: true },
];
export const FALLBACK_FOOTPRINTS: Record<FixtureType, number> = { layer: 64, master: 8, output: 8, keystone: 16 };

export const STANDARD_UNIVERSES: readonly string[] = [
  'artnet:0.0.0', 'artnet:0.0.1', 'artnet:0.0.2', 'artnet:0.0.3',
  'sacn:1', 'sacn:2', 'sacn:3', 'sacn:4',
];

// ---- channel map -----------------------------------------------------------------------------------------

export interface ParamSpec {
  name: string;
  key: string;
  /** 1-based, fixture-relative; a 16-bit parameter also spans channel + 1 (fine) */
  channel: number;
  bits: 8 | 16;
  default?: number;
  group?: string;
  unit?: string;
  bands?: { from: number; to: number; name: string }[];
}

export interface ChannelMap {
  footprints: Record<FixtureType, number>;
  modes: Record<FixtureType, ParamSpec[]>;
  /** every mode, in display order */
  fixtures: FixtureMode[];
}

/** Shallow shape check: `fixtures` lists every mode of `footprints`, each with its specs. Anything else is treated as "no channel map" and the fallback modes apply. */
export function parseChannelMap(json: unknown): ChannelMap | null {
  const j = json as Partial<ChannelMap> | null;
  if (!j || typeof j !== 'object' || !j.footprints || !j.modes || !Array.isArray(j.fixtures)) return null;
  const listed = new Set<string>();
  for (const f of j.fixtures as (Partial<FixtureMode> | null)[]) {
    if (typeof f?.mode !== 'string' || typeof f.name !== 'string' || typeof f.per !== 'string' || typeof f.optional !== 'boolean') return null;
    if (typeof j.footprints[f.mode] !== 'number') return null;
    listed.add(f.mode);
  }
  for (const [mode, footprint] of Object.entries(j.footprints)) {
    if (typeof footprint !== 'number' || !Array.isArray(j.modes[mode]) || !listed.has(mode)) return null;
  }
  return j as ChannelMap;
}

let channelMapRequest: Promise<ChannelMap | null> | undefined;

/** Fetches the channel map once per page load; a failure is not cached, so the next visit retries. */
export function loadChannelMap(): Promise<ChannelMap | null> {
  channelMapRequest ??= fetch('/api/channel-map.json')
    .then((response) => (response.ok ? response.json() : null))
    .then(parseChannelMap)
    .catch(() => null)
    .then((map) => {
      if (!map) channelMapRequest = undefined;
      return map;
    });
  return channelMapRequest;
}

export function footprintOf(map: ChannelMap | null, type: FixtureType): number {
  return (map ? map.footprints[type] : FALLBACK_FOOTPRINTS[type]) ?? 0;
}

export interface ParamAt {
  spec: ParamSpec;
  /** the second (low) byte of a 16-bit parameter */
  fine: boolean;
}

/** The parameter at a fixture-relative channel (1-based), or null for a gap or an unknown map. */
export function paramAt(map: ChannelMap | null, type: FixtureType, rel: number): ParamAt | null {
  for (const spec of map?.modes[type] ?? []) {
    if (spec.channel === rel) return { spec, fine: false };
    if (spec.bits === 16 && spec.channel + 1 === rel) return { spec, fine: true };
  }
  return null;
}

// ---- universes -------------------------------------------------------------------------------------------

/** "artnet:0.0.1" -> "A 0.0.1", "sacn:3" -> "S 3"; anything else is shown as is. */
export function universeName(id: string): string {
  if (id.startsWith('artnet:')) return `A ${id.slice('artnet:'.length)}`;
  if (id.startsWith('sacn:')) return `S ${id.slice('sacn:'.length)}`;
  return id;
}

/** "S 7" -> "sacn:7", "A 0.0.1" -> "artnet:0.0.1"; the id form passes through (the engine validates). */
export function parseUniverseName(text: string): string {
  const t = text.trim();
  const m = /^([AaSs])\s*(\S+)$/.exec(t);
  if (!m || t.includes(':')) return t;
  return `${m[1]!.toLowerCase() === 'a' ? 'artnet' : 'sacn'}:${m[2]}`;
}

/** Art-Net port-address 0–32767 as "artnet:net.subnet.universe". */
function artnetId(n: number): string {
  return `artnet:${n >> 8}.${(n >> 4) & 0xf}.${n & 0xf}`;
}

function portAddress(id: string): number {
  const [net = 0, sub = 0, uni = 0] = id.slice('artnet:'.length).split('.').map(Number);
  return (net << 8) | (sub << 4) | uni;
}

/** The other protocol's universe by the engine's default mapping: sACN n ↔ Art-Net port-address n − 1 (S 1 ↔ A 0.0.0). */
export function defaultPair(id: string): string {
  if (id.startsWith('sacn:')) return artnetId(Math.min(Math.max(Number(id.slice(5)) - 1, 0), 0x7fff));
  return `sacn:${Math.min(portAddress(id) + 1, 63999)}`;
}

/** `n` universes on (Core `UniverseID.advanced(by:)`): Art-Net port-address + n (A 0.0.15 + 1 = A 0.1.0), sACN + n; null outside Art-Net 0–32767, sACN 1–63999 or for another id. */
export function advanceUniverse(id: string, n: number): string | null {
  if (id.startsWith('sacn:')) {
    const next = Number(id.slice('sacn:'.length)) + n;
    return Number.isInteger(next) && next >= 1 && next <= 63999 ? `sacn:${next}` : null;
  }
  if (!id.startsWith('artnet:')) return null;
  const next = portAddress(id) + n;
  return next >= 0 && next <= 0x7fff ? artnetId(next) : null;
}

/** A universe's receive settings (B28): its project entry, or the engine defaults when it has none. */
export function universeSettings(list: readonly UniverseSettingsDoc[] | undefined, id: string): UniverseSettingsDoc {
  return list?.find((u) => u.id === id) ?? {
    id, protocol: id.startsWith('sacn:') ? 'sacn' : 'artnet', interface: 'any', holdOnLoss: 'hold', lossTimeout: 2.5, sacnPriorityMode: 'highest', pair: defaultPair(id),
  };
}

/** Interface choices: any, every interface name and address on the Mac, and the current value (marked when absent). */
export function interfaceOptions(interfaces: readonly { name: string; address: string }[] | undefined, current: string): { value: string; label: string }[] {
  const options = [{ value: 'any', label: 'All interfaces' }];
  for (const name of [...new Set((interfaces ?? []).map((i) => i.name))]) {
    const addresses = (interfaces ?? []).filter((i) => i.name === name).map((i) => i.address);
    options.push({ value: name, label: `${name} (${addresses.join(', ')})` });
    for (const address of addresses) options.push({ value: address, label: `${address} (${name})` });
  }
  if (!options.some((o) => o.value === current)) options.push({ value: current, label: `${current} (not present)` });
  return options;
}

function sortKey(id: string): [number, number[]] {
  const colon = id.indexOf(':');
  const proto = colon < 0 ? id : id.slice(0, colon);
  const rank = proto === 'artnet' ? 0 : proto === 'sacn' ? 1 : 2;
  return [rank, (colon < 0 ? '' : id.slice(colon + 1)).split('.').map(Number)];
}

/** Art-Net before sACN, then numerically per component ("0.0.2" before "0.0.10"). */
export function compareUniverse(a: string, b: string): number {
  const [ra, na] = sortKey(a);
  const [rb, nb] = sortKey(b);
  if (ra !== rb) return ra - rb;
  for (let i = 0; i < Math.max(na.length, nb.length); i++) {
    const d = (na[i] ?? -1) - (nb[i] ?? -1);
    if (d) return d;
  }
  return a.localeCompare(b);
}

function sortedUnique(ids: string[]): string[] {
  return [...new Set(ids.filter(Boolean))].sort(compareUniverse);
}

/** Universe choices for a fixture: everything in the patch and the live list plus the standard ones. */
export function universeOptions(patch: readonly PatchEntry[], live: readonly UniverseInfo[], stored: readonly UniverseSettingsDoc[] = []): string[] {
  return sortedUnique([...patch.map((e) => e.universe), ...live.map((u) => u.id), ...stored.map((u) => u.id), ...STANDARD_UNIVERSES]);
}

export const PROTOCOL_LABELS: Record<UniverseSettingsDoc['protocol'], string> = { artnet: 'Art-Net', sacn: 'sACN', both: 'Art-Net + sACN' };
export const HOLD_LABELS: Record<UniverseSettingsDoc['holdOnLoss'], string> = { hold: 'Hold last values', zero: 'Go to zero', internal: 'UI and cues take over' };

export interface Health {
  tone: 'green' | 'yellow' | 'red';
  text: string;
}

/** active -> green, silent for at most the loss timeout or never seen -> yellow, lost after having received -> red (DESIGN §12: red = look now). */
export function universeHealth(info: UniverseInfo | undefined, lossTimeout = 2.5): Health {
  if (info?.active) return { tone: 'green', text: `${info.packets} packets · ${info.source}` };
  if (!info || info.ageSeconds < 0) return { tone: 'yellow', text: 'never seen' };
  if (info.ageSeconds <= lossTimeout) return { tone: 'yellow', text: `${info.ageSeconds.toFixed(1)} s` };
  return { tone: 'red', text: 'lost' };
}

// ---- fixtures --------------------------------------------------------------------------------------------

export interface Collision {
  with: string;
  /** the contested channels */
  from: number;
  to: number;
}

export interface FixtureRow {
  name: string;
  type: FixtureType;
  /** the mode's name: "Layer", "Master" */
  typeLabel: string;
  /** what its mode is patched per: the group it is in */
  kind: string;
  /** n of "Layer n"; 1 for the one fixture of a `machine` mode */
  number: number;
  optional: boolean;
  footprint: number;
  /** as stored in the patch (also kept for an entry with address 0) */
  universe: string | null;
  /** 1-based first channel, 0 = unpatched */
  address: number;
  patched: boolean;
  /** last channel (may be above 512), 0 when unpatched */
  end: number;
  colour: string;
  collisions: Collision[];
  exceeds: boolean;
  /** unpatched although its block has a slot for it: the slot and the fixture on it (a new layer that found no room) */
  blocked: { slot: Slot; by: string } | null;
  /** patched, but not on its slot from the group's anchor: laying the group as a block moves it */
  offBlock: boolean;
}

interface Kind {
  /** the group's title; without one, its first mode's name ("Master") */
  title?: string;
  /** the highest fixture number: the next mode's block starts on slot max + 1 (Keystones on slot 9 of the outputs) */
  max: number;
  /** the fixture numbers that exist */
  numbers: (layerCount: number, outputIds: readonly number[]) => number[];
  /** the group after this one starts on the next universe (the standard patch puts the Master after the layers) */
  ownUniverses?: boolean;
}

/** The kinds this UI groups by (DESIGN §6.6 item 3): a new mode of one of them appears without code; a new kind needs an entry here. */
const KINDS: Record<string, Kind> = {
  layer: {
    title: 'Layers', max: MAX_LAYERS, ownUniverses: true,
    numbers: (layers) => Array.from({ length: Math.max(0, Math.min(Math.floor(layers) || 0, MAX_LAYERS)) }, (_, i) => i + 1),
  },
  machine: { max: 1, numbers: () => [1] },
  output: { title: 'Outputs', max: MAX_OUTPUTS, numbers: (_, ids) => [...new Set(ids)].filter((n) => n >= 1 && n <= MAX_OUTPUTS).sort((a, b) => a - b) },
};

/** The fixtures of one kind (DESIGN §6.6 item 2): Layers, the Master, the outputs with their Keystones. */
export interface Group {
  kind: string;
  title: string;
  modes: (FixtureMode & { footprint: number })[];
  /** the fixture numbers that exist: Layer 1…min(layerCount, 32), Master 1, each output 1–8 */
  numbers: number[];
  max: number;
  ownUniverses: boolean;
  /** by number, then mode: Output 1, Keystone 1, Output 2 … */
  rows: FixtureRow[];
  block: Block;
}

/** A group's block, derived from where its fixtures are, never stored (DESIGN §6.6 item 2). */
export interface Block {
  /** where the block starts; null when the group is Custom or has no required fixture patched */
  start: Slot | null;
  /** the anchor's start (address at least 1): a Custom group is re-laid from here; null with nothing required patched */
  anchor: Slot | null;
  required: number;
  /** required fixtures without an address */
  unplaced: number;
  /** patched required fixtures off the block from the anchor's start (Custom) */
  off: number;
  /** patched fixtures, optional ones included, that laying the group from its anchor's start moves */
  handPlaced: number;
}

export interface PatchScreen {
  /** every fixture that exists, group by group */
  rows: FixtureRow[];
  /** in channel-map order */
  groups: Group[];
}

/**
 * The fixtures that exist, patched or not, grouped by kind in channel-map order (DESIGN §6.6): Layer 1…min(layerCount,
 * 32), the Master, then Output n and Keystone n of every output n ≤ 8. Collisions are overlapping channel ranges within
 * one universe; a range past channel 512 is flagged as exceeding. Entries of fixtures that do not exist take no part.
 */
export function buildPatch(patch: readonly PatchEntry[], layerCount: number, map: ChannelMap | null, outputIds: readonly number[] = []): PatchScreen {
  const entries = new Map(patch.map((e) => [e.fixture, e] as const));
  const groups: Group[] = [];
  for (const f of map?.fixtures ?? FALLBACK_FIXTURES) {
    const kind = KINDS[f.per];
    if (!kind) continue; // a kind this UI does not know yet
    let group = groups.find((g) => g.kind === f.per);
    if (!group) {
      group = { kind: f.per, title: kind.title ?? f.name, modes: [], numbers: kind.numbers(layerCount, outputIds), max: kind.max, ownUniverses: !!kind.ownUniverses, rows: [], block: NO_BLOCK };
      groups.push(group);
    }
    group.modes.push({ ...f, footprint: footprintOf(map, f.mode) });
  }
  const rows: FixtureRow[] = [];
  for (const g of groups) {
    for (const number of g.numbers) {
      for (const m of g.modes) {
        const name = g.kind === 'machine' ? m.name : `${m.name} ${number}`;
        const entry = entries.get(name);
        const address = entry && entry.address >= 1 ? entry.address : 0;
        const end = address ? address + m.footprint - 1 : 0;
        const row: FixtureRow = {
          name, type: m.mode, typeLabel: m.name, kind: g.kind, number, optional: m.optional, footprint: m.footprint,
          universe: entry?.universe ?? null, address, patched: address > 0, end,
          colour: FIXTURE_COLOURS[rows.length % FIXTURE_COLOURS.length]!,
          collisions: [], exceeds: end > UNIVERSE_SIZE, blocked: null, offBlock: false,
        };
        g.rows.push(row);
        rows.push(row);
      }
    }
  }
  for (let i = 0; i < rows.length; i++) {
    const a = rows[i]!;
    if (!a.patched) continue;
    for (let j = i + 1; j < rows.length; j++) {
      const b = rows[j]!;
      if (!b.patched || b.universe !== a.universe) continue;
      const from = Math.max(a.address, b.address);
      const to = Math.min(a.end, b.end, UNIVERSE_SIZE);
      if (from > to) continue;
      a.collisions.push({ with: b.name, from, to });
      b.collisions.push({ with: a.name, from, to });
    }
  }
  for (const g of groups) g.block = detectBlock(g, rows);
  return { rows, groups };
}

/** Counts for the toolbar; a collision is one overlapping pair of fixtures. */
export function summarize(rows: readonly FixtureRow[]): { fixtures: number; universes: number; collisions: number } {
  const universes = new Set<string>();
  let ends = 0;
  for (const r of rows) {
    if (r.patched && r.universe) universes.add(r.universe);
    ends += r.collisions.length;
  }
  return { fixtures: rows.length, universes: universes.size, collisions: ends / 2 };
}

export function rangeText(r: FixtureRow): string {
  return r.patched ? `${r.address}–${r.end}` : '—';
}

/** "A 0.0.1 1–64": `footprint` channels from a slot. */
export function slotText(slot: Slot, footprint: number): string {
  return `${universeName(slot.universe)} ${slot.address}–${slot.address + footprint - 1}`;
}

export interface Status {
  tone: 'ok' | 'faint' | 'warn' | 'bad';
  text: string;
}

/**
 * The status words (DESIGN §6.6 item 4): "ok", or a collision or a range past 512 in red. Without an address: an
 * optional fixture is "not used"; one whose block slot is taken names what took it; else what it does under Who
 * controls (`policy`): Fanous only, or under Console only a layer stays dark (yellow) and the Master or an output stays
 * at its defaults (grey: full and normal are the working state).
 */
export function rowStatus(r: FixtureRow, policy: string): Status {
  if (!r.patched) {
    if (r.optional) return { tone: 'faint', text: 'not used' };
    if (r.blocked) return { tone: 'warn', text: `no address · ${slotText(r.blocked.slot, r.footprint)} is taken by ${r.blocked.by}` };
    if (policy !== 'dmx') return { tone: 'faint', text: 'no address · Fanous only' };
    return r.kind === 'layer' ? { tone: 'warn', text: 'no address · stays dark' } : { tone: 'faint', text: 'no address · at defaults' };
  }
  const parts: string[] = [];
  const first = r.collisions[0];
  if (first) parts.push(`collides with ${first.with} · ${first.from}–${first.to}${r.collisions.length > 1 ? ` (+${r.collisions.length - 1})` : ''}`);
  if (r.exceeds) parts.push('exceeds universe');
  return parts.length ? { tone: 'bad', text: parts.join('; ') } : { tone: 'ok', text: 'ok' };
}

/** Accessible name of a chip: "Layer 3, A 0.0.0 129–192, ok", with ", off the block" for a hand-placed fixture. */
export function rowSummary(r: FixtureRow, policy: string): string {
  const where = r.patched && r.universe ? `${universeName(r.universe)} ${rangeText(r)}, ` : '';
  return `${r.name}, ${where}${rowStatus(r, policy).text}${r.offBlock ? ', off the block' : ''}`;
}

// ---- blocks ----------------------------------------------------------------------------------------------

/** A universe and an address: where a block starts, or where one of its fixtures sits. */
export interface Slot {
  universe: string;
  address: number;
}

/**
 * Where fixture number `number` of a block from `start` sits (Core `Patch.slot(of:from:footprint:)`, DESIGN §6.6 item
 * 2): on slot number − 1, at start + (number − 1) × footprint. A slot that would run past channel 512 moves to address
 * 1 of the next universe, and so does every slot after it. Null for a start outside 1…512 or past the last universe.
 */
export function slotOf(number: number, start: Slot, footprint: number): Slot | null {
  if (number < 1 || start.address < 1 || start.address > UNIVERSE_SIZE || footprint < 1 || footprint > UNIVERSE_SIZE) return null;
  const index = number - 1;
  const first = Math.floor((UNIVERSE_SIZE + 1 - start.address) / footprint); // the slots that fit in the start universe
  if (index < first) return { universe: start.universe, address: start.address + index * footprint };
  const rest = index - first;
  const perUniverse = Math.floor(UNIVERSE_SIZE / footprint);
  const universe = advanceUniverse(start.universe, 1 + Math.floor(rest / perUniverse));
  return universe ? { universe, address: 1 + (rest % perUniverse) * footprint } : null;
}

function sameSlot(a: Slot | null | undefined, b: { universe: string | null; address: number }): boolean {
  return !!a && a.universe === b.universe && a.address === b.address;
}

/**
 * The start of a block (Core `Patch.blockStart`), or null when it is Custom or nothing is placed. `placed`: the patched
 * required fixtures by number. The anchor, the lowest number k, gives the start: its address − (k − 1) × footprint in
 * its universe, never rolled back across a universe. Block when every placed fixture sits on its slot from there.
 */
export function blockStart(placed: ReadonlyMap<number, Slot>, footprint: number): Slot | null {
  const anchor = Math.min(...placed.keys());
  const at = placed.get(anchor);
  if (!at) return null;
  const start = { universe: at.universe, address: at.address - (anchor - 1) * footprint };
  return [...placed].every(([n, slot]) => sameSlot(slotOf(n, start, footprint), slot)) ? start : null;
}

/**
 * Each fixture's slot when the group is laid from `start`: its first mode from there, each next mode's block from slot
 * max + 1 of the one before (Keystone n on slot n − 1 of a block that starts where a ninth output would sit). Null past
 * the last universe.
 */
export function groupSlots(g: Group, start: Slot): Map<string, Slot | null> {
  const slots = new Map<string, Slot | null>();
  let from: Slot | null = start;
  for (const m of g.modes) {
    for (const r of g.rows) if (r.type === m.mode) slots.set(r.name, from && slotOf(r.number, from, m.footprint));
    from = from && slotOf(g.max + 1, from, m.footprint);
  }
  return slots;
}

const NO_BLOCK: Block = { start: null, anchor: null, required: 0, unplaced: 0, off: 0, handPlaced: 0 };

/** The patched fixture other than `except` on any of `footprint` channels from `at`. */
function takenBy(rows: readonly FixtureRow[], at: Slot, footprint: number, except: string): FixtureRow | undefined {
  const end = at.address + footprint - 1;
  return rows.find((o) => o.patched && o.name !== except && o.universe === at.universe && o.address <= end && at.address <= o.end);
}

/** The group's block from its first mode's patched fixtures; while it is a Block, an unplaced required fixture whose slot is taken records what took it. */
function detectBlock(g: Group, rows: readonly FixtureRow[]): Block {
  const first = g.modes[0]!;
  const required = g.rows.filter((r) => !r.optional);
  const placed = new Map(required.filter((r) => r.type === first.mode && r.patched).map((r) => [r.number, { universe: r.universe!, address: r.address }] as const));
  const counts = { ...NO_BLOCK, required: required.length, unplaced: required.filter((r) => !r.patched).length };
  const anchorNumber = Math.min(...placed.keys());
  const at = placed.get(anchorNumber);
  if (!at) return counts;
  let start = blockStart(placed, first.footprint);
  const anchor = start ?? { universe: at.universe, address: Math.max(1, at.address - (anchorNumber - 1) * first.footprint) };
  const slots = groupSlots(g, anchor);
  for (const r of g.rows) r.offBlock = r.patched && !sameSlot(slots.get(r.name), r);
  const off = required.filter((r) => r.offBlock).length;
  if (off > 0) start = null; // a required fixture of a later mode off its slot
  if (start) {
    for (const r of required) {
      const slot = slots.get(r.name);
      const by = !r.patched && slot ? takenBy(rows, slot, r.footprint, r.name) : undefined;
      if (slot && by) r.blocked = { slot, by: by.name };
    }
  }
  return { ...counts, start, anchor, off, handPlaced: g.rows.filter((r) => r.offBlock).length };
}

/**
 * `patch.setMany` entries that lay the group as a block from `start`: every required fixture and every patched optional
 * one on its slot. `past`: the fixtures that would run past the last universe; the block does not fit then, and is not
 * laid.
 */
export function layEntries(g: Group, start: Slot): { entries: PatchEntry[]; past: FixtureRow[] } {
  const slots = groupSlots(g, start);
  const entries: PatchEntry[] = [];
  const past: FixtureRow[] = [];
  for (const r of g.rows) {
    if (r.optional && !r.patched) continue;
    const slot = slots.get(r.name);
    if (slot) entries.push({ fixture: r.name, ...slot });
    else past.push(r);
  }
  return { entries, past };
}

/** Where the group after `g` starts when `g` is laid from `start`: on the universe after its last slot for the layers (the standard patch), else right after its last mode's block (the outputs after the Master). */
function after(g: Group, start: Slot): Slot | null {
  if (g.ownUniverses) {
    const last = slotOf(g.numbers.at(-1) ?? 1, start, g.modes[0]!.footprint);
    const next = last && advanceUniverse(last.universe, 1);
    return next ? { universe: next, address: 1 } : null;
  }
  let from: Slot | null = start;
  for (const m of g.modes) from = from && slotOf(g.max + 1, from, m.footprint);
  return from;
}

/**
 * Where Patch as block lays group `index` (DESIGN §6.6 item 2): the standard patch's position, counted from where the
 * groups before it are: the layers at A 0.0.0 1, the Master on the universe after the layers, the outputs after it.
 */
export function standardStart(groups: readonly Group[], index: number): Slot | null {
  const before = groups[index - 1];
  if (!before) return { universe: 'artnet:0.0.0', address: 1 };
  const from = before.block.start ?? before.block.anchor ?? standardStart(groups, index - 1);
  return from && after(before, from);
}

/**
 * "Move Master and outputs after the layers" (DESIGN §6.6 item 2), offered when a layer found no room because a later
 * group sits on its slot: lays each later group that has a block from the universe after the last layer slot, each
 * after the one before, and puts the unplaced layers on their slots, as one `patch.setMany`. Null when no layer is
 * blocked by a later group, or a later group would run past the last universe.
 */
export function moveAfterLayers(groups: readonly Group[]): PatchEntry[] | null {
  const i = groups.findIndex((g) => g.ownUniverses);
  const layers = groups[i];
  const start = layers?.block.start;
  if (!layers || !start) return null;
  const later = groups.slice(i + 1);
  const names = new Set(later.flatMap((g) => g.rows.map((r) => r.name)));
  if (!layers.rows.some((r) => r.blocked && names.has(r.blocked.by))) return null;
  const slots = groupSlots(layers, start);
  const entries: PatchEntry[] = [];
  for (const r of layers.rows) {
    const slot = slots.get(r.name);
    if (!r.optional && !r.patched && slot) entries.push({ fixture: r.name, ...slot });
  }
  let from = after(layers, start);
  for (const g of later) {
    if (!from) return null;
    if (g.block.anchor) {
      const laid = layEntries(g, from);
      if (laid.past.length > 0) return null;
      entries.push(...laid.entries);
    }
    from = after(g, from);
  }
  return entries;
}

/**
 * Where Patch puts an unpatched optional fixture (a Keystone, DESIGN §6.6 item 2): on its slot of the group's block
 * when that range is free, else on the first free range after it in that universe. Null when none is free or the group
 * has no block: then it is placed by hand.
 */
export function patchTarget(g: Group, r: FixtureRow, rows: readonly FixtureRow[]): Slot | null {
  const slot = g.block.start && groupSlots(g, g.block.start).get(r.name);
  if (!slot) return null;
  for (let address = slot.address; address + r.footprint - 1 <= UNIVERSE_SIZE; address++) {
    if (!takenBy(rows, { universe: slot.universe, address }, r.footprint, r.name)) return { universe: slot.universe, address };
  }
  return null;
}

// ---- cells -----------------------------------------------------------------------------------------------

export interface Cell {
  /** 1..512 */
  ch: number;
  /** every fixture claiming this channel, in list order */
  owners: string[];
  /** the first owner (list order); it decides colour and parameter */
  owner: FixtureRow | null;
  collision: boolean;
  /** fixture-relative channel of the owner, 0 when unowned */
  rel: number;
  at: ParamAt | null;
}

/** The 512 cells of one universe with their owners; ranges are clipped at channel 512. */
export function buildCells(rows: readonly FixtureRow[], universe: string | null, map: ChannelMap | null): Cell[] {
  const cells: Cell[] = Array.from({ length: UNIVERSE_SIZE }, (_, i) => ({ ch: i + 1, owners: [], owner: null, collision: false, rel: 0, at: null }));
  if (universe === null) return cells;
  for (const r of rows) {
    if (!r.patched || r.universe !== universe) continue;
    for (let k = 0; k < r.footprint; k++) {
      const cell = cells[r.address - 1 + k];
      if (!cell) break;
      cell.owners.push(r.name);
      if (!cell.owner) {
        cell.owner = r;
        cell.rel = k + 1;
        cell.at = paramAt(map, r.type, k + 1);
      }
    }
  }
  for (const c of cells) c.collision = c.owners.length > 1;
  return cells;
}

/** "Opacity", "Opacity (fine)", or '' when the channel map does not name this channel. */
export function paramName(c: Cell): string {
  return c.at ? c.at.spec.name + (c.at.fine ? ' (fine)' : '') : '';
}

export function cellLabel(c: Cell): string {
  if (c.collision) return `Channel ${c.ch} · collision · ${c.owners.join(', ')}`;
  if (!c.owner) return `Channel ${c.ch} · free`;
  return `Channel ${c.ch} · ${c.owner.name} · ${paramName(c) || `ch ${c.rel}`}`;
}

/** A monitor frame as exactly 512 slots (a short or long payload is padded or cut). */
export function frameValues(payload: Uint8Array): Uint8Array {
  if (payload.length === UNIVERSE_SIZE) return payload;
  const out = new Uint8Array(UNIVERSE_SIZE);
  out.set(payload.subarray(0, UNIVERSE_SIZE));
  return out;
}

// ---- universes panel -------------------------------------------------------------------------------------

/** "Layers 1–8, Master", "Layers 1–3, 5", "Output 2, Keystone 2": per type in list order, consecutive numbers as a range. */
export function fixturesText(rows: readonly FixtureRow[]): string {
  const groups = new Map<string, number[]>();
  for (const r of rows) {
    const numbers = groups.get(r.typeLabel) ?? [];
    if (r.kind !== 'machine') numbers.push(r.number);
    groups.set(r.typeLabel, numbers);
  }
  return [...groups].map(([label, numbers]) => {
    if (numbers.length === 0) return label;
    const n = numbers.sort((a, b) => a - b);
    const runs: string[] = [];
    for (let i = 0; i < n.length; i++) {
      const from = n[i]!;
      while (n[i + 1] === n[i]! + 1) i++;
      runs.push(from === n[i] ? `${from}` : `${from}–${n[i]}`);
    }
    return `${label}${n.length > 1 ? 's' : ''} ${runs.join(', ')}`;
  }).join(', ');
}

export interface UniverseRow {
  id: string;
  settings: UniverseSettingsDoc;
  health: Health;
  /** "Art-Net · All interfaces · Hold last values" */
  line: string;
  /** the fixtures on it, "feeds A 0.0.0" (its pair), "heard, nothing patched" (a console sending to the wrong universe) or "not used" */
  text: string;
  tone: 'ok' | 'warn' | 'faint';
  /** the pill as a word, without the live packet count: receiving, quiet, lost or never seen */
  state: string;
}

/** Packets now, or silent for at most the loss timeout: the console is sending to it. */
function heardNow(info: UniverseInfo | undefined, lossTimeout: number): boolean {
  return !!info && (info.active || (info.ageSeconds >= 0 && info.ageSeconds <= lossTimeout));
}

/**
 * One row per universe that a fixture is patched on, the engine hears now, or the project stores settings for (DESIGN
 * §6.6). A universe the engine heard earlier and nobody uses drops out after its loss timeout, so a fixed console clears
 * its warning; one in `keep` (open in the panel or shown in the monitor) stays, so a row never vanishes under the user
 * when a console pauses. Red is for a patched universe (look now): one without fixtures shows a loss as yellow "quiet".
 */
export function universeRows(
  rows: readonly FixtureRow[], live: readonly UniverseInfo[], stored: readonly UniverseSettingsDoc[] | undefined, keep: readonly string[] = [],
): UniverseRow[] {
  const patched = rows.filter((r) => r.patched && r.universe);
  const used = new Set(patched.map((r) => r.universe!));
  // a used universe fed by the other protocol also lists that wire universe (engine UniverseTable.targets): pair → used
  const feeds = new Map<string, string>();
  for (const id of used) {
    const s = universeSettings(stored, id);
    if (s.protocol !== (id.startsWith('sacn:') ? 'sacn' : 'artnet')) feeds.set(s.pair, id);
  }
  const listening = (info: UniverseInfo | undefined) =>
    !!info && (heardNow(info, universeSettings(stored, info.id).lossTimeout) || (info.ageSeconds >= 0 && keep.includes(info.id)));
  const heard = live.filter(listening).map((u) => u.id);
  const ids = sortedUnique([...used, ...heard, ...(stored ?? []).map((u) => u.id)]);
  return ids.map((id) => {
    const info = live.find((u) => u.id === id);
    const settings = universeSettings(stored, id);
    const on = patched.filter((r) => r.universe === id);
    const line = [
      PROTOCOL_LABELS[settings.protocol] ?? settings.protocol,
      settings.interface === 'any' ? 'All interfaces' : settings.interface,
      HOLD_LABELS[settings.holdOnLoss] ?? settings.holdOnLoss,
    ].join(' · ');
    const fed = feeds.get(id);
    const what: Pick<UniverseRow, 'text' | 'tone'> = on.length > 0 ? { text: fixturesText(on), tone: 'ok' }
      : fed ? { text: `feeds ${universeName(fed)}`, tone: 'ok' }
      : listening(info) ? { text: 'heard, nothing patched', tone: 'warn' }
      : { text: 'not used', tone: 'faint' };
    let health = universeHealth(info, settings.lossTimeout);
    if (on.length === 0 && health.tone === 'red') health = { tone: 'yellow', text: 'quiet' };
    const state = health.tone === 'green' ? 'receiving' : health.tone === 'red' ? 'lost' : health.text === 'never seen' ? 'never seen' : 'quiet';
    return { id, settings, health, line, ...what, state };
  });
}
