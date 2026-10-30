<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onDestroy } from 'svelte';

  // One −/range/+ slider for a value the engine owns (B114; the colour of an output, a wall's seams, floor and overlap).
  // What it sent shows instead of the engine's value while a finger holds the thumb, and after a release, a −/+ tap or
  // a key until the engine's value shows the same, at most GRACE ms: the echoes of earlier sends do not pull it back,
  // and Undo, other clients or a refused value show again after that. −/+ step from that value, so quick taps all land.
  // Each slider keeps its own, so two fingers on two sliders do not disturb each other.
  let {
    label,
    key,
    value,
    min = 0,
    max,
    step,
    digits,
    unit = '',
    off,
    focus = false,
    onRelease = false,
    set,
    flush,
  }: {
    label: string;
    /** what the value belongs to ("1/color/gain/0"): what was sent for one never shows on another */
    key: string;
    value: number;
    min?: number;
    max: number;
    step: number;
    digits: number;
    unit?: string;
    /** why it cannot change (role, show lock, ...): disabled, with this as the title */
    off?: string | null;
    focus?: boolean;
    /** send on release only (a geometry change re-computes the wall; one undo step each) */
    onRelease?: boolean;
    set: (v: number) => void;
    /** sends what is still queued, on release */
    flush?: () => void;
  } = $props();

  const GRACE = 1000;
  let pending = $state<{ key: string; value: number } | null>(null);
  /** the pointer holding the thumb */
  let finger = $state<number | null>(null);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const v = $derived(pending?.key === key ? pending.value : value);
  const text = $derived(`${v.toFixed(digits)}${unit}`);
  // the engine caught up with what was sent
  $effect(() => {
    if (pending && finger === null && pending.value.toFixed(digits) === value.toFixed(digits)) pending = null;
  });
  onDestroy(() => clearTimeout(timer));

  /** the grace runs while no finger holds the thumb */
  function wait() {
    clearTimeout(timer);
    if (finger === null) timer = setTimeout(() => (pending = null), GRACE);
  }
  function hold(n: number) {
    pending = { key, value: n };
    wait();
  }
  function release() {
    finger = null;
    wait();
  }
  const up = (e: PointerEvent) => e.pointerId === finger && release();
  function nudge(by: number) {
    const n = Math.min(max, Math.max(min, Number((v + by).toFixed(digits))));
    hold(n);
    set(n);
  }
</script>

<div class="slider" class:focus>
  <span class="label">{label}</span>
  <span class="line">
    <button type="button" class="btn btn-icon" aria-label="{label} down" title={off} disabled={!!off || v <= min} onclick={() => nudge(-step)}>−</button>
    <input type="range" {min} {max} {step} aria-label={label} aria-valuetext={text} title={off} disabled={!!off} value={v}
      onpointerdown={(e) => (finger = e.pointerId)} onpointerup={up} onpointercancel={up} onlostpointercapture={up} onblur={release}
      oninput={(e) => { const n = Number(e.currentTarget.value); hold(n); if (!onRelease) set(n); }}
      onchange={(e) => { if (onRelease) set(Number(e.currentTarget.value)); else flush?.(); release(); }} />
    <button type="button" class="btn btn-icon" aria-label="{label} up" title={off} disabled={!!off || v >= max} onclick={() => nudge(step)}>+</button>
    <span class="mono val" aria-label="{label} value">{text}</span>
  </span>
</div>

<style>
  .slider { display: flex; flex-direction: column; gap: 4px; border-radius: 8px; }
  .line { display: flex; align-items: center; gap: 8px; }
  .line input { flex: 1; min-width: 0; min-height: var(--touch); accent-color: var(--accent); }
  .val { min-width: 64px; text-align: right; }
  .focus { outline: 2px solid var(--accent); outline-offset: 4px; }
</style>
