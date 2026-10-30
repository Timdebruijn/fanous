// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure logic of the Show control screen: cue numbering and reordering, trigger text, fixture and parameter
// choices for cue values, value controls from the channel map, timecode wording, OSC log times, MIDI map wording.
import type { CueDoc, CueValueDoc, LiveDoc, MIDIMappingDoc, PatchEntry, TimecodeSettingsDoc } from './docs';
import { LOCKED_TITLE, type ChannelMap, type FixtureType, type ParamSpec } from './patch-screen';

export const LOCKED_OPERATOR = 'Locked: operator only';
export const LOCKED_SHOW = 'Locked: the show is locked (press L to unlock)';

/**
 * Tooltip of a control the user cannot use, undefined when it is usable: the role lacks it, or the show is locked
 * (configuration commands are refused then; go/back/goto are not configuration and pass `showLock = false`).
 */
export function lockTitle(role: 'operator' | 'programmer', allowed: boolean, showLock: boolean): string | undefined {
  if (!allowed) return role === 'operator' ? LOCKED_OPERATOR : LOCKED_TITLE;
  return showLock ? LOCKED_SHOW : undefined;
}

// ---- cue numbers -------------------------------------------------------------------------------------------

/** Up to three decimals, no trailing zeros: 3, 2.5, 2.125. */
export function formatNumber(n: number): string {
  return Number.isFinite(n) ? String(Number(n.toFixed(3))) : '—';
}

export function sortedCues(cues: readonly CueDoc[]): CueDoc[] {
  return [...cues].sort((a, b) => a.number - b.number);
}

/** "Add cue": one above the highest number, whole, so decimal cues do not drag the list along (2.5 → 3). */
export function nextCueNumber(cues: readonly CueDoc[]): number {
  return cues.length === 0 ? 1 : Math.floor(Math.max(...cues.map((c) => c.number))) + 1;
}

/** "Duplicate": halfway to the next cue so the copy lands right behind the original; the end of the list when there is none. */
export function numberAfter(cues: readonly CueDoc[], number: number): number {
  const above = cues.map((c) => c.number).filter((n) => n > number);
  if (above.length === 0) return nextCueNumber(cues);
  const middle = Number(((number + Math.min(...above)) / 2).toFixed(3));
  return middle > number ? middle : nextCueNumber(cues); // three decimals used up
}

export function isNumberTaken(cues: readonly CueDoc[], number: number, exceptId?: string): boolean {
  return cues.some((c) => c.id !== exceptId && c.number === number);
}

/**
 * Move a cue one place by swapping its number with its neighbour's. The engine refuses a duplicate number
 * (cue.set → "cue number exists"), so a plain two-step swap cannot work: the first cue parks above the list.
 * Returns whole cues for `cue.set`, to be sent in order; empty at either end of the list.
 */
export function swapSteps(cues: readonly CueDoc[], id: string, direction: -1 | 1): CueDoc[] {
  const list = sortedCues(cues);
  const index = list.findIndex((c) => c.id === id);
  const a = list[index];
  const b = list[index + direction];
  if (!a || !b) return [];
  const parked = nextCueNumber(list);
  return [{ ...a, number: parked }, { ...b, number: a.number }, { ...a, number: b.number }];
}

// ---- trigger text ------------------------------------------------------------------------------------------

/**
 * `id` is how the rate is typed and shown (docs.ts: 24, 25, 29.97df, 30); `engine` is the spelling
 * ShowCommands.parseTimecode accepts (TimecodeRate.label), which is what we store.
 */
const TRIGGER_RATES: { id: string; engine: string; frames: number }[] = [
  { id: '24', engine: '24', frames: 24 },
  { id: '25', engine: '25', frames: 25 },
  { id: '29.97df', engine: '29.97 DF', frames: 30 },
  { id: '29.97ndf', engine: '29.97 NDF', frames: 30 },
  { id: '30', engine: '30', frames: 30 },
];

export const TRIGGER_HINT = 'hh:mm:ss:ff@rate, for example 00:01:30:00@25 (rates: 24, 25, 29.97df, 30)';

