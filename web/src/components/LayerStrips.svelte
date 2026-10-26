<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { ResolvedParameter } from '../lib/docs';
  import { findParam, outputFixtures, valueText } from '../lib/layers';
  import { app } from '../lib/state.svelte';

  // Select puts Master or an output in the Layers side panel, where its Control switch sets it from the UI (B27).
  let { selected = null, onselect }: { selected?: string | null; onselect?: (fixture: string) => void } = $props();

  const master = $derived(app.live.dmx.fixtures['Master']);
  const outputs = $derived(outputFixtures(app.live.dmx.fixtures));
</script>

{#snippet value(params: ResolvedParameter[] | undefined, key: string, caption: string)}
  {@const param = findParam(params, key)}
  <span class="val">
    <span class="mono v">{param ? valueText(param) : '—'}</span>
    <span class="caption">{caption}</span>
  </span>
{/snippet}

{#snippet pick(fixture: string)}
  {#if onselect}
    <button type="button" class="btn pick" aria-pressed={selected === fixture} onclick={() => onselect(fixture)}>{selected === fixture ? 'Selected' : 'Select'}</button>
  {/if}
{/snippet}

<div class="strips" role="group" aria-label="Master and outputs">
  <section class="panel strip" aria-label="Master">
    <span class="name">Master</span>
    {@render value(master, 'intensity', 'Intensity')}
    {@render value(master, 'speed', 'Speed')}
    {@render value(master, 'control', 'Control')}
    {@render value(master, 'testPattern', 'Test pattern')}
    {@render pick('Master')}
  </section>
  {#each outputs as name (name)}
    {@const params = app.live.dmx.fixtures[name]}
    <section class="panel strip" aria-label={name}>
      <span class="name"><span class="dot dot-green" aria-hidden="true"></span>{name}</span>
      {@render value(params, 'intensity', 'Intensity')}
      {@render value(params, 'control', 'Control')}
      {@render value(params, 'testPattern', 'Test pattern')}
      {@render value(params, 'blend', 'Blend')}
      {@render pick(name)}
    </section>
  {/each}
</div>

<style>
  .strips { display: flex; flex-wrap: wrap; gap: 8px; }
  .strip { flex: 1 1 280px; min-width: 0; min-height: 56px; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 20px; padding: 8px 16px; }
  .name { display: inline-flex; align-items: center; gap: 8px; min-width: 64px; font-size: 12px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--text-2); }
  .val { display: flex; flex-direction: column; min-width: 0; }
  .pick { margin-left: auto; }
  .pick[aria-pressed='true'] { border-color: var(--accent); color: var(--accent); }
  .v { font-size: 15px; font-weight: 500; }
</style>
