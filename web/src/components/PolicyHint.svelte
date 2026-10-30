<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { policyName } from '../lib/layers';
  import { app, can, cmd } from '../lib/state.svelte';

  // Shown wherever the UI sets layer values: with Who controls "Console only" they are kept but have no effect.
  let { what = 'values set here' }: { what?: string } = $props();

  const lock = $derived(!can('programmer') ? 'Locked: programmer only' : app.project.showLock ? 'Locked: show lock is on' : undefined);
</script>

{#if app.project.policy === 'dmx'}
  <div class="banner banner-yellow hint" role="status">
    <span class="dot dot-yellow"></span>
    <span class="text">Who controls: <strong>{policyName('dmx')}</strong>, so {what} are kept but not shown on the layer.</span>
    <button type="button" class="btn" disabled={lock !== undefined} title={lock} onclick={() => void cmd('project.set', { path: '/policy', value: 'ltp' })}>Use {policyName('ltp')}</button>
  </div>
{/if}

<style>
  /* on a phone the long button goes to its own line and may wrap; the text keeps the line next to the dot */
  .hint { flex-wrap: wrap; }
  .text { flex: 1 1 200px; }
  .hint .btn { max-width: 100%; white-space: normal; text-align: center; }
</style>
