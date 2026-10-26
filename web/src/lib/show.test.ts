// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { CueDoc, PatchEntry } from './docs';
import type { ChannelMap, ParamSpec } from './patch-screen';
import {
  cueRowLabel, cueRowText, cueStatus, fixtureNames, fixtureType, formatClock, formatNumber, groupSpecs, isNumberTaken, lockTitle, newValue, nextCueNumber,
  numberAfter, parseTrigger, retargetValue, sortedCues, specsFor, swapSteps, timecodeBadge, timecodeSource, valueControl, withFade,
  offsetText,
  rateFps,
} from './show';

const cue = (id: string, number: number, extra: Partial<CueDoc> = {}): CueDoc => ({ id, number, name: `Cue ${number}`, fade: 0, values: [], ...extra });

const playMode: ParamSpec = {
  name: 'Play mode', key: 'playMode', channel: 5, bits: 8, default: 0, group: 'Media',
  bands: [{ from: 0, to: 15, name: 'Loop fwd' }, { from: 16, to: 31, name: 'Loop rev' }, { from: 32, to: 47, name: 'Once hold' }],
};
const intensity: ParamSpec = { name: 'Intensity', key: 'intensity', channel: 1, bits: 16, default: 0, group: 'Output' };
const control: ParamSpec = { name: 'Control', key: 'control', channel: 3, bits: 8, default: 0, group: 'Output' };
const map: ChannelMap = {
  footprints: { layer: 64, master: 8, output: 8 },
  modes: { layer: [intensity, playMode], master: [{ ...intensity, name: 'Master intensity' }, control], output: [intensity, control] },
};

describe('lockTitle', () => {
  it('names the missing role, then the show lock, else nothing', () => {
    expect(lockTitle('programmer', false, false)).toBe('Locked: programmer only');
    expect(lockTitle('operator', false, false)).toBe('Locked: operator only');
    expect(lockTitle('programmer', true, true)).toContain('show is locked');
    expect(lockTitle('programmer', false, true)).toBe('Locked: programmer only');
    expect(lockTitle('operator', true, false)).toBeUndefined();
  });
});

describe('cue numbers', () => {
  it('numbers the next cue one above the highest, whole', () => {
    expect(nextCueNumber([])).toBe(1);
    expect(nextCueNumber([cue('a', 1), cue('b', 4)])).toBe(5);
    expect(nextCueNumber([cue('a', 2.5)])).toBe(3);
  });

  it('puts a duplicate halfway to the next cue, or at the end', () => {
    const cues = [cue('a', 1), cue('b', 2), cue('c', 3)];
    expect(numberAfter(cues, 1)).toBe(1.5);
    expect(numberAfter(cues, 3)).toBe(4);
    expect(numberAfter([cue('a', 1), cue('b', 1.0005)], 1)).toBe(2); // out of decimals: end of list
  });

  it('formats and finds numbers', () => {
    expect(formatNumber(3)).toBe('3');
    expect(formatNumber(2.1250001)).toBe('2.125');
    expect(formatNumber(NaN)).toBe('—');
    expect(isNumberTaken([cue('a', 1), cue('b', 2)], 2)).toBe(true);
    expect(isNumberTaken([cue('a', 1), cue('b', 2)], 2, 'b')).toBe(false);
    expect(sortedCues([cue('b', 2), cue('a', 1)]).map((c) => c.id)).toEqual(['a', 'b']);
  });
});

