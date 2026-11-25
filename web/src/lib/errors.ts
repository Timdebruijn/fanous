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

/** the banner goes away by itself after this long */
export const BANNER_MS = 10_000;
/** an Undo toast stays this long */
export const TOAST_MS = 8_000;

/** Why show mode is refused while the library root switches (B51): not a readiness item, it passes by itself. */
export const ROOT_SWITCH_CAUSE = 'the library root is being switched';

/** The engine's text for a show mode entry refused during a library root switch (a `notReady` with this one id). */
export function isRootSwitch(message: string): boolean {
  return message === 'readiness: libraryRootChanging';
}

/**
 * The next step for a command refusal code (engine `CommandError` codes), or '' for an unknown one. `message` is the
 * engine's text: a `notReady` for `libraryRootChanging` is the root switch (B239), not a failed readiness check.
 */
export function errorHint(code: string, message = ''): string {
  switch (code) {
    case 'showLocked':
      return 'Show lock is on — press L or the Locked tag in the status bar to unlock (programmer).';
    case 'forbidden':
      return 'Not allowed for this role — click the role tag in the status bar and log in as programmer.';
    case 'notReady':
      if (isRootSwitch(message)) return `Show mode was refused: ${ROOT_SWITCH_CAUSE}; try again in a few seconds.`;
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
