<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { LOCKED_TITLE, UNIVERSE_SIZE, universeName, type FixtureRow } from '../lib/patch-screen';

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

  /** The output behind an Output fixture; removing it also unpatches the fixture (one undo step). */
  const output = $derived(row.type === 'output' ? app.project.outputs.find((o) => `Output ${o.id}` === row.name) : undefined);
  async function removeOutput() {
    if (!output) return;
    const name = output.name;
    if ((await cmd('output.remove', { id: output.id })) !== undefined) toastUndo(`${name} removed.`);
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
  {#if output}
    <p class="caption">
      The console channels of {output.name === row.name ? 'this output' : output.name}, {output.display ? `shown on ${output.display.name}` : 'not on a display yet'}.
      Display, picture and mapping are on <a href="#/outputs">Outputs &amp; Mapping</a>.
    </p>
  {/if}
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
    {#if output}
      <button type="button" class="btn btn-danger" disabled={locked} title={locked ? LOCKED_TITLE : 'Removes the output with its mapping (undo brings it back)'} onclick={removeOutput}>Remove output</button>
    {/if}
  </div>
</section>

<style>
  .inspector { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .fields { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 16px; }
  .fields .select { min-width: 140px; }
  .stepper button:disabled, .stepper input:disabled { color: var(--text-3); cursor: default; }
  .ro { display: inline-flex; align-items: center; min-height: var(--touch); color: var(--text-2); }
  p { margin: 0; }
</style>
