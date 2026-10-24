<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import type { Role } from '../lib/protocol';
  import { can, cmd } from '../lib/state.svelte';
  import { LOCKED_TITLE, ROLES, parseOpenRoles } from '../lib/system';

  // null = unknown (not loaded yet or the request failed)
  let open = $state.raw<Role[] | null>(null);
  let drafts = $state<Record<Role, string>>({ monitor: '', operator: '', programmer: '' });
  const locked = $derived(!can('programmer'));

  async function refresh() {
    try {
      const response = await fetch('/api/session', { cache: 'no-store' });
      open = response.ok ? parseOpenRoles(await response.json()) : null;
    } catch {
      open = null;
    }
  }
  onMount(() => {
    void refresh();
  });

  async function save(role: Role, password: string | null) {
    if ((await cmd('roles.setPassword', { role, password })) !== undefined) drafts[role] = '';
    await refresh();
  }
  function clear(role: Role) {
    if (confirm(`Clear the ${role} password? The ${role} role is then open: anyone who can reach this address gets it.`)) void save(role, null);
  }
</script>

<section class="panel" aria-labelledby="roles-title">
  <header class="phead">
    <h2 id="roles-title">Roles and passwords</h2>
    <span class="caption">A role without a password is open to everyone who can reach this address.</span>
  </header>
  <ul>
    {#each ROLES as role (role)}
      {@const isOpen = open === null ? undefined : open.includes(role)}
      <li class="list-row item">
        <span class="role role-{role}">{role}</span>
        <span class="state">
          {#if isOpen === undefined}<span class="caption">unknown</span>
          {:else if isOpen}<span class="badge {role === 'programmer' ? 'badge-warn' : 'badge-outline'}">open</span>
          {:else}<span class="badge badge-outline">password set</span>{/if}
        </span>
        <form class="pw" onsubmit={(event) => { event.preventDefault(); void save(role, drafts[role]); }}>
          <input class="input" type="password" autocomplete="new-password" aria-label="New {role} password" placeholder="New password" bind:value={drafts[role]} disabled={locked} title={locked ? LOCKED_TITLE : undefined} />
          <button type="submit" class="btn" disabled={locked || drafts[role] === ''} title={locked ? LOCKED_TITLE : undefined}>Set</button>
          <button type="button" class="btn btn-danger" disabled={locked || isOpen === true} title={locked ? LOCKED_TITLE : undefined} onclick={() => clear(role)}>Clear</button>
        </form>
      </li>
    {/each}
  </ul>
  <p class="caption note">The local shell always has programmer access.</p>
</section>

<style>
  .phead { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; padding: 12px 16px; }
  ul { list-style: none; margin: 0; padding: 0; }
  .item { flex-wrap: wrap; gap: 8px 16px; padding: 8px 16px; }
  .item:last-child { border-bottom: 0; }
  .role { flex: 0 0 104px; justify-content: center; }
  .state { flex: 0 0 110px; }
  .pw { display: flex; flex-wrap: wrap; flex: 1 1 320px; gap: 8px; }
  .pw .input { flex: 1 1 180px; min-width: 0; }
  .note { margin: 0; padding: 12px 16px 16px; }
</style>