export type TriggerResult = { ok: true; value: string | null } | { ok: false; error: string };

/**
 * Empty = no trigger. Otherwise `hh:mm:ss:ff` with an optional `@rate` (25 when left out), `;` allowed before the frames.
 * The result is padded and carries the rate in the spelling the engine parses, so a typo cannot become a trigger that
 * the engine silently drops.
 */
export function parseTrigger(text: string): TriggerResult {
  const trimmed = text.trim();
  if (trimmed === '') return { ok: true, value: null };
  const match = /^(\d{1,2}):(\d{1,2}):(\d{1,2})[:;](\d{1,2})(?:\s*@\s*(.+))?$/.exec(trimmed);
  if (!match) return { ok: false, error: `Use ${TRIGGER_HINT}` };
  const [h, m, s, f] = [match[1], match[2], match[3], match[4]].map(Number) as [number, number, number, number];
  const rateText = (match[5] ?? '25').toLowerCase().replace(/\s+/g, '');
  const rate = TRIGGER_RATES.find((r) => r.id === rateText);
  if (!rate) return { ok: false, error: `Unknown rate "${match[5]}"; use 24, 25, 29.97df, 29.97ndf or 30` };
  if (h > 23 || m > 59 || s > 59) return { ok: false, error: 'Hours go to 23, minutes and seconds to 59' };
  if (f >= rate.frames) return { ok: false, error: `Frames go to ${rate.frames - 1} at ${rate.id} fps` };
  const pad = (n: number) => String(n).padStart(2, '0');
  return { ok: true, value: `${pad(h)}:${pad(m)}:${pad(s)}:${pad(f)}@${rate.engine}` };
}

// ---- cue rows ----------------------------------------------------------------------------------------------

export interface CueRowText {
  number: string;
  fade: string;
  trigger: string;
  follow: string;
  values: string;
}

export function cueRowText(cue: CueDoc): CueRowText {
  return {
    number: formatNumber(cue.number),
    fade: `${formatNumber(cue.fade)} s`,
    trigger: cue.trigger || '—',
    follow: cue.follow == null ? '—' : `${formatNumber(cue.follow)} s`,
    values: String(cue.values.length),
  };
}

/** Accessible name of a cue row (the row is a button, its cells are not labelled). */
export function cueRowLabel(cue: CueDoc, status: 'current' | 'next' | null): string {
  const t = cueRowText(cue);
  const parts = [`Cue ${t.number}`, cue.name || 'unnamed', `fade ${t.fade}`];
  if (cue.trigger) parts.push(`trigger ${cue.trigger}`);
  if (cue.follow != null) parts.push(`follow ${t.follow}`);
  parts.push(`${t.values} ${cue.values.length === 1 ? 'value' : 'values'}`);
  if (status) parts.push(status);
  return parts.join(', ');
}

/** The cue is the live current/next one by number (the engine reports numbers). */
export function cueStatus(cue: CueDoc, live: LiveDoc['cue']): 'current' | 'next' | null {
  return live.current === cue.number ? 'current' : live.next === cue.number ? 'next' : null;
}

// ---- fixtures, parameters and values ------------------------------------------------------------------------

export function fixtureType(name: string): FixtureType | null {
  if (name === 'Master') return 'master';
  if (/^Layer \d+$/.test(name)) return 'layer';
  if (/^Output \d+$/.test(name)) return 'output';
  if (/^Keystone \d+$/.test(name)) return 'keystone';
  return null;
}

/** "Layer 1".."Layer n", "Master", then every "Output n" and "Keystone n" of the patch in numeric order. */
export function fixtureNames(layerCount: number, patch: readonly PatchEntry[]): string[] {
  const patched = (type: FixtureType) =>
    patch
      .map((e) => e.fixture)
      .filter((name) => fixtureType(name) === type)
      .sort((a, b) => Number(a.split(' ')[1]) - Number(b.split(' ')[1]));
  const layers = Array.from({ length: Math.max(0, Math.floor(layerCount) || 0) }, (_, i) => `Layer ${i + 1}`);
  return [...new Set([...layers, 'Master', ...patched('output'), ...patched('keystone')])];
}

