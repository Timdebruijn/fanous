<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd } from '../lib/state.svelte';
  import { LOCKED_TITLE, UNIVERSE_SIZE, universeHealth, universeName, universeSettings, type FixtureRow } from '../lib/patch-screen';

  let { row, options, defaultUniverse, onpatched }: {
    row: FixtureRow;
    options: string[];
    /** shown (and used for the first address) while the fixture is unpatched */
    defaultUniverse: string;
    /** a patch.set that put the fixture on a universe was accepted */
    onpatched: (universe: string) => void;
  } = $props();

  const locked = $derived(!can('programmer'));
  const maxAddress = $derived(Math.max(0, UNIVERSE_SIZE - row.footprint + 1));
  // Drafts: they follow the patch until edited, so quick repeated taps add up before the engine answers.
  let universe = $derived(row.universe ?? defaultUniverse);
  let address = $derived(row.address);

  const info = $derived(row.universe ? app.live.dmx.universes.find((u) => u.id === row.universe) : undefined);
  const health = $derived(universeHealth(info));
  const settings = $derived(universeSettings(row.universe ?? ''));

  function clamp(n: number): number {
    return Math.min(maxAddress, Math.max(0, Math.round(n)));
  }

  async function apply(nextUniverse: string, nextAddress: number) {
    universe = nextUniverse;
    address = nextAddress;
    // an unpatched fixture only remembers the universe for its first address
    if (nextAddress === 0 && !row.patched) return;
    await cmd('patch.set', { fixture: row.name, universe: nextUniverse, address: nextAddress });
    if (app.lastError) {
      // refused (show lock, ...): the banner says why; show the patch again
      universe = row.universe ?? defaultUniverse;
      address = row.address;
    } else if (nextAddress > 0) {
      onpatched(nextUniverse);
    }
  }

  function commitAddress(input: HTMLInputElement) {
    const typed = input.value.trim();
    const next = typed === '' || Number.isNaN(Number(typed)) ? address : clamp(Number(typed));
    input.value = String(next);
    if (next !== address) void apply(universe, next);
  }
</script>

<section class="panel inspector" aria-label="Selected fixture">
  <div class="label">Selected fixture</div>
  <h2>{row.name}</h2>
  <div class="fields">
    <label class="field">
      <span class="label">Universe</span>
      <select class="select" value={universe} disabled={locked} title={locked ? LOCKED_TITLE : undefined} onchange={(e) => apply(e.currentTarget.value, address)}>
        {#each options as id (id)}
          <option value={id}>{universeName(id)}</option>
        {/each}
      </select>
    </label>
    <div class="field" role="group" aria-label="Address">
      <span class="label" aria-hidden="true">Address</span>
      <div class="stepper">
        <button type="button" aria-label="Decrease address" title={locked ? LOCKED_TITLE : 'Decrease address (Shift: 10)'} disabled={locked || address <= 0} onclick={(e) => apply(universe, clamp(address - (e.shiftKey ? 10 : 1)))}>−</button>
        <input
          type="number" inputmode="numeric" min="0" max={maxAddress} step="1" aria-label="Address (0 = unpatched)"
          value={address} disabled={locked} title={locked ? LOCKED_TITLE : undefined}
          onchange={(e) => commitAddress(e.currentTarget)} />
        <button type="button" aria-label="Increase address" title={locked ? LOCKED_TITLE : 'Increase address (Shift: 10)'} disabled={locked || address >= maxAddress} onclick={(e) => apply(universe, clamp(address + (e.shiftKey ? 10 : 1)))}>+</button>
      </div>
    </div>
    <div class="field">
      <span class="label">Footprint</span>
      <span class="mono ro">{row.footprint} channels</span>
    </div>
    <span class="spacer"></span>
    <button type="button" class="btn btn-ghost" disabled={locked || !row.patched} title={locked ? LOCKED_TITLE : undefined} onclick={() => apply(universe, 0)}>Unpatch</button>
  </div>

  <hr />
  {#if row.patched && row.universe}
    <div class="uhead">
      <h3>Universe {universeName(row.universe)}</h3>
      <span class="pill pill-{health.tone}"><span class="dot"></span>{health.text}</span>
    </div>
    <dl>
      <div><dt>Protocol</dt><dd class="mono">{settings.protocol}</dd></div>
      <div><dt>Interface</dt><dd class="mono">{settings.iface}</dd></div>
      <div><dt>Hold on loss</dt><dd class="mono">{settings.holdOnLoss}</dd></div>
      <div><dt>sACN priority</dt><dd class="mono">{settings.priority}</dd></div>
    </dl>
    <p class="caption">Per-universe settings arrive with projects (B28)</p>
  {:else}
    <p class="caption">Not patched: set an address to start listening on a universe.</p>
  {/if}
</section>

<style>
  .inspector { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .fields { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 16px; }
  .fields .select { min-width: 140px; }
  .stepper button:disabled, .stepper input:disabled { color: var(--text-3); cursor: default; }
  .ro { display: inline-flex; align-items: center; min-height: var(--touch); color: var(--text-2); }
  hr { width: 100%; margin: 4px 0; border: 0; border-top: 1px solid var(--line); }
  .uhead { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  h3 { margin: 0; font-size: 15px; font-weight: 600; }
  dl { display: flex; flex-wrap: wrap; gap: 8px 24px; margin: 0; }
  dl > div { display: flex; flex-direction: column; gap: 2px; }
  dt { font-size: 12px; color: var(--text-3); }
  dd { margin: 0; color: var(--text-2); }
  p { margin: 0; }
</style>
