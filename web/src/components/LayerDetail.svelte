<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { LayerStatus, PatchEntry, ResolvedParameter } from '../lib/docs';
  import { GENERATORS, RELEASE_TEXT, channelRange, mediaOptions, mediaPath, patchText, reservedText, valueText, type ChannelSpec, type LibrarySnapshot } from '../lib/layers';
  import { app, can, cmd, playOnLayer } from '../lib/state.svelte';
  import PolicyHint from './PolicyHint.svelte';

  let {
    n,
    layer,
    params,
    entry,
    specs,
    footprint,
    library = null,
  }: {
    n: number;
    layer: LayerStatus | undefined;
    params: ResolvedParameter[] | undefined;
    entry: PatchEntry | undefined;
    specs: ChannelSpec[] | undefined;
    footprint: number;
    library?: LibrarySnapshot | null;
  } = $props();

  const specByKey = $derived(new Map((specs ?? []).map((spec) => [spec.key, spec])));
  const missing = $derived(layer?.kind === 'missing');

  // UI control (DESIGN §7.2): values go in as the `ui` source; the project's source policy decides whether they win.
  let control = $state(false);
  const fixture = $derived(`Layer ${n}`);
  const lockTitle = $derived(!can('programmer') ? 'Locked: programmer only' : app.project.showLock ? 'Locked: show lock is on' : undefined);
  const options = $derived(mediaOptions(library));
  const current = $derived(layer && layer.folder > 0 && layer.file > 0 ? `${layer.folder}/${layer.file}` : '');
  const currentName = $derived(layer && layer.folder > 0 ? mediaPath(library, layer.folder, layer.file) : null);
  const hasUI = $derived((params ?? []).some((p) => p.source === 'ui') || (app.live.dmx.internalValues[fixture] ?? []).some((v) => v.source === 'ui'));

  // at most ~20 commands a second per parameter while a slider moves; the last value always goes out
  const pending = new Map<string, number>();
  let timer: ReturnType<typeof setTimeout> | null = null;
  function send(key: string, raw: number) {
    pending.set(key, Math.round(raw));
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      for (const [parameter, value] of pending) void cmd('fixture.set', { fixture, parameter, raw: value });
      pending.clear();
    }, 50);
  }
  const rawMax = (spec: ChannelSpec | undefined) => (spec?.bits === 16 ? 65535 : 255);
  const isNumber = (key: string) => key === 'folder' || key === 'file';
</script>

