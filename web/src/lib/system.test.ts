// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { ReadinessItemDoc } from './docs';
import {
  ageText, droppedTone, filterLines, formatClock, headerCaption, memoryText, metricTiles, outputTone, parseMetrics, parseOpenRoles,
  pushHistory, readinessBadge, readinessSummary, sparkline, stampText, thermalTone,
} from './system';

const item = (state: ReadinessItemDoc['state'], acknowledged = false): ReadinessItemDoc => ({ id: state, title: state, state, detail: '', fix: '', acknowledged });

describe('clocks and captions', () => {
  it('formats uptime as h:mm:ss', () => {
    expect(formatClock(0)).toBe('0:00:00');
    expect(formatClock(59.9)).toBe('0:00:59');
    expect(formatClock(3723)).toBe('1:02:03');
    expect(formatClock(100 * 3600)).toBe('100:00:00');
    expect(formatClock(-5)).toBe('0:00:00');
    expect(formatClock(Number.NaN)).toBe('0:00:00');
  });

  it('shows a check stamp in local hh:mm:ss, and never for 0', () => {
    expect(stampText(0)).toBe('never');
    expect(stampText(new Date(2026, 9, 23, 13, 5, 9).getTime() / 1000)).toBe('13:05:09');
  });

  it('leaves out header parts the engine has not published', () => {
    expect(headerCaption({ chip: 'M4 Max', os: 'macOS 27.0', version: '0.7.0', uptimeSeconds: 3723 })).toBe('M4 Max · macOS 27.0 · engine 0.7.0 · up 1:02:03');
    expect(headerCaption({ chip: '', os: '', version: '', uptimeSeconds: 0 })).toBe('up 0:00:00');
  });

  it('formats ages and memory', () => {
    expect(ageText(-1)).toBe('never');
    expect(ageText(0.04)).toBe('0.0 s');
    expect(ageText(12.34)).toBe('12.3 s');
    expect(memoryText(0.623, 64)).toBe('62 % free · 64 GB');
    expect(memoryText(2, 0)).toBe('100 % free');
  });
});

describe('machine tones', () => {
  it('colours thermal state: only serious and critical are red', () => {
    expect(['nominal', 'fair', 'serious', 'critical', '?'].map(thermalTone)).toEqual(['green', 'yellow', 'red', 'red', 'yellow']);
  });

  it('colours output state: lost is the only red', () => {
    expect(['bound', 'lost', 'unassigned'].map(outputTone)).toEqual(['green', 'red', 'off']);
  });
});

describe('readiness', () => {
  it('maps every item state to a dot and a word', () => {
    expect(readinessBadge(item('ok'))).toEqual({ tone: 'green', label: 'ok' });
    expect(readinessBadge(item('fail'))).toEqual({ tone: 'red', label: 'failed' });
    expect(readinessBadge(item('fail', true))).toEqual({ tone: 'yellow', label: 'acknowledged' });
    expect(readinessBadge(item('manual'))).toEqual({ tone: 'off', label: 'manual' });
    expect(readinessBadge(item('hard'))).toEqual({ tone: 'red', label: 'blocking' });
  });

  it('is not ready on a hard failure or an unacknowledged failure, ready once acknowledged', () => {
    expect(readinessSummary([item('ok'), item('manual')], 100).status).toBe('ready');
    expect(readinessSummary([item('ok'), item('fail')], 100)).toMatchObject({ status: 'notReady', blocking: [{ id: 'fail' }] });
    expect(readinessSummary([item('ok'), item('hard')], 100).status).toBe('notReady');
    expect(readinessSummary([item('fail', true), item('manual')], 100).status).toBe('ready');
    expect(readinessSummary([item('hard', true)], 100).status).toBe('notReady');
  });

  it('is unchecked until the first run, but a known failure still blocks', () => {
    expect(readinessSummary([], 0).status).toBe('unchecked');
    expect(readinessSummary([item('fail')], 0).status).toBe('notReady');
  });
});

