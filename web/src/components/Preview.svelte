<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { app, subscribePreview } from '../lib/state.svelte';

  // Canvas (or output) preview (DESIGN.md §11.3): WebCodecs H.264 when the browser decodes it, JPEG at 5 fps otherwise.
  // aspect: CSS aspect-ratio of the picture; an output preview uses the output's own shape (the stream itself is 16:9)
  // label: what is shown, appended to the caption ("Layer 3"); none = the caption names no source
  let { target = 'canvas', aspect = '16 / 9', label = '' }: { target?: string; aspect?: string; label?: string } = $props();
  let canvas: HTMLCanvasElement | undefined = $state();
  let mode = $state<'connecting' | 'avc' | 'jpeg' | 'off'>('connecting');
  let detail = $state('');
  // the time of the last drawn frame is a plain variable: per-frame $state would re-render the caption 30× a second
  let lastFrame = 0;
  let stalled = $state(false);
  let stop: (() => void) | null = null;
  // a hidden tab (another tab in front, minimised window) takes no preview stream; it resumes when the tab shows again
  let hidden = typeof document !== 'undefined' && document.hidden;

  async function start() {
    if (!canvas || hidden) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const supportsWebCodecs = 'VideoDecoder' in window && 'EncodedVideoChunk' in window;
    let decoder: VideoDecoder | null = null;
    let configured = false;
    let sawKey = false;

    const drawBitmap = (bitmap: ImageBitmap | VideoFrame) => {
      if (!canvas) return;
      if (canvas.width !== bitmap.displayWidth && 'displayWidth' in bitmap) {
        canvas.width = bitmap.displayWidth;
        canvas.height = bitmap.displayHeight;
      }
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      lastFrame = performance.now();
      bitmap.close();
    };

    const fallbackToJPEG = async (why: string) => {
      detail = why;
      decoder?.close();
      decoder = null;
      stop?.();
      const sub = await subscribePreview(
        'jpeg',
        async (_kind, payload) => {
          if (!canvas) return;
          const bitmap = await createImageBitmap(new Blob([payload as BlobPart], { type: 'image/jpeg' }));
          if (canvas && (canvas.width !== bitmap.width || canvas.height !== bitmap.height)) {
            canvas.width = bitmap.width;
            canvas.height = bitmap.height;
          }
          drawBitmap(bitmap);
        },
        () => {},
        target,
      );
      stop = sub.stop;
      mode = 'jpeg';
      if (hidden) pause();  // hidden while the subscription was being set up
    };

    if (!supportsWebCodecs) {
      await fallbackToJPEG('no WebCodecs');
      return;
    }
    try {
      const sub = await subscribePreview(
        'avc',
        (kind, payload) => {
          if (kind !== 1 || !decoder || !configured || payload.length < 9) return;
          const key = payload[0] === 1;
          if (!sawKey && !key) return;
          sawKey = true;
          let micros = 0;
          for (let i = 1; i < 9; i++) micros = micros * 256 + payload[i]!;
          try {
            decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: micros, data: payload.subarray(9) }));
          } catch (error) {
            void fallbackToJPEG(`decode: ${String(error)}`);
          }
        },
        async (description) => {
          const config: VideoDecoderConfig = { codec: description.codec, description: description.description, optimizeForLatency: true };
          try {
            const support = await VideoDecoder.isConfigSupported(config);
            if (!support.supported) throw new Error('config not supported');
            decoder?.close();
            decoder = new VideoDecoder({ output: drawBitmap, error: (e) => void fallbackToJPEG(`decoder: ${e.message}`) });
            decoder.configure(config);
            configured = true;
            sawKey = false;
            mode = 'avc';
            if (canvas) {
              canvas.width = description.w;
              canvas.height = description.h;
            }
          } catch (error) {
            void fallbackToJPEG(String(error));
          }
        },
        target,
      );
      stop = sub.stop;
      detail = `${sub.w}×${sub.h} · ${sub.fps} fps`;
      if (hidden) pause();
    } catch (error) {
      mode = 'off';
      detail = (error as { message?: string }).message ?? String(error);
    }
  }

  function pause() {
    stop?.();
    stop = null;
    lastFrame = 0;
    stalled = false;
  }

  function onVisibility() {
    hidden = document.hidden;
    if (hidden) pause();
    else if (stop === null) void start();
  }

  onMount(() => {
    void start();
    document.addEventListener('visibilitychange', onVisibility);
    // once a second: flag a preview that stopped arriving (2 s without a frame); only a change touches the DOM
    const watch = setInterval(() => {
      const now = !hidden && lastFrame > 0 && performance.now() - lastFrame > 2000;
      if (now !== stalled) stalled = now;
    }, 1000);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      clearInterval(watch);
      stop?.();
      stop = null;
    };
  });

  // reconnects re-subscribe; a new target restarts the stream
  $effect(() => {
    if (app.connection === 'open' && !hidden && stop === null && mode !== 'connecting') void start();
  });
  let shownTarget = target;
  $effect(() => {
    if (target === shownTarget) return;
    shownTarget = target;
    pause();
    void start();  // does nothing while hidden; the next show starts the new target
  });
</script>

<figure class="preview">
  <canvas bind:this={canvas} width="640" height="360" aria-label={`${label || 'Canvas'} preview`} style:aspect-ratio={aspect}></canvas>
  <figcaption class="caption">
    {#if mode === 'avc'}H.264 · {detail}{:else if mode === 'jpeg'}JPEG 5 fps · {detail}{:else if mode === 'off'}no preview · {detail}{:else}connecting…{/if}{#if label} · {label}{/if}
    {#if stalled}<span class="stalled"> · no new frames</span>{/if}
  </figcaption>
</figure>

<style>
  .stalled { color: var(--yellow); }
  .preview { margin: 0; display: flex; flex-direction: column; gap: 6px; }
  canvas { width: 100%; height: auto; aspect-ratio: 16 / 9; border-radius: 8px; background: #000; border: 1px solid var(--line); display: block; }
</style>
