<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, subscribeDMX } from '../lib/state.svelte';
  import { UNIVERSE_SIZE, buildCells, cellLabel, frameValues, paramName, universeName, type ChannelMap, type FixtureRow } from '../lib/patch-screen';

  let { universes, universe, onuniverse, rows, selected, map }: {
    /** every universe the switcher offers (patched and live) */
    universes: string[];
    universe: string | null;
    onuniverse: (id: string) => void;
    rows: FixtureRow[];
    /** name of the fixture selected in the table: its cells get a faint outline */
    selected: string;
    map: ChannelMap | null;
  } = $props();

  const ZEROS = new Uint8Array(UNIVERSE_SIZE);
  /** one signal for the whole frame: replaced once per packet, never written per cell */
  let values = $state.raw<Uint8Array>(ZEROS);
  let pinned = $state<number | null>(null);
  let grid: HTMLDivElement | undefined = $state();

  const cells = $derived(buildCells(rows, universe, map));
  const inUniverse = $derived(rows.filter((r) => r.patched && r.universe === universe));
  const pinCell = $derived(pinned === null ? null : (cells[pinned - 1] ?? null));
  const pinParam = $derived.by(() => {
    const c = pinCell;
    if (!c?.owner || !c.at || c.at.fine || c.collision) return null;
    return app.live.dmx.fixtures[c.owner.name]?.find((p) => p.key === c.at!.spec.key) ?? null;
  });
  /** first channel of the selected fixture when it lives in the shown universe */
  const focusStart = $derived.by(() => {
    const r = rows.find((x) => x.name === selected);
    return r?.patched && r.universe === universe ? r.address : 0;
  });

  let shown: string | null = null;
  $effect(() => {
    const id = universe;
    if (id !== shown) {
      shown = id;
      values = ZEROS;
      pinned = null;
    }
    // the effect re-runs when the connection (re)opens, which resubscribes after a reconnect
    if (id === null || app.connection !== 'open') return;
    let stop: (() => void) | undefined;
    let cancelled = false;
    subscribeDMX(id, (payload) => {
      if (!cancelled) values = frameValues(payload);
    }).then(
      (unsubscribe) => (cancelled ? unsubscribe() : (stop = unsubscribe)),
      () => {
        /* offline: the connection banner says so */
      },
    );
    return () => {
      cancelled = true;
      stop?.();
    };
  });

  // bring the selected fixture's first row into view (40 px = 38 px cell + 2 px gap)
  $effect(() => {
    if (focusStart > 0 && grid) grid.scrollTop = Math.floor((focusStart - 1) / 16) * 40;
  });

  function togglePin(ch: number) {
    pinned = pinned === ch ? null : ch;
  }
</script>

<section class="panel monitor" aria-label="DMX monitor">
  <div class="head">
    <h2>DMX monitor</h2>
    {#if universes.length > 0}
      <div class="segmented" role="group" aria-label="Universe">
        {#each universes as id (id)}
          <button type="button" class="btn" aria-pressed={id === universe} onclick={() => onuniverse(id)}>{universeName(id)}</button>
        {/each}
      </div>
    {/if}
    <span class="spacer"></span>
    <span class="caption">tap a cell to pin it</span>
  </div>

  {#if universe === null}
    <p class="empty muted">No universe is patched or heard yet. Patch a fixture to watch its universe here.</p>
  {:else}
    <div class="pin">
      {#if pinCell}
        <span class="mono strong">ch {pinCell.ch}</span>
        {#if pinCell.collision}
          <span class="alert">collision</span>
          <span class="ellipsis">{pinCell.owners.join(' + ')}</span>
        {:else if pinCell.owner}
          <span class="sw" style:background={pinCell.owner.colour}></span>
          <span class="strong ellipsis">{pinCell.owner.name}</span>
          <span class="muted">ch {pinCell.rel}{paramName(pinCell) ? ` · ${paramName(pinCell)}` : ''}</span>
        {:else}
          <span class="faint">unpatched</span>
        {/if}
        <span class="spacer"></span>
        <span class="mono">{values[pinCell.ch - 1]}{pinParam?.label ? ` → ${pinParam.label}` : ''}</span>
      {:else}
        <span class="faint">No cell pinned</span>
      {/if}
    </div>

    <div class="grid" bind:this={grid}>
      {#each cells as cell (cell.ch)}
        <button
          type="button" class="cell" class:un={!cell.owner} class:bad={cell.collision}
          class:pinned={pinned === cell.ch} class:sel={cell.owners.includes(selected)}
          style:background={cell.owner && !cell.collision ? cell.owner.colour : undefined}
          aria-label={cellLabel(cell)} aria-pressed={pinned === cell.ch} onclick={() => togglePin(cell.ch)}
        >{values[cell.ch - 1]}</button>
      {/each}
    </div>

    <ul class="legend">
      {#each inUniverse as r (r.name)}
        <li><span class="sw" style:background={r.colour}></span>{r.name}</li>
      {/each}
      <li><span class="sw collision"></span>collision</li>
      <li><span class="sw unpatched"></span>unpatched</li>
    </ul>
  {/if}
</section>

<style>
  .monitor { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .head { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  .segmented { max-width: 100%; overflow-x: auto; }
  .empty { margin: 0; }
  .pin { display: flex; flex-wrap: wrap; align-items: center; gap: 2px 12px; min-height: 48px; padding: 6px 12px; background: var(--surface-2); border: 1px solid var(--line); border-radius: 8px; }
  .strong { font-weight: 700; }
  .alert { color: var(--red); }
  .sw { display: inline-block; width: 12px; height: 12px; flex: none; border-radius: 3px; border: 1px solid var(--line-strong); }
  .sw.collision { background: var(--red-bg); border-color: var(--red); }
  .sw.unpatched { background: var(--surface-2); border-color: var(--line); }
  .grid { display: grid; grid-template-columns: repeat(16, minmax(0, 1fr)); gap: 2px; max-height: 560px; overflow: auto; padding: 2px; }
  .cell { height: 38px; min-width: 0; padding: 0; border: 1px solid transparent; border-radius: 3px; color: var(--text-1); font: 500 11px var(--font-mono); text-align: center; overflow: hidden; }
  .cell:hover { border-color: var(--line-strong); }
  .cell.un { background: var(--surface-2); border-color: var(--line); color: var(--text-3); }
  .cell.bad { background: var(--red-bg); border-color: var(--red); }
  .cell.sel { outline: 1px solid color-mix(in srgb, var(--accent) 55%, transparent); outline-offset: -1px; }
  .cell.pinned { outline: 2px solid var(--accent); outline-offset: 0; position: relative; z-index: 1; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 0; padding: 0; list-style: none; font-size: 12px; color: var(--text-2); }
  .legend li { display: inline-flex; align-items: center; gap: 6px; }
  @media (max-width: 480px) {
    .monitor { padding: 8px; }
    .cell { font-size: 9px; letter-spacing: -0.06em; }
  }
</style>
