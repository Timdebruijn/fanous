<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  // The LTC channel's level (B137): a bar over −60…0 dBFS and the number; `none` says why there is none.
  import { levelText, meterFill } from '../lib/show';

  let { level, label, none = 'no level' }: { level: number | null | undefined; label: string; none?: string } = $props();
</script>

<div class="meter" role="meter" aria-label={label} aria-valuemin={-60} aria-valuemax={0} aria-valuenow={level ?? -60} aria-valuetext={levelText(level, none)}>
  <span class="bar" aria-hidden="true"><span class="fill" class:hot={level != null && level > -3} style:width="{meterFill(level) * 100}%"></span></span>
  <span class="mono caption">{levelText(level, none)}</span>
</div>

<style>
  .meter { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .bar { flex: 1 1 120px; max-width: 240px; height: 8px; border-radius: 4px; background: var(--surface-3); overflow: hidden; }
  .fill { display: block; height: 100%; background: var(--green); transition: width 80ms linear; }
  .fill.hot { background: var(--yellow); }
  @media (prefers-reduced-motion: reduce) { .fill { transition: none; } }
</style>
