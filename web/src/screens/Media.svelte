<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { untrack } from 'svelte';
  import MediaIngestQueue from '../components/MediaIngestQueue.svelte';
  import MediaTile from '../components/MediaTile.svelte';
  import PolicyHint from '../components/PolicyHint.svelte';
  import { app, authHeaders, can, cmd, playOnLayer } from '../lib/state.svelte';
  import {
    LOCKED_TITLE,
    activeSources,
    defaultFolder,
    displayName,
    filterItems,
    invalidCount,
    send,
    type LibraryItem,
    type LibrarySnapshot,
  } from '../lib/media';
  import { ZERO_GROUPS, folderZeroItems, zeroCaption, type FolderZeroItem } from '../lib/layers';
  import { lockTitle } from '../lib/show';

  interface Upload {
    name: string;
    status: 'waiting' | 'uploading' | 'queued' | 'failed';
    error?: string;
  }

  let library = $state.raw<LibrarySnapshot | null>(null);
  let loads = $state(0);
  let notice = $state('');
  let rescanning = $state(false);
  let selectedFolder = $state<string | null>(null); // path: invalid folders have no number
  let selectedItem = $state<string | null>(null);
  let query = $state('');
  let uploads = $state<Upload[]>([]);
  let uploading = $state(false);
  let picker = $state<HTMLInputElement>(); // bound inside the {#if}: reactive, or svelte-check warns
  let latest = 0;
  let creating = $state(false);
  let newNumber = $state(1);
  let newName = $state('');

  /** Folder 0 (generators, capture devices and Syphon servers, B61, B73) is not a library folder; this stands for it in `selectedFolder`. */
  const ZERO = '#0';
  const isZero = $derived(selectedFolder === ZERO);
  /** absent from engines before B73 step 2: then no camera or display group */
  const capture = $derived(app.live.capture);
  const zeroItems = $derived(folderZeroItems(app.live.syphon?.servers, capture));
  const zeroGroups = $derived(
    ZERO_GROUPS.map((g) => {
      const list = zeroItems.filter((i) => i.kind === g.kind);
      // live inputs not running (in use counts as running): their numbers can be forgotten (B69, B73)
      return { ...g, list, notRunning: list.filter((i) => !i.running && !i.inUse).length };
    }).filter((g) => (g.kind === 'capture' ? capture !== undefined : g.kind === 'screen' ? g.list.length > 0 : true)),
  );
  const cameraPermission = $derived(capture?.permissions?.camera);
  const screenPermission = $derived(capture?.permissions?.screen);
  const NOUN = { syphon: 'server', capture: 'device', screen: 'display', generator: '' } as const;
  // capture.forget without a file sweeps cameras and displays (1–28) at once, so one button above the cameras covers both
  const captureNotRunning = $derived(zeroGroups.filter((g) => g.kind === 'capture' || g.kind === 'screen').reduce((n, g) => n + g.notRunning, 0));
  let pickedZero = $state<number | null>(null);
  const pickedZeroItem = $derived(zeroItems.find((i) => i.file === pickedZero));
  function forget(kind: FolderZeroItem['kind'], file?: number) {
    const args = file === undefined ? {} : { file };
    return kind === 'syphon' ? cmd('syphon.forget', args) : cmd('capture.forget', args);
  }
  const unnumbered = $derived(app.live.syphon?.unnumbered ?? []);
  const folders = $derived(library?.folders ?? []);
  const current = $derived(isZero ? undefined : (folders.find((f) => f.path === selectedFolder) ?? defaultFolder(folders)));
  const items = $derived(current?.items ?? []);
  const shown = $derived(filterItems(items, query));
  const invalid = $derived(invalidCount(items));
  const probing = $derived(folders.some((f) => f.items.some((i) => i.status === 'probing')));
  const inFlight = $derived(activeSources(app.live.ingest));
  const locked = $derived(!can('programmer'));
  const picked = $derived(shown.find((i) => i.path === selectedItem));
  const playable = $derived(picked !== undefined && picked.file !== null && current?.number != null && picked.status === 'playable');
  const layerNumbers = $derived(Array.from({ length: Math.max(0, Math.floor(app.project.layerCount) || 0) }, (_, i) => i + 1));
  const playLock = $derived(lockTitle('programmer', !locked, app.project.showLock));
  let playNote = $state('');

  async function play(n: number, folder: number, file: number, name: string) {
    const ok = await playOnLayer(n, folder, file);
    playNote = ok ? `Layer ${n} now ${folder === 0 ? 'shows' : 'plays'} ${folder} / ${file} · ${name}.` : '';
  }
  const canImport = $derived(current?.number != null);
  /** "folder/file" → the layers playing it, for the tile badge */
  const playing = $derived.by(() => {
    const map = new Map<string, string[]>();
    for (const layer of app.live.layers) {
      if (layer.folder >= 0 && layer.file > 0) map.set(`${layer.folder}/${layer.file}`, [...(map.get(`${layer.folder}/${layer.file}`) ?? []), `Layer ${layer.index}`]);
    }
    return map;
  });
  const nextFolderNumber = $derived.by(() => {
    const used = new Set(folders.map((f) => f.number));
    for (let n = 1; n <= 255; n++) if (!used.has(n)) return n;
    return 0;
  });

  async function load() {
    const mine = ++latest;
    try {
      const response = await fetch('/api/library');
      if (!response.ok) throw new Error(`${response.status} ${(await response.text()).trim()}`.trim());
      const snapshot = (await response.json()) as LibrarySnapshot;
      if (mine === latest) library = snapshot;
    } catch (error) {
      if (mine === latest) notice = `Cannot load the library: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      if (mine === latest) loads++;
    }
  }

  // Every rescan (a file landed, Rescan pressed) bumps scannedAt in the live document.
  $effect(() => {
    void app.live.library.scannedAt;
    untrack(() => void load());
  });

  // Metadata and thumbnails arrive after the scan without a new scannedAt: poll while anything is still probing.
  $effect(() => {
    void loads;
    if (!probing) return;
    const timer = setTimeout(() => void load(), 2000);
    return () => clearTimeout(timer);
  });

  function startCreate() {
    newNumber = nextFolderNumber;
    newName = '';
    creating = true;
  }

  async function createFolder(event: SubmitEvent) {
    event.preventDefault();
    const error = await send('/api/library/folder', {
      method: 'POST', headers: { ...authHeaders(), 'Content-Type': 'application/json' }, body: JSON.stringify({ number: newNumber, name: newName.trim() }),
    });
    if (error) {
      notice = `Cannot create the folder: ${error}`;
      return;
    }
    creating = false;
    await load();
    selectedFolder = folders.find((f) => f.number === newNumber)?.path ?? selectedFolder;
  }

  async function rescan() {
    rescanning = true;
    const error = await send('/api/library/rescan', { method: 'POST', headers: authHeaders() });
    if (error) notice = `Rescan failed: ${error}`;
    rescanning = false;
    await load();
  }

  async function transcode(item: LibraryItem, codec: string) {
    const body = { source: item.path, folder: current?.number, file: item.file, name: item.name, codec, ...(item.kind === 'sequence' ? { fps: 25 } : {}) };
    const error = await send('/api/ingest', { method: 'POST', headers: { ...authHeaders(), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    if (error) notice = `Cannot transcode ${item.name}: ${error}`;
  }

  async function upload(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const files = Array.from(input.files ?? []);
    input.value = ''; // the same file can be picked again
    const folder = current?.number;
    if (files.length === 0 || folder == null) return;
    uploading = true;
    uploads = files.map((file) => ({ name: file.name, status: 'waiting' }));
    for (const [index, file] of files.entries()) {
      uploads[index].status = 'uploading';
      const error = await send(`/api/upload/${folder}/${encodeURIComponent(file.name)}`, { method: 'PUT', body: file, headers: authHeaders() });
      uploads[index] = error ? { name: file.name, status: 'failed', error } : { name: file.name, status: 'queued' };
    }
    uploading = false;
  }
</script>

{#snippet playMenu(folder: number, file: number, name: string)}
  <select class="select" aria-label="Play on layer" disabled={playLock !== undefined || layerNumbers.length === 0} title={playLock} value="" onchange={(e) => {
    const n = Number(e.currentTarget.value);
    e.currentTarget.value = '';
    if (n) void play(n, folder, file, name);
  }}>
    <option value="">Play on layer ▾</option>
    {#each layerNumbers as n (n)}<option value={n}>Layer {n}</option>{/each}
  </select>
{/snippet}

<div class="media">
  {#if notice}
    <div class="banner banner-yellow" role="alert">
      <span class="dot dot-yellow"></span>
      <span>{notice}</span>
      <span class="spacer"></span>
      <button class="btn btn-ghost" onclick={() => (notice = '')}>Dismiss</button>
    </div>
  {/if}
  {#if library && !library.rootExists}
    <div class="banner banner-yellow" role="status">
      <span class="dot dot-yellow"></span>
      <span>The library root does not exist: <span class="mono">{library.root}</span></span>
    </div>
  {/if}

  <div class="cols">
    <aside class="panel lib" aria-labelledby="lib-title">
      <header>
        <div class="grow">
          <h2 id="lib-title">Library</h2>
          <div class="caption mono ellipsis" title={library?.root ?? app.live.library.root}>{library?.root ?? app.live.library.root}</div>
        </div>
        <button class="btn btn-icon" aria-label="Rescan" title="Rescan the library" disabled={rescanning} onclick={rescan}>
          <svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 4v6h-6M20.49 15a9 9 0 1 1-2.12-9.36L23 10" /></svg>
        </button>
      </header>
      {#if creating}
        <form class="create" onsubmit={createFolder}>
          <label class="field"><span>Number</span><input class="input mono" type="number" min="1" max="255" bind:value={newNumber} required /></label>
          <label class="field grow"><span>Name</span><input class="input" type="text" bind:value={newName} placeholder="Intro" required /></label>
          <div class="create-actions">
            <button type="button" class="btn btn-ghost" onclick={() => (creating = false)}>Cancel</button>
            <button type="submit" class="btn btn-primary">Create</button>
          </div>
        </form>
      {/if}
      <ul>
        <li>
          <button class="list-row" aria-pressed={isZero} onclick={() => (selectedFolder = ZERO)}>
            <span class="num mono">0</span>
            <span class="ellipsis grow">Built-in and live inputs</span>
            <span class="mono faint">{zeroItems.length}</span>
          </button>
        </li>
      </ul>
      {#if folders.length === 0}
        <p class="caption pad">{library ? 'No folders yet. Press New folder below to create the first one (the console addresses folders by number), then Import… to add files.' : 'Loading…'}</p>
      {:else}
        <ul>
          {#each folders as folder (folder.path)}
            {@const bad = invalidCount(folder.items)}
            <li>
              <button class="list-row" class:dim={folder.number === null} aria-pressed={folder.path === current?.path} onclick={() => (selectedFolder = folder.path)}>
                <span class="num mono">{folder.number ?? ''}</span>
                <span class="ellipsis grow" title={folder.name}>{displayName(folder.name, folder.number !== null)}</span>
                {#if bad > 0}<span class="badge badge-err">{bad} invalid</span>{/if}
                <span class="mono faint">{folder.items.length}</span>
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <div class="pad">
        <button class="btn" disabled={locked || creating || nextFolderNumber === 0} title={locked ? LOCKED_TITLE : undefined} onclick={startCreate}>New folder</button>
      </div>
      <p class="caption pad">Folders 1–255 are addressable from the console. Names without a number prefix are listed but never resolved.</p>
    </aside>

    <section class="main" aria-label="Files">
      {#if isZero}
      <div class="toolbar">
        <div>
          <h1>0 · Built-in and live inputs</h1>
          <div class="caption">Drawn by the engine, the cameras, capture cards and displays of this Mac, and the Syphon servers of other apps. A console selects them as folder 0, file n.</div>
        </div>
      </div>
      {#if pickedZeroItem}
        <div class="panel playbar" role="group" aria-label="Selected item">
          <span class="ellipsis grow" title={pickedZeroItem.name}><strong>{pickedZeroItem.file}</strong> · {pickedZeroItem.name}</span>
          {@render playMenu(0, pickedZeroItem.file, pickedZeroItem.name)}
          {#if pickedZeroItem.kind !== 'generator' && !pickedZeroItem.running && !pickedZeroItem.inUse}
            <button class="btn" disabled={playLock !== undefined} title={playLock ?? `Free this number: a console cue on it then selects the next new ${NOUN[pickedZeroItem.kind]} (undo brings it back)`}
              onclick={() => void forget(pickedZeroItem.kind, pickedZeroItem.file)}>Forget</button>
          {/if}
        </div>
        <PolicyHint what="content put on a layer from here" />
        {#if playNote}<p class="caption" role="status">{playNote}</p>{/if}
      {/if}
      {#each zeroGroups as group (group.kind)}
        <div class="zero-head">
          <h2 class="zero-title">{group.title}</h2>
          {#if group.kind === 'syphon' && group.notRunning > 1}
            <button class="btn" disabled={playLock !== undefined} title={playLock ?? 'Free the numbers of every server that is not running (undo brings them back)'}
              onclick={() => void forget(group.kind)}>Forget all not running</button>
          {:else if group.kind === 'capture' && captureNotRunning > 1}
            <button class="btn" disabled={playLock !== undefined} title={playLock ?? 'Free the numbers of every camera, capture card and display that is not running (undo brings them back)'}
              onclick={() => void forget(group.kind)}>Forget all not running (cameras and displays)</button>
          {/if}
        </div>
        {#if group.kind === 'syphon' && unnumbered.length > 0}
          <p class="caption" role="status">Not numbered, all 20 numbers are taken: {unnumbered.join(', ')}. Forget a server that is not running to free one.</p>
        {/if}
        {#if group.kind === 'capture' && cameraPermission && cameraPermission !== 'granted'}
          <p class="caption" role="status">{cameraPermission === 'denied' ? 'Camera permission denied: allow Fanous under Privacy & Security › Camera.' : 'Camera permission not granted: authorize on the System screen.'}</p>
        {/if}
        {#if group.kind === 'screen'}
          {#if screenPermission && screenPermission !== 'granted'}
            <p class="caption" role="status">Screen permission not granted: authorize on the System screen, then Engine › Restart Engine.</p>
          {/if}
          <p class="caption">A display used as a Fanous output reads not running (one that was an output from the start gets no number). macOS asks again about once a month whether Fanous may record the screen: see Capture permissions on the <a href="#/system">System screen</a>.</p>
        {/if}
        {#if group.list.length === 0}
          <p class="caption">{group.kind === 'capture'
            ? 'No cameras or capture cards found. One connected to this Mac appears here with the lowest free number from 1; it keeps that number, also across engine restarts, until you forget it here.'
            : 'No Syphon servers running. When another app on this Mac starts one, it appears here with the lowest free number from 150; it keeps that number, also across engine restarts, until you forget it here.'}</p>
        {:else}
          <ul class="panel zero" aria-label={group.title}>
            {#each group.list as item (item.file)}
              {@const on = playing.get(`0/${item.file}`) ?? []}
              <li>
                <button class="list-row" class:dim={item.gone} aria-pressed={pickedZero === item.file} onclick={() => (pickedZero = pickedZero === item.file ? null : item.file)}>
                  <span class="num mono">{item.file}</span>
                  {#if item.kind !== 'generator'}<span class="dot {item.inUse ? 'dot-yellow' : item.running ? 'dot-green' : 'dot-off'}" aria-hidden="true"></span>{/if}
                  <span class="ellipsis grow" title={item.name}>{item.name}</span>
                  {#if zeroCaption(item)}<span class="caption">{zeroCaption(item)}</span>{/if}
                  {#each on as layer (layer)}<span class="badge badge-accent">{layer}</span>{/each}
                </button>
              </li>
            {/each}
          </ul>
        {/if}
      {/each}
      {:else}
      <div class="toolbar">
        <div>
          <h1>{current ? (current.number === null ? current.name : `${current.number} · ${displayName(current.name, true)}`) : 'Media'}</h1>
          {#if current}
            <div class="caption">{items.length} {items.length === 1 ? 'file' : 'files'}{invalid > 0 ? ` · ${invalid} invalid name` : ''}</div>
          {/if}
        </div>
        <span class="spacer"></span>
        <label class="search">
          <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 3a8 8 0 1 0 0 16 8 8 0 0 0 0-16zM21 21l-4.3-4.3" /></svg>
          <span class="sr">Search files</span>
          <input type="search" placeholder="Search files" autocomplete="off" bind:value={query} />
        </label>
        <button
          class="btn btn-primary"
          disabled={locked || uploading || !canImport}
          title={locked ? LOCKED_TITLE : !canImport ? 'Select a numbered folder to import into' : undefined}
          onclick={() => picker?.click()}>{uploading ? 'Uploading…' : 'Import…'}</button
        >
        <input type="file" multiple hidden bind:this={picker} onchange={upload} />
      </div>

      {#if picked}
        <div class="panel playbar" role="group" aria-label="Selected file">
          <span class="ellipsis grow" title={picked.name}><strong>{picked.file ?? '—'}</strong> · {picked.name}</span>
          {#if playable}
            {@render playMenu(current!.number!, picked.file!, picked.name)}
          {:else}
            <span class="caption">{picked.status === 'needsTranscode' ? 'Transcode this file first to play it.' : 'This file cannot be played on a layer.'}</span>
          {/if}
        </div>
        {#if playable}<PolicyHint what="files put on a layer from here" />{/if}
        {#if playNote}<p class="caption" role="status">{playNote}</p>{/if}
      {/if}

      {#if uploads.length > 0}
        <ul class="uploads panel" aria-label="Uploads">
          {#each uploads as file, index (index)}
            <li>
              <span class="ellipsis grow" title={file.name}>{file.name}</span>
              <span class="mono" class:fail={file.status === 'failed'} class:run={file.status === 'uploading'}>{file.status}</span>
              {#if file.error}<span class="caption fail">{file.error}</span>{/if}
            </li>
          {/each}
          {#if !uploading}
            <li class="end"><button class="btn btn-ghost" onclick={() => (uploads = [])}>Clear</button></li>
          {/if}
        </ul>
      {/if}

      {#if !current}
        <p class="caption">{library ? 'Nothing to show.' : 'Loading the library…'}</p>
      {:else if shown.length === 0}
        <p class="caption">{items.length === 0 ? (canImport ? 'No files in this folder. Press Import… to add files, or copy them into the folder on disk; the list updates by itself.' : 'No files here. Select a numbered folder, then press Import….') : `No files match "${query.trim()}".`}</p>
      {:else}
        <div class="grid">
          {#each shown as item (item.path)}
            <MediaTile
              {item}
              selected={selectedItem === item.path}
              pending={inFlight.has(item.path)}
              onLayers={item.file === null ? [] : (playing.get(`${item.folder}/${item.file}`) ?? [])}
              onselect={() => (selectedItem = selectedItem === item.path ? null : item.path)}
              ontranscode={transcode}
            />
          {/each}
        </div>
      {/if}
      {/if}
    </section>
  </div>

  <MediaIngestQueue onfail={(message) => (notice = message)} />
</div>

<style>
  .media { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
  .cols { display: flex; gap: 16px; align-items: flex-start; }
  .lib { flex: 0 0 250px; min-width: 0; }
  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
  .grow { flex: 1; min-width: 0; }
  .lib header { display: flex; align-items: center; gap: 12px; padding: 12px; border-bottom: 1px solid var(--line); }
  .lib ul { list-style: none; margin: 0; padding: 0; }
  .lib .pad { margin: 0; padding: 12px; }
  .num { flex: 0 0 3ch; text-align: right; }
  .create { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 8px; padding: 12px; border-bottom: 1px solid var(--line); }
  .create .input { width: 100%; }
  .create .field:first-child { flex: 0 0 72px; }
  .create-actions { display: flex; gap: 8px; width: 100%; justify-content: flex-end; }
  .list-row.dim { color: var(--text-3); }
  .search { position: relative; display: flex; align-items: center; gap: 8px; min-height: var(--touch); padding: 0 12px; border-radius: var(--radius-control); border: 1px solid var(--line-strong); background: var(--surface-2); color: var(--text-3); }
  .search:focus-within { border-color: var(--accent); }
  .search input { flex: 1; min-width: 0; width: 200px; height: 40px; border: 0; background: transparent; color: var(--text-1); font-size: 15px; outline: none; }
  .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
  .uploads { list-style: none; margin: 0; padding: 4px 12px; font-size: 13px; }
  .uploads li { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 12px; min-height: 32px; }
  .uploads li.end { justify-content: flex-end; }
  .run { color: var(--accent); }
  .fail { color: var(--red); }
  .playbar { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 8px 12px; }
  .playbar .select { min-width: 180px; }
  .zero-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
  .zero-title { margin: 0; font-size: 15px; }
  .zero { list-style: none; margin: 0; padding: 0; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }
  @media (max-width: 900px) {
    .cols { flex-direction: column; align-items: stretch; }
    .lib { flex-basis: auto; }
    .search { flex: 1 1 200px; }
    .search input { width: 100%; }
  }
</style>
