<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { tick } from 'svelte';
  import { lockTitle } from '../lib/show';
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { endCheck, pick, removeWall, startCheck, startWizard, stepCheck, wallUI } from '../lib/wall-session.svelte';
  import { SEAM_STEPS, overlapHint, rc, seamLines, wallPixels, type Control, type ManualField, type SeamLine, type WallConfig } from '../lib/walls';

  // A projector wall (DESIGN §9.9) around a mini-map: one tile per projector, the seams as lines between them. Tap a
  // seam for its gamma and curve, a projector for its black floor; Geometry for the overlap, Edit layout… and Remove
  // wall. The seam check steps through test patterns on every projector of the wall, with what to look for and which
  // control to turn. The engine keeps a slider drag on one seam as one undo step (wall.seam's coalesce key).
  let { wall, onwarp }: { wall: WallConfig; onwarp: (output: number) => void } = $props();

  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const outputs = $derived(new Map(app.project.outputs.map((o) => [o.id, o])));
  const name = (id: number) => outputs.get(id)?.name ?? `Output ${id}`;
  const lines = $derived(seamLines(wall));
  const sel = $derived(wallUI.pick?.wall === wall.id ? wallUI.pick : null);
  const seam = $derived(sel?.kind === 'seam' ? lines.find((l) => l.a === sel.a && l.b === sel.b) : undefined);
  const projector = $derived(sel?.kind === 'projector' ? outputs.get(sel.output) : undefined);
  const check = $derived(wallUI.check?.wall === wall.id ? wallUI.check : null);
  const step = $derived(check ? SEAM_STEPS[check.step] : undefined);
  const armed = $derived(step && wallUI.hint !== null ? step.hints[wallUI.hint] : undefined);
  const pixels = $derived(wallPixels(wall.outputs, app.project.outputs, app.live.displays));
  const canvas = $derived(app.project.canvases.find((c) => c.id === wall.canvas));
  const aspect = $derived(typeof pixels === 'string' ? '16 / 9' : `${pixels.width} / ${pixels.height}`);
  /** the overlaps that matter: across with more than one column, down with more than one row */
  const overlaps = $derived([...(wall.cols > 1 ? [wall.overlap.x] : []), ...(wall.rows > 1 ? [wall.overlap.y] : [])].map((v) => Math.round(v * 100)));
  const tracks = (n: number, size: string) => Array.from({ length: n }, () => size).join(' 44px ');
  const FIELDS: Record<ManualField, string> = {
    source: "Slice 1's part of the canvas", 'overlap.left': 'Left overlap', 'overlap.right': 'Right overlap', 'overlap.top': 'Top overlap', 'overlap.bottom': 'Bottom overlap',
  };

  function tapSeam(l: SeamLine) {
    if (sel?.kind === 'seam' && sel.a === l.a && sel.b === l.b && !armed) return pick(null);
    pick({ wall: wall.id, kind: 'seam', a: l.a, b: l.b }, armed?.target === 'seam' ? armed.control : null);
  }
  function tapProjector(id: number) {
    if (armed?.target === 'projector' && armed.control === 'warp') {
      wallUI.hint = null;
      return onwarp(id);
    }
    if (sel?.kind === 'projector' && sel.output === id && !armed) return pick(null);
    pick({ wall: wall.id, kind: 'projector', output: id }, armed?.target === 'projector' ? armed.control : null);
  }
  /** A hint of the seam check: opens its control for the seam or projector already selected, else waits for a tap. */
  function useHint(i: number) {
    const h = step?.hints[i];
    if (!h?.target) return;
    if (sel?.kind === h.target) {
      if (h.control === 'warp' && sel.kind === 'projector') return onwarp(sel.output);
      wallUI.focus = h.control;
      return;
    }
    pick(null);
    wallUI.hint = i;
  }

  // the control a hint opened comes into view
  let side = $state<HTMLElement>();
  $effect(() => {
    if (!wallUI.focus || !sel) return;
    void tick().then(() => side?.querySelector('.focus')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }));
  });

  function tune(values: { power?: number; gamma?: number; gammaRGB?: [number, number, number] | null }) {
    if (seam) void cmd('wall.seam', { id: wall.id, a: seam.a, b: seam.b, ...values });
  }
  async function applyToAll() {
    if (!seam) return;
    const values = { power: seam.power, gamma: seam.gamma, gammaRGB: (seam.gammaRGB ?? null) as [number, number, number] | null };
    if ((await cmd('wall.seams', { id: wall.id, ...values })) !== undefined) toastUndo(`Every seam of ${wall.name} now has these values.`);
  }
  const rgb = (values: number[] | null | undefined, i: number, v: number) => (values ?? [0, 0, 0]).map((x, j) => (j === i ? v : x)) as [number, number, number];
  function setOverlap(axis: 'x' | 'y', percent: number) {
    void cmd('wall.set', { id: wall.id, overlap: { ...wall.overlap, [axis]: Math.min(50, Math.max(0, Math.round(percent))) / 100 } });
  }

  /** the value under a finger while a slider moves: patches of the values sent before it do not pull it back */
  let drag = $state<{ key: string; value: number } | null>(null);
  interface Slider {
    label: string;
    key: string;
    value: number;
    min: number;
    max: number;
    step: number;
    digits: number;
    set: (v: number) => void;
    focus?: boolean;
    /** send on release only (a geometry change re-computes the wall; one undo step each) */
    onRelease?: boolean;
    unit?: string;
  }
  const stepped = (s: Slider, v: number) => Math.min(s.max, Math.max(s.min, Number(v.toFixed(s.digits))));
