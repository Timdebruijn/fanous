<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  // Copy with its caption for 2.5 s: "Copied", or the fallback where the clipboard refuses (no permission, no secure context).
  let { text, disabled = false, captionFirst = false }: { text: string; disabled?: boolean; captionFirst?: boolean } = $props();

  let copy = $state<'idle' | 'ok' | 'failed'>('idle');
  async function onclick() {
    try {
      await navigator.clipboard.writeText(text);
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

{#snippet caption()}
  <span class="caption" role="status">{copy === 'ok' ? 'Copied' : copy === 'failed' ? 'Copy is not available here; select the text instead' : ''}</span>
{/snippet}
{#if captionFirst}{@render caption()}{/if}
<button type="button" class="btn" {disabled} {onclick}>Copy</button>
{#if !captionFirst}{@render caption()}{/if}
