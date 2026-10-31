<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { app } from '../lib/state.svelte';
  import { filterLines, formatClock } from '../lib/system';

  let text = $state('');
  let query = $state('');
  let error = $state('');
  let loading = $state(false);
  let pre: HTMLPreElement | undefined = $state();

  const visible = $derived(filterLines(text, query));

  async function load() {
    loading = true;
    error = '';
    try {
      const response = await fetch('/api/logs', { cache: 'no-store' });
      const body = await response.text();
      if (!response.ok) throw new Error(`${response.status} ${body}`.trim());
      text = body;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }
  onMount(() => {
    void load();
  });

  // follow the end of the log after every load and every filter change
  $effect(() => {
    void visible.text;
    if (pre) pre.scrollTop = pre.scrollHeight;
  });
</script>

<section class="panel" aria-labelledby="logs-title">
  <header class="phead">
    <h2 id="logs-title">Logs</h2>
    <span class="caption" aria-live="polite">{visible.shown} of {visible.total} lines · last 64 KB</span>
    <span class="spacer"></span>
    <input class="input" type="search" aria-label="Filter log lines" placeholder="Filter lines" autocomplete="off" spellcheck="false" bind:value={query} />
    <button type="button" class="btn" disabled={loading} onclick={load}>Refresh</button>
    <a class="btn" href="/api/logs?download=1" download="fanousd.log">Download</a>
  </header>
  {#if error}<p class="caption err" role="alert">Could not load the log: {error}</p>{/if}
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <pre class="log mono" bind:this={pre} tabindex="0" aria-label="Engine log">{visible.text || (loading ? 'Loading…' : text ? 'No lines match the filter.' : 'The log is empty.')}</pre>
  <dl class="service">
    <dt>Service</dt>
    <dd>
      <span class="mono">engine {app.live.engine.version || '—'}</span>
      <span class="mono">up {formatClock(app.live.engine.uptimeSeconds)}</span>
      <span class="caption">Restart and install/remove agent: shell only (later)</span>
    </dd>
  </dl>
</section>

<style>
  .phead .input { flex: 0 1 240px; min-width: 0; }
  a.btn { text-decoration: none; }
  .err { margin: 0; padding: 0 16px 8px; color: var(--yellow); }
  .log { margin: 0 16px; height: 320px; overflow: auto; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--ground); font-size: 12px; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
  .service { display: grid; grid-template-columns: minmax(96px, 30%) minmax(0, 1fr); gap: 8px 16px; margin: 0; padding: 12px 16px 16px; }
  .service dt { color: var(--text-2); font-size: 13px; font-weight: 500; }
  .service dd { margin: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 16px; }
</style>