describe('swapSteps', () => {
  /** The engine's rule for cue.set: a number that another cue holds is refused. */
  function run(cues: CueDoc[], steps: CueDoc[]): CueDoc[] {
    let state = cues;
    for (const step of steps) {
      expect(state.some((c) => c.id !== step.id && c.number === step.number)).toBe(false);
      state = state.map((c) => (c.id === step.id ? step : c));
    }
    return state;
  }

  const cues = [cue('a', 1, { fade: 1 }), cue('b', 2, { fade: 2 }), cue('c', 4, { fade: 3 })];

  it('swaps with the next cue without ever holding a number twice', () => {
    const result = sortedCues(run(cues, swapSteps(cues, 'a', 1)));
    expect(result.map((c) => c.id)).toEqual(['b', 'a', 'c']);
    expect(result.map((c) => c.number)).toEqual([1, 2, 4]);
    expect(result.find((c) => c.id === 'a')).toMatchObject({ fade: 1, name: 'Cue 1' }); // everything but the number survives
  });

  it('swaps with the previous cue, also when the list is not in order or has gaps', () => {
    const shuffled = [cues[2]!, cues[0]!, cues[1]!];
    const result = sortedCues(run(shuffled, swapSteps(shuffled, 'c', -1)));
    expect(result.map((c) => c.id)).toEqual(['a', 'c', 'b']);
    expect(result.map((c) => c.number)).toEqual([1, 2, 4]);
  });

  it('does nothing at the ends or for an unknown id', () => {
    expect(swapSteps(cues, 'a', -1)).toEqual([]);
    expect(swapSteps(cues, 'c', 1)).toEqual([]);
    expect(swapSteps(cues, 'zzz', 1)).toEqual([]);
  });
});

describe('parseTrigger', () => {
  it('treats empty text as no trigger', () => {
    expect(parseTrigger('')).toEqual({ ok: true, value: null });
    expect(parseTrigger('   ')).toEqual({ ok: true, value: null });
  });

  it('pads, defaults the rate to 25 and spells rates the way the engine parses them', () => {
    expect(parseTrigger('1:2:3:4')).toEqual({ ok: true, value: '01:02:03:04@25' });
    expect(parseTrigger('00:01:30:00@24')).toEqual({ ok: true, value: '00:01:30:00@24' });
    expect(parseTrigger('00:00:10:29@29.97df')).toEqual({ ok: true, value: '00:00:10:29@29.97 DF' });
    expect(parseTrigger('00:00:10:29 @ 29.97 NDF')).toEqual({ ok: true, value: '00:00:10:29@29.97 NDF' }); // what the engine shows back
    expect(parseTrigger('00:01:00;02@29.97DF')).toEqual({ ok: true, value: '00:01:00:02@29.97 DF' });
    expect(parseTrigger('23:59:59:29@30')).toEqual({ ok: true, value: '23:59:59:29@30' });
  });

  it('rejects malformed text, unknown rates and out-of-range fields', () => {
    for (const bad of ['10', '00:00:10', '00:00:10:00@', 'a:b:c:d', '00:00:10:00@25@25']) expect(parseTrigger(bad).ok).toBe(false);
    expect(parseTrigger('00:00:10:00@50')).toMatchObject({ ok: false, error: expect.stringContaining('Unknown rate') });
    expect(parseTrigger('24:00:00:00')).toMatchObject({ ok: false });
    expect(parseTrigger('00:60:00:00')).toMatchObject({ ok: false });
    expect(parseTrigger('00:00:60:00')).toMatchObject({ ok: false });
    expect(parseTrigger('00:00:00:25@25')).toMatchObject({ ok: false, error: 'Frames go to 24 at 25 fps' });
    expect(parseTrigger('00:00:00:24@24')).toMatchObject({ ok: false });
    expect(parseTrigger('00:00:00:29@25')).toMatchObject({ ok: false });
  });
});

