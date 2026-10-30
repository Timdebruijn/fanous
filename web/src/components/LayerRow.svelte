<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { LayerStatus, ResolvedParameter } from '../lib/docs';
  import { clampPercent, findParam, formatPercent, layerState, mediaLine, playedPercent, policyName, positionCaption } from '../lib/layers';
  import { layerCanvas } from '../lib/outputs';
  import { lockTitle } from '../lib/show';
  import { syncStatus } from '../lib/sync';
  import { app, can, cmd } from '../lib/state.svelte';

  let {
    n,
    layer,
    params,
    policy,
    thumb,
    selected,
    onselect,
  }: {
    n: number;
    layer: LayerStatus | undefined;
    params: ResolvedParameter[] | undefined;
    policy: string;
    /** live: the engine's current picture of this layer (B29), otherwise the library thumbnail */
    thumb: { src: string | null; live: boolean };
    selected: boolean;
    onselect: () => void;
  } = $props();

  const media = $derived(mediaLine(layer));
  const status = $derived(layerState(layer));
  const sync = $derived(syncStatus(n, layer?.sync, app.live.sync));
  const isMovie = $derived(layer?.kind === 'movie');
  const intensity = $derived(findParam(params, 'intensity'));
  const playMode = $derived(findParam(params, 'playMode'));
  const speed = $derived(findParam(params, 'speed'));
  const inPoint = $derived(findParam(params, 'inPoint'));
  const outPoint = $derived(findParam(params, 'outPoint'));
  const volume = $derived(findParam(params, 'audioVolume'));
  const level = $derived(clampPercent(volume?.physical ?? 0));
  // the canvas this layer renders into: a project setting (layer.set), shown as a select once there is a choice
  const canvases = $derived(app.project.canvases);
  const canvas = $derived(layerCanvas(app.project.layerCanvas, n));
  const canvasName = $derived(canvases.find((c) => c.id === canvas)?.name ?? `Canvas ${canvas}`);
  const canvasLock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  function keydown(event: KeyboardEvent) {
    if (event.target !== event.currentTarget || (event.key !== 'Enter' && event.key !== ' ')) return;
    event.preventDefault();
    onselect();
  }
</script>