describe('metrics', () => {
  const full = {
    frames: 60, missed: 1, late: 2, textureMisses: 3, cpuMsP50: 1, cpuMsP99: 2.25, cpuMsMax: 3, gpuMsP50: 0.5, gpuMsP99: 4, gpuMsMax: 8,
    dmxToPhotonMsP50: 12, dmxToPhotonMsP99: 20.04, dmxSamples: 37, windowSeconds: 1, clients: 2, lagging: 1, showMode: true, uptimeSeconds: 99,
    audio: { callbacks: 100, underruns: 1, corrections: 4, maxDriftMs: 1.234 }, preview: { framesIn: 30, framesOut: 29, skipped: 1 },
  };

  it('parses the engine summary', () => {
    expect(parseMetrics(full)).toEqual(full);
  });

  it('falls back to defaults for missing, malformed or non-finite values', () => {
    const m = parseMetrics({ frames: 'x', missed: null, late: Number.POSITIVE_INFINITY, audio: 'no', preview: null, showMode: 'yes' });
    expect(m).toMatchObject({ frames: 0, missed: 0, late: 0, cpuMsMax: 0, audio: null, preview: null, showMode: false });
    expect(parseMetrics(null).frames).toBe(0);
    expect(parseMetrics('nope').preview).toBeNull();
    expect(parseMetrics({ audio: {} }).audio).toEqual({ callbacks: 0, underruns: 0, corrections: 0, maxDriftMs: 0 });
  });

  it('builds the tiles with the DMX sample count and the optional groups', () => {
    const tiles = Object.fromEntries(metricTiles(parseMetrics(full), true).map((t) => [t.id, t]));
    expect(tiles.fps!.value).toBe('60');
    expect(tiles.dropped).toMatchObject({ value: '3', tone: 'red' });
    expect(tiles.gpu!.value).toBe('0.5 / 4.0 / 8.0');
    expect(tiles.cpu!.value).toBe('1.0 / 2.3 / 3.0');
    expect(tiles.dmx).toMatchObject({ value: '12.0 / 20.0 (37)', note: 'display scan-out not included' });
    expect(tiles.clients).toMatchObject({ value: '2', tone: 'yellow' });
    expect(tiles.preview!.value).toBe('30 / 29 / 1');
    expect(tiles.audio).toMatchObject({ value: '1 / 4 / 1.2 ms', tone: 'yellow' });
  });

  it('normalises fps to the window and shows dashes without data or subsystems', () => {
    expect(metricTiles(parseMetrics({ frames: 30, windowSeconds: 0.5 }), false)[0]!.value).toBe('60');
    expect(metricTiles(parseMetrics({ frames: 59 }), false)[0]!.value).toBe('59');
    expect(metricTiles(null, true).every((t) => t.value === '—' && t.tone === '')).toBe(true);
    const bare = Object.fromEntries(metricTiles(parseMetrics({}), false).map((t) => [t.id, t]));
    expect(bare.dmx!.value).toBe('— (0)');
    expect(bare.preview).toMatchObject({ value: '—', caption: 'preview frames · no encoder running' });
    expect(bare.audio!.caption).toBe('audio · no mixer running');
  });

  it('flags dropped frames red only in show mode', () => {
    expect(droppedTone(0, true)).toBe('');
    expect(droppedTone(2, true)).toBe('red');
    expect(droppedTone(2, false)).toBe('yellow');
  });
});

describe('sparkline', () => {
  it('scales to the data inside 2 px of padding', () => {
    expect(sparkline([0, 5, 10], 100, 24)).toEqual({ points: '0.0,22.0 50.0,12.0 100.0,2.0', refY: null });
  });

  it('keeps a calm trace low under a ceiling and reports the ceiling line', () => {
    const { points, refY } = sparkline([2, 2], 10, 24, 10);
    expect(points).toBe('0.0,18.0 10.0,18.0');
    expect(refY).toBe(2);
    expect(sparkline([20], 10, 24, 10).refY).toBe(12);
  });

  it('draws nothing for fewer than two values and survives all zeros', () => {
    expect(sparkline([], 100, 24).points).toBe('');
    expect(sparkline([3], 100, 24).points).toBe('');
    expect(sparkline([0, 0, -1], 100, 24).points).toBe('0.0,22.0 50.0,22.0 100.0,22.0');
  });

  it('keeps the last 60 polls', () => {
    const history = Array.from({ length: 80 }, (_, i) => i).reduce((h, v) => pushHistory(h, v), [] as number[]);
    expect(history).toHaveLength(60);
    expect(history[0]).toBe(20);
    expect(history.at(-1)).toBe(79);
  });
});

describe('log filter', () => {
  const log = 'a Start\nb error: disk\nc ERROR: net\nd ok\n';

  it('passes everything without a query and ignores the trailing newline', () => {
    expect(filterLines(log, '')).toEqual({ text: 'a Start\nb error: disk\nc ERROR: net\nd ok', shown: 4, total: 4 });
  });

  it('matches case-insensitively and counts what is hidden', () => {
    expect(filterLines(log, 'error')).toEqual({ text: 'b error: disk\nc ERROR: net', shown: 2, total: 4 });
    expect(filterLines(log, 'zzz')).toEqual({ text: '', shown: 0, total: 4 });
  });

  it('handles an empty log', () => {
    expect(filterLines('', 'x')).toEqual({ text: '', shown: 0, total: 0 });
  });
});

describe('session', () => {
  it('reads the open roles in role order and ignores junk', () => {
    expect(parseOpenRoles({ role: 'monitor', open: ['programmer', 'monitor', 'root'] })).toEqual(['monitor', 'programmer']);
    expect(parseOpenRoles({ role: null, open: [] })).toEqual([]);
    expect(parseOpenRoles(null)).toEqual([]);
    expect(parseOpenRoles({ open: 'monitor' })).toEqual([]);
  });
});
