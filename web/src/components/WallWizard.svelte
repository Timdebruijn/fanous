<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { lockTitle } from '../lib/show';
  import { app, can } from '../lib/state.svelte';
  import { applyWizard, cancelWizard, wallUI, wizardBack } from '../lib/wall-session.svelte';
  import { MAX_CANVAS_PIXELS, fitCanvas, freeOutputs, grids, overlapHint, rc, tap, wallPixels, wallSize, type Grid } from '../lib/walls';

  // New projector wall / Edit layout… (DESIGN §9.9): 1 tap the projectors in order and pick a grid, 2 overlap and
  // canvas, 3 apply, after which the wall panel opens on the seam check. The draft lives in lib/wall-session; Cancel
  // gives every output its own test pattern back and changes nothing else.
  const draft = $derived(wallUI.wizard!);
  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const edited = $derived(draft.edit === null ? undefined : app.project.walls?.find((w) => w.id === draft.edit));
  const free = $derived(freeOutputs(app.project.outputs, app.project.walls, draft.edit ?? undefined));
  const statuses = $derived(new Map(app.live.outputs.map((s) => [s.id, s])));
  const names = $derived(new Map(app.project.outputs.map((o) => [o.id, o.name])));
  const options = $derived(grids(draft.order.length));
  const pixels = $derived(wallPixels(draft.order, app.project.outputs, app.live.displays));
  const size = $derived(typeof pixels === 'string' ? null : pixels);
  const ready = $derived(!!draft.grid && !!size);
  const same = (a: Grid | null, b: Grid) => a?.cols === b.cols && a?.rows === b.rows;

  function tapTile(id: number) {
    draft.order = tap(draft.order, id);
    const choices = grids(draft.order.length);
    if (!choices.some((g) => same(draft.grid, g))) draft.grid = choices[0] ?? null;
  }

  // step 2: an unchanged overlap of an edited wall keeps its own x and y
  const overlap = $derived(edited && draft.overlap === draft.overlapWas ? edited.overlap : { x: draft.overlap / 100, y: draft.overlap / 100 });
  const hint = $derived(overlapHint(draft.overlap));
  const canvas = $derived(app.project.canvases.find((c) => c.id === draft.canvas));
  const others = $derived(app.project.canvases.filter((c) => c.id !== draft.canvas).reduce((sum, c) => sum + c.width * c.height, 0));
  const natural = $derived(draft.grid && size ? wallSize(draft.grid, overlap, size) : null);
  const fit = $derived(draft.grid && size ? fitCanvas(draft.grid, overlap, size, MAX_CANVAS_PIXELS - others) : null);
  const sameShape = $derived(!!natural && !!canvas && Math.abs(natural.width / natural.height / (canvas.width / canvas.height) - 1) < 0.01);
  const showMode = $derived(app.live.show.mode);
  const applyTitle = $derived(lock ?? (draft.fit === 'makeCanvas' && showMode ? 'Leave show mode to resize a canvas, or use the canvas as it is' : undefined));
  function setOverlap(percent: number) {
    draft.overlap = Math.min(50, Math.max(0, Math.round(percent)));
  }
  const ordinal = (n: number) => `${n}${n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th'}`;
</script>

