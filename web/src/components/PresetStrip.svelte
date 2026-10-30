<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onDestroy, tick } from 'svelte';
  import { compareLease, freePresetNumber, recalledText, sharedPresets } from '../lib/outputs';
  import { lockTitle } from '../lib/show';
  import { app, can, client, cmd, toastUndo } from '../lib/state.svelte';

  // Mapping presets (DESIGN §9.10 item 3) of one output, or of a whole wall (`ids` = its outputs, one command each for
  // all of them): store the warp and slices as a number, recall, rename, remove, and hold Compare to see one on the
  // output (a lease the engine lets run out) while the preview keeps showing the mapping being edited.
  let { ids }: { ids: number[] } = $props();

  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const targets = $derived(app.project.outputs.filter((o) => ids.includes(o.id)));
  const presets = $derived(sharedPresets(targets));
  let chosen = $state<number | null>(null);
  const selected = $derived(presets.find((p) => p.number === chosen) ?? presets[0]);
  /** "Store as" typed by the user; null = the lowest free number */
  let typed = $state<number | null>(null);
  const storeAs = $derived(typed ?? freePresetNumber(targets) ?? 1);
  const taken = $derived(targets.some((o) => o.presets?.some((p) => p.number === storeAs)));
  const validNumber = $derived(Number.isInteger(storeAs) && storeAs >= 1 && storeAs <= 255);
  const compareOff = $derived(
    lock ?? (app.live.show.mode ? 'Compare is off in show mode' : ids.some((id) => id > 8) ? 'Compare reaches outputs 1–8' : undefined),
  );

  async function store() {
    const number = storeAs;
    const reply = await cmd('output.preset.store', { ids, number });
    if (reply === undefined) return;
    chosen = number;
    typed = null;
    toastUndo(reply !== null && typeof reply === 'object' && 'replaced' in reply ? `Preset ${number} replaced.` : `Stored as preset ${number}.`);
  }
  async function recall() {
    if (!selected) return;
    const number = selected.number;
    const reply = await cmd('output.preset.recall', { ids, number });
    if (reply !== undefined) toastUndo(recalledText(number, reply, (id) => app.project.outputs.find((o) => o.id === id)?.name ?? `Output ${id}`));
  }
  let storeButton = $state<HTMLButtonElement>();
  async function remove() {
    if (!selected) return;
    const number = selected.number;
    if ((await cmd('output.preset.remove', { ids, number })) === undefined) return;
    toastUndo(`Preset ${number} removed.`);
    // the last one gone takes its line, the focused Remove with it: focus stays in the strip
    await tick();
    if (!document.activeElement || document.activeElement === document.body) storeButton?.focus();
  }
  /** An empty name, or one the engine refused, puts the preset's name back in the field. */
  async function rename(input: HTMLInputElement) {
    const preset = selected, name = input.value.trim();
    if (!preset) return;
    if (name && name !== preset.name && (await cmd('output.preset.rename', { ids, number: preset.number, name })) !== undefined) return;
    input.value = preset.name;
  }

  // hold Compare: pointer down (captured, so the strip moving under it does not end the hold) or Space/Enter starts and
  // renews the lease; pointer up, cancel, lost capture, key up or blur ends it. Under show lock nothing is sent: the
  // engine refuses it and has ended the lease itself. Sent quietly: a renewal every 2 s must not clear another refusal's
  // banner or raise one per renewal in an outage; the next renewal heals a lost one
  let comparing = $state(false);
  const lease = compareLease((preset) => {
    if (!app.project.showLock) client.cmd('output.show', { ids, preset }).catch(() => {});
  });
  function startCompare() {
    if (!selected || compareOff) return;
    comparing = true;
    lease.start(selected.number);
  }
  function stopCompare() {
    comparing = false;
    lease.stop();
  }
  onDestroy(stopCompare);
  // the show locked or show mode began while held
  $effect(() => {
    if (compareOff && comparing) stopCompare();
  });
</script>

<section class="presets" aria-label="Mapping presets">
  <h3>Presets</h3>
  {#if presets.length}
    <div class="line">
      <label class="field"><span>Preset</span>
        <select class="select" value={selected?.number} onchange={(e) => (chosen = Number(e.currentTarget.value))}>
          {#each presets as p (p.number)}<option value={p.number}>{p.number} · {p.name}</option>{/each}
        </select>
      </label>
      <label class="field"><span>Name</span>
        <input class="input" type="text" maxlength="64" value={selected?.name ?? ''} disabled={!!lock} title={lock} onchange={(e) => rename(e.currentTarget)} />
      </label>
      <button type="button" class="btn" disabled={!!lock} title={lock ?? 'Copy this preset into the mapping being edited (Undo takes it back)'} onclick={recall}>Recall</button>
      <button type="button" class="btn hold" aria-pressed={comparing} disabled={!!compareOff} title={compareOff ?? 'Hold to show this preset on the output; let go to go back'}
        onpointerdown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); startCompare(); }}
        onpointerup={stopCompare} onpointercancel={stopCompare} onlostpointercapture={stopCompare} onblur={stopCompare}
        onkeydown={(e) => { if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); startCompare(); } }}
        onkeyup={(e) => { if (e.key === ' ' || e.key === 'Enter') stopCompare(); }}
        oncontextmenu={(e) => e.preventDefault()}>Hold to compare</button>
      <button type="button" class="btn btn-danger" disabled={!!lock} title={lock} onclick={remove}>Remove</button>
    </div>
  {/if}
  <div class="line">
    <label class="field"><span>Store as</span>
      <input class="input mono narrow" type="number" min="1" max="255" step="1" value={storeAs} disabled={!!lock} onchange={(e) => (typed = Number(e.currentTarget.value))} />
    </label>
    <button type="button" class="btn" bind:this={storeButton} disabled={!!lock || !validNumber} title={lock ?? (validNumber ? undefined : 'A preset number is 1–255')} onclick={store}>{taken ? `Replace ${storeAs}` : `Store as ${storeAs}`}</button>
    <p class="caption grow">
      A preset holds the warp and the slices with their masks{ids.length > 1 ? `, of all ${ids.length} outputs` : ''}; blend, colour and black floor stay as they are.
      The console shows one with Output channel 6 = its number{ids.length > 1 ? ' on each output' : ''}; channel 7 sets the glide time.
    </p>
  </div>
</section>

<style>
  .presets { display: flex; flex-direction: column; gap: 8px; }
  h3 { margin: 8px 0 0; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
  .line { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 8px 12px; }
  .line .select { min-width: 180px; }
  .narrow { width: 90px; }
  .grow { flex: 1 1 240px; margin: 0; align-self: center; }
  /* a held press must not select text or open the callout on iOS */
  .hold { touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
</style>
