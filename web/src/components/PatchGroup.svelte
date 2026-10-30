<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { tick } from 'svelte';
  import PatchInspector from './PatchInspector.svelte';
  import type { PatchEntry } from '../lib/docs';
  import { lockTitle } from '../lib/show';
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import {
    MAX_LAYERS, MAX_OUTPUTS, UNIVERSE_SIZE, groupSlots, layEntries, moveAfterLayers, patchTarget, rowStatus, rowSummary, slotText, standardStart, universeName,
    type FixtureRow, type Group, type Slot,
  } from '../lib/patch-screen';

  // One group of the Patch screen (DESIGN §6.6 item 2): its block, its fixtures as chips (one mode) or as a row per
  // number (Output n with Keystone n), and the inline editor of the open fixture.
  let { group, index, groups, rows, options, selected, onselect, onpatched }: {
    group: Group;
    index: number;
    /** every group: Patch as block counts from the ones before, Move Master and outputs lays the ones after */
    groups: Group[];
    /** every fixture, for a free range */
    rows: FixtureRow[];
    /** universe choices */
    options: string[];
    /** the fixture whose editor is open */
    selected: string | null;
    onselect: (name: string | null) => void;
    /** a patch put a fixture on this universe */
    onpatched: (universe: string) => void;
  } = $props();

  // chips stay clickable when locked, so the editor can still be read
  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const locked = $derived(!!lock);
  const policy = $derived(app.project.policy);
  const block = $derived(group.block);
  const first = $derived(group.modes[0]!);
  const open = $derived(group.rows.find((r) => r.name === selected));
  const move = $derived(group.ownUniverses ? moveAfterLayers(groups) : null);
  const standard = $derived(standardStart(groups, index));
  /** the universe a chip's address is read in; a chip elsewhere names its universe */
  const home = $derived(block.start?.universe ?? block.anchor?.universe ?? null);
  const blocked = $derived(group.rows.filter((r) => r.blocked));
  /** a row per number holding each mode's fixture (Output n and Keystone n); a group of one mode is a line of chips */
  const lines = $derived(group.modes.length > 1 ? group.numbers.map((n) => ({ n, rows: group.rows.filter((r) => r.number === n) })) : []);

  let section: HTMLElement | undefined = $state();
  let blockLine: HTMLElement | undefined = $state();
  /** why the last block change sent nothing */
  let notice = $state<string | null>(null);

  /** Opens a fixture's editor and moves the focus into it; its chip again closes it. */
  async function toggle(name: string) {
    const opening = name !== selected;
    onselect(opening ? name : null);
    if (!opening) return;
    await tick();
    section?.querySelector<HTMLElement>('[data-editor]')?.focus();
  }

  /** One `patch.setMany` (one undo step) with a toast; false when refused (the banner says why). */
  async function setMany(entries: PatchEntry[], text: string): Promise<boolean> {
    if ((await cmd('patch.setMany', { entries })) === undefined) return false;
    toastUndo(text);
    const universe = entries.find((e) => e.address > 0)?.universe;
    if (universe) onpatched(universe);
    return true;
  }

  function moved(n: number): string {
    return n > 0 ? ` ${n} hand-placed fixture${n === 1 ? '' : 's'} moved.` : '';
  }

  /** Lays the group from `start`; `verb` says how ("moved to", "re-laid as a block from"). Nothing is sent when the block runs past the last universe. */
  async function lay(start: Slot | null, verb: string, handPlaced: number): Promise<boolean> {
    notice = null;
    if (!start) return false;
    const { entries, past } = layEntries(group, start);
    if (past.length > 0) {
      notice = `From ${universeName(start.universe)} ${start.address}, ${past[0]!.name}${past.length > 1 ? ` and ${past.length - 1} more` : ''} would run past the last universe; nothing was patched.`;
      return false;
    }
    return setMany(entries, `${group.title} ${verb} ${universeName(start.universe)} ${start.address}.${moved(handPlaced)}`);
  }

  /** After a button that goes away with the change, the focus goes to the block line. */
  async function layThenFocus(start: Slot | null, verb: string, handPlaced: number) {
    if (!(await lay(start, verb, handPlaced))) return;
    await tick();
    blockLine?.focus();
  }

  /** Moves the block to a new start; a refused move puts the field back. */
  async function moveTo(el: HTMLInputElement | HTMLSelectElement, start: Slot, to: Slot) {
    if (!(await lay(to, 'moved to', block.handPlaced))) el.value = String(el instanceof HTMLSelectElement ? start.universe : start.address);
  }

  function moveAddress(input: HTMLInputElement, start: Slot) {
    const typed = Math.round(Number(input.value));
    const address = Number.isFinite(typed) && input.value.trim() !== '' ? Math.min(UNIVERSE_SIZE + 1 - first.footprint, Math.max(1, typed)) : start.address;
    input.value = String(address);
    if (address !== start.address) void moveTo(input, start, { universe: start.universe, address });
  }

  async function moveAfter(entries: PatchEntry[]) {
    if (!(await setMany(entries, 'Master and outputs moved after the layers.'))) return;
    await tick();
    blockLine?.focus();
  }

  /** A Keystone's Patch: its slot, else the first free range after it; else its editor opens. The focus stays on its chip. */
  async function patch(r: FixtureRow) {
    const slot = patchTarget(group, r, rows);
    if (!slot) return toggle(r.name);
    await cmd('patch.set', { fixture: r.name, ...slot });
    if (app.lastError) return;
    onpatched(slot.universe);
    await tick();
    section?.querySelector<HTMLElement>(`[data-fixture="${CSS.escape(r.name)}"]`)?.focus();
  }

  // Layers: the count, with the tier limit and Remove's undo toast
  const layerCount = $derived(app.project.layerCount);
  /** `caps.maxLayers` is undefined until the welcome arrives; the protocol allows 1-64 anyway */
  const maxLayers = $derived(typeof app.caps.maxLayers === 'number' ? app.caps.maxLayers : undefined);
  const atLimit = $derived(layerCount >= Math.min(64, maxLayers ?? 64));
  async function removeLast() {
    const n = layerCount;
    if ((await cmd('layers.setCount', { count: n - 1 })) !== undefined) toastUndo(`Layer ${n} removed.`);
  }

  // Outputs
  function addOutput() {
    void cmd('output.add', {}).then((id) => {
      if (typeof id === 'number') void toggle(`${first.name} ${id}`);
    });
  }

  /** A chip's address line: the address, or "A 0.0.1 · 1" off the group's universe, so Layer 1 and Layer 9 never both read "1". */
  function at(r: FixtureRow): string {
    if (!r.patched || !r.universe) return '—';
    return r.universe === home ? String(r.address) : `${universeName(r.universe)} · ${r.address}`;
  }
