<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  let { title, phase }: { title: string; phase: string } = $props();
</script>

<div class="toolbar"><h1>{title}</h1></div>
<div class="panel empty">
  <p class="muted">This screen arrives in {phase}. The engine already serves its data; the layout follows the approved design.</p>
</div>

<style>
  .empty { padding: 32px; }
</style>
