<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { app, client } from '../lib/state.svelte';
  import type { Role } from '../lib/protocol';

  // Role login (DESIGN.md §11.1): a password per role, a session cookie, then a fresh hello over the socket.
  let { onclose }: { onclose: () => void } = $props();

  let dialog: HTMLDialogElement | undefined = $state();
  let role = $state<Role>('programmer');
  let password = $state('');
  let error = $state('');
  let busy = $state(false);
  let open = $state<Role[]>([]);

  $effect(() => {
    dialog?.showModal();
    void fetch('/api/session')
      .then((r) => r.json())
      .then((s: { open: Role[] }) => (open = s.open), () => {});
  });

  function reconnect() {
    client.close();
    client.connect();
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    error = '';
    try {
      const response = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ role, password }) });
      if (response.status === 204) {
        reconnect();
        onclose();
      } else if (response.status === 429) {
        error = 'Too many attempts; wait a minute.';
      } else {
        error = 'Wrong password for this role.';
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  async function logout() {
    await fetch('/api/logout', { method: 'POST' }).catch(() => {});
    reconnect();
    onclose();
  }
</script>

<dialog bind:this={dialog} class="panel" onclose={onclose} aria-labelledby="login-title">
  <form onsubmit={submit}>
    <h2 id="login-title">Log in</h2>
    <p class="caption">You are <strong>{app.role}</strong>. Open roles need no password: {open.length ? open.join(', ') : 'none'}.</p>
    <label class="field">
      <span>Role</span>
      <select class="select" bind:value={role}>
        <option value="programmer">Programmer · everything</option>
        <option value="operator">Operator · cues, blackout, test patterns</option>
        <option value="monitor">Monitor · read only</option>
      </select>
    </label>
    <label class="field">
      <span>Password</span>
      <input class="input" type="password" autocomplete="current-password" bind:value={password} disabled={open.includes(role)} placeholder={open.includes(role) ? 'open role, no password' : ''} />
    </label>
    {#if error}<p class="err" role="alert">{error}</p>{/if}
    <div class="actions">
      <button type="button" class="btn btn-ghost" onclick={logout}>Log out</button>
      <span class="spacer"></span>
      <button type="button" class="btn" onclick={onclose}>Cancel</button>
      <button type="submit" class="btn btn-primary" disabled={busy}>Log in</button>
    </div>
  </form>
</dialog>

<style>
  dialog { width: min(420px, calc(100vw - 32px)); }
  form { display: flex; flex-direction: column; gap: 14px; }
  form p { margin: 0; }
  .field .select, .field .input { width: 100%; }
  .err { color: var(--red); font-size: 13px; }
  .actions { display: flex; gap: 8px; align-items: center; }
</style>
