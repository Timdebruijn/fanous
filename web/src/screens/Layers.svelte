<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script module lang="ts">
  // Module scope: the router unmounts this screen on navigation, the selected layer should survive that.
  const ui = $state({ selected: 1 });
</script>

<script lang="ts">
  import { onMount } from 'svelte';
  import LayerDetail from '../components/LayerDetail.svelte';
  import LayerRow from '../components/LayerRow.svelte';
  import LayerStrips from '../components/LayerStrips.svelte';
  import Preview from '../components/Preview.svelte';
  import { thumbnailFor, thumbnailIndex, type ChannelMap, type LibrarySnapshot } from '../lib/layers';
  import { go } from '../lib/router.svelte';
  import { app } from '../lib/state.svelte';

  let channelMap = $state.raw<ChannelMap | null>(null);
  let library = $state.raw<LibrarySnapshot | null>(null);

  async function getJSON<T>(url: string, signal: AbortSignal): Promise<T> {
    const response = await fetch(url, { signal });
    if (!response.ok) throw new Error(`${url}: ${response.status}`);
    return (await response.json()) as T;
  }

  // Failures leave the previous data in place: ranges show a dash, thumbnails stay empty boxes.
  onMount(() => {
    const abort = new AbortController();
    getJSON<ChannelMap>('/api/channel-map.json', abort.signal).then((map) => (channelMap = map), () => {});
    return () => abort.abort();
  });

  // Runs on mount and again when the engine reports a new library scan.
  $effect(() => {
    void app.live.library.scannedAt;
    const abort = new AbortController();
    getJSON<LibrarySnapshot>('/api/library', abort.signal).then((snapshot) => (library = snapshot), () => {});
    return () => abort.abort();
  });

  const layerCount = $derived(Math.max(0, Math.floor(app.project.layerCount) || 0));
  const numbers = $derived(Array.from({ length: layerCount }, (_, i) => i + 1));
  const selected = $derived(Math.min(Math.max(ui.selected, 1), Math.max(layerCount, 1)));
  const liveByIndex = $derived(new Map(app.live.layers.map((layer) => [layer.index, layer])));
  const patchByFixture = $derived(new Map(app.project.patch.map((entry) => [entry.fixture, entry])));
  const thumbs = $derived(thumbnailIndex(library));
</script>

<div class="toolbar">
  <h1>Layers</h1>
  <span class="caption">Canvas 1 · {layerCount} layers · <span title="Layer limit of this Mac's performance tier (chip class, see System). Add layer on Patch stops at this number so the show does not drop frames.">tier allows {app.caps.maxLayers ?? '—'} layers</span></span>
</div>

<LayerStrips />

{#if layerCount === 0}
  <div class="panel empty">
    <p class="muted">The project has no layers, so there is nothing to play on. Add layers on the Patch screen (this Mac's tier allows {app.caps.maxLayers ?? '—'}).</p>
    <button type="button" class="btn btn-primary" onclick={() => go('patch')}>Go to Patch</button>
  </div>
{:else}
  <div class="layout">
    <div class="table">
      <!-- visual only: every cell of a row carries its own spoken label -->
      <div class="heads" aria-hidden="true">
        <span class="h-layer">Layer</span>
        <span>Media</span>
        <span>Position</span>
        <span>Intensity</span>
        <span>Play mode</span>
        <span>Audio</span>
        <span>Source</span>
        <span></span>
      </div>
      <ul class="list">
        {#each numbers as n (n)}
          {@const layer = liveByIndex.get(n)}
          <li>
            <LayerRow
              {n}
              {layer}
              params={app.live.dmx.fixtures[`Layer ${n}`]}
              policy={app.live.dmx.policies[`Layer ${n}`] ?? app.project.policy}
              thumb={thumbnailFor(thumbs, layer)}
              selected={n === selected}
              onselect={() => (ui.selected = n)}
            />
          </li>
        {/each}
      </ul>
    </div>
    <div class="side">
      {#if app.live.engine.rendering}
        <Preview />
      {/if}
      <LayerDetail
        n={selected}
        layer={liveByIndex.get(selected)}
        params={app.live.dmx.fixtures[`Layer ${selected}`]}
        entry={patchByFixture.get(`Layer ${selected}`)}
        specs={channelMap?.modes.layer}
        {library}
        footprint={channelMap?.footprints.layer ?? 64}
      />
    </div>
  </div>
{/if}

<style>
  .empty { padding: 32px; display: flex; flex-direction: column; align-items: flex-start; gap: 12px; }
  .empty p { margin: 0; }
  .layout { display: flex; gap: 12px; align-items: flex-start; }
  .table {
    /* LayerRow reads these two; the heads below use the same grid so the columns line up. */
    --layer-cols: 96px 70px minmax(0, 1fr) 200px 64px 92px 56px 120px 84px;
    --layer-gap: 8px;
    flex: 1 1 0; min-width: 0; display: flex; flex-direction: column; gap: 6px;
  }
  .heads {
    display: grid; grid-template-columns: var(--layer-cols); column-gap: var(--layer-gap); padding: 0 13px;
    font-size: 11px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--text-3);
  }
  .h-layer { grid-column: span 2; }
  .list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
  .side { display: flex; flex-direction: column; gap: 12px; flex: 0 0 clamp(320px, 22vw, 360px); position: sticky; top: 16px; max-height: calc(100dvh - 32px); overflow-y: auto; border-radius: var(--radius-panel); }

  /* Rows need roughly 860 px of list; narrower than that (11" iPad landscape and down) they become tiles. Keep in step with LayerRow. */
  @media (max-width: 1320px) {
    .heads { display: none; }
    .list { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(380px, 100%), 1fr)); }
  }
  /* Below 1100 px the detail goes under the list. */
  @media (max-width: 1100px) {
    .layout { flex-direction: column; align-items: stretch; }
    .side { flex: none; position: static; max-height: none; overflow: visible; }
  }
</style>
