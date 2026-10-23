// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { IngestJobDoc } from './docs';
import {
  activeSources,
  audioLabel,
  basename,
  codecLabel,
  defaultFolder,
  describeCodec,
  describeJobState,
  displayName,
  durationBadge,
  filterItems,
  formatDuration,
  formatLabel,
  invalidCount,
  orderJobs,
  pathTail,
  queueSummary,
  send,
  transcodeCodecs,
  type LibraryFolder,
  type LibraryItem,
  type MediaMetadata,
} from './media';

const meta = (over: Partial<MediaMetadata> = {}): MediaMetadata => ({
  width: 1920, height: 1080, frameRate: 25, duration: 83.46, codec: 'HapY', hasAlpha: false, audioChannels: 0, audioSampleRate: 0, frameCount: 0, ...over,
});

const item = (over: Partial<LibraryItem> = {}): LibraryItem => ({
  folder: 1, file: 1, name: '001_clip.mov', path: '/lib/001_a/001_clip.mov', kind: 'movie', status: 'playable', reason: null, metadata: meta(), thumbnail: null, ...over,
});

const job = (id: string, state: unknown, source = `/in/${id}.mp4`): IngestJobDoc => ({ id, source, destination: `/lib/${id}.mov`, kind: { still: {} }, state });

describe('describeCodec', () => {
  it('names every codec of a transcode job', () => {
    const name = (codec: unknown) => describeCodec({ transcode: { codec } });
    expect(name({ proRes422HQ: {} })).toBe('ProRes 422 HQ');
    expect(name({ proRes422: {} })).toBe('ProRes 422');
    expect(name({ proRes4444: {} })).toBe('ProRes 4444');
    expect(name({ hap: { _0: 'hap' } })).toBe('HAP');
    expect(name({ hap: { _0: 'hapAlpha' } })).toBe('HAP Alpha');
    expect(name({ hap: { _0: 'hapQ' } })).toBe('HAP Q');
    expect(name({ hap: { _0: 'hapAlphaOnly' } })).toBe('HAP Alpha Only');
  });

  it('reads sequence jobs, stills and malformed input', () => {
    expect(describeCodec({ sequence: { fps: 25, codec: { proRes4444: {} } } })).toBe('ProRes 4444');
    expect(describeCodec({ sequence: { fps: 30, codec: { hap: { _0: 'hapQ' } } } })).toBe('HAP Q');
    expect(describeCodec({ still: {} })).toBe('Still');
    expect(describeCodec({ transcode: { codec: { hap: {} } } })).toBe('HAP');
    expect(describeCodec({ transcode: {} })).toBe('Unknown');
    expect(describeCodec({ nope: {} })).toBe('Unknown');
    expect(describeCodec({})).toBe('Unknown');
    expect(describeCodec(null)).toBe('Unknown');
    expect(describeCodec('still')).toBe('Unknown');
    expect(describeCodec([])).toBe('Unknown');
  });
});

describe('describeJobState', () => {
  it('maps every state', () => {
    expect(describeJobState({ queued: {} })).toEqual({ label: 'queued', progress: 0 });
    expect(describeJobState({ running: { progress: 0.42 } })).toEqual({ label: 'transcoding', progress: 0.42 });
    expect(describeJobState({ done: {} })).toEqual({ label: 'done', progress: 1 });
    expect(describeJobState({ failed: { _0: 'disk full' } })).toEqual({ label: 'failed', progress: 0, error: 'disk full' });
    expect(describeJobState({ cancelled: {} })).toEqual({ label: 'cancelled', progress: 0 });
  });

  it('clamps progress and survives malformed states', () => {
    expect(describeJobState({ running: { progress: 1.7 } }).progress).toBe(1);
    expect(describeJobState({ running: { progress: -1 } }).progress).toBe(0);
    expect(describeJobState({ running: {} })).toEqual({ label: 'transcoding', progress: 0 });
    expect(describeJobState({ failed: {} }).error).toBe('unknown error');
    expect(describeJobState(undefined)).toEqual({ label: 'queued', progress: 0 });
    expect(describeJobState('done')).toEqual({ label: 'queued', progress: 0 });
  });
});

describe('queue helpers', () => {
  const jobs = [job('a', { done: {} }), job('b', { running: { progress: 0.5 } }), job('c', { failed: { _0: 'x' } }), job('d', { queued: {} }), job('e', { cancelled: {} })];

  it('lists newest first with the active jobs ahead of the finished ones', () => {
    expect(orderJobs(jobs).map((j) => j.id)).toEqual(['d', 'b', 'e', 'c', 'a']);
    expect(jobs.map((j) => j.id)).toEqual(['a', 'b', 'c', 'd', 'e']); // input untouched
  });

  it('counts running and queued jobs and finds sources still in flight', () => {
    expect(queueSummary(jobs)).toEqual({ running: 1, queued: 1 });
    expect(queueSummary([])).toEqual({ running: 0, queued: 0 });
    expect(activeSources(jobs)).toEqual(new Set(['/in/b.mp4', '/in/d.mp4']));
  });
});

describe('codecLabel', () => {
  it('maps fourccs and keeps the rest', () => {
    expect(codecLabel('apch')).toBe('ProRes 422 HQ');
    expect(codecLabel('apcn')).toBe('ProRes 422');
    expect(codecLabel('ap4h')).toBe('ProRes 4444');
    expect(codecLabel('ap4x')).toBe('ProRes 4444 XQ');
    expect(codecLabel('Hap1')).toBe('HAP');
    expect(codecLabel('Hap5')).toBe('HAP Alpha');
    expect(codecLabel('HapY')).toBe('HAP Q');
    expect(codecLabel('HapM')).toBe('HAP Q Alpha');
    expect(codecLabel('avc1')).toBe('H.264');
    expect(codecLabel('hvc1')).toBe('HEVC');
    expect(codecLabel('hev1')).toBe('HEVC');
    expect(codecLabel('png')).toBe('png');
    expect(codecLabel('constructor')).toBe('constructor');
  });
});

