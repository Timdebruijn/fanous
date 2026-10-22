<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { attributionText, repositoryURL } from './lib/attribution';
  import { formatUptime, parseHealth, type Health } from './lib/health';

  let health = $state<Health | null>(null);
  let error = $state<string | null>(null);

  async function poll() {
    try {
      const response = await fetch('/healthz', { cache: 'no-store' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      health = parseHealth(await response.json());
      error = null;
    } catch (e) {
      health = null;
      error = e instanceof Error ? e.message : String(e);
    }
  }

  onMount(() => {
    void poll();
    const timer = setInterval(() => void poll(), 2000);
    return () => clearInterval(timer);
  });
</script>

<header class="status" class:red={error !== null}>
  <span class="dot"></span>
  {#if health}
    <span>engine {health.version}</span>
    <span>{health.chip}</span>
    <span>up {formatUptime(health.uptimeSeconds)}</span>
  {:else}
    <span>engine unreachable{error ? `: ${error}` : ''}</span>
  {/if}
</header>

<main>
  <h1>Lanthorn</h1>
  <p>Phase 0 skeleton. The engine is serving this page over HTTPS; the screens arrive in Phase 5.</p>
</main>

<footer>
  {attributionText.replace(repositoryURL, '')}<a href={repositoryURL}>{repositoryURL}</a>
</footer>
