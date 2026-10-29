<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onDestroy } from 'svelte';
  import { colorOf, type OutputConfig } from '../lib/outputs';
  import { lockTitle } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';
  import { throttledSender } from '../lib/throttle';

  // Per-output colour (DESIGN §9.9): gain R, G, B and the black offset of one output, tuned by eye. On the Outputs tab
  // and on a wall's projector tile. A slider sends at most every 50 ms, to the output it was set for (B80); the engine
  // keeps a drag on one value as one undo step (output.set merges the same path within 1 s).
  let { output, focus = false }: { output: OutputConfig; focus?: boolean } = $props();

  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const color = $derived(colorOf(output));
  // throttledSender rounds to whole numbers: values go × SCALE
  const SCALE = 10000;
  const throttle = throttledSender((id, path, raw) => void cmd('output.set', { id: Number(id), path, value: raw / SCALE }));
  onDestroy(throttle.flush);
  const sliders = $derived([
    ...(['R', 'G', 'B'] as const).map((ch, i) => ({ label: `Gain ${ch}`, path: `/color/gain/${i}`, value: color.gain[i]! * 100, max: 200, step: 0.5 })),
    { label: 'Black offset', path: '/color/black', value: color.black * 100, max: 20, step: 0.1 },
  ]);
  /** the value under a finger while a slider moves: patches of the values sent before it do not pull it back */
  let drag = $state<{ key: string; value: number } | null>(null);
  const set = (path: string, percent: number) => throttle.send(String(output.id), path, (percent / 100) * SCALE);
  const stepped = (max: number, v: number) => Math.min(max, Math.max(0, Number(v.toFixed(1))));
</script>

<div class="colour" class:focus role="group" aria-label="Colour">
  {#each sliders as s (s.path)}
    {@const key = `${output.id}${s.path}`}
    {@const v = drag?.key === key ? drag.value : s.value}
    <div class="slider">
      <span class="label">{s.label}</span>
      <span class="line">
        <button type="button" class="btn btn-icon" aria-label="{s.label} down" title={lock} disabled={!!lock || v <= 0} onclick={() => set(s.path, stepped(s.max, v - s.step))}>−</button>
        <input type="range" min="0" max={s.max} step={s.step} aria-label={s.label} aria-valuetext="{v.toFixed(1)} %" title={lock} disabled={!!lock} value={v}
          oninput={(e) => { const n = Number(e.currentTarget.value); drag = { key, value: n }; set(s.path, n); }}
          onchange={() => { throttle.flush(); drag = null; }} />
        <button type="button" class="btn btn-icon" aria-label="{s.label} up" title={lock} disabled={!!lock || v >= s.max} onclick={() => set(s.path, stepped(s.max, v + s.step))}>+</button>
        <span class="mono val" aria-label="{s.label} value">{v.toFixed(1)} %</span>
      </span>
    </div>
  {/each}
</div>

<style>
  .colour { display: flex; flex-direction: column; gap: 10px; border-radius: 8px; }
  .slider { display: flex; flex-direction: column; gap: 4px; }
  .line { display: flex; align-items: center; gap: 8px; }
  .line input { flex: 1; min-width: 0; min-height: var(--touch); accent-color: var(--accent); }
  .val { min-width: 64px; text-align: right; }
  .focus { outline: 2px solid var(--accent); outline-offset: 4px; }
</style>
