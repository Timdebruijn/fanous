// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { PatchEntry, UniverseInfo, UniverseSettingsDoc } from './docs';
import {
  buildCells, buildFixtures, cellLabel, compareUniverse, defaultPair, fixturesText, frameValues, interfaceOptions, paramAt, paramName, parseUniverseName,
  parseChannelMap, rangeText, rowStatus, summarize, universeHealth, universeName, universeOptions, universeRows, universeSettings,
  type ChannelMap, type UniverseRow,
} from './patch-screen';

const spec = (name: string, key: string, channel: number, bits: 8 | 16 = 8) => ({ name, key, channel, bits });
const map: ChannelMap = {
  footprints: { layer: 64, master: 8, output: 8, keystone: 16 },
  modes: {
    layer: [spec('Opacity', 'opacity', 1, 16), spec('Volume', 'volume', 3), spec('Scale', 'scale', 10, 16)],
    master: [spec('Dimmer', 'dimmer', 1)],
    output: [],
    keystone: [spec('Top-left X', 'topLeftX', 1, 16)],
  },
};
const at = (fixture: string, universe: string, address: number): PatchEntry => ({ fixture, universe, address });
const live = (id: string): UniverseInfo => ({ id, active: false, packets: 0, source: '', ageSeconds: -1 });

describe('universe naming and lists', () => {
  it('shortens Art-Net and sACN ids and leaves others alone', () => {
    expect(universeName('artnet:0.0.1')).toBe('A 0.0.1');
    expect(universeName('sacn:3')).toBe('S 3');
    expect(universeName('other:7')).toBe('other:7');
  });

  it('sorts Art-Net before sACN and numerically', () => {
    const ids = ['sacn:10', 'sacn:2', 'artnet:0.0.10', 'artnet:0.0.2', 'artnet:0.1.0'];
    expect(ids.sort(compareUniverse)).toEqual(['artnet:0.0.2', 'artnet:0.0.10', 'artnet:0.1.0', 'sacn:2', 'sacn:10']);
  });

  it('builds a deduplicated, sorted option list with the standard universes', () => {
    const options = universeOptions([at('Layer 1', 'sacn:7', 1), at('Layer 2', 'artnet:0.0.1', 1)], [live('sacn:7'), live('artnet:2.0.0')]);
    expect(options).toEqual([
      'artnet:0.0.0', 'artnet:0.0.1', 'artnet:0.0.2', 'artnet:0.0.3', 'artnet:2.0.0',
      'sacn:1', 'sacn:2', 'sacn:3', 'sacn:4', 'sacn:7',
    ]);
  });

  it('reads per-universe settings, with the engine defaults for universes without an entry', () => {
    expect(universeSettings(undefined, 'artnet:0.0.0')).toEqual({
      id: 'artnet:0.0.0', protocol: 'artnet', interface: 'any', holdOnLoss: 'hold', lossTimeout: 2.5, sacnPriorityMode: 'highest', pair: 'sacn:1',
    });
    expect(universeSettings([], 'sacn:1')).toMatchObject({ protocol: 'sacn', pair: 'artnet:0.0.0' });
    const stored = { ...universeSettings(undefined, 'sacn:2'), holdOnLoss: 'zero' as const };
    expect(universeSettings([stored], 'sacn:2').holdOnLoss).toBe('zero');
  });

  it('maps pairs and parses universe names like the engine', () => {
    expect(defaultPair('artnet:0.0.0')).toBe('sacn:1');
    expect(defaultPair('artnet:1.2.3')).toBe(`sacn:${(1 << 8) + (2 << 4) + 3 + 1}`);
    expect(defaultPair('sacn:300')).toBe('artnet:1.2.11');
    expect(parseUniverseName('S 7')).toBe('sacn:7');
    expect(parseUniverseName(' a 0.0.1 ')).toBe('artnet:0.0.1');
    expect(parseUniverseName('sacn:9')).toBe('sacn:9');
    expect(parseUniverseName('x')).toBe('x');
  });

  it('offers every interface by name and address and marks an absent current one', () => {
    const list = [{ name: 'lo0', address: '127.0.0.1' }, { name: 'en0', address: '10.0.0.5' }];
    expect(interfaceOptions(list, 'any').map((o) => o.value)).toEqual(['any', 'lo0', '127.0.0.1', 'en0', '10.0.0.5']);
    expect(interfaceOptions(list, 'en5').at(-1)).toEqual({ value: 'en5', label: 'en5 (not present)' });
    expect(interfaceOptions(undefined, 'any')).toEqual([{ value: 'any', label: 'All interfaces' }]);
  });

  it('classifies universe health', () => {
    const base = { id: 'sacn:1', active: false, packets: 0, source: '', ageSeconds: 0 };
    expect(universeHealth({ ...base, active: true, packets: 1200, source: 'MA3' })).toEqual({ tone: 'green', text: '1200 packets · MA3' });
    expect(universeHealth({ ...base, ageSeconds: 1.26 })).toEqual({ tone: 'yellow', text: '1.3 s' });
    expect(universeHealth({ ...base, ageSeconds: 2.5 }).tone).toBe('yellow');
    expect(universeHealth({ ...base, ageSeconds: 2.6 })).toEqual({ tone: 'red', text: 'lost' });
    expect(universeHealth({ ...base, ageSeconds: 4 }, 5).tone).toBe('yellow');
    expect(universeHealth({ ...base, ageSeconds: -1 })).toEqual({ tone: 'yellow', text: 'never seen' });
    expect(universeHealth(undefined).tone).toBe('yellow');
  });
});

