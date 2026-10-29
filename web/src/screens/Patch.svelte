<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import DMXMonitor from '../components/DMXMonitor.svelte';
  import PatchInspector from '../components/PatchInspector.svelte';
  import PatchTable from '../components/PatchTable.svelte';
  import { app, can, cmd } from '../lib/state.svelte';
  import { buildFixtures, knownUniverses, loadChannelMap, summarize, universeOptions, type ChannelMap } from '../lib/patch-screen';

  // Footprints come from the engine's channel map; until it arrives (or if it cannot be fetched) 64/8/8 apply.
  let map = $state.raw<ChannelMap | null>(null);
  onMount(() => {
    void loadChannelMap().then((loaded) => (map = loaded));
  });

  let selectedName = $state('Layer 1');
  /** the universe the user picked or patched to last; falls back when it is no longer known */
  let chosenUniverse = $state<string | null>(null);

  const rows = $derived(buildFixtures(app.project.patch, app.project.layerCount, map, app.project.outputs.map((o) => o.id)));
  const selected = $derived(rows.find((r) => r.name === selectedName) ?? rows[0]!);
  const summary = $derived(summarize(rows));
  const known = $derived(knownUniverses(app.project.patch, app.live.dmx.universes));
  const options = $derived(universeOptions(app.project.patch, app.live.dmx.universes));
  const monitorUniverse = $derived.by(() => {
    if (chosenUniverse && known.includes(chosenUniverse)) return chosenUniverse;
    if (selected.patched && selected.universe) return selected.universe;
    return known[0] ?? null;
  });

  const policyTitle = $derived(!can('programmer') ? 'Locked: programmer only' : app.project.showLock ? 'Locked: show lock is on' : 'Which sources control the fixtures: the console only, the UI and cues only, or both merged');

  function select(name: string) {
    selectedName = name;
    const row = rows.find((r) => r.name === name);
    if (row?.patched && row.universe) chosenUniverse = row.universe;
  }
</script>

<div class="toolbar">
  <h1>Patch</h1>
  <span class="caption">
    {summary.fixtures} fixtures · {summary.universes} universes{#if summary.collisions > 0}{' · '}<span class="alert">{summary.collisions} collisions</span>{/if}
  </span>
  <span class="spacer"></span>
  <label class="caption policy" title={policyTitle}>
    Source policy
    <select class="input" value={app.project.policy} disabled={policyTitle.startsWith('Locked')} onchange={(e) => void cmd('project.set', { path: '/policy', value: e.currentTarget.value })}>
      <option value="dmx">Console only</option>
      <option value="internal">UI and cues only (cues, OSC, this screen)</option>
      <option value="ltp">Console + UI (latest wins)</option>
      <option value="htp">Console + UI (highest wins)</option>
    </select>
  </label>
  <a class="link" href="/api/channel-map.md" target="_blank" rel="noopener">Channel map</a>
  <a class="btn" href="/api/gdtf" download>Export GDTF</a>
</div>

<div class="screen">
  <div class="left">
    <PatchTable {rows} selected={selected.name} onselect={select} />
    <PatchInspector row={selected} {options} defaultUniverse={monitorUniverse ?? 'artnet:0.0.0'} onpatched={(universe) => (chosenUniverse = universe)} />
  </div>
  <div class="right">
    <DMXMonitor universes={known} universe={monitorUniverse} onuniverse={(id) => (chosenUniverse = id)} {rows} selected={selected.name} {map} />
  </div>
</div>

<style>
  .policy { display: flex; align-items: center; gap: 8px; }
  .policy select { min-height: var(--touch); }
  .screen { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 12px; }
  .left { flex: 1 1 520px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .right { flex: 1 1 560px; min-width: 0; }
  .link { display: inline-flex; align-items: center; min-height: var(--touch); padding: 0 8px; }
  .alert { color: var(--red); }
</style>
