<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import Login from './Login.svelte';
  import { readinessSummary, resumedText } from '../lib/system';
  import { lastVersionText } from '../lib/versions';
  import { app, can, cmd, shell, toggleLock } from '../lib/state.svelte';

  let showLogin = $state(false);

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
  const showMode = $derived(app.live.show.mode);
  const syncLost = $derived(app.live.layers.filter((l) => l.sync?.state === 'lost').map((l) => `Layer ${l.index}`));
  const resumed = $derived(resumedText(app.live.show.resumedAt));
  const blocking = $derived(readinessSummary(app.live.show.readiness, app.live.show.checkedAt).blocking);
  /** set when entering show mode was refused: the popover under the button says why */
  let refused = $state<string | null>(null);
  async function toggleShowMode() {
    const on = !showMode;
    refused = null;
    if ((await cmd('show.mode', { on })) === undefined && on) refused = app.lastError?.message ?? 'Show mode could not be entered.';
  }
  $effect(() => {
    if (showMode) refused = null;
  });
</script>

<header class="status">
  <div class="item brand">
    <span class="name">Fanous</span>
    <button type="button" class="tag {app.project.showLock ? 'tag-lock' : 'tag-open'}" aria-pressed={app.project.showLock} onclick={toggleLock} disabled={!can('programmer')} title={can('programmer') ? (app.project.showLock ? 'Unlock the show (L)' : 'Lock the show: configuration is refused (L)') : 'Programmer only'}>
      {#if app.project.showLock}<svg aria-hidden="true" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2" /><path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg>{/if}
      {app.project.showLock ? 'LOCKED' : 'UNLOCKED'}
    </button>
    <span class="modewrap">
      <button type="button" class="tag {showMode ? 'tag-mode' : 'tag-open'}" aria-pressed={showMode} aria-expanded={refused !== null} onclick={toggleShowMode} disabled={!can('operator')} title={can('operator') ? (showMode ? 'Leave show mode' : 'Enter show mode: runs the readiness checks first') : 'Operator or programmer only'}>
        SHOW MODE: {showMode ? 'ON' : 'OFF'}
      </button>
      <span role="status">{#if showMode && resumed}<a class="caption resumed" href="#/system">{resumed}</a>{/if}</span>
      {#if refused !== null}
        <div class="pop panel" role="alert">
          <strong>Cannot enter show mode</strong>
          {#if blocking.length > 0}
            <ul>{#each blocking as item (item.id)}<li>{item.title}{#if item.fix}<span class="caption"> — {item.fix}</span>{/if}</li>{/each}</ul>
          {:else}
            <p class="caption">{refused}</p>
          {/if}
          <div class="popactions">
            <a class="btn btn-primary" href="#/system" onclick={() => (refused = null)}>Open System</a>
            <button type="button" class="btn" onclick={() => (refused = null)}>Close</button>
          </div>
        </div>
      {/if}
    </span>
  </div>
  <div class="item col">
    <span class="mono value">{fps}<span class="faint"> fps </span>{metrics.gpuP99.toFixed(1)}<span class="faint"> ms</span></span>
    <span class="caption">{app.live.engine.rendering ? `gpu p99 · cpu ${metrics.cpuP99.toFixed(1)} ms` : 'no outputs rendering: add or assign one (Outputs)'}</span>
  </div>
  <div class="item col" class:red={dropped > 0 && app.project.showLock}>
    <span class="mono value">{dropped}</span>
    <span class="caption">dropped · 1 s</span>
  </div>
  <div class="item dmx">
    {#each universes as u (u.id)}
      <span class="pill {universeClass(u)}"><span class="dot"></span>{universeLabel(u)}</span>
    {:else}
      <span class="caption" title="Nothing has arrived on Art-Net or sACN yet: check the console's output address, the network cable and the universe numbers (System shows details).">no DMX received</span>
    {/each}
  </div>
  <div class="item col" class:red={app.live.timecode.state === 'lost' && app.project.showLock}>
    <span class="mono value" class:faint={app.live.timecode.state === 'off'}>{app.live.timecode.value}</span>
    <span class="caption">timecode{app.live.timecode.state === 'off' ? '' : ` · ${app.live.timecode.state}`}</span>
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
  <a class="item col plain" href="#/system" title="Project versions (System): the engine saves one at start, on show mode and every 10 minutes after a change">
    <span class="mono value">{lastVersionText(app.live.versions?.lastAutomatic)}</span>
    <span class="caption">auto version</span>
  </a>
  <div class="item col">
    <span class="mono value">{app.live.clients.count}</span>
    <span class="caption" class:yellow={app.live.clients.lagging > 0}>clients{app.live.clients.lagging > 0 ? ` · ${app.live.clients.lagging} lagging` : ''}</span>
  </div>
  {#if syncLost.length > 0}
    <a class="item red plain" href="#/layers" title="No sync packets for 2 s: {syncLost.join(', ')} play on their own clock (Layers)"><span class="dot dot-red"></span><span class="caption">sync lost</span></a>
  {/if}
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
    <button type="button" class="btn btn-icon" aria-label="Keyboard shortcuts" title="Keyboard shortcuts (?)" onclick={() => (shell.help = true)}>?</button>
    <button type="button" class="role role-{app.role} role-btn" title="Log in as another role" onclick={() => (showLogin = true)}>{app.role.toUpperCase()}</button>
  </div>
</header>
{#if showLogin}<Login onclose={() => (showLogin = false)} />{/if}

<style>
  .status { display: flex; flex-wrap: wrap; align-items: center; min-height: 56px; padding: 4px 8px; background: var(--surface-1); border-bottom: 1px solid var(--line); }
  .item { display: flex; align-items: center; gap: 8px; height: var(--touch); padding: 0 12px; border-right: 1px solid var(--line); }
  .item.col { flex-direction: column; align-items: flex-start; justify-content: center; gap: 0; }
  .item.right { border-right: 0; padding-right: 4px; }
  .item.red { background: var(--red-bg); border-radius: 6px; }
  .item.red .value, .item.red .caption { color: var(--red); }
  .brand .name { font-weight: 700; letter-spacing: -0.01em; }
  .tag { border: 0; cursor: pointer; }
  .tag.tag-open { border: 1px solid var(--line-strong); background: transparent; }
  .modewrap { position: relative; }
  .pop { position: absolute; z-index: 40; top: calc(100% + 6px); left: 0; width: 320px; max-width: calc(100vw - 24px); padding: 12px; display: flex; flex-direction: column; gap: 8px; background: var(--surface-2); border-color: var(--red); box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5); }
  .pop ul { margin: 0; padding-left: 18px; font-size: 13px; }
  .pop p { margin: 0; }
  .popactions { display: flex; gap: 8px; }
  .popactions a { text-decoration: none; }
  .tag:disabled { opacity: 0.8; }
  .resumed { margin-left: 8px; color: var(--yellow); text-decoration: none; }
  .value { font-size: 15px; font-weight: 500; display: inline-flex; align-items: center; gap: 6px; }
  .dmx { gap: 6px; }
  .ingest { width: 150px; }
  .ingest .bar { width: 100%; height: 4px; margin-top: 4px; }
  .yellow { color: var(--yellow); }
  .role-btn { border: 0; cursor: pointer; min-height: var(--touch); }
  .plain { color: inherit; text-decoration: none; }
</style>
