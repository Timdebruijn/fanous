<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  // On-screen arrow keys for the selected mapper point (no keyboard on an iPad). "10 px" is the Shift of the keyboard;
  // holding an arrow for half a second moves a quarter pixel instead (DESIGN §9.9). `--cell` sets the key size.
  let { onnudge, disabled = false }: { onnudge: (dx: number, dy: number) => void; disabled?: boolean } = $props();

  const HOLD_MS = 500;
  let big = $state(false);
  const step = $derived(big ? 10 : 1);
  let timer: ReturnType<typeof setTimeout> | undefined;
  /** the press became a long press: its click is not a step */
  let held = false;

  function press(dx: number, dy: number) {
    held = false;
    clearTimeout(timer);
    timer = setTimeout(() => {
      held = true;
      onnudge(dx * 0.25, dy * 0.25);
    }, HOLD_MS);
  }
  function release() {
    clearTimeout(timer);
  }
  function click(dx: number, dy: number) {
    if (held) held = false;
    else onnudge(dx * step, dy * step);
  }
</script>

{#snippet arrow(cls: string, name: string, glyph: string, dx: number, dy: number)}
  <button type="button" class="btn btn-icon {cls}" aria-label="{name} {step} px" title="Hold for 0.25 px" {disabled}
    onpointerdown={() => press(dx, dy)} onpointerup={release} onpointerleave={release} onpointercancel={release}
    oncontextmenu={(e) => e.preventDefault()} onclick={() => click(dx, dy)}>{glyph}</button>
{/snippet}

<div class="pad" role="group" aria-label="Nudge the selected point">
  {@render arrow('up', 'Up', '↑', 0, -1)}
  {@render arrow('left', 'Left', '←', -1, 0)}
  <button type="button" class="btn mid" aria-pressed={big} {disabled} title="Move 10 px per press instead of 1 (like Shift)" onclick={() => (big = !big)}>10 px</button>
  {@render arrow('right', 'Right', '→', 1, 0)}
  {@render arrow('down', 'Down', '↓', 0, 1)}
</div>

<style>
  .pad { --size: var(--cell, var(--touch)); display: grid; grid-template-columns: repeat(3, var(--size)); grid-template-rows: repeat(3, var(--size)); gap: 4px; }
  /* a long press must not select text or open the callout on iOS, nor zoom on a double tap */
  .pad .btn { width: var(--size); height: var(--size); touch-action: manipulation; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  .pad .btn-icon { font-size: calc(var(--size) * 0.4); }
  .up { grid-area: 1 / 2; }
  .left { grid-area: 2 / 1; }
  .mid { grid-area: 2 / 2; padding: 0; font-size: 12px; font-family: var(--font-mono); }
  .right { grid-area: 2 / 3; }
  .down { grid-area: 3 / 2; }
</style>
