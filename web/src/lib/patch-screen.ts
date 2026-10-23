// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure logic of the Patch / DMX screen: fixture list with channel ranges and collisions, per-universe cell
// ownership, parameter lookup by fixture-relative channel, universe naming and option lists.
import type { PatchEntry, UniverseInfo } from './docs';

export const UNIVERSE_SIZE = 512;
export const LOCKED_TITLE = 'Locked: programmer only';

/** 11 hues at one lightness: dark backgrounds that carry light mono text. */
export const FIXTURE_COLOURS = ['#4A3A1E', '#1E4A3A', '#1F3B5E', '#3E2A5E', '#5E2A4A', '#2A5E4A', '#5E4A2A', '#2A4A5E', '#4A2A5E', '#5E2A2A', '#2A5E5E'] as const;

export type FixtureType = 'layer' | 'master' | 'output';

/** Used until /api/channel-map.json has arrived (or when it cannot be fetched). */
export const FALLBACK_FOOTPRINTS: Record<FixtureType, number> = { layer: 64, master: 8, output: 8 };

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
}

const TYPES: FixtureType[] = ['layer', 'master', 'output'];

/** Shallow shape check; anything else is treated as "no channel map" and the fallback footprints apply. */
export function parseChannelMap(json: unknown): ChannelMap | null {
  const j = json as Partial<ChannelMap> | null;
  if (!j || typeof j !== 'object' || !j.footprints || !j.modes) return null;
  for (const t of TYPES) {
    if (typeof j.footprints[t] !== 'number' || !Array.isArray(j.modes[t])) return null;
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
  return map?.footprints[type] ?? FALLBACK_FOOTPRINTS[type];
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

export function universeProtocol(id: string): 'Art-Net' | 'sACN' | 'unknown' {
  return id.startsWith('artnet:') ? 'Art-Net' : id.startsWith('sacn:') ? 'sACN' : 'unknown';
}

/** Per-universe settings are not editable yet (B28): what the engine does today, as display strings. */
export function universeSettings(id: string): { protocol: string; iface: string; holdOnLoss: string; priority: string } {
  return { protocol: universeProtocol(id), iface: 'all interfaces', holdOnLoss: '2.5 s', priority: id.startsWith('sacn:') ? '100' : 'n/a' };
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

/** Universes the monitor can show: patched (address >= 1) plus every one the engine listens on. */
export function knownUniverses(patch: readonly PatchEntry[], live: readonly UniverseInfo[]): string[] {
  return sortedUnique([...patch.filter((e) => e.address >= 1).map((e) => e.universe), ...live.map((u) => u.id)]);
}

/** Universe choices for a fixture: everything in the patch and the live list plus the standard ones. */
export function universeOptions(patch: readonly PatchEntry[], live: readonly UniverseInfo[]): string[] {
  return sortedUnique([...patch.map((e) => e.universe), ...live.map((u) => u.id), ...STANDARD_UNIVERSES]);
}

export interface Health {
  tone: 'green' | 'yellow' | 'red';
  text: string;
}

/** active -> green, silent for at most 2.5 s or never seen -> yellow, lost after having received -> red (DESIGN §12: red = look now). */
export function universeHealth(info: UniverseInfo | undefined): Health {
  if (info?.active) return { tone: 'green', text: `${info.packets} packets · ${info.source}` };
  if (!info || info.ageSeconds < 0) return { tone: 'yellow', text: 'never seen' };
  if (info.ageSeconds <= 2.5) return { tone: 'yellow', text: `${info.ageSeconds.toFixed(1)} s` };
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
  typeLabel: 'Layer' | 'Master' | 'Output';
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
}

const TYPE_LABEL = { layer: 'Layer', master: 'Master', output: 'Output' } as const;

export function parseFixture(name: string): { type: FixtureType; index: number } | null {
  if (name === 'Master') return { type: 'master', index: 0 };
  const m = /^(Layer|Output) (\d+)$/.exec(name);
  return m ? { type: m[1] === 'Layer' ? 'layer' : 'output', index: Number(m[2]) } : null;
}

/**
 * Layer 1..layerCount (patched or not), Master, then every Output named in the patch. Collisions are
 * overlapping channel ranges within one universe; a range past channel 512 is flagged as exceeding.
 * Layer entries above layerCount are not fixtures any more and take no part.
 */
export function buildFixtures(patch: readonly PatchEntry[], layerCount: number, map: ChannelMap | null): FixtureRow[] {
  const entries = new Map(patch.map((e) => [e.fixture, e] as const));
  const outputs = new Set<number>();
  for (const e of patch) {
    const f = parseFixture(e.fixture);
    if (f?.type === 'output') outputs.add(f.index);
  }
  const names = [
    ...Array.from({ length: Math.max(0, Math.floor(layerCount)) }, (_, i) => `Layer ${i + 1}`),
    'Master',
    ...[...outputs].sort((a, b) => a - b).map((i) => `Output ${i}`),
  ];
  const rows: FixtureRow[] = names.map((name, i) => {
    const type = parseFixture(name)!.type;
    const entry = entries.get(name);
    const footprint = footprintOf(map, type);
    const address = entry && entry.address >= 1 ? entry.address : 0;
    const end = address ? address + footprint - 1 : 0;
    return {
      name, type, typeLabel: TYPE_LABEL[type], footprint,
      universe: entry?.universe ?? null, address, patched: address > 0, end,
      colour: FIXTURE_COLOURS[i % FIXTURE_COLOURS.length]!,
      collisions: [], exceeds: end > UNIVERSE_SIZE,
    };
  });
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
  return rows;
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

export interface Status {
  tone: 'ok' | 'faint' | 'bad';
  text: string;
}

export function rowStatus(r: FixtureRow): Status {
  if (!r.patched) return { tone: 'faint', text: 'unpatched · no console control' };
  const parts: string[] = [];
  const first = r.collisions[0];
  if (first) parts.push(`collides with ${first.with} · ${first.from}–${first.to}${r.collisions.length > 1 ? ` (+${r.collisions.length - 1})` : ''}`);
  if (r.exceeds) parts.push('exceeds universe');
  return parts.length ? { tone: 'bad', text: parts.join('; ') } : { tone: 'ok', text: 'ok' };
}

/** Accessible name of a table row (its visible cells are laid out in columns). */
export function rowSummary(r: FixtureRow): string {
  const where = r.patched && r.universe ? `universe ${universeName(r.universe)}, address ${r.address}, channels ${rangeText(r)}` : 'not patched';
  return `${r.name}, ${r.typeLabel}, ${r.footprint} channels, ${where}, ${rowStatus(r).text}`;
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
  if (!c.owner) return `Channel ${c.ch} · unpatched`;
  return `Channel ${c.ch} · ${c.owner.name} · ${paramName(c) || `ch ${c.rel}`}`;
}

/** A monitor frame as exactly 512 slots (a short or long payload is padded or cut). */
export function frameValues(payload: Uint8Array): Uint8Array {
  if (payload.length === UNIVERSE_SIZE) return payload;
  const out = new Uint8Array(UNIVERSE_SIZE);
  out.set(payload.subarray(0, UNIVERSE_SIZE));
  return out;
}
