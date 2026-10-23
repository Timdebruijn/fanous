<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { can } from '../lib/state.svelte';
  import {
    LOCKED_TITLE,
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
    ontranscode: (item: LibraryItem, codec: string) => Promise<void>;
  }
  let { item, selected, pending, onLayers, onselect, ontranscode }: Props = $props();

  let codec = $state<string>(transcodeCodecs[0].value);
  let busy = $state(false);

  const meta = $derived(item.metadata);
  const duration = $derived(durationBadge(item));
  const format = $derived(meta ? formatLabel(meta) : '');
  const audio = $derived(meta ? audioLabel(meta) : '');
  const locked = $derived(!can('programmer'));
  const bad = $derived(item.status === 'invalid' || item.status === 'unreadable');

  async function transcode() {
    busy = true;
    await ontranscode(item, codec);
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
    <span class="badges">
      {#if item.status === 'invalid'}
        <span class="badge badge-err">invalid name</span>
      {:else if item.status === 'unreadable'}
        <span class="badge badge-err">unreadable</span>
      {:else if item.status === 'needsTranscode'}
        <span class="badge badge-warn">needs transcode</span>
      {:else if item.status === 'probing'}
        <span class="caption">probing…</span>
      {/if}
      {#if meta?.codec}<span class="badge codec">{codecLabel(meta.codec)}</span>{/if}
      {#if format}<span class="badge badge-outline mono">{format}</span>{/if}
      {#if meta?.hasAlpha}<span class="badge badge-outline" title="Has an alpha channel">α</span>{/if}
      {#if audio}<span class="badge badge-outline mono" title="Audio track">{audio}</span>{/if}
    </span>
    {#if bad && item.reason}<span class="caption reason">{item.reason}</span>{/if}
  </button>
  {#if item.status === 'needsTranscode'}
    <div class="actions">
      <select class="select" aria-label="Codec for {item.name}" bind:value={codec} disabled={locked || busy || pending} title={locked ? LOCKED_TITLE : undefined}>
        {#each transcodeCodecs as option (option.value)}<option value={option.value}>{option.label}</option>{/each}
      </select>
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
  .on { position: absolute; left: 4px; bottom: 4px; height: 20px; padding: 0 6px; border-radius: 4px; background: var(--accent-dim); font-size: 11px; font-weight: 600; display: inline-flex; align-items: center; gap: 5px; }
  .on .dot { width: 6px; height: 6px; }
  .dur { position: absolute; right: 4px; bottom: 4px; height: 18px; padding: 0 5px; border-radius: 3px; background: rgba(11, 12, 14, 0.8); font-size: 11px; font-weight: 600; display: inline-flex; align-items: center; }
  .name { display: block; font-weight: 500; }
  .badges { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; min-height: 24px; }
  .codec { text-transform: uppercase; }
  .reason { display: block; overflow-wrap: anywhere; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; padding: 0 8px 8px; }
  .actions .select { flex: 1 1 120px; min-width: 0; }
  .actions .btn { flex: 1 1 auto; }
</style>
