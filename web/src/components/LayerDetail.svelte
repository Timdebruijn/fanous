<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { LayerStatus, PatchEntry, ResolvedParameter } from '../lib/docs';
  import { channelRange, patchText, reservedText, valueText, type ChannelSpec } from '../lib/layers';

  let {
    n,
    layer,
    params,
    entry,
    specs,
    footprint,
  }: {
    n: number;
    layer: LayerStatus | undefined;
    params: ResolvedParameter[] | undefined;
    entry: PatchEntry | undefined;
    specs: ChannelSpec[] | undefined;
    footprint: number;
  } = $props();

  const specByKey = $derived(new Map((specs ?? []).map((spec) => [spec.key, spec])));
  const missing = $derived(layer?.kind === 'missing');
</script>

<section class="panel detail" aria-labelledby="layer-detail-title">
  <header>
    <h2 id="layer-detail-title">Layer {n}</h2>
    <p class="caption mono">{patchText(entry, footprint)}</p>
  </header>

  <ul class="params">
    {#each params ?? [] as param (param.key)}
      <li class="param">
        <span class="ch mono faint">{channelRange(specByKey.get(param.key))}</span>
        <span class="nm ellipsis" title={param.name}>{param.name}</span>
        <span class="raw mono">{param.raw}</span>
        <span class="val mono ellipsis" class:red={missing && (param.key === 'file' || param.key === 'folder')} title={valueText(param)}>{valueText(param)}</span>
      </li>
    {:else}
      <li class="param none"><span class="caption">No resolved values from the engine yet.</span></li>
    {/each}
  </ul>
  {#if specs}<p class="caption note">{reservedText(specs, footprint)}</p>{/if}
</section>

<style>
  .detail { padding: 12px 12px 16px; display: flex; flex-direction: column; gap: 8px; }
  header { padding: 0 4px; }
  header p { margin: 2px 0 0; }
  .params { list-style: none; margin: 0; padding: 0; }
  .param { display: grid; grid-template-columns: 40px minmax(0, 1fr) 40px 88px; align-items: center; column-gap: 8px; min-height: var(--touch); padding: 0 4px; border-top: 1px solid var(--line); font-size: 13px; }
  .none { display: block; padding-top: 12px; }
  .ch { font-size: 12px; }
  .raw { text-align: right; }
  .val { color: var(--text-2); font-size: 12px; }
  .val.red { color: var(--red); }
  .note { margin: 0; padding: 0 4px; }
</style>
