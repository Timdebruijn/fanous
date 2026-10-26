<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script module lang="ts">
  const ui = $state({ selected: 0, tab: 'outputs' as 'canvases' | 'outputs' | 'warp', mapper: 'cornerPin' as MapperMode, slice: 0, handle: null as string | null, maskAdd: false, draft: null as MapPoint[] | null });
</script>

<script lang="ts">
  import NudgePad from '../components/NudgePad.svelte';
  import OutputMapper from '../components/OutputMapper.svelte';
  import Preview from '../components/Preview.svelte';
  import {
    CANVAS_PRESETS, CANVAS_RATES, canvasSizeError, EDGES, insertNearest, clamp01, TEST_PATTERNS, UNIT_QUAD, blendCurvePath, defaultMask, meshIdentity, modeText, nextSliceId, outputSize, statusText,
    type MapPoint, type MapperMode, type OutputConfig,
  } from '../lib/outputs';
  import { app, can, cmd, toastUndo } from '../lib/state.svelte';
  import { go } from '../lib/router.svelte';
  import { sourcePixels, sourceFromPixels } from '../lib/outputs';
  import { downloadTemplatePNG, templateSVG } from '../lib/template';
  import { fromScreen, nudgeStored, toScreen } from '../lib/warp';
  import type { JSONValue } from '../lib/protocol';

  const LOCKED = 'Locked: programmer only';
  const locked = $derived(!can('programmer'));
  const outputs = $derived(app.project.outputs);
  const displays = $derived(app.live.displays);
  const statuses = $derived(new Map(app.live.outputs.map((s) => [s.id, s])));
  const canvas = $derived(app.project.canvases[0]);
  const output = $derived(outputs.find((o) => o.id === ui.selected) ?? outputs[0]);
  const status = $derived(output ? statuses.get(output.id) : undefined);
  const size = $derived(output ? outputSize(output, displays) : { w: 1920, h: 1080 });
  const lost = $derived(app.live.outputs.filter((s) => s.state === 'lost'));
  const display = $derived(displays.find((d) => d.uuid === output?.display?.uuid));
  const previewTarget = $derived(output && ui.tab !== 'canvases' ? `output:${output.id}` : 'canvas');
  const previewAspect = $derived(output && ui.tab !== 'canvases' ? `${size.w} / ${size.h}` : canvas ? `${canvas.width} / ${canvas.height}` : '16 / 9');
  /** canvas size and rate being edited; null = what the project has */
  let formatDraft = $state<{ width: number; height: number; fps: number } | null>(null);
  const format = $derived(formatDraft ?? { width: canvas?.width ?? 1920, height: canvas?.height ?? 1080, fps: canvas?.fps ?? 60 });
  const formatChanged = $derived(!!canvas && (format.width !== canvas.width || format.height !== canvas.height || format.fps !== (canvas.fps ?? 60)));
  const formatError = $derived(formatChanged ? canvasSizeError(format.width, format.height) : null);
  function editFormat(change: Partial<{ width: number; height: number; fps: number }>) {
    formatDraft = { ...format, ...change };
  }
  async function applyFormat() {
    if (!canvas || formatError) return;
    const { width, height, fps } = format;
    if (!confirm(`Change the canvas to ${width} × ${height} at ${fps} fps? The canvas is re-created: every output blanks briefly. Slices and outputs keep their settings.`)) return;
    if ((await cmd('canvas.set', { id: canvas.id, width, height, fps })) !== undefined) formatDraft = null;
  }
  const sliceIndex = $derived(Math.min(ui.slice, Math.max(0, (output?.slices.length ?? 1) - 1)));

  function set(path: string, value: JSONValue) {
    if (!output) return;
    void cmd('output.set', { id: output.id, path, value });
  }
  function number(event: Event, path: string, scale = 1) {
    const v = Number((event.currentTarget as HTMLInputElement).value);
    if (Number.isFinite(v)) set(path, v * scale);
  }
  function addOutput(uuid: string | null) {
    const d = displays.find((x) => x.uuid === uuid);
    void cmd('output.add', d ? { display: { uuid: d.uuid, name: d.name } } : {}).then((id) => {
      if (typeof id === 'number') {
        ui.selected = id;
        justAdded = id;
      }
    });
  }
  /** the output that was just added: the screen offers the next step for it */
  let justAdded = $state<number | null>(null);
  async function removeOutput() {
    if (!output) return;
    const name = output.name;
    if ((await cmd('output.remove', { id: output.id })) !== undefined) toastUndo(`${name} removed.`);
  }
  function point(path: string, p: MapPoint) {
    set(path, { x: p.x, y: p.y });
  }
  function setMesh(n: number) {
    set('/warp/mesh', n <= 1 ? null : (meshIdentity(n, n) as unknown as JSONValue));
  }
  function addSlice() {
    if (!output) return;
    set(`/slices/${output.slices.length}`, { id: nextSliceId(output), canvas: 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: UNIT_QUAD as unknown as JSONValue, mask: null, opacity: 1 });
    ui.slice = output.slices.length;
  }
  function removeSlice() {
    if (!output || output.slices.length <= 1) return;
    const id = output.slices[sliceIndex]?.id;
    const next = output.slices.filter((_, i) => i !== sliceIndex);
    set('/slices', next as unknown as JSONValue);
    ui.slice = 0;
    toastUndo(`Slice ${id} removed.`);
  }
  function removeMask() {
    set(`/slices/${sliceIndex}/mask`, null);
    toastUndo(`Mask of slice ${output?.slices[sliceIndex]?.id} removed.`);
  }
  const selectedHandle = $derived.by(() => {
    if (!ui.handle || !output) return null;
    const parts = ui.handle.split('/').filter(Boolean);
    let node: unknown = output;
    for (const part of parts) node = (node as Record<string, unknown> | undefined)?.[part];
    return node && typeof node === 'object' ? (node as MapPoint) : null;
  });
  /** the selected point as it appears on screen (through the warp), in output pixels */
  const selectedScreen = $derived(selectedHandle && output ? toScreen(output, ui.mapper, selectedHandle) : null);
  function moveSelected(on: { x?: number; y?: number }) {
    if (!output || !ui.handle || !selectedScreen) return;
    const p = fromScreen(output, ui.mapper, { x: on.x ?? selectedScreen.x, y: on.y ?? selectedScreen.y });
    point(ui.handle, { x: Math.min(1, Math.max(0, p.x)), y: Math.min(1, Math.max(0, p.y)) });
  }
  function nudgeSelected(dx: number, dy: number) {
    if (!output || !ui.handle || !selectedHandle) return;
    point(ui.handle, nudgeStored(output, ui.mapper, selectedHandle, dx, dy, size));
  }
  async function exportTemplate() {
    if (!output || !canvas) return;
    const size = { width: canvas.width, height: canvas.height };
    const name = output.name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    await downloadTemplatePNG(templateSVG(output, size), size.width, size.height, `fanous-template-${name}-${size.width}x${size.height}.png`);
  }
  /** a tap or double-click on the picture in Mask mode: a corner of a mask being drawn, or a new point on the nearest edge */
  function addMaskAt(p: MapPoint) {
    const slice = output?.slices[sliceIndex];
    if (!output || !slice || locked) return;
    const q = { x: clamp01(p.x), y: clamp01(p.y) };
    if (ui.draft) {
      ui.draft = [...ui.draft, q];
      return;
    }
    if (!slice.mask) return;
    const { path, index } = insertNearest(slice.mask.path, q);
    set(`/slices/${sliceIndex}/mask/path`, path as unknown as JSONValue);
    ui.handle = `/slices/${sliceIndex}/mask/path/${index}`;
  }
  function startDrawing() {
    ui.draft = [];
    ui.handle = null;
  }
  function finishDrawing() {
    if (!ui.draft || ui.draft.length < 3) return;
    set(`/slices/${sliceIndex}/mask`, { path: ui.draft, feather: 0 } as unknown as JSONValue);
    ui.draft = null;
    ui.maskAdd = false;
  }
  function removeMaskPointAt(path: string) {
    if (!path.startsWith(`/slices/${sliceIndex}/mask/path/`)) return;
    ui.handle = path;
    removeMaskPoint();
  }
  function removeMaskPoint() {
    const slice = output?.slices[sliceIndex];
    if (!slice?.mask || slice.mask.path.length <= 3 || !ui.handle?.startsWith(`/slices/${sliceIndex}/mask/path/`)) return;
    const index = Number(ui.handle.split('/').pop());
    set(`/slices/${sliceIndex}/mask/path`, slice.mask.path.filter((_, i) => i !== index) as unknown as JSONValue);
    ui.handle = null;
  }
