<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, can, cmd } from '../lib/state.svelte';
  import { LOCKED_TITLE } from '../lib/system';
  import { type ProjectVersion, parseVersions, revertBlocked, versionSummary, versionTime } from '../lib/versions';

  // Project versions (B23): the engine saves automatic ones; a named one is saved here and never expires.
  let versions = $state.raw<ProjectVersion[]>([]);
  const lockedProgrammer = $derived(!can('programmer'));
  const blocked = $derived(revertBlocked({ programmer: can('programmer'), showLock: app.project.showLock, showMode: app.live.show.mode }));
  const serial = $derived(app.live.versions?.serial ?? 0);

  async function refresh() {
    const result = await cmd('project.versions');
    if (result !== undefined) versions = parseVersions(result);
  }
  // again whenever the engine saved or deleted one (the serial in live)
  $effect(() => {
    void serial;
    void refresh();
  });

  let saveDialog: HTMLDialogElement | undefined = $state();
  let name = $state('');
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (name.trim() === '') return;
    if ((await cmd('project.snapshot', { name: name.trim() })) !== undefined) {
      name = '';
      saveDialog?.close();
    }
  }

  let revertDialog: HTMLDialogElement | undefined = $state();
  let target = $state<ProjectVersion | null>(null);
  function askRevert(version: ProjectVersion) {
    target = version;
    revertDialog?.showModal();
  }
  async function revert() {
    if (!target) return;
    if ((await cmd('project.revert', { id: target.id })) !== undefined) revertDialog?.close();
  }

  function remove(version: ProjectVersion) {
    if (confirm(`Delete the version “${version.name}”? This cannot be undone.`)) void cmd('project.deleteVersion', { id: version.id });
  }
</script>

<section class="panel" aria-labelledby="versions-title">
  <header class="phead">
    <h2 id="versions-title">Project versions</h2>
    <span class="caption">Saved at engine start, on entering show mode and every 10 minutes after a change (newest 50 kept). Named versions never expire.</span>
    <span class="spacer"></span>
    <button type="button" class="btn" disabled={lockedProgrammer} title={lockedProgrammer ? LOCKED_TITLE : undefined} onclick={() => saveDialog?.showModal()}>Save version…</button>
  </header>
  <ul>
    {#each versions as v (v.id)}
      <li class="list-row item">
        <span class="mono time">{versionTime(v.at)}</span>
        <div class="grow">
          <div class="ellipsis" title={v.name}>{v.name}</div>
          <div class="caption">{versionSummary(v)}</div>
        </div>
        {#if v.automatic}<span class="badge badge-outline">automatic</span>{:else}<span class="badge badge-accent">named</span>{/if}
        <button type="button" class="btn" disabled={blocked !== null} title={blocked ?? undefined} onclick={() => askRevert(v)}>Revert…</button>
        {#if !v.automatic}
          <button type="button" class="btn btn-danger" disabled={lockedProgrammer || app.project.showLock} title={lockedProgrammer ? LOCKED_TITLE : app.project.showLock ? 'The show is locked' : undefined} onclick={() => remove(v)}>Delete</button>
        {/if}
      </li>
    {:else}
      <li class="caption empty">No versions yet. The engine saves one at its next start, on entering show mode and every 10 minutes after a change; save a named one before doors.</li>
    {/each}
  </ul>
</section>

<dialog bind:this={saveDialog} class="panel" aria-labelledby="save-version-title">
  <form onsubmit={save}>
    <h2 id="save-version-title">Save version</h2>
    <p class="caption">A named version of the project as it is now. It is kept until you delete it.</p>
    <label class="field">
      <span>Name</span>
      <input class="input" type="text" maxlength="80" autocomplete="off" placeholder="Before doors" bind:value={name} />
    </label>
    <div class="actions">
      <span class="spacer"></span>
      <button type="button" class="btn" onclick={() => saveDialog?.close()}>Cancel</button>
      <button type="submit" class="btn btn-primary" disabled={name.trim() === ''}>Save</button>
    </div>
  </form>
</dialog>

<dialog bind:this={revertDialog} class="panel" aria-labelledby="revert-title" onclose={() => (target = null)}>
  <form onsubmit={(event) => { event.preventDefault(); void revert(); }}>
    <h2 id="revert-title">Revert to “{target?.name ?? ''}”?</h2>
    {#if target}
      <p class="caption">{versionTime(target.at)} · {versionSummary(target)}</p>
    {/if}
    <p>The project goes back to this version: layers, patch, outputs, canvases and cues. The current project is saved as a version first, and Undo takes the revert back.</p>
    <div class="actions">
      <span class="spacer"></span>
      <button type="button" class="btn" onclick={() => revertDialog?.close()}>Cancel</button>
      <button type="submit" class="btn btn-primary" disabled={blocked !== null}>Revert</button>
    </div>
  </form>
</dialog>

<style>
  .phead { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; padding: 12px 16px; }
  ul { list-style: none; margin: 0; padding: 0; max-height: 420px; overflow-y: auto; }
  .item { flex-wrap: wrap; gap: 8px 12px; padding: 8px 16px; }
  .item:last-child { border-bottom: 0; }
  .time { flex: 0 0 110px; }
  .grow { flex: 1 1 160px; min-width: 0; }
  .empty { margin: 0; padding: 8px 16px 12px; }
  dialog { width: min(440px, calc(100vw - 32px)); padding: 24px; color: var(--text-1); border: 1px solid var(--line-strong); }
  dialog::backdrop { background: rgba(11, 12, 14, 0.7); }
  form { display: flex; flex-direction: column; gap: 14px; }
  form p, form h2 { margin: 0; overflow-wrap: anywhere; }
  .field .input { width: 100%; text-align: left; }
  .actions { display: flex; gap: 8px; align-items: center; }
</style>
