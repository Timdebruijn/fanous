// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { LayerStatus, ResolvedParameter } from './docs';
import {
  channelRange,
  clockText,
  controlKeys,
  findParam,
  formatTime,
  layerPreview,
  layerState,
  mediaLine,
  outputFixtures,
  patchText,
  playedPercent,
  positionCaption,
  reservedText,
  thumbnailFor,
  thumbnailIndex,
  valueText,
  type ChannelSpec,
} from './layers';

function layer(over: Partial<LayerStatus> = {}): LayerStatus {
  return { index: 1, folder: 2, file: 5, name: 'intro.mov', kind: 'movie', codec: 'hevc', width: 1920, height: 1080, fps: 25, frames: 1500, frame: 75, error: null, ...over };
}

describe('formatTime', () => {
  it('prints mm:ss.s and truncates to a tenth', () => {
    expect(formatTime(0)).toBe('00:00.0');
    expect(formatTime(1.3)).toBe('00:01.3');
    expect(formatTime(59.99)).toBe('00:59.9');
    expect(formatTime(83.25)).toBe('01:23.2');
    expect(formatTime(3725.04)).toBe('62:05.0');
  });
  it('treats negative and non-finite input as zero', () => {
    expect(formatTime(-4)).toBe('00:00.0');
    expect(formatTime(Number.NaN)).toBe('00:00.0');
    expect(formatTime(Infinity)).toBe('00:00.0');
  });
});

describe('position', () => {
  it('shows elapsed / total for movies and guards a zero frame rate', () => {
    expect(positionCaption(layer())).toBe('00:03.0 / 01:00.0');
    expect(positionCaption(layer({ fps: 0 }))).toBe('00:00.0 / 00:00.0');
    expect(playedPercent(layer())).toBe(5);
    expect(playedPercent(layer({ frames: 0 }))).toBe(0);
    expect(playedPercent(layer({ frame: 9999 }))).toBe(100);
  });
  it('labels stills and live inputs and dashes the rest', () => {
    expect(positionCaption(layer({ kind: 'still' }))).toBe('still');
    expect(positionCaption(layer({ kind: 'live' }))).toBe('live');
    expect(positionCaption(layer({ kind: 'none' }))).toBe('—');
    expect(positionCaption(undefined)).toBe('—');
  });
});

describe('mediaLine and layerState', () => {
  it('describes each media kind', () => {
    expect(mediaLine(layer())).toMatchObject({ title: '2 / 5 · intro.mov', detail: 'hevc · 1080p25', text: '2 / 5 · intro.mov · hevc · 1080p25', tone: 'normal' });
    expect(mediaLine(layer({ fps: 29.97002997, codec: 'HapY' })).detail).toBe('HAP Q · 1080p29.97');
    expect(mediaLine(layer({ kind: 'still', name: 'logo.png', width: 800, height: 600 })).text).toBe('2 / 5 · logo.png · Still · 800×600');
    expect(mediaLine(layer({ kind: 'live', name: 'Syphon: Resolume' })).text).toBe('Syphon: Resolume · Live · 1920×1080');
    expect(mediaLine(layer({ kind: 'none' }))).toMatchObject({ text: 'no media', detail: '', tone: 'faint' });
  });
  it('shows the error in red for a missing file or a decoder error, and colours the dot', () => {
    const missing = layer({ kind: 'missing', error: 'file not found: 2/5' });
    expect(mediaLine(missing)).toMatchObject({ title: '2 / 5', detail: 'file not found: 2/5', tone: 'error' });
    expect(mediaLine(layer({ kind: 'missing' })).detail).toBe('File missing');
    expect(mediaLine(layer({ error: 'decoder failed' })).tone).toBe('error');
    expect(layerState(missing).dot).toBe('red');
    expect(layerState(layer({ error: 'decoder failed' })).dot).toBe('red');
    expect(layerState(layer({ kind: 'none' })).dot).toBe('off');
    expect(layerState(undefined).dot).toBe('off');
    expect(layerState(layer()).dot).toBe('green');
  });
});

