// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// At most one command per fixture and parameter every `ms` while a slider moves; the last value always goes out,
// to the fixture it was set for (B80: not to whichever layer is selected when the timer fires).

export type Sender = (fixture: string, parameter: string, raw: number) => void;

export function throttledSender(out: Sender, ms = 50) {
  const pending = new Map<string, Map<string, number>>(); // fixture → parameter → raw
  let timer: ReturnType<typeof setTimeout> | null = null;
  function flush() {
    if (timer) clearTimeout(timer);
    timer = null;
    for (const [fixture, values] of pending) for (const [parameter, raw] of values) out(fixture, parameter, raw);
    pending.clear();
  }
  function send(fixture: string, parameter: string, raw: number) {
    const values = pending.get(fixture) ?? new Map<string, number>();
    pending.set(fixture, values.set(parameter, Math.round(raw)));
    timer ??= setTimeout(flush, ms);
  }
  return { send, flush };
}
