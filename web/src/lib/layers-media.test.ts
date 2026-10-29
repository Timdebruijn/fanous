// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { LayerStatus, ResolvedParameter } from './docs';
import { GENERATORS, folderZeroItems, zeroCaption, layerState, mediaLine, mediaOptions, mediaPath, playSteps, policyName, type LibrarySnapshot } from './layers';

const layer = (over: Partial<LayerStatus> = {}): LayerStatus => ({ index: 1, folder: 3, file: 12, name: 'loop.mov', kind: 'movie', codec: 'HapY', width: 1920, height: 1080, fps: 25, frames: 100, frame: 0, error: null, ...over });

const library: LibrarySnapshot = {
  scannedAt: 1,
  folders: [
    { number: 3, name: '003_Intro', items: [{ folder: 3, file: 12, name: 'loop.mov', status: 'playable' }, { folder: 3, file: null, name: 'bad.mov', status: 'invalid' }] },
    { number: 1, name: 'Music', items: [{ folder: 1, file: 2, name: 'a.mov', status: 'playable' }, { folder: 1, file: 1, name: 'b.mov', status: 'unreadable' }] },
    { number: null, name: 'junk', items: [{ folder: 0, file: 4, name: 'x.mov' }] },
  ],
};

describe('layer status word', () => {
  it('names every state next to the dot', () => {
    expect(layerState(layer({ kind: 'missing' }))).toMatchObject({ dot: 'red', chip: 'MISSING FILE' });
    expect(layerState(layer({ error: 'decoder failed' }))).toMatchObject({ dot: 'red', chip: 'DECODER ERROR' });
    expect(layerState(layer({ kind: 'live' })).chip).toBe('LIVE');
    expect(layerState(layer()).chip).toBe('OK');
    expect(layerState(layer({ kind: 'none' })).chip).toBe('NO MEDIA');
    expect(layerState(undefined).chip).toBe('NO MEDIA');
  });
});

describe('source policy names', () => {
  it('uses plain words for the stored values', () => {
    expect(policyName('dmx')).toBe('Console only');
    expect(policyName('internal')).toBe('UI and cues only');
    expect(policyName('ltp')).toBe('Console + UI (latest wins)');
    expect(policyName('htp')).toBe('Console + UI (highest wins)');
    expect(policyName('other')).toBe('other');
  });
});

describe('media names', () => {
  it('writes folder and file with their names', () => {
    expect(mediaPath(library, 3, 12)).toBe('Folder 3 · Intro / 12 · loop.mov');
    expect(mediaPath(library, 3, 99)).toBeNull();
    expect(mediaPath(null, 3, 12)).toBeNull();
  });
  it('lists playable numbered items in numeric order', () => {
    expect(mediaOptions(library).map((o) => `${o.folder}/${o.file}`)).toEqual(['1/2', '3/12']);
  });
});

describe('folder 0 (B61)', () => {
  const servers = [
    { file: 151, app: 'Simple Server', server: '', running: false, gone: true as const },
    { file: 150, app: 'fanousd', server: 'Fanous – Canvas', running: true },
  ];
  it('lists the generators, then the Syphon servers by number with their state', () => {
    const items = folderZeroItems(servers);
    expect(items.slice(0, GENERATORS.length).map((i) => i.file)).toEqual(GENERATORS.map((g) => g.file));
    expect(items.slice(GENERATORS.length).map((i) => i.label)).toEqual(['150 · Syphon: fanousd/Fanous – Canvas', '151 · Syphon: Simple Server (not running)']);
    expect(items.at(-1)).toMatchObject({ kind: 'syphon', running: false, gone: true, name: 'Syphon: Simple Server' });
    expect(items.at(-2)).toMatchObject({ running: true, gone: false });
    expect(folderZeroItems(undefined)).toHaveLength(GENERATORS.length);
  });
  it('lists the cameras and capture cards, then the displays, before the Syphon servers (B73)', () => {
    const capture = {
      devices: [
        { file: 3, name: 'Cam Link 4K', running: false, gone: true as const },
        { file: 1, name: 'FaceTime HD Camera', running: true },
        { file: 2, name: 'iPhone Camera', running: false, inUse: true as const },
      ],
      screens: [{ file: 21, name: 'Built-in Retina Display', running: true }],
      permissions: { camera: 'granted' as const, screen: 'granted' as const },
    };
    const items = folderZeroItems(servers, capture).slice(GENERATORS.length);
    expect(items.map((i) => `${i.kind} ${i.label}`)).toEqual([
      'capture 1 · FaceTime HD Camera',
      'capture 2 · iPhone Camera (in use by another app)',
      'capture 3 · Cam Link 4K (not running)',
      'screen 21 · Built-in Retina Display',
      'syphon 150 · Syphon: fanousd/Fanous – Canvas',
      'syphon 151 · Syphon: Simple Server (not running)',
    ]);
    expect(items.map(zeroCaption)).toEqual([null, 'in use by another app', 'not seen since the engine started', null, null, 'not seen since the engine started']);
    expect(zeroCaption({ ...items[2], gone: false })).toBe('not running');
    // an engine without live.capture, or one with no devices: only generators and Syphon
    expect(folderZeroItems(servers, undefined).map((i) => i.kind)).not.toContain('capture');
    expect(folderZeroItems(undefined, { ...capture, devices: [], screens: [] })).toHaveLength(GENERATORS.length);
  });
  it('shows a gone server by name with "not running" on the layer', () => {
    const gone = layer({ folder: 0, file: 151, kind: 'live', name: 'Syphon: Simple Server', error: 'not running', width: 0, height: 0 });
    expect(mediaLine(gone)).toMatchObject({ text: 'Syphon: Simple Server · not running', tone: 'error' });
    expect(layerState(gone)).toMatchObject({ dot: 'red', chip: 'NOT RUNNING', label: 'Live input not running' });
    expect(layerState({ ...gone, error: 'could not connect' }).chip).toBe('COULD NOT CONNECT');
    expect(mediaLine(layer({ kind: 'live', name: 'Syphon: X', width: 0, height: 0 })).text).toBe('Syphon: X · Live');
  });
});

describe('playSteps', () => {
  const param = (key: string, raw: number): ResolvedParameter => ({ key, raw }) as ResolvedParameter;
  it('sets folder and file, and lifts a dark layer to full', () => {
    expect(playSteps([param('intensity', 0)], 3, 12)).toEqual([{ parameter: 'folder', raw: 3 }, { parameter: 'file', raw: 12 }, { parameter: 'intensity', raw: 65535 }]);
    expect(playSteps([param('intensity', 300)], 3, 12)).toHaveLength(2);
    expect(playSteps(undefined, 3, 12)).toHaveLength(2);
  });
});
