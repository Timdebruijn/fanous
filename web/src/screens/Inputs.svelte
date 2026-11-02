<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  // The live inputs of folder 0, the audio inputs and the permissions they need (DESIGN §12.1, B137 steps 1 and 2).
  // Media's folder 0 stays the picker; the timecode settings stay on Show, "Use for timecode" is a second way to them.
  import LevelMeter from '../components/LevelMeter.svelte';
  import type { AudioInputDoc } from '../lib/docs';
  import { ZERO_GROUPS, folderZeroItems, layersShowing, signalText, zeroCaption, type FolderZeroItem } from '../lib/layers';
  import { go, route } from '../lib/router.svelte';
  import { lockTitle, ltcInput, timecodeBadge, timecodeOn } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';
  import { permissionRow } from '../lib/system';

  const capture = $derived(app.live.capture);
  const items = $derived(folderZeroItems(app.live.syphon?.servers, capture).filter((i) => i.kind !== 'generator'));
  const groups = $derived(
    ZERO_GROUPS.filter((g) => g.kind !== 'generator')
      .map((g) => {
        const list = items.filter((i) => i.kind === g.kind);
        // not running (in use counts as running): their numbers can be forgotten (B69, B73)
        return { ...g, list, notRunning: list.filter((i) => !i.running && !i.inUse).length };
      })
      .filter((g) => (g.kind === 'capture' ? capture !== undefined : g.kind === 'screen' ? g.list.length > 0 : true)),
  );
  // capture.forget without a file sweeps cameras and displays (1–28) at once, so one button above the cameras covers both
  const captureNotRunning = $derived(groups.filter((g) => g.kind === 'capture' || g.kind === 'screen').reduce((n, g) => n + g.notRunning, 0));
  const unnumbered = $derived(app.live.syphon?.unnumbered ?? []);
  const showing = $derived(layersShowing(app.live.layers));
  /** the first layer showing a folder 0 file: its status carries the input's signal (a Syphon layer's carries no size) */
  const openOn = (file: number) => app.live.layers.find((l) => l.folder === 0 && l.file === file);
  const picked = $derived(items.find((i) => String(i.file) === route.item));
  const audioInputs = $derived(app.live.audio?.inputs ?? []);
  /** an audio input has no folder 0 number: it is selected by name (`#/inputs/audio:<name>`) */
  const audioKey = (input: AudioInputDoc) => `audio:${encodeURIComponent(input.name)}`;
  const pickedAudio = $derived(audioInputs.find((i) => audioKey(i) === route.item));
  const tc = $derived(app.project.timecode);
  const ltc = $derived(ltcInput(tc, audioInputs));
  const ltcOn = $derived(timecodeOn(tc) && tc.source === 'ltc');
  let channelPick = $state<Record<string, number>>({});
  /** the timecode source set to LTC on this device and channel, as one `timecode.set` (one undo step); the switch stays */
  function useForTimecode(input: AudioInputDoc, channel: number) {
    void cmd('timecode.set', { path: '', value: { ...tc, source: 'ltc', device: input.name, channel } });
  }
  const editLock = $derived(lockTitle('programmer', can('programmer'), app.project.showLock));
  const authorizeLock = $derived(editLock ?? (app.live.show.mode ? 'Leave show mode first' : undefined));

  const KIND = { capture: 'Camera or capture card', screen: 'Display', syphon: 'Syphon server', generator: '' } as const;
  const NOUN = { capture: 'device', screen: 'display', syphon: 'server', generator: '' } as const;
  const shownOn = (kind: 'capture' | 'screen') => app.live.layers.some((l) => l.folder === 0 && (kind === 'capture' ? l.file >= 1 && l.file <= 20 : l.file >= 21 && l.file <= 28));
  const permissions = $derived.by(() => {
    const p = capture?.permissions;
    if (!p) return [];
    return [
      ...((capture?.devices.length ?? 0) > 0 ? [{ kind: 'camera' as const, label: 'Camera', row: permissionRow('camera', p.camera, shownOn('capture')) }] : []),
      ...((capture?.screens?.length ?? 0) > 0 ? [{ kind: 'screen' as const, label: 'Screen recording', row: permissionRow('screen', p.screen, shownOn('screen')) }] : []),
      // LTC is the one input that needs the microphone: shown while timecode is on LTC, yellow only with the switch on
      ...(tc.source === 'ltc' && p.microphone ? [{ kind: 'microphone' as const, label: 'Microphone (LTC)', row: permissionRow('microphone', p.microphone, ltcOn) }] : []),
    ];
  });
  const model = (item: FolderZeroItem) => {
    const m = item.kind === 'capture' ? app.project.capture?.[String(item.file)]?.model : undefined;
    return m && m !== item.name ? m : undefined;
  };

  async function forget(kind: FolderZeroItem['kind'], file?: number) {
    const args = file === undefined ? {} : { file };
    const done = await (kind === 'syphon' ? cmd('syphon.forget', args) : cmd('capture.forget', args));
    // a freed number goes to the next new input: the selection must not move to it
    if (done !== undefined && picked && !picked.running && !picked.inUse) go('inputs', '', true);
  }
  function statusWord(item: FolderZeroItem): string {
    return zeroCaption(item) ?? 'running';
  }
