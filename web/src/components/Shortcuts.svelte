<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { screens } from '../lib/router.svelte';
  import { shell } from '../lib/state.svelte';

  let dialog: HTMLDialogElement | undefined = $state();

  $effect(() => {
    if (shell.help && dialog && !dialog.open) dialog.showModal();
    if (!shell.help && dialog?.open) dialog.close();
  });

  const keys: [string, string][] = [
    ...screens.map((s) => [s.key, `Go to ${s.label}`] as [string, string]),
    ['L', 'Lock or unlock the show (programmer)'],
    ['⌘Z', 'Undo (programmer)'],
    ['⇧⌘Z', 'Redo (programmer)'],
    ['Space', 'Go: fire the next cue (Show screen)'],
    ['?', 'This list'],
  ];
</script>

<dialog bind:this={dialog} class="panel" onclose={() => (shell.help = false)} aria-labelledby="keys-title">
  <h2 id="keys-title">Keyboard shortcuts</h2>
  <dl>
    {#each keys as [key, text] (key)}
      <dt><kbd>{key}</kbd></dt>
      <dd>{text}</dd>
    {/each}
  </dl>
  <p class="caption">Shortcuts are ignored while you type in a field or a dialog is open. On an iPad use the buttons on screen.</p>
  <div class="actions"><button type="button" class="btn btn-primary" onclick={() => (shell.help = false)}>Close</button></div>
</dialog>

<style>
  dialog { width: min(420px, calc(100vw - 32px)); padding: 24px; color: var(--text-1); border: 1px solid var(--line-strong); }
  dialog::backdrop { background: rgba(11, 12, 14, 0.7); }
  dl { display: grid; grid-template-columns: 72px 1fr; gap: 8px 12px; margin: 16px 0; align-items: center; }
  dt, dd { margin: 0; }
  kbd { display: inline-flex; align-items: center; justify-content: center; min-width: 36px; height: 30px; padding: 0 8px; border-radius: 6px; border: 1px solid var(--line-strong); background: var(--surface-2); font: 600 13px var(--font-mono); }
  .actions { display: flex; justify-content: flex-end; }
</style>
