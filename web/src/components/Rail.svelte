<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { route, screens } from '../lib/router.svelte';

  const icons: Record<string, string> = {
    layers: 'm12 3 9 5-9 5-9-5 9-5zM3 13l9 5 9-5M3 17l9 5 9-5',
    media: 'M3 4h18v16H3zM3 9h18M3 15h18M8 4v16M16 4v16',
    outputs: 'M2 4h20v13H2zM8 21h8M12 17v4',
    patch: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
    show: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2',
    system: 'M3 12h4l3-8 4 16 3-8h4',
  };
</script>

<nav aria-label="Screens">
  {#each screens as screen (screen.id)}
    <a href="#/{screen.id}" aria-current={route.screen === screen.id ? 'page' : undefined} title="{screen.label} ({screen.key})">
      <svg aria-hidden="true" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d={icons[screen.id]} /></svg>
      <span>{screen.label}</span>
    </a>
  {/each}
</nav>

<style>
  nav { flex: 1 0 84px; display: flex; flex-wrap: wrap; align-content: flex-start; background: var(--surface-1); border-right: 1px solid var(--line); padding: 8px 0; }
  a { flex: 0 0 84px; height: 64px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; color: var(--text-2); text-decoration: none; font-size: 11px; font-weight: 500; }
  a:hover { color: var(--text-1); }
  a[aria-current='page'] { color: var(--text-1); background: var(--surface-2); box-shadow: inset 3px 0 0 var(--accent); font-weight: 600; }
  /* iPad portrait and narrower: icons only, 56 px */
  @media (max-width: 1100px) {
    nav { flex-basis: 56px; }
    a { flex-basis: 56px; height: 56px; }
    a span { display: none; }
  }
</style>