/** Parameters of a fixture; empty until the channel map has arrived (or for a name that is no fixture). */
export function specsFor(map: ChannelMap | null, fixture: string): ParamSpec[] {
  const type = fixtureType(fixture);
  return (type && map?.modes[type]) || [];
}

/** Specs by their `group` in order of first appearance, for `<optgroup>`s; ungrouped specs come first. */
export function groupSpecs(specs: readonly ParamSpec[]): { group: string; specs: ParamSpec[] }[] {
  const groups = new Map<string, ParamSpec[]>();
  for (const spec of specs) {
    const key = spec.group ?? '';
    groups.set(key, [...(groups.get(key) ?? []), spec]);
  }
  return [...groups].map(([group, list]) => ({ group, specs: list }));
}

export function rawMax(spec: ParamSpec | undefined): number {
  return spec?.bits === 8 ? 255 : 65535; // an unknown parameter allows the wide range; the engine clamps
}

export function clampRaw(spec: ParamSpec | undefined, n: number): number {
  return Math.min(rawMax(spec), Math.max(0, Math.round(Number.isFinite(n) ? n : 0)));
}

export type ValueControl =
  | { kind: 'select'; options: { label: string; raw: number }[]; /** `from` of the band holding the value, null when outside every band */ selected: number | null; caption: string }
  | { kind: 'number'; min: number; max: number; caption: string };

/** Parameters with bands (play mode, blend mode, ...) get a select of band names; all others a number input. */
export function valueControl(spec: ParamSpec | undefined, raw: number): ValueControl {
  if (spec?.bands?.length) {
    const band = spec.bands.find((b) => raw >= b.from && raw <= b.to);
    return { kind: 'select', options: spec.bands.map((b) => ({ label: b.name, raw: b.from })), selected: band?.from ?? null, caption: `${spec.name} · raw ${raw}` };
  }
  return { kind: 'number', min: 0, max: rawMax(spec), caption: spec ? `${spec.name} · 0–${rawMax(spec)}` : 'raw value' };
}

/** A new value row: the first parameter of the first fixture at its default. */
export function newValue(map: ChannelMap | null, fixtures: readonly string[]): CueValueDoc {
  const fixture = fixtures[0] ?? 'Master';
  const spec = specsFor(map, fixture)[0];
  return { fixture, parameter: spec?.key ?? 'intensity', raw: spec?.default ?? 0 };
}

/**
 * Change the fixture or the parameter of a value. A new fixture keeps the parameter when its type has one by that key
 * (intensity exists on all three) and otherwise takes the first; a different parameter starts at its default.
 */
export function retargetValue(map: ChannelMap | null, value: CueValueDoc, change: { fixture?: string; parameter?: string }): CueValueDoc {
  const fixture = change.fixture ?? value.fixture;
  const specs = specsFor(map, fixture);
  const spec = specs.find((s) => s.key === (change.parameter ?? value.parameter)) ?? specs[0];
  if (!spec) return { ...value, fixture };
  return { ...value, fixture, parameter: spec.key, raw: spec.key === value.parameter ? clampRaw(spec, value.raw) : (spec.default ?? 0) };
}

/** The per-value fade override; null removes it so the cue's fade applies again. */
export function withFade(value: CueValueDoc, fade: number | null): CueValueDoc {
  const { fade: _old, ...rest } = value;
  return fade === null ? rest : { ...rest, fade };
}

// ---- timecode and OSC wording --------------------------------------------------------------------------------

export type ClockTone = 'green' | 'yellow' | 'red' | 'off';

export function timecodeBadge(state: LiveDoc['timecode']['state']): { label: string; tone: ClockTone } {
  switch (state) {
    case 'locked':
      return { label: 'Locked', tone: 'green' };
    case 'freewheel':
      return { label: 'Freewheel', tone: 'yellow' };
    case 'lost':
      return { label: 'Lost', tone: 'red' };
    default:
      return { label: 'Off', tone: 'off' };
  }
}

