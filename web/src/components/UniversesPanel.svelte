<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd } from '../lib/state.svelte';
  import { lockTitle as lockFor } from '../lib/show';
  import { HOLD_LABELS, PROTOCOL_LABELS, interfaceOptions, parseUniverseName, universeName, type UniverseRow } from '../lib/patch-screen';

  // The universes and their receive settings (B28, DESIGN §6.6). Settings belong to the universe, not to the fixtures on it.
  let { rows, open, onopen }: {
    rows: UniverseRow[];
    /** the universe whose settings are open */
    open: string | null;
    onopen: (id: string) => void;
  } = $props();

  const lockTitle = $derived(lockFor('programmer', can('programmer'), app.project.showLock));

  /** One universe setting; a refused change (show lock, invalid value) puts the control back. */
  async function set(id: string, path: string, value: string | number | null, el: HTMLInputElement | HTMLSelectElement, previous: string) {
    await cmd('universe.set', { id, path: path as '/protocol', value });
    if (app.lastError) el.value = previous;
  }
</script>

<section class="panel universes" aria-label="Universes">
  <div class="head">
    <h2>Universes</h2>
    <span class="caption">tap one for its settings</span>
  </div>
  {#each rows as u (u.id)}
    {@const expanded = u.id === open}
    <!-- a stable name without the live packet count ("A 0.0.0, Layers 1–8, receiving"); the pill and settings line describe it -->
    <button type="button" class="list-row uni" aria-label="{universeName(u.id)}, {u.text}, {u.state}" aria-describedby="universe-meta-{u.id}"
      aria-expanded={expanded} aria-controls="universe-{u.id}" onclick={() => onopen(u.id)}>
      <span class="name mono">{universeName(u.id)}</span>
      <span class="fx" class:warn={u.tone === 'warn'} class:faint={u.tone === 'faint'}>{u.text}</span>
      <span class="meta" id="universe-meta-{u.id}">
        <span class="pill pill-{u.health.tone}" title={u.health.text}><span class="dot"></span><span class="ellipsis">{u.health.text}</span></span>
        <span class="caption">{u.line}</span>
      </span>
    </button>
    {#if expanded}
      {@const s = u.settings}
      {@const own = s.id.startsWith('sacn:') ? 'sacn' : 'artnet'}
      {@const interfaces = interfaceOptions(app.live.system.interfaces, s.interface)}
      <div class="settings" id="universe-{u.id}" role="group" aria-label="Settings of {universeName(u.id)}">
        <div class="fields">
          <label class="field">
            <span class="label">Protocol</span>
            <select class="select" value={s.protocol} disabled={!!lockTitle} title={lockTitle} onchange={(e) => set(s.id, '/protocol', e.currentTarget.value, e.currentTarget, s.protocol)}>
              {#each Object.entries(PROTOCOL_LABELS) as [value, label] (value)}
                <option {value}>{label}</option>
              {/each}
            </select>
          </label>
          {#if s.protocol !== own}
            <label class="field" title={lockTitle ?? 'The other protocol\'s universe that feeds this one, e.g. S 1 or A 0.0.0'}>
              <span class="label">{own === 'artnet' ? 'sACN universe' : 'Art-Net universe'}</span>
              <input class="input mono pair" value={universeName(s.pair)} disabled={!!lockTitle}
                onchange={(e) => set(s.id, '/pair', parseUniverseName(e.currentTarget.value), e.currentTarget, universeName(s.pair))} />
            </label>
          {/if}
          <label class="field">
            <span class="label">Interface</span>
            <select class="select" value={s.interface} disabled={!!lockTitle} title={lockTitle} onchange={(e) => set(s.id, '/interface', e.currentTarget.value, e.currentTarget, s.interface)}>
              {#each interfaces as option (option.value)}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </label>
          <label class="field">
            <span class="label">Hold on signal loss</span>
            <select class="select" value={s.holdOnLoss} disabled={!!lockTitle} title={lockTitle} onchange={(e) => set(s.id, '/holdOnLoss', e.currentTarget.value, e.currentTarget, s.holdOnLoss)}>
              {#each Object.entries(HOLD_LABELS) as [value, label] (value)}
                <option {value}>{label}</option>
              {/each}
            </select>
          </label>
          <label class="field">
            <span class="label">Signal lost after (s)</span>
            <input class="input mono timeout" type="number" min="1" max="60" step="0.5" value={s.lossTimeout} disabled={!!lockTitle} title={lockTitle}
              onchange={(e) => set(s.id, '/lossTimeout', Number(e.currentTarget.value), e.currentTarget, String(s.lossTimeout))} />
          </label>
          {#if s.protocol !== 'artnet'}
            <label class="field">
              <span class="label">sACN priority</span>
              <select class="select" value={s.sacnPriorityMode} disabled={!!lockTitle} title={lockTitle} onchange={(e) => set(s.id, '/sacnPriorityMode', e.currentTarget.value, e.currentTarget, s.sacnPriorityMode)}>
                <option value="highest">Highest wins</option>
                <option value="htp">Merge equal (HTP)</option>
              </select>
            </label>
          {/if}
        </div>
        {#if interfaces.find((o) => o.value === s.interface)?.label.endsWith('(not present)')}
          <p class="caption alert">Interface {s.interface} is not on this Mac: the universe receives nothing until it is connected.</p>
        {/if}
      </div>
    {/if}
  {:else}
    <p class="empty muted">No universe is patched, heard or set up yet.</p>
  {/each}
</section>

<style>
  .universes { overflow: hidden; }
  .head { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 16px 16px 8px; }
  /* name and fixtures, then the pill and the settings on a line of their own that wraps (a long pill on a phone) */
  .uni {
    display: grid; grid-template-columns: max-content minmax(0, 1fr); grid-template-areas: 'name fx' 'meta meta';
    column-gap: 12px; row-gap: 6px; padding: 10px 16px;
  }
  .uni[aria-expanded='true'] { background: var(--surface-2); box-shadow: inset 3px 0 0 var(--accent); }
  .name { grid-area: name; font-weight: 600; font-size: 14px; }
  .fx { grid-area: fx; font-size: 13px; }
  .meta { grid-area: meta; display: flex; flex-wrap: wrap; align-items: center; gap: 4px 12px; min-width: 0; }
  .pill { min-width: 0; max-width: 100%; }
  .warn { color: var(--yellow); }
  .settings { display: flex; flex-direction: column; gap: 12px; padding: 12px 16px 16px; border-bottom: 1px solid var(--line); box-shadow: inset 3px 0 0 var(--accent); }
  .fields { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 16px; }
  .fields .select { min-width: 140px; }
  .pair { width: 110px; }
  .timeout { width: 80px; }
  .alert { color: var(--yellow); }
  .empty { margin: 0; padding: 8px 16px 16px; }
  p { margin: 0; }
</style>
