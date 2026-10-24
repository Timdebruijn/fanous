<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { CueDoc, CueValueDoc } from '../lib/docs';
  import type { ChannelMap, ParamSpec } from '../lib/patch-screen';
  import type { JSONValue } from '../lib/protocol';
  import {
    LOCKED_OPERATOR, TRIGGER_HINT, clampRaw, fixtureNames, formatNumber, groupSpecs, isNumberTaken, lockTitle, newValue, parseTrigger, retargetValue,
    specsFor, valueControl, withFade,
  } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';

  /** `map`: undefined while the channel map loads, null when it could not be loaded */
  let { cue, map: loaded }: { cue: CueDoc | undefined; map: ChannelMap | null | undefined } = $props();

  const map = $derived(loaded ?? null);

  const lock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const editable = $derived(lock === undefined);
  const fixtures = $derived(fixtureNames(app.project.layerCount, app.project.patch));
  /** the last entry that was refused here, shown under the fields (the engine's refusals show in the app banner) */
  let problem = $state('');

  $effect(() => {
    void cue?.id;
    problem = '';
  });

  /** Sends the whole cue; `revert` puts the control back when it was refused or nothing changed. */
  async function save(next: CueDoc, revert: () => void) {
    problem = '';
    if (JSON.stringify(next) === JSON.stringify(cue)) return revert();
    if ((await cmd('cue.set', { id: next.id, cue: next as unknown as JSONValue })) === undefined) revert();
  }

  /** The number typed into `el`, or null when it is empty, not a number, or below `min`. */
  function typed(el: HTMLInputElement, min = 0): number | null {
    const n = Number(el.value);
    return el.value.trim() === '' || !Number.isFinite(n) || n < min ? null : n;
  }

  /** An entry that cannot be a valid value: say why under the fields and put the control back. */
  function reject(el: HTMLInputElement, message: string, original: string) {
    problem = message;
    el.value = original;
  }

  function onNumber(c: CueDoc, el: HTMLInputElement) {
    const n = typed(el);
    const original = String(c.number);
    if (n === null) return reject(el, 'A cue number is a number from 0 up.', original);
    if (isNumberTaken(app.project.cues, n, c.id)) return reject(el, `Cue ${formatNumber(n)} already exists.`, original);
    void save({ ...c, number: n }, () => (el.value = original));
  }

  function onFade(c: CueDoc, el: HTMLInputElement) {
    const n = el.value.trim() === '' ? 0 : typed(el);
    const original = String(c.fade);
    if (n === null) return reject(el, 'A fade time is seconds, 0 or more.', original);
    void save({ ...c, fade: n }, () => (el.value = original));
  }

  function onFollow(c: CueDoc, el: HTMLInputElement) {
    const n = el.value.trim() === '' ? null : typed(el);
    const original = c.follow == null ? '' : String(c.follow);
    if (n === null && el.value.trim() !== '') return reject(el, 'Follow is seconds, 0 or more; leave it empty for none.', original);
    void save({ ...c, follow: n }, () => (el.value = original));
  }

  function onTrigger(c: CueDoc, el: HTMLInputElement) {
    const result = parseTrigger(el.value);
    if (!result.ok) {
      problem = result.error;
      el.value = c.trigger ?? '';
      return;
    }
    el.value = result.value ?? '';
    void save({ ...c, trigger: result.value }, () => (el.value = c.trigger ?? ''));
  }

  function setValue(c: CueDoc, i: number, next: CueValueDoc, revert: () => void) {
    void save({ ...c, values: c.values.map((v, j) => (j === i ? next : v)) }, revert);
  }

  function onRaw(c: CueDoc, i: number, v: CueValueDoc, spec: ParamSpec | undefined, el: HTMLInputElement) {
    const original = String(v.raw);
    const n = typed(el, -Infinity);
    if (n === null) {
      el.value = original;
      return;
    }
    const raw = clampRaw(spec, n);
    el.value = String(raw);
    setValue(c, i, { ...v, raw }, () => (el.value = original));
  }

  function onValueFade(c: CueDoc, i: number, v: CueValueDoc, el: HTMLInputElement) {
    const n = el.value.trim() === '' ? null : typed(el);
    const original = v.fade == null ? '' : String(v.fade);
    if (n === null && el.value.trim() !== '') return reject(el, 'A value fade is seconds, 0 or more; leave it empty to use the cue fade.', original);
    setValue(c, i, withFade(v, n), () => (el.value = original));
  }
