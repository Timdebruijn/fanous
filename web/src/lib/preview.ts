// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

export interface Generation {
  /** No newer `begin()` and no `cancel()` since this one began. */
  current: () => boolean;
  /** After the subscription resolved: true = keep it; false = superseded, `stop` has been called. */
  keep: (stop: () => void) => boolean;
}

/**
 * Keeps only the newest of overlapping async subscriptions, so a quick target change never leaves the old stream
 * running on the server: every start `begin()`s a generation and hands its resolved subscription to `keep`.
 */
export function latestOnly(): { begin: () => Generation; cancel: () => void } {
  let generation = 0;
  return {
    begin() {
      const mine = ++generation;
      const current = () => mine === generation;
      return {
        current,
        keep(stop) {
          if (current()) return true;
          stop();
          return false;
        },
      };
    },
    cancel() {
      generation++;
    },
  };
}

/** Preview size classes (engine `PreviewSize`, DESIGN.md §11.3): the engine encodes the smallest one at least as wide as
 * the `w` a subscription asks for, `w` clamped to 160–1280. */
export const PREVIEW_CLASSES = [320, 640, 960, 1280] as const;

export function previewClass(w: number): number {
  const clamped = Math.min(1280, Math.max(160, w));
  return PREVIEW_CLASSES.find((c) => c >= clamped) ?? 1280;
}

/** The `w` a preview asks for: its rendered width in device pixels, rounded up; undefined while it has no width (the
 * engine's default then). */
export function wantedWidth(cssWidth: number, devicePixelRatio: number): number | undefined {
  const px = Math.ceil(cssWidth * (devicePixelRatio || 1));
  return px > 0 ? px : undefined;
}

/** A resize from the `w` a stream was asked with to `w`: true when the engine would pick another class (re-subscribe),
 * with 5 % hysteresis at the class edges so a box at a boundary does not flip between two streams. */
export function classChanged(asked: number | undefined, w: number | undefined): boolean {
  const current = previewClass(asked ?? 640);
  const width = w ?? 640;
  if (previewClass(width) === current) return false;
  const lower = PREVIEW_CLASSES[PREVIEW_CLASSES.indexOf(current as (typeof PREVIEW_CLASSES)[number]) - 1] ?? 160;  // current covers (lower, current]
  return width > current * 1.05 || width < lower * 0.95;
}

/** True when a served `w`×`h` stream is another shape than the box's CSS `aspect` ("1440 / 1080"): a canvas-stream
 * fallback at the encoder limit (B70) for an output's region (B87). The engine derives the height from the even width
 * and rounds it down to even (`PreviewSize.size`), so a stream of the box's shape is less than 2 lines off. An extreme
 * strip past the engine's 2160-line cap loses its aspect and counts as another shape too. */
export function otherShape(w: number, h: number, aspect: string): boolean {
  const [aw = NaN, ah = 1] = aspect.split('/').map(Number);
  const box = aw / ah;
  return w > 0 && h > 0 && box > 0 && Math.abs(h - w / box) >= 2;
}
