<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { LOCKED_TITLE, rangeText, rowStatus, rowSummary, universeName, type FixtureRow } from '../lib/patch-screen';

  let { rows, selected, onselect }: { rows: FixtureRow[]; selected: string; onselect: (name: string) => void } = $props();

  const locked = $derived(!can('programmer'));
  const layerCount = $derived(app.project.layerCount);
  /** `caps.maxLayers` is undefined until the welcome arrives; the protocol allows 1-64 anyway */
  const maxLayers = $derived(typeof app.caps.maxLayers === 'number' ? app.caps.maxLayers : undefined);
  const atLimit = $derived(layerCount >= Math.min(64, maxLayers ?? 64));

  function setLayerCount(count: number) {
    void cmd('layers.setCount', { count });
  }
  async function removeLast() {
    const n = layerCount;
    if ((await cmd('layers.setCount', { count: n - 1 })) !== undefined) toastUndo(`Layer ${n} removed.`);
  }
</script>

<section class="panel table" aria-label="Fixtures">
  <div class="fx fx-head caption" aria-hidden="true">
    <span class="c-name">Fixture</span>
    <span class="c-type">Type</span>
    <span class="c-uni">Universe</span>
    <span class="c-addr">Address</span>
    <span class="c-range">Footprint</span>
    <span class="c-status">Status</span>
  </div>
  <div class="rows" role="group" aria-label="Fixture list">
    {#each rows as r (r.name)}
      {@const st = rowStatus(r)}
      <button type="button" class="list-row fx" aria-pressed={r.name === selected} aria-label={rowSummary(r)} onclick={() => onselect(r.name)}>
        <span class="sw" style:background={r.colour}></span>
        <span class="c-name name ellipsis">{r.name}</span>
        <span class="c-type type">{r.typeLabel} · {r.footprint}</span>
        <span class="c-uni mono muted">{r.patched && r.universe ? universeName(r.universe) : '—'}</span>
        <span class="c-addr mono">{r.patched ? r.address : '—'}</span>
        <span class="c-range mono muted">{rangeText(r)}</span>
        <span class="c-status status" class:muted={st.tone === 'ok'} class:faint={st.tone === 'faint'} class:bad={st.tone === 'bad'}>{st.text}</span>
      </button>
    {/each}
  </div>
  <div class="foot">
    <button type="button" class="btn" disabled={locked || atLimit} title={locked ? LOCKED_TITLE : atLimit ? 'Layer limit of this Mac (performance tier)' : undefined} onclick={() => setLayerCount(layerCount + 1)}>Add layer</button>
    <span class="caption">{layerCount} of {maxLayers ?? '?'} layers · <span title="The layer limit of this Mac's performance tier; Add layer stops there so the show does not drop frames.">tier limit</span> measured on this machine</span>
    <span class="spacer"></span>
    <button type="button" class="btn btn-danger" disabled={locked || layerCount <= 1} title={locked ? LOCKED_TITLE : undefined} onclick={removeLast}>Remove layer {layerCount}</button>
  </div>
</section>

<style>
  .table { container-type: inline-size; overflow: hidden; }
  .rows { max-height: 480px; overflow-y: auto; }
  .fx { display: grid; grid-template-columns: 12px 88px 96px 60px 48px 60px minmax(0, 1fr); column-gap: 8px; align-items: center; }
  .fx-head { min-height: 32px; padding: 0 12px; border-bottom: 1px solid var(--line); }
  .fx-head .c-name { grid-column: 1 / span 2; }
  .fx .c-addr { text-align: right; }
  .list-row.fx { padding-top: 6px; padding-bottom: 6px; font-size: 13px; }
  .sw { width: 12px; height: 12px; border-radius: 3px; border: 1px solid var(--line-strong); }
  .name { font-weight: 600; font-size: 14px; }
  .status { line-height: 1.25; }
  .bad { color: var(--red); }
  .foot { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 12px; }
  /* narrow panels (phones, split views): three lines per fixture, still column-aligned */
  @container (max-width: 560px) {
    .fx-head { display: none; }
    .list-row.fx {
      grid-template-columns: 12px minmax(0, 1fr) auto auto;
      grid-template-areas: 'sw name name addr' '. type uni range' '. status status status';
      gap: 2px 10px; padding-top: 8px; padding-bottom: 8px;
    }
    .fx .sw { grid-area: sw; }
    .fx .c-name { grid-area: name; }
    .fx .c-type { grid-area: type; }
    .fx .c-uni { grid-area: uni; }
    .fx .c-addr { grid-area: addr; }
    .fx .c-range { grid-area: range; text-align: right; }
    .fx .c-status { grid-area: status; }
  }
</style>