describe('cue rows', () => {
  it('summarises a cue with dashes for the optional fields', () => {
    expect(cueRowText(cue('a', 2.5, { fade: 1.5, trigger: '00:00:10:00@25', follow: 3, values: [{ fixture: 'Master', parameter: 'intensity', raw: 1 }] }))).toEqual({
      number: '2.5', fade: '1.5 s', trigger: '00:00:10:00@25', follow: '3 s', values: '1',
    });
    expect(cueRowText(cue('a', 1, { trigger: null, follow: null }))).toMatchObject({ trigger: '—', follow: '—', values: '0' });
  });

  it('labels a row for assistive technology', () => {
    expect(cueRowLabel(cue('a', 3, { name: 'Intro', fade: 2, follow: 5 }), 'next')).toBe('Cue 3, Intro, fade 2 s, follow 5 s, 0 values, next');
    expect(cueRowLabel(cue('a', 1, { name: '', trigger: '00:00:01:00@25' }), null)).toBe('Cue 1, unnamed, fade 0 s, trigger 00:00:01:00@25, 0 values');
  });

  it('marks the live current and next cue by number', () => {
    const live = { current: 2, currentName: 'x', next: 3, nextName: 'y', fading: false, count: 3 };
    expect(cueStatus(cue('a', 2), live)).toBe('current');
    expect(cueStatus(cue('b', 3), live)).toBe('next');
    expect(cueStatus(cue('c', 1), live)).toBeNull();
    expect(cueStatus(cue('c', 1), { ...live, current: null, next: null })).toBeNull();
  });
});

describe('fixtures and parameters', () => {
  const patch: PatchEntry[] = ['Layer 1', 'Output 10', 'Master', 'Output 2', 'Output 1'].map((fixture) => ({ fixture, universe: 'artnet:0.0.0', address: 1 }));

  it('lists layers, the master and the patched outputs in numeric order', () => {
    expect(fixtureNames(2, patch)).toEqual(['Layer 1', 'Layer 2', 'Master', 'Output 1', 'Output 2', 'Output 10']);
    expect(fixtureNames(0, [])).toEqual(['Master']);
    expect(fixtureNames(NaN, [])).toEqual(['Master']);
  });

  it('maps fixture names to types and types to specs', () => {
    expect(['Layer 3', 'Master', 'Output 2', 'Layers', 'Layer', 'Output'].map(fixtureType)).toEqual(['layer', 'master', 'output', null, null, null]);
    expect(specsFor(map, 'Layer 3')).toBe(map.modes.layer);
    expect(specsFor(map, 'Master')).toBe(map.modes.master);
    expect(specsFor(null, 'Layer 3')).toEqual([]);
    expect(specsFor(map, 'Spot 1')).toEqual([]);
  });

  it('groups specs in order of first appearance', () => {
    expect(groupSpecs(map.modes.layer).map((g) => [g.group, g.specs.map((s) => s.key)])).toEqual([['Output', ['intensity']], ['Media', ['playMode']]]);
    expect(groupSpecs([{ ...control, group: undefined }])).toEqual([{ group: '', specs: [{ ...control, group: undefined }] }]);
  });
});

describe('valueControl', () => {
  it('offers band names for banded parameters and selects the band holding the value', () => {
    const c = valueControl(playMode, 20);
    expect(c).toEqual({ kind: 'select', options: [{ label: 'Loop fwd', raw: 0 }, { label: 'Loop rev', raw: 16 }, { label: 'Once hold', raw: 32 }], selected: 16, caption: 'Play mode · raw 20' });
    expect(valueControl(playMode, 0)).toMatchObject({ selected: 0 });
    expect(valueControl(playMode, 47)).toMatchObject({ selected: 32 });
  });

  it('selects nothing for a value outside every band (the channel map\'s "rest = ...")', () => {
    expect(valueControl(playMode, 200)).toMatchObject({ kind: 'select', selected: null });
  });

  it('gives a number range from the bit depth, and the wide range for an unknown parameter', () => {
    expect(valueControl(control, 0)).toEqual({ kind: 'number', min: 0, max: 255, caption: 'Control · 0–255' });
    expect(valueControl(intensity, 0)).toEqual({ kind: 'number', min: 0, max: 65535, caption: 'Intensity · 0–65535' });
    expect(valueControl(undefined, 0)).toEqual({ kind: 'number', min: 0, max: 65535, caption: 'raw value' });
  });
});

