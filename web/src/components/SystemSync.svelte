<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { lockTitle } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';
  import { interfaceChoices, mastersHere, shortId } from '../lib/sync';

  // Multi-server sync (B60, DESIGN §23.4): this machine's id, the settings (sync.set) and the packet counters.
  const sync = $derived(app.live.sync ?? null);
  const locked = $derived(lockTitle('programmer', can('programmer'), app.project.showLock) ?? (app.live.show.mode ? 'Leave show mode first' : undefined));

  // drafts: null = follow the engine
  let iface = $state<string | null>(null);
  let port = $state<string | null>(null);
  let target = $state<string | null>(null);
  const changes = $derived.by(() => {
    if (!sync) return {};
    const args: { interface?: string; port?: number; target?: string } = {};
    if (iface !== null && iface !== sync.interface) args.interface = iface;
    if (port !== null && Number(port) !== sync.port) args.port = Number(port);
    if (target !== null && target.trim() !== sync.target) args.target = target.trim();
    return args;
  });
  const dirty = $derived(Object.keys(changes).length > 0);
  async function apply(event: SubmitEvent) {
    event.preventDefault();
    if (!dirty) return;
    if ((await cmd('sync.set', changes)) !== undefined) iface = port = target = null;
  }
</script>

<section class="panel" aria-labelledby="sync-title">
  <header class="phead">
    <h2 id="sync-title">Sync</h2>
    <span class="caption">Layer clocks shared with other Fanous machines (layer channel 51).</span>
  </header>
  {#if sync}
    {@const here = mastersHere(sync)}
    <dl class="kv">
      <dt>Machine</dt>
      <dd class="mono wrap" title={sync.machine}>{app.live.system.host || '—'} · {shortId(sync.machine)}</dd>
      <dt>Packets</dt>
      <dd class="mono">in {sync.packetsIn} · out {sync.packetsOut} · <span class:red={sync.decodeErrors > 0}>{sync.decodeErrors} decode errors</span></dd>
      <dt>Masters here</dt>
      <dd class="mono wrap">
        {#each here as m (m.group)}<div>Group {m.group} · Layer {m.layer}</div>{:else}none{/each}
      </dd>
      <dt>Conflicts</dt>
      <dd class="mono wrap" class:red={sync.conflicts.length > 0}>{sync.conflicts.length > 0 ? sync.conflicts.map((g) => `Group ${g}`).join(', ') : 'none'}</dd>
    </dl>
    <form class="settings" onsubmit={apply}>
      <label class="field">
        <span class="caption">Interface</span>
        <select class="select" aria-label="Sync interface" value={iface ?? sync.interface} disabled={locked !== undefined} title={locked} onchange={(e) => (iface = e.currentTarget.value)}>
          {#each interfaceChoices(app.live.system.interfaces, iface ?? sync.interface) as name (name)}<option value={name}>{name}</option>{/each}
        </select>
      </label>
      <label class="field">
        <span class="caption">Port</span>
        <input class="input mono" type="number" min="1" max="65535" aria-label="Sync port" value={port ?? sync.port} disabled={locked !== undefined} title={locked} oninput={(e) => (port = e.currentTarget.value)} />
      </label>
      <label class="field grow">
        <span class="caption">Target</span>
        <input class="input mono" type="text" aria-label="Sync target" autocomplete="off" spellcheck="false" value={target ?? sync.target} disabled={locked !== undefined} title={locked} oninput={(e) => (target = e.currentTarget.value)} />
      </label>
      <button type="submit" class="btn" disabled={locked !== undefined || !dirty} title={locked}>Apply</button>
    </form>
    <p class="caption note">Target: <span class="mono">broadcast</span> (every machine on the interface's subnet) or one address, <span class="mono">10.0.0.12</span> or <span class="mono">10.0.0.12:8003</span>. Every machine in a show uses the same port. Apply restarts sending and receiving at once; refused in show mode.</p>
  {:else}
    <p class="caption note">Sync runs with the outputs: nothing is rendering on this machine.</p>
  {/if}
</section>

<style>
  .wrap { overflow-wrap: anywhere; }
  .red { color: var(--red); }
  .settings { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 8px 12px; padding: 0 16px; }
  .field { display: flex; flex-direction: column; gap: 4px; }
  .field .input[type='number'] { width: 110px; }
  .grow { flex: 1 1 200px; }
  .grow .input { text-align: left; }
  .note { margin: 0; padding: 12px 16px 16px; }
</style>