</script>

<div class="toolbar">
  <h1>Outputs &amp; Mapping</h1>
  <div class="segmented" role="group" aria-label="Section">
    <button type="button" class="btn" aria-pressed={ui.tab === 'canvases'} onclick={() => (ui.tab = 'canvases')}>Canvases</button>
    <button type="button" class="btn" aria-pressed={ui.tab === 'outputs'} onclick={() => (ui.tab = 'outputs')}>Outputs</button>
    <button type="button" class="btn" aria-pressed={ui.tab === 'warp'} onclick={() => (ui.tab = 'warp')}>Warp &amp; Slices</button>
  </div>
  <span class="spacer"></span>
  <span class="caption">{outputs.length} outputs · {displays.length} displays connected</span>
</div>

{#each lost as s (s.id)}
  <div class="banner banner-red" role="alert">
    <span class="dot dot-red"></span>
    <span><strong>Output {s.id} lost</strong> · {s.display ?? 'its display'} is not connected; the other outputs keep running</span>
  </div>
{/each}

{#if justAdded !== null && outputs.some((o) => o.id === justAdded)}
  <div class="banner banner-yellow" role="status">
    <span class="dot dot-green"></span>
    <span><strong>Next: align this output.</strong> Open Warp &amp; Slices to place the picture on the projector.</span>
    <span class="spacer"></span>
    <button type="button" class="btn btn-primary" onclick={() => { ui.selected = justAdded!; ui.tab = 'warp'; justAdded = null; }}>Align this output</button>
    <button type="button" class="btn btn-ghost" onclick={() => (justAdded = null)}>Later</button>
  </div>
{/if}

<div class="screen">
  <aside class="list">
    {#each outputs as o (o.id)}
      {@const st = statusText(statuses.get(o.id), o)}
      <button type="button" class="row out" aria-pressed={output?.id === o.id} onclick={() => (ui.selected = o.id)}>
        <span class="head"><span class="dot dot-{st.tone === 'green' ? 'green' : st.tone === 'red' ? 'red' : 'off'}"></span><span class="nm">{o.name}</span><span class="spacer"></span><span class="caption mono">{Math.round(o.intensity * 100)} %</span></span>
        <span class="caption ellipsis tone-{st.tone}">{st.text}</span>
      </button>
    {:else}
      <p class="caption pad">No outputs yet. Add one for each projector or display with "Add output on" below; a new output shows the whole canvas.</p>
    {/each}
    <div class="add">
      <label class="field"><span>Add output on</span>
        <select class="select" disabled={locked} title={locked ? LOCKED : undefined} onchange={(e) => { addOutput(e.currentTarget.value || null); e.currentTarget.value = ''; }}>
          <option value="">Choose a display…</option>
          {#each displays as d (d.uuid)}<option value={d.uuid}>{d.name} · {d.width} × {d.height}{d.builtin ? ' (this Mac)' : ''}</option>{/each}
          <option value="none">Unassigned (assign later)</option>
        </select>
      </label>
    </div>
    <p class="caption pad">Displays are matched by identity, so a replugged projector lands on the same output.</p>
  </aside>

  <section class="main">
    <div class="preview">
      {#if app.live.engine.rendering}
        <!-- an output preview takes the output's shape (the 16:9 stream is stretched back into it), and the overlay
             uses exactly the same box, so handles sit on the picture whatever the display's aspect ratio -->
        <Preview target={previewTarget} aspect={previewAspect} />
        {#if output && ui.tab === 'warp'}
          <div class="overlay" style:aspect-ratio={previewAspect}>
            <OutputMapper {output} mode={ui.mapper} {sliceIndex} {size} bind:selected={ui.handle} onchange={point} addMode={ui.maskAdd} draft={ui.mapper === 'mask' ? ui.draft : null} onadd={addMaskAt} onremove={removeMaskPointAt} />
          </div>
        {/if}
      {:else}
        <div class="panel nopreview">
          <p class="muted">No preview: the engine is not rendering outputs. Assign this output to a connected display (Outputs tab), or check System › Readiness. Settings can still be edited; the preview appears when an output renders.</p>
          <button type="button" class="btn" onclick={() => go('system')}>Open System</button>
        </div>
      {/if}
    </div>

    {#if ui.tab === 'canvases'}
      <section class="panel form" aria-label="Canvas">
        {#if canvas}
          <h2>{canvas.name}</h2>
          <div class="fields">
            <label class="field"><span>Name</span><input class="input" type="text" value={canvas.name} disabled={locked} onchange={(e) => void cmd('canvas.set', { id: canvas.id, path: '/name', value: e.currentTarget.value })} /></label>
            <div class="field" role="group" aria-label="Canvas size"><span>Size w × h (px)</span>
              <span class="row4">
                <input class="input mono" type="number" min="320" max="8192" step="2" aria-label="Canvas width" value={format.width} disabled={locked} onchange={(e) => editFormat({ width: Number(e.currentTarget.value) })} />
                <input class="input mono" type="number" min="320" max="8192" step="2" aria-label="Canvas height" value={format.height} disabled={locked} onchange={(e) => editFormat({ height: Number(e.currentTarget.value) })} />
                <select class="select" aria-label="Canvas size preset" disabled={locked} value={`${format.width}x${format.height}`} onchange={(e) => { const [w, h] = e.currentTarget.value.split('x').map(Number); if (w && h) editFormat({ width: w, height: h }); }}>
                  {#if !CANVAS_PRESETS.some((p) => p.width === format.width && p.height === format.height)}<option value={`${format.width}x${format.height}`}>Custom</option>{/if}
                  {#each CANVAS_PRESETS as p (`${p.width}x${p.height}`)}<option value={`${p.width}x${p.height}`}>{p.width} × {p.height}</option>{/each}
                </select>
              </span>
            </div>
            <label class="field"><span>Frame rate</span>
              <select class="select" disabled={locked} value={String(format.fps)} onchange={(e) => editFormat({ fps: Number(e.currentTarget.value) })}>
                {#each CANVAS_RATES as r (r)}<option value={String(r)}>{r} fps</option>{/each}
              </select>
            </label>
            <div class="field"><span>&nbsp;</span>
              <span class="row4">
                <button type="button" class="btn" disabled={locked || !formatChanged || !!formatError || app.live.show.mode} title={locked ? LOCKED : app.live.show.mode ? 'Leave show mode to change the canvas' : undefined} onclick={applyFormat}>Apply</button>
                {#if formatChanged}<button type="button" class="btn btn-ghost" onclick={() => (formatDraft = null)}>Revert</button>{/if}
              </span>
            </div>
            <label class="field"><span>Clock master</span>
              <select class="select" disabled={locked} value={canvas.clockMaster ?? ''} onchange={(e) => void cmd('canvas.set', { id: canvas.id, path: '/clockMaster', value: e.currentTarget.value ? Number(e.currentTarget.value) : null })}>
                <option value="">First bound output</option>
                {#each outputs as o (o.id)}<option value={o.id}>{o.name}</option>{/each}
              </select>
            </label>
          </div>
          {#if formatError}<p class="caption tone-red">{formatError}</p>{/if}
          <p class="caption">Layers are assigned to this canvas by the patch. Applying a new size or frame rate re-creates the canvas: outputs blank briefly. Slices keep their place (they are stored as fractions of the canvas).</p>
        {/if}
      </section>
    {:else if !output}
      <section class="panel form"><p class="muted">Select or add an output.</p></section>
    {:else if ui.tab === 'outputs'}
      <section class="panel form" aria-label="Output settings">
        <div class="head2"><h2>{output.name}</h2><span class="caption tone-{statusText(status, output).tone}">{statusText(status, output).text}</span><span class="spacer"></span>
          <button type="button" class="btn btn-danger" disabled={locked} title={locked ? LOCKED : undefined} onclick={removeOutput}>Remove output</button></div>
        <div class="fields">
          <label class="field"><span>Name</span><input class="input" type="text" value={output.name} disabled={locked} onchange={(e) => set('/name', e.currentTarget.value)} /></label>
          <label class="field"><span>Display</span>
            <select class="select" disabled={locked} value={output.display?.uuid ?? ''} onchange={(e) => { const d = displays.find((x) => x.uuid === e.currentTarget.value); set('/display', d ? { uuid: d.uuid, name: d.name } : null); }}>
              <option value="">Unassigned</option>
              {#if output.display && !display}<option value={output.display.uuid}>{output.display.name} · missing</option>{/if}
              {#each displays as d (d.uuid)}<option value={d.uuid}>{d.name} · {d.width} × {d.height}{d.builtin ? ' (this Mac)' : ''}</option>{/each}
            </select>
          </label>
          <label class="field"><span>Mode</span>
            <select class="select" disabled={locked || !display} value={output.mode ? `${output.mode.width}x${output.mode.height}@${output.mode.hz}` : ''} onchange={(e) => { const m = display?.modes.find((x) => `${x.width}x${x.height}@${x.hz}` === e.currentTarget.value); set('/mode', m ? { width: m.width, height: m.height, hz: m.hz } : null); }}>
              <option value="">Current · {display ? modeText(display) : '—'}</option>
              {#each display?.modes ?? [] as m (`${m.width}x${m.height}@${m.hz}`)}<option value={`${m.width}x${m.height}@${m.hz}`}>{modeText(m)}</option>{/each}
            </select>
          </label>
          <div class="field" role="group" aria-label="Region"><span>Region x · y · w · h (px)</span>
            <span class="row4">
              {#each ['x', 'y', 'w', 'h'] as k (k)}
                <input class="input mono" type="number" aria-label="Region {k}" value={output.region ? output.region[k as 'x'] : (k === 'w' ? size.w : k === 'h' ? size.h : 0)} disabled={locked} onchange={(e) => { const r = output.region ?? { x: 0, y: 0, w: size.w, h: size.h }; set('/region', { ...r, [k]: Number(e.currentTarget.value) }); }} />
              {/each}
              <button type="button" class="btn btn-ghost" disabled={locked || !output.region} onclick={() => set('/region', null)}>Full display</button>
            </span>
          </div>
          <label class="field"><span>Intensity %</span><input class="input mono" type="number" min="0" max="100" value={Math.round(output.intensity * 100)} disabled={locked} onchange={(e) => number(e, '/intensity', 0.01)} /></label>
        </div>
        {#if display?.builtin}<p class="caption yellow">This output uses the Mac's own display: the local UI shell will be hidden behind it.</p>{/if}

        <h3>Blend edges</h3>
        <div class="edges">
          {#each EDGES as edge (edge)}
            {@const e = output.blend[edge]}
            <div class="edge panel">
              <div class="ehead"><span class="label">{edge}</span><svg class="curve" viewBox="0 0 100 40" aria-hidden="true"><path d={blendCurvePath(e, 100, 40)} fill="none" stroke="#4C9EFF" stroke-width="2" /></svg></div>
              <label class="field"><span>Overlap (px)</span><input class="input mono" type="number" min="0" value={e.overlap} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/overlap`)} /></label>
              <p class="caption">Overlap: width of the strip shared with the neighbouring projector, in pixels of this output.</p>
              <label class="field"><span>Power</span><input class="input mono" type="number" min="0.1" max="10" step="0.1" value={e.power} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/power`)} /></label>
              <p class="caption">Power: steepness of the fade. 2 is a smooth S-curve; higher is sharper in the middle.</p>
              <label class="field"><span>Gamma</span><input class="input mono" type="number" min="0.5" max="5" step="0.1" value={e.gamma} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/gamma`)} /></label>
              <p class="caption">Gamma: set it to the projector's gamma (usually 2.2) so the two lights add up evenly.</p>
            </div>
          {/each}
        </div>
        <div class="fields">
          <label class="field"><span>Black lift (%)</span><input class="input mono" type="number" min="0" max="50" step="0.5" value={Math.round(output.blend.lift * 1000) / 10} disabled={locked} onchange={(e) => number(e, '/blend/lift', 0.01)} /></label>
          <label class="field"><span>Lift feather px</span><input class="input mono" type="number" min="0" value={output.blend.liftFeather} disabled={locked} onchange={(e) => number(e, '/blend/liftFeather')} /></label>
        </div>

        <h3>Test pattern</h3>
        <div class="patterns">
          {#each TEST_PATTERNS as name, i (name)}
            <button type="button" class="btn" aria-pressed={output.testPattern === i} disabled={locked} title={locked ? LOCKED : undefined} onclick={() => set('/testPattern', i)}>{name}</button>
          {/each}
        </div>
        <p class="caption">The Output fixture's Test pattern and Master channels override this; its Blend channel at 128+ shows the raw canvas (no blend, warp or mask) for alignment.</p>
      </section>
    {:else}
      <section class="panel form" aria-label="Warp and slices">
        <div class="head2">
          <h2>{output.name}</h2>
          <div class="segmented" role="group" aria-label="Edit">
            <button type="button" class="btn" aria-pressed={ui.mapper === 'cornerPin'} onclick={() => (ui.mapper = 'cornerPin')}>Corner pin · 4 points</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'mesh'} onclick={() => (ui.mapper = 'mesh')}>Mesh · up to 33 × 33</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'slices'} onclick={() => (ui.mapper = 'slices')}>Slices</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'mask'} onclick={() => (ui.mapper = 'mask')}>Mask</button>
          </div>
          <button type="button" class="btn" disabled={!canvas} title="A PNG at canvas size showing which part of the canvas each slice uses and what its mask leaves visible: a guide for making content" onclick={exportTemplate}>Content template (PNG)</button>
          <span class="spacer"></span>
          {#if selectedHandle && selectedScreen}
            <span class="caption">Selected point (px)</span>
            <input class="input mono narrow" type="number" aria-label="Point x in pixels" value={Math.round(selectedScreen.x * size.w)} disabled={locked} onchange={(e) => moveSelected({ x: Number(e.currentTarget.value) / size.w })} />
            <input class="input mono narrow" type="number" aria-label="Point y in pixels" value={Math.round(selectedScreen.y * size.h)} disabled={locked} onchange={(e) => moveSelected({ y: Number(e.currentTarget.value) / size.h })} />
          {/if}
        </div>
        {#if selectedHandle}
          <div class="nudge">
            <NudgePad disabled={locked} onnudge={nudgeSelected} />
            <p class="caption">Tap a handle on the picture, then nudge it here. 10 px moves ten pixels per press. Keyboard: arrow keys, Shift for ten.</p>
          </div>
        {/if}
        {#if ui.mapper === 'cornerPin'}
          <div class="fields">
            <p class="caption grow">Drag the four corners on the preview; arrow keys nudge the selected corner by one pixel (Shift: ten). For a curved or uneven surface, switch to Mesh and pick a density; the mesh works on top of the corner pin.</p>
            <button type="button" class="btn" disabled={locked} onclick={() => set('/warp/cornerPin', UNIT_QUAD as unknown as JSONValue)}>Reset corners</button>
          </div>
        {:else if ui.mapper === 'mesh'}
          <div class="fields">
            <label class="field"><span>Density</span>
              <select class="select" disabled={locked} value={output.warp.mesh?.cols ?? 1} onchange={(e) => setMesh(Number(e.currentTarget.value))}>
                <option value={1}>Off (corner pin only)</option>
                {#each [2, 3, 5, 9, 17, 33] as n (n)}<option value={n}>{n} × {n}</option>{/each}
              </select>
            </label>
            <button type="button" class="btn" disabled={locked || !output.warp.mesh} onclick={() => output.warp.mesh && setMesh(output.warp.mesh.cols)}>Reset mesh</button>
            <p class="caption grow">A change of density starts from a flat grid. The mesh is a smooth surface through its points.</p>
          </div>
        {:else if ui.mapper === 'slices'}
          <div class="fields">
            <label class="field"><span>Slice</span>
              <select class="select" value={sliceIndex} onchange={(e) => (ui.slice = Number(e.currentTarget.value))}>
                {#each output.slices as s, i (s.id)}<option value={i}>Slice {s.id}</option>{/each}
              </select>
            </label>
            {#if output.slices[sliceIndex]}
              {@const s = output.slices[sliceIndex]!}
              <div class="field" role="group" aria-label="Source rectangle on the canvas, in pixels"><span>Source x · y · w · h (canvas px)</span>
                <span class="row4">
                  {#each ['x', 'y', 'w', 'h'] as k (k)}
                    <input class="input mono" type="number" step="1" min="0" aria-label="Source {k} in pixels" title="Stored as {Math.round(s.source[k as 'x'] * 10000) / 10000} (0–1 of the canvas)" value={sourcePixels(s.source, canvas)[k as 'x']} disabled={locked} onchange={(e) => { const v = sourceFromPixels(k as 'x', Number(e.currentTarget.value), canvas); if (v !== null) set(`/slices/${sliceIndex}/source/${k}`, v); }} />
                  {/each}
                </span>
              </div>
              <label class="field"><span>Opacity %</span><input class="input mono" type="number" min="0" max="100" value={Math.round(s.opacity * 100)} disabled={locked} onchange={(e) => set(`/slices/${sliceIndex}/opacity`, Number(e.currentTarget.value) / 100)} /></label>
            {/if}
            <button type="button" class="btn" disabled={locked} onclick={addSlice}>Add slice</button>
            <button type="button" class="btn btn-danger" disabled={locked || output.slices.length <= 1} onclick={removeSlice}>Remove slice</button>
          </div>
        {:else}
          {@const s = output.slices[sliceIndex]}
          <div class="fields">
            <label class="field"><span>Slice</span>
              <select class="select" value={sliceIndex} onchange={(e) => (ui.slice = Number(e.currentTarget.value))}>
                {#each output.slices as sl, i (sl.id)}<option value={i}>Slice {sl.id}</option>{/each}
              </select>
            </label>
            {#if ui.draft}
              <p class="caption grow"><strong>Drawing a mask:</strong> tap the corners of the area that stays visible, in order around it ({ui.draft.length} so far, at least 3).</p>
              <button type="button" class="btn btn-primary" disabled={ui.draft.length < 3} onclick={finishDrawing}>Done</button>
              <button type="button" class="btn" disabled={ui.draft.length === 0} onclick={() => (ui.draft = ui.draft!.slice(0, -1))}>Undo last corner</button>
              <button type="button" class="btn" onclick={() => (ui.draft = null)}>Cancel</button>
            {:else if s?.mask}
              <label class="field"><span>Feather px</span><input class="input mono" type="number" min="0" value={s.mask.feather} disabled={locked} onchange={(e) => set(`/slices/${sliceIndex}/mask/feather`, Number(e.currentTarget.value))} /></label>
              <button type="button" class="btn" aria-pressed={ui.maskAdd} disabled={locked} onclick={() => (ui.maskAdd = !ui.maskAdd)}>{ui.maskAdd ? 'Adding points: tap the picture' : 'Add points'}</button>
              <button type="button" class="btn" disabled={locked || s.mask.path.length <= 3 || !ui.handle?.includes('/mask/')} onclick={removeMaskPoint}>Remove point</button>
              <button type="button" class="btn" disabled={locked} onclick={startDrawing}>Redraw</button>
              <button type="button" class="btn btn-danger" disabled={locked} onclick={removeMask}>Remove mask</button>
              <p class="caption grow">Tap the picture to add a point where you tap (with Add points on), or double-click anywhere; it joins the nearest edge. Drag points to move them; Backspace removes the selected one.</p>
            {:else}
              <button type="button" class="btn btn-primary" disabled={locked || !s} onclick={startDrawing}>Draw mask</button>
              <button type="button" class="btn" disabled={locked || !s} onclick={() => set(`/slices/${sliceIndex}/mask`, defaultMask() as unknown as JSONValue)}>Rectangle</button>
              <p class="caption grow">A mask hides everything outside its shape. Draw mask: tap the corners of the visible area on the picture. Feather softens the edge.</p>
            {/if}
          </div>
        {/if}
      </section>
    {/if}
  </section>
</div>

<style>
  .screen { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
  .list { flex: 1 1 280px; max-width: 340px; display: flex; flex-direction: column; gap: 8px; }
  .out { flex-direction: column; align-items: stretch; gap: 4px; min-height: var(--touch); }
  .out .head { display: flex; align-items: center; gap: 10px; }
  .nm { font-weight: 600; font-size: 15px; }
  .tone-red { color: var(--red); }
  .tone-faint { color: var(--text-3); }
  .tone-green { color: var(--text-2); }
  .pad { margin: 0; padding: 4px 2px; }
  .add .select { width: 100%; }
  .main { flex: 999 1 560px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .preview { position: relative; }
  .overlay { position: absolute; left: 0; top: 0; width: 100%; }
  .nopreview { padding: 32px; }
  .form { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .head2 { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  h3 { margin: 8px 0 0; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
  .fields { display: flex; flex-wrap: wrap; gap: 12px 16px; align-items: flex-end; }
  .fields .input { width: 120px; }
  .fields .select { min-width: 200px; }
  .fields .caption.grow { flex: 1 1 240px; align-self: center; }
  .row4 { display: flex; flex-wrap: wrap; gap: 8px; }
  .row4 .input { width: 90px; }
  .ro { display: inline-flex; align-items: center; min-height: var(--touch); color: var(--text-2); }
  .narrow { width: 90px; }
  .nudge { display: flex; flex-wrap: wrap; align-items: center; gap: 16px; }
  .nudge .caption { flex: 1 1 200px; margin: 0; }
  .yellow { color: var(--yellow); }
  .edges { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
  .edge { padding: 12px; display: flex; flex-direction: column; gap: 8px; }
  .edge .input { width: 100%; }
  .ehead { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .ehead .label { text-transform: capitalize; }
  .curve { width: 100px; height: 40px; background: var(--surface-2); border-radius: 4px; }
  .patterns { display: flex; flex-wrap: wrap; gap: 8px; }
  @media (max-width: 900px) {
    .list { max-width: none; }
  }
</style>
