// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import type { LayerStatus, ResolvedParameter } from './docs';
import {
  GENERATORS,
  POLICIES,
  ZERO_GROUPS,
  channelRange,
  clockText,
  controlKeys,
  findParam,
  formatTime,
  layerPreview,
  layerState,
  layersShowing,
  renumberEffect,
  mediaLine,
  outputFixtures,
  parseThumbFrame,
  patchText,
  playedPercent,
  positionCaption,
  reservedText,
  signalText,
  rowThumb,
  thumbnailFor,
  thumbnailIndex,
  valueText,
  layerNumbers,
  folderZeroItems,
  zeroCaption,
  mediaOptions,
  mediaPath,
  playSteps,
  policyName,
  zeroGroups,
  type LibrarySnapshot,
} from './layers';
import type { ParamSpec } from './patch-screen';

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
    expect(mediaLine(layer())).toMatchObject({ title: '2 / 5 · intro.mov', detail: 'HEVC · 1080p25', text: '2 / 5 · intro.mov · HEVC · 1080p25', tone: 'normal' });
    expect(mediaLine(layer({ fps: 29.97002997, codec: 'HapY' })).detail).toBe('HAP Q · 1080p29.97');
    // an anamorphic movie shows its shown width too, as the Media tile does (B146, B147)
    expect(mediaLine(layer({ width: 1440, pixelAspect: 4 / 3 })).detail).toBe('HEVC · 1440×1080p25');
    expect(mediaLine(layer({ pixelAspect: null })).detail).toBe('HEVC · 1080p25');
    expect(mediaLine(layer({ kind: 'still', name: 'logo.png', width: 800, height: 600 })).text).toBe('2 / 5 · logo.png · Still · 800×600');
    expect(mediaLine(layer({ kind: 'live', name: 'Syphon: Resolume' })).text).toBe('Syphon: Resolume · Live · 1920×1080');
    expect(mediaLine(layer({ kind: 'none' }))).toMatchObject({ text: 'no media', detail: '', tone: 'faint' });
  });
  it('shows the error in red for a missing file or a decoder error, and colours the dot', () => {
    const missing = layer({ kind: 'missing', error: 'file not found: 2/5' });
    expect(mediaLine(missing)).toMatchObject({ title: '2 / 5', detail: 'file not found: 2/5', tone: 'error' });
    expect(mediaLine(layer({ kind: 'missing' })).detail).toBe('File missing');
    expect(mediaLine(layer({ error: 'decoder failed' })).tone).toBe('error');
    expect(layerState(missing)).toMatchObject({ dot: 'red', chip: 'Missing file' });
    expect(layerState(layer({ error: 'decoder failed' }))).toMatchObject({ dot: 'red', chip: 'Decoder error' });
    expect(layerState(layer({ kind: 'none' }))).toMatchObject({ dot: 'off', chip: 'No media' });
    expect(layerState(undefined)).toMatchObject({ dot: 'off', chip: 'No media' });
    expect(layerState(layer())).toMatchObject({ dot: 'green', chip: 'OK' });
    expect(layerState(layer({ kind: 'live' })).chip).toBe('Live');
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
  const spec = (key: string, channel: number, bits: 8 | 16): ParamSpec => ({ name: key, key, channel, bits });
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
    expect(patchText(undefined, 64)).toBe('no address');
    expect(patchText({ fixture: 'Layer 3', universe: 'artnet:0.0.1', address: 0 }, 64)).toBe('no address');
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

  it('parses a live thumbnail frame: layer number, big-endian size, the JPEG (B29)', () => {
    const frame = parseThumbFrame(new Uint8Array([3, 0, 160, 1, 28, 0xff, 0xd8, 0xff, 0xd9]));
    expect(frame && { layer: frame.layer, w: frame.w, h: frame.h, jpeg: [...frame.jpeg] }).toEqual({ layer: 3, w: 160, h: 284, jpeg: [0xff, 0xd8, 0xff, 0xd9] });
    const empty = parseThumbFrame(new Uint8Array([32, 0, 0, 0, 0]));
    expect(empty && { layer: empty.layer, w: empty.w, h: empty.h, bytes: empty.jpeg.length }).toEqual({ layer: 32, w: 0, h: 0, bytes: 0 });
    expect(parseThumbFrame(new Uint8Array([1, 0, 160, 0]))).toBeNull();
    expect(parseThumbFrame(new Uint8Array([1, 0, 160, 0, 90])), 'a size without JPEG bytes').toBeNull();
  });

  it('shows the live thumbnail while there is one, else the library thumbnail', () => {
    expect(rowThumb('blob:live', '/api/thumbnail/abc.jpg')).toEqual({ src: 'blob:live', live: true });
    expect(rowThumb(undefined, '/api/thumbnail/abc.jpg')).toEqual({ src: '/api/thumbnail/abc.jpg', live: false });
    expect(rowThumb(undefined, null)).toEqual({ src: null, live: false });
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

describe('live inputs on the Inputs screen (B137)', () => {
  it('signalText: size, rate and pixel format of a capture layer; the reason when it shows none', () => {
    const cam = layer({ folder: 0, file: 3, kind: 'live', codec: '2vuy', width: 1920, height: 1080, fps: 59.94 });
    expect(signalText(cam)).toBe('1920×1080 · 59.94 fps · 2vuy');
    // as the engine sends it: a Syphon layer has no size or rate
    expect(signalText({ ...cam, width: 0, height: 0, fps: 0, codec: 'syphon' })).toBe('connected');
    expect(signalText({ ...cam, width: 0, height: 0, fps: 0 })).toBe('waiting for the first frame');
    expect(signalText({ ...cam, error: 'no signal' })).toBe('no signal');
  });
  it('layersShowing: every layer on a folder/file, none for no media', () => {
    const map = layersShowing([layer({ index: 1, folder: 0, file: 3 }), layer({ index: 2, folder: 0, file: 3 }), layer({ index: 3, folder: 0, file: 0 })]);
    expect(map.get('0/3')).toEqual(['Layer 1', 'Layer 2']);
    expect(map.size).toBe(1);
  });
});

describe('renumberEffect (B137 step 3)', () => {
  const item = (file: number, name: string, kind: 'capture' | 'screen' | 'syphon' = 'capture') => ({ file, name, kind, running: true, gone: false, inUse: false, label: '' });
  const items = [item(1, 'Cam A'), item(2, 'Cam B'), item(21, 'Built-in', 'screen'), item(150, 'Syphon: App', 'syphon')];
  it('a free number moves, a taken one swaps; within the kind range only', () => {
    expect(renumberEffect(items, items[0], 5)).toEqual({ swap: null, text: 'moves to 5, a free number' });
    expect(renumberEffect(items, items[0], 2)).toEqual({ swap: items[1], text: 'swaps with 2 · Cam B' });
    expect(renumberEffect(items, items[2], 22)?.text).toBe('moves to 22, a free number');
    expect(renumberEffect(items, items[3], 169)?.swap).toBeNull();
  });
  it('null for its own number, another range, or no number', () => {
    expect(renumberEffect(items, items[0], 1)).toBeNull();
    expect(renumberEffect(items, items[0], 21)).toBeNull();
    expect(renumberEffect(items, items[2], 3)).toBeNull();
    expect(renumberEffect(items, items[0], 0)).toBeNull();
    expect(renumberEffect(items, items[0], 2.5)).toBeNull();
  });
});

describe('layerNumbers', () => {
  it('counts 1…layerCount and guards a bad count', () => {
    expect(layerNumbers(3)).toEqual([1, 2, 3]);
    expect(layerNumbers(2.7)).toEqual([1, 2]);
    expect(layerNumbers(-1)).toEqual([]);
    expect(layerNumbers(Number.NaN)).toEqual([]);
  });
});

const library: LibrarySnapshot = {
  scannedAt: 1,
  folders: [
    { number: 3, name: '003_Intro', items: [{ folder: 3, file: 12, name: 'loop.mov', status: 'playable' }, { folder: 3, file: null, name: 'bad.mov', status: 'invalid' }] },
    { number: 1, name: 'Music', items: [{ folder: 1, file: 2, name: 'a.mov', status: 'playable' }, { folder: 1, file: 1, name: 'b.mov', status: 'unreadable' }] },
    { number: null, name: 'junk', items: [{ folder: 0, file: 4, name: 'x.mov' }] },
  ],
};

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

  // label and short are pinned above; the line under the Who controls select is pinned nowhere else
  it('words the line under the select as in the DESIGN §6.6 table', () => {
    expect(Object.fromEntries(Object.entries(POLICIES).map(([k, p]) => [k, p.line]))).toEqual({
      dmx: 'Fanous follows the console. A fixture without an address stays at its defaults; cues and OSC are recorded but do nothing.',
      internal: 'The console is shown but ignored.',
      ltp: 'Per parameter, the latest change wins.',
      htp: 'Intensity and other numbers take the highest value; folder, file and modes the latest change.',
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
  it('groups by heading: no camera group without a capture feed, no display group without displays', () => {
    const groups = (capture?: Parameters<typeof folderZeroItems>[1]) => zeroGroups(folderZeroItems(servers, capture), capture).map((g) => `${g.kind} ${g.list.length}`);
    expect(groups()).toEqual([`generator ${GENERATORS.length}`, 'syphon 2']);
    expect(groups({ devices: [] })).toEqual([`generator ${GENERATORS.length}`, 'capture 0', 'syphon 2']);
    expect(groups({ devices: [], screens: [{ file: 21, name: 'Built-in Retina Display', running: true }] })).toEqual([`generator ${GENERATORS.length}`, 'capture 0', 'screen 1', 'syphon 2']);
  });
  it('shows a gone server by name with "not running" on the layer', () => {
    const gone = layer({ folder: 0, file: 151, kind: 'live', name: 'Syphon: Simple Server', error: 'not running', width: 0, height: 0 });
    expect(mediaLine(gone)).toMatchObject({ text: 'Syphon: Simple Server · not running', tone: 'error' });
    expect(layerState(gone)).toMatchObject({ dot: 'red', chip: 'Not running', label: 'Live input not running' });
    expect(layerState({ ...gone, error: 'could not connect' }).chip).toBe('Could not connect');
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
