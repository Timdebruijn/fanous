<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app } from '../lib/state.svelte';
  import { metricTiles, parseMetrics, pushHistory, sparkline, type Metrics } from '../lib/system';

  const W = 240;
  const H = 48;
  const POLL_MS = 2000;

  let metrics = $state.raw<Metrics | null>(null);
  let history = $state.raw<number[]>([]);
  let error = $state('');

  // GET /metrics every 2 s while this component is mounted and the tab is visible (a hidden tab stops polling and polls
  // once when it shows again); a poll that is still running is not stacked.
  $effect(() => {
    let alive = true;
    let busy = false;
    async function poll() {
      if (busy) return;
      busy = true;
      try {
        const response = await fetch('/metrics', { cache: 'no-store', signal: AbortSignal.timeout(POLL_MS - 200) });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const next = parseMetrics(await response.json());
        if (!alive) return;
        metrics = next;
        history = pushHistory(history, next.gpuMsP99);
        error = '';
      } catch (e) {
        if (alive) error = e instanceof Error ? e.message : String(e);
      } finally {
        busy = false;
      }
    }
    let timer: ReturnType<typeof setInterval> | undefined;
    const run = () => {
      if (timer !== undefined) return;
      void poll();
      timer = setInterval(poll, POLL_MS);
    };
    const pause = () => {
      clearInterval(timer);
      timer = undefined;
    };
    const onVisibility = () => (document.hidden ? pause() : run());
    document.addEventListener('visibilitychange', onVisibility);
    if (!document.hidden) run();
    return () => {
      alive = false;
      pause();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  });

  const tiles = $derived(metricTiles(metrics, app.live.show.mode));
  const budget = $derived(typeof app.caps.fps === 'number' && app.caps.fps > 0 ? 1000 / app.caps.fps : 0);
  const trace = $derived(sparkline(history, W, H, budget));
  const latest = $derived(history.at(-1));
</script>

<section class="panel" aria-labelledby="metrics-title">
  <header class="phead">
    <h2 id="metrics-title">Live metrics</h2>
    <span class="caption">1 s window, refreshed every 2 s</span>
    <span class="spacer"></span>
    {#if error}<span class="badge badge-warn" role="status">metrics unavailable: {error}</span>{/if}
  </header>
  <div class="tiles">
    {#each tiles as t (t.id)}
      <div class="tile">
        <span class="num mono tone-{t.tone}">{t.value}</span>
        <span class="caption">{t.caption}</span>
        {#if t.note}<span class="caption">{t.note}</span>{/if}
      </div>
    {/each}
  </div>
  <figure class="spark">
    <svg viewBox="0 0 {W} {H}" preserveAspectRatio="none" role="img" aria-label="GPU p99 frame time over the last {history.length} polls{latest === undefined ? '' : `, now ${latest.toFixed(1)} ms`}">
      {#if trace.refY !== null}<line class="ref" x1="0" x2={W} y1={trace.refY} y2={trace.refY} />{/if}
      {#if trace.points}<polyline class="trace" points={trace.points} />{/if}
    </svg>
    <figcaption class="caption">GPU p99 per poll, last {history.length} of 60{budget ? `; dashed line is the ${budget.toFixed(1)} ms frame budget` : ''}</figcaption>
  </figure>
</section>

<style>
  .phead { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; padding: 12px 16px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 200px), 1fr)); gap: 8px; padding: 0 16px 12px; }
  .tile { display: flex; flex-direction: column; gap: 2px; min-width: 0; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-2); }
  .num { font-size: 18px; font-weight: 600; overflow-wrap: anywhere; }
  .tone-red { color: var(--red); }
  .tone-yellow { color: var(--yellow); }
  .spark { margin: 0; padding: 0 16px 16px; display: flex; flex-direction: column; gap: 6px; }
  .spark svg { display: block; width: 100%; height: 48px; border-radius: 4px; background: var(--surface-2); }
  .trace { fill: none; stroke: var(--accent); stroke-width: 2; stroke-linejoin: round; vector-effect: non-scaling-stroke; }
  .ref { stroke: var(--line-strong); stroke-width: 1; stroke-dasharray: 4 4; vector-effect: non-scaling-stroke; }
</style>
