<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- Copyright (c) 2026 Tim de Bruijn -->
<!-- Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md -->
<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { previewReady } from '../lib/outputs';
  import { classChanged, latestOnly, otherShape, wantedWidth } from '../lib/preview';
  import { app, subscribePreview } from '../lib/state.svelte';

  // Canvas (or output) preview (DESIGN.md §11.3): WebCodecs H.264 when the browser decodes it, JPEG at 5 fps otherwise.
  // aspect: CSS aspect-ratio of the picture, the shape of the canvas or output shown (the stream has the same shape)
  // label: what is shown, appended to the caption ("Layer 3"); none = the caption names no source
  let { target = 'canvas', aspect = '16 / 9', label = '' }: { target?: string; aspect?: string; label?: string } = $props();
  let canvas: HTMLCanvasElement | undefined = $state();
  let mode = $state<'connecting' | 'avc' | 'jpeg' | 'off'>('connecting');
  let detail = $state('');
  // the time of the last drawn frame is a plain variable: per-frame $state would re-render the caption 30× a second
  let lastFrame = 0;
  let stalled = $state(false);
  let stop: (() => void) | null = null;
  // the size of the stream served (the `sub` reply, then each `stream` description): another shape than the box is the
  // canvas stream an output's region fell back to at the encoder limit (B70), shown whole, letterboxed (B87)
  let served = $state<{ w: number; h: number } | null>(null);
  const fallback = $derived(served !== null && otherShape(served.w, served.h, aspect));
  // a hidden tab (another tab in front, minimised window) takes no preview stream; it resumes when the tab shows again
  let hidden = typeof document !== 'undefined' && document.hidden;
  // a new canvas renders only after the canvas switch: its preview is asked for once the engine lists it as rendered
  const ready = $derived(previewReady(target, app.live.canvas?.canvases));

  // a target change while a subscription is still pending: the older one is stopped when it resolves
  const latest = latestOnly();
  // the width the stream was asked for (B32): the rendered width in device pixels, so a small box gets a small stream
  let asked: number | undefined;
  const measure = () => (canvas ? wantedWidth(canvas.getBoundingClientRect().width, window.devicePixelRatio) : undefined);
  // the H.264 decoder of the current stream: closed by `pause()` (target change, disconnect, hidden tab) and on unmount
  // (B85); a decoder that failed closed itself, so `close()` (which throws then) only on one that is still open
  let decoder: VideoDecoder | null = null;
  function closeDecoder() {
    if (decoder && decoder.state !== 'closed') decoder.close();
    decoder = null;
  }

  async function start() {
    if (!canvas || hidden || !ready) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const run = latest.begin();
    asked = measure();
    const supportsWebCodecs = 'VideoDecoder' in window && 'EncodedVideoChunk' in window;
    let configured = false;
    let sawKey = false;

    const drawBitmap = (bitmap: ImageBitmap | VideoFrame) => {
      if (!canvas) return;
      if ('displayWidth' in bitmap && canvas.width !== bitmap.displayWidth) {
        canvas.width = bitmap.displayWidth;
        canvas.height = bitmap.displayHeight;
      }
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      lastFrame = performance.now();
      bitmap.close();
    };
    // a JPEG frame (kind 2): the JPEG stream, or an H.264 one the engine refused at its encoder limit (B86)
    const drawJPEG = async (payload: Uint8Array) => {
      if (!canvas) return;
      const bitmap = await createImageBitmap(new Blob([payload as BlobPart], { type: 'image/jpeg' }));
      // decoded after the H.264 path started: it must not set the canvas back to its size (`drawBitmap` compares widths)
      if (mode === 'avc' && configured) return bitmap.close();
      if (canvas && (canvas.width !== bitmap.width || canvas.height !== bitmap.height)) {
        canvas.width = bitmap.width;
        canvas.height = bitmap.height;
      }
      drawBitmap(bitmap);
    };

    const fallbackToJPEG = async (why: string) => {
      if (!run.current()) return;  // a late error of a stream that was already replaced
      const jpegRun = latest.begin();
      detail = why;
      closeDecoder();
      configured = false;
      mode = 'connecting';  // no "H.264 · …" caption over the closed decoder while JPEG is asked for (B98)
      stop?.();
      stop = null;  // a refused JPEG request must not leave the stopped stream behind: reconnects restart from null
      let sub: Awaited<ReturnType<typeof subscribePreview>>;
      try {
        sub = await subscribePreview(
          'jpeg',
          (_kind, payload) => void drawJPEG(payload),
          () => {},
          target,
          asked,
        );
      } catch (error) {
        if (!jpegRun.current()) return;
        mode = 'off';
        detail = (error as { message?: string }).message ?? String(error);
        return;
      }
      if (!jpegRun.keep(sub.stop)) return;
      stop = sub.stop;
      served = { w: sub.w, h: sub.h };
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
          // JPEG on this stream: refused at the encoder limit (B70), or moved back to JPEG by the engine (B88); drawn,
          // and a later `stream` description upgrades it again (the engine moves a subscriber in one step)
          if (kind === 2) {
            if (configured) {
              closeDecoder();
              configured = false;
              mode = 'jpeg';
              detail = 'H.264 stopped by the engine';
            }
            void drawJPEG(payload);
            return;
          }
          if (kind !== 1 || decoder?.state !== 'configured' || payload.length < 9) return;
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
            if (!run.current()) return;  // paused (or fallen back) while the check ran: no decoder for a stopped stream
            closeDecoder();
            decoder = new VideoDecoder({ output: drawBitmap, error: (e) => void fallbackToJPEG(`decoder: ${e.message}`) });
            decoder.configure(config);
            configured = true;
            sawKey = false;
            mode = 'avc';
            detail = `${description.w}×${description.h} · ${description.fps} fps`;  // a rebuilt stream (new shape) too
            served = { w: description.w, h: description.h };
            if (canvas) {
              canvas.width = description.w;
              canvas.height = description.h;
            }
          } catch (error) {
            void fallbackToJPEG(String(error));
          }
        },
        target,
        asked,
      );
      if (!run.keep(sub.stop)) return;
      stop = sub.stop;
      served = { w: sub.w, h: sub.h };
      if (sub.codec === 'jpeg') {
        // all H.264 encoders busy (B70): JPEG on this stream, kept, so the engine can upgrade it when one frees up (B86)
        mode = 'jpeg';
        detail = `${sub.w}×${sub.h} · H.264 encoders busy`;
      } else {
        detail = `${sub.w}×${sub.h} · ${sub.fps} fps`;
        // the engine makes its H.264 encoder for the first viewer (B66): no description in 5 s (it failed or is stuck) → JPEG
        setTimeout(() => {
          if (!configured) void fallbackToJPEG('no H.264 stream from the engine');
        }, 5000);
      }
      if (hidden) pause();
    } catch (error) {
      if (!run.current()) return;
      mode = 'off';
      detail = (error as { message?: string }).message ?? String(error);
    }
  }

  function pause() {
    latest.cancel();  // a subscription still on its way is stopped when it arrives
    stop?.();
    stop = null;
    closeDecoder();
    mode = 'connecting';  // no stale "H.264 · …" caption while the next stream is asked for
    served = null;
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
    // a resize into another size class asks for a stream of that size, once the resize has settled
    let settle: ReturnType<typeof setTimeout> | undefined;
    const check = () => {
      clearTimeout(settle);
      settle = setTimeout(() => {
        if (hidden || mode === 'off' || !classChanged(asked, measure())) return;
        pause();
        void start();
      }, 300);
    };
    const resized = new ResizeObserver(check);
    if (canvas) resized.observe(canvas);
    // the window moved to a screen with another pixel ratio (or the page was zoomed): same box, other device pixels
    let ratio: MediaQueryList | undefined;
    const onRatio = () => {
      ratio?.removeEventListener('change', onRatio);
      ratio = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
      ratio.addEventListener('change', onRatio);
      check();
    };
    onRatio();
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      clearInterval(watch);
      clearTimeout(settle);
      resized.disconnect();
      ratio?.removeEventListener('change', onRatio);
      latest.cancel();  // unmounted while subscribing: that stream stops when it arrives
      stop?.();
      stop = null;
      closeDecoder();
    };
  });

  // reconnects re-subscribe (only the connection triggers this: a refusal turning mode to 'off' must not ask again at
  // once); a closed socket took the stream with it (B68), so it is let go and the next open asks once; a new target
  // restarts the stream
  $effect(() => {
    if (app.connection !== 'open') untrack(offline);
    else if (!hidden && stop === null && untrack(() => mode) !== 'connecting') {
      mode = 'connecting';  // not "no preview" (which also ignores resizes) until the stream is back
      void start();
    }
  });
  function offline() {
    pause();
    mode = 'off';
    detail = 'not connected';
  }
  // the first target; the effect below follows later changes, and a canvas that starts (or stops) rendering
  let shownTarget = untrack(() => target);
  let shownReady = untrack(() => ready);
  $effect(() => {
    if (target === shownTarget && ready === shownReady) return;
    shownTarget = target;
    shownReady = ready;
    pause();
    void start();  // does nothing while hidden or not ready; the next show or the canvas switch starts it
  });
</script>

<figure class="preview">
  <canvas bind:this={canvas} width="640" height="360" aria-label={`${label || 'Canvas'} preview`} style:aspect-ratio={aspect} style:object-fit={fallback ? 'contain' : undefined}></canvas>
  <figcaption class="caption">
    {#if !ready}starting…{:else if mode === 'avc'}H.264 · {detail}{:else if mode === 'jpeg'}JPEG 5 fps · {detail}{:else if mode === 'off'}no preview · {detail}{:else}connecting…{/if}{#if fallback && (mode === 'avc' || mode === 'jpeg')}{' · canvas fallback'}{/if}{#if label}{' · '}{label}{/if}
    {#if stalled}<span class="stalled"> · no new frames</span>{/if}
  </figcaption>
</figure>

<style>
  .stalled { color: var(--yellow); }
  .preview { margin: 0; display: flex; flex-direction: column; gap: 6px; }
  canvas { width: 100%; height: auto; aspect-ratio: 16 / 9; border-radius: 8px; background: #000; border: 1px solid var(--line); display: block; }
</style>
