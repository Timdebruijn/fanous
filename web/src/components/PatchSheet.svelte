<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { SHEET_HEADER, sheetFaults, sheetRows, sheetTSV, type Group } from '../lib/patch-screen';
  import { app } from '../lib/state.svelte';

  // The Patch sheet (DESIGN §6.6 item 4): what to patch on the console, with Print and Copy. Read-only, for every role.
  let { groups, onclose }: { groups: Group[]; onclose: () => void } = $props();

  // Count Art-Net universes from 1, remembered per browser (default off)
  const FROM_ONE_KEY = 'fanous.artnetFromOne';
  function storedFromOne(): boolean {
    try {
      return localStorage.getItem(FROM_ONE_KEY) === '1';
    } catch {
      return false;
    }
  }
  let fromOne = $state(storedFromOne());
  function setFromOne(on: boolean) {
    fromOne = on;
    try {
      localStorage.setItem(FROM_ONE_KEY, on ? '1' : '0');
    } catch {
      // private mode or blocked storage: the choice lasts for this page only
    }
  }

  const rows = $derived(sheetRows(groups, fromOne, app.project.universes));
  const faults = $derived(sheetFaults(groups));
  const base = $derived(fromOne ? 1 : 0);

  let dialog: HTMLDialogElement | undefined = $state();
  $effect(() => {
    dialog?.showModal();
  });

  let copy = $state<'idle' | 'ok' | 'failed'>('idle');
  async function copySheet() {
    try {
      await navigator.clipboard.writeText(sheetTSV(rows));
      copy = 'ok';
    } catch {
      copy = 'failed';
    }
  }
  $effect(() => {
    if (copy === 'idle') return;
    const timer = setTimeout(() => (copy = 'idle'), 2500);
    return () => clearTimeout(timer);
  });
</script>

<dialog bind:this={dialog} class="panel patch-sheet" {onclose} aria-labelledby="sheet-title">
  <!-- svelte-ignore a11y_autofocus -->
  <h2 id="sheet-title" tabindex="-1" autofocus>Patch sheet</h2>
  <p class="caption">
    Import Fanous.gdtf (Export GDTF) on the console and patch these modes. Art-Net universes counted from {base}: A 0.0.0 = universe {base}. sACN
    universes as numbered.
  </p>
  {#if rows.length > 0}
    <div class="scroll">
      <table>
        <thead>
          <tr>
            {#each SHEET_HEADER as h (h)}<th scope="col">{h}</th>{/each}
          </tr>
        </thead>
        <tbody>
          {#each rows as cells (cells[0])}
            <tr>
              {#each cells as cell, i (i)}<td>{cell}</td>{/each}
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
    {#if faults > 0}
      <p class="alert">
        {faults === 1 ? '1 fixture collides or runs past channel 512: fix it' : `${faults} fixtures collide or run past channel 512: fix them`} on the Patch screen before
        patching the console.
      </p>
    {/if}
  {:else}
    <p>Nothing has an address yet.</p>
  {/if}
  <div class="actions">
    <label class="switch">
      <input type="checkbox" role="switch" checked={fromOne} onchange={(e) => setFromOne(e.currentTarget.checked)} />
      <span class="track" aria-hidden="true"></span>
      <span class="label">Count Art-Net universes from 1</span>
    </label>
    <span class="spacer"></span>
    <span class="caption" role="status">{copy === 'ok' ? 'Copied' : copy === 'failed' ? 'Copy is not available here; select the text instead' : ''}</span>
    <button type="button" class="btn" onclick={copySheet}>Copy</button>
    <button type="button" class="btn" onclick={() => window.print()}>Print</button>
    <button type="button" class="btn btn-primary" onclick={() => dialog?.close()}>Close</button>
  </div>
</dialog>

<style>
  dialog { width: min(1040px, calc(100vw - 32px)); padding: 24px; color: var(--text-1); border: 1px solid var(--line-strong); }
  dialog::backdrop { background: rgba(11, 12, 14, 0.7); }
  .caption { margin: 8px 0 16px; }
  .scroll { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 6px 8px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
  th { color: var(--text-2); font-weight: 600; white-space: nowrap; }
  td:not(:last-child) { white-space: nowrap; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 16px; }
  .actions .caption { margin: 0; }
  .alert { color: var(--red); margin: 12px 0 0; }
  h2:focus { outline: none; }

  /* window.print() prints the sheet alone, black on white */
  @media print {
    :global(body *:not(:has(.patch-sheet), .patch-sheet, .patch-sheet *)) { display: none !important; }
    /* !important: app.css comes later in the bundle and sets both with the same specificity */
    :global(html), :global(body) { height: auto !important; background: #fff !important; }
    dialog { position: absolute; inset: 0 auto auto 0; width: 100%; max-width: none; max-height: none; margin: 0; padding: 0; overflow: visible; border: 0; border-radius: 0; background: #fff; color: #000; }
    .scroll { overflow: visible; }
    dialog::backdrop { background: none; }
    .caption, th, .alert { color: #000; }
    th, td { border-bottom-color: #000; }
    .actions { display: none; }
  }
</style>