describe('buildFixtures', () => {
  it('lists layers (patched or not), Master, then outputs in numeric order, each with its Keystone', () => {
    const rows = buildFixtures([at('Output 10', 'sacn:1', 100), at('Layer 2', 'artnet:0.0.0', 65), at('Output 2', 'sacn:1', 200)], 3, map, [10, 2]);
    expect(rows.map((r) => r.name)).toEqual(['Layer 1', 'Layer 2', 'Layer 3', 'Master', 'Output 2', 'Keystone 2', 'Output 10', 'Keystone 10']);
    expect(rows[5]).toMatchObject({ type: 'keystone', typeLabel: 'Keystone', footprint: 16, patched: false });
    const keystone = buildFixtures([at('Keystone 3', 'sacn:1', 9)], 0, null, [3]);
    expect(keystone.map((r) => [r.name, r.footprint, r.end])).toEqual([['Master', 8, 0], ['Output 3', 8, 0], ['Keystone 3', 16, 24]]);
    expect(paramAt(map, 'keystone', 2)).toMatchObject({ spec: { key: 'topLeftX' }, fine: true });
    expect(rows[0]).toMatchObject({ patched: false, address: 0, end: 0 });
    expect(rows[1]).toMatchObject({ patched: true, address: 65, end: 128, footprint: 64, typeLabel: 'Layer' });
    expect(rangeText(rows[1]!)).toBe('65–128');
    expect(rangeText(rows[0]!)).toBe('—');
  });

  it('falls back to 64/8/8 without a channel map and ignores layers above layerCount', () => {
    const rows = buildFixtures([at('Layer 1', 'artnet:0.0.0', 1), at('Master', 'artnet:0.0.0', 65), at('Layer 9', 'artnet:0.0.0', 1)], 2, null);
    expect(rows.map((r) => [r.name, r.footprint])).toEqual([['Layer 1', 64], ['Layer 2', 64], ['Master', 8]]);
    expect(rows.every((r) => r.collisions.length === 0)).toBe(true);
    expect(buildFixtures([], 0, null).map((r) => r.name)).toEqual(['Master']);
  });

  it('lists every output, patched or not, and no Output fixture without its output', () => {
    const rows = buildFixtures([at('Output 1', 'artnet:0.0.1', 9), at('Output 4', 'artnet:0.0.1', 33)], 0, map, [1, 5]);
    expect(rows.map((r) => [r.name, r.patched])).toEqual([['Master', false], ['Output 1', true], ['Keystone 1', false], ['Output 5', false], ['Keystone 5', false]]);
  });

  it('treats address 0 as unpatched', () => {
    const [row] = buildFixtures([at('Layer 1', 'artnet:0.0.0', 0)], 1, map);
    expect(row).toMatchObject({ patched: false, universe: 'artnet:0.0.0', address: 0 });
    expect(rowStatus(row!)).toEqual({ tone: 'faint', text: 'unpatched · no console control' });
  });

  it('finds collisions per universe with the contested range, and none for touching ranges', () => {
    const rows = buildFixtures(
      [at('Layer 1', 'artnet:0.0.0', 1), at('Layer 2', 'artnet:0.0.0', 40), at('Layer 3', 'artnet:0.0.0', 104), at('Layer 4', 'sacn:1', 1)],
      4, map);
    expect(rows[0]!.collisions).toEqual([{ with: 'Layer 2', from: 40, to: 64 }]);
    expect(rows[1]!.collisions).toEqual([{ with: 'Layer 1', from: 40, to: 64 }]); // Layer 2 ends at 103, Layer 3 starts at 104
    expect(rows[2]!.collisions).toEqual([]);
    expect(rows[3]!.collisions).toEqual([]); // same address, other universe
    expect(rowStatus(rows[0]!)).toEqual({ tone: 'bad', text: 'collides with Layer 2 · 40–64' });
    expect(rowStatus(rows[2]!)).toEqual({ tone: 'ok', text: 'ok' });
    expect(summarize(rows)).toEqual({ fixtures: 5, universes: 2, collisions: 1 });
  });

  it('counts every colliding pair and mentions the extra ones', () => {
    const rows = buildFixtures([at('Layer 1', 'sacn:1', 1), at('Layer 2', 'sacn:1', 1), at('Master', 'sacn:1', 60)], 2, map);
    expect(summarize(rows).collisions).toBe(3);
    expect(rowStatus(rows[0]!).text).toBe('collides with Layer 2 · 1–64 (+1)');
  });

  it('flags a range past channel 512 and clips its collisions at 512', () => {
    const rows = buildFixtures([at('Layer 1', 'artnet:0.0.0', 500), at('Master', 'artnet:0.0.0', 505)], 1, map);
    expect(rows[0]).toMatchObject({ end: 563, exceeds: true });
    expect(rows[1]).toMatchObject({ end: 512, exceeds: false });
    expect(rows[0]!.collisions).toEqual([{ with: 'Master', from: 505, to: 512 }]);
    expect(rowStatus(rows[0]!).text).toBe('collides with Master · 505–512; exceeds universe');
    const [alone] = buildFixtures([at('Layer 1', 'artnet:0.0.0', 449)], 1, map);
    expect(alone!.exceeds).toBe(false); // 449 + 64 - 1 = 512
    expect(rowStatus(buildFixtures([at('Layer 1', 'artnet:0.0.0', 450)], 1, map)[0]!)).toEqual({ tone: 'bad', text: 'exceeds universe' });
  });
});