<section class="panel detail" aria-labelledby="layer-detail-title">
  <header>
    <div class="titlebar">
      <h2 id="layer-detail-title">Layer {n}</h2>
      <span class="spacer"></span>
      <label class="switch" title={lockTitle ?? 'Set this layer from here, without a console'}>
        <input type="checkbox" role="switch" bind:checked={control} disabled={lockTitle !== undefined} />
        <span class="track"></span>
        <span>Control</span>
      </label>
    </div>
    <p class="caption mono">{patchText(entry, footprint)}</p>
    {#if currentName}<p class="caption">{currentName}</p>{/if}
  </header>
  {#if control}
    <PolicyHint />
    <div class="releasebar">
      <span class="caption">{RELEASE_TEXT}</span>
      <button type="button" class="btn" disabled={!hasUI || lockTitle !== undefined} onclick={() => void cmd('fixture.release', { fixture })}>Release</button>
    </div>
    <label class="field builtin">
      <span>Media from the library</span>
      <select class="select" aria-label="Media from the library" disabled={lockTitle !== undefined || options.length === 0} value={current} onchange={(e) => {
        const [folder, file] = e.currentTarget.value.split('/').map(Number);
        if (folder && file) void playOnLayer(n, folder, file);
      }}>
        <option value="" disabled>{options.length === 0 ? 'No media in the library yet (Media screen)' : 'Choose media…'}</option>
        {#each options as o (`${o.folder}/${o.file}`)}<option value={`${o.folder}/${o.file}`}>{o.label}</option>{/each}
      </select>
    </label>
    <label class="field builtin">
      <span>Built-in content (folder 0)</span>
      <select class="select" disabled={lockTitle !== undefined} value="" onchange={(e) => {
        const file = Number(e.currentTarget.value);
        e.currentTarget.value = '';
        if (!file) return;
        send('folder', 0);
        send('file', file);
        if ((params ?? []).find((p) => p.key === 'intensity')?.raw === 0) send('intensity', 65535);
      }}>
        <option value="">Put on this layer…</option>
        {#each GENERATORS as g (g.file)}<option value={g.file}>{g.file} · {g.name}</option>{/each}
      </select>
    </label>
  {/if}

  <ul class="params">
    {#each params ?? [] as param (param.key)}
      <li class="param">
        <span class="ch mono faint">{channelRange(specByKey.get(param.key))}</span>
        <span class="nm ellipsis" title={param.name}>{param.name}</span>
        <span class="raw mono">{param.raw}</span>
        <span class="val mono ellipsis" class:red={missing && (param.key === 'file' || param.key === 'folder')} title={valueText(param)}>{valueText(param)}{#if param.source === 'ui'}<span class="ui"> · UI</span>{/if}</span>
        {#if control}
          {@const spec = specByKey.get(param.key)}
          <span class="ctl">
            {#if spec?.bands?.length}
              <select class="select" aria-label={param.name} disabled={lockTitle !== undefined} value={spec.bands.find((b) => param.raw >= b.from && param.raw <= b.to)?.from ?? param.raw} onchange={(e) => send(param.key, Number(e.currentTarget.value))}>
                {#each spec.bands as band (band.from)}<option value={band.from}>{band.name}</option>{/each}
              </select>
            {:else if isNumber(param.key)}
              <input class="input mono" type="number" min="0" max="255" aria-label={param.name} disabled={lockTitle !== undefined} value={param.raw} onchange={(e) => send(param.key, Math.max(0, Math.min(255, Number(e.currentTarget.value) || 0)))} />
            {:else}
              <input type="range" min="0" max={rawMax(spec)} step="1" aria-label={param.name} disabled={lockTitle !== undefined} value={param.raw} oninput={(e) => send(param.key, Number(e.currentTarget.value))} ondblclick={() => spec && send(param.key, spec.default)} title="Double-click: default" />
            {/if}
          </span>
        {/if}
      </li>
    {:else}
      <li class="param none"><span class="caption">No resolved values from the engine yet.</span></li>
    {/each}
  </ul>
  {#if specs}<p class="caption note">{reservedText(specs, footprint)}</p>{/if}
</section>

<style>
  .detail { padding: 12px 12px 16px; display: flex; flex-direction: column; gap: 8px; }
  header { padding: 0 4px; }
  header p { margin: 2px 0 0; }
  .params { list-style: none; margin: 0; padding: 0; }
  .param { display: grid; grid-template-columns: 40px minmax(0, 1fr) 40px 88px; align-items: center; column-gap: 8px; min-height: var(--touch); padding: 0 4px; border-top: 1px solid var(--line); font-size: 13px; }
  .ctl { grid-column: 1 / -1; display: flex; padding: 0 0 8px 48px; }
  .ctl input[type='range'] { width: 100%; min-height: var(--touch); accent-color: var(--accent); }
  .ctl .select, .ctl .input { width: 100%; }
  .ui { color: var(--accent); }
  .titlebar { display: flex; align-items: center; gap: 8px; }
  .releasebar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 0 4px; }
  .releasebar .caption { flex: 1 1 160px; }
  .builtin { display: flex; flex-direction: column; gap: 4px; padding: 0 4px; }
  .none { display: block; padding-top: 12px; }
  .ch { font-size: 12px; }
  .raw { text-align: right; }
  .val { color: var(--text-2); font-size: 12px; }
  .val.red { color: var(--red); }
  .note { margin: 0; padding: 0 4px; }
</style>
