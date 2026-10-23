<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, authHeaders, can } from '../lib/state.svelte';
  import { LOCKED_TITLE, basename, describeCodec, describeJobState, isActive, orderJobs, pathTail, queueSummary, send } from '../lib/media';

  let { onfail }: { onfail: (message: string) => void } = $props();

  const jobs = $derived(orderJobs(app.live.ingest));
  const summary = $derived(queueSummary(app.live.ingest));
  const locked = $derived(!can('programmer'));

  async function act(id: string, action: 'cancel' | 'remove') {
    const error = await send(`/api/ingest/${encodeURIComponent(id)}/${action}`, { method: 'POST', headers: authHeaders() });
    if (error) onfail(`Could not ${action} the job: ${error}`);
  }
</script>

<section class="panel queue" aria-labelledby="queue-title">
  <header class="toolbar">
    <div>
      <h2 id="queue-title">Ingest queue</h2>
      <div class="caption">{summary.running} running · {summary.queued} queued · yields when the show needs the CPU</div>
    </div>
    <span class="spacer"></span>
    <!-- IngestQueue has `paused`, but IngestAPI has no pause route yet -->
    <button class="btn" disabled title="Not wired yet">Pause all</button>
  </header>
  {#if jobs.length === 0}
    <p class="caption empty">Nothing queued. Import a file or transcode one from the library.</p>
  {:else}
    <ul>
      {#each jobs as job (job.id)}
        {@const state = describeJobState(job.state)}
        {@const percent = Math.round(state.progress * 100)}
        <li class="job">
          <div class="who">
            <div class="ellipsis" title={job.source}>{basename(job.source)}</div>
            <div class="caption mono ellipsis" title={job.destination}>{pathTail(job.destination)}</div>
          </div>
          <span class="badge badge-outline">{describeCodec(job.kind)}</span>
          <span class="state" class:run={state.label === 'transcoding'} class:fail={state.label === 'failed'}>
            {state.label}{#if state.label === 'transcoding'}<span class="mono pct">{percent}%</span>{/if}
          </span>
          <span class="bar" role="progressbar" aria-label="Progress of {basename(job.source)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow={percent}>
            <span style:width="{percent}%"></span>
          </span>
          {#if isActive(state.label)}
            <button class="btn" disabled={locked} title={locked ? LOCKED_TITLE : undefined} onclick={() => act(job.id, 'cancel')}>Cancel</button>
          {:else}
            <button class="btn" disabled={locked} title={locked ? LOCKED_TITLE : undefined} onclick={() => act(job.id, 'remove')}>Remove</button>
          {/if}
          {#if state.error}<div class="error">{state.error}</div>{/if}
        </li>
      {/each}
    </ul>
  {/if}
</section>

<style>
  .queue > header { padding: 12px 16px; }
  ul { list-style: none; margin: 0; padding: 0; }
  .empty { margin: 0; padding: 12px 16px 16px; }
  .job { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; padding: 8px 16px; border-top: 1px solid var(--line); }
  .who { flex: 1 1 220px; min-width: 0; }
  .state { flex: 0 0 120px; color: var(--text-2); }
  .state.run { color: var(--accent); }
  .pct { margin-left: 6px; }
  .state.fail { color: var(--red); font-weight: 600; }
  .bar { flex: 0 0 140px; }
  .error { flex-basis: 100%; color: var(--red); font-size: 13px; overflow-wrap: anywhere; user-select: text; }
</style>
