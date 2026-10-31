// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// What the projector-wall wizard and the wall panels have open, kept outside the components so it is shared by them
// and survives a switch to Warp & Slices (the Grid step of the seam check sends the user there); leaving the Outputs
// screen ends the wizard and the seam check. The test patterns they show are a lease (`output.pattern`, B102) that the
// Outputs screen holds while `wallPatterns` names one: never an edit of the outputs' own patterns, so nothing to give back.
import { app, cmd, toastUndo } from './state.svelte';
import { PATTERN, SEAM_STEPS, editDraft, freeOutputs, newDraft, wallArgs, type Control, type WallConfig, type WizardDraft } from './walls';

export type Pick = { wall: number } & ({ kind: 'seam'; a: number; b: number } | { kind: 'projector'; output: number } | { kind: 'geometry' });

export const wallUI = $state({
  wizard: null as WizardDraft | null,
  /** a wall.add or wall.set of the wizard is on its way */
  busy: false,
  /** what a wall panel shows below its mini-map */
  pick: null as Pick | null,
  /** the control a seam-check hint opened: drawn highlighted */
  focus: null as Control | null,
  /** a hint of the current seam-check step (its index) waiting for the user to tap a seam or projector on the mini-map */
  hint: null as number | null,
  check: null as { wall: number; step: number } | null,
});

/** The test pattern the seam check or the wizard shows and on which outputs, or null: the check's step on every output
 * of its wall; the wizard's Output ID on every free output on a display (an output bound or unbound meanwhile too). */
export function wallPatterns(): { ids: number[]; pattern: number } | null {
  const check = wallUI.check, wall = check && app.project.walls?.find((w) => w.id === check.wall);
  if (check && wall) return { ids: wall.outputs, pattern: SEAM_STEPS[check.step]!.pattern };
  if (!wallUI.wizard) return null;
  const bound = new Set(app.live.outputs.filter((s) => s.state === 'bound').map((s) => s.id));
  const ids = freeOutputs(app.project.outputs, app.project.walls, wallUI.wizard.edit ?? undefined).map((o) => o.id).filter((id) => bound.has(id));
  return ids.length ? { ids, pattern: PATTERN.outputID } : null;
}

/** New projector wall, or Edit layout… of `wall`. */
export function startWizard(wall?: WallConfig): void {
  endCheck();
  wallUI.pick = null;
  wallUI.wizard = wall ? editDraft(wall) : newDraft(app.project.canvases[0]?.id ?? 1);
}

export function wizardBack(): void {
  if (wallUI.wizard) wallUI.wizard.step = 1;
}

export function cancelWizard(): void {
  wallUI.wizard = null;
}

/** wall.add (or wall.set): one Undo takes the wall back; the panel opens on the seam check, Blend check. A refusal keeps
 * the wizard open (the banner says why). */
export async function applyWizard(): Promise<void> {
  const draft = wallUI.wizard;
  if (!draft?.grid || wallUI.busy) return;
  wallUI.busy = true;
  try {
    const args = wallArgs({ ...draft, grid: draft.grid });
    const result = draft.edit !== null ? await cmd('wall.set', { ...args, id: draft.edit }) : await cmd('wall.add', { ...args, overlap: args.overlap! });
    if (result === undefined) return;
    wallUI.wizard = null;
    wallUI.check = { wall: draft.edit ?? Number(result), step: SEAM_STEPS.findIndex((s) => s.pattern === PATTERN.blendCheck) };
  } finally {
    wallUI.busy = false;
  }
}

export function stepCheck(wall: WallConfig, step: number): void {
  if (!SEAM_STEPS[step]) return;
  wallUI.check = { wall: wall.id, step };
  wallUI.hint = null;
}

export function endCheck(): void {
  wallUI.hint = null;
  wallUI.check = null;
}

/** Selects a seam, a projector or the geometry on a wall's panel (null: closes it). */
export function pick(next: Pick | null, focus: Control | null = null): void {
  wallUI.pick = next;
  wallUI.focus = focus;
  wallUI.hint = null;
}

/** Remove wall: the outputs keep their slices and blend edges as they are now; Undo brings the wall back. */
export async function removeWall(wall: WallConfig): Promise<void> {
  if (wallUI.check?.wall === wall.id) endCheck();
  if (wallUI.pick?.wall === wall.id) pick(null);
  if ((await cmd('wall.remove', { id: wall.id })) !== undefined) toastUndo(`${wall.name} removed. Its outputs keep their slices and blend edges.`);
}
