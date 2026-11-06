<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { can } from '../lib/state.svelte';
  import { LOCKED_TITLE } from '../lib/patch-screen';
  import {
    audioLabel,
    codecLabel,
    displayName,
    durationBadge,
    formatLabel,
    transcodeCodecs,
    type LibraryItem,
  } from '../lib/media';

  interface Props {
    item: LibraryItem;
    selected: boolean;
    /** a job for this source is still going */
    pending: boolean;
    /** layers currently playing this file ("Layer 3") */
    onLayers: string[];
    onselect: () => void;
    ontranscode: (item: LibraryItem, codec: string, fps: number) => Promise<void>;
  }
  let { item, selected, pending, onLayers, onselect, ontranscode }: Props = $props();

  let codec = $state<string>(transcodeCodecs[0].value);
  /** an image sequence has no rate of its own: the movie is written at this one (the engine takes 1–240) */
  let fps = $state(25);
  let busy = $state(false);

  const meta = $derived(item.metadata);
  const duration = $derived(durationBadge(item));
  const format = $derived(meta ? formatLabel(meta) : '');
  const audio = $derived(meta ? audioLabel(meta) : '');
  /** one quiet line like the layer row's "HEVC · 1080p25": a tile's format is information, not a state */
  const detail = $derived(meta ? [meta.codec ? codecLabel(meta.codec) : '', format, meta.hasAlpha ? 'α' : '', audio].filter(Boolean).join(' · ') : '');
  const locked = $derived(!can('programmer'));
  const bad = $derived(item.status === 'invalid' || item.status === 'unreadable');

  async function transcode() {
    busy = true;
    await ontranscode(item, codec, fps);
    busy = false;
  }
</script>

<div class="tile panel" class:warn={item.status === 'needsTranscode'} class:err={bad} class:sel={selected}>
  <button class="face" aria-pressed={selected} title={item.name} onclick={onselect}>
    <span class="thumb">
      {#if item.thumbnail}<img src="/api/thumbnail/{item.thumbnail}" alt="" loading="lazy" />{/if}
      <span class="n" class:invalid={item.file === null}>{item.file ?? '—'}</span>
      {#if duration}<span class="dur mono">{duration}</span>{/if}
      {#if onLayers.length}<span class="on"><span class="dot dot-green"></span>{onLayers.join(', ')}</span>{/if}
    </span>
    <span class="name ellipsis">{displayName(item.name, item.file !== null)}</span>
    {#if item.status !== 'playable'}<span class="badges">
      {#if item.status === 'invalid'}
        <span class="badge badge-err">invalid name</span>
      {:else if item.status === 'unreadable'}
        <span class="badge badge-err">unreadable</span>
      {:else if item.status === 'needsTranscode'}
        <span class="badge badge-warn">needs transcode</span>
      {:else if item.status === 'probing'}
        <span class="caption">probing…</span>
      {/if}
    </span>{/if}
    {#if detail}<span class="caption mono" title={meta?.hasAlpha ? 'α: has an alpha channel' : undefined}>{detail}</span>{/if}
    {#if bad && item.reason}<span class="caption reason">{item.reason}</span>{/if}
  </button>
  {#if item.status === 'needsTranscode'}
    <div class="actions">
      <select class="select" aria-label="Codec for {item.name}" bind:value={codec} disabled={locked || busy || pending} title={locked ? LOCKED_TITLE : undefined}>
        {#each transcodeCodecs as option (option.value)}<option value={option.value}>{option.label}</option>{/each}
      </select>
      {#if item.kind === 'sequence'}
        <label class="fps caption"><input class="input mono" type="number" min="1" max="240" step="1" aria-label="Frame rate for {item.name}" bind:value={fps} disabled={locked || busy || pending} title={locked ? LOCKED_TITLE : undefined} /> fps</label>
      {/if}
      <button
        class="btn"
        disabled={locked || busy || pending}
        title={locked ? LOCKED_TITLE : pending ? 'Already in the ingest queue' : undefined}
        onclick={transcode}>{pending ? 'Queued' : 'Transcode'}</button
      >
    </div>
  {/if}
</div>

<style>
  .tile { display: flex; flex-direction: column; min-width: 0; overflow: hidden; }
  .tile.warn { border-color: var(--yellow); }
  .tile.err { border-color: var(--red); }
  .tile.sel { box-shadow: 0 0 0 2px var(--accent); }
  .face { display: flex; flex-direction: column; gap: 8px; width: 100%; padding: 8px; border: 0; background: transparent; text-align: left; flex: 1; }
  .face:hover { background: var(--surface-2); }
  .thumb { display: block; aspect-ratio: 16 / 9; background: var(--ground); }
  .thumb img { position: absolute; inset: 0; }
  .n.invalid { color: var(--red); background: var(--red-bg); }
  .on { position: absolute; left: 4px; bottom: 4px; height: 20px; padding: 0 6px; border-radius: 4px; background: var(--accent-dim); font-size: 11px; font-weight: 500; display: inline-flex; align-items: center; gap: 6px; }
  .on .dot { width: 6px; height: 6px; }
  .dur { position: absolute; right: 4px; bottom: 4px; height: 20px; padding: 0 6px; border-radius: 4px; background: var(--scrim); font-size: 11px; font-weight: 500; display: inline-flex; align-items: center; }
  .name { display: block; font-weight: 500; }
  .badges { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
  .reason { display: block; overflow-wrap: anywhere; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; padding: 0 8px 8px; }
  .actions .select { flex: 1 1 120px; min-width: 0; }
  .actions .btn { flex: 1 1 auto; }
  .fps { display: inline-flex; align-items: center; gap: 4px; }
  .fps .input { width: 64px; }
</style>
