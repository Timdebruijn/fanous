// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Refused commands in plain words: what happened and what to do next. Pure, no store.

export interface UIMessage {
  id: number;
  at: number;
  code: string;
  /** what the engine said */
  message: string;
  /** what to do next; empty when the engine's own text says it all */
  hint: string;
}

export const MESSAGE_LIMIT = 20;
/** the banner goes away by itself after this long */
export const BANNER_MS = 10_000;
/** an Undo toast stays this long */
export const TOAST_MS = 8_000;

/** The next step for a command refusal code (engine `CommandError` codes), or '' for an unknown one. */
export function errorHint(code: string): string {
  switch (code) {
    case 'showLocked':
      return 'Show lock is on — press L or the LOCKED tag in the top bar to unlock (programmer).';
    case 'forbidden':
      return 'Not allowed for this role — click the role tag in the top bar and log in as programmer.';
    case 'notReady':
      return 'Show mode is blocked by failed readiness checks — open System to fix or acknowledge them.';
    case 'nothingToUndo':
      return 'Nothing left to undo.';
    case 'historyConflict':
      return 'Something changed since — undo no longer applies. Check the current values and redo the edit by hand.';
    case 'invalidArgs':
      return 'The value was not accepted — check it and try again.';
    case 'unknownCommand':
      return 'The engine does not know this command — the UI and the engine may be different versions; reload the page.';
    default:
      return '';
  }
}

/** Prepends a message (newest first), keeping at most `limit`. */
export function pushMessage(list: readonly UIMessage[], entry: UIMessage, limit = MESSAGE_LIMIT): UIMessage[] {
  return [entry, ...list].slice(0, limit);
}

export function makeMessage(id: number, at: number, error: { code: string; message: string }): UIMessage {
  return { id, at, code: error.code, message: error.message, hint: errorHint(error.code) };
}
