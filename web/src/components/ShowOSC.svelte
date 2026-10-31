<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { stampText } from '../lib/system';
  import { app } from '../lib/state.svelte';

  // DESIGN §15.3. Layer and output parameters take a float (0–1 of the raw range) or an int (raw value).
  const addresses = [
    { address: '/fanous/layer/{n}/{param}', args: 'f', note: 'Layer parameter; param is a key of the channel map' },
    { address: '/fanous/layer/{n}/media', args: 'ii', note: 'Folder, file' },
    { address: '/fanous/layer/{n}/retrigger', args: '', note: 'Restart the media' },
    { address: '/fanous/master/{param}', args: 'f', note: 'Master parameter' },
    { address: '/fanous/output/{n}/{param}', args: 'f', note: 'Output parameter' },
    { address: '/fanous/keystone/{n}/{param}', args: 'f', note: 'Keystone parameter of output n' },
    { address: '/fanous/cue/go', args: '', note: 'Fire the next cue' },
    { address: '/fanous/cue/back', args: '', note: 'Fire the previous cue' },
    { address: '/fanous/cue/goto', args: 'i', note: 'Fire the cue with this number' },
    { address: '/fanous/cue/{number}/go', args: '', note: 'Fire that cue' },
    { address: '/fanous/show/lock', args: 'i', note: '1 locks the show, 0 unlocks' },
    { address: '/fanous/show/mode', args: 'i', note: '1 enters show mode, 0 leaves' },
    { address: '/fanous/timecode/enable', args: 'i', note: '1 switches timecode on, 0 off' },
  ];

  const osc = $derived(app.live.osc);
  const recent = $derived([...osc.recent].reverse());
</script>

<section class="panel osc" aria-labelledby="osc-title">
  <header>
    <h2 id="osc-title">OSC</h2>
    <span class="spacer"></span>
    <span class="caption">Port <span class="mono">{osc.port}</span></span>
  </header>

  <h3 id="osc-recent">Last received</h3>
  {#if recent.length === 0}
    <p class="caption">Nothing received yet. Send <span class="mono">/fanous/cue/go</span> to port {osc.port} to try it.</p>
  {:else}
    <ol class="recent" aria-labelledby="osc-recent">
      {#each recent as r, i (i)}
        <li><time class="mono faint">{stampText(r.at)}</time><span class="mono ellipsis" title={r.command}>{r.command}</span></li>
      {/each}
    </ol>
  {/if}

  <h3>Addresses</h3>
  <div class="scroll">
    <table>
      <thead><tr><th scope="col">Address</th><th scope="col">Args</th><th scope="col">Effect</th></tr></thead>
      <tbody>
        {#each addresses as a (a.address)}
          <tr><td class="mono">{a.address}</td><td class="mono">{a.args || '–'}</td><td class="muted">{a.note}</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
</section>

<style>
  .osc { padding: 16px; display: flex; flex-direction: column; gap: 8px; }
  header { display: flex; align-items: center; gap: 12px; }
  p { margin: 0; }
  .recent { list-style: none; margin: 0; padding: 0; max-height: 240px; overflow-y: auto; border: 1px solid var(--line); border-radius: 8px; }
  .recent li { display: flex; gap: 12px; align-items: baseline; padding: 6px 12px; border-bottom: 1px solid var(--line); font-size: 13px; }
  .recent li:last-child { border-bottom: 0; }
  .recent time { flex: none; }
  .scroll { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th { text-align: left; font-weight: 500; color: var(--text-3); padding: 4px 8px 4px 0; border-bottom: 1px solid var(--line); }
  td { padding: 6px 8px 6px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
  td.mono { white-space: nowrap; }
  tbody tr:last-child td { border-bottom: 0; }
</style>