</script>

{#snippet slider(s: Slider)}
  {@const v = drag?.key === s.key ? drag.value : s.value}
  <div class="slider" class:focus={s.focus}>
    <span class="label">{s.label}</span>
    <span class="line">
      <button type="button" class="btn btn-icon" aria-label="{s.label} down" title={lock} disabled={!!lock || v <= s.min} onclick={() => s.set(stepped(s, v - s.step))}>−</button>
      <input type="range" min={s.min} max={s.max} step={s.step} aria-label={s.label} title={lock} disabled={!!lock} value={v}
        oninput={(e) => { const n = Number(e.currentTarget.value); drag = { key: s.key, value: n }; if (!s.onRelease) s.set(n); }}
        onchange={(e) => { if (s.onRelease) s.set(Number(e.currentTarget.value)); drag = null; }} />
      <button type="button" class="btn btn-icon" aria-label="{s.label} up" title={lock} disabled={!!lock || v >= s.max} onclick={() => s.set(stepped(s, v + s.step))}>+</button>
      <span class="mono val" aria-label="{s.label} value">{v.toFixed(s.digits)}{s.unit ?? ''}</span>
    </span>
  </div>
{/snippet}

<section class="panel wall" aria-label={wall.name}>
  <header>
    <h2>{wall.name}</h2>
    <span class="caption">{wall.rows} × {wall.cols} · {canvas?.name ?? `Canvas ${wall.canvas}`} · overlap {[...new Set(overlaps)].join(' / ')} %</span>
    <span class="spacer"></span>
    <button type="button" class="btn" aria-pressed={!!check} disabled={!!lock} title={lock ?? 'Test patterns on every projector of the wall, with what to look for and which control to turn'} onclick={() => (check ? endCheck() : startCheck(wall))}>Seam check</button>
    <button type="button" class="btn" aria-pressed={sel?.kind === 'geometry'} onclick={() => pick(sel?.kind === 'geometry' ? null : { wall: wall.id, kind: 'geometry' })}>Geometry</button>
  </header>
  {#if lock}<p class="caption">{lock}</p>{/if}
  {#if typeof pixels === 'string'}<p class="caption yellow">Geometry changes wait until every output of the wall has one pixel size. {pixels}</p>{/if}

  <div class="body">
    <div class="map" role="group" aria-label="Map of {wall.name}" style:grid-template-columns={tracks(wall.cols, 'minmax(0, 1fr)')} style:grid-template-rows={tracks(wall.rows, 'auto')}>
      {#each wall.outputs as id, i (id)}
        {@const p = rc(i, wall.cols)}
        <button type="button" class="tile" style:grid-column={2 * p.col - 1} style:grid-row={2 * p.row - 1} style:aspect-ratio={aspect}
          aria-pressed={sel?.kind === 'projector' && sel.output === id} aria-label="{name(id)} · r{p.row} c{p.col}" onclick={() => tapProjector(id)}>
          <span class="id mono">{id}</span>
          <span class="nm ellipsis">{name(id)}</span>
          <span class="caption mono">r{p.row} c{p.col}</span>
          {#if wall.manual.some((m) => m.output === id)}<span class="badge badge-warn">manual</span>{/if}
        </button>
      {/each}
      {#each lines as l (`${l.a}-${l.b}`)}
        <button type="button" class="seam {l.side}" style:grid-column={l.side === 'right' ? 2 * l.col + 2 : 2 * l.col + 1} style:grid-row={l.side === 'right' ? 2 * l.row + 1 : 2 * l.row + 2}
          aria-pressed={sel?.kind === 'seam' && sel.a === l.a && sel.b === l.b} aria-label="Seam between {name(l.a)} and {name(l.b)}" title="Gamma {l.gamma.toFixed(2)} · curve {l.power.toFixed(1)}" onclick={() => tapSeam(l)}>
          <span class="mono">{l.gamma.toFixed(1)}</span>
        </button>
      {/each}
    </div>

    <div class="side" bind:this={side}>
      {#if check && step}
        <section class="check" aria-label="Seam check">
          <div class="steps" role="group" aria-label="Seam check pattern">
            {#each SEAM_STEPS as s, i (s.name)}
              <button type="button" class="btn" aria-pressed={check.step === i} disabled={!!lock} title={lock} onclick={() => stepCheck(wall, i)}>{s.name}</button>
            {/each}
          </div>
          <p class="caption">Step {check.step + 1} of {SEAM_STEPS.length}, on every projector of the wall: {step.shows} Look for:</p>
          <div class="hints">
            {#each step.hints as h, i (h.see)}
              {#if h.target}
                <button type="button" class="hint" aria-pressed={wallUI.hint === i} onclick={() => useHint(i)}><span>{h.see}</span><span class="turn">→ {h.turn}</span></button>
              {:else}
                <div class="hint"><span>{h.see}</span><span class="turn">→ {h.turn}</span></div>
              {/if}
            {/each}
          </div>
          {#if armed}<p class="armed" role="status">Now tap {armed.target === 'seam' ? 'that seam' : 'that projector'} on the map.</p>{/if}
          <div class="actions">
            <button type="button" class="btn" disabled={!!lock || check.step === 0} onclick={() => stepCheck(wall, check.step - 1)}>Previous</button>
            <button type="button" class="btn" disabled={!!lock || check.step === SEAM_STEPS.length - 1} onclick={() => stepCheck(wall, check.step + 1)}>Next</button>
            <span class="spacer"></span>
            <button type="button" class="btn btn-ghost" onclick={endCheck}>End seam check</button>
          </div>
        </section>
      {/if}

      {#if seam}
        {@const key = `${seam.a}-${seam.b}`}
        <section class="ctl" aria-label="Seam">
          <h3>Seam · {name(seam.a)} | {name(seam.b)}</h3>
          {#if seam.gammaRGB}
            {#each ['R', 'G', 'B'] as ch, i (ch)}
              {@render slider({ label: `Gamma ${ch}`, key: `${key}-g${i}`, value: seam.gammaRGB[i] ?? seam.gamma, min: 0.5, max: 5, step: 0.05, digits: 2, set: (v) => tune({ gammaRGB: rgb(seam.gammaRGB, i, v) }), focus: wallUI.focus === 'rgb' })}
            {/each}
            <p class="caption yellow">Gamma per colour is stored with the wall, but the picture still uses one gamma ({seam.gamma.toFixed(2)}) for all three until a later update brings it to the output.</p>
          {:else}
            {@render slider({ label: 'Gamma', key: `${key}-g`, value: seam.gamma, min: 0.5, max: 5, step: 0.05, digits: 2, set: (v) => tune({ gamma: v }), focus: wallUI.focus === 'gamma' })}
          {/if}
          <label class="switch" class:focus={wallUI.focus === 'rgb'} title={lock}>
            <input type="checkbox" role="switch" checked={!seam.gammaRGB} disabled={!!lock} onchange={(e) => tune({ gammaRGB: e.currentTarget.checked ? null : [seam.gamma, seam.gamma, seam.gamma] })} />
            <span class="track"></span><span>Link R, G, B</span>
          </label>
          {@render slider({ label: 'Curve', key: `${key}-p`, value: seam.power, min: 0.1, max: 10, step: 0.1, digits: 1, set: (v) => tune({ power: v }), focus: wallUI.focus === 'curve' })}
          <p class="caption">Gamma: down for a bright band in the seam, up for a dark one. Curve: how steep the fade is; change it when you see an edge where the overlap starts. Both sides of the seam follow.</p>
          {#if lines.length > 1}
            <button type="button" class="btn" disabled={!!lock} title={lock ?? 'Give every seam of the wall this gamma and curve'} onclick={applyToAll}>Apply to all seams</button>
          {/if}
        </section>
      {:else if projector}
        {@const at = rc(wall.outputs.indexOf(projector.id), wall.cols)}
        <section class="ctl" aria-label="Projector">
          <h3>{projector.name} · r{at.row} c{at.col}</h3>
          {@render slider({ label: 'Black floor', key: `${projector.id}-lift`, value: projector.blend.lift * 100, min: 0, max: 20, step: 0.1, digits: 1, unit: ' %', set: (v) => void cmd('output.set', { id: projector.id, path: '/blend/lift', value: Number((v / 100).toFixed(4)) }), focus: wallUI.focus === 'floor' })}
          <p class="caption">Lifts this projector's black outside its overlaps, to match the double black inside them. On Grey 0 %, raise it on the projectors next to a lighter seam, one by one, until even.</p>
          {#each wall.manual.filter((m) => m.output === projector.id) as m (m.field)}
            <p class="manual"><span class="badge badge-warn">manual</span><span>{FIELDS[m.field]} was set by hand; the wall leaves it alone.</span>
              <button type="button" class="btn" disabled={!!lock} title={lock} onclick={() => cmd('wall.set', { id: wall.id, resetManual: [m] })}>Back to wall</button></p>
          {/each}
          <button type="button" class="btn" onclick={() => onwarp(projector.id)}>Open in Warp &amp; Slices</button>
        </section>
      {:else if sel?.kind === 'geometry'}
        {@const hint = overlaps.map(overlapHint).find((h) => h)}
        <section class="ctl" aria-label="Geometry">
          {#if wall.cols > 1}
            {@render slider({ label: 'Overlap across', key: 'ox', value: Math.round(wall.overlap.x * 100), min: 0, max: 50, step: 1, digits: 0, unit: ' %', set: (v) => setOverlap('x', v), onRelease: true })}
          {/if}
          {#if wall.rows > 1}
            {@render slider({ label: 'Overlap down', key: 'oy', value: Math.round(wall.overlap.y * 100), min: 0, max: 50, step: 1, digits: 0, unit: ' %', set: (v) => setOverlap('y', v), onRelease: true })}
          {/if}
          {#if typeof pixels !== 'string'}
            <p class="caption">Of one projector's {pixels.width} × {pixels.height} px, {wall.cols > 1 ? `${Math.round(wall.overlap.x * pixels.width)} px across` : ''}{wall.cols > 1 && wall.rows > 1 ? ' and ' : ''}{wall.rows > 1 ? `${Math.round(wall.overlap.y * pixels.height)} px down` : ''} are shared with each neighbour.</p>
          {/if}
          {#if hint}<p class="caption yellow">{hint}</p>{/if}
          <div class="actions">
            <button type="button" class="btn" disabled={!!lock} title={lock ?? 'The order, the grid, the overlap and the canvas, in the wizard'} onclick={() => startWizard(wall)}>Edit layout…</button>
            <span class="spacer"></span>
            <button type="button" class="btn btn-danger" disabled={!!lock} title={lock ?? 'The outputs keep their slices and blend edges as they are now'} onclick={() => removeWall(wall)}>Remove wall</button>
          </div>
        </section>
      {:else if !check}
        <p class="caption">Tap a seam on the map for its gamma and curve, or a projector for its black floor. Seam check guides you through the patterns.</p>
      {:else if !armed}
        <p class="caption">Tap a line above, or a seam or projector on the map.</p>
      {/if}
    </div>
  </div>
</section>

<style>
  .wall { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .caption { margin: 0; }
  .yellow { color: var(--yellow); }
  .body { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
  .map { flex: 1 1 300px; max-width: 520px; display: grid; }
  .side { flex: 999 1 320px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .tile {
    display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; min-width: 0; min-height: var(--touch); padding: 6px;
    border: 1px solid var(--line-strong); border-radius: 6px; background: var(--surface-2); color: var(--text-1); overflow: hidden;
  }
  .tile:hover { background: var(--surface-3); }
  .tile[aria-pressed='true'] { border-color: var(--accent); background: var(--accent-dim); }
  .tile .id { font-size: 24px; font-weight: 700; line-height: 1; }
  .tile .nm { max-width: 100%; font-size: 12px; font-weight: 600; }
  .seam { position: relative; display: flex; align-items: center; justify-content: center; padding: 0; border: 0; border-radius: 4px; background: transparent; color: var(--text-2); }
  .seam::before { content: ''; position: absolute; background: var(--line-strong); border-radius: 2px; }
  .seam.right::before { top: 4px; bottom: 4px; left: calc(50% - 2px); width: 4px; }
  .seam.bottom::before { left: 4px; right: 4px; top: calc(50% - 2px); height: 4px; }
  .seam span { position: relative; padding: 1px 3px; border-radius: 3px; background: var(--surface-1); font-size: 11px; }
  .seam:hover::before { background: var(--text-2); }
  .seam[aria-pressed='true']::before { background: var(--accent); }
  .seam[aria-pressed='true'] span { color: var(--text-1); background: var(--accent-dim); }
  .check { display: flex; flex-direction: column; gap: 10px; padding: 12px; border: 1px solid var(--line-strong); border-radius: 8px; background: var(--surface-2); }
  .steps { display: flex; flex-wrap: wrap; gap: 6px; }
  .hints { display: flex; flex-direction: column; gap: 6px; }
  .hint {
    display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.3fr); gap: 4px 12px; align-items: center; min-height: var(--touch); padding: 8px 12px;
    border: 1px solid var(--line); border-radius: 6px; background: var(--surface-1); color: var(--text-1); text-align: left; font-size: 13px;
  }
  button.hint:hover { background: var(--surface-3); }
  .hint[aria-pressed='true'] { border-color: var(--accent); }
  div.hint { color: var(--text-2); }
  .turn { color: var(--text-2); }
  .armed { margin: 0; padding: 8px 12px; border-radius: 6px; background: var(--accent-dim); font-weight: 600; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
  .ctl { display: flex; flex-direction: column; gap: 10px; }
  h3 { margin: 0; font-size: 15px; font-weight: 600; }
  .slider { display: flex; flex-direction: column; gap: 4px; border-radius: 8px; }
  .slider .line { display: flex; align-items: center; gap: 8px; }
  .slider input { flex: 1; min-width: 0; min-height: var(--touch); accent-color: var(--accent); }
  .val { min-width: 64px; text-align: right; }
  .focus { outline: 2px solid var(--accent); outline-offset: 4px; }
  .manual { margin: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; font-size: 13px; }
  @media (max-width: 600px) {
    .hint { grid-template-columns: 1fr; }
  }
</style>