describe('formatting', () => {
  it('formats durations as m:ss.s', () => {
    expect(formatDuration(0)).toBe('0:00.0');
    expect(formatDuration(5.04)).toBe('0:05.0');
    expect(formatDuration(83.46)).toBe('1:23.5');
    expect(formatDuration(59.96)).toBe('1:00.0');
    expect(formatDuration(4325.2)).toBe('72:05.2');
    expect(formatDuration(-3)).toBe('0:00.0');
  });

  it('badges the duration by kind', () => {
    expect(durationBadge(item())).toBe('1:23.5');
    expect(durationBadge(item({ kind: 'still', metadata: null }))).toBe('still');
    expect(durationBadge(item({ kind: 'sequence', metadata: meta({ frameCount: 240, duration: 0 }) }))).toBe('240 frames');
    expect(durationBadge(item({ metadata: null }))).toBeNull();
    expect(durationBadge(item({ metadata: meta({ duration: 0 }) }))).toBeNull();
  });

  it('writes resolution, frame rate and audio', () => {
    expect(formatLabel(meta())).toBe('1080p25');
    expect(formatLabel(meta({ frameRate: 29.970030784606934 }))).toBe('1080p29.97');
    expect(formatLabel(meta({ frameRate: 23.976024627685547 }))).toBe('1080p23.976');
    expect(formatLabel(meta({ frameRate: 0 }))).toBe('1920×1080');
    expect(formatLabel(meta({ height: 0 }))).toBe('');
    expect(audioLabel(meta())).toBe('');
    expect(audioLabel(meta({ audioChannels: 2, audioSampleRate: 48000 }))).toBe('48k');
    expect(audioLabel(meta({ audioChannels: 2, audioSampleRate: 44100 }))).toBe('44.1k');
  });

  it('strips the number prefix only when it is a number', () => {
    expect(displayName('012_Show', true)).toBe('Show');
    expect(displayName('3 Intro', true)).toBe('Intro');
    expect(displayName('007-clip.mov', true)).toBe('clip.mov');
    expect(displayName('12.mov', true)).toBe('12.mov');
    expect(displayName('003', true)).toBe('003');
    expect(displayName('12_Dup', false)).toBe('12_Dup');
    expect(displayName('Show', true)).toBe('Show');
  });

  it('shortens paths', () => {
    expect(basename('/lib/003_Intro/012_clip.mov')).toBe('012_clip.mov');
    expect(basename('clip.mov')).toBe('clip.mov');
    expect(pathTail('/lib/003_Intro/012_clip.mov')).toBe('003_Intro/012_clip.mov');
    expect(pathTail('/clip.mov')).toBe('clip.mov');
  });
});

describe('library helpers', () => {
  const folder = (number: number | null, name: string, items: LibraryItem[] = []): LibraryFolder => ({ number, name, path: `/lib/${name}`, items });

  it('counts invalid names, also inside invalid folders', () => {
    expect(invalidCount([item(), item({ file: null, status: 'invalid' }), item({ status: 'needsTranscode' })])).toBe(1);
    expect(invalidCount([item({ status: 'invalid', reason: 'folder: no 1–255 prefix' })])).toBe(1);
    expect(invalidCount([])).toBe(0);
  });

  it('selects the first numbered folder by default', () => {
    const bad = folder(null, 'Misc');
    const one = folder(1, '001_A');
    expect(defaultFolder([bad, one])).toBe(one);
    expect(defaultFolder([bad])).toBe(bad);
    expect(defaultFolder([])).toBeUndefined();
  });

  it('filters by name, ignoring case and surrounding blanks', () => {
    const items = [item({ name: '001_Intro.mov' }), item({ name: '002_loop.mov' })];
    expect(filterItems(items, '')).toBe(items);
    expect(filterItems(items, '  ')).toBe(items);
    expect(filterItems(items, ' INTRO ').map((i) => i.name)).toEqual(['001_Intro.mov']);
    expect(filterItems(items, '.mov')).toHaveLength(2);
    expect(filterItems(items, 'zzz')).toEqual([]);
  });

  it('offers the codec names the ingest API understands, HAP Q first', () => {
    expect(transcodeCodecs[0].value).toBe('hapq');
    expect(transcodeCodecs.map((c) => c.value)).toEqual(['hapq', 'hap', 'hapalpha', 'prores422hq', 'prores4444']);
  });
});

describe('send', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('resolves to null when the engine accepts', async () => {
    const fetchMock = vi.fn(async () => new Response('queued', { status: 202 }));
    vi.stubGlobal('fetch', fetchMock);
    expect(await send('/api/ingest', { method: 'POST' })).toBeNull();
    expect(fetchMock).toHaveBeenCalledWith('/api/ingest', { method: 'POST' });
  });

  it('reports the status and body of a refusal', async () => {
    vi.stubGlobal('fetch', async () => new Response('programmer role required', { status: 403 }));
    expect(await send('/x', {})).toBe('403 programmer role required');
    vi.stubGlobal('fetch', async () => new Response('', { status: 500, statusText: 'Internal Server Error' }));
    expect(await send('/x', {})).toBe('500 Internal Server Error');
  });

  it('reports a network failure', async () => {
    vi.stubGlobal('fetch', async () => {
      throw new TypeError('Failed to fetch');
    });
    expect(await send('/x', {})).toBe('Failed to fetch');
  });
});
