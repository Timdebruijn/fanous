<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { JSONValue } from '../lib/protocol';
  import { lockTitle, timecodeBadge, timecodeSource } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';

  const tc = $derived(app.project.timecode);
  const live = $derived(app.live.timecode);
  const badge = $derived(timecodeBadge(live.state));
  // The switch is the operator's `timecode.enable` (also under show lock); the source and the rest are configuration.
  const on = $derived(tc.source !== 'off' && tc.enabled !== false);

  // Settings are configuration (programmer, refused under show lock); the switch is the operator's.
  const editTitle = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const editable = $derived(editTitle === undefined);
  const switchTitle = $derived(tc.source === 'off' ? 'Choose a source first' : lockTitle('operator', can('operator'), false));
  const switchable = $derived(switchTitle === undefined);

  const devices = $derived(tc.source === 'ltc' ? app.live.osc.audioInputs : tc.source === 'mtc' ? app.live.osc.midiSources : []);
  const deviceMissing = $derived(!!tc.device && !devices.includes(tc.device));
  const noDevice = $derived(tc.source === 'mtc' ? 'All sources' : 'Default input');

  // Draft that follows the project until edited, so quick repeated taps on the stepper add up before the engine answers.
  let offset = $derived(tc.offset);

  /** Sends one setting; `revert` puts the control back when the engine refuses (the banner says why). */
  async function set(path: string, value: JSONValue, revert: () => void) {
    if ((await cmd('timecode.set', { path, value })) === undefined) revert();
  }

  function typed(el: HTMLInputElement): number | null {
    const n = Number(el.value);
    return el.value.trim() === '' || !Number.isFinite(n) ? null : n;
  }

  function setOffset(n: number | null, el?: HTMLInputElement) {
    if (n === null) {
      if (el) el.value = String(offset);
      return;
    }
    offset = Math.round(n);
    void set('/offset', offset, () => (offset = tc.offset));
  }
</script>

<section class="panel tc" aria-labelledby="tc-title">
  <header>
    <h2 id="tc-title">Timecode</h2>
    <span class="spacer"></span>
    <label class="switch" title={switchTitle}>
      <input
        type="checkbox"
        role="switch"
        checked={on}
        disabled={!switchable}
        onchange={async (e) => {
          const el = e.currentTarget;
          if ((await cmd('timecode.enable', { on: !on })) === undefined) el.checked = on;
        }}
      />
      <span class="track"></span>
      <span>Timecode on/off</span>
    </label>
  </header>

  <div class="readout-row">
    <div class="readout mono" role="timer" aria-label="Timecode">{live.value}</div>
    <div class="meta">
      <span class="pill pill-{badge.tone}"><span class="dot"></span>{badge.label}</span>
      <span class="mono">{timecodeSource(live)}</span>
      <span class="caption">{live.seen} frames seen</span>
    </div>
  </div>
  {#if live.error}<p class="err" role="alert">{live.error}</p>{/if}

  <div class="fields">
    <label class="field">
      <span>Source</span>
      <select class="select" value={tc.source} disabled={!editable} title={editTitle} onchange={(e) => { const el = e.currentTarget; void set('/source', el.value, () => (el.value = tc.source)); }}>
        <option value="off">Off</option>
        <option value="ltc">LTC (audio input)</option>
        <option value="mtc">MTC (MIDI)</option>
      </select>
    </label>
    <label class="field">
      <span>Device</span>
      <select class="select" value={tc.device ?? ''} disabled={!editable || tc.source === 'off'} title={editTitle} onchange={(e) => { const el = e.currentTarget; void set('/device', el.value === '' ? null : el.value, () => (el.value = tc.device ?? '')); }}>
        <option value="">{noDevice}</option>
        {#if deviceMissing}<option value={tc.device}>{tc.device} (not connected)</option>{/if}
        {#each devices as d (d)}<option value={d}>{d}</option>{/each}
      </select>
    </label>
    <label class="field">
      <span>Channel</span>
      <input
        class="input mono"
        type="number"
        min="1"
        step="1"
        value={tc.channel + 1}
        disabled={!editable || tc.source !== 'ltc'}
        title={editTitle}
        onchange={(e) => {
          const el = e.currentTarget;
          const n = typed(el);
          if (n === null || n < 1) el.value = String(tc.channel + 1);
          else void set('/channel', Math.round(n) - 1, () => (el.value = String(tc.channel + 1)));
        }}
      />
    </label>
    <div class="field" role="group" aria-labelledby="tc-offset">
      <span id="tc-offset">Offset (frames)</span>
      <div class="stepper" title={editTitle}>
        <button type="button" aria-label="Offset one frame earlier" disabled={!editable} onclick={() => setOffset(offset - 1)}>−</button>
        <input type="number" step="1" aria-labelledby="tc-offset" value={offset} disabled={!editable} onchange={(e) => setOffset(typed(e.currentTarget), e.currentTarget)} />
        <button type="button" aria-label="Offset one frame later" disabled={!editable} onclick={() => setOffset(offset + 1)}>+</button>
      </div>
    </div>
    <label class="field">
      <span>Freewheel (s)</span>
      <input
        class="input mono"
        type="number"
        min="0.1"
        step="0.5"
        value={tc.freewheel}
        disabled={!editable}
        title={editTitle}
        onchange={(e) => {
          const el = e.currentTarget;
          const n = typed(el);
          if (n === null || n < 0.1) el.value = String(tc.freewheel);
          else void set('/freewheel', n, () => (el.value = String(tc.freewheel)));
        }}
      />
    </label>
  </div>
  <p class="caption">
    Offset is subtracted from the incoming time. Channel 1 is the first input channel of the device.
    {#if tc.source === 'ltc'}LTC needs the microphone permission; the engine asks once.{/if}
  </p>
</section>

<style>
  .tc { padding: 16px; display: flex; flex-direction: column; gap: 16px; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  .readout-row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 24px; }
  .readout { font-size: clamp(34px, 11vw, 48px); font-weight: 600; line-height: 1.1; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
  .meta { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .pill-off { background: var(--surface-3); color: var(--text-3); }
  .err { margin: 0; color: var(--red); font-size: 13px; }
  .fields { display: flex; flex-wrap: wrap; gap: 12px 16px; align-items: flex-end; }
  .fields .select { min-width: 200px; max-width: 100%; }
  .fields .input { width: 110px; }
  .stepper input { width: 90px; }
  .switch { position: relative; }
  .switch input:focus-visible + .track { outline: 2px solid var(--accent); outline-offset: 2px; }
  p { margin: 0; }
</style>
