// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { LayerStatus, ResolvedParameter } from './docs';
import { layerState, mediaOptions, mediaPath, playSteps, policyName, type LibrarySnapshot } from './layers';

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

describe('playSteps', () => {
  const param = (key: string, raw: number): ResolvedParameter => ({ key, raw }) as ResolvedParameter;
  it('sets folder and file, and lifts a dark layer to full', () => {
    expect(playSteps([param('intensity', 0)], 3, 12)).toEqual([{ parameter: 'folder', raw: 3 }, { parameter: 'file', raw: 12 }, { parameter: 'intensity', raw: 65535 }]);
    expect(playSteps([param('intensity', 300)], 3, 12)).toHaveLength(2);
    expect(playSteps(undefined, 3, 12)).toHaveLength(2);
  });
});
