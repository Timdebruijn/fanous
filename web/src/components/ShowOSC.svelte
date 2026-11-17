<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { refusalNote } from '../lib/show';
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
    { address: '/fanous/project/load', args: 's', note: 'Load the newest named project version with that name, else the version with that id; refused in show mode or while locked' },
    { address: '/fanous/{path}/get', args: '[i]', note: 'Answers the sender with every value at or below path (/fanous/get: the summary); with a port, to that port of a confirmed subscription' },
    { address: '/fanous/subscribe', args: 'si [s]', note: 'Your own IP address, a port and an optional prefix: changes go to that port once /fanous/subscribe/ack returns the cookie' },
    { address: '/fanous/subscribe/ack', args: 's', note: 'The cookie from /fanous/subscribe/confirm, within 5 s' },
    { address: '/fanous/unsubscribe', args: '[s i s]', note: 'Ends the sender\'s subscriptions; with host, port and prefix only that one' },
    { address: '/fanous/ping', args: '', note: 'Renews the sender\'s subscriptions; answered with /fanous/pong' },
  ];

  const osc = $derived(app.live.osc);
  const recent = $derived([...osc.recent].reverse());
  const refused = $derived(refusalNote(osc.refused, app.live.show.readiness));
</script>

<section class="panel osc" aria-labelledby="osc-title">
  <header>
    <h2 id="osc-title">OSC</h2>
    <span class="spacer"></span>
    <span class="caption">Port <span class="mono">{osc.port}</span></span>
  </header>

  <h3 id="osc-recent">Last received</h3>
  <p class="caption">Every message received, as sent; a listed command can still be refused. A fader sweep on one address is one row with its last value.</p>
  <!-- B210: a polite live region, always there, so a refusal is announced when it appears (StatusBar's "not ready" does
       the same). The engine replaces it with a newer refusal and clears it once the command is accepted from OSC/MIDI,
       a minute after its last refusal, or (show mode) once show mode is on. -->
  <p class="err" role="status" aria-atomic="true">{refused ?? ''}</p>
  {#if recent.length === 0}
    <p class="caption">Nothing received yet. Send <span class="mono">/fanous/cue/go</span> to port {osc.port} to try it.</p>
  {:else}
    <ol class="recent" aria-labelledby="osc-recent">
      {#each recent as r, i (i)}
        <li><time class="mono faint">{stampText(r.at)}</time><span class="mono text" title={r.command}>{r.command}</span></li>
      {/each}
    </ol>
  {/if}

  <h3 id="osc-addresses">Addresses</h3>
  <!-- address and args on one line, the effect under it: a three-column table clipped the effect in the 320 px side column -->
  <ul class="addresses" role="list" aria-labelledby="osc-addresses">
    {#each addresses as a (a.address)}
      <li><span class="mono">{a.address}</span><span class="mono faint">{a.args ? `args ${a.args}` : 'no args'}</span><span class="effect muted">{a.note}</span></li>
    {/each}
  </ul>
</section>

<style>
  .osc { padding: 16px; display: flex; flex-direction: column; gap: 8px; }
  header { display: flex; align-items: center; gap: 12px; }
  p { margin: 0; }
  .err { color: var(--red); font-size: 13px; overflow-wrap: anywhere; }
  .err:empty { margin-bottom: -8px; } /* takes no room, the panel's gap included, while there is nothing to say */
  .recent { list-style: none; margin: 0; padding: 0; max-height: 240px; overflow-y: auto; border: 1px solid var(--line); border-radius: 8px; }
  .recent li { display: flex; gap: 12px; align-items: flex-start; padding: 8px 12px; border-bottom: 1px solid var(--line); font-size: 13px; }
  .recent li:last-child { border-bottom: 0; }
  .recent time { flex: none; }
  /* wraps, so a parameter row shows its value in the narrow panel; three lines bound a long message (the title has all of it).
     The time and the text are the same mono face, so top-aligned they share a first line without a baseline of the clamp box. */
  .recent .text { min-width: 0; overflow-wrap: anywhere; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 3; line-clamp: 3; overflow: hidden; }
  .addresses { list-style: none; margin: 0; padding: 0; font-size: 12px; }
  .addresses li { display: grid; grid-template-columns: minmax(0, 1fr) auto; column-gap: 8px; padding: 8px 0; border-bottom: 1px solid var(--line); overflow-wrap: anywhere; }
  .addresses li:last-child { border-bottom: 0; }
  .effect { grid-column: 1 / -1; }
</style>
