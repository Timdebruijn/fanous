<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { LOCKED_TITLE, UNIVERSE_SIZE, interfaceOptions, parseUniverseName, universeHealth, universeName, universeSettings, type FixtureRow } from '../lib/patch-screen';

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
  const settings = $derived(universeSettings(app.project.universes, row.universe ?? ''));
  const health = $derived(universeHealth(info, settings.lossTimeout));
  const own = $derived(settings.id.startsWith('sacn:') ? 'sacn' : 'artnet');
  const interfaces = $derived(interfaceOptions(app.live.system.interfaces, settings.interface));
  const absent = $derived(interfaces.find((o) => o.value === settings.interface)?.label.endsWith('(not present)') ?? false);
  const uLockTitle = $derived(locked ? LOCKED_TITLE : app.project.showLock ? 'Locked: show lock is on' : undefined);

  /** One universe setting; a refused change (show lock, invalid value) puts the control back. */
  async function setUniverse(path: string, value: string | number | null, el: HTMLInputElement | HTMLSelectElement, previous: string) {
    await cmd('universe.set', { id: settings.id, path: path as '/protocol', value });
    if (app.lastError) el.value = previous;
  }

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
  const output = $derived(row.type === 'output' && !row.orphan ? app.project.outputs.find((o) => `Output ${o.id}` === row.name) : undefined);
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

  <hr />
  {#if row.patched && row.universe}
    <div class="uhead">
      <h3>Universe {universeName(row.universe)}</h3>
      <span class="pill pill-{health.tone}"><span class="dot"></span>{health.text}</span>
    </div>
    <div class="fields">
      <label class="field">
        <span class="label">Protocol</span>
        <select class="select" value={settings.protocol} disabled={!!uLockTitle} title={uLockTitle} onchange={(e) => setUniverse('/protocol', e.currentTarget.value, e.currentTarget, settings.protocol)}>
          <option value="artnet">Art-Net</option>
          <option value="sacn">sACN</option>
          <option value="both">Art-Net + sACN</option>
        </select>
      </label>
      {#if settings.protocol !== own}
        <label class="field" title={uLockTitle ?? 'The other protocol\'s universe that feeds this one, e.g. S 1 or A 0.0.0'}>
          <span class="label">{own === 'artnet' ? 'sACN universe' : 'Art-Net universe'}</span>
          <input class="input mono pair" value={universeName(settings.pair)} disabled={!!uLockTitle}
            onchange={(e) => setUniverse('/pair', parseUniverseName(e.currentTarget.value), e.currentTarget, universeName(settings.pair))} />
        </label>
      {/if}
      <label class="field">
        <span class="label">Interface</span>
        <select class="select" value={settings.interface} disabled={!!uLockTitle} title={uLockTitle} onchange={(e) => setUniverse('/interface', e.currentTarget.value, e.currentTarget, settings.interface)}>
          {#each interfaces as option (option.value)}
            <option value={option.value}>{option.label}</option>
          {/each}
        </select>
      </label>
      <label class="field">
        <span class="label">Hold on loss</span>
        <select class="select" value={settings.holdOnLoss} disabled={!!uLockTitle} title={uLockTitle} onchange={(e) => setUniverse('/holdOnLoss', e.currentTarget.value, e.currentTarget, settings.holdOnLoss)}>
          <option value="hold">Hold last values</option>
          <option value="zero">Go to zero</option>
          <option value="internal">UI and cues take over</option>
        </select>
      </label>
      <label class="field">
        <span class="label">Loss after (s)</span>
        <input class="input mono timeout" type="number" min="1" max="60" step="0.5" value={settings.lossTimeout} disabled={!!uLockTitle} title={uLockTitle}
          onchange={(e) => setUniverse('/lossTimeout', Number(e.currentTarget.value), e.currentTarget, String(settings.lossTimeout))} />
      </label>
      {#if settings.protocol !== 'artnet'}
        <label class="field">
          <span class="label">sACN priority</span>
          <select class="select" value={settings.sacnPriorityMode} disabled={!!uLockTitle} title={uLockTitle} onchange={(e) => setUniverse('/sacnPriorityMode', e.currentTarget.value, e.currentTarget, settings.sacnPriorityMode)}>
            <option value="highest">Highest wins</option>
            <option value="htp">Merge equal (HTP)</option>
          </select>
        </label>
      {/if}
    </div>
    {#if absent}
      <p class="caption alert">Interface {settings.interface} is not on this Mac: the universe receives nothing until it is connected.</p>
    {/if}
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
  .pair { width: 110px; }
  .timeout { width: 80px; }
  .alert { color: var(--yellow); }
  p { margin: 0; }
</style>
