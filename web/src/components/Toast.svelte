<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { can, cmd, dismissToast, shell } from '../lib/state.svelte';

  async function undo() {
    dismissToast();
    await cmd('undo');
  }
</script>

{#if shell.toast}
  <div class="toast" role="status" aria-live="polite">
    <span>{shell.toast.text}</span>
    <button type="button" class="btn" disabled={!can('programmer')} onclick={undo}>Undone? — Undo</button>
    <button type="button" class="btn btn-ghost btn-icon" aria-label="Dismiss" onclick={dismissToast}>×</button>
  </div>
{/if}

<style>
  .toast { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); z-index: 50; display: flex; align-items: center; gap: 8px; max-width: calc(100vw - 32px); padding: 6px 6px 6px 16px; background: var(--surface-3); border: 1px solid var(--line-strong); border-radius: var(--radius-panel); box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5); }
</style>