</script>

{#snippet options(list: ParamSpec[])}
  {#each list as s (s.key)}<option value={s.key}>{s.name}</option>{/each}
{/snippet}

{#if !cue}
  <section class="panel editor" aria-label="Cue editor">
    <p class="caption">Select a cue to edit it.</p>
  </section>
{:else}
  {@const c = cue}
  <section class="panel editor" aria-labelledby="editor-title">
    <header>
      <h2 id="editor-title" class="ellipsis">Cue {formatNumber(c.number)}{c.name ? ` · ${c.name}` : ''}</h2>
      <span class="spacer"></span>
      <button type="button" class="btn" disabled={!can('operator')} title={can('operator') ? undefined : LOCKED_OPERATOR} onclick={() => void cmd('cue.goto', { number: c.number })}>Go to this cue</button>
    </header>

    <div class="fields">
      <label class="field">
        <span>Number</span>
        <input class="input mono" type="number" step="any" min="0" value={c.number} disabled={!editable} title={lock} onchange={(e) => onNumber(c, e.currentTarget)} />
      </label>
      <label class="field grow">
        <span>Name</span>
        <input class="input" type="text" value={c.name} disabled={!editable} title={lock} onchange={(e) => { const el = e.currentTarget; void save({ ...c, name: el.value }, () => (el.value = c.name)); }} />
      </label>
      <label class="field">
        <span>Fade (s)</span>
        <input class="input mono" type="number" step="0.1" min="0" value={c.fade} disabled={!editable} title={lock} onchange={(e) => onFade(c, e.currentTarget)} />
      </label>
      <label class="field">
        <span>Trigger</span>
        <input class="input mono left" type="text" autocomplete="off" spellcheck="false" placeholder="hh:mm:ss:ff@25" aria-describedby="editor-hint" value={c.trigger ?? ''} disabled={!editable} title={lock} onchange={(e) => onTrigger(c, e.currentTarget)} />
      </label>
      <label class="field">
        <span>Follow (s)</span>
        <input class="input mono" type="number" step="0.1" min="0" placeholder="none" value={c.follow ?? ''} disabled={!editable} title={lock} onchange={(e) => onFollow(c, e.currentTarget)} />
      </label>
    </div>
    <p class="caption" id="editor-hint">Trigger fires the cue when the timecode passes it; empty is none. Format: {TRIGGER_HINT}. Follow fires the next cue that many seconds after this one.</p>
    {#if problem}<p class="problem" role="alert">{problem}</p>{/if}

    <h3>Values</h3>
    {#if loaded === null}<p class="caption">The channel map could not be loaded; parameters show by key and the value range is the widest.</p>{/if}
    {#if c.values.length === 0}
      <p class="caption">This cue changes nothing yet. Add a value for each parameter it should set.</p>
    {:else}
      <ul class="values" aria-label="Values of cue {formatNumber(c.number)}">
        <li class="vrow vhead" aria-hidden="true"><span>Fixture</span><span>Parameter</span><span>Value</span><span>Fade (s)</span><span></span></li>
        {#each c.values as v, i (i)}
          {@const specs = specsFor(map, v.fixture)}
          {@const spec = specs.find((s) => s.key === v.parameter)}
          {@const ctl = valueControl(spec, v.raw)}
          <li class="vrow">
            <select class="select fx" aria-label="Fixture of value {i + 1}" value={v.fixture} disabled={!editable} title={lock} onchange={(e) => { const el = e.currentTarget; setValue(c, i, retargetValue(map, v, { fixture: el.value }), () => (el.value = v.fixture)); }}>
              {#each fixtures as f (f)}<option value={f}>{f}</option>{/each}
              {#if !fixtures.includes(v.fixture)}<option value={v.fixture}>{v.fixture} (missing)</option>{/if}
            </select>
            <select class="select par" aria-label="Parameter of value {i + 1}" value={v.parameter} disabled={!editable} title={lock} onchange={(e) => { const el = e.currentTarget; setValue(c, i, retargetValue(map, v, { parameter: el.value }), () => (el.value = v.parameter)); }}>
              {#if !spec}<option value={v.parameter}>{v.parameter}{specs.length ? ' (unknown)' : ''}</option>{/if}
              {#each groupSpecs(specs) as g (g.group)}
                {#if g.group}<optgroup label={g.group}>{@render options(g.specs)}</optgroup>{:else}{@render options(g.specs)}{/if}
              {/each}
            </select>
            <div class="ctl">
              {#if ctl.kind === 'select'}
                <select class="select" aria-label="{spec?.name ?? v.parameter} of value {i + 1}" value={ctl.selected ?? ''} disabled={!editable} title={lock} onchange={(e) => { const el = e.currentTarget; setValue(c, i, { ...v, raw: Number(el.value) }, () => (el.value = String(ctl.selected ?? ''))); }}>
                  {#if ctl.selected === null}<option value="" disabled>Raw {v.raw}</option>{/if}
                  {#each ctl.options as o (o.raw)}<option value={o.raw}>{o.label}</option>{/each}
                </select>
              {:else}
                <input class="input mono" type="number" step="1" min={ctl.min} max={ctl.max} aria-label="{spec?.name ?? v.parameter} of value {i + 1}" value={v.raw} disabled={!editable} title={lock} onchange={(e) => onRaw(c, i, v, spec, e.currentTarget)} />
              {/if}
              <span class="caption ellipsis" title={ctl.caption}>{ctl.caption}</span>
            </div>
            <input class="input mono vfade" type="number" step="0.1" min="0" placeholder="cue fade" aria-label="Fade of value {i + 1} in seconds, empty uses the cue fade" value={v.fade ?? ''} disabled={!editable} title={lock} onchange={(e) => onValueFade(c, i, v, e.currentTarget)} />
            <button type="button" class="btn btn-ghost btn-icon rm" aria-label="Remove value {i + 1}" disabled={!editable} title={lock ?? 'Remove value'} onclick={() => void save({ ...c, values: c.values.filter((_, j) => j !== i) }, () => {})}>×</button>
          </li>
        {/each}
      </ul>
    {/if}
    <div>
      <button type="button" class="btn" disabled={!editable} title={lock} onclick={() => void save({ ...c, values: [...c.values, newValue(map, fixtures)] }, () => {})}>Add value</button>
    </div>
  </section>
{/if}

<style>
  .editor { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
  header h2 { flex: 0 1 auto; max-width: 100%; }
  h3 { margin: 8px 0 0; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text-3); }
  p { margin: 0; }
  .problem { color: var(--red); font-size: 13px; }
  .fields { display: flex; flex-wrap: wrap; gap: 12px 16px; align-items: flex-end; }
  .fields .input { width: 110px; }
  .fields .field.grow { flex: 1 1 200px; }
  .fields .field.grow .input { width: 100%; }
  .fields .input.left { width: 190px; text-align: left; }

  .values { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .vrow { display: grid; grid-template-columns: 150px minmax(160px, 1.2fr) minmax(150px, 1fr) 110px var(--touch); gap: 8px 12px; align-items: start; }
  .vhead { font-size: 12px; color: var(--text-3); }
  .vrow .select, .vrow .input { width: 100%; min-width: 0; }
  .ctl { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .ctl .caption { padding: 0 2px; }

  @media (max-width: 720px) {
    .vhead { display: none; }
    .vrow {
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) var(--touch);
      grid-template-areas: 'fx par rm' 'ctl vfade rm';
      padding-bottom: 8px; border-bottom: 1px solid var(--line);
    }
    .fx { grid-area: fx; }
    .par { grid-area: par; }
    .ctl { grid-area: ctl; }
    .vfade { grid-area: vfade; }
    .rm { grid-area: rm; }
  }
</style>