/** The operator's switch with a source chosen (Show › Timecode); a missing or null `enabled` is on. */
export function timecodeOn(tc: Pick<TimecodeSettingsDoc, 'source' | 'enabled'>): boolean {
  return tc.source !== 'off' && tc.enabled !== false;
}

/** "LTC · Scarlett 2i2 · 25 fps"; "29.97 DF" already names its rate. */
export function timecodeSource(tc: Pick<LiveDoc['timecode'], 'state' | 'source' | 'device' | 'rate'>): string {
  if (tc.state === 'off') return 'No source';
  const rate = /^\d+(\.\d+)?$/.test(tc.rate) ? `${tc.rate} fps` : tc.rate;
  return [tc.source.toUpperCase(), tc.device, rate].filter(Boolean).join(' · ');
}

/** `recent[].at` is a Unix time in seconds; shown as local hh:mm:ss. */
export function formatClock(at: number): string {
  const date = new Date(at * 1000);
  if (Number.isNaN(date.getTime())) return '--:--:--';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/** Frames per second of a timecode rate as the engine spells it ("25", "29.97 DF"); null when it names none. */
export function rateFps(rate: string): number | null {
  const n = Number.parseFloat(rate);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.abs(n - 29.97) < 0.005 ? 30000 / 1001 : n;
}

/** "+25 frames = +1.00 s at 25 fps": the offset in both units, the sign kept. Unknown rate: assumes 25 and says so. */
export function offsetText(frames: number, rate: string): string {
  const fps = rateFps(rate);
  const seconds = frames / (fps ?? 25);
  const sign = frames > 0 ? '+' : '';
  const unit = Math.abs(frames) === 1 ? 'frame' : 'frames';
  const at = fps === null ? 'assuming 25 fps until a source locks' : `at ${rate.replace(/ (DF|NDF)$/, '')} fps`;
  return `${sign}${frames} ${unit} = ${sign}${seconds.toFixed(2)} s ${at}`;
}

// ---- MIDI map (B36) ------------------------------------------------------------------------------------------

/** "ch 1 · note 36", "any ch · CC 1/33 (14-bit)", "ch 10 · any program". */
export function midiControlText(m: Pick<MIDIMappingDoc, 'channel' | 'kind' | 'number'>): string {
  const ch = m.channel === 0 ? 'any ch' : `ch ${m.channel}`;
  const n = m.number ?? 0;
  const what = { note: `note ${n}`, cc: `CC ${n}`, cc14: `CC ${n}/${n + 32} (14-bit)`, pc: m.number == null ? 'any program' : `program ${n}` }[m.kind];
  return `${ch} · ${what}`;
}

/** The fixture and parameter key a parameter target names; null for cue targets and anything unknown. */
export function midiParameterTarget(target: string): { fixture: string; parameter: string } | null {
  const path = target.startsWith('fixture:') ? target.slice(8) : target.startsWith('master/') ? `Master${target.slice(6)}` : null;
  const slash = path?.lastIndexOf('/') ?? -1;
  if (!path || slash < 1) return null;
  return { fixture: path.slice(0, slash), parameter: path.slice(slash + 1) };
}

/** "GO", "Back", "Go to cue 3", "Go to cue (program + 1)", "Layer 2 · Intensity". */
export function midiTargetText(m: Pick<MIDIMappingDoc, 'target' | 'cue'>, map: ChannelMap | null): string {
  if (m.target === 'cue.go') return 'GO';
  if (m.target === 'cue.back') return 'Back';
  if (m.target === 'cue.goto') return m.cue == null ? 'Go to cue (program + 1)' : `Go to cue ${formatNumber(m.cue)}`;
  const p = midiParameterTarget(m.target);
  if (!p) return m.target;
  const spec = specsFor(map, p.fixture).find((s) => s.key === p.parameter);
  return `${p.fixture} · ${spec?.name ?? p.parameter}`;
}
