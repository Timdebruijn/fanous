<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { MIDIMappingDoc } from '../lib/docs';
  import type { ChannelMap } from '../lib/patch-screen';
  import { fixtureNames, formatClock, formatNumber, groupSpecs, lockTitle, midiControlText, midiParameterTarget, midiTargetText, specsFor } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';

  /** null while the channel map is not there: parameter targets are then offered by key only once it arrives */
  let { map }: { map: ChannelMap | null } = $props();

  // DESIGN §15.4 (B36): source, MSC device id and the map are configuration (programmer, refused under show lock).
  const midi = $derived(app.project.midi ?? { source: null, mscDevice: 0, mscFormat: null, map: [] });
  /** MSC command formats offered; '' = the default (video 0x30–0x3F). All-types (0x7F) is always answered. */
  const formats: { value: number; label: string }[] = [
    { value: 0x01, label: 'Lighting (01)' },
    { value: 0x10, label: 'Sound (10)' },
    { value: 0x30, label: 'Video general (30) only' },
    { value: 0x7f, label: 'All types (7F) only' },
  ];
  const formatMissing = $derived(midi.mscFormat != null && !formats.some((f) => f.value === midi.mscFormat));
  const live = $derived(app.live.midi);
  const sources = $derived(app.live.osc.midiSources);
  const sourceMissing = $derived(!!midi.source && !sources.includes(midi.source));
  const mtcDevice = $derived(app.project.timecode.source === 'mtc' ? (app.project.timecode.device ?? '') : null);
  const editTitle = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const editable = $derived(editTitle === undefined);

  // the target the next Learn maps to
  let kind = $state<'cue.go' | 'cue.back' | 'cue.goto' | 'parameter'>('cue.go');
  let cueNumber = $state<number | null>(null);
  let fixture = $state('Layer 1');
  let parameter = $state('intensity');
  const fixtures = $derived(fixtureNames(app.project.layerCount, app.project.patch));
  const params = $derived(specsFor(map, fixture));
  const ready = $derived(kind === 'cue.goto' ? cueNumber !== null : kind === 'parameter' ? params.some((p) => p.key === parameter) : true);

  function learn() {
    if (kind === 'parameter') void cmd('midi.learn', { target: `fixture:${fixture}/${parameter}` });
    else if (kind === 'cue.goto' && cueNumber !== null) void cmd('midi.learn', { target: kind, cue: cueNumber });
    else void cmd('midi.learn', { target: kind });
  }

  async function save(m: MIDIMappingDoc, change: Partial<MIDIMappingDoc>, revert: () => void) {
    if ((await cmd('midi.map.set', { ...m, ...change })) === undefined) revert();
  }
</script>

