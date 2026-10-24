<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import SystemLogs from '../components/SystemLogs.svelte';
  import SystemMetrics from '../components/SystemMetrics.svelte';
  import SystemRoles from '../components/SystemRoles.svelte';
  import { modeText } from '../lib/outputs';
  import { app, can, cmd } from '../lib/state.svelte';
  import { LOCKED_TITLE, OPERATOR_TITLE, ageText, headerCaption, memoryText, outputTone, readinessBadge, readinessSummary, stampText, thermalTone } from '../lib/system';

  const show = $derived(app.live.show);
  const sys = $derived(app.live.system);
  const library = $derived(app.live.library);
  const summary = $derived(readinessSummary(show.readiness, show.checkedAt));
  const lockedOperator = $derived(!can('operator'));
  const lockedProgrammer = $derived(!can('programmer'));
  const caption = $derived(
    headerCaption({
      chip: app.live.engine.chip || (typeof app.caps.chip === 'string' ? app.caps.chip : ''),
      os: sys.os,
      version: app.live.engine.version,
      uptimeSeconds: app.live.engine.uptimeSeconds,
    }),
  );
  const outputName = (id: number) => app.project.outputs.find((o) => o.id === id)?.name ?? `Output ${id}`;

  let readinessPanel: HTMLElement | undefined = $state();

  // The switch follows the live document; a refused command puts it back and shows what blocks.
  async function toggleShowMode(event: Event & { currentTarget: HTMLInputElement }) {
    const input = event.currentTarget;
    const on = input.checked;
    if ((await cmd('show.mode', { on })) !== undefined) return;
    input.checked = show.mode;
    if (on) readinessPanel?.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' });
  }

  let rootDraft = $state<string | null>(null);
  const rootValue = $derived(rootDraft ?? app.project.library.root);
  const rootDirty = $derived(rootDraft !== null && rootDraft.trim() !== '' && rootDraft.trim() !== app.project.library.root);
  async function applyRoot(event: SubmitEvent) {
    event.preventDefault();
    if (rootDraft === null || !rootDirty) return;
    if ((await cmd('project.set', { path: '/library/root', value: rootDraft.trim() })) !== undefined) rootDraft = null;
  }

  let copy = $state<'idle' | 'ok' | 'failed'>('idle');
  async function copyFingerprint() {
    try {
      await navigator.clipboard.writeText(sys.tlsFingerprint);
      copy = 'ok';
    } catch {
      copy = 'failed';
    }
  }
  $effect(() => {
    if (copy === 'idle') return;
    const timer = setTimeout(() => (copy = 'idle'), 2500);
    return () => clearTimeout(timer);
  });
</script>

<div class="toolbar">
  <h1>System</h1>
  <span class="caption">{caption}</span>
  <span class="spacer"></span>
  <label class="switch" title={lockedOperator ? OPERATOR_TITLE : undefined}>
    <input type="checkbox" role="switch" checked={show.mode} disabled={lockedOperator} onchange={toggleShowMode} />
    <span class="track" aria-hidden="true"></span>
    <span class="label">Show mode</span>
  </label>
</div>