<!-- Column widths come from --layer-cols / --layer-gap, set by the Layers screen so its column heads line up. -->
<!-- a div, not a button: the canvas select sits inside the row -->
<div class="row layer" role="button" tabindex="0" aria-pressed={selected} onclick={onselect} onkeydown={keydown}>
  <span class="thumb c-thumb">
    {#if thumb.src}<img src={thumb.src} alt="" loading="lazy" data-live={thumb.live ? 'true' : undefined} />{/if}
    <span class="n">{n}</span>
  </span>
  <span class="c-name">
    <span class="nm">Layer {n}</span>
    {#if canvases.length > 1}
      <select class="select canvas" aria-label="Canvas of layer {n}" title={canvasLock ?? 'The canvas this layer renders into'} disabled={canvasLock !== undefined} value={canvas} onclick={(e) => e.stopPropagation()} onkeydown={(e) => e.stopPropagation()} onchange={(e) => void cmd('layer.set', { layer: n, canvas: Number(e.currentTarget.value) })}>
        {#if !canvases.some((c) => c.id === canvas)}<option value={canvas}>Canvas {canvas} · missing</option>{/if}
        {#each canvases as c (c.id)}<option value={c.id}>{c.name}</option>{/each}
      </select>
    {:else}
      <span class="caption">{canvasName}</span>
    {/if}
    {#if sync}<span class="pill sync sync-{sync.tone}" role="img" aria-label="Sync {sync.label}: {sync.text}" title="Sync: {sync.text}">{sync.label}</span>{/if}
  </span>
  <span class="c-media tone-{media.tone}" title={media.text}>
    <span class="lbl">Media: </span>
    <span class="ellipsis mtitle">{media.title}</span>
    {#if media.detail}<span class="ellipsis caption mono mdetail">{media.detail}</span>{/if}
  </span>
  <span class="c-pos">
    <span class="lbl">Position</span>
    <span class="scrubber" aria-hidden="true">
      {#if isMovie}
        <span class="played" style:width="{playedPercent(layer)}%"></span>
        <span class="head" style:left="{playedPercent(layer)}%"></span>
        {#if inPoint}<span class="mark" style:left="{clampPercent(inPoint.physical)}%"></span>{/if}
        {#if outPoint}<span class="mark" style:left="{clampPercent(outPoint.physical)}%"></span>{/if}
      {/if}
    </span>
    <span class="caption mono">{positionCaption(layer)}</span>
  </span>
  <span class="c-vals">
    <span class="c-int">
      <span class="lbl">Intensity</span>
      <span class="mono">{intensity ? `${formatPercent(intensity.physical)} %` : '—'}</span>
      <span class="bar bar-level" aria-hidden="true"><span style:width="{clampPercent(intensity?.physical ?? 0)}%"></span></span>
    </span>
    <span class="c-mode">
      <span class="lbl">Play mode</span>
      <span class="mode">{playMode?.label ?? '—'}</span>
      <span class="caption mono">{speed ? `speed ${speed.label}` : '—'}</span>
    </span>
    <span class="c-audio" title="Audio volume parameter (no level meter yet)">
      <span class="lbl">Audio</span>
      <span class="mono">{volume ? `${formatPercent(volume.physical)} %` : '—'}</span>
      <span class="bar" aria-hidden="true"><span style:width="{level}%"></span></span>
    </span>
    <span class="c-src">
      <span class="lbl">Source</span>
      <span class="badge badge-outline pol">{policyName(policy, true)}</span>
    </span>
  </span>
  <span class="c-dot">
    <span class="dot dot-{status.dot}" role="img" aria-label={status.label} title={status.label}></span>
    <span class="chip chip-{status.dot}">{status.chip}</span>
  </span>
</div>

<style>
  /* Desktop row: one grid line per layer. Narrower than 1320 px the row becomes a tile (the list is a tile grid there). */
  .layer {
    display: grid; grid-template-columns: var(--layer-cols); column-gap: var(--layer-gap); align-items: center;
    min-height: var(--row); font-size: 13px;
  }
  .c-thumb { display: block; flex: none; width: 96px; height: 54px; border: 1px solid var(--line); background: var(--ground); }
  .layer { cursor: pointer; }
  .c-name { display: flex; flex-direction: column; align-items: flex-start; min-width: 0; }
  .canvas { min-height: 28px; height: 28px; padding: 0 6px; font-size: 12px; max-width: 100%; }
  .nm { font-weight: 600; font-size: 14px; }
  .sync { height: 20px; padding: 0 6px; margin-top: 2px; font-size: 11px; font-weight: 700; }
  .sync-green { background: var(--green-bg); color: var(--green); }
  .sync-yellow { background: var(--yellow-bg); color: var(--yellow); }
  .sync-red { background: var(--red-bg); color: var(--red); }
  .sync-grey { background: var(--surface-3); color: var(--text-2); }
  .c-media { display: flex; flex-direction: column; gap: 2px; min-width: 0; font-size: 13px; }
  .mdetail { font-size: 12px; }
  .tone-faint { color: var(--text-3); }
  .tone-error .mdetail { color: var(--red); }
  .c-pos { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .scrubber { width: 200px; max-width: 100%; }
  .c-vals { display: contents; }
  .c-int, .c-mode, .c-audio, .c-src { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .c-int .mono { font-size: 13px; }
  .mode { overflow-wrap: anywhere; line-height: 1.2; }
  .c-audio { align-items: stretch; }
  .c-audio .bar { height: 6px; }
  .c-src { align-items: flex-start; }
  .pol { height: auto; min-height: 24px; padding: 2px 6px; white-space: normal; line-height: 1.2; font-size: 11px; }
  .c-dot { display: flex; flex-direction: column; align-items: center; gap: 4px; }
  .chip { font: 700 10px var(--font-ui); letter-spacing: 0.04em; text-align: center; line-height: 1.1; color: var(--text-2); }
  .chip-red { color: var(--red); }
  .chip-green { color: var(--green); }
  /* column labels: spoken on the desktop row (the heads are visual), drawn on the tile (no heads there) */
  .lbl { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }

  @media (max-width: 1320px) {
    .layer { grid-template-columns: 96px minmax(0, 1fr) auto; row-gap: 10px; align-items: start; align-content: start; height: 100%; padding: 12px; }
    .c-thumb { grid-row: 1 / span 2; }
    .c-name { grid-column: 2; grid-row: 1; }
    .c-dot { grid-column: 3; grid-row: 1; padding-top: 6px; flex-direction: row; }
    .c-media { grid-column: 2 / 4; grid-row: 2; }
    .c-pos { grid-column: 1 / -1; }
    .scrubber { width: 100%; }
    .c-vals { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 10px 20px; grid-column: 1 / -1; }
    .c-int { flex: 1 1 90px; }
    .c-mode { flex: 1 1 110px; }
    .lbl { position: static; width: auto; height: auto; overflow: visible; clip-path: none; font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
    .c-media .lbl { display: none; }
  }
</style>
