<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script module lang="ts">
  // Module scope: the router unmounts this screen on navigation, the selected cue should survive that.
  const ui = $state({ selected: '' });
</script>

<script lang="ts">
  import { onMount } from 'svelte';
  import ShowCueEditor from '../components/ShowCueEditor.svelte';
  import ShowCues from '../components/ShowCues.svelte';
  import ShowMIDI from '../components/ShowMIDI.svelte';
  import ShowOSC from '../components/ShowOSC.svelte';
  import ShowTimecode from '../components/ShowTimecode.svelte';
  import { loadChannelMap, type ChannelMap } from '../lib/patch-screen';
  import { formatNumber, lockTitle } from '../lib/show';
  import { app, can, cmd } from '../lib/state.svelte';

  /** undefined while loading, null when it could not be fetched (the next visit retries) */
  let channelMap = $state.raw<ChannelMap | null | undefined>(undefined);
  let gotoNumber = $state<number | null | undefined>(undefined);

  const cues = $derived(app.project.cues);
  const selectedCue = $derived(cues.find((c) => c.id === ui.selected));
  const gotoTarget = $derived(typeof gotoNumber === 'number' ? cues.find((c) => c.number === gotoNumber) : undefined);
  const nextText = $derived(
    app.live.cue.next === null ? 'Next: no further cue' : `Next: ${formatNumber(app.live.cue.next)}${app.live.cue.nextName ? ` ${app.live.cue.nextName}` : ''}`,
  );
  const transportLock = $derived(lockTitle('operator', can('operator'), false));

  onMount(() => {
    void loadChannelMap().then((map) => (channelMap = map));
    // Space fires the next cue (DESIGN §12) unless it is typing or pressing a focused control.
    const onKey = (event: KeyboardEvent) => {
      if (event.code !== 'Space' || event.repeat || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      const target = event.target as HTMLElement | null;
      if (target && (['INPUT', 'SELECT', 'TEXTAREA', 'BUTTON'].includes(target.tagName) || target.isContentEditable)) return;
      if (!can('operator')) return;
      event.preventDefault();
      void cmd('cue.go');
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  /** A pointer click leaves focus on the button, and Space would press it again instead of firing the next cue. */
  function releaseFocus(event: MouseEvent) {
    if (event.detail > 0 && event.target instanceof Element) event.target.closest('button')?.blur();
  }
</script>

<svelte:window onclick={releaseFocus} />

<div class="toolbar">
  <h1>Show control</h1>
  <span class="caption">{cues.length} {cues.length === 1 ? 'cue' : 'cues'} · timecode {app.live.timecode.state}</span>
  <span class="spacer"></span>
  <form
    class="goto"
    onsubmit={(event) => {
      event.preventDefault();
      if (gotoTarget) void cmd('cue.goto', { number: gotoTarget.number });
    }}
  >
    <input class="input mono" type="number" step="any" min="0" placeholder="Cue no." aria-label="Go to cue number" bind:value={gotoNumber} disabled={transportLock !== undefined} title={transportLock} />
    <button type="submit" class="btn" disabled={transportLock !== undefined || !gotoTarget} title={transportLock ?? (gotoTarget ? undefined : 'Type the number of an existing cue')}>Go to</button>
    <span class="caption target ellipsis" aria-live="polite">{gotoTarget ? (gotoTarget.name || `cue ${formatNumber(gotoTarget.number)}`) : typeof gotoNumber === 'number' ? 'no such cue' : ''}</span>
  </form>
</div>

<div class="transport" role="group" aria-label="Cue transport">
  <button type="button" class="btn btn-primary go" aria-keyshortcuts="Space" disabled={transportLock !== undefined} title={transportLock ?? 'Fire the next cue (Space)'} onclick={() => void cmd('cue.go')}>
    <span class="go-title">GO · Space</span>
    <span class="go-next ellipsis">{nextText}</span>
  </button>
  <span class="spacer"></span>
  <button type="button" class="btn back" disabled={transportLock !== undefined} title={transportLock ?? 'Fire the previous cue'} onclick={() => void cmd('cue.back')}>Back</button>
</div>

{#if app.project.policy === 'dmx'}
  <div class="banner banner-yellow" role="status">
    <span class="dot dot-yellow"></span>
    <span><strong>Source policy is Console only:</strong> cues and OSC are recorded but do not control the layers. Change it under Patch › Source policy.</span>
  </div>
{/if}

<div class="screen">
  <div class="main">
    <ShowTimecode />
    <ShowCues bind:selected={ui.selected} />
    <ShowCueEditor cue={selectedCue} map={channelMap} />
  </div>
  <aside class="side" aria-label="Control inputs">
    <ShowOSC />
    <ShowMIDI map={channelMap ?? null} />
  </aside>
</div>

<style>
  .transport { display: flex; align-items: center; gap: 48px; }
  .go { flex: 1 1 320px; max-width: 520px; height: 72px; flex-direction: column; gap: 2px; font-size: 22px; letter-spacing: 0.02em; }
  .go-title { font-weight: 700; }
  .go-next { max-width: 100%; font-size: 14px; font-weight: 500; }
  .back { min-width: 96px; }
  .goto { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
  .goto .input { width: 120px; }
  .target { max-width: 160px; }
  .screen { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
  .main { flex: 999 1 640px; min-width: 0; display: flex; flex-direction: column; gap: 16px; }
  .side { flex: 1 1 320px; min-width: 0; display: flex; flex-direction: column; gap: 16px; }
</style>