<section class="panel" bind:this={readinessPanel} aria-labelledby="readiness-title">
  <header class="phead">
    <h2 id="readiness-title">Readiness</h2>
    {#if summary.status === 'ready'}<span class="pill pill-green"><span class="dot"></span>ready</span>
    {:else if summary.status === 'notReady'}<span class="pill pill-red"><span class="dot"></span>not ready</span>
    {:else}<span class="pill pill-yellow"><span class="dot"></span>not checked</span>{/if}
    <span class="caption">checked {stampText(show.checkedAt)}</span>
    <span class="spacer"></span>
    <button type="button" class="btn" disabled={lockedOperator} title={lockedOperator ? OPERATOR_TITLE : undefined} onclick={() => void cmd('readiness.run')}>Run checks</button>
  </header>
  {#if show.mode && summary.status === 'notReady'}
    <div class="banner banner-red inset" role="alert">
      <span class="dot dot-red"></span>
      <span><strong>Show mode is on with blocking items:</strong> {summary.blocking.map((i) => i.title).join(', ')}</span>
    </div>
  {/if}
  <ul>
    {#each show.readiness as item (item.id)}
      {@const badge = readinessBadge(item)}
      <li class="list-row item">
        <span class="dot dot-{badge.tone}" role="img" aria-label={badge.label}></span>
        <div class="grow">
          <div>{item.title}</div>
          {#if item.detail}<div class="mono muted wrap">{item.detail}</div>{/if}
          {#if item.fix && item.state !== 'ok'}<div class="caption">{item.fix}</div>{/if}
        </div>
        {#if item.state === 'hard'}
          <span class="badge badge-err">blocking</span>
        {:else if item.state === 'manual'}
          <span class="badge badge-outline">manual</span>
        {:else if item.state === 'fail'}
          {#if item.acknowledged}
            <span class="badge badge-warn">acknowledged</span>
          {:else}
            <button type="button" class="btn" disabled={lockedProgrammer} title={lockedProgrammer ? LOCKED_TITLE : undefined} onclick={() => void cmd('readiness.acknowledge', { id: item.id })}>Acknowledge</button>
          {/if}
        {/if}
      </li>
    {:else}
      <li class="caption empty">No checks have run yet. Run the checks, or enter show mode, which runs them.</li>
    {/each}
  </ul>
</section>

<SystemMetrics />

<div class="cols">
  <section class="panel" aria-labelledby="machine-title">
    <header class="phead"><h2 id="machine-title">Machine</h2></header>
    <dl class="kv">
      <dt>Thermal</dt>
      <dd><span class="pill pill-{thermalTone(sys.thermal)}"><span class="dot"></span>{sys.thermal}</span></dd>
      <dt>Power</dt>
      <dd><span class="pill pill-{sys.onAC ? 'green' : 'yellow'}"><span class="dot"></span>{sys.power || (sys.onAC ? 'AC power' : 'on battery')}</span></dd>
      <dt>Memory</dt>
      <dd class="mono">{memoryText(sys.memoryFreeFraction, sys.memoryGB)}</dd>
      <dt>Library</dt>
      <dd>
        <div class="mono wrap">{library.root || '—'}</div>
        <div class="caption status">
          <span class="dot dot-{library.rootExists ? 'green' : 'yellow'}"></span>
          {library.rootExists ? 'folder found' : 'folder not found'} · {library.folders} folders · {library.fileCount} files{library.invalidCount > 0 ? ` · ${library.invalidCount} invalid` : ''}
        </div>
        <form class="rootform" onsubmit={applyRoot}>
          <input class="input mono" type="text" aria-label="Library root path" autocomplete="off" spellcheck="false" value={rootValue} disabled={lockedProgrammer} title={lockedProgrammer ? LOCKED_TITLE : undefined} oninput={(event) => (rootDraft = event.currentTarget.value)} />
          <button type="submit" class="btn" disabled={lockedProgrammer || !rootDirty} title={lockedProgrammer ? LOCKED_TITLE : undefined}>Apply</button>
        </form>
      </dd>
    </dl>

    <h3>Displays</h3>
    <ul>
      {#each app.live.displays as d (d.uuid)}
        <li class="list-row item">
          <span class="grow ellipsis" title={d.name}>{d.name}</span>
          <span class="mono muted">{modeText(d)}</span>
          {#if d.main}<span class="badge badge-outline">main</span>{/if}
          {#if d.builtin}<span class="badge badge-outline">built-in</span>{/if}
        </li>
      {:else}
        <li class="caption empty">No displays reported.</li>
      {/each}
    </ul>

    <h3>Outputs</h3>
    <ul>
      {#each app.live.outputs as s (s.id)}
        <li class="list-row item">
          <span class="dot dot-{outputTone(s.state)}" role="img" aria-label={s.state}></span>
          <span class="grow ellipsis">{outputName(s.id)}</span>
          <span class={s.state === 'lost' ? 'red' : 'muted'}>{s.state}{s.display ? ` · ${s.display}` : ''}</span>
          {#if s.state === 'bound'}<span class="mono muted">{modeText(s)}</span>{/if}
        </li>
      {:else}
        <li class="caption empty">No outputs configured.</li>
      {/each}
    </ul>

    <h3>DMX universes</h3>
    <ul>
      {#each app.live.dmx.universes as u (u.id)}
        <li class="list-row item">
          <span class="dot dot-{u.active ? 'green' : 'off'}" role="img" aria-label={u.active ? 'active' : 'silent'}></span>
          <span class="mono">{u.id}</span>
          <span class="grow ellipsis muted" title={u.source}>{u.source || '—'}</span>
          <span class="mono muted">{u.packets} packets</span>
          <span class="mono muted">{ageText(u.ageSeconds)}</span>
        </li>
      {:else}
        <li class="caption empty">No universes seen.</li>
      {/each}
    </ul>
  </section>

  <section class="panel" aria-labelledby="network-title">
    <header class="phead"><h2 id="network-title">Network</h2></header>
    {#if app.live.security.webUIOpen}
      <div class="banner banner-yellow inset" role="status">
        <span class="dot dot-yellow"></span>
        <span><strong>Web UI open:</strong> the programmer role has no password, so anyone who can reach this address has full control. Set one under Roles and passwords.</span>
      </div>
    {/if}
    <dl class="kv">
      <dt>Host</dt>
      <dd class="mono wrap">{sys.host || '—'}</dd>
      <dt>Addresses</dt>
      <dd class="mono wrap">
        {#each sys.addresses as address (address)}<div>{address}</div>{:else}—{/each}
      </dd>
      <dt>Port</dt>
      <dd class="mono">{sys.port}</dd>
      <dt>Bonjour</dt>
      <dd class="mono wrap">{sys.bonjour || '—'}</dd>
      <dt>TLS fingerprint</dt>
      <dd>
        <div class="mono wrap">{sys.tlsFingerprint || '—'}</div>
        <div class="copyrow">
          <button type="button" class="btn" disabled={!sys.tlsFingerprint} onclick={copyFingerprint}>Copy</button>
          <span class="caption" role="status">{copy === 'ok' ? 'Copied' : copy === 'failed' ? 'Copy is not available here; select the text instead' : ''}</span>
        </div>
      </dd>
      <dt>Clients</dt>
      <dd class="mono">{app.live.clients.count} connected · <span class:yellow={app.live.clients.lagging > 0}>{app.live.clients.lagging} lagging</span></dd>
      <dt>CITP</dt>
      <dd class="mono wrap">
        {#if app.live.citp.port}
          TCP {app.live.citp.port} · {app.live.citp.clients.length} console{app.live.citp.clients.length === 1 ? '' : 's'} · {app.live.citp.streams} stream{app.live.citp.streams === 1 ? '' : 's'}
          {#each app.live.citp.clients as client (client)}<div>{client}</div>{/each}
        {:else}
          not running
        {/if}
      </dd>
    </dl>
  </section>
</div>

<SystemRoles />
<SystemLogs />

<style>
  .phead { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; padding: 12px 16px; }
  .inset { margin: 0 16px 12px; }
  ul { list-style: none; margin: 0; padding: 0; }
  .item { flex-wrap: wrap; gap: 8px 12px; padding: 8px 16px; }
  .item:last-child { border-bottom: 0; }
  .empty { margin: 0; padding: 8px 16px 12px; }
  .grow { flex: 1 1 140px; min-width: 0; }
  .wrap { overflow-wrap: anywhere; }
  .red { color: var(--red); }
  .yellow { color: var(--yellow); }
  .cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 420px), 1fr)); gap: 12px; align-items: start; }
  .kv { display: grid; grid-template-columns: minmax(96px, 30%) minmax(0, 1fr); gap: 12px 16px; margin: 0; padding: 0 16px 16px; align-items: start; }
  .kv dt { padding-top: 5px; color: var(--text-2); font-size: 13px; font-weight: 500; }
  .kv dd { margin: 0; min-width: 0; padding-top: 3px; }
  .status { display: flex; align-items: center; gap: 6px; margin-top: 4px; }
  .rootform, .copyrow { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 8px; }
  .rootform .input { flex: 1 1 200px; min-width: 0; text-align: left; }
  h3 { margin: 0; padding: 4px 16px 8px; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
  .switch:has(input:focus-visible) .track { outline: 2px solid var(--accent); outline-offset: 2px; }
  .switch:has(input:disabled) { cursor: default; opacity: 0.55; }
</style>
