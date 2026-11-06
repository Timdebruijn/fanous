<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script module lang="ts">
  /** how long what was sent shows at most after the last input or release: the longest an echo is waited for */
  export const GRACE = 1000;
</script>

<script lang="ts">
  import { onDestroy, untrack } from 'svelte';

  // One −/range/+ slider for a value the engine owns (B114; the colour of an output, a wall's seams, floor and overlap).
  // From an input, a −/+ tap or a key it shows the value it sent instead of the engine's, until the engine's value
  // changes to it (the echo) or GRACE ms after the last input or release. So neither the engine's value from before the
  // sends nor the echoes of earlier sends pull it back, Undo, other clients and a refused value show again at the latest
  // when the grace ends, and −/+ step from it, so quick taps all land. Each slider keeps its own: two fingers on two
  // sliders do not disturb each other. While a pointer holds the thumb no echo ends it (a drag 100 → 88 → 97 slower
  // than a round trip meets the echo of its first 97 on the way back up, and the echo of 91 showed next: CI, 2026-11-01);
  // after the release the next echo equal to it, or the grace, ends it. Edges: a release on a value the drag passed
  // earlier (100 → 88 → 97) lets the echo of that earlier 97 end it, and the echo of 88 shows for a moment; so does any
  // echo that takes longer than the grace.
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

  let pending = $state<{ key: string; value: number } | null>(null);
  /** the pointer holding the thumb */
  let finger: number | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const v = $derived(pending?.key === key ? pending.value : value);
  const text = $derived(`${v.toFixed(digits)}${unit}`);
  // runs when the engine's value changes (a derived passes on changes only, not the parent re-rendering): changed to
  // what was sent, it is the echo
  const engine = $derived(value);
  $effect(() => {
    const now = engine;
    untrack(() => {
      if (finger === null && pending?.value.toFixed(digits) === now.toFixed(digits)) pending = null;
    });
  });
  onDestroy(() => clearTimeout(timer));

  /** (re)starts the grace; not while a pointer holds a send-on-release slider, which has sent nothing yet */
  function wait() {
    clearTimeout(timer);
    if (!onRelease || finger === null) timer = setTimeout(() => (pending = null), GRACE);
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
      onpointerdown={(e) => { if (e.button === 0) finger = e.pointerId; }} onpointerup={up} onpointercancel={up} onlostpointercapture={up} onblur={release}
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
</style>
