<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script module lang="ts">
  // handle: the selected point (JSON pointer); group: what moves with it in remote mode (lib/remote.ts)
  const ui = $state({ selected: 0, canvas: 1, tab: 'outputs' as 'canvases' | 'outputs' | 'warp', mapper: 'cornerPin' as MapperMode, slice: 0, handle: null as string | null, group: 'point' as Group, maskAdd: false, draft: null as MapPoint[] | null, tool: null as MaskTool | null, remote: storedRemote() });

  // Remote mode on Warp & Slices, remembered per browser; by default on for touch screens narrower than 900 px
  const REMOTE_KEY = 'fanous.remote';
  function storedRemote(): boolean {
    try {
      const stored = localStorage.getItem(REMOTE_KEY);
      if (stored !== null) return stored === '1';
    } catch {
      // blocked storage: the default
    }
    return matchMedia('(pointer: coarse) and (max-width: 899.98px)').matches;
  }
  function setRemote(on: boolean) {
    ui.remote = on;
    ui.group = 'point';
    try {
      localStorage.setItem(REMOTE_KEY, on ? '1' : '0');
    } catch {
      // private mode or blocked storage: the choice lasts for this page only
    }
  }
</script>

<script lang="ts">
  import { onDestroy } from 'svelte';
  import NudgePad from '../components/NudgePad.svelte';
  import OutputColour from '../components/OutputColour.svelte';
  import OutputMapper from '../components/OutputMapper.svelte';
  import PresetStrip from '../components/PresetStrip.svelte';
  import RemotePanel from '../components/RemotePanel.svelte';
  import WallPanel from '../components/WallPanel.svelte';
  import WallWizard from '../components/WallWizard.svelte';
  import Preview from '../components/Preview.svelte';
  import {
    CANVAS_PRESETS, CANVAS_RATES, MAX_CANVASES, canvasSizeError, canvasTarget, layerRuns, layersOn, EDGES, insertNearest, clamp01, TEST_PATTERNS, UNIT_QUAD, blendCurvePath, circleMask, finishMask, handles, keystoneBadges, maskHandle, maskRemoval, maskTarget, modeText, movedHandle, nextSliceId, outputSize, overlayBadges, overlayLease, overlaySelection, presetBadges, presetNote, redrawIndex, spreadSources, statusText, toggleSmooth, toolPath, triangleDest,
    type MapPoint, type MapperMode, type MaskPoint, type MaskShape, type MaskTool, type OutputConfig,
  } from '../lib/outputs';
  import { mediaOptions, mediaPath, type LibrarySnapshot } from '../lib/layers';
  import { app, can, client, cmd, toastUndo } from '../lib/state.svelte';
  import { LOCKED_TITLE } from '../lib/patch-screen';
  import { lockTitle } from '../lib/show';
  import { go } from '../lib/router.svelte';
  import { sourcePixels, sourceFromPixels } from '../lib/outputs';
  import { downloadTemplatePNG, templateSVG } from '../lib/template';
  import { choose, grid, groups, label, members, nudgeCommand, nudgeQueue, step, type Group } from '../lib/remote';
  import { fromScreen, resampleMesh, toScreen } from '../lib/warp';
  import type { JSONValue } from '../lib/protocol';
  import { badge, freeOutputs, isManual, SEAM_STEPS, wallOf, type ManualField } from '../lib/walls';
  import { cancelWizard, endCheck, giveBack, keepLeftover, startWizard, stuckText, wallUI } from '../lib/wall-session.svelte';

  const locked = $derived(!can('programmer'));
  /** why the remote cannot move points: the role, or the show lock (the engine would refuse) */
  const moveLock = $derived(lockTitle('programmer', !locked, app.project.showLock));
  const outputs = $derived(app.project.outputs);
  const displays = $derived(app.live.displays);
  const statuses = $derived(new Map(app.live.outputs.map((s) => [s.id, s])));
  const canvases = $derived(app.project.canvases);
  /** canvas 1: its rate is every canvas's rate, its clock master drives the compositor */
  const first = $derived(canvases[0]);
  /** the canvas shown on the Canvases tab */
  const canvas = $derived(canvases.find((c) => c.id === ui.canvas) ?? first);
  const output = $derived(outputs.find((o) => o.id === ui.selected) ?? outputs[0]);
  const status = $derived(output ? statuses.get(output.id) : undefined);
  const size = $derived(output ? outputSize(output, displays) : { w: 1920, h: 1080 });
  const lost = $derived(app.live.outputs.filter((s) => s.state === 'lost'));
  const walls = $derived(app.project.walls ?? []);
  /** the wall the selected output is in */
  const wall = $derived(output ? wallOf(walls, output.id) : undefined);
  /** why a wall cannot be made or changed: the role, the show lock */
  const wallLock = $derived(lockTitle('programmer', !locked, app.project.showLock));
  const freeCount = $derived(freeOutputs(outputs, walls).length);
  const checking = $derived(wallUI.check ? walls.find((w) => w.id === wallUI.check?.wall) : undefined);
  // a seam check whose wall went (Undo, another client) ends, and its outputs get their own test patterns back
  $effect(() => {
    if (wallUI.check && !checking) void endCheck();
  });
  // leaving the screen ends the seam check and the wizard: nothing else would show that they still hold the projectors
  onDestroy(() => {
    void endCheck();
    if (wallUI.wizard) void cancelWizard();
  });
  /** test patterns waiting to be given back with nothing open that would: a reloaded page's, or a check whose wall went */
  const leftBehind = $derived(!!wallUI.leftover || (!wallUI.wizard && !checking && Object.keys(wallUI.saved).length > 0));
  const newWallReason = $derived(wallLock ?? (freeCount < 2 ? 'Add at least two outputs that are in no wall yet.' : null));
  /** a wall panel's "Open in Warp & Slices" and the Grid step of the seam check */
  function openWarp(id: number) {
    pickOutput(id);
    ui.tab = 'warp';
  }
  function backToWall(field: ManualField) {
    if (wall && output) void cmd('wall.set', { id: wall.id, resetManual: [{ output: output.id, field }] });
  }
  const display = $derived(displays.find((d) => d.uuid === output?.display?.uuid));
  const previewTarget = $derived(output && ui.tab !== 'canvases' ? `output:${output.id}` : canvasTarget(canvas?.id ?? 1));
  const previewAspect = $derived(output && ui.tab !== 'canvases' ? `${size.w} / ${size.h}` : canvas ? `${canvas.width} / ${canvas.height}` : '16 / 9');
  /** canvas size and rate being edited; null = what the project has */
  let formatDraft = $state<{ id: number; width: number; height: number; fps: number } | null>(null);
  const format = $derived(formatDraft && formatDraft.id === canvas?.id ? formatDraft : { id: canvas?.id ?? 1, width: canvas?.width ?? 1920, height: canvas?.height ?? 1080, fps: first?.fps ?? 60 });
  const formatChanged = $derived(!!canvas && (format.width !== canvas.width || format.height !== canvas.height || format.fps !== (canvas.fps ?? 60)));
  const formatError = $derived(formatChanged ? canvasSizeError(format.width, format.height) : null);
  function editFormat(change: Partial<{ width: number; height: number; fps: number }>) {
    formatDraft = { ...format, ...change };
  }
  async function applyFormat() {
    if (!canvas || formatError) return;
    const { width, height, fps } = format;
    const all = canvas.id === first?.id && canvases.length > 1 && fps !== (first?.fps ?? 60) ? ' The rate applies to every canvas.' : '';
    if (!confirm(`Change ${canvas.name} to ${width} × ${height} at ${fps} fps? The canvases are re-created: every output blanks briefly. Slices and outputs keep their settings.${all}`)) return;
    if ((await cmd('canvas.set', { id: canvas.id, width, height, fps })) !== undefined) formatDraft = null;
  }
  async function addCanvas() {
    const size = first ? { width: first.width, height: first.height } : { width: 1920, height: 1080 };
    if (!confirm(`Add a canvas of ${size.width} × ${size.height}? The canvases are re-created: every output blanks briefly.`)) return;
    const id = await cmd('canvas.add', size);
    if (typeof id === 'number') ui.canvas = id;
  }
  async function removeCanvas() {
    if (!canvas || canvas.id === 1) return;
    const name = canvas.name;
    if (!confirm(`Remove ${name}? Its layers and the slices that show it move to ${first?.name ?? 'Canvas 1'}; every output blanks briefly.`)) return;
    if ((await cmd('canvas.remove', { id: canvas.id })) !== undefined) {
      ui.canvas = 1;
      toastUndo(`${name} removed.`);
    }
  }
  const canvasLayers = $derived(canvas ? layerRuns(layersOn(app.project.layerCanvas, app.project.layerCount, canvas.id)) : '');
  const sliceIndex = $derived(Math.min(ui.slice, Math.max(0, (output?.slices.length ?? 1) - 1)));

  function set(path: string, value: JSONValue) {
    if (!output) return;
    overlay.edited();
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
        pickOutput(id);
        justAdded = id;
      }
    });
  }
  /** a row or edge of one output is not a selection on another */
  function pickOutput(id: number) {
    ui.selected = id;
    ui.group = 'point';
  }
  /** the output that was just added: the screen offers the next step for it */
  let justAdded = $state<number | null>(null);
  async function removeOutput() {
    if (!output) return;
    const name = output.name;
    if ((await cmd('output.remove', { id: output.id })) !== undefined) toastUndo(`${name} removed.`);
  }
  function point(path: string, p: MapPoint) {
    // a mask point keeps its Bézier handles; a Bézier handle is stored as the offset from its point
    if (!output) return;
    const moved = movedHandle(output, path, p);
    set(moved.path, moved.value as unknown as JSONValue);
  }
  /** A new density keeps the current shape: the new points are placed on the current surface. */
  function setMesh(n: number) {
    set('/warp/mesh', n <= 1 ? null : (resampleMesh(output?.warp.mesh, n, n) as unknown as JSONValue));
  }
  function resetMesh() {
    const mesh = output?.warp.mesh;
    if (mesh) set('/warp/mesh', resampleMesh(null, mesh.cols, mesh.rows) as unknown as JSONValue);
  }
  function addSlice() {
    if (!output) return;
    // output.set only replaces existing pointers, so append by setting the whole list
    const slice = { id: nextSliceId(output), canvas: output.slices[sliceIndex]?.canvas ?? 1, source: { x: 0, y: 0, w: 1, h: 1 }, dest: UNIT_QUAD, opacity: 1 };
    set('/slices', [...output.slices, slice] as unknown as JSONValue);
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
  function resetSlice() {
    const s = output?.slices[sliceIndex];
    if (!s) return;
    set(`/slices/${sliceIndex}`, { ...s, source: { x: 0, y: 0, w: 1, h: 1 }, dest: UNIT_QUAD, opacity: 1 } as unknown as JSONValue);
    toastUndo(`Slice ${s.id} reset to the whole canvas.`);
  }
  function spreadCanvas() {
    if (!output) return;
    set('/slices', spreadSources(output.slices, size) as unknown as JSONValue);
    toastUndo('Canvas spread over the slices, left to right.');
  }
  /** Slice shapes (DESIGN §9.10 item 5), each one edit: Triangle meets the top corners in the middle of the top edge,
   *  Circle adds an ellipse mask filling the slice's corners' bounding box */
  function triangle() {
    const s = output?.slices[sliceIndex];
    if (!s) return;
    set(`/slices/${sliceIndex}/dest`, triangleDest(s.dest) as unknown as JSONValue);
    toastUndo(`Slice ${s.id} is a triangle: drag a top corner away for a quad again.`);
  }
  function circle() {
    const s = output?.slices[sliceIndex];
    if (!s) return;
    set(`/slices/${sliceIndex}/masks`, [...(s.masks ?? []), circleMask(s.dest)] as unknown as JSONValue);
    toastUndo(`Slice ${s.id} has a circle mask: Mask mode edits it.`);
  }
  /** the slice's masks, and the path mask Add points acts on (−1: none) */
  const masks = $derived(output?.slices[sliceIndex]?.masks ?? []);
  const maskIndex = $derived(maskTarget(output?.slices[sliceIndex], sliceIndex, ui.handle));
  /** the selected mask point (also while one of its Bézier handles is selected) */
  const maskPoint = $derived.by(() => {
    const h = maskHandle(ui.handle);
    return h?.slice === sliceIndex ? masks[h.mask]?.path?.[h.point] : undefined;
  });
  function removeMask(m: number) {
    const which = masks.length > 1 ? `Mask ${m + 1}` : 'Mask';
    set(`/slices/${sliceIndex}/masks`, masks.filter((_, k) => k !== m) as unknown as JSONValue);
    ui.handle = null;
    toastUndo(`${which} of slice ${output?.slices[sliceIndex]?.id} removed.`);
  }
  /** Invert: an add mask becomes a subtract mask (a hole) and back */
  function invertMask(m: number) {
    set(`/slices/${sliceIndex}/masks/${m}/mode`, masks[m]?.mode === 'subtract' ? 'add' : 'subtract');
  }
  /** a double-tap on a mask point (or the Smooth button): corner ↔ smooth; a handle that goes leaves its point selected */
  function toggleSmoothAt(path: string | null) {
    const h = maskHandle(path);
    const list = h?.slice === sliceIndex ? masks[h.mask]?.path : undefined;
    if (!h || !list || locked) return;
    const at = `/slices/${sliceIndex}/masks/${h.mask}/path/${h.point}`;
    set(at, toggleSmooth(list, h.point) as unknown as JSONValue);
    ui.handle = at;
  }
  /** the library's stills, for an image mask (read while the mask tools show, again after each library scan) */
  let library = $state.raw<LibrarySnapshot | null>(null);
  $effect(() => {
    void app.live.library.scannedAt;
    if (ui.tab !== 'warp' || ui.mapper !== 'mask') return;
    const abort = new AbortController();
    fetch('/api/library', { signal: abort.signal })
      .then((r) => (r.ok ? (r.json() as Promise<LibrarySnapshot>) : null))
      .then((snapshot) => snapshot && (library = snapshot), () => {});
    return () => abort.abort();
  });
  const stills = $derived(mediaOptions(library, 'still'));
  function imageMask(value: string) {
    const [folder, file] = value.split('/').map(Number);
    if (folder && file) set(`/slices/${sliceIndex}/masks`, [...masks, { mode: 'add', feather: 0, image: { folder, file } }] as unknown as JSONValue);
  }
  /** the points of the mapper mode; the selected one is the anchor of the selection */
  const points = $derived(output ? handles(output, ui.mapper, sliceIndex) : []);
  const cells = $derived(output ? grid(output, ui.mapper, points.length) : null);
  const anchor = $derived(points.findIndex((h) => h.path === ui.handle));
  const modeGroups = $derived(groups(ui.mapper));
  /** groups are a remote-mode tool: outside it the arrows and the nudge pad move the selected point only */
  const group = $derived(ui.remote && modeGroups.includes(ui.group) ? ui.group : 'point');
  /** the indices that move together: the selected point, or its row, column, an edge or all (a mask's Bézier handles
   *  move with their points then, and do not count) */
  const selection = $derived(members(cells, points.length, group, anchor).filter((i) => group === 'point' || !maskHandle(points[i]!.path)?.side));
  const selectedHandle = $derived(points[anchor]?.point ?? null);
  /** the selected point as it appears on screen (through the warp), in output pixels */
  const selectedScreen = $derived(selectedHandle && output ? toScreen(output, ui.mapper, selectedHandle) : null);
  function moveSelected(on: { x?: number; y?: number }) {
    if (!output || !ui.handle || !selectedScreen) return;
    const p = fromScreen(output, ui.mapper, { x: on.x ?? selectedScreen.x, y: on.y ?? selectedScreen.y });
    point(ui.handle, { x: Math.min(1, Math.max(0, p.x)), y: Math.min(1, Math.max(0, p.y)) });
  }
  function select(next: { group: Group; anchor: number }) {
    ui.group = next.group;
    ui.handle = points[next.anchor]?.path ?? null;
  }
  function stepSelection(dir: 1 | -1) {
    select(step(cells, points.length, group, anchor, dir));
  }
  /** one output.set per nudge for all moved points; a burst while one is on its way is added up and sent next */
  const nudge = nudgeQueue();
  function nudgeSelected(dx: number, dy: number) {
    if (!output || selection.length === 0) return;
    const id = output.id, mode = ui.mapper, slice = sliceIndex, indices = selection;
    overlay.edited();
    nudge(`${id} ${mode} ${slice} ${group} ${anchor}`, dx, dy, async (dx, dy) => {
      const current = app.project.outputs.find((o) => o.id === id);
      const command = current && nudgeCommand(current, mode, slice, indices, dx, dy, outputSize(current, displays));
      if (command) await cmd('output.set', { id, ...command });
    });
  }
  // the edit overlay (DESIGN §9.10 item 4): on whenever Warp & Slices opens, the selected point sent with it and the lease
  // renewed while the tab stays open and the page visible (a hidden tab's timers are throttled to once a minute, so the
  // lease would lapse and come back); it stops after 10 minutes without an edit, and the switch shows that. Sent quietly:
  // a renewal must not clear another refusal's banner, and one lost in an outage heals at the next. Nothing is sent under
  // show lock or without the role: the engine refuses it, and has ended the lease itself or never had one
  let overlayOn = $state(true);
  let visible = $state(document.visibilityState !== 'hidden');
  const overlayLock = $derived(moveLock ?? (app.live.show.mode ? 'Off in show mode' : undefined));
  const overlay = overlayLease((id, on, selected) => {
    if (!app.project.showLock && can('programmer')) client.cmd('output.overlay', { id, on, selected }).catch(() => {});
  }, () => (overlayOn = false));
  const overlaySelected = $derived(overlaySelection(ui.mapper, sliceIndex, anchor, ui.handle));
  $effect(() => {
    if (ui.tab !== 'warp') overlayOn = true;  // on again the next time the tab opens
  });
  let warpOpen = false;  // not state: whether the tab was open when the effect below last ran
  $effect(() => {
    if (ui.tab === 'warp' && !warpOpen) overlay.edited();  // the 10 minutes count from opening the tab
    warpOpen = ui.tab === 'warp';
    if (output && warpOpen && overlayOn && !overlayLock && visible && app.live.engine.rendering) overlay.start(output.id, overlaySelected);
    else overlay.stop();
  });
  onDestroy(() => overlay.stop());
  const remoteLabel = $derived(output ? label(output, ui.mapper, sliceIndex, cells, group, anchor) : '');
  /** "x 960.25 · y 0 px", "5 points move together" */
  const remoteDetail = $derived.by(() => {
    if (selection.length > 1) return `${selection.length} points move together`;
    if (!selectedScreen) return points.length ? 'Tap Next, or a point on the picture' : 'No points to move in this mode';
    const px = (v: number) => Math.round(v * 100) / 100;
    return `x ${px(selectedScreen.x * size.w)} · y ${px(selectedScreen.y * size.h)} px`;
  });
  /** the canvas the selected slice takes its picture from */
  const sliceCanvas = $derived(canvases.find((c) => c.id === output?.slices[sliceIndex]?.canvas));
  async function exportTemplate() {
    if (!output || !sliceCanvas) return;
    const size = { width: sliceCanvas.width, height: sliceCanvas.height };
    const name = output.name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    // the slices on the selected slice's canvas (a template is drawn on one canvas)
    const onCanvas = { ...output, slices: output.slices.filter((s) => s.canvas === sliceCanvas.id) };
    const suffix = canvases.length > 1 ? `-canvas${sliceCanvas.id}` : '';
    await downloadTemplatePNG(templateSVG(onCanvas, size), size.width, size.height, `fanous-template-${name}${suffix}-${size.width}x${size.height}.png`);
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
    const target = masks[maskIndex]?.path;
    if (!target) return;
    const { path, index } = insertNearest(target, q);
    set(`/slices/${sliceIndex}/masks/${maskIndex}/path`, path as unknown as JSONValue);
    ui.handle = `/slices/${sliceIndex}/masks/${maskIndex}/path/${index}`;
  }
  /** the mask Redraw was chosen on, as it was then (`finishMask` looks it up when the shape is done; a copy, as patches
   *  change the project in place); null: a new mask */
  let redraw = $state.raw<MaskShape | null>(null);
  /** a mask tool: Polygon takes taps (`ui.draft`), the others one drag (`ui.tool`); a Redraw keeps its target */
  function startTool(tool: 'polygon' | MaskTool, target: MaskShape | null = redraw) {
    redraw = target && $state.snapshot(target);
    ui.draft = tool === 'polygon' ? [] : null;
    ui.tool = tool === 'polygon' ? null : tool;
    ui.handle = null;
    ui.maskAdd = false;
  }
  function stopTool() {
    ui.draft = null;
    ui.tool = null;
    redraw = null;
  }
  /** what the drawing caption says: a Redraw whose mask another client changed or removed meanwhile adds a mask */
  const drawingText = $derived.by(() => {
    if (!redraw) return 'Drawing a mask:';
    const i = redrawIndex(masks, redraw);
    return i >= 0 ? `Redrawing mask ${i + 1}:` : 'Drawing a new mask (the mask to redraw has changed since):';
  });
  /** a tool's path, as one edit */
  function addMask(path: MaskPoint[]) {
    set(`/slices/${sliceIndex}/masks`, finishMask(masks, path, redraw) as unknown as JSONValue);
    stopTool();
  }
  function finishDrawing() {
    if (ui.draft && ui.draft.length >= 3) addMask(ui.draft);
  }
  function removeMaskPointAt(path: string) {
    if (maskHandle(path)?.slice !== sliceIndex) return;
    ui.handle = path;
    removeMaskPoint();
  }
  /** the selected point goes (a mask keeps 3), or the selected Bézier handle (its point stays, selected) */
  const removal = $derived(output && maskHandle(ui.handle)?.slice === sliceIndex ? maskRemoval(output, ui.handle) : null);
  function removeMaskPoint() {
    if (!removal) return;
    set(removal.path, removal.value as unknown as JSONValue);
    ui.handle = maskHandle(ui.handle)?.side ? removal.path : null;
    ui.group = 'point';
  }
</script>

<svelte:document onvisibilitychange={() => (visible = document.visibilityState !== 'hidden')} />

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
    <button type="button" class="btn btn-primary" onclick={() => { pickOutput(justAdded!); ui.tab = 'warp'; justAdded = null; }}>Align this output</button>
    <button type="button" class="btn btn-ghost" onclick={() => (justAdded = null)}>Later</button>
  </div>
{/if}

{#if leftBehind}
  <div class="banner banner-yellow" role="status">
    <span class="dot dot-yellow"></span>
    <span><strong>Outputs still show a projector-wall test pattern</strong> · {stuckText() ?? (wallUI.leftover ? `left by ${wallUI.leftover.wall ? `the seam check of Wall ${wallUI.leftover.wall}` : 'the wall wizard'} before this page was reloaded` : 'the seam check ended when its wall went')}</span>
    <span class="spacer"></span>
    <button type="button" class="btn" onclick={giveBack}>Give the test patterns back</button>
    {#if wallUI.leftover}<button type="button" class="btn btn-ghost" onclick={keepLeftover}>Keep them</button>{/if}
  </div>
{/if}

{#if checking && wallUI.check && ui.tab !== 'outputs'}
  <div class="banner banner-yellow" role="status">
    <span class="dot dot-yellow"></span>
    <span><strong>Seam check on {checking.name}</strong> · {SEAM_STEPS[wallUI.check.step]?.name} on every projector of the wall</span>
    <span class="spacer"></span>
    <button type="button" class="btn" onclick={() => (ui.tab = 'outputs')}>Back to the seam check</button>
  </div>
{/if}

<div class="screen">
  {#if ui.tab === 'outputs'}
    <section class="walls" aria-label="Projector walls">
      {#if wallUI.wizard}
        <WallWizard />
      {:else}
        {#each walls as w (w.id)}<WallPanel wall={w} onwarp={openWarp} />{/each}
        <div class="wallbar">
          <button type="button" class="btn" disabled={!!newWallReason} onclick={() => startWizard()}>New projector wall</button>
          {#if newWallReason}<span class="caption">{newWallReason}</span>{:else if walls.length === 0}<span class="caption">Two or more projectors side by side or stacked: the wall gives each its part of the canvas and the overlaps, then guides the blend tuning.</span>{/if}
        </div>
      {/if}
    </section>
  {/if}
  <aside class="list">
    {#each outputs as o (o.id)}
      {@const st = statusText(statuses.get(o.id), o)}
      <button type="button" class="row out" aria-pressed={output?.id === o.id} onclick={() => pickOutput(o.id)}>
        <span class="head"><span class="dot dot-{st.tone === 'green' ? 'green' : st.tone === 'red' ? 'red' : 'off'}"></span><span class="nm">{o.name}</span><span class="spacer"></span><span class="caption mono">{Math.round(o.intensity * 100)} %</span></span>
        <span class="caption ellipsis tone-{st.tone}">{st.text}</span>
        {#if statuses.get(o.id)?.modeNote}<span class="caption yellow">{statuses.get(o.id)?.modeNote}</span>{/if}
        {#each [...presetBadges(statuses.get(o.id)), ...keystoneBadges(statuses.get(o.id))] as b (b.text)}<span class="badge wallbadge" class:badge-warn={b.warn}>{b.text}</span>{/each}
        {#if wallOf(walls, o.id)}<span class="badge wallbadge">{badge(wallOf(walls, o.id)!, o.id)}</span>{/if}
      </button>
    {:else}
      <p class="caption pad">No outputs yet. Add one for each projector or display with "Add output on" below; a new output shows the whole canvas.</p>
    {/each}
    <div class="add">
      <label class="field"><span>Add output on</span>
        <select class="select" disabled={locked} title={locked ? LOCKED_TITLE : undefined} onchange={(e) => { addOutput(e.currentTarget.value || null); e.currentTarget.value = ''; }}>
          <option value="">Choose a display…</option>
          {#each displays as d (d.uuid)}<option value={d.uuid}>{d.name} · {d.width} × {d.height}{d.builtin ? ' (this Mac)' : ''}</option>{/each}
          <option value="none">Unassigned (assign later)</option>
        </select>
      </label>
    </div>
    <p class="caption pad">Displays are matched by identity, so a replugged projector lands on the same output.</p>
  </aside>

  <section class="main" class:remote={ui.remote && ui.tab === 'warp'}>
    <div class="preview">
      {#if app.live.engine.rendering}
        <!-- an output preview takes the output's shape (so does its stream, B32), and the overlay uses exactly the
             same box, so handles sit on the picture whatever the display's aspect ratio -->
        <Preview target={previewTarget} aspect={previewAspect} />
        {#if output && ui.tab === 'warp'}
          <div class="overlay" style:aspect-ratio={previewAspect}>
            <OutputMapper {output} mode={ui.mapper} {sliceIndex} {size} bind:selected={() => ui.handle, (path) => select({ group: 'point', anchor: points.findIndex((h) => h.path === path) })} marked={selection.length > 1 ? selection.map((i) => points[i]!.path) : []} onchange={point} onnudge={nudgeSelected} onstep={stepSelection} addMode={ui.maskAdd} draft={ui.mapper === 'mask' ? ui.draft : null} onadd={addMaskAt} onremove={removeMaskPointAt}
              tool={ui.mapper === 'mask' && !locked ? ui.tool : null} ondraw={addMask} ontoggle={ui.mapper === 'mask' ? toggleSmoothAt : undefined} />
          </div>
        {/if}
        <!-- the preview and the handles show the mapping as edited; the projector shows a preset and the keystone (DESIGN §9.10 item 3) -->
        {#if output && ui.tab === 'warp'}
          <!-- always there, space reserved: a badge or the note appearing does not move the controls below -->
          <div class="kbadges">
            <!-- one way: off while it cannot be on, with the reason beside it -->
            <label class="switch" title="Draws the warp, the slice and mask outlines and the selected point on the output itself while this tab is open; off after 10 minutes without an edit">
              <input type="checkbox" role="switch" checked={overlayOn && !overlayLock} disabled={!!overlayLock} aria-describedby={overlayLock ? 'overlay-lock' : undefined}
                onchange={(e) => {
                  overlayOn = e.currentTarget.checked;
                  if (overlayOn) overlay.edited();  // switched on: 10 minutes from now
                }} />
              <span class="track"></span><span>Show on output</span>
            </label>
            {#if overlayLock}<span class="caption" id="overlay-lock">{overlayLock}</span>{/if}
            {#each [...presetBadges(status), ...keystoneBadges(status), ...overlayBadges(status)] as b (b.text)}<span class="badge" class:badge-warn={b.warn}>{b.text}</span>{/each}
          </div>
          <p class="caption yellow pnote" role="status">{presetNote(status) ?? ''}</p>
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
        <div class="head2">
          <div class="segmented" role="group" aria-label="Canvas">
            {#each canvases as c (c.id)}<button type="button" class="btn" aria-pressed={canvas?.id === c.id} onclick={() => (ui.canvas = c.id)}>{c.name}</button>{/each}
          </div>
          <button type="button" class="btn" disabled={locked || canvases.length >= MAX_CANVASES || app.live.show.mode} title={locked ? LOCKED_TITLE : canvases.length >= MAX_CANVASES ? `At most ${MAX_CANVASES} canvases` : app.live.show.mode ? 'Leave show mode to add a canvas' : 'Another canvas for other layers, e.g. an LED wall next to the projectors'} onclick={addCanvas}>Add canvas</button>
          <span class="spacer"></span>
          {#if canvas && canvas.id !== 1}<button type="button" class="btn btn-danger" disabled={locked || app.live.show.mode} title={locked ? LOCKED_TITLE : app.live.show.mode ? 'Leave show mode to remove a canvas' : undefined} onclick={removeCanvas}>Remove canvas</button>{/if}
        </div>
        {#if canvas}
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
              <select class="select" disabled={locked || canvas.id !== first?.id} title={canvas.id !== first?.id ? `All canvases run at the rate of ${first?.name ?? 'Canvas 1'}; change it there` : undefined} value={String(format.fps)} onchange={(e) => editFormat({ fps: Number(e.currentTarget.value) })}>
                {#each CANVAS_RATES as r (r)}<option value={String(r)}>{r} fps</option>{/each}
              </select>
            </label>
            <div class="field"><span>&nbsp;</span>
              <span class="row4">
                <button type="button" class="btn" disabled={locked || !formatChanged || !!formatError || app.live.show.mode} title={locked ? LOCKED_TITLE : app.live.show.mode ? 'Leave show mode to change the canvas' : undefined} onclick={applyFormat}>Apply</button>
                {#if formatChanged}<button type="button" class="btn btn-ghost" onclick={() => (formatDraft = null)}>Revert</button>{/if}
              </span>
            </div>
            {#if canvas.id === first?.id}
            <label class="field"><span>Clock master</span>
              <select class="select" disabled={locked} value={canvas.clockMaster ?? ''} onchange={(e) => void cmd('canvas.set', { id: canvas.id, path: '/clockMaster', value: e.currentTarget.value ? Number(e.currentTarget.value) : null })}>
                <option value="">First bound output</option>
                {#each outputs as o (o.id)}<option value={o.id}>{o.name}</option>{/each}
              </select>
            </label>
            {/if}
          </div>
          {#if formatError}<p class="caption tone-red">{formatError}</p>{/if}
          {#if app.live.canvas?.error}<p class="caption tone-red">Canvas change failed, the previous canvas is still running: {app.live.canvas.error}</p>{/if}
          {#if app.live.canvas?.pending}<p class="caption">Rendering {app.live.canvas.width} × {app.live.canvas.height} at {app.live.canvas.fps} fps. {app.live.show.mode ? 'The project canvas applies when show mode ends.' : 'Applying the project canvas…'}</p>{/if}
          <p class="caption">Layers on this canvas: {canvasLayers || 'none'}. Pick a layer's canvas under its name on the Layers screen; a slice picks its canvas on Warp &amp; Slices. Applying a new size or frame rate re-creates the canvases: outputs blank briefly. Slices keep their place (they are stored as fractions of the canvas).</p>
        {/if}
      </section>
    {:else if !output}
      <section class="panel form"><p class="muted">Select or add an output.</p></section>
    {:else if ui.tab === 'outputs'}
      <section class="panel form" aria-label="Output settings">
        <div class="head2"><h2>{output.name}</h2><span class="caption tone-{statusText(status, output).tone}">{statusText(status, output).text}</span><span class="spacer"></span>
          <button type="button" class="btn btn-danger" disabled={locked} title={locked ? LOCKED_TITLE : undefined} onclick={removeOutput}>Remove output</button></div>
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
        {#if status?.modeNote}<p class="caption yellow">{status.modeNote}</p>{/if}
        {#if display?.builtin}<p class="caption yellow">This output uses the Mac's own display: the local UI shell will be hidden behind it.</p>{/if}

        <h3>Blend edges</h3>
        {#if wall}<p class="caption">In {wall.name}: the wall sets the overlap of the inner edges and slice 1's part of the canvas; tune the seams in its panel above. An overlap typed here becomes manual, and the wall leaves it alone.</p>{/if}
        <div class="edges">
          {#each EDGES as edge (edge)}
            {@const e = output.blend[edge]}
            <div class="edge panel" role="group" aria-label="{edge} edge">
              <div class="ehead"><span class="label">{edge}</span>{#if isManual(wall, output.id, `overlap.${edge}`)}<span class="badge badge-warn">manual</span>{/if}<svg class="curve" viewBox="0 0 100 40" aria-hidden="true"><path d={blendCurvePath(e, 100, 40)} fill="none" stroke="#4C9EFF" stroke-width="2" /></svg></div>
              <label class="field"><span>Overlap (px)</span><input class="input mono" type="number" min="0" value={e.overlap} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/overlap`)} /></label>
              {#if isManual(wall, output.id, `overlap.${edge}`)}<button type="button" class="btn" disabled={!!wallLock} title={wallLock ?? `Give this overlap back to ${wall?.name}`} onclick={() => backToWall(`overlap.${edge}`)}>Back to wall</button>{/if}
              <p class="caption">Overlap: width of the strip shared with the neighbouring projector, in pixels of this output.</p>
              <label class="field"><span>Power</span><input class="input mono" type="number" min="0.1" max="10" step="0.1" value={e.power} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/power`)} /></label>
              <p class="caption">Power: steepness of the fade. 2 is a smooth S-curve; higher is sharper in the middle.</p>
              {#if e.gammaRGB}
                <label class="field"><span>Gamma R · G · B</span><input class="input mono" value={e.gammaRGB.map((g) => g.toFixed(2)).join(' · ')} disabled /></label>
                <button type="button" class="btn" disabled={locked} onclick={() => set(`/blend/${edge}/gammaRGB`, null)}>One gamma for R, G, B</button>
                <p class="caption">Gamma: this edge has a gamma per colour{wall ? ', tuned on its seam in the wall panel' : ''}. One gamma for R, G, B brings the single gamma back.</p>
              {:else}
                <label class="field"><span>Gamma</span><input class="input mono" type="number" min="0.5" max="5" step="0.1" value={e.gamma} disabled={locked} onchange={(ev) => number(ev, `/blend/${edge}/gamma`)} /></label>
                <p class="caption">Gamma: set it to the projector's gamma (usually 2.2) so the two lights add up evenly.</p>
              {/if}
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
            <button type="button" class="btn" aria-pressed={output.testPattern === i} disabled={locked} title={locked ? LOCKED_TITLE : undefined} onclick={() => set('/testPattern', i)}>{name}</button>
          {/each}
        </div>
        <p class="caption">The Output fixture's Test pattern and Master channels override this; its Blend channel at 128+ shows the raw canvas (no blend, warp, mask or keystone) for alignment.</p>

        <h3>Colour</h3>
        <OutputColour {output} />
        <p class="caption">Match this projector to the others by eye, on Colour bars, Grey steps or the Grey and White fields: the gain scales each channel, the black offset raises its black over the whole output. Gain and black offset also apply in Raw, like the intensity.</p>
      </section>
    {:else}
      <section class="panel form" aria-label="Warp and slices">
        <div class="head2">
          <h2>{output.name}</h2>
          <div class="segmented wrap" role="group" aria-label="Edit">
            <button type="button" class="btn" aria-pressed={ui.mapper === 'cornerPin'} onclick={() => (ui.mapper = 'cornerPin')}>Corner pin · 4 points</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'mesh'} onclick={() => (ui.mapper = 'mesh')}>Mesh · up to 33 × 33</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'slices'} onclick={() => (ui.mapper = 'slices')}>Slices</button>
            <button type="button" class="btn" aria-pressed={ui.mapper === 'mask'} onclick={() => (ui.mapper = 'mask')}>Mask</button>
          </div>
          <button type="button" class="btn" aria-pressed={ui.remote} title="Big controls for aligning from an iPad: step through the points, nudge them, drag on a trackpad" onclick={() => setRemote(!ui.remote)}>Remote</button>
          <button type="button" class="btn" disabled={!sliceCanvas} title="A PNG at canvas size showing which part of the canvas each slice uses and what its mask leaves visible: a guide for making content" onclick={exportTemplate}>Content template (PNG)</button>
          <span class="spacer"></span>
          {#if selectedHandle && selectedScreen && selection.length === 1}
            <span class="caption">Selected point (px)</span>
            <input class="input mono narrow" type="number" aria-label="Point x in pixels" value={Math.round(selectedScreen.x * size.w)} disabled={locked} onchange={(e) => moveSelected({ x: Number(e.currentTarget.value) / size.w })} />
            <input class="input mono narrow" type="number" aria-label="Point y in pixels" value={Math.round(selectedScreen.y * size.h)} disabled={locked} onchange={(e) => moveSelected({ y: Number(e.currentTarget.value) / size.h })} />
          {/if}
        </div>
        {#if ui.remote}
          <RemotePanel label={remoteLabel} detail={remoteDetail} {group} groups={modeGroups} lock={moveLock} onnudge={nudgeSelected}
            onstep={stepSelection} ongroup={(g) => select(choose(cells, points.length, g, anchor))} />
        {:else if selectedHandle}
          <div class="nudge">
            <NudgePad disabled={locked} onnudge={nudgeSelected} />
            <p class="caption">Tap a handle on the picture, then nudge it here. 10 px moves ten pixels per press; hold an arrow for 0.25 px. Keyboard: arrow keys, Shift for ten, Tab for the next point. Remote has bigger controls.</p>
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
            <button type="button" class="btn" disabled={locked || !output.warp.mesh} onclick={resetMesh}>Reset mesh</button>
            <p class="caption grow">A change of density keeps the shape: the new points sit on the current surface (going down keeps the overall shape, not the detail in between). Reset mesh flattens it. The mesh is a smooth surface through its points.</p>
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
              <label class="field"><span>Canvas</span>
                <select class="select" disabled={locked} title={locked ? LOCKED_TITLE : 'The canvas this slice takes its picture from'} value={s.canvas} onchange={(e) => set(`/slices/${sliceIndex}/canvas`, Number(e.currentTarget.value))}>
                  {#if !sliceCanvas}<option value={s.canvas}>Canvas {s.canvas} · missing (black)</option>{/if}
                  {#each canvases as c (c.id)}<option value={c.id}>{c.name} · {c.width} × {c.height}</option>{/each}
                </select>
              </label>
              <div class="field" role="group" aria-label="Source rectangle on the canvas, in pixels"><span>Source x · y · w · h (canvas px){#if s.id === 1 && isManual(wall, output.id, 'source')} <span class="badge badge-warn">manual</span>{/if}</span>
                <span class="row4">
                  {#each ['x', 'y', 'w', 'h'] as k (k)}
                    <input class="input mono" type="number" step="1" min="0" aria-label="Source {k} in pixels" title="Stored as {Math.round(s.source[k as 'x'] * 10000) / 10000} (0–1 of the canvas)" value={sourcePixels(s.source, sliceCanvas)[k as 'x']} disabled={locked} onchange={(e) => { const v = sourceFromPixels(k as 'x', Number(e.currentTarget.value), sliceCanvas); if (v !== null) set(`/slices/${sliceIndex}/source/${k}`, v); }} />
                  {/each}
                </span>
              </div>
              {#if s.id === 1 && isManual(wall, output.id, 'source')}<button type="button" class="btn" disabled={!!wallLock} title={wallLock ?? `Give slice 1's part of the canvas back to ${wall?.name}`} onclick={() => backToWall('source')}>Back to wall</button>{/if}
              <label class="field"><span>Opacity %</span><input class="input mono" type="number" min="0" max="100" value={Math.round(s.opacity * 100)} disabled={locked} onchange={(e) => set(`/slices/${sliceIndex}/opacity`, Number(e.currentTarget.value) / 100)} /></label>
            {/if}
            <button type="button" class="btn" disabled={locked} onclick={addSlice}>Add slice</button>
            <button type="button" class="btn" disabled={locked} title="Whole canvas on the whole output; the masks stay" onclick={resetSlice}>Reset slice</button>
            <button type="button" class="btn" disabled={locked || output.slices.length < 2} title="One picture across all slices: each slice gets the next strip of the canvas, left to right, as wide as the slice is on the output" onclick={spreadCanvas}>Spread canvas</button>
            <button type="button" class="btn" disabled={locked || !output.slices[sliceIndex]} title={locked ? LOCKED_TITLE : 'The top corners meet in the middle of the top edge; drag one away for a quad again'} onclick={triangle}>Triangle</button>
            <button type="button" class="btn" disabled={locked || !output.slices[sliceIndex]} title={locked ? LOCKED_TITLE : "Adds an ellipse mask filling the slice's corners; edit it in Mask mode"} onclick={circle}>Circle</button>
            <button type="button" class="btn btn-danger" disabled={locked || output.slices.length <= 1} title={output.slices.length <= 1 ? 'An output needs at least one slice: use Reset slice instead' : undefined} onclick={removeSlice}>Remove slice</button>
          </div>
        {:else}
          {@const s = output.slices[sliceIndex]}
          <div class="fields">
            <label class="field"><span>Slice</span>
              <select class="select" value={sliceIndex} onchange={(e) => (ui.slice = Number(e.currentTarget.value))}>
                {#each output.slices as sl, i (sl.id)}<option value={i}>Slice {sl.id}</option>{/each}
              </select>
            </label>
            <div class="segmented wrap" role="group" aria-label="Mask tools">
              <button type="button" class="btn" aria-pressed={!!ui.draft} disabled={locked || !s} title="Tap the corners of the area that stays visible" onclick={() => ui.draft || startTool('polygon')}>Polygon</button>
              {#each [['rectangle', 'Rectangle'], ['ellipse', 'Ellipse'], ['freehand', 'Freehand']] as const as [tool, name] (tool)}
                <button type="button" class="btn" aria-pressed={ui.tool === tool} disabled={locked || !s} title={tool === 'freehand' ? 'Drag along the outline of the area that stays visible' : 'Drag a box on the picture'} onclick={() => ui.tool === tool || startTool(tool)}>{name}</button>
              {/each}
            </div>
            <label class="field"><span>Image mask</span>
              <select class="select" disabled={locked || !s || stills.length === 0} value="" onchange={(e) => { imageMask(e.currentTarget.value); e.currentTarget.value = ''; }}>
                <option value="">{stills.length === 0 ? 'No stills in the library' : 'Add a still from the library…'}</option>
                {#each stills as o (`${o.folder}/${o.file}`)}<option value={`${o.folder}/${o.file}`}>{o.label}</option>{/each}
              </select>
            </label>
          </div>
          {#if ui.draft || ui.tool}
            <div class="fields">
              {#if ui.draft}
                <p class="caption grow"><strong>{drawingText}</strong> tap the corners of the area that stays visible, in order around it ({ui.draft.length} so far, at least 3).</p>
                <button type="button" class="btn btn-primary" disabled={ui.draft.length < 3} onclick={finishDrawing}>Done</button>
                <button type="button" class="btn" disabled={ui.draft.length === 0} onclick={() => (ui.draft = ui.draft!.slice(0, -1))}>Undo last corner</button>
              {:else if ui.tool === 'freehand'}
                <p class="caption grow"><strong>{drawingText}</strong> drag along the outline of the area that stays visible, with a finger on an iPad; letting go closes it. Where it turns sharply it keeps a corner, elsewhere it is smooth; drag its points and handles after.</p>
              {:else}
                {@const tool = ui.tool}
                <p class="caption grow"><strong>{drawingText}</strong> drag a box on the picture; the {tool} fills it.</p>
                <button type="button" class="btn" onclick={() => { const path = toolPath(tool!, [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.9 }], size); if (path) addMask(path); }}>10 % inside</button>
              {/if}
              <button type="button" class="btn" onclick={stopTool}>Cancel</button>
            </div>
          {/if}
          <ul class="masks" aria-label="Masks of slice {s?.id ?? ''}">
            {#each masks as m, i (i)}
              {@const name = `Mask ${i + 1}`}
              <li class="mask">
                {#if m.path}
                  <button type="button" class="btn btn-ghost" aria-pressed={maskHandle(ui.handle)?.slice === sliceIndex && maskHandle(ui.handle)?.mask === i} title="Selects its first point" onclick={() => select({ group: 'point', anchor: points.findIndex((h) => h.path === `/slices/${sliceIndex}/masks/${i}/path/0`) })}>{name}</button>
                {:else}
                  <span class="mname">{name}</span>
                {/if}
                <span class="badge" class:badge-warn={m.mode === 'subtract'}>{m.mode === 'subtract' ? 'Subtract' : 'Add'}</span>
                <span class="caption grow ellipsis">{m.image ? (mediaPath(library, m.image.folder, m.image.file) ?? `Image ${m.image.folder} / ${m.image.file}`) : `${m.path?.length ?? 0} points`}</span>
                <button type="button" class="btn" aria-pressed={m.mode === 'subtract'} aria-label="Invert {name}" title="Add shows what is inside the shape, Subtract cuts it out (a hole)" disabled={locked} onclick={() => invertMask(i)}>Invert</button>
                {#if m.path}
                  <label class="field inline"><span>Feather px</span><input class="input mono" type="number" min="0" aria-label="{name} feather px" value={m.feather} disabled={locked} onchange={(e) => set(`/slices/${sliceIndex}/masks/${i}/feather`, Number(e.currentTarget.value))} /></label>
                  <button type="button" class="btn" aria-label="Redraw {name}" disabled={locked} onclick={() => startTool('polygon', m)}>Redraw</button>
                {/if}
                <button type="button" class="btn btn-danger" aria-label="Remove {name}" disabled={locked} onclick={() => removeMask(i)}>Remove</button>
              </li>
            {:else}
              <li class="caption">No masks: the whole slice shows. Add one with a tool above; new masks add, Invert makes a hole.</li>
            {/each}
          </ul>
          {#if maskIndex >= 0 && !ui.draft && !ui.tool}
            <div class="fields">
              <button type="button" class="btn" aria-pressed={ui.maskAdd} disabled={locked} onclick={() => (ui.maskAdd = !ui.maskAdd)}>{ui.maskAdd ? 'Adding points: tap the picture' : 'Add points'}</button>
              <button type="button" class="btn" aria-pressed={!!(maskPoint?.in || maskPoint?.out)} disabled={locked || !maskPoint} title="Smooth: Bézier handles from its neighbours; off: a corner. Double-tap a point does the same" onclick={() => toggleSmoothAt(ui.handle)}>Smooth point</button>
              <button type="button" class="btn" disabled={locked || !removal} onclick={removeMaskPoint}>{maskHandle(ui.handle)?.side ? 'Remove handle' : 'Remove point'}</button>
              <p class="caption grow">Tap the picture to add a point (with Add points on), or double-click anywhere; it joins the nearest edge, on a curve without changing it. Drag points and their handles; double-tap a point for corner or smooth; Backspace removes the selected point.</p>
            </div>
          {/if}
        {/if}
        <PresetStrip ids={[output.id]} />
      </section>
    {/if}
  </section>
</div>

<style>
  .screen { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
  .list { flex: 1 1 280px; max-width: 340px; display: flex; flex-direction: column; gap: 8px; }
  .walls { flex: 1 1 100%; display: flex; flex-direction: column; gap: 12px; }
  .wallbar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .wallbar .caption { flex: 1 1 280px; }
  .out { flex-direction: column; align-items: stretch; gap: 4px; min-height: var(--touch); }
  .out .head { display: flex; align-items: center; gap: 10px; }
  .nm { font-weight: 600; font-size: 15px; }
  .wallbadge { align-self: flex-start; }
  .tone-red { color: var(--red); }
  .tone-faint { color: var(--text-3); }
  .tone-green { color: var(--text-2); }
  .pad { margin: 0; padding: 4px 2px; }
  .add .select { width: 100%; }
  .main { flex: 999 1 560px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .preview { position: relative; }
  /* remote mode: the controls come first, the picture is on the projector */
  .main.remote > .form { order: -1; }
  .overlay { position: absolute; left: 0; top: 0; width: 100%; }
  .kbadges { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 8px; }
  .kbadges .switch { margin-right: 8px; }
  .pnote { margin: 4px 0 0; min-height: 2.8em; }
  .nopreview { padding: 32px; }
  .form { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .head2 { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  .fields { display: flex; flex-wrap: wrap; gap: 12px 16px; align-items: flex-end; }
  .fields .input { width: 120px; }
  .fields .select { min-width: 200px; }
  .fields .caption.grow { flex: 1 1 240px; align-self: center; }
  .row4 { display: flex; flex-wrap: wrap; gap: 8px; }
  .row4 .input { width: 90px; }
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
  /* the mode and tool groups wrap on a phone instead of cutting off their last buttons */
  .segmented.wrap { flex-wrap: wrap; }
  .masks { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .mask { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .mask .caption.grow { flex: 1 1 120px; min-width: 0; }
  .mask .input { width: 80px; }
  .mname { padding: 0 12px; font-weight: 600; }
  .field.inline { flex-direction: row; align-items: center; gap: 8px; }
  @media (max-width: 900px) {
    .list { max-width: none; }
  }
</style>