</script>

<section class="panel group" aria-label={group.title} bind:this={section}>
  <div class="head">
    <h2>{group.title}</h2>
    {#if group.kind === 'layer'}
      <div class="stepper" role="group" aria-label="Layer count">
        <button type="button" aria-label="Remove layer {layerCount}" disabled={locked || layerCount <= 1} title={lock ?? `Remove layer ${layerCount} (undo brings it back)`} onclick={removeLast}>−</button>
        <span class="count mono">{layerCount}</span>
        <button type="button" aria-label="Add layer" disabled={locked || atLimit} title={lock ?? (atLimit ? 'Layer limit of this Mac (performance tier)' : 'Add layer')} onclick={() => void cmd('layers.setCount', { count: layerCount + 1 })}>+</button>
      </div>
      <span class="caption">of {maxLayers ?? '?'} · <span title="The layer limit of this Mac's performance tier; Add layer stops there so the show does not drop frames.">tier limit</span> measured on this machine</span>
    {:else if group.kind === 'output'}
      <span class="spacer"></span>
      <button type="button" class="btn" disabled={locked} title={lock ?? 'A new output without a display; pick its display on Outputs & Mapping'} onclick={addOutput}>Add output</button>
    {/if}
  </div>

  {#if group.rows.length > 0}
    <div class="block" role="group" aria-label="{group.title} block" tabindex="-1" bind:this={blockLine}>
      {#if block.start}
        {@const start = block.start}
        <span>Block ·</span>
        <select class="select" aria-label="{group.title} block universe" value={start.universe} disabled={locked} title={lock}
          onchange={(e) => moveTo(e.currentTarget, start, { universe: e.currentTarget.value, address: start.address })}>
          {#each options as id (id)}
            <option value={id}>{universeName(id)}</option>
          {/each}
        </select>
        <span>from</span>
        <input class="input mono address" type="number" inputmode="numeric" min="1" max={UNIVERSE_SIZE + 1 - first.footprint} aria-label="{group.title} block start address"
          value={start.address} disabled={locked} title={lock} onchange={(e) => moveAddress(e.currentTarget, start)} />
        {#if block.unplaced > 0}<span class="muted">· {block.unplaced} unplaced</span>{/if}
      {:else if block.anchor}
        {@const anchor = block.anchor}
        <span class="warn">Custom · {block.off} of {block.required} off the block</span>
        <button type="button" class="btn" disabled={locked} title={lock ?? `Every ${first.name.toLowerCase()} on its slot from ${universeName(anchor.universe)} ${anchor.address}`}
          onclick={() => layThenFocus(anchor, 're-laid as a block from', block.handPlaced)}>Re-lay as block</button>
      {:else}
        <span class="muted">No address</span>
        <button type="button" class="btn" disabled={locked || !standard} title={lock ?? (standard ? `From ${universeName(standard.universe)} ${standard.address}, as the standard patch` : undefined)}
          onclick={() => layThenFocus(standard, 'patched as a block from', 0)}>Patch as block</button>
      {/if}
      {#each blocked as r (r.name)}
        <p class="full caption warn">{r.name}: {rowStatus(r, policy).text}</p>
      {/each}
      {#if move}
        <button type="button" class="btn" disabled={locked} title={lock ?? 'Moves the Master, Output and Keystone blocks to the universe after the last layer and puts the unplaced layers on their slots; the console patch changes too'}
          onclick={() => moveAfter(move)}>Move Master and outputs after the layers</button>
      {/if}
      {#if notice}
        <p class="full caption alert" role="status">{notice}</p>
      {/if}
    </div>
  {/if}

  {#if lines.length === 0}
    <div class="chips" role="group" aria-label="{group.title} fixtures">
      {#each group.rows as r (r.name)}
        {@const st = rowStatus(r, policy)}
        <button type="button" class="chip tone-{st.tone}" data-fixture={r.name} aria-pressed={r.name === selected} aria-label={rowSummary(r, policy)} title={st.text}
          onclick={() => toggle(r.name)}>
          <span class="sw" style:background={r.colour}></span>
          <span class="n">{group.kind === 'machine' ? r.name : r.number}{#if r.offBlock}<span class="off">OFF</span>{/if}</span>
          <span class="at mono">{at(r)}</span>
        </button>
      {/each}
    </div>
  {:else}
    {#each lines as line (line.n)}
      {@const output = group.kind === 'output' ? app.project.outputs.find((o) => o.id === line.n) : undefined}
      <div class="line">
        <div class="line-head">
          <span class="strong">{output?.name ?? `${first.name} ${line.n}`}</span>
          {#if output}
            <span class="caption">· {output.display ? `on ${output.display.name}` : 'no display yet'} · <a href="#/outputs">Outputs &amp; Mapping</a></span>
          {/if}
        </div>
        <div class="fxs">
          {#each line.rows as r (r.name)}
            {@const st = rowStatus(r, policy)}
            <div class="fx">
              <button type="button" class="chip wide tone-{st.tone}" data-fixture={r.name} aria-pressed={r.name === selected} aria-label={rowSummary(r, policy)}
                onclick={() => toggle(r.name)}>
                <span class="sw" style:background={r.colour}></span>
                <span class="n">{r.typeLabel}{#if r.offBlock}<span class="off">OFF</span>{/if}</span>
                <span class="at mono">{r.patched && r.universe ? slotText({ universe: r.universe, address: r.address }, r.footprint) : `${r.footprint} ch`}</span>
              </button>
              <span class="status tone-{st.tone}">{st.text}</span>
              {#if r.optional && !r.patched}
                <button type="button" class="btn" aria-label="Patch {r.name}" disabled={locked} title={lock ?? 'On its slot after the outputs, or the first free channels after it'} onclick={() => patch(r)}>Patch</button>
              {/if}
            </div>
          {/each}
        </div>
      </div>
    {/each}
  {/if}

  {#if group.kind === 'layer' && layerCount > MAX_LAYERS}
    <p class="caption pad">Layers above {MAX_LAYERS} do not render and have no console channels.</p>
  {:else if group.kind === 'output' && app.project.outputs.length > MAX_OUTPUTS}
    <p class="caption pad">Outputs above {MAX_OUTPUTS} have no console channels.</p>
  {:else if group.rows.length === 0}
    <p class="caption pad">No {group.title.toLowerCase()} yet.</p>
  {/if}

  {#if open}
    {@const slot = block.start ? (groupSlots(group, block.start).get(open.name) ?? null) : null}
    <PatchInspector row={open} status={rowStatus(open, policy)} {options} {slot} defaultUniverse={block.anchor?.universe ?? standard?.universe ?? 'artnet:0.0.0'} {onpatched} />
  {/if}
</section>

<style>
  .group { display: flex; flex-direction: column; gap: 12px; padding: 16px; min-width: 0; }
  .head, .block { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .block:focus { outline: none; }
  .block:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; border-radius: 4px; }
  .head h2 { margin-right: 4px; }
  .count { display: inline-flex; align-items: center; justify-content: center; min-width: 48px; border-left: 1px solid var(--line-strong); border-right: 1px solid var(--line-strong); font-size: 15px; }
  .stepper button:disabled { color: var(--text-3); cursor: default; }
  .block .select { min-width: 110px; }
  .address { width: 84px; }
  .full { flex-basis: 100%; margin: 0; }
  .warn, .tone-warn { color: var(--yellow); }
  .alert { color: var(--red); }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip {
    display: inline-grid; grid-template-columns: 10px auto; grid-template-areas: 'sw n' '. at'; align-items: center; column-gap: 6px;
    min-width: 56px; min-height: var(--touch); padding: 4px 8px; border: 1px solid var(--line-strong); border-radius: var(--radius-control);
    background: var(--surface-2); color: var(--text-1); text-align: left;
  }
  .chip:hover { background: var(--surface-3); }
  .chip[aria-pressed='true'] { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); }
  .chip.tone-faint { border-style: dashed; color: var(--text-2); }
  .chip.tone-warn { border-color: var(--yellow); }
  .chip.tone-bad { border-color: var(--red); background: var(--red-bg); }
  .chip .sw { grid-area: sw; width: 10px; height: 10px; border-radius: 3px; border: 1px solid var(--line-strong); }
  .chip .n { grid-area: n; font-weight: 600; }
  .chip .off { margin-left: 4px; font-size: 11px; font-weight: 700; color: var(--yellow); letter-spacing: 0.04em; }
  .chip .at { grid-area: at; font-size: 11px; color: var(--text-2); }
  .chip.wide { min-width: 0; }
  .line { display: flex; flex-direction: column; gap: 6px; padding-top: 10px; border-top: 1px solid var(--line); }
  .line-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 8px; }
  .strong { font-weight: 600; }
  .fxs { display: flex; flex-wrap: wrap; gap: 8px 28px; }
  .fx { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; }
  .status { font-size: 13px; color: var(--text-2); }
  .status.tone-faint { color: var(--text-3); }
  .status.tone-bad { color: var(--red); }
  .pad { margin: 0; }
</style>
