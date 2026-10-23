// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Hash routing for six screens (DESIGN.md §11.4): no router library.

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
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target as HTMLElement | null;
    if (target && (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return;
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