describe('paramAt', () => {
  it('finds coarse, fine and plain channels and gaps', () => {
    expect(paramAt(map, 'layer', 1)).toMatchObject({ spec: { key: 'opacity' }, fine: false });
    expect(paramAt(map, 'layer', 2)).toMatchObject({ spec: { key: 'opacity' }, fine: true });
    expect(paramAt(map, 'layer', 3)).toMatchObject({ spec: { key: 'volume' }, fine: false });
    expect(paramAt(map, 'layer', 4)).toBeNull();
    expect(paramAt(map, 'layer', 11)).toMatchObject({ spec: { key: 'scale' }, fine: true });
    expect(paramAt(map, 'output', 1)).toBeNull();
    expect(paramAt(null, 'layer', 1)).toBeNull();
  });
});

describe('buildCells', () => {
  const rows = buildFixtures([at('Layer 1', 'artnet:0.0.0', 1), at('Master', 'artnet:0.0.0', 60), at('Layer 2', 'sacn:1', 449)], 2, map);

  it('always yields 512 cells and none for no universe', () => {
    expect(buildCells(rows, 'artnet:0.0.0', map)).toHaveLength(512);
    expect(buildCells(rows, null, map).every((c) => !c.owner)).toBe(true);
  });

  it('assigns owners, relative channels, parameters and collisions', () => {
    const cells = buildCells(rows, 'artnet:0.0.0', map);
    expect(cells[0]).toMatchObject({ ch: 1, owners: ['Layer 1'], rel: 1, collision: false });
    expect(paramName(cells[0]!)).toBe('Opacity');
    expect(paramName(cells[1]!)).toBe('Opacity (fine)');
    expect(cellLabel(cells[1]!)).toBe('Channel 2 · Layer 1 · Opacity (fine)');
    expect(cellLabel(cells[3]!)).toBe('Channel 4 · Layer 1 · ch 4'); // gap in the map
    expect(cells[59]).toMatchObject({ ch: 60, owners: ['Layer 1', 'Master'], collision: true, rel: 60 });
    expect(cellLabel(cells[59]!)).toBe('Channel 60 · collision · Layer 1, Master');
    expect(cells[64]).toMatchObject({ ch: 65, owners: ['Master'], rel: 6 }); // Master 60..67
    expect(cells[67]!.owner).toBeNull();
    expect(cellLabel(cells[67]!)).toBe('Channel 68 · unpatched');
    // 64 (Layer 1) + 8 (Master) channels, 5 of them (60..64) claimed twice
    expect(cells.filter((c) => c.owner).length).toBe(64 + 8 - 5);
    expect(cells.filter((c) => c.collision).map((c) => c.ch)).toEqual([60, 61, 62, 63, 64]);
  });

  it('only shows the fixtures of the requested universe and clips at 512', () => {
    const cells = buildCells(rows, 'sacn:1', map);
    expect(cells.filter((c) => c.owner).length).toBe(64); // 449..512
    expect(cells[511]).toMatchObject({ ch: 512, owners: ['Layer 2'], rel: 64 });
    expect(cells[448]!.rel).toBe(1);
    expect(buildCells(rows, 'sacn:2', map).every((c) => !c.owner)).toBe(true);
    const past = buildFixtures([at('Layer 1', 'sacn:1', 500)], 1, map);
    expect(buildCells(past, 'sacn:1', map).filter((c) => c.owner)).toHaveLength(13);
  });
});

