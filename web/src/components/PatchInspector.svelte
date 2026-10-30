<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { LOCKED_TITLE, UNIVERSE_SIZE, rangeText, universeName, type FixtureRow, type Status } from '../lib/patch-screen';

  // The inline editor of one fixture, inside its group (DESIGN §6.6 item 2): universe, address, Unpatch.
  let { row, status, options, defaultUniverse, onpatched }: {
    row: FixtureRow;
    status: Status;
    options: string[];
    /** shown (and used for the first address) while the fixture has no address */
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
    // a fixture without an address only remembers the universe for its first address
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
  const output = $derived(row.kind === 'output' && !row.optional ? app.project.outputs.find((o) => o.id === row.number) : undefined);
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

<div class="editor" role="group" aria-label="Patch of {row.name}">
  <p class="what">
    <span class="strong">{row.name}</span>
    <span class="mono muted">{row.footprint} ch{row.patched && row.universe ? ` · ${universeName(row.universe)} ${rangeText(row)}` : ''}</span>
    <span class="status tone-{status.tone}">{status.text}</span>
  </p>
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
          type="number" inputmode="numeric" min="0" max={maxAddress} step="1" aria-label="Address (0 = no address)"
          value={address} disabled={locked} title={locked ? LOCKED_TITLE : undefined}
          onchange={(e) => commitAddress(e.currentTarget)} />
        <button type="button" aria-label="Increase address" title={locked ? LOCKED_TITLE : 'Increase address (Shift: 10)'} disabled={locked || address >= maxAddress} onclick={(e) => apply(universe, clamp(address + (e.shiftKey ? 10 : 1)))}>+</button>
      </div>
    </div>
    <span class="spacer"></span>
    <button type="button" class="btn btn-ghost" disabled={locked || !row.patched} title={locked ? LOCKED_TITLE : undefined} onclick={() => apply(universe, 0)}>Unpatch</button>
    {#if output}
      <button type="button" class="btn btn-danger" disabled={locked} title={locked ? LOCKED_TITLE : 'Removes the output with its mapping (undo brings it back)'} onclick={removeOutput}>Remove output</button>
    {/if}
  </div>
</div>

<style>
  .editor { display: flex; flex-direction: column; gap: 12px; padding: 12px; border-radius: var(--radius-control); background: var(--surface-2); box-shadow: inset 3px 0 0 var(--accent); }
  .what { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; margin: 0; }
  .strong { font-weight: 600; font-size: 15px; }
  .status { font-size: 13px; color: var(--text-2); }
  .tone-faint { color: var(--text-3); }
  .tone-warn { color: var(--yellow); }
  .tone-bad { color: var(--red); }
  .fields { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 16px; }
  .fields .select { min-width: 140px; }
  .stepper button:disabled, .stepper input:disabled { color: var(--text-3); cursor: default; }
</style>
