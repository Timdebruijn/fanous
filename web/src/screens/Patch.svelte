<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import DMXMonitor from '../components/DMXMonitor.svelte';
  import PatchGroup from '../components/PatchGroup.svelte';
  import UniversesPanel from '../components/UniversesPanel.svelte';
  import { POLICIES } from '../lib/layers';
  import { app, can, cmd } from '../lib/state.svelte';
  import { LOCKED_TITLE, buildPatch, loadChannelMap, summarize, universeOptions, universeRows, type ChannelMap } from '../lib/patch-screen';

  // Modes and footprints come from the engine's channel map; until it arrives (or if it cannot be fetched) the four
  // standard modes apply.
  let map = $state.raw<ChannelMap | null>(null);
  onMount(() => {
    void loadChannelMap().then((loaded) => (map = loaded));
  });

  /** the fixture whose inline editor is open */
  let selectedName = $state<string | null>(null);
  /** the universe the user picked or patched to last; falls back when it is no longer known */
  let chosenUniverse = $state<string | null>(null);
  /** the universe whose settings are open in the Universes panel */
  let openUniverse = $state<string | null>(null);

  const screen = $derived(buildPatch(app.project.patch, app.project.layerCount, map, app.project.outputs.map((o) => o.id)));
  const rows = $derived(screen.rows);
  const selected = $derived(rows.find((r) => r.name === selectedName) ?? null);
  const summary = $derived(summarize(rows));
  // the open and the monitored universe keep their row while their console pauses
  const universes = $derived(universeRows(rows, app.live.dmx.universes, app.project.universes, [openUniverse, chosenUniverse].filter((id) => id !== null)));
  const known = $derived(universes.map((u) => u.id));
  // every universe the panel and the monitor know, so a select never goes blank on one of them
  const options = $derived(universeOptions(app.project.patch, app.live.dmx.universes, app.project.universes));
  const monitorUniverse = $derived.by(() => {
    if (chosenUniverse && known.includes(chosenUniverse)) return chosenUniverse;
    if (selected?.patched && selected.universe) return selected.universe;
    return known[0] ?? null;
  });

  const policyLock = $derived(!can('programmer') ? LOCKED_TITLE : app.project.showLock ? 'Locked: show lock is on' : undefined);

  function select(name: string | null) {
    selectedName = name;
    const row = rows.find((r) => r.name === name);
    if (row?.patched && row.universe) chosenUniverse = row.universe;
  }

  function openSettings(id: string) {
    openUniverse = openUniverse === id ? null : id;
    chosenUniverse = id;
  }
</script>

<div class="toolbar">
  <h1>Patch</h1>
  <span class="caption">
    {summary.fixtures} fixtures · {summary.universes} universes{#if summary.collisions > 0}{' · '}<span class="alert">{summary.collisions} collisions</span>{/if}
  </span>
  <span class="spacer"></span>
  <a class="link" href="/api/channel-map.md" target="_blank" rel="noopener">Channel map</a>
  <a class="btn" href="/api/gdtf" download>Export GDTF</a>
</div>

<div class="screen">
  <div class="left">
    <section class="panel who" aria-label="Who controls">
      <label class="field">
        <span class="label">Who controls</span>
        <select class="select" aria-describedby="who-line" value={app.project.policy} disabled={!!policyLock} title={policyLock} onchange={(e) => void cmd('project.set', { path: '/policy', value: e.currentTarget.value })}>
          {#each Object.entries(POLICIES) as [value, p] (value)}
            <option {value}>{p.label}</option>
          {/each}
        </select>
      </label>
      <p class="caption" id="who-line">{POLICIES[app.project.policy]?.line}</p>
    </section>
    {#each screen.groups as group, index (group.kind)}
      <PatchGroup {group} {index} groups={screen.groups} {rows} {options} selected={selectedName} onselect={select} onpatched={(universe) => (chosenUniverse = universe)} />
    {/each}
  </div>
  <div class="right">
    <UniversesPanel rows={universes} open={openUniverse} onopen={openSettings} />
    <DMXMonitor universes={known} universe={monitorUniverse} onuniverse={(id) => (chosenUniverse = id)} {rows} selected={selectedName ?? ''} {map} />
  </div>
</div>

<style>
  .who { padding: 16px; display: flex; flex-direction: column; gap: 8px; }
  .who .select { max-width: 100%; }
  .who p { margin: 0; }
  .screen { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 12px; }
  .left { flex: 1 1 520px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .right { flex: 1 1 560px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .link { display: inline-flex; align-items: center; min-height: var(--touch); padding: 0 8px; }
  .alert { color: var(--red); }
</style>