<section class="panel wizard" aria-label="New projector wall">
  <header>
    <h2>{edited ? `Edit layout · ${edited.name}` : 'New projector wall'}</h2>
    <span class="caption">Step {draft.step} of 3 · {draft.step === 1 ? 'Order' : 'Overlap and canvas'}</span>
    <span class="spacer"></span>
    <button type="button" class="btn btn-ghost" onclick={cancelWizard}>Cancel</button>
  </header>

  {#if draft.step === 1}
    <p class="muted">{free.some((o) => statuses.get(o.id)?.state === 'bound') ? 'Each projector on a display now shows its Output ID. ' : ''}Tap the tiles in the order the projectors hang: the top row from left to right, then the next row.</p>
    <div class="tiles">
      {#each free as o (o.id)}
        {@const n = draft.order.indexOf(o.id) + 1}
        {@const st = statuses.get(o.id)}
        <button type="button" class="tile" aria-pressed={n > 0} aria-label="{o.name}{n ? `, ${ordinal(n)}` : ''}" onclick={() => tapTile(o.id)}>
          <span class="id mono">{o.id}</span>
          <span class="nm ellipsis">{o.name}</span>
          <span class="caption ellipsis">{st?.state === 'bound' ? `on ${st.display}` : 'not on a display'}</span>
          {#if n}<span class="order mono" aria-hidden="true">{n}</span>{/if}
        </button>
      {:else}
        <p class="caption">No free outputs: every output is in a wall already.</p>
      {/each}
    </div>

    {#if draft.order.length >= 2}
      {#if options.length}
        <div class="fieldrow">
          <span class="label">Grid (rows × columns)</span>
          <div class="segmented" role="group" aria-label="Grid">
            {#each options as g (`${g.rows}x${g.cols}`)}
              <button type="button" class="btn" aria-pressed={same(draft.grid, g)} title="{g.rows} {g.rows === 1 ? 'row' : 'rows'} of {g.cols}" onclick={() => (draft.grid = g)}>{g.rows} × {g.cols}</button>
            {/each}
          </div>
        </div>
        {#if draft.grid}
          {@const g = draft.grid}
          <div class="layout" style:grid-template-columns="repeat({g.cols}, minmax(0, 1fr))" aria-label="The wall as tapped">
            {#each draft.order as id, i (id)}
              {@const p = rc(i, g.cols)}
              <span class="cell" style:aspect-ratio={size ? `${size.width} / ${size.height}` : '16 / 9'}><strong class="ellipsis">{names.get(id)}</strong><span class="caption mono">r{p.row} c{p.col}</span></span>
            {/each}
          </div>
        {/if}
      {:else}
        <p class="caption yellow">{draft.order.length} projectors make no grid of up to 4 × 4. Tap more, or fewer.</p>
      {/if}
      {#if !size}<p class="caption yellow">{pixels}</p>{/if}
    {:else}
      <p class="caption">Tap at least two tiles.</p>
    {/if}

    <footer>
      <button type="button" class="btn btn-ghost" disabled={draft.order.length === 0} onclick={() => (draft.order = [])}>Clear order</button>
      <span class="spacer"></span>
      <button type="button" class="btn btn-primary" disabled={!ready} title={!draft.grid ? 'Tap the projectors and pick a grid first' : !size ? String(pixels) : undefined} onclick={() => (draft.step = 2)}>Next</button>
    </footer>
  {:else if draft.grid && size}
    <div class="fieldrow">
      <span class="label" id="wall-overlap-label">Overlap</span>
      <div class="slider">
        <button type="button" class="btn btn-icon" aria-label="Less overlap" disabled={draft.overlap <= 0} onclick={() => setOverlap(draft.overlap - 1)}>−</button>
        <input type="range" min="0" max="50" step="1" aria-labelledby="wall-overlap-label" value={draft.overlap} oninput={(e) => setOverlap(Number(e.currentTarget.value))} />
        <button type="button" class="btn btn-icon" aria-label="More overlap" disabled={draft.overlap >= 50} onclick={() => setOverlap(draft.overlap + 1)}>+</button>
        <span class="mono val">{draft.overlap} %</span>
      </div>
    </div>
    <p class="caption">Of one projector: {draft.grid.cols > 1 ? `${Math.round(overlap.x * size.width)} of its ${size.width} px across` : ''}{draft.grid.cols > 1 && draft.grid.rows > 1 ? ', ' : ''}{draft.grid.rows > 1 ? `${Math.round(overlap.y * size.height)} of its ${size.height} px down` : ''} are shared with the neighbour. The wall computes each projector's part of the canvas from this.</p>
    {#if hint}<p class="caption yellow">{hint}</p>{/if}

    {#if app.project.canvases.length > 1}
      <label class="fieldrow"><span class="label">Canvas</span>
        <select class="select" value={draft.canvas} onchange={(e) => (draft.canvas = Number(e.currentTarget.value))}>
          {#each app.project.canvases as c (c.id)}<option value={c.id}>{c.name} · {c.width} × {c.height}</option>{/each}
        </select>
      </label>
    {/if}
    {#if canvas && natural && fit}
      <div class="choices" role="radiogroup" aria-label="Canvas">
        <label class="choice">
          <input type="radio" name="wall-fit" checked={draft.fit === 'canvas'} onchange={() => (draft.fit = 'canvas')} />
          <span><strong>Use {canvas.name}</strong> as it is ({canvas.width} × {canvas.height}).
            <span class="caption">At projector resolution the wall is {Math.round(natural.width)} × {Math.round(natural.height)}; {sameShape ? 'the canvas has the same shape.' : "the canvas is stretched to the wall's shape."}</span></span>
        </label>
        <label class="choice" title={showMode ? 'Leave show mode to resize a canvas' : undefined}>
          <input type="radio" name="wall-fit" checked={draft.fit === 'makeCanvas'} disabled={showMode} onchange={() => (draft.fit = 'makeCanvas')} />
          <span><strong>Make {canvas.name} fit the wall</strong>: it becomes {fit.width} × {fit.height}.
            <span class="caption">{fit.width < Math.round(natural.width) - 1 ? 'Scaled down to stay within the canvas limits. ' : ''}Every output blanks briefly while the canvas changes.</span></span>
        </label>
      </div>
      {#if showMode}<p class="caption yellow">Show mode is on: the canvas cannot change size now. Use the canvas as it is, or leave show mode first.</p>{/if}
    {/if}

    <footer>
      <button type="button" class="btn" onclick={wizardBack}>Back</button>
      <span class="spacer"></span>
      <button type="button" class="btn btn-primary" disabled={!!applyTitle} title={applyTitle} onclick={applyWizard}>{edited ? 'Apply layout' : 'Make wall'}</button>
    </footer>
  {:else}
    <p class="caption yellow">{size ? 'Pick a grid first.' : pixels}</p>
    <footer><button type="button" class="btn" onclick={wizardBack}>Back</button></footer>
  {/if}
</section>

<style>
  .wizard { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  header, footer { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  .muted { margin: 0; }
  .caption { margin: 0; }
  .yellow { color: var(--yellow); }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 12px; }
  .tile {
    position: relative; display: flex; flex-direction: column; align-items: flex-start; gap: 2px; min-height: 96px; padding: 10px 12px;
    border: 1px solid var(--line-strong); border-radius: 8px; background: var(--surface-2); color: var(--text-1); text-align: left; min-width: 0;
  }
  .tile:hover { background: var(--surface-3); }
  .tile[aria-pressed='true'] { border-color: var(--accent); background: var(--accent-dim); }
  .tile .id { font-size: 32px; font-weight: 700; line-height: 1; }
  .tile .nm { font-weight: 600; max-width: 100%; }
  .tile .caption { max-width: 100%; }
  .order {
    position: absolute; top: 8px; right: 8px; width: 32px; height: 32px; border-radius: 50%; background: var(--accent); color: var(--ground);
    display: inline-flex; align-items: center; justify-content: center; font-weight: 700; font-size: 16px;
  }
  .fieldrow { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .layout { display: grid; gap: 4px; max-width: 360px; }
  .cell { display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 2px; padding: 4px; min-width: 0; border: 1px solid var(--line-strong); border-radius: 4px; background: var(--surface-2); font-size: 12px; }
  .cell strong { max-width: 100%; }
  .slider { display: flex; align-items: center; gap: 8px; flex: 1 1 280px; max-width: 520px; }
  .slider input { flex: 1; min-width: 0; min-height: var(--touch); accent-color: var(--accent); }
  .val { min-width: 48px; text-align: right; }
  .choices { display: flex; flex-direction: column; gap: 8px; }
  .choice { display: flex; align-items: flex-start; gap: 12px; min-height: var(--touch); padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; cursor: pointer; }
  .choice:has(input:checked) { border-color: var(--accent); background: var(--surface-2); }
  .choice:has(input:disabled) { cursor: default; color: var(--text-3); }
  .choice input { width: 20px; height: 20px; margin: 2px 0 0; accent-color: var(--accent); flex: none; }
  .choice .caption { display: block; margin-top: 2px; }
</style>
