<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { clamp01, handles, outlines, type MapPoint, type MapperMode, type OutputConfig } from '../lib/outputs';
  import { fromScreen, toScreen, warpedOutline } from '../lib/warp';

  // Handles over the output preview (DESIGN.md §12.3): corner pin, mesh points, slice quads or a mask path.
  // Pointer Events everywhere, 44 px hit targets, arrow keys nudge the selection by one output pixel (Shift: ten),
  // Tab / Shift+Tab step to the next / previous point, Escape lets go (so Tab leaves the editor again). Drags go out
  // as (JSON pointer, point) at most every 120 ms and on release.
  // Slice, mask and mesh points are stored before the warp but the preview shows the warped picture, so handles are
  // drawn through the warp (lib/warp.ts) and the pointer is mapped back through its inverse.
  let {
    output,
    mode,
    sliceIndex,
    size,
    selected = $bindable(null),
    marked = [],
    onchange,
    onnudge,
    onstep,
    addMode = false,
    draft = null,
    onadd,
    onremove,
  }: {
    output: OutputConfig;
    mode: MapperMode;
    sliceIndex: number;
    /** output size in pixels: nudge steps and the aspect ratio of the overlay */
    size: { w: number; h: number };
    selected: string | null;
    /** further selected points (a row, an edge…), drawn like the selected one */
    marked?: string[];
    onchange: (path: string, point: MapPoint) => void;
    /** arrow keys, in output pixels: the screen moves the selection */
    onnudge: (dx: number, dy: number) => void;
    /** Tab (+1) and Shift+Tab (−1) */
    onstep: (dir: 1 | -1) => void;
    /** mask mode: taps on the picture add points (stored, pre-warp coordinates); double-click always does */
    addMode?: boolean;
    /** a mask being drawn corner by corner, before it has three points */
    draft?: MapPoint[] | null;
    onadd?: (point: MapPoint) => void;
    onremove?: (path: string) => void;
  } = $props();

  const W = 1000;
  const H = $derived(Math.round((W * size.h) / size.w));
  const points = $derived(handles(output, mode, sliceIndex));
  const markedSet = $derived(new Set(marked));
  const lines = $derived(
    outlines(output, mode, sliceIndex).map((line) => ({
      group: line.group,
      closed: mode !== 'mesh',
      points: mode === 'mesh' ? line.points.map((p) => toScreen(output, mode, p)) : warpedOutline(output, mode, line.points, true),
    })),
  );
  /** while dragging, the handle follows the pointer before the engine echoes the patch */
  let dragging = $state<{ path: string; point: MapPoint } | null>(null);
  let svg: SVGSVGElement | undefined = $state();
  let lastSent = 0;

  function shown(h: { path: string; point: MapPoint }): MapPoint {
    return toScreen(output, mode, dragging?.path === h.path ? dragging.point : h.point);
  }

  function toPoint(event: PointerEvent): MapPoint {
    const rect = svg!.getBoundingClientRect();
    const onScreen = { x: clamp01((event.clientX - rect.left) / rect.width), y: clamp01((event.clientY - rect.top) / rect.height) };
    const p = fromScreen(output, mode, onScreen);
    return { x: clamp01(p.x), y: clamp01(p.y) };
  }

  function down(event: PointerEvent, path: string) {
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
    selected = path;
    dragging = { path, point: toPoint(event) };
  }

  function move(event: PointerEvent) {
    if (!dragging) return;
    dragging = { path: dragging.path, point: toPoint(event) };
    const now = performance.now();
    if (now - lastSent > 120) {
      lastSent = now;
      onchange(dragging.path, dragging.point);
    }
  }

  function up(event: PointerEvent) {
    if (!dragging) return;
    const final = { path: dragging.path, point: toPoint(event) };
    dragging = null;
    onchange(final.path, final.point);
  }

  /** a tap on the picture itself (not on a handle) */
  function background(event: PointerEvent) {
    if ((event.target as Element).closest('.handle') || mode !== 'mask' || !onadd) return;
    if (!(addMode || draft)) return;
    event.preventDefault();
    onadd(fromScreen(output, mode, toPoint(event)));
  }

  function doubleClick(event: MouseEvent) {
    if ((event.target as Element).closest('.handle') || mode !== 'mask' || !onadd || draft) return;
    const rect = svg!.getBoundingClientRect();
    const p = { x: clamp01((event.clientX - rect.left) / rect.width), y: clamp01((event.clientY - rect.top) / rect.height) };
    onadd(fromScreen(output, mode, p));
  }

  function key(event: KeyboardEvent) {
    if ((event.key === 'Backspace' || event.key === 'Delete') && selected && mode === 'mask' && onremove) {
      event.preventDefault();
      onremove(selected);
      return;
    }
    if (!selected || !points.some((h) => h.path === selected)) return;
    if (event.key === 'Tab' || event.key === 'Escape') {
      event.preventDefault();
      if (event.key === 'Tab') onstep(event.shiftKey ? -1 : 1);
      else selected = null;
      return;
    }
    const step = event.shiftKey ? 10 : 1;
    const delta: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    const d = delta[event.key];
    if (!d) return;
    event.preventDefault();
    onnudge(d[0], d[1]);
  }

  const colours = ['#4C9EFF', '#35D07F', '#FFC532', '#FF5A5F', '#A3AAB4'];