</script>

<div class="toolbar">
  <div>
    <h1>Inputs</h1>
    <div class="caption">The cameras, capture cards and displays of this Mac and the Syphon servers of other apps. A console selects them as folder 0, file n; put one on a layer from Media › folder 0 or the layer panel.</div>
  </div>
</div>

{#if permissions.length > 0}
  <section class="panel" aria-labelledby="permissions-title">
    <header class="phead"><h2 id="permissions-title">Permissions</h2></header>
    <ul aria-label="Permissions">
      {#each permissions as { kind, label, row } (kind)}
        <li class="list-row item">
          <span class="dot dot-{row.tone}" aria-hidden="true"></span>
          <span class="grow">{label}</span>
          <span class="muted">{row.word}</span>
          {#if row.authorize}
            <button type="button" class="btn" disabled={authorizeLock !== undefined} title={authorizeLock} onclick={() => void cmd('capture.authorize', { kind })}>Authorize {kind}</button>
          {/if}
          <!-- always rendered, so the live region announces the caption when it appears -->
          <span class="caption" role="status">{row.caption ?? ''}</span>
        </li>
      {/each}
    </ul>
    {#if capture?.permissions?.camera === 'denied'}
      <p class="caption empty">Camera denied: allow Fanous under System Settings › Privacy & Security › Camera.</p>
    {/if}
    {#if tc.source === 'ltc' && capture?.permissions?.microphone === 'denied'}
      <p class="caption empty">Microphone denied: allow Fanous under System Settings › Privacy & Security › Microphone.</p>
    {/if}
    {#if (capture?.screens?.length ?? 0) > 0}
      <p class="caption empty">Screen recording: macOS asks again about once a month; before a show, check the readiness item Screen recording granted on the System screen.</p>
    {/if}
  </section>
{/if}

<div class="cols">
  <section class="list" aria-label="Inputs">
    {#each groups as group (group.kind)}
      <div class="head">
        <h2>{group.title}</h2>
        {#if group.kind === 'syphon' && group.notRunning > 1}
          <button class="btn" disabled={editLock !== undefined} title={editLock ?? 'Free the numbers of every server that is not running (undo brings them back)'}
            onclick={() => void forget(group.kind)}>Forget all not running</button>
        {:else if group.kind === 'capture' && captureNotRunning > 1}
          <button class="btn" disabled={editLock !== undefined} title={editLock ?? 'Free the numbers of every camera, capture card and display that is not running (undo brings them back)'}
            onclick={() => void forget(group.kind)}>Forget all not running (cameras and displays)</button>
        {/if}
      </div>
      {#if group.kind === 'syphon' && unnumbered.length > 0}
        <p class="caption" role="status">Not numbered, all 20 numbers are taken: {unnumbered.join(', ')}. Forget a server that is not running to free one.</p>
      {/if}
      {#if group.kind === 'screen'}
        <p class="caption">A display used as a Fanous output reads not running (one that was an output from the start gets no number).</p>
      {/if}
      {#if group.list.length === 0}
        <p class="caption">{group.kind === 'capture'
          ? 'No cameras or capture cards found. One connected to this Mac appears here with the lowest free number from 1; it keeps that number, also across engine restarts, until you forget it here.'
          : 'No Syphon servers running. When another app on this Mac starts one, it appears here with the lowest free number from 150; it keeps that number, also across engine restarts, until you forget it here.'}</p>
      {:else}
        <ul class="panel" aria-label={group.title}>
          {#each group.list as item (item.file)}
            {@const layer = openOn(item.file)}
            {@const caption = layer && item.running ? signalText(layer) : zeroCaption(item)}
            <li>
              <button class="list-row" class:dim={item.gone} aria-pressed={picked?.file === item.file} onclick={() => go('inputs', picked?.file === item.file ? '' : String(item.file), true)}>
                <span class="num mono">{item.file}</span>
                <span class="dot {item.inUse ? 'dot-yellow' : item.running ? 'dot-green' : 'dot-off'}" aria-hidden="true"></span>
                <span class="ellipsis grow" title={item.name}>{item.name}</span>
                {#if caption}<span class="caption">{caption}</span>{/if}
                {#each showing.get(`0/${item.file}`) ?? [] as on (on)}<span class="badge badge-accent">{on}</span>{/each}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    {/each}
    <div class="head"><h2>Audio inputs</h2></div>
    {#if audioInputs.length === 0}
      <p class="caption">No audio inputs found. An audio interface or microphone connected to this Mac appears here; LTC timecode comes in on one of its channels.</p>
    {:else}
      <ul class="panel" aria-label="Audio inputs">
        {#each audioInputs as input (input.name)}
          <li>
            <button class="list-row" aria-pressed={pickedAudio?.name === input.name} onclick={() => go('inputs', pickedAudio?.name === input.name ? '' : audioKey(input), true)}>
              <span class="num"></span>
              <span class="ellipsis grow" title={input.name}>{input.name}</span>
              <span class="caption">{input.channels} {input.channels === 1 ? 'channel' : 'channels'}{input.default ? ' · default' : ''}</span>
              {#if ltc?.device === input.name}<span class="badge badge-accent">Timecode (LTC, channel {ltc.channel + 1})</span>{/if}
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </section>

  <aside class="panel detail" aria-label="Selected input">
    {#if picked}
      {@const layer = openOn(picked.file)}
      {@const on = showing.get(`0/${picked.file}`) ?? []}
      <header class="phead"><h2 class="ellipsis" title={picked.name}>{picked.file} · {picked.name}</h2></header>
      <dl class="kv">
        <dt>Kind</dt>
        <dd>{KIND[picked.kind]}</dd>
        {#if model(picked)}
          <dt>Model</dt>
          <dd>{model(picked)}</dd>
        {/if}
        <dt>Status</dt>
        <dd class="status"><span class="dot {picked.inUse ? 'dot-yellow' : picked.running ? 'dot-green' : 'dot-off'}" aria-hidden="true"></span>{statusWord(picked)}</dd>
        <dt>Shown on</dt>
        <dd>{#each on as l (l)}<span class="badge badge-accent">{l}</span> {:else}no layer{/each}</dd>
        {#if layer}
          <dt>Signal</dt>
          <dd class="mono">{signalText(layer)}</dd>
          {#if layer.capture}
            <dt>Frames</dt>
            <dd class="mono">{layer.capture.frames} · {layer.capture.dropped} dropped · {layer.capture.outOfBuffers} out of buffers · {layer.capture.unusable} unusable</dd>
          {/if}
        {:else}
          <dt>Signal</dt>
          <dd class="muted">not open: no layer shows it</dd>
        {/if}
      </dl>
      {#if !picked.running && !picked.inUse}
        <div class="actions">
          <button class="btn" disabled={editLock !== undefined} title={editLock ?? `Free this number: a console cue on it then selects the next new ${NOUN[picked.kind]} (undo brings it back)`}
            onclick={() => void forget(picked.kind, picked.file)}>Forget</button>
        </div>
      {/if}
    {:else if pickedAudio}
      {@const used = ltc?.device === pickedAudio.name}
      {@const live = app.live.timecode}
      {@const badge = timecodeBadge(live.state)}
      {@const channel = channelPick[pickedAudio.name] ?? (used ? ltc!.channel : 0)}
      <header class="phead"><h2 class="ellipsis" title={pickedAudio.name}>{pickedAudio.name}</h2></header>
      <dl class="kv">
        <dt>Kind</dt>
        <dd>Audio input{pickedAudio.default ? ' (system default)' : ''}</dd>
        <dt>Channels</dt>
        <dd class="mono">{pickedAudio.channels}</dd>
        <dt>Timecode</dt>
        {#if used}
          <dd>
            <div>LTC on channel {ltc!.channel + 1}</div>
            <div class="status"><span class="pill pill-{badge.tone}"><span class="dot"></span>{badge.label}</span> <span class="mono">{live.value}</span> <span class="caption">{live.rate}</span></div>
            <LevelMeter level={live.level} label="LTC level" none={ltcOn ? 'LTC not open' : 'timecode switched off'} />
          </dd>
        {:else}
          <dd class="muted">not used</dd>
        {/if}
      </dl>
      <div class="actions">
        <label class="field">
          <span>Channel</span>
          <select class="select" value={channel} disabled={editLock !== undefined} onchange={(e) => (channelPick[pickedAudio.name] = Number(e.currentTarget.value))}>
            {#each Array.from({ length: pickedAudio.channels }, (_, i) => i) as c (c)}<option value={c}>{c + 1}</option>{/each}
          </select>
        </label>
        <button class="btn" disabled={editLock !== undefined || (used && ltc!.channel === channel && tc.device === pickedAudio.name)} title={editLock ?? 'Set the timecode source to LTC on this device and channel (Show › Timecode has the rest; undo takes it back)'}
          onclick={() => useForTimecode(pickedAudio, channel)}>Use for timecode</button>
      </div>
    {:else}
      <p class="caption empty">Select an input to see its status. An input is opened only while a layer shows it: opening a camera just to look could take it from another app.</p>
    {/if}
  </aside>
</div>

<style>
  .cols { display: flex; gap: 16px; align-items: flex-start; }
  .list { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }
  .detail { flex: 0 0 360px; min-width: 0; position: sticky; top: 16px; }
  .head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
  .head h2 { margin: 0; font-size: 15px; }
  ul { list-style: none; margin: 0; padding: 0; }
  .item { flex-wrap: wrap; gap: 8px 12px; padding: 8px 16px; }
  .item:last-child { border-bottom: 0; }
  .empty { margin: 0; padding: 8px 16px 12px; }
  .grow { flex: 1 1 140px; min-width: 0; }
  .num { flex: 0 0 3ch; text-align: right; }
  .list-row.dim { color: var(--text-3); }
  .status { display: flex; align-items: center; gap: 6px; }
  .actions { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 8px; padding: 0 16px 16px; }
  .actions .select { min-width: 80px; }
  @media (max-width: 900px) {
    .cols { flex-direction: column; align-items: stretch; }
    .detail { flex-basis: auto; position: static; }
  }
</style>
