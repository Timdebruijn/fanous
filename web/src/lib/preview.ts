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
