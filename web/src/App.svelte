<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import Rail from './components/Rail.svelte';
  import Shortcuts from './components/Shortcuts.svelte';
  import StatusBar from './components/StatusBar.svelte';
  import Toast from './components/Toast.svelte';
  import { BANNER_MS } from './lib/errors';
  import { attributionText, repositoryURL } from './lib/attribution';
  import { route, startRouter } from './lib/router.svelte';
  import { app, connect } from './lib/state.svelte';
  import Layers from './screens/Layers.svelte';
  import Media from './screens/Media.svelte';
  import Outputs from './screens/Outputs.svelte';
  import Patch from './screens/Patch.svelte';
  import Show from './screens/Show.svelte';
  import System from './screens/System.svelte';

  let showMessages = $state(false);

  // The banner clears itself after 10 s; the message stays in "Recent messages".
  $effect(() => {
    const error = app.lastError;
    if (!error) return;
    const timer = setTimeout(() => {
      if (app.lastError === error) app.lastError = null;
    }, BANNER_MS);
    return () => clearTimeout(timer);
  });

  const hint = $derived(app.messages[0]?.hint ?? '');
  const time = (at: number) => new Date(at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

  onMount(() => {
    connect();
    return startRouter();
  });
</script>

<StatusBar />
<Toast />
<Shortcuts />
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
        <span><strong>{app.lastError.message}</strong>{#if hint}<br />{hint}{/if}</span>
        <span class="spacer"></span>
        <button class="btn btn-ghost" aria-expanded={showMessages} onclick={() => (showMessages = !showMessages)}>Recent messages</button>
        <button class="btn btn-ghost" onclick={() => (app.lastError = null)}>Dismiss</button>
      </div>
    {/if}
    {#if showMessages && app.messages.length > 0}
      <section class="panel messages" aria-label="Recent messages">
        <header><h2>Recent messages</h2><span class="spacer"></span><button class="btn btn-ghost" onclick={() => (showMessages = false)}>Close</button></header>
        <ul>
          {#each app.messages as m (m.id)}
            <li><span class="mono faint">{time(m.at)}</span> <strong>{m.message}</strong>{#if m.hint}<span class="muted"> · {m.hint}</span>{/if}</li>
          {/each}
        </ul>
      </section>
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
  .messages { padding: 8px 16px; }
  .messages header { display: flex; align-items: center; }
  .messages ul { list-style: none; margin: 0; padding: 0; font-size: 13px; }
  .messages li { padding: 6px 0; border-top: 1px solid var(--line); }
</style>
