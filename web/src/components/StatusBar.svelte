<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd } from '../lib/state.svelte';

  const metrics = $derived(app.live.metrics);
  const fps = $derived(metrics.frames > 0 ? Math.min(999, metrics.frames) : 0);
  const dropped = $derived(metrics.missed + metrics.late);
  const universes = $derived(app.live.dmx.universes);
  const patchedUniverses = $derived(new Set(app.project.patch.map((p) => p.universe)));
  const outputsOk = $derived(app.live.engine.rendering);
  const running = $derived(app.live.ingest.filter((j) => typeof j.state === 'object' && j.state !== null && 'running' in (j.state as object)));
  const progress = $derived.by(() => {
    const job = running[0];
    if (!job) return null;
    const state = job.state as { running?: { progress?: number } };
    return Math.round((state.running?.progress ?? 0) * 100);
  });

  function universeClass(u: { active: boolean; ageSeconds: number; id: string }): string {
    if (u.active) return 'pill-green';
    // never received = not yet (yellow); lost after having received on a patched universe = look now (red)
    if (u.ageSeconds < 0) return 'pill-yellow';
    return u.ageSeconds > 2.5 && patchedUniverses.has(u.id) ? 'pill-red' : 'pill-yellow';
  }
  function universeLabel(u: { id: string; active: boolean; ageSeconds: number }): string {
    const name = u.id.replace('artnet:', 'A ').replace('sacn:', 'S ');
    if (u.active) return name;
    if (u.ageSeconds < 0) return `${name} · silent`;
    return `${name} · ${u.ageSeconds.toFixed(1)} s`;
  }
  async function toggleLock() {
    if (app.project.showLock) {
      if (confirm('Unlock the show? Configuration commands are accepted again.')) await cmd('show.unlock');
    } else {
      await cmd('show.lock');
    }
  }
</script>

<header class="status">
  <div class="item brand">
    <span class="name">Lanthorn</span>
    {#if app.project.showLock}
      <button class="tag tag-lock" onclick={toggleLock} disabled={!can('programmer')} title={can('programmer') ? 'Unlock the show' : 'Locked: programmer only'}>
        <svg aria-hidden="true" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2" /><path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg>
        SHOW LOCK
      </button>
    {:else}
      <button class="tag tag-open" onclick={toggleLock} disabled={!can('programmer')} title={can('programmer') ? 'Lock the show' : 'Locked: programmer only'}>UNLOCKED</button>
    {/if}
  </div>
  <div class="item col">
    <span class="mono value">{fps}<span class="faint"> fps </span>{metrics.gpuP99.toFixed(1)}<span class="faint"> ms</span></span>
    <span class="caption">{app.live.engine.rendering ? `gpu p99 · cpu ${metrics.cpuP99.toFixed(1)} ms` : 'no outputs rendering'}</span>
  </div>
  <div class="item col" class:red={dropped > 0 && app.project.showLock}>
    <span class="mono value">{dropped}</span>
    <span class="caption">dropped · 1 s</span>
  </div>
  <div class="item dmx">
    {#each universes as u (u.id)}
      <span class="pill {universeClass(u)}"><span class="dot"></span>{universeLabel(u)}</span>
    {:else}
      <span class="caption">no universes</span>
    {/each}
  </div>
  <div class="item col">
    <span class="mono value faint">--:--:--:--</span>
    <span class="caption">timecode · Phase 7</span>
  </div>
  <div class="item col" class:red={!outputsOk && app.project.showLock}>
    <span class="mono value"><span class="dot {outputsOk ? 'dot-green' : 'dot-off'}"></span> {outputsOk ? 'on' : 'off'}</span>
    <span class="caption">outputs</span>
  </div>
  <div class="item col ingest">
    {#if progress !== null}
      <span class="caption">ingest · {running.length} running<span class="mono"> {progress} %</span></span>
      <span class="bar"><span style="width: {progress}%"></span></span>
    {:else}
      <span class="faint">idle</span>
      <span class="caption">ingest</span>
    {/if}
  </div>
  <div class="item col">
    <span class="mono value">{app.live.clients.count}</span>
    <span class="caption" class:yellow={app.live.clients.lagging > 0}>clients{app.live.clients.lagging > 0 ? ` · ${app.live.clients.lagging} lagging` : ''}</span>
  </div>
  {#if app.live.security.webUIOpen}
    <div class="item yellow caption"><span class="dot dot-yellow"></span> web UI open</div>
  {/if}
  <span class="spacer"></span>
  <div class="item right">
    <button class="btn btn-icon" aria-label="Undo" title="Undo (⌘Z)" disabled={!can('programmer')} onclick={() => cmd('undo')}>
      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14 4 9l5-5" /><path d="M4 9h11a5 5 0 0 1 0 10H9" /></svg>
    </button>
    <button class="btn btn-icon" aria-label="Redo" title="Redo (⇧⌘Z)" disabled={!can('programmer')} onclick={() => cmd('redo')}>
      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 14 5-5-5-5" /><path d="M20 9H9a5 5 0 0 0 0 10h6" /></svg>
    </button>
    <span class="role role-{app.role}">{app.role.toUpperCase()}</span>
  </div>
</header>

<style>
  .status { display: flex; flex-wrap: wrap; align-items: center; min-height: 56px; padding: 4px 8px; background: var(--surface-1); border-bottom: 1px solid var(--line); }
  .item { display: flex; align-items: center; gap: 8px; height: var(--touch); padding: 0 12px; border-right: 1px solid var(--line); }
  .item.col { flex-direction: column; align-items: flex-start; justify-content: center; gap: 0; }
  .item.right { border-right: 0; padding-right: 4px; }
  .item.red { background: var(--red-bg); border-radius: 6px; }
  .item.red .value, .item.red .caption { color: var(--red); }
  .brand .name { font-weight: 700; letter-spacing: -0.01em; }
  .tag { border: 0; }
  .tag:disabled { opacity: 0.8; }
  .value { font-size: 15px; font-weight: 500; display: inline-flex; align-items: center; gap: 6px; }
  .dmx { gap: 6px; }
  .ingest { width: 150px; }
  .ingest .bar { width: 100%; height: 4px; margin-top: 4px; }
  .yellow { color: var(--yellow); }
</style>
