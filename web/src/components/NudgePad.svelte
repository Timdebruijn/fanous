<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  // On-screen arrow keys for the selected mapper point (no keyboard on an iPad). "10 px" is the Shift of the keyboard.
  let { onnudge, disabled = false }: { onnudge: (dx: number, dy: number) => void; disabled?: boolean } = $props();

  let big = $state(false);
  const step = $derived(big ? 10 : 1);
</script>

<div class="pad" role="group" aria-label="Nudge the selected point">
  <button type="button" class="btn btn-icon up" aria-label="Up {step} px" {disabled} onclick={() => onnudge(0, -step)}>↑</button>
  <button type="button" class="btn btn-icon left" aria-label="Left {step} px" {disabled} onclick={() => onnudge(-step, 0)}>←</button>
  <button type="button" class="btn mid" aria-pressed={big} {disabled} title="Move 10 px per press instead of 1 (like Shift)" onclick={() => (big = !big)}>10 px</button>
  <button type="button" class="btn btn-icon right" aria-label="Right {step} px" {disabled} onclick={() => onnudge(step, 0)}>→</button>
  <button type="button" class="btn btn-icon down" aria-label="Down {step} px" {disabled} onclick={() => onnudge(0, step)}>↓</button>
</div>

<style>
  .pad { display: grid; grid-template-columns: repeat(3, var(--touch)); grid-template-rows: repeat(3, var(--touch)); gap: 4px; }
  .up { grid-area: 1 / 2; }
  .left { grid-area: 2 / 1; }
  .mid { grid-area: 2 / 2; padding: 0; font-size: 12px; font-family: var(--font-mono); }
  .right { grid-area: 2 / 3; }
  .down { grid-area: 3 / 2; }
</style>
