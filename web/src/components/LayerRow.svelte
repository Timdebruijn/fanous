<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { LayerStatus, ResolvedParameter } from '../lib/docs';
  import { clampPercent, findParam, formatPercent, layerState, mediaLine, playedPercent, positionCaption } from '../lib/layers';

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
    thumb: string | null;
    selected: boolean;
    onselect: () => void;
  } = $props();

  const media = $derived(mediaLine(layer));
  const status = $derived(layerState(layer));
  const isMovie = $derived(layer?.kind === 'movie');
  const intensity = $derived(findParam(params, 'intensity'));
  const playMode = $derived(findParam(params, 'playMode'));
  const speed = $derived(findParam(params, 'speed'));
  const inPoint = $derived(findParam(params, 'inPoint'));
  const outPoint = $derived(findParam(params, 'outPoint'));
  const volume = $derived(findParam(params, 'audioVolume'));
  const level = $derived(clampPercent(volume?.physical ?? 0));
</script>

<!-- Column widths come from --layer-cols / --layer-gap, set by the Layers screen so its column heads line up. -->
<button type="button" class="row layer" aria-pressed={selected} onclick={onselect}>
  <span class="thumb c-thumb">
    {#if thumb}<img src={thumb} alt="" loading="lazy" />{/if}
    <span class="n">{n}</span>
  </span>
  <span class="c-name">
    <span class="nm">Layer {n}</span>
    <span class="caption">Canvas 1</span>
  </span>
  <span class="c-media mono tone-{media.tone}" title={media.text}><span class="lbl">Media: </span>{media.text}</span>
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
    <span class="c-audio" title="Bars follow the audioVolume parameter; there is no real level meter yet">
      <span class="lbl">Audio</span>
      <span class="meter" role="img" aria-label="Audio volume {formatPercent(volume?.physical ?? 0)} % (no level meter yet)">
        <span style:height="{level}%"></span>
        <span style:height="{level}%"></span>
      </span>
      <span class="caption">volume</span>
    </span>
    <span class="c-src">
      <span class="lbl">Source</span>
      <span class="badge badge-outline">{policy.toUpperCase()}</span>
    </span>
  </span>
  <span class="c-dot"><span class="dot dot-{status.dot}" role="img" aria-label={status.label} title={status.label}></span></span>
</button>

<style>
  /* Desktop row: one grid line per layer. Narrower than 1320 px the row becomes a tile (the list is a tile grid there). */
  .layer {
    display: grid; grid-template-columns: var(--layer-cols); column-gap: var(--layer-gap); align-items: center;
    min-height: var(--row); font-size: 13px;
  }
  .c-thumb { display: block; flex: none; width: 96px; height: 54px; border: 1px solid var(--line); background: var(--ground); }
  .c-name { display: flex; flex-direction: column; min-width: 0; }
  .nm { font-weight: 600; font-size: 14px; }
  .c-media { font-size: 12px; line-height: 1.35; min-width: 0; overflow-wrap: anywhere; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 3; line-clamp: 3; overflow: hidden; }
  .tone-faint { color: var(--text-3); }
  .tone-error { color: var(--red); }
  .c-pos { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .scrubber { width: 200px; max-width: 100%; }
  .c-vals { display: contents; }
  .c-int, .c-mode, .c-audio, .c-src { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .c-int .mono { font-size: 13px; }
  .mode { overflow-wrap: anywhere; line-height: 1.2; }
  .c-audio { align-items: flex-start; }
  .c-audio .meter { height: 36px; }
  /* the shared gradient spans the full meter height, so a low level stays green */
  .c-audio .meter span { background-size: 8px 36px; background-position: bottom; background-repeat: no-repeat; min-height: 2px; }
  .c-src { align-items: flex-start; }
  .c-dot { display: flex; justify-content: center; }
  /* column labels: spoken on the desktop row (the heads are visual), drawn on the tile (no heads there) */
  .lbl { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }

  @media (max-width: 1320px) {
    .layer { grid-template-columns: 96px minmax(0, 1fr) auto; row-gap: 10px; align-items: start; align-content: start; height: 100%; padding: 12px; }
    .c-thumb { grid-row: 1 / span 2; }
    .c-name { grid-column: 2; grid-row: 1; }
    .c-dot { grid-column: 3; grid-row: 1; padding-top: 6px; }
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