<section class="panel midi" aria-labelledby="midi-title">
  <header>
    <h2 id="midi-title">MIDI</h2>
    <span class="spacer"></span>
    <span class="caption">{live.connected.length} {live.connected.length === 1 ? 'source' : 'sources'} listened to</span>
  </header>

  <p class="last mono" aria-live="polite">
    {#if live.last}<time class="faint">{formatClock(live.lastAt ?? 0)}</time> {live.last}{:else}<span class="caption">Nothing received yet. Press a key or move a control.</span>{/if}
  </p>
  {#if live.error}<p class="err" role="alert">{live.error}</p>{/if}

  <div class="fields">
    <label class="field">
      <span>Source</span>
      <select class="select" value={midi.source ?? ''} disabled={!editable} title={editTitle} onchange={(e) => { const el = e.currentTarget; void cmd('midi.set', { source: el.value === '' ? null : el.value }).then((r) => { if (r === undefined) el.value = midi.source ?? ''; }); }}>
        <option value="">All sources</option>
        {#if sourceMissing}<option value={midi.source}>{midi.source} (not connected)</option>{/if}
        {#each sources as s (s)}<option value={s}>{s}</option>{/each}
      </select>
    </label>
    <label class="field">
      <span>MSC device id</span>
      <input
        class="input mono"
        type="number"
        min="0"
        max="111"
        step="1"
        value={midi.mscDevice}
        disabled={!editable}
        title={editTitle ?? 'MIDI Show Control GO / GO with a cue number to this id (or to all, 127) fires cues'}
        onchange={(e) => {
          const el = e.currentTarget;
          const n = Number(el.value);
          if (!Number.isInteger(n) || n < 0 || n > 111) el.value = String(midi.mscDevice);
          else void cmd('midi.set', { mscDevice: n }).then((r) => { if (r === undefined) el.value = String(midi.mscDevice); });
        }}
      />
    </label>
    <label class="field">
      <span>MSC format</span>
      <select
        class="select"
        value={midi.mscFormat == null ? '' : String(midi.mscFormat)}
        disabled={!editable}
        title={editTitle ?? 'MSC messages in other command formats are ignored; all types (7F) is always answered'}
        onchange={(e) => {
          const el = e.currentTarget;
          void cmd('midi.set', { mscFormat: el.value === '' ? null : Number(el.value) }).then((r) => { if (r === undefined) el.value = midi.mscFormat == null ? '' : String(midi.mscFormat); });
        }}
      >
        <option value="">Video (30–3F)</option>
        {#if formatMissing}<option value={String(midi.mscFormat)}>Format {midi.mscFormat?.toString(16).toUpperCase().padStart(2, '0')}</option>{/if}
        {#each formats as f (f.value)}<option value={String(f.value)}>{f.label}</option>{/each}
      </select>
    </label>
  </div>

  {#if sources.length === 0}
    <p class="caption">No MIDI sources found. Connect an interface or enable a network MIDI session; the list updates by itself.</p>
  {:else}
    <ul class="sources">
      {#each sources as source (source)}
        <li>
          <span class="dot {live.connected.includes(source) ? 'dot-green' : 'dot-off'}"></span>
          <span class="ellipsis" title={source}>{source}</span>
          <span class="spacer"></span>
          {#if mtcDevice !== null && (mtcDevice === '' || mtcDevice === source)}<span class="badge badge-accent">timecode</span>{/if}
        </li>
      {/each}
    </ul>
  {/if}

  <h3>Map</h3>
  <div class="learn" role="group" aria-label="Learn a control">
    <select class="select" aria-label="Learn target" bind:value={kind} disabled={!editable} title={editTitle}>
      <option value="cue.go">GO</option>
      <option value="cue.back">Back</option>
      <option value="cue.goto">Go to cue</option>
      <option value="parameter">Parameter</option>
    </select>
    {#if kind === 'cue.goto'}
      <select class="select" aria-label="Cue" bind:value={cueNumber} disabled={!editable}>
        <option value={null}>Cue…</option>
        {#each app.project.cues as c (c.id)}<option value={c.number}>{formatNumber(c.number)} {c.name}</option>{/each}
      </select>
    {:else if kind === 'parameter'}
      <select class="select" aria-label="Fixture" bind:value={fixture} disabled={!editable}>
        {#each fixtures as f (f)}<option value={f}>{f}</option>{/each}
      </select>
      <select class="select" aria-label="Parameter" bind:value={parameter} disabled={!editable || params.length === 0}>
        {#each groupSpecs(params) as g (g.group)}
          <optgroup label={g.group || 'Parameters'}>{#each g.specs as p (p.key)}<option value={p.key}>{p.name}</option>{/each}</optgroup>
        {/each}
      </select>
    {/if}
    {#if live.learning}
      <span class="caption" aria-live="polite">Waiting for MIDI: press a key or move a control…</span>
      <button type="button" class="btn" disabled={!editable} title={editTitle} onclick={() => void cmd('midi.learn', {})}>Cancel</button>
    {:else}
      <button type="button" class="btn" disabled={!editable || !ready} title={editTitle ?? (ready ? 'Map the next note, controller or program change received' : 'Choose the cue or parameter first')} onclick={learn}>Learn</button>
    {/if}
  </div>
  {#if live.learned && !live.learning}<p class="caption" aria-live="polite">Learned: {live.learned}</p>{/if}

  {#if midi.map.length === 0}
    <p class="caption">No controls mapped. Choose a target, press Learn and touch the control.</p>
  {:else}
    <div class="scroll">
      <table>
        <thead><tr><th scope="col">Control</th><th scope="col">Target and mode</th><th scope="col" aria-label="Remove"></th></tr></thead>
        <tbody>
          {#each midi.map as m (m.id)}
            <tr>
              <td class="mono">{midiControlText(m)}<div class="faint ellipsis" title={m.source ?? 'any source'}>{m.source ?? 'any source'}</div></td>
              <td>
                <div>{midiTargetText(m, map)}</div>
                {#if midiParameterTarget(m.target)}
                  <div class="mode">
                    <select class="select" aria-label="Mode" value={m.curve} disabled={!editable} title={editTitle} onchange={(e) => { const el = e.currentTarget; void save(m, { curve: el.value as MIDIMappingDoc['curve'] }, () => (el.value = m.curve)); }}>
                      <option value="linear">Linear</option>
                      <option value="toggle">Toggle</option>
                    </select>
                    <label class="pickup" title="Ignore the control until it passes the current value, so nothing jumps">
                      <input type="checkbox" checked={m.pickup} disabled={!editable || m.curve === 'toggle'} onchange={(e) => { const el = e.currentTarget; void save(m, { pickup: el.checked }, () => (el.checked = m.pickup)); }} />
                      Pickup
                    </label>
                  </div>
                {/if}
              </td>
              <td><button type="button" class="btn" disabled={!editable} title={editTitle} onclick={() => void cmd('midi.map.remove', { id: m.id })}>Remove</button></td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</section>

<style>
  .midi { padding: 16px; display: flex; flex-direction: column; gap: 8px; }
  header { display: flex; align-items: center; gap: 12px; }
  h3 { margin: 8px 0 0; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
  p { margin: 0; }
  .last { font-size: 13px; min-height: 20px; overflow-wrap: anywhere; }
  .err { color: var(--red); font-size: 13px; }
  .fields, .learn { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: flex-end; }
  .learn { align-items: center; }
  .fields .select, .learn .select { min-width: 0; max-width: 100%; }
  .fields .input { width: 90px; }
  .sources { list-style: none; margin: 0; padding: 0; }
  .sources li { display: flex; align-items: center; gap: 10px; min-height: var(--touch); border-bottom: 1px solid var(--line); }
  .sources li:last-child { border-bottom: 0; }
  .scroll { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; font-weight: 500; color: var(--text-3); padding: 4px 8px 4px 0; border-bottom: 1px solid var(--line); }
  td { padding: 6px 8px 6px 0; border-bottom: 1px solid var(--line); vertical-align: middle; }
  td .faint { font-size: 12px; max-width: 160px; }
  tbody tr:last-child td { border-bottom: 0; }
  td:last-child { padding-right: 0; text-align: right; }
  /* the aside can be ~290 px wide: mode and pickup sit under the target and wrap, so Remove always fits */
  .mode { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; margin-top: 4px; }
  .pickup { display: inline-flex; align-items: center; gap: 4px; white-space: nowrap; }
</style>