describe('cue values', () => {
  it('starts a new value on the first parameter of the first fixture', () => {
    expect(newValue(map, ['Layer 1', 'Master'])).toEqual({ fixture: 'Layer 1', parameter: 'intensity', raw: 0 });
    expect(newValue(null, [])).toEqual({ fixture: 'Master', parameter: 'intensity', raw: 0 });
  });

  it('keeps the parameter and value when the new fixture has it', () => {
    expect(retargetValue(map, { fixture: 'Layer 1', parameter: 'intensity', raw: 30000, fade: 2 }, { fixture: 'Master' })).toEqual({ fixture: 'Master', parameter: 'intensity', raw: 30000, fade: 2 });
  });

  it('falls back to the first parameter at its default when the new fixture lacks it', () => {
    expect(retargetValue(map, { fixture: 'Layer 1', parameter: 'playMode', raw: 40 }, { fixture: 'Master' })).toEqual({ fixture: 'Master', parameter: 'intensity', raw: 0 });
  });

  it('starts a changed parameter at its default and clamps a kept value into the range', () => {
    expect(retargetValue(map, { fixture: 'Layer 1', parameter: 'intensity', raw: 999 }, { parameter: 'playMode' })).toEqual({ fixture: 'Layer 1', parameter: 'playMode', raw: 0 });
    expect(retargetValue(map, { fixture: 'Master', parameter: 'control', raw: 255 }, { fixture: 'Output 1' })).toEqual({ fixture: 'Output 1', parameter: 'control', raw: 255 });
    expect(retargetValue(map, { fixture: 'Layer 1', parameter: 'intensity', raw: 60000 }, { fixture: 'Output 1' }).raw).toBe(60000);
  });

  it('keeps the key without a channel map', () => {
    expect(retargetValue(null, { fixture: 'Layer 1', parameter: 'x', raw: 5 }, { fixture: 'Master' })).toEqual({ fixture: 'Master', parameter: 'x', raw: 5 });
  });

  it('sets or removes the per-value fade', () => {
    const v = { fixture: 'Master', parameter: 'intensity', raw: 1 };
    expect(withFade(v, 2.5)).toEqual({ ...v, fade: 2.5 });
    expect('fade' in withFade({ ...v, fade: 2 }, null)).toBe(false);
    expect(withFade({ ...v, fade: 2 }, 0)).toEqual({ ...v, fade: 0 });
  });
});

describe('timecode and OSC wording', () => {
  it('maps the clock state to a badge', () => {
    expect(['locked', 'freewheel', 'lost', 'off'].map((s) => timecodeBadge(s as 'off').tone)).toEqual(['green', 'yellow', 'red', 'off']);
    expect(timecodeBadge('freewheel').label).toBe('Freewheel');
  });

  it('describes the source, device and rate', () => {
    expect(timecodeSource({ state: 'locked', source: 'ltc', device: 'Scarlett 2i2', rate: '25' })).toBe('LTC · Scarlett 2i2 · 25 fps');
    expect(timecodeSource({ state: 'freewheel', source: 'mtc', device: '', rate: '29.97 DF' })).toBe('MTC · 29.97 DF');
    expect(timecodeSource({ state: 'off', source: '', device: '', rate: '25' })).toBe('No source');
  });

  it('shows the time of an OSC message as local hh:mm:ss', () => {
    expect(formatClock(new Date(2026, 9, 23, 14, 5, 9).getTime() / 1000)).toBe('14:05:09');
    expect(formatClock(new Date(2026, 0, 1, 0, 0, 0, 900).getTime() / 1000)).toBe('00:00:00');
    expect(formatClock(NaN)).toBe('--:--:--');
  });
});

describe('timecode offset text', () => {
  it('shows frames and the equivalent seconds', () => {
    expect(offsetText(25, '25')).toBe('+25 frames = +1.00 s at 25 fps');
    expect(offsetText(-1, '24')).toBe('-1 frame = -0.04 s at 24 fps');
    expect(offsetText(30, '29.97 DF')).toBe('+30 frames = +1.00 s at 29.97 fps');
    expect(offsetText(0, '')).toBe('0 frames = 0.00 s assuming 25 fps until a source locks');
    expect(rateFps('30')).toBe(30);
  });
});
