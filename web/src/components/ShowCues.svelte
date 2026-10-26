<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { CueDoc } from '../lib/docs';
  import type { JSONValue } from '../lib/protocol';
  import { cueRowLabel, cueRowText, cueStatus, formatNumber, lockTitle, nextCueNumber, numberAfter, sortedCues, swapSteps } from '../lib/show';
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';

  let { selected = $bindable('') }: { selected: string } = $props();

  const cues = $derived(sortedCues(app.project.cues));
  const index = $derived(cues.findIndex((c) => c.id === selected));
  const picked = $derived(cues[index]);
  const status = $derived(app.live.cue);

  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  let busy = $state(false);
  const blocked = $derived(lock !== undefined || busy);

  async function add() {
    const number = nextCueNumber(cues);
    const id = await cmd('cue.add', { number, name: `Cue ${formatNumber(number)}` });
    if (typeof id === 'string') selected = id;
  }

  async function duplicate() {
    if (!picked) return;
    const source = $state.snapshot(picked) as CueDoc;
    // trigger and follow stay behind: a copy that fires at the same moment would double-fire
    const id = await cmd('cue.add', { number: numberAfter(cues, source.number), name: `${source.name} (copy)`, fade: source.fade, values: source.values });
    if (typeof id === 'string') selected = id;
  }

  async function remove() {
    if (!picked) return;
    const label = `Cue ${formatNumber(picked.number)} "${picked.name}" removed.`;
    const neighbour = cues[index + 1] ?? cues[index - 1];
    if ((await cmd('cue.remove', { id: picked.id })) !== undefined) {
      selected = neighbour?.id ?? '';
      toastUndo(label);
    }
  }

  /** Swaps numbers with the neighbour; the engine refuses duplicate numbers, so it takes three cue.set calls (three undo steps). */
  async function move(direction: -1 | 1) {
    if (!picked) return;
    busy = true;
    try {
      for (const step of swapSteps($state.snapshot(app.project.cues) as CueDoc[], picked.id, direction)) {
        if ((await cmd('cue.set', { id: step.id, cue: step as unknown as JSONValue })) === undefined) break;
      }
    } finally {
      busy = false;
    }
  }
</script>

<section class="panel cues" aria-labelledby="cues-title">
  <header>
    <h2 id="cues-title">Cues</h2>
    <p class="caption" aria-live="polite">
      {#if status.current !== null}Now {formatNumber(status.current)} {status.currentName ?? ''}{status.fading ? ' (fading)' : ''}{:else}No cue fired yet{/if}
      {#if status.next !== null} · next {formatNumber(status.next)} {status.nextName ?? ''}{/if}
    </p>
    <span class="spacer"></span>
    <div class="actions">
      <button type="button" class="btn" disabled={blocked} title={lock} onclick={add}>Add cue</button>
      <button type="button" class="btn" disabled={blocked || !picked} title={lock} onclick={duplicate}>Duplicate</button>
      <button type="button" class="btn btn-danger" disabled={blocked || !picked} title={lock} onclick={remove}>Remove</button>
      <div class="segmented" role="group" aria-label="Move the selected cue">
        <button type="button" class="btn" disabled={blocked || index < 1} title={lock} onclick={() => move(-1)}>Move up</button>
        <button type="button" class="btn" disabled={blocked || !picked || index >= cues.length - 1} title={lock} onclick={() => move(1)}>Move down</button>
      </div>
    </div>
  </header>

  {#if cues.length === 0}
    <p class="caption empty">No cues yet. Add one, then give it values and a fade.</p>
  {:else}
    <div class="list" role="group" aria-label="Cue list">
      <div class="list-row cue head" aria-hidden="true">
        <span class="c-num">No.</span><span class="c-name">Name</span><span class="c-fade">Fade</span><span class="c-trig">Trigger</span><span class="c-follow">Follow</span><span class="c-vals">Values</span>
      </div>
      {#each cues as c (c.id)}
        {@const st = cueStatus(c, status)}
        {@const t = cueRowText(c)}
        <button
          type="button"
          class="list-row cue"
          class:current={st === 'current'}
          aria-pressed={c.id === selected}
          aria-current={st === 'current' ? 'true' : undefined}
          aria-label={cueRowLabel(c, st)}
          onclick={() => (selected = c.id)}
        >
          <span class="c-num mono">{t.number}</span>
          <span class="c-name ellipsis">{c.name || 'Unnamed'}</span>
          <span class="c-fade mono">{t.fade}</span>
          <span class="c-trig mono ellipsis">{t.trigger}</span>
          <span class="c-follow mono">{t.follow}</span>
          <span class="c-vals mono">{t.values}</span>
          <span class="c-mark">
            {#if st === 'current'}<span class="badge">{status.fading ? 'fading' : 'current'}</span>{:else if st === 'next'}<span class="badge badge-accent">next</span>{/if}
          </span>
        </button>
      {/each}
    </div>
  {/if}
</section>

<style>
  .cues { display: flex; flex-direction: column; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; padding: 16px; }
  header p { margin: 0; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; }
  .empty { margin: 0; padding: 0 16px 16px; }
  .list { border-top: 1px solid var(--line); max-height: min(50vh, 440px); overflow-y: auto; }
  .list > :last-child { border-bottom: 0; }

  .cue {
    display: grid; align-items: center; column-gap: 12px; padding: 0 16px;
    grid-template-columns: 56px minmax(0, 1fr) 72px 150px 72px 56px 72px;
    grid-template-areas: 'num name fade trig follow vals mark';
  }
  .cue.head { min-height: 32px; font-size: 12px; color: var(--text-3); position: sticky; top: 0; background: var(--surface-1); z-index: 1; }
  .cue.head:hover { background: var(--surface-1); }
  .cue.current { background: var(--accent-dim); }
  .cue.current:hover { background: var(--accent-dim); }
  .cue.current .c-num, .cue.current .c-name { font-weight: 600; }
  .c-num { grid-area: num; text-align: right; }
  .c-name { grid-area: name; }
  .c-fade { grid-area: fade; text-align: right; }
  .c-trig { grid-area: trig; }
  .c-follow { grid-area: follow; text-align: right; }
  .c-vals { grid-area: vals; text-align: right; }
  .c-mark { grid-area: mark; justify-self: end; }
  .cue:not(.head) .c-fade, .cue:not(.head) .c-trig, .cue:not(.head) .c-follow, .cue:not(.head) .c-vals { color: var(--text-2); font-size: 13px; }

  /* Phone and narrow panes: name and marker on top, the details as a caption line below. */
  @media (max-width: 720px) {
    .cue { grid-template-columns: 44px auto minmax(0, 1fr) auto auto; grid-template-areas: 'num name name name mark' 'num fade trig follow vals'; row-gap: 2px; padding: 8px 12px; }
    .cue.head { display: none; }
    .c-fade, .c-trig, .c-follow, .c-vals { font-size: 12px; text-align: left; }
    .cue .c-follow::before { content: 'follow '; }
    .cue .c-vals::after { content: ' values'; }
  }
</style>
