// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Hash routing for seven screens (DESIGN.md §11.4, §12.1): no router library. Also the global keys of §12:
// 1–7 screens, Cmd/Ctrl+Z undo, Shift+Cmd/Ctrl+Z redo, L show lock (programmer; asks only when unlocking during show mode), ? shortcut list.
// None of them act while a modal dialog is open, except ? closing the shortcut list.
import { can, cmd, shell, toggleLock } from './state.svelte';

export const screens = [
  { id: 'layers', label: 'Layers', key: '1' },
  { id: 'media', label: 'Media', key: '2' },
  { id: 'inputs', label: 'Inputs', key: '3' },
  { id: 'outputs', label: 'Outputs', key: '4' },
  { id: 'patch', label: 'Patch', key: '5' },
  { id: 'show', label: 'Show', key: '6' },
  { id: 'system', label: 'System', key: '7' },
] as const;

export type ScreenId = (typeof screens)[number]['id'];

function fromHash(): { screen: ScreenId; item: string } {
  const [id, item = ''] = location.hash.replace(/^#\/?/, '').split('/');
  return { screen: (screens.find((s) => s.id === id)?.id ?? 'layers') as ScreenId, item };
}

/** `item` is the second hash segment: the input selected on the Inputs screen (`#/inputs/3`). */
export const route = $state(fromHash());

export function go(screen: ScreenId, item = ''): void {
  location.hash = item ? `#/${screen}/${item}` : `#/${screen}`;
}

export function startRouter(): () => void {
  const onHash = () => {
    Object.assign(route, fromHash());
  };
  const onKey = (event: KeyboardEvent) => {
    const target = event.target as HTMLElement | null;
    if (target && (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return;
    // the page under a modal dialog is inert, so its keys are too
    if (document.querySelector('dialog:modal') && !(event.key === '?' && shell.help)) return;
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'z') {
      event.preventDefault();
      if (can('programmer')) void cmd(event.shiftKey ? 'redo' : 'undo');
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === '?') {
      shell.help = !shell.help;
      return;
    }
    if (event.key.toLowerCase() === 'l' && can('programmer')) {
      void toggleLock();
      return;
    }
    const screen = screens.find((s) => s.key === event.key);
    if (screen) go(screen.id);
  };
  window.addEventListener('hashchange', onHash);
  window.addEventListener('keydown', onKey);
  return () => {
    window.removeEventListener('hashchange', onHash);
    window.removeEventListener('keydown', onKey);
  };
}
