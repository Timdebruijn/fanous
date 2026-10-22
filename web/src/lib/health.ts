// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

export interface Health {
  status: 'ok';
  version: string;
  uptimeSeconds: number;
  chip: string;
}

/** Validates the /healthz payload; the server is the source of truth, the client never guesses. */
export function parseHealth(value: unknown): Health {
  if (typeof value !== 'object' || value === null) throw new Error('healthz: not an object');
  const v = value as Record<string, unknown>;
  if (v.status !== 'ok') throw new Error(`healthz: status ${String(v.status)}`);
  if (typeof v.version !== 'string' || typeof v.chip !== 'string' || typeof v.uptimeSeconds !== 'number') {
    throw new Error('healthz: missing fields');
  }
  return { status: 'ok', version: v.version, uptimeSeconds: v.uptimeSeconds, chip: v.chip };
}

export function formatUptime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const rest = s % 60;
  const pad = (n: number) => n.toString().padStart(2, '0');
  return h > 0 ? `${h}h ${pad(m)}m ${pad(rest)}s` : `${m}m ${pad(rest)}s`;
}