</script>

<!-- role="application" is the ARIA role for a focusable widget that handles its own keys; Svelte counts it as non-interactive -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
<svg bind:this={svg} class="mapper" viewBox="0 0 {W} {H}" role="application" aria-label="Mapping editor: drag the handles, arrow keys nudge the selected point, Tab steps to the next one, Escape lets go so Tab leaves" tabindex="0" class:adding={mode === 'mask' && (addMode || draft)} onkeydown={key} onpointerdown={background} ondblclick={doubleClick} onpointermove={move} onpointerup={up} onpointercancel={up}>
  {#if draft && draft.length > 0}
    {@const pts = draft.map((p) => toScreen(output, mode, p))}
    <polyline points={pts.map((p) => `${p.x * W},${p.y * H}`).join(' ')} fill="none" stroke="#FFC532" stroke-width="2" stroke-dasharray="6 4" vector-effect="non-scaling-stroke" />
    {#each pts as p, i (i)}<circle cx={p.x * W} cy={p.y * H} r="10" fill="#FFC532" stroke="#0B0C0E" stroke-width="3" vector-effect="non-scaling-stroke" />{/each}
  {/if}
  {#each lines as line, i (i)}
    <polyline
      points={line.points.map((p) => `${p.x * W},${p.y * H}`).join(' ') + (line.closed ? ` ${line.points[0]!.x * W},${line.points[0]!.y * H}` : '')}
      fill={mode === 'mask' ? 'rgba(76,158,255,0.12)' : 'none'}
      stroke={colours[line.group % colours.length]}
      stroke-width="2"
      vector-effect="non-scaling-stroke"
      opacity={mode === 'mesh' ? 0.5 : 0.9}
    />
  {/each}
  {#each points as h (h.path)}
    {@const p = shown(h)}
    {@const sel = selected === h.path || markedSet.has(h.path)}
    <g class="handle" class:sel onpointerdown={(e) => down(e, h.path)} role="button" aria-label={h.path} tabindex="-1">
      <circle cx={p.x * W} cy={p.y * H} r="36" fill="transparent" />
      <circle cx={p.x * W} cy={p.y * H} r={mode === 'mesh' ? 9 : 12} fill={sel ? '#ECEEF1' : colours[h.group % colours.length]} stroke="#0B0C0E" stroke-width="3" vector-effect="non-scaling-stroke" />
    </g>
  {/each}
</svg>

<style>
  .mapper { position: absolute; inset: 0; width: 100%; height: 100%; touch-action: none; outline: none; cursor: default; }
  .mapper:focus-visible { outline: 2px solid var(--accent); }
  .mapper.adding { cursor: crosshair; }
  .handle { cursor: grab; }
  .handle:active { cursor: grabbing; }
  .handle.sel circle:last-child { stroke: var(--accent); }
</style>
