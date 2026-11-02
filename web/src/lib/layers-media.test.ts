// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { LayerStatus, ResolvedParameter } from './docs';
import { GENERATORS, POLICIES, ZERO_GROUPS, folderZeroItems, zeroCaption, layerState, mediaLine, mediaOptions, mediaPath, playSteps, policyName, type LibrarySnapshot } from './layers';

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

describe('who controls (source policy) names', () => {
  it('uses the long labels of DESIGN §6.6 for the stored values', () => {
    expect(policyName('dmx')).toBe('Console only');
    expect(policyName('internal')).toBe('Fanous only (UI, cues, OSC, MIDI)');
    expect(policyName('ltp')).toBe('Console and Fanous, latest change wins');
    expect(policyName('htp')).toBe('Console and Fanous, highest value wins');
    expect(policyName('other')).toBe('other');
  });

  it('has short labels for the Source badge', () => {
    expect(['dmx', 'internal', 'ltp', 'htp', 'other'].map((p) => policyName(p, true))).toEqual(['Console', 'Fanous', 'Both · latest', 'Both · highest', 'other']);
  });

  it('matches the DESIGN §6.6 table word for word', () => {
    expect(POLICIES).toEqual({
      dmx: {
        label: 'Console only',
        short: 'Console',
        line: 'Fanous follows the console. A fixture without an address stays at its defaults; cues and OSC are recorded but do nothing.',
      },
      internal: { label: 'Fanous only (UI, cues, OSC, MIDI)', short: 'Fanous', line: 'The console is shown but ignored.' },
      ltp: { label: 'Console and Fanous, latest change wins', short: 'Both · latest', line: 'Per parameter, the latest change wins.' },
      htp: {
        label: 'Console and Fanous, highest value wins',
        short: 'Both · highest',
        line: 'Intensity and other numbers take the highest value; folder, file and modes the latest change.',
      },
    });
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
  it('lists only the stills for an image mask', () => {
    const stills = { ...library, folders: [...library.folders, { number: 2, items: [{ folder: 2, file: 1, name: 'door.png', kind: 'still', status: 'playable' }] }] };
    expect(mediaOptions(stills, 'still').map((o) => `${o.folder}/${o.file}`)).toEqual(['2/1']);
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
        { file: 2, name: 'iPhone Camera', running: true, inUse: true as const },
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
  it('takes a partial capture feed: devices without screens or permissions', () => {
    const items = folderZeroItems(undefined, { devices: [{ file: 1, name: 'FaceTime HD Camera', running: false }] }).slice(GENERATORS.length);
    expect(items.map((i) => `${i.kind} ${i.label}`)).toEqual(['capture 1 · FaceTime HD Camera (not running)']);
    expect(items.map(zeroCaption)).toEqual(['not running']);
  });
  it('lists displays 21–28 by number with their state, in the group order of the Media screen (B73 step 3b)', () => {
    const capture = {
      devices: [{ file: 1, name: 'FaceTime HD Camera', running: true, inUse: true as const }],
      screens: [
        { file: 23, name: 'LG UltraFine', running: false, gone: true as const },
        { file: 21, name: 'Built-in Retina Display', running: true },
        { file: 22, name: 'DELL U2720Q', running: false },
      ],
      permissions: { camera: 'granted' as const, screen: 'denied' as const },
    };
    const items = folderZeroItems(servers, capture);
    const screens = items.filter((i) => i.kind === 'screen');
    expect(screens.map((i) => i.label)).toEqual(['21 · Built-in Retina Display', '22 · DELL U2720Q (not running)', '23 · LG UltraFine (not running)']);
    expect(screens.map(zeroCaption)).toEqual([null, 'not running', 'not seen since the engine started']);
    expect(screens.every((i) => !i.inUse)).toBe(true);
    // the groups follow ZERO_GROUPS, so the Media screen and the layer picker agree
    const kinds = [...new Set(items.map((i) => i.kind))];
    expect(kinds).toEqual(ZERO_GROUPS.map((g) => g.kind));
    expect(ZERO_GROUPS.find((g) => g.kind === 'screen')?.title).toBe('Displays (21–28)');
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