describe('frames and channel map', () => {
  it('pads and cuts monitor frames to 512 slots', () => {
    const exact = new Uint8Array(512).fill(7);
    expect(frameValues(exact)).toBe(exact);
    const short = frameValues(Uint8Array.of(1, 2, 3));
    expect(short).toHaveLength(512);
    expect([...short.subarray(0, 4)]).toEqual([1, 2, 3, 0]);
    expect(frameValues(new Uint8Array(600).fill(9))).toHaveLength(512);
  });

  it('accepts the engine document and rejects other shapes', () => {
    expect(parseChannelMap(map)).toBe(map);
    expect(parseChannelMap(null)).toBeNull();
    expect(parseChannelMap({ footprints: { layer: 64 }, modes: {} })).toBeNull();
    expect(parseChannelMap({ footprints: map.footprints, modes: { layer: [], master: [] } })).toBeNull();
  });
});

describe('universes panel', () => {
  const standard = [
    ...Array.from({ length: 8 }, (_, i) => at(`Layer ${i + 1}`, 'artnet:0.0.0', 1 + 64 * i)),
    at('Master', 'artnet:0.0.1', 1), at('Output 1', 'artnet:0.0.1', 9), at('Output 2', 'artnet:0.0.1', 17), at('Keystone 2', 'artnet:0.0.1', 89),
  ];
  const heard = (id: string, ageSeconds = 0.4): UniverseInfo => ({ ...live(id), ageSeconds, packets: 12, source: '10.0.0.5' });
  const stored = (id: string, change: Partial<UniverseSettingsDoc> = {}): UniverseSettingsDoc => ({ ...universeSettings(undefined, id), ...change });
  const texts = (out: UniverseRow[]) => out.map((u) => [universeName(u.id), u.text, u.tone]);

  it('compresses consecutive fixture numbers per type', () => {
    const rows = buildFixtures(standard, 8, null, [1, 2]);
    expect(fixturesText(rows.filter((r) => r.universe === 'artnet:0.0.0'))).toBe('Layers 1–8');
    expect(fixturesText(rows.filter((r) => r.universe === 'artnet:0.0.1' && r.patched))).toBe('Master, Outputs 1–2, Keystone 2');
    const some = buildFixtures([at('Layer 1', 'sacn:1', 1), at('Layer 2', 'sacn:1', 65), at('Layer 3', 'sacn:1', 129), at('Layer 5', 'sacn:1', 257), at('Layer 7', 'sacn:1', 385), at('Master', 'sacn:1', 449)], 8, null);
    expect(fixturesText(some.filter((r) => r.patched))).toBe('Layers 1–3, 5, 7, Master');
    expect(fixturesText([])).toBe('');
  });

  it('lists patched, heard and stored universes, sorted, with what is on each', () => {
    const out = universeRows(buildFixtures(standard, 8, null, [1, 2]), [live('artnet:0.0.0'), heard('sacn:9')], [stored('artnet:0.0.7', { holdOnLoss: 'zero', interface: 'en0' })]);
    expect(texts(out)).toEqual([
      ['A 0.0.0', 'Layers 1–8', 'ok'],
      ['A 0.0.1', 'Master, Outputs 1–2, Keystone 2', 'ok'],
      ['A 0.0.7', 'not used', 'faint'],
      ['S 9', 'heard, nothing patched', 'warn'],
    ]);
    expect(out[0]!.line).toBe('Art-Net · All interfaces · Hold last values');
    expect(out[2]!.line).toBe('Art-Net · en0 · Go to zero');
    expect(out[0]!.health).toEqual({ tone: 'yellow', text: 'never seen' });
    expect(out[3]!.health.text).toBe('0.4 s');
  });

  it('shows a patched universe with stored settings once, with those settings', () => {
    const out = universeRows(buildFixtures(standard, 8, null), [], [stored('artnet:0.0.0', { holdOnLoss: 'internal', lossTimeout: 5 })]);
    expect(out.filter((u) => u.id === 'artnet:0.0.0').map((u) => [u.text, u.settings.holdOnLoss, u.settings.lossTimeout, u.line])).toEqual([
      ['Layers 1–8', 'internal', 5, 'Art-Net · All interfaces · UI and cues take over'],
    ]);
  });

  it('warns about a stored universe a console sends to with nothing patched', () => {
    expect(texts(universeRows([], [heard('artnet:0.0.5')], [stored('artnet:0.0.5', { holdOnLoss: 'zero' })]))).toEqual([['A 0.0.5', 'heard, nothing patched', 'warn']]);
  });

  it('names the wire universe that feeds a patched one by its pair instead of warning', () => {
    const rows = buildFixtures(standard, 8, null);
    const out = universeRows(rows, [heard('artnet:0.0.0'), heard('sacn:7')], [stored('artnet:0.0.0', { protocol: 'sacn', pair: 'sacn:7' })]);
    expect(texts(out)).toEqual([['A 0.0.0', 'Layers 1–8', 'ok'], ['A 0.0.1', 'Master', 'ok'], ['S 7', 'feeds A 0.0.0', 'ok']]);
    // Art-Net + sACN on its default pair
    const both = universeRows(rows, [heard('sacn:2')], [stored('artnet:0.0.1', { protocol: 'both' })]);
    expect(both.find((u) => u.id === 'sacn:2')?.text).toBe('feeds A 0.0.1');
  });

  it('leaves out never heard universes, unpatched fixtures and layers above the count', () => {
    const out = universeRows(buildFixtures([at('Layer 1', 'artnet:0.0.2', 0), at('Layer 9', 'artnet:0.0.3', 1)], 8, null), [live('artnet:0.0.3'), live('artnet:0.0.2')], undefined);
    expect(out).toEqual([]);
  });

  it('drops a heard, unused universe after its loss timeout and never shows red without fixtures', () => {
    const rows = buildFixtures(standard, 8, null);
    expect(universeRows(rows, [heard('sacn:9', 2.4)], undefined).map((u) => u.id)).toContain('sacn:9');
    expect(universeRows(rows, [heard('sacn:9', 30)], undefined).map((u) => u.id)).not.toContain('sacn:9');
    expect(universeRows(rows, [heard('sacn:9', 9)], [stored('sacn:9', { lossTimeout: 10 })]).find((u) => u.id === 'sacn:9')?.text).toBe('heard, nothing patched');
    // stored and silent: stays, not used, yellow
    const silent = universeRows(rows, [heard('sacn:9', 30)], [stored('sacn:9')]).find((u) => u.id === 'sacn:9')!;
    expect([silent.text, silent.health]).toEqual(['not used', { tone: 'yellow', text: 'silent' }]);
    // a patched universe that is lost stays red
    expect(universeRows(rows, [heard('artnet:0.0.0', 30)], undefined)[0]!.health).toEqual({ tone: 'red', text: 'lost' });
  });

  it('offers every universe of the panel in the fixture universe select', () => {
    const patch = [...standard, at('Layer 3', 'sacn:40', 0)];
    const lives = [heard('sacn:9'), live('artnet:3.0.0'), heard('sacn:7')];
    const settings = [stored('artnet:0.0.9'), stored('artnet:0.0.0', { protocol: 'sacn', pair: 'sacn:7' })];
    const known = universeRows(buildFixtures(patch, 8, null, [1, 2]), lives, settings).map((u) => u.id);
    expect(known).toContain('artnet:0.0.9');
    const options = universeOptions(patch, lives, settings);
    expect(known.filter((id) => !options.includes(id))).toEqual([]);
  });
});