describe('parameters', () => {
  const params: ResolvedParameter[] = [
    { key: 'intensity', name: 'Intensity', raw: 49152, physical: 75, label: '75 %', unit: '%', source: 'dmx' },
    { key: 'speed', name: 'Speed', raw: 32768, physical: 100, label: '', unit: '%', source: 'dmx' },
  ];
  it('finds a parameter by key and falls back to physical + unit without a label', () => {
    expect(findParam(params, 'intensity')?.raw).toBe(49152);
    expect(findParam(params, 'nope')).toBeUndefined();
    expect(findParam(undefined, 'intensity')).toBeUndefined();
    expect(valueText(params[0]!)).toBe('75 %');
    expect(valueText(params[1]!)).toBe('100 %');
  });
});

describe('channels and patch', () => {
  const spec = (key: string, channel: number, bits: number): ChannelSpec => ({ name: key, key, channel, bits, default: 0, group: '', unit: '' });
  it('formats single and coarse/fine channel ranges', () => {
    expect(channelRange(spec('folder', 3, 8))).toBe('3');
    expect(channelRange(spec('intensity', 1, 16))).toBe('1–2');
    expect(channelRange(undefined)).toBe('—');
  });
  it('derives the reserved channels from the map', () => {
    const specs = [spec('intensity', 1, 16), spec('control', 50, 8)];
    expect(reservedText(specs, 64)).toBe('Showing all 50 of 64 channels; 51–64 reserved');
    expect(reservedText([spec('x', 63, 16)], 64)).toBe('Showing all 64 of 64 channels');
  });
  it('writes the patch line, treating a missing entry or address 0 as unpatched', () => {
    expect(patchText({ fixture: 'Layer 3', universe: 'artnet:0.0.1', address: 145 }, 64)).toBe('artnet:0.0.1 · ch 145–208 · 64 ch');
    expect(patchText(undefined, 64)).toBe('unpatched');
    expect(patchText({ fixture: 'Layer 3', universe: 'artnet:0.0.1', address: 0 }, 64)).toBe('unpatched');
  });
  it('lists output fixtures in numeric order and ignores the rest', () => {
    expect(outputFixtures({ Master: [], 'Layer 1': [], 'Output 10': [], 'Output 2': [], 'Output 1': [] })).toEqual(['Output 1', 'Output 2', 'Output 10']);
  });
});

describe('thumbnails', () => {
  it('matches a layer to the library item with the same folder and file', () => {
    const index = thumbnailIndex({
      scannedAt: 1,
      folders: [{ number: 2, items: [{ folder: 2, file: 5, thumbnail: 'abc.jpg' }, { folder: 2, file: 6, thumbnail: null }] }],
    });
    expect(thumbnailFor(index, layer())).toBe('/api/thumbnail/abc.jpg');
    expect(thumbnailFor(index, layer({ file: 6 }))).toBeNull();
    expect(thumbnailFor(index, undefined)).toBeNull();
    expect(thumbnailIndex(null).size).toBe(0);
  });
});

describe('UI control (B27)', () => {
  it('counts down as m:ss', () => {
    expect(clockText(462)).toBe('7:42');
    expect(clockText(600)).toBe('10:00');
    expect(clockText(-3)).toBe('0:00');
  });
  it('offers intensity/speed for Master, intensity/test pattern for outputs, everything for layers', () => {
    expect(controlKeys('Master')).toEqual(['intensity', 'speed']);
    expect(controlKeys('Output 2')).toEqual(['intensity', 'testPattern']);
    expect(controlKeys('Layer 1')).toBeUndefined();
  });
});

describe('layerPreview', () => {
  it('shows the canvas by default and the selected layer on request', () => {
    expect(layerPreview('canvas', 3)).toEqual({ target: 'canvas', label: 'Canvas', shows: 'canvas' });
    expect(layerPreview('layer', 3)).toEqual({ target: 'layer:3', label: 'Layer 3', shows: 'layer' });
  });
  it('falls back to the canvas without a selected layer and says so', () => {
    expect(layerPreview('layer', null)).toEqual({ target: 'canvas', label: 'Canvas (no layer selected)', shows: 'canvas' });
  });
});
