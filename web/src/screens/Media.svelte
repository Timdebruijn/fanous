<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { untrack } from 'svelte';
  import MediaIngestQueue from '../components/MediaIngestQueue.svelte';
  import MediaTile from '../components/MediaTile.svelte';
  import { app, authHeaders, can } from '../lib/state.svelte';
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
  let picker: HTMLInputElement | undefined;
  let latest = 0;

  const folders = $derived(library?.folders ?? []);
  const current = $derived(folders.find((f) => f.path === selectedFolder) ?? defaultFolder(folders));
  const items = $derived(current?.items ?? []);
  const shown = $derived(filterItems(items, query));
  const invalid = $derived(invalidCount(items));
  const probing = $derived(folders.some((f) => f.items.some((i) => i.status === 'probing')));
  const inFlight = $derived(activeSources(app.live.ingest));
  const locked = $derived(!can('programmer'));
  const canImport = $derived(current?.number != null);

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
      {#if folders.length === 0}
        <p class="caption pad">{library ? 'No folders in the library.' : 'Loading…'}</p>
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
      <p class="caption pad">Folders 1–255 are addressable from the console. Names without a number prefix are listed but never resolved.</p>
    </aside>

    <section class="main" aria-label="Files">
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
        <p class="caption">{items.length === 0 ? 'No files in this folder.' : `No files match "${query.trim()}".`}</p>
      {:else}
        <div class="grid">
          {#each shown as item (item.path)}
            <MediaTile
              {item}
              selected={selectedItem === item.path}
              pending={inFlight.has(item.path)}
              onselect={() => (selectedItem = selectedItem === item.path ? null : item.path)}
              ontranscode={transcode}
            />
          {/each}
        </div>
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
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }
  @media (max-width: 900px) {
    .cols { flex-direction: column; align-items: stretch; }
    .lib { flex-basis: auto; }
    .search { flex: 1 1 200px; }
    .search input { width: 100%; }
  }
</style>
