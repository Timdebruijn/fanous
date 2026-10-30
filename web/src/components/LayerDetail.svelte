<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import type { LayerStatus, PatchEntry, ResolvedParameter } from '../lib/docs';
  import { RELEASE_TEXT, ZERO_GROUPS, channelRange, clockText, controlKeys, folderZeroItems, mediaOptions, mediaPath, patchText, reservedText, valueText, type ChannelSpec, type LibrarySnapshot } from '../lib/layers';
  import { app, can, cmd, playOnLayer } from '../lib/state.svelte';
  import { syncStatus } from '../lib/sync';
  import { throttledSender } from '../lib/throttle';
  import PolicyHint from './PolicyHint.svelte';

  let {
    n,
    layer,
    params,
    entry,
    specs,
    footprint,
    library = null,
    name = undefined,
  }: {
    n: number;
    layer: LayerStatus | undefined;
    params: ResolvedParameter[] | undefined;
    entry: PatchEntry | undefined;
    specs: ChannelSpec[] | undefined;
    footprint: number;
    library?: LibrarySnapshot | null;
    /** "Master" or "Output n" instead of Layer n: intensity/speed or intensity/test pattern only, no media (B27). */
    name?: string;
  } = $props();

  const specByKey = $derived(new Map((specs ?? []).map((spec) => [spec.key, spec])));
  const missing = $derived(layer?.kind === 'missing');
  const sync = $derived(syncStatus(n, layer?.sync, app.live.sync));

  // UI control (DESIGN §7.2): values go in as the `ui` source; the project's source policy decides whether they win.
  let control = $state(false);
  const fixture = $derived(name ?? `Layer ${n}`);
  const isLayer = $derived(name === undefined);
  const keys = $derived(controlKeys(fixture));
  const shown = $derived(keys ? (params ?? []).filter((p) => keys.includes(p.key)) : (params ?? []));
  // the engine releases UI values 10 min after the last change, but only while a console is received for the fixture
  const expiresIn = $derived(app.live.dmx.uiExpiresIn?.[fixture]);
  const lockTitle = $derived(!can('programmer') ? 'Locked: programmer only' : app.project.showLock ? 'Locked: show lock is on' : undefined);
  const options = $derived(mediaOptions(library));
  const folderZero = $derived(folderZeroItems(app.live.syphon?.servers, app.live.capture));
  const current = $derived(layer && layer.folder > 0 && layer.file > 0 ? `${layer.folder}/${layer.file}` : '');
  const currentName = $derived(layer && layer.folder > 0 ? mediaPath(library, layer.folder, layer.file) : null);
  // MIDI values are a controller like the UI (B36): same expiry, Keep and Release
  const isController = (source: string) => source === 'ui' || source === 'midi';
  const hasUI = $derived((params ?? []).some((p) => isController(p.source)) || (app.live.dmx.internalValues[fixture] ?? []).some((v) => isController(v.source)));
  const controlLabel = $derived((app.live.dmx.internalValues[fixture] ?? []).some((v) => v.source === 'ui') ? 'UI control' : 'MIDI control');

  // at most ~20 commands a second per parameter while a slider moves; the last value always goes out, to the fixture
  // it was set on, flushed when another layer is picked (B80)
  const throttle = throttledSender((fixture, parameter, raw) => void cmd('fixture.set', { fixture, parameter, raw }));
  const send = (key: string, raw: number) => throttle.send(fixture, key, raw);
  $effect(() => {
    void fixture;
    return throttle.flush;
  });
  const rawMax = (spec: ChannelSpec | undefined) => (spec?.bits === 16 ? 65535 : 255);
  const isNumber = (key: string) => key === 'folder' || key === 'file';
</script>

<section class="panel detail" aria-labelledby="layer-detail-title">
  <header>
    <div class="titlebar">
      <h2 id="layer-detail-title">{fixture}</h2>
      <span class="spacer"></span>
      <label class="switch" title={lockTitle ?? 'Set these values from here, without a console'}>
        <input type="checkbox" role="switch" bind:checked={control} disabled={lockTitle !== undefined} />
        <span class="track"></span>
        <span>Control</span>
      </label>
    </div>
    <p class="caption mono">{patchText(entry, footprint)}</p>
    {#if currentName}<p class="caption">{currentName}</p>{/if}
    {#if hasUI}
      <p class="caption uinote">
        <span class="ui">{controlLabel}</span>{#if expiresIn !== undefined}<span>· console active, releases in <span class="mono">{clockText(expiresIn)}</span></span>
          <button type="button" class="btn" disabled={lockTitle !== undefined} title={lockTitle ?? 'Restart the 10 minutes'} onclick={() => void cmd('fixture.keep', { fixture })}>Keep</button>{/if}
      </p>
    {/if}
  </header>
  {#if control}
    <PolicyHint />
    <div class="releasebar">
      <span class="caption">{RELEASE_TEXT}</span>
      <button type="button" class="btn" disabled={!hasUI || lockTitle !== undefined} onclick={() => void cmd('fixture.release', { fixture })}>Release</button>
    </div>
    {#if isLayer}
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
      <span>Built-in content and live inputs (folder 0)</span>
      <select class="select" disabled={lockTitle !== undefined} value="" onchange={(e) => {
        const file = Number(e.currentTarget.value);
        e.currentTarget.value = '';
        if (!file) return;
        send('folder', 0);
        send('file', file);
        if ((params ?? []).find((p) => p.key === 'intensity')?.raw === 0) send('intensity', 65535);
      }}>
        <option value="">Put on this layer…</option>
        {#each ZERO_GROUPS as group (group.kind)}
          {@const list = folderZero.filter((i) => i.kind === group.kind)}
          {#if list.length > 0}
            <optgroup label={group.title}>{#each list as item (item.file)}<option value={item.file}>{item.label}</option>{/each}</optgroup>
          {/if}
        {/each}
      </select>
    </label>
    {/if}
  {/if}

  <ul class="params">
    {#each shown as param (param.key)}
      <li class="param">
        <span class="ch mono faint">{channelRange(specByKey.get(param.key))}</span>
        <span class="nm ellipsis" title={param.name}>{param.name}</span>
        <span class="raw mono">{param.raw}</span>
        <span class="val mono ellipsis" class:red={missing && (param.key === 'file' || param.key === 'folder')} title={valueText(param)}>{valueText(param)}{#if param.source === 'ui'}<span class="ui"> · UI</span>{:else if param.source === 'midi'}<span class="ui"> · MIDI</span>{/if}</span>
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
        {#if param.key === 'sync' && sync && isLayer}<span class="syncline caption sync-{sync.tone}">{sync.text}</span>{/if}
      </li>
    {:else}
      <li class="param none"><span class="caption">No resolved values from the engine yet.</span></li>
    {/each}
  </ul>
  {#if specs && isLayer}<p class="caption note">{reservedText(specs, footprint)}</p>{/if}
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
  .uinote { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; }
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
  .syncline { grid-column: 1 / -1; padding: 0 0 8px 48px; }
  .sync-green { color: var(--green); }
  .sync-yellow { color: var(--yellow); }
  .sync-red { color: var(--red); }
</style>
