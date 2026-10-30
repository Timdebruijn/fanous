// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Hash routing for six screens (DESIGN.md §11.4): no router library. Also the global keys of §12:
// 1–6 screens, Cmd/Ctrl+Z undo, Shift+Cmd/Ctrl+Z redo, L show lock (programmer; asks only when unlocking during show mode), ? shortcut list.
// None of them act while a modal dialog is open, except ? closing the shortcut list.
import { can, cmd, shell, toggleLock } from './state.svelte';

export const screens = [
  { id: 'layers', label: 'Layers', key: '1' },
  { id: 'media', label: 'Media', key: '2' },
  { id: 'outputs', label: 'Outputs', key: '3' },
  { id: 'patch', label: 'Patch', key: '4' },
  { id: 'show', label: 'Show', key: '5' },
  { id: 'system', label: 'System', key: '6' },
] as const;

export type ScreenId = (typeof screens)[number]['id'];

function fromHash(): ScreenId {
  const id = location.hash.replace(/^#\/?/, '').split('/')[0];
  return (screens.find((s) => s.id === id)?.id ?? 'layers') as ScreenId;
}

export const route = $state({ screen: fromHash() });

export function go(screen: ScreenId): void {
  location.hash = `#/${screen}`;
}

export function startRouter(): () => void {
  const onHash = () => {
    route.screen = fromHash();
  };
  const onKey = (event: KeyboardEvent) => {
    const target = event.target as HTMLElement | null;
    if (target && (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return;
    // the page under a modal dialog (login, revert, Patch sheet) is inert, so its keys are too
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
