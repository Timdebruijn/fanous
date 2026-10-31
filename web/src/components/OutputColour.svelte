<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onDestroy } from 'svelte';
  import RangeStepper from './RangeStepper.svelte';
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
  const set = (path: string, percent: number) => throttle.send(String(output.id), path, (percent / 100) * SCALE);
</script>

<div class="colour" class:focus role="group" aria-label="Colour">
  {#each sliders as s (s.path)}
    <RangeStepper label={s.label} key="{output.id}{s.path}" value={s.value} max={s.max} step={s.step} digits={1} unit=" %" off={lock} set={(v) => set(s.path, v)} flush={throttle.flush} />
  {/each}
</div>

<style>
  .colour { display: flex; flex-direction: column; gap: 10px; border-radius: 8px; }
  .focus { outline: 2px solid var(--accent); outline-offset: 4px; }
</style>
