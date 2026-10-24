<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import Rail from './components/Rail.svelte';
  import StatusBar from './components/StatusBar.svelte';
  import { attributionText, repositoryURL } from './lib/attribution';
  import { route, startRouter } from './lib/router.svelte';
  import { app, connect } from './lib/state.svelte';
  import Layers from './screens/Layers.svelte';
  import Media from './screens/Media.svelte';
  import Outputs from './screens/Outputs.svelte';
  import Patch from './screens/Patch.svelte';
  import Show from './screens/Show.svelte';
  import System from './screens/System.svelte';

  onMount(() => {
    connect();
    return startRouter();
  });
</script>

<StatusBar />
<div class="body">
  <Rail />
  <main>
    {#if app.connection !== 'open' && app.rev === 0}
      <div class="banner banner-yellow" role="status">
        <span class="dot dot-yellow"></span>
        <span>{app.connection === 'connecting' ? 'Connecting to the engine…' : `Engine unreachable${app.detail ? `: ${app.detail}` : ''}; retrying`}</span>
      </div>
    {:else if app.connection === 'closed'}
      <div class="banner banner-red" role="alert">
        <span class="dot dot-red"></span>
        <span><strong>Connection lost</strong> · {app.detail || 'reconnecting'} · values shown are stale</span>
      </div>
    {/if}
    {#if app.lastError}
      <div class="banner banner-yellow" role="alert">
        <span class="dot dot-yellow"></span>
        <span><strong>{app.lastError.code}</strong> · {app.lastError.message}</span>
        <span class="spacer"></span>
        <button class="btn btn-ghost" onclick={() => (app.lastError = null)}>Dismiss</button>
      </div>
    {/if}
    {#if route.screen === 'layers'}
      <Layers />
    {:else if route.screen === 'media'}
      <Media />
    {:else if route.screen === 'patch'}
      <Patch />
    {:else if route.screen === 'outputs'}
      <Outputs />
    {:else if route.screen === 'show'}
      <Show />
    {:else}
      <System />
    {/if}
    <footer>
      {attributionText.replace(repositoryURL, '')}<a href={repositoryURL}>{repositoryURL}</a>
    </footer>
  </main>
</div>

<style>
  .body { display: flex; flex-wrap: wrap; flex: 1; align-items: stretch; }
  main { flex: 999 1 560px; min-width: 0; display: flex; flex-direction: column; gap: 12px; padding: 16px; }
  footer { margin-top: auto; padding-top: 16px; color: var(--text-3); font-size: 12px; }
  footer a { color: inherit; }
</style>
