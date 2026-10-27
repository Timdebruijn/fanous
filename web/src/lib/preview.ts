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

/** A resize from the `w` a stream was asked with to `w`: true when the engine would pick another class (re-subscribe). */
export function classChanged(asked: number | undefined, w: number | undefined): boolean {
  return previewClass(asked ?? 640) !== previewClass(w ?? 640);
}
