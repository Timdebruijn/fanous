<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import NudgePad from './NudgePad.svelte';
  import { SIDES, trackpad, type Group } from '../lib/remote';

  // iPad remote mode (DESIGN §9.9): the selection in large type, stepping and group selection, the nudge pad and a
  // trackpad, so the finger never covers the picture. The logic lives in lib/remote.ts; this only lays it out.
  let { label, detail, group, groups, disabled = false, onstep, ongroup, onnudge }: {
    label: string;
    detail: string;
    group: Group;
    /** the groups this mapper mode offers */
    groups: Group[];
    /** moving needs the programmer role; selecting does not */
    disabled?: boolean;
    onstep: (dir: 1 | -1) => void;
    ongroup: (group: Group) => void;
    onnudge: (dx: number, dy: number) => void;
  } = $props();

  const names: Record<Group, string> = { point: 'One point', row: 'Row', column: 'Column', all: 'All', top: 'Top', right: 'Right', bottom: 'Bottom', left: 'Left' };
  const unit = $derived(group === 'row' || group === 'column' ? group : group === 'point' || group === 'all' ? 'point' : 'edge');

  /** the finger on the trackpad: only the first one counts */
  let finger: { id: number; x: number; y: number; t: number } | null = null;
  function down(event: PointerEvent) {
    if (finger || disabled) return;
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
    finger = { id: event.pointerId, x: event.clientX, y: event.clientY, t: event.timeStamp };
  }
  function move(event: PointerEvent) {
    if (finger?.id !== event.pointerId) return;
    const [dx, dy] = trackpad(event.clientX - finger.x, event.clientY - finger.y, event.timeStamp - finger.t);
    finger = { id: event.pointerId, x: event.clientX, y: event.clientY, t: event.timeStamp };
    if (dx || dy) onnudge(dx, dy);
  }
  function up(event: PointerEvent) {
    if (finger?.id === event.pointerId) finger = null;
  }
</script>

<section class="remote" aria-label="Remote">
  <p class="now" aria-live="polite"><span class="big">{label}</span><span class="caption">{detail}</span></p>
  <div class="steps">
    <button type="button" class="btn" disabled={group === 'all'} onclick={() => onstep(-1)}>← Previous {unit}</button>
    <button type="button" class="btn" disabled={group === 'all'} onclick={() => onstep(1)}>Next {unit} →</button>
  </div>
  <div class="choose">
    <div class="segmented" role="group" aria-label="Move">
      {#each groups.filter((g) => !(SIDES as readonly string[]).includes(g)) as g (g)}
        <button type="button" class="btn" aria-pressed={group === g} onclick={() => ongroup(g)}>{names[g]}</button>
      {/each}
    </div>
    {#if groups.includes('top')}
      <div class="segmented" role="group" aria-label="Edge">
        {#each SIDES as side (side)}
          <button type="button" class="btn" aria-label="{side} edge" aria-pressed={group === side} onclick={() => ongroup(side)}>{names[side]}</button>
        {/each}
      </div>
    {/if}
  </div>
  <div class="move">
    <NudgePad --cell="64px" {disabled} {onnudge} />
    <!-- svelte-ignore a11y_no_static_element_interactions: a touch surface; the arrows beside it do the same by keyboard -->
    <div class="trackpad" class:disabled onpointerdown={down} onpointermove={move} onpointerup={up} onpointercancel={up}>
      <span class="caption">Trackpad: drag here to move the selection. A slow drag moves 1 px per 4 px of finger, a fast one four times as far.</span>
    </div>
  </div>
  <p class="caption">Tap an arrow for 1 px (10 px with <strong>10 px</strong> on); hold it for 0.25 px. Nudges less than a second apart undo as one step.</p>
</section>

<style>
  .remote { display: flex; flex-direction: column; gap: 12px; padding: 12px; border: 1px solid var(--line-strong); border-radius: var(--radius-panel); background: var(--surface-1); }
  .now { margin: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 16px; }
  .big { font-size: 32px; font-weight: 600; line-height: 1.15; color: var(--text-1); }
  .now .caption { font-family: var(--font-mono); font-size: 14px; }
  .steps { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .steps .btn { min-height: 56px; font-size: 16px; }
  .choose { display: flex; flex-wrap: wrap; gap: 8px; }
  .choose .segmented { flex: 1 1 280px; display: flex; }
  .choose .btn { flex: 1 1 0; padding: 0 8px; }
  .move { display: flex; flex-wrap: wrap; gap: 12px; align-items: stretch; }
  .trackpad { flex: 1 1 200px; min-height: 200px; display: flex; align-items: flex-end; padding: 12px; border: 1px dashed var(--line-strong); border-radius: var(--radius-control); background: var(--ground); touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; cursor: move; }
  .trackpad.disabled { opacity: 0.5; cursor: default; }
  .remote > .caption { margin: 0; }
</style>
